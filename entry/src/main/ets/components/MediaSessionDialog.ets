import { AVPlaybackState, AVCastController, AVSession, AVSessionController, ConnectionState, DeviceInfo, OutputDeviceInfo, PlaybackState, createAVSession, createController } from '../common/compat/AvSessionCompat';
import { PlatformInfo } from '../common/compat/PlatformInfo';
import { common, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { webSocket } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { Logger } from '../common/Logger';
import { CoPlayInviteHandoff } from '../common/CoPlayInviteHandoff';
import { CoPlayShareService } from '../common/CoPlayShareService';
import { CoPlayLanDevice, CoPlayLanService } from '../common/CoPlayLanService';
import { Quest3ControlService, Quest3CoPlayPayload, Quest3DeviceDescriptor, Quest3SceneMode, Quest3StatePacket } from '../common/Quest3ControlService';
import { Ui } from '../common/Ui';

export interface MediaSessionDevice {
  deviceId: string;
  deviceName: string;
  lastSeen: number;
}
export interface MediaSessionCommand {
  action: string;
  deviceId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  speedIndex: number;
  playing: boolean;
  // 新版单调递增序列号；旧版本消息可缺省，接收端退回 timestamp 去重。
  sequence?: number;
  protocolVersion?: number;
  routeIndex?: number;
  ratio?: string;
  // 可选协播弹幕包；旧客户端忽略该字段，避免改变既有协议必填字段。
  danmaku?: string;
}
export interface MediaSessionInvitation {
  version: number;
  vodId: string;
  sessionId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  syncMode?: string;
  serverUrl?: string;
}
interface SessionEnvelope {
  action: string;
  sessionId: string;
  deviceId: string;
  deviceName: string;
  targetId: string;
  hostId: string;
  devices: MediaSessionDevice[];
  command?: MediaSessionCommand;
}
// JSON v1：服务器须验证房间成员和主控权限，create + resume 须按房间与设备幂等处理。
// 请求 create/join/control/transfer/kick/leave/ping；响应 welcome/members/state/pong/error。
// welcome/members 必须返回完整 hostId 和 devices；不得相信客户端自报的主控身份。
interface ServerPacket {
  version: number;
  type: string;
  roomId: string;
  deviceId?: string;
  deviceName?: string;
  hostId?: string;
  targetId?: string;
  devices?: MediaSessionDevice[];
  command?: MediaSessionCommand;
  timestamp?: number;
  vodId?: string;
  resume?: boolean;
  code?: string;
}
interface InvitationRoute {
  sessionId?: string;
  timestamp?: number;
  syncMode?: string;
  serverUrl?: string;
}
interface SocketCloseInfo { code: number; reason: string; }
interface ControllerListeners {
  sessionEvent: (event: string, args: Record<string, Object>) => void;
  sessionDestroy: () => void;
  playbackStateChange: (state: AVPlaybackState) => void;
}
export class MediaSessionView {
  active: boolean = false;
  isHost: boolean = false;
  sessionId: string = '';
  localId: string = '';
  hostId: string = '';
  // Android/iOS 没有系统 AVSession，默认直接进入可用的服务器信令模式。
  mode: string = PlatformInfo.isHarmonyOS() ? 'lan' : 'server';
  serverUrl: string = '';
  status: string = '未连接';
  fatalMessage: string = '';
  devices: MediaSessionDevice[] = [];
  castDevices: MediaSessionDevice[] = [];
}
type SessionListener = (view: MediaSessionView) => void;

export class MediaSessionService {
  private context?: common.UIAbilityContext;
  private owner?: AVSession;
  private controller?: AVSessionController;
  private controllerSessionId: string = '';
  private controllerListeners?: ControllerListeners;
  private castController?: AVCastController;
  private castSessionId: string = '';
  private castStateListener?: (state: AVPlaybackState) => void;
  private castAttachVersion: number = 0;
  private receiverFailurePending: boolean = false;
  private socket?: webSocket.WebSocket;
  private socketGeneration: number = 0;
  private socketReady: boolean = false;
  private socketRequest: string = 'join';
  private roomConfirmed: boolean = false;
  private reconnectTimer: number = -1;
  private reconnectCount: number = 0;
  private maxReconnects: number = 6;
  private view: MediaSessionView = new MediaSessionView();
  private listeners: SessionListener[] = [];
  private revision: number = 0;
  private pulseTimer: number = -1;
  private joinTimer: number = -1;
  private localName: string = '鸿蒙设备';
  private lastCommandAt: number = 0;
  private lastCommandSequence: number = -1;
  private outboundSequence: number = 0;
  private lastCommandDevice: string = '';
  private lastReceivedAt: number = 0;
  private latestHostCommand?: MediaSessionCommand;
  private consuming: boolean = false;
  private queuedCommand?: MediaSessionCommand;
  private publishingRevision: number = -1;
  private pulsingRevision: number = -1;
  private castSeekToleranceMs: number = 800;
  private invitationConsumed: string = '';
  private snapshotReader: () => MediaSessionCommand = (): MediaSessionCommand => {
    return { action: 'state', deviceId: '', currentMs: 0, timestamp: Date.now(), episodeIndex: 0, speedIndex: 1, playing: false };
  };
  private commandConsumer: (command: MediaSessionCommand) => Promise<void> = async (): Promise<void> => {};
  private notice: (message: string) => void = (): void => {};
  private sourceId: string = '';
  private sourceTitle: string = '';
  private sourceJson: string = '';
  private stateCallback = (event: string, args: Record<string, Object>): void => {
    try {
      if (event !== 'wuyin.session' || !this.controller || this.controllerSessionId !== this.view.sessionId) { return; }
      const raw: string = String(args['payload'] || '');
      if (raw.length > 65536) { throw new Error('会话事件过长'); }
      this.receive(JSON.parse(raw) as SessionEnvelope);
    } catch (error) { this.failReceiver('接收会话事件失败', error); }
  };
  private commandCallback = (command: string, args: Record<string, Object>): void => {
    try {
      if (command !== 'wuyin.session' || !this.owner) { return; }
      const raw: string = String(args['payload'] || '');
      if (raw.length > 65536) { throw new Error('会话指令过长'); }
      void this.relay(JSON.parse(raw) as SessionEnvelope);
    } catch (error) { this.failReceiver('接收媒体会话指令失败', error); }
  };
  private destroyedCallback = (): void => {
    try {
      if (!this.controller || this.controllerSessionId !== this.view.sessionId) { return; }
      Logger.info('MEDIA_SESSION', '收到会话销毁事件，会话=' + this.view.sessionId);
      void this.release(); this.notify('协同播放会话已结束');
    } catch (error) { this.failReceiver('处理会话断开失败', error); }
  };
  private outputCallback = (_state: ConnectionState, info: OutputDeviceInfo): void => {
    try {
      if (!this.owner || this.view.mode !== 'lan') { return; }
      this.view.castDevices = info.devices.map((device: DeviceInfo): MediaSessionDevice => {
        return { deviceId: device.deviceId, deviceName: device.deviceName || '投送设备', lastSeen: Date.now() };
      });
      this.emit(); void this.attachCast();
    } catch (error) { this.failReceiver('刷新系统投送设备失败', error); }
  };
  private controllerPlaybackCallback = (state: AVPlaybackState): void => {
    try {
      if (!this.controller) { return; }
      this.receivePlaybackState(state, this.controllerSessionId);
    } catch (error) { this.failReceiver('处理系统会话时间同步回调失败', error); }
  };
  private castPlaybackCallback = (state: AVPlaybackState): void => {
    try {
      // AVCastController 由真实 AVSession 提供；不能用邀请 ID 伪造投送控制器。
      if (!this.castController) { return; }
      this.receivePlaybackState(state, this.castSessionId);
    } catch (error) { this.failReceiver('处理 AVCast 时间同步回调失败', error); }
  };
  private receivePlaybackState(state: AVPlaybackState, sessionId: string): void {
    try {
      if (!sessionId || sessionId !== this.view.sessionId || this.view.mode !== 'lan' || !this.view.active || this.view.isHost) { return; }
      if (!state || !state.position || !Number.isSafeInteger(state.position.elapsedTime) || state.position.elapsedTime < 0) { return; }
      if (state.state !== PlaybackState.PLAYBACK_STATE_PLAY &&
        state.state !== PlaybackState.PLAYBACK_STATE_PAUSE) { return; }
      const previous: MediaSessionCommand | undefined = this.latestHostCommand;
      if (!previous || previous.deviceId !== this.view.hostId || !this.validCommand(previous)) { return; }
      // 系统播放状态不含集号，必须与已收到的主控快照属于同一次发布。
      // setAVPlaybackState 可能先于切集消息到达：不能把新集时间套用到旧集，
      // 更不能用本机 Date.now()+1 推进协议时间水位，吞掉随后到达的真实切集指令。
      if (state.position.updateTime !== previous.timestamp) {
        Logger.debug('MEDIA_SESSION', '忽略尚未匹配主控集号的系统时间状态，会话=' + sessionId);
        return;
      }
      const speeds: number[] = [0.75, 1, 1.25, 1.75, 2];
      const playbackSpeed: number | undefined = state.speed;
      const speed: number = typeof playbackSpeed === 'number' && Number.isFinite(playbackSpeed) ? speeds.indexOf(playbackSpeed) : -1;
      const command: MediaSessionCommand = {
        action: 'state', deviceId: this.view.hostId, currentMs: state.position.elapsedTime,
          timestamp: previous.timestamp, episodeIndex: previous.episodeIndex,
          speedIndex: speed >= 0 ? speed : previous.speedIndex,
          playing: state.state === PlaybackState.PLAYBACK_STATE_PLAY
      };
      // 只补充同一主控快照的时间校准，不改写协议去重水位及最新集号。
      if (this.queuedCommand && this.queuedCommand.timestamp > command.timestamp) { return; }
      this.queuedCommand = command;
      if (!this.consuming) { void this.consumeCommands(); }
    } catch (error) { this.failReceiver('解析系统播放状态失败', error); }
  }

  configure(context: common.UIAbilityContext, reader: () => MediaSessionCommand,
    consumer: (command: MediaSessionCommand) => Promise<void>, notice: (message: string) => void): void {
    try { this.context = context; this.snapshotReader = reader; this.commandConsumer = consumer; this.notice = notice; }
    catch (error) { this.failReceiver('配置同播服务失败', error); }
  }
  setSource(vodId: string, title: string, videoJson: string): void {
    try { this.sourceId = vodId; this.sourceTitle = title; this.sourceJson = videoJson; }
    catch (error) { this.failReceiver('更新同播影视资料失败', error); }
  }
  snapshot(): MediaSessionView {
    const copy: MediaSessionView = new MediaSessionView();
    copy.active = this.view.active; copy.isHost = this.view.isHost; copy.sessionId = this.view.sessionId;
    copy.localId = this.view.localId; copy.hostId = this.view.hostId; copy.mode = this.view.mode;
    copy.serverUrl = this.view.serverUrl; copy.status = this.view.status; copy.fatalMessage = this.view.fatalMessage;
    copy.devices = this.copyDevices(this.view.devices); copy.castDevices = this.copyDevices(this.view.castDevices);
    return copy;
  }
  private copyDevices(items: MediaSessionDevice[]): MediaSessionDevice[] {
    return items.map((item: MediaSessionDevice): MediaSessionDevice => {
      return { deviceId: item.deviceId, deviceName: item.deviceName, lastSeen: item.lastSeen };
    });
  }
  subscribe(listener: SessionListener): void {
    try { if (!this.listeners.includes(listener)) { this.listeners.push(listener); } listener(this.snapshot()); }
    catch (error) { this.failReceiver('订阅同播状态失败', error); }
  }
  unsubscribe(listener: SessionListener): void {
    try { this.listeners = this.listeners.filter((item: SessionListener): boolean => item !== listener); }
    catch (error) { this.failure('释放同播界面监听失败', error); }
  }
  private emit(): void {
    this.view.isHost = this.view.active && this.view.localId === this.view.hostId;
    this.listeners.slice().forEach((listener: SessionListener): void => {
      try { listener(this.snapshot()); } catch (error) { this.failReceiver('刷新同播界面失败', error); }
    });
  }
  private notify(message: string): void {
    try { this.notice(message); } catch (error) { this.failure('显示会话提示失败', error); }
  }
  private failure(message: string, error: Object): void {
    // 不输出地址、影视链接或外部载荷；异常本身为空也不能导致日志处理二次抛错。
    const problem: BusinessError | undefined = error as BusinessError | undefined;
    Logger.error('MEDIA_SESSION', message + (problem && typeof problem.code === 'number' ? '，错误码=' + problem.code : ''));
  }
  private failReceiver(message: string, error: Object): void {
    this.failure(message, error);
    if (this.view.mode !== 'lan' || this.view.isHost || this.receiverFailurePending ||
      (!this.controller && !this.view.sessionId)) { return; }
    this.receiverFailurePending = true;
    // release 在第一个 await 前清空会话并通知页面解锁，避免失败回调留下从机锁。
    void this.release().finally((): void => { this.receiverFailurePending = false; });
    this.notify('协同同播入会失败');
  }
  private validRoom(value: string): boolean { return /^[A-Za-z0-9_-]{1,256}$/.test(value); }
  private checkedServer(value: string): string {
    const target: string = value.trim();
    if (target.length > 2048 || !/^wss?:\/\/(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(:\d{1,5})?(\/[^\s?#@]*)?$/i.test(target)) {
      throw new Error('请输入不含凭据或查询参数的 ws/wss 服务器地址');
    }
    const match: RegExpExecArray | null = /\]:(\d+)(?:\/|$)|[^\]]:(\d+)(?:\/|$)/.exec(target.substring(target.indexOf('://') + 3));
    if (match) {
      const port: number = Number(match[1] || match[2]);
      if (!Number.isInteger(port) || port < 1 || port > 65535) { throw new Error('信令服务器端口无效'); }
    }
    return target;
  }
  async setMode(mode: string): Promise<void> {
    try {
      if ((mode !== 'lan' && mode !== 'server') || mode === this.view.mode) { return; }
      if (mode === 'lan' && !PlatformInfo.isHarmonyOS()) { this.notify('当前平台不支持系统协同会话，请使用服务器模式'); return; }
      await this.release(); this.view.mode = mode; this.view.fatalMessage = ''; this.emit();
      Logger.info('MEDIA_SESSION', '已切换同步模式并销毁上一会话资源');
    } catch (error) { this.failure('切换同步模式失败', error); this.notify('切换模式失败，请重试'); }
  }
  setServer(value: string): void {
    try {
      if (this.view.active || this.socket || this.reconnectTimer !== -1) { this.notify('请退出会话后修改服务器'); return; }
      this.view.serverUrl = value.trim().slice(0, 2048); this.emit();
    } catch (error) { this.failure('更新信令地址失败', error); }
  }
  private async identity(): Promise<string> {
    try {
      if (!this.context) { throw new Error('播放器上下文尚未就绪'); }
      const store = await preferences.getPreferences(this.context, 'media_session_identity');
      let value: string = String(await store.get('installation_id', ''));
      if (!/^[A-Za-z0-9-]{12,96}$/.test(value)) {
        value = 'wuyin-' + util.generateRandomUUID(true);
        await store.put('installation_id', value); await store.flush();
      }
      this.view.localId = value;
      this.localName = (deviceInfo.marketName || deviceInfo.productModel || '鸿蒙设备').slice(0, 64) + '-' + value.slice(-6);
      return value;
    } catch (error) { this.failure('生成本地设备标识失败', error); throw new Error('无法读取本地设备标识'); }
  }
  async create(): Promise<void> {
    const revision: number = ++this.revision;
    try {
      this.notifyDeparture(); await this.releaseResources();
      if (revision !== this.revision) { return; }
      if (this.view.mode === 'lan' && !PlatformInfo.isHarmonyOS()) {
        this.notify('当前平台不支持系统协同会话，请使用服务器模式'); return;
      }
      if (!this.context || !this.sourceId) { throw new Error('当前影片尚未就绪'); }
      const deviceId: string = await this.identity();
      if (revision !== this.revision) { return; }
      if (this.view.mode === 'server') {
        this.view.serverUrl = this.checkedServer(this.view.serverUrl);
        this.view.sessionId = 'WY-' + util.generateRandomUUID(true).replace(/-/g, '').slice(0, 12).toUpperCase();
        this.socketRequest = 'create'; await this.connectSocket(revision, 'create', false); return;
      }
      const created: AVSession = await createAVSession(this.context, '无音影视协同同播', 'video');
      if (revision !== this.revision) { await created.destroy(); return; }
      this.owner = created;
      created.on('commonCommand', this.commandCallback); created.on('outputDeviceChange', this.outputCallback);
      await created.setAVMetadata({ assetId: this.sourceId, title: this.sourceTitle || '无音影视' });
      if (revision !== this.revision || this.owner !== created) { return; }
      await created.activate();
      if (revision !== this.revision || this.owner !== created) { return; }
      // 系统会话必须使用真实 sessionId，不以随机房间号冒充软总线发现结果。
      this.view.sessionId = created.sessionId; this.view.hostId = deviceId; this.view.active = true;
      this.view.status = '已连接'; this.view.devices = [{ deviceId: deviceId, deviceName: this.localName, lastSeen: Date.now() }];
      this.lastReceivedAt = Date.now(); this.emit(); this.startPulse(); await this.publish();
      if (revision === this.revision && this.view.active) { this.notify('同播会话创建成功'); }
    } catch (error) {
      this.failure('创建会话失败', error);
      if (revision === this.revision) { await this.release(); this.notify('创建同播会话失败，请检查模式、地址及系统媒体服务'); }
    }
  }
  private async readInvitationMode(sessionId: string): Promise<void> {
    try {
      const params: InvitationRoute | undefined = router.getParams() as InvitationRoute | undefined;
      if (!params || params.sessionId !== sessionId || params.syncMode === undefined) { return; }
      const key: string = sessionId + ':' + String(params.timestamp || 0);
      if (this.invitationConsumed === key) { return; }
      if (params.syncMode !== 'lan' && params.syncMode !== 'server') { throw new Error('邀请同步模式无效'); }
      const address: string = params.syncMode === 'server' ? this.checkedServer(params.serverUrl || '') : '';
      await this.setMode(params.syncMode);
      if (address) { this.view.serverUrl = address; }
      this.invitationConsumed = key;
    } catch (error) { this.failure('读取分享同步模式失败', error); throw new Error('同播邀请的模式或服务器地址无效'); }
  }
  async join(sessionId: string): Promise<void> {
    try { await this.readInvitationMode(sessionId.trim()); }
    catch (error) {
      this.failure('解析入会模式失败', error); await this.release(); this.notify('协同同播入会失败'); return;
    }
    const revision: number = ++this.revision;
    try {
      if (this.view.mode === 'lan' && !PlatformInfo.isHarmonyOS()) {
        this.notify('当前平台不支持系统协同会话，请使用服务器模式'); return;
      }
      if (!this.validRoom(sessionId.trim())) { throw new Error('会话 ID 无效'); }
      this.notifyDeparture(); await this.releaseResources();
      if (revision !== this.revision) { return; }
      this.view.sessionId = sessionId.trim();
      this.view.status = '正在加入会话';
      // 在身份读取和 createController 之前开始计时，系统调用迟迟不返回也必须解锁从机。
      this.armJoinTimeout(revision); this.emit();
      await this.identity();
      if (revision !== this.revision) { return; }
      if (this.view.mode === 'server') {
        this.view.serverUrl = this.checkedServer(this.view.serverUrl);
        this.socketRequest = 'join'; await this.connectSocket(revision, 'join', false); return;
      }
      Logger.info('MEDIA_SESSION', '创建邀请对应的系统会话控制器，会话=' + this.view.sessionId);
      const linked: AVSessionController = await createController(sessionId.trim());
      if (revision !== this.revision) { await linked.destroy(); return; }
      this.controller = linked; this.controllerSessionId = sessionId.trim(); this.view.status = '等待主控确认';
      // 每次入会绑定实际控制器及版本。旧会话已经排队的销毁/播放事件不能结束新会话。
      const callbacks: ControllerListeners = {
        sessionEvent: (event: string, args: Record<string, Object>): void => {
          try {
            if (revision !== this.revision || this.controller !== linked) { return; }
            this.stateCallback(event, args);
          } catch (error) { this.failReceiver('处理绑定会话事件失败', error); }
        },
          sessionDestroy: (): void => {
          try {
            if (revision !== this.revision || this.controller !== linked) { return; }
            this.destroyedCallback();
          } catch (error) { this.failReceiver('处理绑定会话销毁失败', error); }
        },
          playbackStateChange: (state: AVPlaybackState): void => {
          try {
            if (revision !== this.revision || this.controller !== linked) { return; }
            this.controllerPlaybackCallback(state);
          } catch (error) { this.failReceiver('处理绑定会话时间同步失败', error); }
        }
      };
      this.controllerListeners = callbacks;
      linked.on('sessionEvent', callbacks.sessionEvent); linked.on('sessionDestroy', callbacks.sessionDestroy);
      // 接收端持有 AVSessionController，而非主控的 AVSession，不能调用不存在的远端 AVCast 工厂。
      // AVCast 的真实监听仍由 attachCast 管理；普通会话接收端补齐同会话播放状态监听。
      linked.on('playbackStateChange', 'all', callbacks.playbackStateChange);
      this.emit();
      Logger.info('MEDIA_SESSION', '已注册会话时间同步、切集及销毁监听，会话=' + this.view.sessionId);
      this.lastReceivedAt = Date.now();
      await linked.sendCommonCommand('wuyin.session', sessionArgs('payload', JSON.stringify(this.envelope('join'))));
      if (revision === this.revision) { this.startPulse(); }
    } catch (error) {
      this.failure('加入会话失败', error);
      if (revision === this.revision) { await this.release(); this.notify('协同同播入会失败'); }
    }
  }
  private armJoinTimeout(revision: number): void {
    if (this.joinTimer !== -1) { clearTimeout(this.joinTimer); }
    this.joinTimer = setTimeout((): void => {
      try {
        this.joinTimer = -1;
        if (revision !== this.revision || this.view.active) { return; }
        if (this.view.mode === 'server') { void this.socketLost(revision); }
        else {
          Logger.warn('MEDIA_SESSION', '系统会话入会超时，会话=' + this.view.sessionId);
          void this.release(); this.notify('协同同播入会失败');
        }
      } catch (error) { this.failReceiver('处理加入会话超时失败', error); }
    }, 12000);
  }
  private envelope(action: string, targetId: string = ''): SessionEnvelope {
    return { action: action, sessionId: this.view.sessionId, deviceId: this.view.localId, deviceName: this.localName,
        targetId: targetId, hostId: this.view.hostId, devices: [] };
  }
  private validCommand(command: MediaSessionCommand): boolean {
    return command !== undefined && command !== null && command.action === 'state' && command.deviceId === this.view.hostId &&
      Number.isSafeInteger(command.timestamp) && command.timestamp >= Date.now() - 30000 && command.timestamp <= Date.now() + 60000 &&
      Number.isSafeInteger(command.currentMs) && command.currentMs >= 0 && Number.isInteger(command.episodeIndex) && command.episodeIndex >= 0 &&
      Number.isInteger(command.speedIndex) && command.speedIndex >= 0 && command.speedIndex <= 4 && typeof command.playing === 'boolean' &&
      (command.sequence === undefined || (Number.isSafeInteger(command.sequence) && command.sequence >= 0)) &&
      (command.protocolVersion === undefined || command.protocolVersion === 1) &&
      (command.routeIndex === undefined || (Number.isInteger(command.routeIndex) && command.routeIndex >= 0)) &&
      (command.ratio === undefined || ['原画', '铺满屏幕'].includes(command.ratio));
  }
  private validDevices(devices: MediaSessionDevice[], hostId: string): boolean {
    if (!Array.isArray(devices) || devices.length === 0 || devices.length > 32 || typeof hostId !== 'string') { return false; }
    const ids: string[] = [];
    for (let index: number = 0; index < devices.length; index++) {
      const item: MediaSessionDevice = devices[index];
      if (!item || typeof item.deviceId !== 'string' || !/^[A-Za-z0-9-]{12,96}$/.test(item.deviceId) ||
        typeof item.deviceName !== 'string' || item.deviceName.length === 0 || item.deviceName.length > 80 ||
        !Number.isFinite(item.lastSeen) || item.lastSeen < 0 || ids.includes(item.deviceId)) { return false; }
      ids.push(item.deviceId);
    }
    return ids.includes(hostId);
  }
  private async relay(envelope: SessionEnvelope): Promise<void> {
    const revision: number = this.revision;
    try {
      const owner: AVSession | undefined = this.owner;
      if (!owner || !this.view.active || !envelope || envelope.sessionId !== this.view.sessionId ||
        typeof envelope.deviceId !== 'string' || !/^[A-Za-z0-9-]{12,96}$/.test(envelope.deviceId)) { return; }
      const action: string = envelope.action;
      if (!['join', 'pulse', 'leave', 'transfer', 'kick', 'control'].includes(action)) { return; }
      const member: MediaSessionDevice | undefined = this.view.devices.find((item: MediaSessionDevice): boolean => item.deviceId === envelope.deviceId);
      if (action === 'join') {
        if (!member && this.view.devices.length < 32) {
          this.view.devices = this.view.devices.concat([{ deviceId: envelope.deviceId,
              deviceName: String(envelope.deviceName || '鸿蒙设备').slice(0, 80), lastSeen: Date.now() }]);
        }
      } else if (!member) { return; }
      if (member) { member.lastSeen = Date.now(); }
      if (envelope.command && (envelope.deviceId !== this.view.hostId || !this.validCommand(envelope.command))) { return; }
      if (action === 'control' && !envelope.command) { return; }
      if (envelope.command) { this.latestHostCommand = envelope.command; }
      if (action === 'leave') {
        if (envelope.deviceId === this.view.hostId) { await this.release(); this.notify('协同播放会话已结束'); return; }
        this.view.devices = this.view.devices.filter((item: MediaSessionDevice): boolean => item.deviceId !== envelope.deviceId);
      } else if (action === 'transfer' || action === 'kick') {
        if (envelope.deviceId !== this.view.hostId || !this.view.devices.some((item: MediaSessionDevice): boolean => item.deviceId === envelope.targetId)) { return; }
        if (action === 'transfer') { this.view.hostId = envelope.targetId; this.latestHostCommand = undefined; this.notify('已移交主控'); }
        else if (envelope.targetId !== this.view.hostId) {
          this.view.devices = this.view.devices.filter((item: MediaSessionDevice): boolean => item.deviceId !== envelope.targetId); this.notify('已踢出成员');
        }
      }
      const message: SessionEnvelope = { action: 'members', sessionId: this.view.sessionId, deviceId: this.view.localId,
          deviceName: this.localName, targetId: envelope.targetId, hostId: this.view.hostId,
          devices: this.copyDevices(this.view.devices), command: envelope.command };
      if (action === 'join' || action === 'pulse') {
        if (this.view.localId === this.view.hostId) {
          message.command = this.snapshotReader(); message.command.deviceId = this.view.hostId;
          message.command.timestamp = Date.now(); this.latestHostCommand = message.command;
        } else { message.command = this.latestHostCommand; }
      }
      this.emit();
      if (revision !== this.revision || this.owner !== owner) { return; }
      await owner.dispatchSessionEvent('wuyin.session', sessionArgs('payload', JSON.stringify(message)));
      if (this.owner === owner && revision === this.revision && message.command && !this.view.isHost) { this.applyCommand(message.command); }
    } catch (error) { this.failReceiver('转发同播指令失败', error); }
  }
  private receive(envelope: SessionEnvelope): void {
    try {
      if (!this.controller || !envelope || envelope.sessionId !== this.view.sessionId) { return; }
      if (envelope.action === 'destroy' || envelope.action === 'disconnect') {
        if (envelope.deviceId !== this.view.hostId || !this.view.active) { return; }
        void this.release(); this.notify('协同播放会话已结束'); return;
      }
      if (envelope.action !== 'members' || !this.validDevices(envelope.devices, envelope.hostId)) { return; }
      if (this.acceptMembers(envelope.devices, envelope.hostId) && envelope.command && !this.view.isHost) { this.applyCommand(envelope.command); }
    } catch (error) { this.failReceiver('处理同播状态失败', error); }
  }
  private acceptMembers(devices: MediaSessionDevice[], hostId: string, created: boolean = false): boolean {
    const wasActive: boolean = this.view.active;
    const previousHost: string = this.view.hostId;
    const previousDevices: MediaSessionDevice[] = this.view.devices;
    if (!devices.some((item: MediaSessionDevice): boolean => item.deviceId === this.view.localId)) {
      void this.release(); this.notify('协同播放会话已结束'); return false;
    }
    this.lastReceivedAt = Date.now();
    if (this.joinTimer !== -1) { clearTimeout(this.joinTimer); this.joinTimer = -1; }
    this.view.hostId = hostId; this.view.devices = this.copyDevices(devices); this.view.active = true; this.view.status = '已连接';
    this.view.fatalMessage = ''; this.reconnectCount = 0;
    if (previousHost !== hostId) {
      this.lastCommandDevice = ''; this.lastCommandAt = 0; this.lastCommandSequence = -1;
      this.latestHostCommand = undefined; this.queuedCommand = undefined;
    }
    this.emit();
    Logger.info('MEDIA_SESSION', '会话成员确认，会话=' + this.view.sessionId + '，从机=' + !this.view.isHost);
    if (!wasActive) {
      if (!created) { Logger.info('MEDIA_SESSION', '【CoPlay][JoinSuccess] 【已加入协同播放会话】，sessionId=' + this.view.sessionId); }
      this.notify(created ? '同播会话创建成功' : '已加入协同播放会话');
    }
    else if (previousHost !== hostId) { this.notify(this.view.isHost ? '已成为主控设备' : '主控已移交'); }
    else if (this.view.mode === 'server' && this.view.isHost && previousDevices.some((old: MediaSessionDevice): boolean =>
      !devices.some((item: MediaSessionDevice): boolean => item.deviceId === old.deviceId))) { this.notify('成员已退出或被踢出'); }
    if (this.view.isHost && previousHost !== hostId) { void this.publish(); }
    return true;
  }
  private applyCommand(command: MediaSessionCommand): void {
    try {
      if (!this.view.active || this.view.isHost || !this.validCommand(command)) { return; }
      if (this.lastCommandDevice === command.deviceId) {
        if (command.sequence !== undefined && this.lastCommandSequence >= 0) {
          if (command.sequence <= this.lastCommandSequence) { return; }
        } else if (command.timestamp <= this.lastCommandAt) { return; }
      }
      this.latestHostCommand = command;
      this.lastCommandDevice = command.deviceId;
      this.lastCommandAt = command.timestamp;
      if (command.sequence !== undefined) { this.lastCommandSequence = command.sequence; }
      this.queuedCommand = command;
      if (!this.consuming) { void this.consumeCommands(); }
    } catch (error) { this.failReceiver('校验同播指令失败', error); }
  }
  private async consumeCommands(): Promise<void> {
    const revision: number = this.revision; this.consuming = true;
    try {
      while (this.queuedCommand && revision === this.revision && this.view.active && !this.view.isHost) {
        const command: MediaSessionCommand = this.queuedCommand; this.queuedCommand = undefined;
        if (this.validCommand(command)) { await this.commandConsumer(command); }
      }
    } catch (error) {
      if (revision === this.revision) { this.failReceiver('执行同播指令失败', error); }
    }
    finally {
      this.consuming = false;
      if (this.queuedCommand && this.view.active && !this.view.isHost) { void this.consumeCommands(); }
    }
  }
  async publish(): Promise<void> {
    const revision: number = this.revision;
    try {
      if (!this.view.active || !this.view.isHost || this.publishingRevision === revision) { return; }
      this.publishingRevision = revision;
      const command: MediaSessionCommand = this.snapshotReader();
      command.deviceId = this.view.localId;
      command.timestamp = Date.now();
      command.protocolVersion = 1;
      command.sequence = ++this.outboundSequence;
      if (!this.validCommand(command)) { throw new Error('本地播放状态无效'); }
      if (this.view.mode === 'server') {
        try { await this.sendPacket({ version: 1, type: 'control', roomId: this.view.sessionId, deviceId: this.view.localId, command: command }); }
        catch (error) { this.failure('发送播放信令失败', error); if (revision === this.revision) { await this.socketLost(revision); } }
        return;
      }
      const envelope: SessionEnvelope = this.envelope('control'); envelope.command = command;
      const owner: AVSession | undefined = this.owner;
      const controller: AVSessionController | undefined = this.controller;
      if (owner) {
        await owner.setAVPlaybackState({ state: command.playing ? PlaybackState.PLAYBACK_STATE_PLAY : PlaybackState.PLAYBACK_STATE_PAUSE,
            speed: [0.75, 1, 1.25, 1.75, 2][command.speedIndex], position: { elapsedTime: command.currentMs, updateTime: command.timestamp } });
        if (revision !== this.revision || this.owner !== owner || !this.view.isHost) { return; }
        await this.relay(envelope);
      } else if (controller) { await controller.sendCommonCommand('wuyin.session', sessionArgs('payload', JSON.stringify(envelope))); }
      if (revision === this.revision && this.view.active && this.view.isHost) { await this.publishCast(command, revision); }
    } catch (error) { this.failure('发布同播播放状态失败', error); }
    finally { if (this.publishingRevision === revision) { this.publishingRevision = -1; } }
  }
  private async publishCast(command: MediaSessionCommand, revision: number): Promise<void> {
    try {
      const cast: AVCastController | undefined = this.castController;
      if (!cast || !this.view.isHost || this.castSessionId !== this.view.sessionId) { return; }
      const state: AVPlaybackState = await cast.getAVPlaybackState();
      if (revision !== this.revision || this.castController !== cast || !this.view.isHost) { return; }
      const expectedState: PlaybackState = command.playing ? PlaybackState.PLAYBACK_STATE_PLAY : PlaybackState.PLAYBACK_STATE_PAUSE;
      if (state.state !== expectedState) { await cast.sendCommonCommand(command.playing ? 'play' : 'pause', {}); }
      if (revision !== this.revision || this.castController !== cast || !this.view.isHost) { return; }
      const targetSpeed: number = [0.75, 1, 1.25, 1.75, 2][command.speedIndex];
      if (state.speed !== targetSpeed) { await cast.sendCommonCommand('setSpeed', sessionArgs('parameter', targetSpeed)); }
      if (revision !== this.revision || this.castController !== cast || !this.view.isHost) { return; }
      const target: number = Math.max(0, Math.floor(command.currentMs + (command.playing ? Math.max(0, Date.now() - command.timestamp) * targetSpeed : 0)));
      let actual: number = -1;
      if (state.position && Number.isFinite(state.position.elapsedTime)) {
        actual = state.position.elapsedTime;
        if (state.state === PlaybackState.PLAYBACK_STATE_PLAY && Number.isFinite(state.position.updateTime) && Math.abs(Date.now() - state.position.updateTime) <= 30000) {
          actual += Math.max(0, Date.now() - state.position.updateTime) * (state.speed || 1);
        }
      }
      if (actual < 0 || Math.abs(actual - target) >= this.castSeekToleranceMs) { await cast.sendCommonCommand('seek', sessionArgs('parameter', target)); }
    } catch (error) { this.failReceiver('同步系统投送状态失败', error); }
  }
  private detachCast(): void {
    ++this.castAttachVersion;
    const cast: AVCastController | undefined = this.castController;
    const listener: ((state: AVPlaybackState) => void) | undefined = this.castStateListener;
    this.castController = undefined; this.castSessionId = ''; this.castStateListener = undefined;
    if (!cast || !listener) { return; }
    try { cast.off('playbackStateChange', listener); }
    catch (error) { this.failure('注销 AVCast 播放状态监听失败', error); }
  }
  private async attachCast(): Promise<void> {
    const revision: number = this.revision;
    const attachVersion: number = ++this.castAttachVersion;
    try {
      if (!this.owner || this.view.castDevices.length === 0) { this.detachCast(); return; }
      const owner: AVSession = this.owner;
      const cast: AVCastController = await owner.getAVCastController();
      if (revision !== this.revision || attachVersion !== this.castAttachVersion || this.owner !== owner ||
        !this.view.active || this.view.castDevices.length === 0) { return; }
      if (this.castController === cast) { return; }
      this.detachCast(); this.castController = cast; this.castSessionId = this.view.sessionId;
      const listener: (state: AVPlaybackState) => void = (state: AVPlaybackState): void => {
        try {
          if (revision !== this.revision || this.owner !== owner || this.castController !== cast) { return; }
          this.castPlaybackCallback(state);
        } catch (error) { this.failReceiver('处理绑定 AVCast 状态失败', error); }
      };
      this.castStateListener = listener;
      cast.on('playbackStateChange', 'all', listener);
      Logger.info('MEDIA_SESSION', '已注册 AVCast 播放状态监听，会话=' + this.castSessionId);
    } catch (error) {
      if (revision === this.revision && this.owner && this.view.castDevices.length > 0) {
        this.failReceiver('连接系统 AVCastController 失败', error);
      }
    }
  }
  private async connectSocket(revision: number, request: string, resume: boolean): Promise<void> {
    let connecting: webSocket.WebSocket | undefined;
    try {
      if (revision !== this.revision || this.view.mode !== 'server') { return; }
      const address: string = this.checkedServer(this.view.serverUrl);
      const socket: webSocket.WebSocket = webSocket.createWebSocket(); connecting = socket;
      const generation: number = ++this.socketGeneration;
      this.socket = socket; this.socketReady = false; this.view.status = resume ? '正在重新连接' : '正在连接服务器'; this.emit();
      socket.on('open', (problem: BusinessError, _headers: Object): void => {
        try {
          if (this.socket !== socket || generation !== this.socketGeneration || revision !== this.revision) { return; }
          if (problem && problem.code) { this.failure('信令连接被拒绝', problem); void this.socketLost(revision); return; }
          this.socketReady = true; this.lastReceivedAt = Date.now();
          this.armJoinTimeout(revision); this.startPulse(); void this.sendHandshake(revision, request, resume, socket);
        } catch (error) { this.failure('处理信令连接成功事件失败', error); if (this.socket === socket) { void this.socketLost(revision); } }
      });
      socket.on('message', (problem: BusinessError, data: string | ArrayBuffer): void => {
        try {
          if (this.socket !== socket || generation !== this.socketGeneration || revision !== this.revision) { return; }
          if (problem && problem.code) { this.failure('读取信令消息失败', problem); return; }
          if (typeof data !== 'string' || data.length > 65536) { throw new Error('只接受受限长度的 JSON 文本信令'); }
          this.receivePacket(JSON.parse(data) as ServerPacket, revision);
        } catch (error) { this.failure('解析信令失败', error); }
      });
      socket.on('close', (_error: BusinessError, _info: SocketCloseInfo): void => {
        try { if (this.socket === socket && generation === this.socketGeneration) { void this.socketLost(revision); } }
        catch (error) { this.failure('处理信令关闭事件失败', error); }
      });
      socket.on('error', (problem: BusinessError): void => {
        try {
          if (this.socket === socket && generation === this.socketGeneration) { this.failure('信令连接异常', problem); void this.socketLost(revision); }
        } catch (error) { this.failure('处理信令错误事件失败', error); }
      });
      this.armJoinTimeout(revision);
      const connected: boolean = await socket.connect(address);
      if (!connected && this.socket === socket && revision === this.revision) { await this.socketLost(revision); }
    } catch (error) {
      this.failure('连接信令服务器失败', error);
      // 旧连接 connect() 迟到的拒绝不得关闭已经重连成功的新连接。
      if (revision === this.revision && connecting && this.socket === connecting) { await this.socketLost(revision); }
    }
  }
  private async sendHandshake(revision: number, request: string, resume: boolean, socket: webSocket.WebSocket): Promise<void> {
    try {
      if (revision !== this.revision || this.socket !== socket) { return; }
      await this.sendPacket({ version: 1, type: request, roomId: this.view.sessionId, deviceId: this.view.localId,
          deviceName: this.localName, vodId: this.sourceId, resume: resume, timestamp: Date.now() });
    } catch (error) {
      this.failure('发送入会握手失败', error);
      if (revision === this.revision && this.socket === socket) { await this.socketLost(revision); }
    }
  }
  private async sendPacket(packet: ServerPacket): Promise<void> {
    try {
      const socket: webSocket.WebSocket | undefined = this.socket;
      if (!socket || !this.socketReady) { throw new Error('信令连接未就绪'); }
      const sent: boolean = await socket.send(JSON.stringify(packet));
      if (!sent) { throw new Error('信令发送失败'); }
    } catch (error) { this.failure('发送同播数据失败', error); throw new Error('同播信令发送失败'); }
  }
  private receivePacket(packet: ServerPacket, revision: number): void {
    try {
      if (revision !== this.revision || !packet || packet.version !== 1 || packet.roomId !== this.view.sessionId || typeof packet.type !== 'string') { return; }
      if (packet.type === 'error') {
        if (packet.code === 'ROOM_NOT_FOUND') { this.notify('房间不存在，请确认房间 ID'); }
        else if (packet.code === 'KICKED') { this.notify('已被踢出成员，连接已断开'); }
        else if (packet.code === 'ROOM_CLOSED') { this.notify('房间已关闭，连接已断开'); }
        else { this.notify('服务器拒绝同播请求，请检查房间状态'); }
        void this.release(); return;
      }
      if (packet.type === 'pong') { this.lastReceivedAt = Date.now(); return; }
      if (packet.type === 'welcome' || packet.type === 'members') {
        if (!packet.devices || !packet.hostId) { throw new Error('服务器成员快照无效'); }
        const creating: boolean = !this.roomConfirmed && this.socketRequest === 'create' && packet.hostId === this.view.localId;
        if (!this.acceptMembers(packet.devices, packet.hostId, creating)) { return; }
        this.roomConfirmed = true;
      }
      if (packet.type === 'state' || packet.type === 'welcome' || packet.type === 'members') {
        if (packet.command && this.view.active && !this.view.isHost) { this.applyCommand(packet.command); }
      }
    } catch (error) { this.failure('处理服务器同步消息失败', error); }
  }
  private async detachSocket(): Promise<void> {
    const socket: webSocket.WebSocket | undefined = this.socket;
    this.socket = undefined; this.socketReady = false; ++this.socketGeneration;
    if (!socket) { return; }
    try { socket.off('open'); } catch (error) { this.failure('注销信令连接监听失败', error); }
    try { socket.off('message'); } catch (error) { this.failure('注销信令消息监听失败', error); }
    try { socket.off('close'); } catch (error) { this.failure('注销信令关闭监听失败', error); }
    try { socket.off('error'); } catch (error) { this.failure('注销信令异常监听失败', error); }
    try { await socket.close(); } catch (error) { this.failure('关闭信令连接失败', error); }
  }
  private async socketLost(revision: number): Promise<void> {
    try {
      if (revision !== this.revision || this.view.mode !== 'server' || this.reconnectTimer !== -1 || !this.socket) { return; }
      // 先同步摘除连接，隔离重复 error/close；UI 回调也不能再次使用旧连接。
      const closing: Promise<void> = this.detachSocket();
      this.view.active = false; this.queuedCommand = undefined; this.view.devices = []; this.view.status = '连接断开'; this.emit();
      if (revision !== this.revision) { await closing; return; }
      if (this.pulseTimer !== -1) { clearInterval(this.pulseTimer); this.pulseTimer = -1; }
      if (this.joinTimer !== -1) { clearTimeout(this.joinTimer); this.joinTimer = -1; }
      if (this.reconnectCount >= this.maxReconnects) {
        this.view.fatalMessage = '同播连接重试已达上限（6 次），已停止自动重连。请检查网络及服务器后重新加入。';
        this.emit(); this.notify('连接断开，已停止自动重连'); await closing; return;
      }
      const interval: number = Math.min(30000, 1000 * Math.pow(2, this.reconnectCount));
      this.reconnectCount++; this.view.status = '等待重连 ' + this.reconnectCount + '/' + this.maxReconnects; this.emit();
      if (revision !== this.revision) { await closing; return; }
      this.reconnectTimer = setTimeout((): void => {
        try {
          this.reconnectTimer = -1;
          if (revision === this.revision) { void this.reconnectSocket(revision); }
        } catch (error) { this.failure('触发信令重连失败', error); }
      }, interval);
      this.notify('连接断开，正在尝试重连'); await closing;
    } catch (error) { this.failure('安排信令重连失败', error); }
  }
  private async reconnectSocket(revision: number): Promise<void> {
    try {
      if (revision === this.revision) { await this.connectSocket(revision, this.roomConfirmed ? 'join' : this.socketRequest, true); }
    } catch (error) { this.failure('执行信令重连失败', error); }
  }
  async invite(): Promise<void> {
    try {
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] 进入邀请设备方法，context就绪=' + Boolean(this.context) +
      '，会话活跃=' + this.view.active + '，主控=' + this.view.isHost);
      if (!this.context || !this.view.active || !this.view.isHost) {
        Logger.warn('MEDIA_SESSION', '【CoPlay][SendShare] 未满足邀请条件，未调用系统分享');
        this.notify('请先创建会话，邀请仅主控可操作'); return;
      }
      const sessionId: string = this.view.sessionId;
      if (typeof sessionId !== 'string' || !sessionId.length || sessionId === 'null' || sessionId === 'undefined') {
        throw new Error('协播会话 ID 缺失，无法构造完整邀请');
      }
      if (!this.sourceJson) { throw new Error('影视邀请资料为空'); }
      // setSource 提供的是视频 JSON 文本；还原视频对象后显式序列化，确保 videoJson 始终为字符串。
      // 不在分享边界清洗或裁剪选集，也不再用旧的 128 KiB 字符阈值拒绝完整长载荷。
      const video: Object = JSON.parse(this.sourceJson) as Object;
      if (!video || typeof video !== 'object' || Array.isArray(video)) { throw new Error('影视邀请资料无效'); }
      const videoJson: string = JSON.stringify(video);
      const command: MediaSessionCommand = this.snapshotReader();
      const payload: MediaSessionInvitation = { version: 1, vodId: this.sourceId, sessionId: sessionId,
          currentMs: Math.max(0, Math.floor(command.currentMs)), timestamp: Date.now(), episodeIndex: command.episodeIndex,
          videoJson: videoJson, syncMode: this.view.mode, serverUrl: this.view.mode === 'server' ? this.checkedServer(this.view.serverUrl) : '' };
      const raw: string = JSON.stringify(payload);
      CoPlayInviteHandoff.logText('SendShare', '完整分享载荷', raw);
      CoPlayInviteHandoff.logText('SendShare', 'sessionId 原始字符串', payload.sessionId);
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] videoJson类型=' + typeof payload.videoJson +
      '，videoJson字符数=' + videoJson.length + '，完整载荷字符数=' + raw.length + '，sessionId字符数=' + sessionId.length);
      // Want 只作为协播分享边界的显式类型载体，share_data 直接保存完整 JSON。
      // sendData 是接收端匹配动作，不能用 startAbility(sendData) 代替唤起系统分享面板。
      const parameters: Record<string, string> = { 'ohos.extra.param.key.share_data': raw };
      const shareWant: Want = { action: 'ohos.want.action.sendData', type: 'text/plain', parameters: parameters };
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] share_data类型=' + typeof parameters['ohos.extra.param.key.share_data'] +
      '，与完整载荷一致=' + (parameters['ohos.extra.param.key.share_data'] === raw) + '，即将调用协播 ShareKit 服务');
      await CoPlayShareService.show(this.context, shareWant, this.sourceTitle || '无音影视协播邀请',
        (message: string): void => { this.notify(message); });
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] 系统分享面板调用已返回；不代表邀请已送达或已入会');
    } catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('MEDIA_SESSION', '【CoPlay][SendShare] 分享启动或载荷构造失败，code=' + String(problem.code) +
      '，message=' + String(problem.message));
      this.failure('分享同播邀请失败', error); this.notify('唤起协播分享邀请失败');
    }
  }
  // 局域网邀请是独立备选入口，不替换或改写上面的华为分享链路。
  async inviteLan(deviceId: string): Promise<void> {
    try {
      Logger.info('MEDIA_SESSION', '【CoPlay][LAN-Send] 设备列表邀请点击，deviceId=' + deviceId);
      if (!this.context || !this.view.active || !this.view.isHost || this.view.mode !== 'lan') {
        this.notify('请先创建局域网会话，邀请仅主控可操作'); return;
      }
      const sessionId: string = this.view.sessionId;
      if (!sessionId.length || sessionId === 'null' || sessionId === 'undefined') {
        throw new Error('协播会话 ID 缺失');
      }
      if (!deviceId || !this.sourceId || !this.sourceJson) { throw new Error('目标设备或影视资料缺失'); }
      const video: Object = JSON.parse(this.sourceJson) as Object;
      if (!video || typeof video !== 'object' || Array.isArray(video)) { throw new Error('影视邀请资料无效'); }
      const videoJson: string = JSON.stringify(video);
      const command: MediaSessionCommand = this.snapshotReader();
      const payload: MediaSessionInvitation = {
        version: 1, vodId: this.sourceId, sessionId: sessionId,
          currentMs: Math.max(0, Math.floor(command.currentMs)), timestamp: Date.now(),
          episodeIndex: command.episodeIndex, videoJson: videoJson, syncMode: 'lan'
      };
      const raw: string = JSON.stringify(payload);
      CoPlayInviteHandoff.logText('LAN-Send', '完整局域网邀请载荷', raw);
      CoPlayInviteHandoff.logText('LAN-Send', 'sessionId 原始字符串', sessionId);
      Logger.info('MEDIA_SESSION', '【CoPlay][LAN-Send] deviceId=' + deviceId +
      '，videoJson类型=' + typeof payload.videoJson + '，videoJson字符数=' + videoJson.length +
      '，videoJson UTF-8字节数=' + new util.TextEncoder().encodeInto(videoJson).length +
      '，完整载荷字符数=' + raw.length + '，完整载荷 UTF-8字节数=' + new util.TextEncoder().encodeInto(raw).length);
      await CoPlayLanService.shared.send(deviceId, raw);
      this.notify('协播邀请已下发');
    } catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('MEDIA_SESSION', '【CoPlay][LAN-Send] 向设备下发邀请失败，code=' + String(problem.code) +
      '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
      this.notify('向设备下发协播邀请失败');
    }
  }
  async manage(action: string, targetId: string): Promise<void> {
    try {
      if ((action !== 'transfer' && action !== 'kick') || !this.view.active || !this.view.isHost || targetId === this.view.localId) { return; }
      if (!this.view.devices.some((device: MediaSessionDevice): boolean => device.deviceId === targetId)) { this.notify('设备已离线，请刷新后重试'); return; }
      if (this.view.mode === 'server') {
        await this.sendPacket({ version: 1, type: action, roomId: this.view.sessionId, deviceId: this.view.localId, targetId: targetId, timestamp: Date.now() });
        return;
      }
      const message: SessionEnvelope = this.envelope(action, targetId);
      if (this.owner) { await this.relay(message); }
      else if (this.controller) { await this.controller.sendCommonCommand('wuyin.session', sessionArgs('payload', JSON.stringify(message))); }
    } catch (error) { this.failure('管理同播设备失败', error); this.notify('设备管理失败，请重试'); }
  }
  private startPulse(): void {
    try {
      if (this.pulseTimer !== -1) { clearInterval(this.pulseTimer); }
      this.pulseTimer = setInterval((): void => { void this.pulse(); }, 3000);
    } catch (error) { this.failReceiver('注册同播保活失败', error); }
  }
  private async pulse(): Promise<void> {
    const revision: number = this.revision;
    if (this.pulsingRevision === revision) { return; }
    this.pulsingRevision = revision;
    try {
      if (this.view.mode === 'server') {
        if (this.view.active && Date.now() - this.lastReceivedAt > 8000) { await this.socketLost(revision); return; }
        await this.sendPacket({ version: 1, type: 'ping', roomId: this.view.sessionId, deviceId: this.view.localId, timestamp: Date.now() });
      } else if (this.owner) {
        this.view.devices = this.view.devices.filter((item: MediaSessionDevice): boolean => item.deviceId === this.view.localId || Date.now() - item.lastSeen < 15000);
        if (!this.view.devices.some((item: MediaSessionDevice): boolean => item.deviceId === this.view.hostId)) { await this.release(); this.notify('协同播放会话已结束'); return; }
        await this.relay(this.envelope('pulse'));
      } else if (this.controller) {
        if (this.view.active && Date.now() - this.lastReceivedAt > 8000) { await this.release(); this.notify('协同播放会话已结束'); return; }
        await this.controller.sendCommonCommand('wuyin.session', sessionArgs('payload', JSON.stringify(this.envelope(this.view.active ? 'pulse' : 'join'))));
      }
      if (revision === this.revision && this.view.isHost) { await this.publish(); }
    } catch (error) {
      this.failure('同播保活失败', error);
      if (revision === this.revision) {
        if (this.view.mode === 'server') { await this.socketLost(revision); }
        else {
          const joined: boolean = this.view.active;
          await this.release(); this.notify(joined ? '协同播放会话已结束' : '协同同播入会失败');
        }
      }
    } finally { if (this.pulsingRevision === revision) { this.pulsingRevision = -1; } }
  }
  private notifyDeparture(): void {
    try {
      const controller: AVSessionController | undefined = this.controller;
      const socket: webSocket.WebSocket | undefined = this.socket;
      if (this.view.active && socket && this.socketReady) {
        void socket.send(JSON.stringify({ version: 1, type: 'leave', roomId: this.view.sessionId, deviceId: this.view.localId } as ServerPacket))
          .catch((error: BusinessError): void => { this.failure('通知服务器退出失败', error); });
      } else if (controller && this.view.active) {
        void controller.sendCommonCommand('wuyin.session', sessionArgs('payload', JSON.stringify(this.envelope('leave'))))
          .catch((error: BusinessError): void => { this.failure('通知退出系统会话失败', error); });
      }
    } catch (error) { this.failure('发送退出通知失败', error); }
  }
  private async releaseResources(): Promise<void> {
    const controller: AVSessionController | undefined = this.controller;
    const callbacks: ControllerListeners | undefined = this.controllerListeners;
    const owner: AVSession | undefined = this.owner;
    this.detachCast(); this.controller = undefined; this.controllerSessionId = ''; this.controllerListeners = undefined; this.owner = undefined;
    const previous: MediaSessionView = this.view; this.view = new MediaSessionView();
    this.view.localId = previous.localId; this.view.mode = previous.mode; this.view.serverUrl = previous.serverUrl;
    this.lastCommandAt = 0; this.lastCommandDevice = ''; this.lastReceivedAt = 0;
    this.latestHostCommand = undefined; this.queuedCommand = undefined; this.reconnectCount = 0;
    this.socketRequest = 'join'; this.roomConfirmed = false;
    try {
      if (this.pulseTimer !== -1) { clearInterval(this.pulseTimer); this.pulseTimer = -1; }
      if (this.joinTimer !== -1) { clearTimeout(this.joinTimer); this.joinTimer = -1; }
      if (this.reconnectTimer !== -1) { clearTimeout(this.reconnectTimer); this.reconnectTimer = -1; }
      // 先摘除所有监听及本地引用，立即解锁接收端；网络关闭不阻塞系统会话销毁。
      const closing: Promise<void> = this.detachSocket(); this.emit();
      Logger.info('MEDIA_SESSION', '会话缓存及监听已清理，会话=' + previous.sessionId);
      if (controller) {
        if (callbacks) {
          try { controller.off('sessionEvent', callbacks.sessionEvent); } catch (error) { this.failure('注销接收端事件监听失败', error); }
          try { controller.off('sessionDestroy', callbacks.sessionDestroy); } catch (error) { this.failure('注销接收端销毁监听失败', error); }
          try { controller.off('playbackStateChange', callbacks.playbackStateChange); } catch (error) { this.failure('注销接收端时间同步监听失败', error); }
        }
        try { await controller.destroy(); } catch (error) { this.failure('释放接收端会话失败', error); }
      }
      if (owner) {
        try { owner.off('commonCommand', this.commandCallback); } catch (error) { this.failure('注销主控指令监听失败', error); }
        try { owner.off('outputDeviceChange', this.outputCallback); } catch (error) { this.failure('注销投送设备监听失败', error); }
        try { await owner.destroy(); } catch (error) { this.failure('释放主控会话失败', error); }
      }
      await closing;
    } catch (error) { this.failure('释放媒体会话资源失败', error); }
  }
  async release(): Promise<void> {
    ++this.revision;
    try { this.notifyDeparture(); await this.releaseResources(); }
    catch (error) { this.failure('退出同播会话失败', error); }
  }
}

@Builder
function SelectItem(configuration: MenuItemConfiguration) {
  // 全局函数无法使用 this，直接读取 AppStorage 中的全局字体缩放。
  Text(configuration.value).fontSize(Ui.fs('13vp', AppStorage.get<number>('fontScale') ?? 1));
}

class MediaSessionSelectItemModifier implements ContentModifier<MenuItemConfiguration> {
  applyContent(): WrappedBuilder<[MenuItemConfiguration]> {
    return wrapBuilder(SelectItem);
  }
}

/**
 * ArkTS 不允许把无类型对象字面量传给 Record<string, Object> 参数，
 * 统一在这里构造 AVSessionController / AVCastController 的命令参数。
 */
function sessionArgs(key: string, value: Object): Record<string, Object> {
  const args: Record<string, Object> = {};
  args[key] = value;
  return args;
}

@Component
export struct MediaSessionDialog {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop @Watch('onVisibilityChanged') visible: boolean = false;
  service: MediaSessionService = new MediaSessionService();
  onClose: () => void = (): void => {};
  quest3Service?: Quest3ControlService;
  getQuestPayload?: () => Quest3CoPlayPayload;
  getQuestCurrentMs?: () => number;
  getQuestEpisodeIndex?: () => number;
  getQuestSpeed?: () => number;
  onQuestState?: (packet: Quest3StatePacket) => void;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private session: MediaSessionView = new MediaSessionView();
  @State private joinId: string = '';
  @State private serverAddress: string = '';
  @State private busy: boolean = false;
  @State private lanDevices: CoPlayLanDevice[] = [];
  @State private lanStatus: string = '尚未扫描，点击“刷新设备”开始；打开弹窗不会自动扫描。';
  @State private lanRefreshing: boolean = false;
  @State private lanSendingId: string = '';
  @State private questAddress: string = '';
  @State private questPort: string = '43827';
  @State private questOnline: boolean = false;
  @State private questMenuVisible: boolean = false;
  @State private questSceneMode: Quest3SceneMode = 'plane';
  @State private questStatus: string = '输入 Quest 3 的局域网 IP 后连接';
  @State private questBusy: boolean = false;
  private lanRevision: number = 0;
  private lanOpening?: Promise<void>;
  private lastOperation: number = 0;
  private listening: boolean = false;
  private presented: boolean = false;
  private shownFatal: string = '';
  private viewCallback = (view: MediaSessionView): void => {
    try {
      if (!this.listening || !this.visible) { return; }
      this.session = view;
      if (view.fatalMessage && this.shownFatal !== view.fatalMessage) {
        this.shownFatal = view.fatalMessage;
        this.getUIContext().getPromptAction().showDialog({ title: '同播连接已停止', message: view.fatalMessage,
            buttons: [{ text: '知道了', color: Ui.accent(this.darkTheme) }] })
          .catch((error: BusinessError): void => { Logger.warn('MEDIA_SESSION', '重连失败提示已关闭，错误码=' + error.code); });
      }
      if (!view.fatalMessage) { this.shownFatal = ''; }
    } catch (error) { Logger.error('MEDIA_SESSION', '更新弹窗状态失败：' + String(error)); }
  };
  aboutToAppear(): void { this.onVisibilityChanged(); }
  aboutToDisappear(): void { this.releasePresented(); }
  private detach(): void {
    try { this.listening = false; this.service.unsubscribe(this.viewCallback); }
    catch (error) { Logger.warn('MEDIA_SESSION', '释放弹窗监听失败：' + String(error)); }
  }
  private lanFailure(stage: string, error: Object): void {
    const problem: BusinessError = error as BusinessError;
    Logger.error('MEDIA_SESSION', '【CoPlay][LAN-Dialog][' + stage + '] code=' + String(problem.code) +
    '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
  }
  private async openLan(): Promise<void> {
    const revision: number = this.lanRevision;
    try {
      if (!this.visible || !this.presented) { return; }
      const context: common.UIAbilityContext | undefined = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      if (!context) { throw new Error('协播弹窗上下文尚未就绪'); }
      await CoPlayLanService.shared.openDialog(context, (devices: CoPlayLanDevice[]): void => {
        if (!this.visible || !this.presented || revision !== this.lanRevision) { return; }
        this.lanDevices = devices;
      }, (message: string): void => {
        if (!this.visible || !this.presented || revision !== this.lanRevision) { return; }
        this.lanStatus = message;
        this.getUIContext().getPromptAction().showToast({ message: message });
      });
    } catch (error) {
      this.lanFailure('Init', error);
      if (this.visible && this.presented && revision === this.lanRevision) {
        this.lanStatus = '局域网设备初始化失败，请检查分布式权限后重试';
      }
    }
  }
  private async prepareLan(): Promise<void> {
    if (this.lanOpening) { await this.lanOpening; return; }
    const task: Promise<void> = this.openLan();
    this.lanOpening = task;
    try { await task; }
    finally { if (this.lanOpening === task) { this.lanOpening = undefined; } }
  }
  private async refreshLanDevices(): Promise<void> {
    const revision: number = this.lanRevision;
    try {
      Logger.info('MEDIA_SESSION', '【CoPlay][LAN-Dialog] 刷新设备按钮点击');
      if (!this.visible || this.busy || this.lanRefreshing || this.lanSendingId.length > 0) { return; }
      if (this.session.mode !== 'lan') {
        this.getUIContext().getPromptAction().showToast({ message: '请切换至局域网模式后刷新设备' }); return;
      }
      this.lanRefreshing = true; this.lanDevices = [];
      this.lanStatus = '正在准备扫描，请确认两台设备连接同一 WiFi';
      // 初始化与刷新串行；权限弹窗尚未返回时，不能绕过设备回调注册直接扫描。
      await this.prepareLan();
      if (!this.visible || !this.presented || revision !== this.lanRevision) { return; }
      await CoPlayLanService.shared.refresh();
    } catch (error) {
      this.lanFailure('Refresh', error);
      if (this.visible && revision === this.lanRevision) {
        this.lanStatus = '局域网设备扫描失败，请检查权限与同一 WiFi';
        this.getUIContext().getPromptAction().showToast({ message: this.lanStatus });
      }
    } finally { if (revision === this.lanRevision) { this.lanRefreshing = false; } }
  }
  private async connectQuest3(): Promise<void> {
    try {
      if (this.questBusy) { return; }
      const address: string = this.questAddress.trim();
      const port: number = Number(this.questPort);
      if (!address || !/^[A-Za-z0-9.:-]+$/.test(address) || !Number.isInteger(port) || port < 1 || port > 65535) {
        this.getUIContext().getPromptAction().showToast({ message: '请输入有效的 Quest 3 IP 地址和端口' }); return;
      }
      if (!this.quest3Service || !this.getQuestPayload) {
        this.getUIContext().getPromptAction().showToast({ message: 'Quest 3 控制服务尚未初始化' }); return;
      }
      this.questBusy = true;
      const device: Quest3DeviceDescriptor = { deviceId: 'quest3-manual', deviceName: 'Meta Quest 3',
          deviceType: 'vr_quest3', address: address, port: port, online: false };
      const sessionId: string = this.getQuestPayload().sessionId;
      await this.quest3Service.connect(device, sessionId, {
        onState: (packet: Quest3StatePacket): void => {
          try { this.onQuestState?.(packet); } catch (error) { this.lanFailure('QuestStateCallback', error); }
        },
          onConnectionChanged: (online: boolean, message: string): void => {
          try { this.questOnline = online; this.questStatus = message; }
          catch (error) { this.lanFailure('QuestConnectionCallback', error); }
        }
      });
      const payload: Quest3CoPlayPayload = this.getQuestPayload();
      payload.sceneMode = this.questSceneMode;
      await this.quest3Service.sendPayload(payload);
      this.questOnline = this.quest3Service.isOnline();
      this.questStatus = this.questOnline ? 'Quest 3 已连接' : 'Quest 3 连接中';
      this.getUIContext().getPromptAction().showToast({ message: this.questStatus });
    } catch (error) {
      this.lanFailure('QuestConnect', error); this.questOnline = false; this.questStatus = '连接失败，请检查 IP、端口和 Quest 端服务';
      this.getUIContext().getPromptAction().showDialog({ title: 'Quest 3 连接失败', message: this.questStatus,
          buttons: [{ text: '知道了', color: Ui.accent(this.darkTheme) }] }).catch((problem: BusinessError): void => { this.lanFailure('QuestDialog', problem); });
    } finally { this.questBusy = false; }
  }
  private async sendQuestCommand(command: 'play' | 'pause' | 'seek' | 'speed' | 'switchEpisode'): Promise<void> {
    try {
      if (!this.quest3Service || !this.quest3Service.isOnline()) {
        this.getUIContext().getPromptAction().showToast({ message: 'Quest 3 当前离线，请先连接设备' }); return;
      }
      const currentMs: number = Math.max(0, Math.floor(this.getQuestCurrentMs ? this.getQuestCurrentMs() : 0));
      const episodeIndex: number = Math.max(0, Math.floor(this.getQuestEpisodeIndex ? this.getQuestEpisodeIndex() : 0));
      const speed: number = this.getQuestSpeed ? this.getQuestSpeed() : 1;
      await this.quest3Service.sendCommand(command, currentMs, speed, episodeIndex);
      this.getUIContext().getPromptAction().showToast({ message: '已发送：' + command });
    } catch (error) { this.lanFailure('QuestCommand', error); this.getUIContext().getPromptAction().showToast({ message: 'Quest 3 指令发送失败' }); }
  }
  private async changeQuestScene(mode: Quest3SceneMode): Promise<void> {
    try {
      this.questSceneMode = mode;
      if (!this.quest3Service || !this.quest3Service.isOnline()) {
        this.getUIContext().getPromptAction().showToast({ message: '请先连接 Quest 3' }); return;
      }
      await this.quest3Service.setSceneMode(mode);
      this.getUIContext().getPromptAction().showToast({ message: '幕布模式：' + mode });
    } catch (error) { this.lanFailure('QuestScene', error); }
  }
  private async sendLanInvitation(deviceId: string): Promise<void> {
    let started: boolean = false;
    try {
      if (!this.visible || this.busy || this.lanRefreshing || this.lanSendingId.length > 0) { return; }
      this.busy = true; this.lanSendingId = deviceId; started = true;
      await this.service.inviteLan(deviceId);
    } catch (error) {
      this.lanFailure('Invite', error);
      if (this.visible) { this.getUIContext().getPromptAction().showToast({ message: '向设备下发协播邀请失败' }); }
    } finally {
      if (started) { this.lanSendingId = ''; this.busy = false; }
    }
  }
  private releasePresented(): void {
    try {
      this.detach();
      // 初次以隐藏状态挂载时不释放分享入会；只有真正打开过的浮层关闭才清理资源。
      if (this.presented) {
        this.presented = false; ++this.lanRevision;
        // 关闭同步窗口只释放窗口级设备发现资源，不销毁现有协播会话。
        // 会话 ID、主控信息、播放状态与缓存由 MediaSessionService 保留；
        // 真正离开播放器页面时由 PlayerPage.aboutToDisappear() 统一 release。
        CoPlayLanService.shared.closeDialog();
        this.lanOpening = undefined; this.lanDevices = []; this.lanRefreshing = false;
        this.lanStatus = '窗口已关闭；原协播会话保留。重新打开后可继续查看。';
      }
    } catch (error) { Logger.warn('MEDIA_SESSION', '关闭浮层释放会话失败：' + String(error)); }
  }
  private onVisibilityChanged(): void {
    try {
      if (!this.visible) { this.releasePresented(); return; }
      const opening: boolean = !this.presented;
      this.presented = true; this.serverAddress = this.service.snapshot().serverUrl;
      if (!this.listening) { this.listening = true; this.service.subscribe(this.viewCallback); }
      // 此浮层由 visible 控制，而非系统 Dialog：以可见性生命周期对应打开/关闭。
      // 打开只初始化 DeviceManager、注册回调；扫描只能由“刷新设备”触发。
      if (opening) { ++this.lanRevision; void this.prepareLan(); }
    } catch (error) { Logger.error('MEDIA_SESSION', '监听弹窗状态失败：' + String(error)); }
  }
  private async operate(action: string, target: string = ''): Promise<void> {
    let started: boolean = false;
    try {
      if (action === 'invite') {
        Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] 邀请设备按钮点击，visible=' + this.visible + '，busy=' + this.busy);
      }
      // 邀请由分享服务防重复；不再被创建会话后的 600ms 操作间隔静默丢弃。
      if (!this.visible || this.busy || (action !== 'invite' && Date.now() - this.lastOperation < 600)) {
        if (action === 'invite') {
          Logger.warn('MEDIA_SESSION', '【CoPlay][SendShare] 邀请暂未执行，弹窗隐藏或上一会话操作尚未结束');
          if (this.visible && this.busy) {
            this.getUIContext().getPromptAction().showToast({ message: '会话操作正在处理中，请稍后重试' });
          }
        }
        return;
      }
      this.lastOperation = Date.now(); this.busy = true; started = true;
      if (action === 'mode') { await this.service.setMode(target); }
      else if (action === 'create' || action === 'join') {
        if (this.session.mode === 'server') { this.service.setServer(this.serverAddress); }
        if (action === 'create') { await this.service.create(); } else { await this.service.join(this.joinId); }
      } else if (action === 'invite') { await this.service.invite(); }
      else if (action === 'leave') { await this.service.release(); }
      else { await this.service.manage(action, target); }
    } catch (error) { Logger.error('MEDIA_SESSION', '弹窗操作失败：' + String(error)); }
    finally { if (started) { this.busy = false; } }
  }
  private close(): void {
    try { this.releasePresented(); this.onClose(); }
    catch (error) { Logger.error('MEDIA_SESSION', '关闭弹窗失败：' + String(error)); }
  }
  // 视觉取值统一走液态玻璃令牌，深浅模式切换时随 @StorageLink('darkTheme') 同步。
  private ink(): string { return Ui.ink(this.darkTheme); }
  private tint(): string { return Ui.glassTintStrong(this.darkTheme); }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme)).onClick((): void => { this.close(); });
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 16 }) {
            SymbolGlyph($r('sys.symbol.wireless_projection')).fontSize(Ui.fs('24vp', this.fontScale)).fontColor([this.ink()]);
            Text('协同同播').fontSize(Ui.fs('20vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).layoutWeight(1);
            Button({ type: ButtonType.Normal }) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(Ui.fs('20vp', this.fontScale)).fontColor([this.ink()]);
            }.width('36vp').height('36vp').padding('0vp').borderRadius('18vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
              .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
              .accessibilityText('关闭协同同播窗口，保留当前会话')
              .onClick((): void => { this.close(); });
          }.width('100%').alignItems(VerticalAlign.Center);
          Select([{ value: '局域网 AVSession / AVCast（仅 HarmonyOS）' }, { value: '自建 WebSocket 信令服务器' }])
            .selected(this.session.mode === 'server' ? 1 : 0).value(this.session.mode === 'server' ? '自建 WebSocket 信令服务器' : '局域网 AVSession / AVCast（仅 HarmonyOS）')
            .font({ size: '13vp' }).fontColor(Ui.ink(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp')
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
            .menuItemContentModifier(new MediaSessionSelectItemModifier()).width('100%').onSelect((index: number): void => { void this.operate('mode', index === 1 ? 'server' : 'lan'); });
          Text('当前模式：' + (this.session.mode === 'server' ? '服务器信令' : '系统局域网') + ' · ' + this.session.status)
            .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.ink()).width('100%');
          TextInput({ placeholder: '信令服务器地址，例如 wss://服务器域名/路径', text: this.serverAddress }).height('40vp').fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp').padding({ left: '14vp', right: '14vp' })
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
            .visibility(this.session.mode === 'server' ? Visibility.Visible : Visibility.None)
            .onChange((value: string): void => {
            try { if (!this.session.active && !this.busy) { this.serverAddress = value.slice(0, 2048); } }
            catch (error) { Logger.warn('MEDIA_SESSION', '更新服务器输入失败：' + String(error)); }
          });
          Text('房间 / 会话 ID：' + (this.session.sessionId || '尚未创建')).fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.ink()).width('100%').copyOption(CopyOptions.InApp);
          Text('主控：' + (this.session.devices.find((item: MediaSessionDevice): boolean => item.deviceId === this.session.hostId)?.deviceName || '无'))
            .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.ink()).width('100%');
          Text(this.session.hostId).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%').copyOption(CopyOptions.InApp)
            .visibility(this.session.active ? Visibility.Visible : Visibility.None);
          TextInput({ placeholder: this.session.mode === 'server' ? '手动输入房间 ID 加入' : '输入系统实际可见的会话 ID', text: this.joinId }).height('40vp').fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp').padding({ left: '14vp', right: '14vp' })
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
            .onChange((value: string): void => {
            try { this.joinId = value.trim().slice(0, 256); }
            catch (error) { Logger.warn('MEDIA_SESSION', '更新会话输入失败：' + String(error)); }
          });
          Row({ space: 16 }) {
            Button(this.busy ? '处理中…' : this.session.mode === 'server' ? '随机创建房间' : '创建系统会话').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('36vp').fontSize(Ui.fs('13vp', this.fontScale)).layoutWeight(1)
              .onClick((): void => { void this.operate('create'); });
            Button('加入会话').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('36vp').fontSize(Ui.fs('13vp', this.fontScale)).layoutWeight(1).onClick((): void => { void this.operate('join'); });
          }.width('100%').alignItems(VerticalAlign.Center).visibility(this.session.active ? Visibility.None : Visibility.Visible);
          Column({ space: 10 }) {
            Text('邀请方式').fontSize(Ui.fs('15vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).width('100%');
            Row({ space: 12 }) {
              Button('华为分享邀请').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('38vp').fontSize(Ui.fs('13vp', this.fontScale)).layoutWeight(1)
                .enabled(this.session.active && this.session.isHost && !this.busy)
                .onClick((): void => { void this.operate('invite'); });
              Button(this.lanRefreshing ? '准备扫描…' : '刷新设备').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('38vp').fontSize(Ui.fs('13vp', this.fontScale)).layoutWeight(1)
                .enabled(this.session.mode === 'lan' && !this.busy && !this.lanRefreshing)
                .onClick((): void => { void this.refreshLanDevices(); });
            }.width('100%').alignItems(VerticalAlign.Center);
            Text(this.session.mode === 'server' ? '服务器模式可使用华为分享；切换至局域网模式后可刷新设备邀请。' :
              '两种邀请方式共存。请先创建系统会话，再选择华为分享，或刷新后点击局域网设备邀请。')
              .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
            Divider();
            Text('Quest 3 独立连接').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.ink()).width('100%');
            Text('Quest 3 需在同一局域网运行 WebSocket 服务端（默认端口 43827）。').fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
            Row({ space: 8 }) {
              TextInput({ text: this.questAddress, placeholder: 'Quest 3 IP 地址' }).layoutWeight(1).height('40vp')
                .fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp').padding({ left: '12vp', right: '12vp' })
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
                .onChange((value: string): void => { this.questAddress = value; });
              TextInput({ text: this.questPort, placeholder: '端口' }).width('76vp').height('40vp').type(InputType.Number)
                .fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp')
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
                .onChange((value: string): void => { this.questPort = value; });
              Button(this.questBusy ? '连接中' : (this.questOnline ? '已连接' : '连接')).fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('40vp')
                .enabled(!this.questBusy).onClick((): void => { void this.connectQuest3(); });
            }.width('100%');
            Text(this.questStatus).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(this.questOnline ? Ui.success(this.darkTheme) : Ui.inkFaint(this.darkTheme)).width('100%');
            Button(this.questMenuVisible ? '收起 Quest 3 操作菜单' : '打开 Quest 3 操作菜单').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).width('100%')
              .onClick((): void => { this.questMenuVisible = !this.questMenuVisible; });
            if (this.questMenuVisible) {
              Row({ space: 8 }) {
                Button('同步播放').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.sendQuestCommand('play'); });
                Button('暂停').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.sendQuestCommand('pause'); });
                Button('跳转当前进度').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.sendQuestCommand('seek'); });
              }.width('100%');
              Row({ space: 8 }) {
                Button('平面').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.changeQuestScene('plane'); });
                Button('180°弧幕').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.changeQuestScene('arc180'); });
                Button('360°球幕').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.changeQuestScene('sphere360'); });
              }.width('100%');
              Row({ space: 8 }) {
                Button('切换到当前集').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.sendQuestCommand('switchEpisode'); });
                Button('同步倍速').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline).onClick((): void => { void this.sendQuestCommand('speed'); });
                Button('断开连接').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).layoutWeight(1).enabled(this.questOnline || this.questBusy).onClick((): void => {
                  try { this.quest3Service?.close(); this.questOnline = false; this.questBusy = false; this.questStatus = 'Quest 3 已断开'; }
                  catch (error) { this.lanFailure('QuestDisconnect', error); }
                });
              }.width('100%');
            }
            Text('局域网设备（' + this.lanDevices.length + '）').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.ink()).width('100%');
            Text(this.lanDevices.length > 0 ? '点击设备下发邀请；目标应用需在前台，且两台设备连接同一 WiFi。' : this.lanStatus)
              .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
            ForEach(this.lanDevices, (device: CoPlayLanDevice) => {
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    if (device.deviceType === 'vr_quest3' || /quest\s*3|meta quest/i.test(device.deviceName)) { SymbolGlyph($r('sys.symbol.wireless_projection')).fontSize(Ui.fs('18vp', this.fontScale)); }
                    Text(device.deviceName + ((device.deviceType === 'vr_quest3' || /quest\s*3|meta quest/i.test(device.deviceName)) ? ' · Quest 3' : ' · 鸿蒙设备')).fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.ink()).width('100%');
                  }.width('100%');
                  Text('deviceId：' + device.deviceId).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%').copyOption(CopyOptions.InApp);
                }.layoutWeight(1);
                Text(this.lanSendingId === device.deviceId ? '发送中…' : '邀请').fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor(Ui.accent(this.darkTheme));
              }.width('100%').padding('10vp').borderRadius('18vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
                .enabled(this.session.mode === 'lan' && !this.busy && !this.lanRefreshing)
                .accessibilityText('邀请局域网设备 ' + device.deviceName + '，deviceId ' + device.deviceId)
                .onClick((): void => {
                if (device.deviceType === 'vr_quest3' || /quest\s*3|meta quest/i.test(device.deviceName)) {
                  this.questMenuVisible = true;
                  this.getUIContext().getPromptAction().showToast({ message: 'Quest 3 需在上方填写 IP 地址后连接' });
                } else { void this.sendLanInvitation(device.deviceId); }
              });
            }, (device: CoPlayLanDevice): string => device.deviceId);
          }.width('100%').padding('12vp').borderRadius('20vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) });
          Text('在线设备（' + this.session.devices.length + '）').fontSize(Ui.fs('15vp', this.fontScale)).fontColor(this.ink()).width('100%');
          Column({ space: 10 }) {
            ForEach(this.session.devices, (device: MediaSessionDevice) => {
              Column({ space: 4 }) {
                Text(device.deviceName + (device.deviceId === this.session.hostId ? ' · 主控' : '') + (device.deviceId === this.session.localId ? ' · 本机' : ''))
                  .fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.ink()).width('100%');
                Text(device.deviceId).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%').copyOption(CopyOptions.InApp);
                Row({ space: 16 }) {
                  Button('移交主控').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('32vp').fontSize(Ui.fs('12vp', this.fontScale)).onClick((): void => { void this.operate('transfer', device.deviceId); });
                  Button('踢出设备').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('32vp').fontSize(Ui.fs('12vp', this.fontScale)).onClick((): void => { void this.operate('kick', device.deviceId); });
                }.alignItems(VerticalAlign.Center).visibility(this.session.isHost && device.deviceId !== this.session.localId ? Visibility.Visible : Visibility.None);
              }.width('100%').padding('8vp').borderRadius('16vp').backgroundColor(Ui.glassTintSoft(this.darkTheme)).border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) });
            }, (device: MediaSessionDevice): string => device.deviceId);
            ForEach(this.session.castDevices, (device: MediaSessionDevice) => {
              Text('系统投送 · ' + device.deviceName + '\n' + device.deviceId).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme)).width('100%');
            }, (device: MediaSessionDevice): string => 'cast-' + device.deviceId);
          }.width('100%');
          Row({ space: 16 }) {
            Button('退出会话').fontColor(Ui.ink(this.darkTheme)).backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('18vp').border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) }).height('36vp').fontSize(Ui.fs('13vp', this.fontScale)).layoutWeight(1)
              .visibility(this.session.sessionId ? Visibility.Visible : Visibility.None).onClick((): void => { void this.operate('leave'); });
          }.width('100%').alignItems(VerticalAlign.Center);
          Text(this.session.mode === 'server' ?
            '需要已部署并实现 JSON v1 房间协议的信令服务。支持 wss；服务端须校验主控权限。断线采用 1、2、4、8、16、30 秒退避，最多重试 6 次。' :
            '局域网模式仅连接系统实际可访问的 AVSession，仅在 HarmonyOS 上可用；Android/iOS 请使用服务器模式。AVCast 设备由系统投送能力提供。')
            .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
          Text('华为分享邀请继续使用原有系统分享接收链路；局域网邀请为独立备选通道。打开弹窗仅初始化设备管理，点击刷新才扫描，关闭窗口只停止设备扫描并解除发现回调，不清除当前协播会话。')
            .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
          Text('通过系统分享邀请，华为分享及碰一碰取决于设备支持。关闭同步窗口仅释放窗口级扫描资源并保留会话；点击“退出会话”或离开播放器页面时才释放会话、网络监听与重连任务。')
            .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
        }.width('100%').padding('16vp');
      }.width('92%').constraintSize({ maxWidth: '480vp', maxHeight: '94%' }).scrollBar(BarState.Auto)
        .backgroundColor(this.tint())
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur)).borderRadius('24vp')
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
        .shadow({ radius: 26, color: Ui.shadow(this.darkTheme), offsetX: 0, offsetY: 12 })
        .onTouch((event: TouchEvent): void => { event.stopPropagation(); });
    }.width('100%').height('100%').visibility(this.visible ? Visibility.Visible : Visibility.None);
  }
}

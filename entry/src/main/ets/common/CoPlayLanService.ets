import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { DeviceBasicInfo, DeviceManager, DeviceStateChange, createDeviceManager } from './compat/DeviceManagerCompat';
import { PlatformInfo } from './compat/PlatformInfo';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';
import { CoPlayTransport, CoPlayInvitation } from './CoPlayTransport';

export interface CoPlayLanDevice {
  deviceId: string;
  deviceName: string;
  networkId: string;
  deviceType?: 'harmony' | 'vr_quest3';
}
interface DiscoveryEvent { device: DeviceBasicInfo; }
interface DiscoveryFailure { reason: number; }
interface DeviceStateEvent {
  action: DeviceStateChange;
  device: DeviceBasicInfo;
}
interface LanAnnouncement {
  protocol: string;
  kind: string;
  deviceId: string;
  networkId: string;
}
interface LanEndpoint { deviceId: string; networkId: string; address: string; seenAt: number; }
interface IncomingInvitation {
  connection: socket.TCPSocketConnection;
  data: Uint8Array;
  timer: number;
  processing: boolean;
}

// API26 Beta2 的 DeviceManager 只负责发现/状态/认证，不存在 sendMessage 或 message 事件。
// 因此用真实 DeviceManager 发现目标，用同 WiFi UDP 定位应用端点，再以 TCP 完整传输。
// UDP 只承载端点公告，绝不承载 videoJson。接收端仅在应用前台运行，不启动设备扫描。
export class CoPlayLanService {
  static readonly shared: CoPlayLanService = new CoPlayLanService();
  private static readonly PORT: number = 43826;
  private static readonly MAX_BYTES: number = 32 * 1024 * 1024;
  private context?: common.UIAbilityContext;
  private manager?: DeviceManager;
  private creating?: Promise<DeviceManager>;
  private managerRevision: number = 0;
  private callbacksBound: boolean = false;
  private dialogOpen: boolean = false;
  private dialogRevision: number = 0;
  private refreshRevision: number = 0;
  private scanning: boolean = false;
  private scanTimer: number = -1;
  private scanEndTimer: number = -1;
  private devices: CoPlayLanDevice[] = [];
  private endpoints: LanEndpoint[] = [];
  private devicesChanged: (devices: CoPlayLanDevice[]) => void = (): void => {};
  private notice: (message: string) => void = (): void => {};
  private receiver?: (raw: string) => Promise<void>;
  private foreground: boolean = false;
  private receiverRevision: number = 0;
  private starting?: Promise<void>;
  private udp?: socket.UDPSocket;
  private server?: socket.TCPSocketServer;
  private incoming: IncomingInvitation[] = [];
  private localDeviceId: string = '';
  private localNetworkId: string = '';
  private sending: boolean = false;

  private failure(stage: string, error: Object): void {
    const problem: BusinessError = error as BusinessError;
    Logger.error('CO_PLAYBACK', '【CoPlay][LAN][' + stage + '] code=' + String(problem.code) +
    '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
  }
  private toast(message: string): void {
    try { this.notice(message); } catch (error) { this.failure('Toast', error); }
  }
  private emitDevices(): void {
    try { this.devicesChanged(this.devices.slice()); } catch (error) { this.failure('Devices', error); }
  }
  private readonly discovered = (event: DiscoveryEvent): void => {
    try { if (this.dialogOpen && this.scanning) { this.addDevice(event.device); } }
    catch (error) { this.failure('DiscoverCallback', error); }
  };
  private readonly discoveryFailed = (event: DiscoveryFailure): void => {
    try {
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN] 扫描失败，reason=' + event.reason);
      ++this.refreshRevision;
      this.stopScanning(); this.toast('局域网设备扫描失败，' + this.permissionHint());
    } catch (error) { this.failure('DiscoverFailureCallback', error); }
  };
  private readonly stateChanged = (event: DeviceStateEvent): void => {
    try {
      if (!this.dialogOpen) { return; }
      if (event.action === DeviceStateChange.UNAVAILABLE) {
        Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 设备离线，deviceId=' + event.device.deviceId);
        this.devices = this.devices.filter((item: CoPlayLanDevice): boolean => item.deviceId !== event.device.deviceId);
        this.endpoints = this.endpoints.filter((item: LanEndpoint): boolean => item.deviceId !== event.device.deviceId &&
          item.networkId !== event.device.networkId);
        this.emitDevices();
      } else { this.addDevice(event.device); }
    } catch (error) { this.failure('DeviceStateCallback', error); }
  };
  private addDevice(device: DeviceBasicInfo): void {
    if (!device.deviceId || device.deviceId === this.localDeviceId ||
      (device.networkId && device.networkId === this.localNetworkId)) { return; }
    const item: CoPlayLanDevice = {
      deviceId: String(device.deviceId), deviceName: String(device.deviceName || '鸿蒙设备'),
        networkId: String(device.networkId || ''),
      deviceType: /quest\s*3|meta quest/i.test(String(device.deviceName || '')) ? 'vr_quest3' : 'harmony'
    };
    this.devices = this.devices.filter((value: CoPlayLanDevice): boolean => value.deviceId !== item.deviceId).concat([item]);
    Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 发现设备，名称=' + item.deviceName + '，deviceId=' + item.deviceId +
    '，networkId=' + item.networkId);
    this.emitDevices();
  }
  /** 权限失败提示按平台区分，避免在 Android/iOS 上提示“分布式权限”。 */
  private permissionHint(): string {
    if (PlatformInfo.isHarmonyOS()) { return '请确认已授予分布式数据同步权限，并检查应用签名与系统版本。'; }
    return '请确认两台设备在同一 Wi-Fi，并允许应用的本地网络权限。';
  }
  private async granted(request: boolean): Promise<boolean> {
    if (!this.context) { return false; }
    // Android/iOS 没有 DISTRIBUTED_DATASYNC 权限体系，局域网协播不依赖分布式软总线。
    if (!PlatformInfo.isHarmonyOS()) { return true; }
    try {
      const control = abilityAccessCtrl.createAtManager();
      const permission: abilityAccessCtrl.GrantStatus = await control.checkAccessToken(
        this.context.applicationInfo.accessTokenId, 'ohos.permission.DISTRIBUTED_DATASYNC');
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN][PermissionCheck] DISTRIBUTED_DATASYNC=' + String(permission));
      if (permission === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { return true; }
      if (!request) { return false; }
      const result = await control.requestPermissionsFromUser(this.context, ['ohos.permission.DISTRIBUTED_DATASYNC']);
      const granted: boolean = result.authResults.length > 0 && result.authResults.every((value: number): boolean => value === 0);
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN][PermissionRequest] authResults=' + JSON.stringify(result.authResults) + '，granted=' + String(granted));
      return granted;
    } catch (error) { this.failure('PermissionRequestOrCheck', error); return false; }
  }
  private async ensureManager(): Promise<DeviceManager> {
    if (this.manager) { return this.manager; }
    if (this.creating) { return this.creating; }
    if (!this.context) { throw new Error('局域网上下文尚未就绪'); }
    const revision: number = this.managerRevision;
    const bundleName: string = this.context.abilityInfo.bundleName;
    const task: Promise<DeviceManager> = new Promise((resolve, reject): void => {
      try {
        // API26 使用单参数同步工厂，不再传入旧版异步回调。
        const manager: DeviceManager = createDeviceManager(bundleName);
        try {
          if (revision !== this.managerRevision) {
            // 过期实例不再挂载到服务，也不注册回调。
            reject(new Error('分布式设备初始化已取消')); return;
          }
          this.manager = manager;
          this.localDeviceId = manager.getLocalDeviceId();
          this.localNetworkId = manager.getLocalDeviceNetworkId();
          resolve(manager);
        } catch (caught) { this.failure('ManagerIdentity', caught); this.releaseManager(); reject(new Error('读取本机分布式身份失败')); }
      } catch (error) { this.failure('CreateDeviceManager', error); reject(new Error('初始化分布式设备管理失败')); }
    });
    this.creating = task;
    try { return await task; }
    finally { if (this.creating === task) { this.creating = undefined; } }
  }
  async openDialog(context: common.UIAbilityContext, changed: (devices: CoPlayLanDevice[]) => void,
    notice: (message: string) => void): Promise<void> {
    this.context = context; this.devicesChanged = changed; this.notice = notice;
    if (this.dialogOpen && this.callbacksBound) { this.emitDevices(); return; }
    this.dialogOpen = true;
    const revision: number = ++this.dialogRevision;
    try {
      if (!await this.granted(true)) { throw new Error('未获得分布式设备权限'); }
      if (!this.dialogOpen || revision !== this.dialogRevision) { return; }
      const manager: DeviceManager = await this.ensureManager();
      if (!this.dialogOpen || revision !== this.dialogRevision) { return; }
      // 标记先置位，任一 on 失败时也逐项 off，避免半初始化留下监听。
      if (!this.callbacksBound) {
        this.callbacksBound = true;
        manager.on('discoverSuccess', this.discovered);
        manager.on('discoverFailure', this.discoveryFailed);
        manager.on('deviceStateChange', this.stateChanged);
      }
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 弹窗设备管理初始化完成、发现和状态回调已注册；不自动扫描');
      await this.startReceiver();
    } catch (error) {
      this.failure('DialogInit', error);
      if (revision === this.dialogRevision) {
        this.closeDialog();
        const problem: BusinessError = error as BusinessError;
        const detail: string = String(problem.code) + ' ' + String(problem.message || error);
        notice('局域网设备初始化失败（' + detail + '）。' + this.permissionHint());
      }
    }
  }
  async refresh(): Promise<void> {
    const revision: number = ++this.refreshRevision;
    try {
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 刷新设备点击');
      this.stopScanning();
      this.devices = []; this.endpoints = []; this.emitDevices();
      this.toast('正在扫描局域网设备…');
      if (!this.context || !this.dialogOpen) { throw new Error('弹窗设备管理尚未就绪'); }
      const manager: DeviceManager = await this.ensureManager();
      if (!this.dialogOpen || revision !== this.refreshRevision) { return; }
      await this.startReceiver();
      if (!this.dialogOpen || revision !== this.refreshRevision) { return; }
      if (!this.udp) { throw new Error('局域网接收端尚未就绪'); }
      // SDK 的发现参数是字典；先显式声明 Record，再按键赋值，避免匿名对象推断。
      // 不向 startDiscovering 的 Object 上下文直接传入含字段的对象字面量。
      const discoverParameters: Record<string, Object> = {};
      discoverParameters['discoverTargetType'] = 1;
      const filters: Record<string, Object> = {};
      filters['availableStatus'] = 0;
      this.scanning = true;
      manager.startDiscovering(discoverParameters, filters);
      if (!this.scanning || !this.dialogOpen || revision !== this.refreshRevision) { return; }
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN] startDiscovering 扫描开始');
      try {
        manager.getAvailableDeviceListSync().forEach((device: DeviceBasicInfo): void => { this.addDevice(device); });
      } catch (error) { this.failure('AvailableDevices', error); }
      await this.announce('probe', '255.255.255.255');
      // 广播等待期间可能关闭弹窗或再次刷新；旧任务不得重建后台扫描定时器。
      if (!this.dialogOpen || !this.scanning || revision !== this.refreshRevision) { return; }
      this.scanTimer = setInterval((): void => {
        void this.announce('probe', '255.255.255.255').catch((error: Error): void => { this.failure('Probe', error); });
      }, 2000);
      this.scanEndTimer = setTimeout((): void => { this.stopScanning(); }, 15000);
    } catch (error) {
      this.failure('Scan', error);
      if (revision === this.refreshRevision) {
        this.stopScanning(); this.toast('局域网设备扫描失败，' + this.permissionHint());
      }
    }
  }
  private stopScanning(): void {
    if (this.scanTimer !== -1) { clearInterval(this.scanTimer); this.scanTimer = -1; }
    if (this.scanEndTimer !== -1) { clearTimeout(this.scanEndTimer); this.scanEndTimer = -1; }
    const wasScanning: boolean = this.scanning;
    this.scanning = false;
    // HarmonyOS DeviceManager 的 startDiscovering/stopDiscovering 均为 void API，
    // stopDiscovering 不接收订阅 ID。仅在确实进入扫描状态时调用，避免重复停止。
    if (wasScanning && this.manager) {
      try { this.manager.stopDiscovering(); }
      catch (error) { this.failure('StopDiscovering', error); }
    }
    Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 扫描停止');
  }
  private releaseManager(): void {
    const manager: DeviceManager | undefined = this.manager;
    this.manager = undefined; ++this.managerRevision; this.creating = undefined;
    if (manager) {
      if (this.callbacksBound) {
        try { manager.off('discoverSuccess', this.discovered); } catch (error) { this.failure('OffDiscoverSuccess', error); }
        try { manager.off('discoverFailure', this.discoveryFailed); } catch (error) { this.failure('OffDiscoverFailure', error); }
        try { manager.off('deviceStateChange', this.stateChanged); } catch (error) { this.failure('OffDeviceState', error); }
      }
      // 清理监听及业务引用，不调用当前 SDK 未声明的实例释放方法。
    }
    this.callbacksBound = false;
  }
  closeDialog(): void {
    ++this.dialogRevision; ++this.refreshRevision; this.dialogOpen = false;
    this.stopScanning(); this.releaseManager();
    this.devices = []; this.endpoints = [];
    this.devicesChanged = (): void => {}; this.notice = (): void => {};
  }
  async resume(context: common.UIAbilityContext, receive: (raw: string) => Promise<void>): Promise<void> {
    this.context = context; this.receiver = receive; this.foreground = true;
    try {
      if (!await this.granted(false) || !this.foreground) { return; }
      await this.startReceiver();
    } catch (error) { this.failure('ReceiverResume', error); }
  }
  private async startReceiver(): Promise<void> {
    if (!this.foreground || !this.receiver) { return; }
    if (this.udp && this.server) { return; }
    const previous: Promise<void> | undefined = this.starting;
    if (previous) {
      try { await previous; }
      finally { if (this.starting === previous) { this.starting = undefined; } }
      // 后台取消的旧初始化结束后，当前前台请求仍需重新建立接收端。
      if (!this.foreground || !this.receiver || (this.udp && this.server)) { return; }
      if (this.starting) { await this.starting; return; }
    }
    const revision: number = this.receiverRevision;
    const task: Promise<void> = this.createReceiver(revision);
    this.starting = task;
    try { await task; }
    finally { if (this.starting === task) { this.starting = undefined; } }
  }
  private async createReceiver(revision: number): Promise<void> {
    let udp: socket.UDPSocket | undefined;
    let server: socket.TCPSocketServer | undefined;
    let stage: string = 'EnsureManager';
    let udpBound: boolean = false;
    let serverListening: boolean = false;
    try {
      await this.ensureManager();
      if (!this.dialogOpen) { this.releaseManager(); }
      if (!this.foreground || revision !== this.receiverRevision) { return; }
      stage = 'ConstructUdp';
      udp = socket.constructUDPSocketInstance();
      stage = 'ConstructTcpServer';
      server = socket.constructTCPSocketServerInstance();
      const receiverUdp: socket.UDPSocket = udp;
      const receiverServer: socket.TCPSocketServer = server;
      udp.on('message', (message: socket.SocketMessageInfo): void => {
        if (this.udp === receiverUdp && this.foreground) { void this.receiveAnnouncement(message); }
      });
      udp.on('error', (error: BusinessError): void => { this.failure('UdpError', error); });
      server.on('connect', (connection: socket.TCPSocketConnection): void => {
        try {
          if (this.server !== receiverServer || !this.foreground) {
            void connection.close().catch((error: Error): void => { this.failure('CloseInactiveConnection', error); }); return;
          }
          this.acceptConnection(connection);
        } catch (error) { this.failure('AcceptConnection', error); }
      });
      // 先 bind 再设置 UDP 扩展选项：部分 HarmonyOS 设备在未绑定的 Socket
      // 上调用 setExtraOptions 会返回 Parameter error / Bad file descriptor。
      stage = 'UdpBind';
      await udp.bind({ address: '0.0.0.0', port: CoPlayLanService.PORT, family: 1 });
      udpBound = true;
      // 端点探测使用 255.255.255.255，必须启用广播；若设置失败，记录真实阶段，
      // 不要假装接收服务可用后再把错误延迟到 announce()/SendPayload。
      stage = 'UdpSetExtraOptions';
      await udp.setExtraOptions({ reuseAddress: true, broadcast: true });
      stage = 'TcpListen';
      await server.listen({ address: '0.0.0.0', port: CoPlayLanService.PORT, family: 1 });
      serverListening = true;
      if (!this.foreground || revision !== this.receiverRevision) {
        // 初始化期间切到后台：释放资源，但不要把取消当作初始化故障。
        try { udp.off('message'); udp.off('error'); } catch (_) {}
        try { await udp.close(); } catch (error) { this.failure('CloseCancelledUdp', error); }
        udp = undefined;
        try { await server.close(); } catch (error) { this.failure('CloseCancelledServer', error); }
        server = undefined; return;
      }
      this.udp = udp; this.server = server;
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 前台邀请消息接收监听已注册；未启动设备扫描');
    } catch (error) {
      // 首先记录真正失败的阶段；close() 的二次异常只作为清理告警，不能掩盖根因。
      this.failure('CreateReceiver:' + stage, error);
      if (udp) {
        try { udp.off('message'); udp.off('error'); } catch (caught) { this.failure('DetachFailedUdp', caught); }
        try { await udp.close(); } catch (caught) { this.failure('CloseFailedUdp(bound=' + String(udpBound) + ')', caught); }
      }
      if (server) {
        try { await server.close(); } catch (caught) { this.failure('CloseFailedServer(listening=' + String(serverListening) + ')', caught); }
      }
      throw new Error('局域网消息接收服务初始化失败，阶段=' + stage);
    }
  }
  private async announce(kind: string, address: string): Promise<void> {
    try {
      if (!this.udp || !this.foreground) { return; }
      const packet: LanAnnouncement = {
        protocol: 'wuyin-coplay-lan-v1', kind: kind,
          deviceId: this.localDeviceId, networkId: this.localNetworkId
      };
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN][AnnouncementSend] kind=' + kind + '，target=' + address + ':' + String(CoPlayLanService.PORT));
      await this.udp.send({ address: { address: address, port: CoPlayLanService.PORT, family: 1 }, data: JSON.stringify(packet) });
    } catch (error) {
      this.failure('AnnouncementSend', error);
      const problem: BusinessError = error as BusinessError;
      throw new Error('局域网端点广播失败（code=' + String(problem.code) + '，message=' + String(problem.message || error) + '）');
    }
  }
  private async receiveAnnouncement(message: socket.SocketMessageInfo): Promise<void> {
    try {
      if (message.message.byteLength > 4096) { return; }
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message));
      const packet: LanAnnouncement = JSON.parse(text) as LanAnnouncement;
      if (!packet || packet.protocol !== 'wuyin-coplay-lan-v1' || typeof packet.deviceId !== 'string' ||
        typeof packet.networkId !== 'string' || !packet.networkId || packet.networkId === this.localNetworkId) { return; }
      if (packet.kind === 'probe') { await this.announce('hello', message.remoteInfo.address); }
      if ((packet.kind === 'hello' || packet.kind === 'probe') && this.dialogOpen) {
        // 没有分布式设备发现时，局域网 UDP 广播就是设备来源；按 deviceId 去重后进入设备列表。
        const lanDevice: DeviceBasicInfo = {
          deviceId: packet.deviceId, networkId: packet.networkId,
          deviceName: '局域网设备-' + packet.deviceId.slice(-4)
        };
        this.addDevice(lanDevice);
        const endpoint: LanEndpoint = { deviceId: packet.deviceId, networkId: packet.networkId,
            address: message.remoteInfo.address, seenAt: Date.now() };
        this.endpoints = this.endpoints.filter((item: LanEndpoint): boolean => item.networkId !== packet.networkId).concat([endpoint]);
      }
    } catch (error) { this.failure('AnnouncementReceive', error); }
  }
  private acceptConnection(connection: socket.TCPSocketConnection): void {
    if (this.incoming.length >= 4) {
      void connection.close().catch((error: Error): void => { this.failure('CloseExcessConnection', error); }); return;
    }
    const pending: IncomingInvitation = { connection: connection, data: new Uint8Array(0), timer: -1, processing: false };
    this.incoming.push(pending);
    pending.timer = setTimeout((): void => { this.closeIncoming(pending); }, 20000);
    connection.on('message', (message: socket.SocketMessageInfo): void => {
      try {
        if (pending.processing || !this.foreground) { return; }
        const part: Uint8Array = new Uint8Array(message.message);
        if (pending.data.length + part.length > CoPlayLanService.MAX_BYTES + 4) { throw new Error('协播载荷超过安全接收上限'); }
        const merged: Uint8Array = new Uint8Array(pending.data.length + part.length);
        merged.set(pending.data); merged.set(part, pending.data.length); pending.data = merged;
        if (merged.length < 4) { return; }
        const size: number = new DataView(merged.buffer).getUint32(0, false);
        if (size === 0 || size > CoPlayLanService.MAX_BYTES) { throw new Error('协播帧长度无效'); }
        if (merged.length < size + 4) { return; }
        if (merged.length !== size + 4) { throw new Error('协播帧长度不一致'); }
        pending.processing = true;
        const raw: string = util.TextDecoder.create('utf-8').decodeToString(merged.subarray(4));
        if (new util.TextEncoder().encodeInto(raw).length !== size) { throw new Error('协播 UTF-8 字节数不一致'); }
        Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Receive] 完整帧已收到，UTF-8字节数=' + size + '，字符串长度=' + raw.length);
        void this.deliver(pending, raw);
      } catch (error) {
        this.failure('ReceiveFrame', error); this.closeIncoming(pending);
      }
    });
    connection.on('close', (): void => { this.forgetIncoming(pending); });
  }
  private async deliver(pending: IncomingInvitation, raw: string): Promise<void> {
    try {
      if (!this.foreground || !this.receiver) { throw new Error('局域网接收端不在前台'); }
      // 业务解析只在 EntryAbility 执行，非法 JSON/字段也必须到达其 Toast 与错误日志分支。
      // 接收回调完成后才确认；页面打开和系统会话实际入会仍是不同阶段。
      await this.receiver(raw);
      await pending.connection.send({ data: 'WY_OK' });
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Receive] 邀请入口处理完成，已回传交付确认；不是系统会话入会确认');
    } catch (error) {
      this.failure('ReceivePayload', error);
      try { await pending.connection.send({ data: 'WY_ERROR' }); } catch (caught) { this.failure('SendFailureAck', caught); }
    } finally { this.closeIncoming(pending); }
  }
  private forgetIncoming(pending: IncomingInvitation): void {
    if (pending.timer !== -1) { clearTimeout(pending.timer); pending.timer = -1; }
    pending.data = new Uint8Array(0); this.incoming = this.incoming.filter((item: IncomingInvitation): boolean => item !== pending);
  }
  private closeIncoming(pending: IncomingInvitation): void {
    this.forgetIncoming(pending);
    try {
      void pending.connection.close().catch((error: Error): void => { this.failure('CloseIncoming', error); });
    } catch (error) { this.failure('DetachIncoming', error); }
  }
  async send(deviceId: string, raw: string): Promise<void> {
    let client: socket.TCPSocket | undefined;
    let timeout: number = -1;
    if (this.sending) { throw new Error('上一份协播邀请尚未发送完成'); }
    this.sending = true;
    try {
      if (!this.dialogOpen || !this.foreground) { throw new Error('局域网邀请弹窗已关闭'); }
      const target: CoPlayLanDevice | undefined = this.devices.find((item: CoPlayLanDevice): boolean => item.deviceId === deviceId);
      if (!target || !target.networkId) { throw new Error('目标尚未完成系统发现或设备授权，请先在系统中完成组网'); }
      // 发送端只校验，不调用带 LAN-Receive 日志的接收解析方法。
      const invitation: CoPlayInvitation = JSON.parse(raw) as CoPlayInvitation;
      CoPlayTransport.validateLanInvitation(invitation);
      CoPlayTransport.logLanMetrics('LAN-Send-Transport', invitation, raw);
      await this.announce('probe', '255.255.255.255');
      await new Promise<void>((resolve): void => { setTimeout(resolve, 600); });
      if (!this.dialogOpen || !this.foreground) { throw new Error('发送已取消'); }
      const endpoint: LanEndpoint | undefined = this.endpoints.find((item: LanEndpoint): boolean =>
        item.networkId === target.networkId && Date.now() - item.seenAt < 30000);
      if (!endpoint) { throw new Error('目标应用未在前台或 WiFi 隔离了设备通信'); }
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(raw);
      if (bytes.length > CoPlayLanService.MAX_BYTES) { throw new Error('协播载荷超过 32 MiB，未截断发送'); }
      const frame: Uint8Array = new Uint8Array(bytes.length + 4);
      new DataView(frame.buffer).setUint32(0, bytes.length, false); frame.set(bytes, 4);
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Send] 目标deviceId=' + deviceId + '，完整 UTF-8 字节数=' + bytes.length);
      const outgoing: socket.TCPSocket = socket.constructTCPSocketInstance(); client = outgoing;
      let acknowledgement: string = '';
      const acknowledged: Promise<void> = new Promise((resolve, reject): void => {
        timeout = setTimeout((): void => { reject(new Error('等待接收端确认超时')); }, 18000);
        outgoing.on('message', (message: socket.SocketMessageInfo): void => {
          try {
            acknowledgement += util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message));
            if (acknowledgement === 'WY_OK') { resolve(); }
            else if (acknowledgement.length >= 8 || !'WY_OK'.startsWith(acknowledgement)) { reject(new Error('接收端拒绝协播数据')); }
          } catch (error) { this.failure('ReceiveAck', error); reject(new Error('确认消息解析失败')); }
        });
        outgoing.on('error', (error: BusinessError): void => { this.failure('OutgoingError', error); reject(new Error('局域网发送连接异常')); });
        outgoing.on('close', (): void => { if (acknowledgement !== 'WY_OK') { reject(new Error('邀请完整确认前连接已关闭')); } });
      });
      // 立即挂接拒绝处理，connect/send 失败时不会产生孤立的未处理拒绝。
      const delivered: Promise<void> = acknowledged.catch((error: Error): void => { throw error; });
      const transmit: Promise<void> = (async (): Promise<void> => {
        await outgoing.connect({ address: { address: endpoint.address, port: CoPlayLanService.PORT, family: 1 }, timeout: 6000 });
        await outgoing.send({ data: frame.buffer });
      })();
      await Promise.all([transmit, delivered]);
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Send] 接收端已确认完整邀请处理完成，非入会成功确认');
    } catch (error) { this.failure('SendPayload', error); throw new Error('向设备下发协播邀请失败'); }
    finally {
      if (timeout !== -1) { clearTimeout(timeout); }
      if (client) {
        try { client.off('message'); client.off('error'); client.off('close'); await client.close(); }
        catch (error) { this.failure('CloseOutgoing', error); }
      }
      this.sending = false;
    }
  }
  suspend(): void {
    this.foreground = false; ++this.receiverRevision; this.closeDialog();
    this.incoming.slice().forEach((item: IncomingInvitation): void => { this.closeIncoming(item); });
    const udp: socket.UDPSocket | undefined = this.udp;
    const server: socket.TCPSocketServer | undefined = this.server;
    this.udp = undefined; this.server = undefined;
    if (udp) {
      try { udp.off('message'); udp.off('error'); void udp.close().catch((error: Error): void => { this.failure('CloseUdp', error); }); }
      catch (error) { this.failure('DetachUdp', error); }
    }
    if (server) {
      try { void server.close().catch((error: Error): void => { this.failure('CloseServer', error); }); }
      catch (error) { this.failure('DetachServer', error); }
    }
  }
  destroy(): void { this.suspend(); this.receiver = undefined; this.context = undefined; }
}

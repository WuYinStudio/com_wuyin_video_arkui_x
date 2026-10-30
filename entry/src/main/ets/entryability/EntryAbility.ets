import { UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { AppConfig } from '../common/AppConfig';
import { NavTabs } from '../common/NavTabs';
import { SocialStore } from '../common/SocialStore';
import { ThemeService } from '../common/ThemeService';
import { AppState } from '../common/AppState';
import { AgreementService } from '../common/AgreementService';
import { ChatAlertService } from '../common/ChatAlertService';
import { ImmersiveService } from '../common/ImmersiveService';
import { ShareService, SharedPlayerParams } from '../common/ShareService';
import { CoPlayInviteHandoff } from '../common/CoPlayInviteHandoff';
import { CoPlayShareService } from '../common/CoPlayShareService';
import { CoPlayLanService } from '../common/CoPlayLanService';
import { CoPlayTransport, CoPlayInvitation } from '../common/CoPlayTransport';
import { parseWzlj, WzljEpisode } from '../common/WzljParser';
import { TencentSDK } from '../common/TencentSdkService';
import { wantAction, wantUri } from '../common/compat/WantCompat';

interface SessionVideoInfo {
  yhm: string;
  feng: string;
  sfeng: string;
  data: string;
  tilie: string;
  wzlj: string;
  genxi: string;
  zyuanuuu: string;
  vodId: string;
}
// 显式继承共用载荷接口，避免 ArkTS 按字段相同进行结构类型匹配。
interface SessionInvitePayload extends CoPlayInvitation {
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
interface MediaSessionInvite extends SessionVideoInfo {
  sessionId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  sharedEpisodeIndex: number;
  sharedPlayProgress: number;
  shareChannel: string;
  fromShare: boolean;
  syncMode: string;
  serverUrl: string;
}

// API26 Beta2 对参数对象使用独立具名接口，不能依赖 SDK 的 Object 类型推断内部字面量。
// 此接口只包含字符串短参数，完整影视资料继续通过本地缓存交接。
interface SessionRouteParameters {
  coPlayEntry: string;
  coPlayPayloadKey: string;
  sessionId: string;
  vodId: string;
  currentMs: string;
  timestamp: string;
  episodeIndex: string;
  syncMode: string;
}

// 收窄 RouterOptions.params，创建选项时也使用此具名类型，避免嵌套对象退化成 Object。
interface SessionPlayerRouteOptions extends router.RouterOptions {
  url: string;
  params: SessionRouteParameters;
}

// 通知栏点击进入聊天室的路由参数（与 ChatRoomPage 读取的字段一致）。
interface ChatNoticeRouteParameters {
  room: string;
  peer: string;
  title: string;
}

interface ChatNoticeRouteOptions extends router.RouterOptions {
  url: string;
  params: ChatNoticeRouteParameters;
}

export default class EntryAbility extends UIAbility {
  private stage?: window.WindowStage;
  private ready: boolean = false;
  private configReady: boolean = false;
  // 普通分享保留原有内存交接；协播长载荷另存应用私有缓存，不进入 Want/页面路由。
  private pendingShare?: SharedPlayerParams;
  private pendingSessionInvite?: MediaSessionInvite;
  private pendingShareError: string = '';
  // 从通知栏点进来时要打开的聊天室（等界面就绪后再跳）。
  private pendingChatRoom: string = '';
  private pendingChatPeer: string = '';
  private agreementTimer: number = -1;
  private shareRevision: number = 0;
  private lanOpening: boolean = false;

  onCreate(want: Want): void {
    // 在 Ability 创建时传入应用标识，不再等到窗口创建后无 appId 地初始化 QQ SDK。
    void this.initializeQQOpenSdk();
    // 分享接收使用真实的 UIAbility Want 回调，不注册不存在的华为分享事件。
    try { void this.captureSharedWant(want, '冷启动'); }
    catch (error) { Logger.error('SCHEME', '读取冷启动分享链接失败：' + String(error)); }
    // 从通知栏点进来：记录目标聊天室，等界面就绪后跳转。
    try { this.captureChatNotification(want); }
    catch (error) { Logger.error('CHAT_NOTIFY', '读取冷启动通知参数失败：' + String(error)); }
  }

  onNewWant(want: Want): void {
    try { void this.captureSharedWant(want, 'onNewWant'); }
    catch (error) { Logger.error('SCHEME', '处理新分享链接失败：' + String(error)); }
    try { this.captureChatNotification(want); }
    catch (error) { Logger.error('CHAT_NOTIFY', '处理通知点击参数失败：' + String(error)); }
  }

  // 通知栏点击会带 chatRoom / chatPeer；这里只搬运参数，界面没就绪就先挂着。
  private captureChatNotification(want: Want): void {
    const parameters = want.parameters;
    if (!parameters) { return; }
    const room = parameters['chatRoom'];
    if (room === undefined || room === null) { return; }
    const roomText: string = String(room);
    if (roomText.length === 0) { return; }
    const peer = parameters['chatPeer'];
    this.pendingChatRoom = roomText;
    this.pendingChatPeer = peer === undefined || peer === null ? '' : String(peer);
    Logger.info('CHAT_NOTIFY', '通知栏点击进入聊天室：' + this.pendingChatRoom);
    this.openPendingChatRoom();
  }

  private openPendingChatRoom(): void {
    const room: string = this.pendingChatRoom;
    if (!this.ready || !this.stage || room.length === 0) { return; }
    const peer: string = this.pendingChatPeer;
    this.pendingChatRoom = '';
    this.pendingChatPeer = '';
    try {
      const parameters: ChatNoticeRouteParameters = {
        room: room,
        peer: peer,
        title: peer.length > 0 ? peer : room
      };
      const options: ChatNoticeRouteOptions = { url: 'pages/ChatRoomPage', params: parameters };
      router.pushUrl(options).catch((problem: BusinessError) => {
        Logger.error('CHAT_NOTIFY', '打开通知对应聊天室失败：' + String(problem.message));
      });
      Logger.info('CHAT_NOTIFY', '已打开通知对应的聊天室：' + room);
    } catch (error) {
      Logger.error('CHAT_NOTIFY', '打开通知对应聊天室异常：' + String(error));
    }
  }

  // DeviceManager 没有消息事件。真实消息由 CoPlayLanService 的前台 TCP 接收监听交付，
  // 系统设备发现仍由 DeviceManager 执行，不伪造 sendMessage/message 接口。
  private readonly lanReceiver = async (raw: string): Promise<void> => {
    let want: Want;
    try {
      const payload: CoPlayInvitation = CoPlayTransport.parseLanInvitation(raw);
      // 跳转前先复用原有影片/选集合法性校验；不得改写 sessionId 原串。
      this.validateSessionInvite(payload);
      // Record 使用字符串字面量键，避免 ArkTS 将其推断为未声明的匿名对象。
      const parameters: Record<string, string> = {
        'mediaSessionInvite': String(raw), 'version': String(payload.version),
          'vodId': String(payload.vodId), 'sessionId': String(payload.sessionId),
          'currentMs': String(payload.currentMs), 'timestamp': String(payload.timestamp),
          'episodeIndex': String(payload.episodeIndex), 'videoJson': String(payload.videoJson), 'syncMode': 'lan'
      };
      const lanWant: Want = {
        bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name,
          parameters: parameters
      };
      if (parameters['sessionId'] !== payload.sessionId) { throw new Error('局域网 sessionId 原串发生变化'); }
      CoPlayTransport.logText('LAN-Want', '显式 Want 的全部 parameters 键值（全部为字符串）', JSON.stringify(lanWant.parameters));
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Want] 校验通过，sessionId原串一致=true，videoJson字符串长度=' + payload.videoJson.length);
      // 显式 Want 仅在本 Ability 内部交接，不以 startAbility 携带超长选集。
      want = lanWant;
    } catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Receive] 数据校验失败，code=' + String(problem.code) +
      '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
      this.showLanNotice('收到非法协播数据');
      throw new Error('收到非法协播数据');
    }
    // 独立等待局域网页面交接，不再调用会吞掉跳转异常的分享排队入口。
    // 华为分享仍使用 captureSharedWant/openSharedPlayer，原解析和协议等待行为不变。
    try {
      await this.openLanSessionPlayer(want);
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Receive] 协播页面已打开；等待播放器确认实际入会，不提前输出入会成功');
    } catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Route] 页面交接失败，code=' + String(problem.code) +
      '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
      this.showLanNotice(error instanceof Error ? error.message : '协播页面打开失败，请重试');
      throw new Error('局域网协播页面交接失败');
    }
  };

  private showLanNotice(message: string): void {
    try {
      if (this.stage && this.ready) {
        this.stage.getMainWindowSync().getUIContext().getPromptAction().showToast({ message: message });
      }
    } catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Receive] 显示提示失败，message=' + String(problem.message) +
      '，堆栈=' + String(problem.stack));
    }
  }

  private async openLanSessionPlayer(want: Want): Promise<void> {
    if (this.lanOpening) { throw new Error('正在处理上一份协播邀请，请稍后重试'); }
    this.lanOpening = true;
    let payloadKey: string = '';
    try {
      const activeStage: window.WindowStage | undefined = this.stage;
      if (!this.ready || !activeStage) { throw new Error('播放器页面尚未就绪，请稍后重新邀请'); }
      // 不绕过用户协议，也不把等待协议误报为页面打开成功。
      if (AppStorage.get<boolean>('agreementAccepted') !== true) {
        throw new Error('请先在接收设备同意用户协议，再重新邀请');
      }
      const invite: MediaSessionInvite | undefined = this.parseSessionInvite(want, '');
      if (!invite) { throw new Error('协播参数丢失，无法入会'); }
      invite.shareChannel = 'lan';
      const revision: number = ++this.shareRevision;
      this.pendingShare = undefined;
      this.pendingSessionInvite = undefined;
      this.pendingShareError = '';
      this.clearAgreementTimer();
      payloadKey = CoPlayInviteHandoff.put(this.context, JSON.stringify(invite));
      const parameters: SessionRouteParameters = this.sessionRouteParameters(invite, payloadKey);
      CoPlayTransport.logText('LAN-Route', '跳转 parameters 全量键值（全部为字符串）', JSON.stringify(parameters));
      for (const key of Object.keys(parameters)) {
        const value: string = this.sessionRouteValue(parameters, key);
        CoPlayTransport.logText('LAN-Route', 'key=' + key + '，类型=' + typeof value + '，字符数=' + value.length, value);
      }
      CoPlayTransport.logText('LAN-Route', '跳转前 sessionId 原串', parameters.sessionId);
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Route] 长载荷已完整缓存，videoJson字符数=' + invite.videoJson.length +
      '，缓存键=' + payloadKey + '，sessionId原串一致=' + (parameters.sessionId === invite.sessionId) +
      '，videoJson未进入系统Want或路由=true');
      const routeOptions: SessionPlayerRouteOptions = { url: 'pages/PlayerPage', params: parameters };
      if (revision !== this.shareRevision || activeStage !== this.stage || !this.ready) {
        throw new Error('协播页面交接已取消，请重新邀请');
      }
      const result = await activeStage.getMainWindowSync().getUIContext().getRouter().pushUrl(
        routeOptions, router.RouterMode.Single);
      if (activeStage !== this.stage || !this.ready) { throw new Error('接收窗口已关闭，请重新邀请'); }
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Route] router.pushUrl完成，返回结果=' + String(result) +
      '，sessionId=' + invite.sessionId + '；此结果仅确认页面交接，不代表系统会话入会成功');
    } catch (error) {
      if (payloadKey) {
        try { CoPlayInviteHandoff.remove(this.context, payloadKey); }
        catch (caught) { Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Route] 清理失败交接缓存异常：' + String(caught)); }
      }
      const problem: BusinessError = error as BusinessError;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Route] 打开播放器失败，code=' + String(problem.code) +
      '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
      throw new Error(error instanceof Error ? error.message : '协播页面打开失败，请重试');
    } finally {
      this.lanOpening = false;
    }
  }

  private async resumeLanReceiver(): Promise<void> {
    try { await CoPlayLanService.shared.resume(this.context, this.lanReceiver); }
    catch (error) {
      const problem: BusinessError = error as BusinessError;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN] 恢复前台接收监听失败，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
    }
  }

  private readInviteValue(want: Want, uri: string, key: string): string | undefined {
    const parameters = want.parameters;
    if (parameters) {
      const value = parameters[key];
      if (value !== undefined && value !== null) {
        if (typeof value !== 'string' && typeof value !== 'number') {
          throw new Error('会话参数类型无效');
        }
        return String(value);
      }
    }
    if (!/^wuyin:\/\/player\/?\?/i.test(uri)) { return undefined; }
    if (uri.length > 524288) { throw new Error('分享链接过长'); }
    const queryStart: number = uri.indexOf('?');
    const fragmentStart: number = uri.indexOf('#', queryStart);
    const query: string = uri.substring(queryStart + 1, fragmentStart < 0 ? uri.length : fragmentStart);
    const pairs: string[] = query.split('&');
    let result: string | undefined = undefined;
    for (let index: number = 0; index < pairs.length; index++) {
      const separator: number = pairs[index].indexOf('=');
      const rawKey: string = separator < 0 ? pairs[index] : pairs[index].substring(0, separator);
      if (decodeURIComponent(rawKey.replace(/\+/g, ' ')) !== key) { continue; }
      if (result !== undefined) { throw new Error('分享参数重复'); }
      const rawValue: string = separator < 0 ? '' : pairs[index].substring(separator + 1);
      result = decodeURIComponent(rawValue.replace(/\+/g, ' '));
    }
    return result;
  }

  private inviteNumber(value: string | undefined, fallback: number): number {
    if (value === undefined) { return fallback; }
    if (!/^[0-9]{1,16}$/.test(value)) { throw new Error('会话数值参数无效'); }
    const parsed: number = Number(value);
    if (!Number.isSafeInteger(parsed)) { throw new Error('会话数值超出范围'); }
    return parsed;
  }

  private inviteText(value: string, limit: number): string {
    return typeof value === 'string' ? value.slice(0, limit) : '';
  }

  private validateSessionInvite(payload: CoPlayInvitation): MediaSessionInvite {
    try {
      if (!payload || Array.isArray(payload) || payload.version !== 1 ||
        typeof payload.vodId !== 'string' || !payload.vodId.trim() ||
        typeof payload.sessionId !== 'string' || !payload.sessionId.trim() ||
        payload.sessionId === 'null' || payload.sessionId === 'undefined' ||
        typeof payload.videoJson !== 'string' || !payload.videoJson.trim() ||
        (payload.syncMode !== undefined && typeof payload.syncMode !== 'string') ||
        typeof payload.currentMs !== 'number' || !Number.isFinite(payload.currentMs) ||
        payload.currentMs < 0 || payload.currentMs > Number.MAX_SAFE_INTEGER ||
        typeof payload.timestamp !== 'number' || !Number.isFinite(payload.timestamp) ||
        payload.timestamp < 0 || payload.timestamp > Number.MAX_SAFE_INTEGER ||
        typeof payload.episodeIndex !== 'number' || !Number.isSafeInteger(payload.episodeIndex) || payload.episodeIndex < 0) {
        throw new Error('协播数据解析失败');
      }
      // 旧版载荷可能没有 syncMode，按当前默认模式 lan 兼容；server 模式需同时携带信令地址。
      const syncMode: string = payload.syncMode && payload.syncMode.trim() ? payload.syncMode.trim() : 'lan';
      if (syncMode !== 'lan' && syncMode !== 'server') { throw new Error('协播同步模式无效'); }
      const serverUrl: string = typeof payload.serverUrl === 'string' ? payload.serverUrl.trim() : '';
      if (syncMode === 'server' && !/^wss?:\/\//i.test(serverUrl)) {
        throw new Error('服务器协播邀请缺少有效信令地址');
      }
      const vodId: string = payload.vodId.trim();
      // 系统 AVSession 的 sessionId 由系统生成，不强制限定为 UUID/字母数字字符集；仅拒绝控制字符与异常长度。
      const sessionId: string = payload.sessionId;
      if (sessionId.length > 256 || /[\u0000-\u001F\u007F]/.test(sessionId)) { throw new Error('协播会话标识无效'); }
      let video: SessionVideoInfo;
      try {
        video = JSON.parse(payload.videoJson) as SessionVideoInfo;
        if (!video || Array.isArray(video) || typeof video.yhm !== 'string' || !video.yhm.trim() ||
          typeof video.wzlj !== 'string') {
          throw new Error('缺少影片名称或选集字段');
        }
        video.wzlj = video.wzlj.replaceAll('\t', '');
        if (!video.wzlj.trim()) { throw new Error('清洗后的选集字段为空'); }
        video.vodId = vodId;
        // 接收端与 PlayerPage 使用同一个解析器，避免过滤空片段后集号发生偏移。
        const episodes: WzljEpisode[] = parseWzlj(video.wzlj);
        if (episodes.length === 0 || payload.episodeIndex >= episodes.length) {
          throw new Error('选集为空或集号超出范围');
        }
        for (let index: number = 0; index < episodes.length; index++) {
          // 外部邀请不能将本地文件路径交给播放器。
          if (!/^https?:\/\/[^\s/]+/i.test(episodes[index].url)) { throw new Error('选集播放地址无效'); }
        }
        Logger.info('MEDIA_SESSION', '协播剧集校验通过，选集数=' + episodes.length + '，目标集号=' + payload.episodeIndex);
      } catch (error) {
        Logger.error('MEDIA_SESSION', '解析或清洗协播 videoJson 失败：' + String(error));
        throw new Error('协播剧集信息损坏');
      }
      const invite: MediaSessionInvite = {
        yhm: this.inviteText(video.yhm, 256),
          feng: this.inviteText(video.feng, 4096), sfeng: this.inviteText(video.sfeng, 4096),
          data: this.inviteText(video.data, 4096), tilie: this.inviteText(video.tilie, 256) || this.inviteText(video.yhm, 256),
          wzlj: video.wzlj, genxi: this.inviteText(video.genxi, 4096), zyuanuuu: this.inviteText(video.zyuanuuu, 4096),
          vodId: vodId, sessionId: sessionId, currentMs: payload.currentMs, timestamp: payload.timestamp,
          // 缓存保留分享中的原始 videoJson 字符串；播放器继续执行原有选集清洗入口。
        episodeIndex: payload.episodeIndex, videoJson: payload.videoJson,
          sharedEpisodeIndex: payload.episodeIndex, sharedPlayProgress: payload.currentMs / 1000,
          shareChannel: 'huawei-share', fromShare: true, syncMode: syncMode, serverUrl: serverUrl
      };
      Logger.info('MEDIA_SESSION', '协播载荷校验通过，sessionId=' + invite.sessionId + '，currentMs=' + invite.currentMs);
      return invite;
    } catch (error) {
      Logger.error('MEDIA_SESSION', '校验协播载荷失败：' + String(error));
      // ArkTS 只抛出 Error，保留各阶段约定的中文错误提示。
      throw new Error(error instanceof Error ? error.message : '协播数据解析失败');
    }
  }

  private parsePackedInvite(content: string): MediaSessionInvite | undefined {
    if (!content.trim().startsWith('{')) { return undefined; }
    let payload: SessionInvitePayload;
    try { payload = JSON.parse(content) as SessionInvitePayload; }
    catch (error) {
      Logger.error('MEDIA_SESSION', '解析协播外层 JSON 失败：' + String(error));
      throw new Error('协播数据解析失败');
    }
    if (!payload || payload.sessionId === undefined) { return undefined; }
    return this.validateSessionInvite(payload);
  }

  private parseSessionInvite(want: Want, uri: string): MediaSessionInvite | undefined {
    const packed: string | undefined = this.readInviteValue(want, uri, 'mediaSessionInvite');
    if (packed !== undefined) {
      const result: MediaSessionInvite | undefined = this.parsePackedInvite(packed);
      if (!result) { throw new Error('协播数据解析失败'); }
      return result;
    }
    const room: string | undefined = this.readInviteValue(want, uri, 'sessionId');
    if (room === undefined) { return undefined; }
    const rawVodId: string | undefined = this.readInviteValue(want, uri, 'vodId');
    const rawCurrent: string | undefined = this.readInviteValue(want, uri, 'currentMs');
    const rawStart: string | undefined = this.readInviteValue(want, uri, 'startTimestamp');
    const rawVideo: string | undefined = this.readInviteValue(want, uri, 'videoJson');
    if (!rawVodId || (rawCurrent === undefined && rawStart === undefined)) { throw new Error('协播数据解析失败'); }
    // 保留原有 Scheme 分享入口，但与华为分享执行相同的局域网协播校验。
    const directVideo: SessionVideoInfo = {
      yhm: this.readInviteValue(want, uri, 'yhm') || '', feng: this.readInviteValue(want, uri, 'feng') || '',
        sfeng: this.readInviteValue(want, uri, 'sfeng') || '', data: this.readInviteValue(want, uri, 'data') || '',
        tilie: this.readInviteValue(want, uri, 'tilie') || '', wzlj: this.readInviteValue(want, uri, 'wzlj') || '',
        genxi: this.readInviteValue(want, uri, 'genxi') || '', zyuanuuu: this.readInviteValue(want, uri, 'zyuanuuu') || '', vodId: rawVodId
    };
    const payload: SessionInvitePayload = {
      version: 1, vodId: rawVodId, sessionId: room,
        currentMs: this.inviteNumber(rawCurrent === undefined ? rawStart : rawCurrent, 0),
        timestamp: this.inviteNumber(this.readInviteValue(want, uri, 'timestamp'), Date.now()),
        episodeIndex: this.inviteNumber(this.readInviteValue(want, uri, 'episodeIndex'), 0),
        videoJson: rawVideo === undefined ? JSON.stringify(directVideo) : rawVideo,
        syncMode: this.readInviteValue(want, uri, 'syncMode'), serverUrl: this.readInviteValue(want, uri, 'serverUrl')
    };
    return this.validateSessionInvite(payload);
  }

  private readHuaweiShareInvite(want: Want): MediaSessionInvite | undefined {
    try {
      // API26 Beta2 使用 parameters，share_data 必须直接是完整原始字符串。
      const shareKey: string = 'ohos.extra.param.key.share_data';
      const parameters = want.parameters;
      const raw = parameters ? parameters[shareKey] : undefined;
      const keys: string[] = parameters ? Object.keys(parameters) : [];
      if (raw === undefined) {
        if (wantAction(want) === 'ohos.want.action.sendData') {
          CoPlayInviteHandoff.logText('ReceiveWant', '分享入口参数键名（未收到指定share_data键）', JSON.stringify(keys));
          for (const key of keys) {
            if (key !== shareKey && key.toLowerCase() === shareKey) {
              Logger.error('CO_PLAYBACK', '【CoPlay][ReceiveWant] share_data参数键大小写错误，实际key=' + key + '，要求key=' + shareKey);
            }
          }
        }
        Logger.info('MEDIA_SESSION', 'Want 不含 ohos.extra.param.key.share_data，跳过华为分享协播接收');
        return undefined;
      }
      CoPlayInviteHandoff.logText('ReceiveWant', '入口 want.parameters 全部键名', JSON.stringify(keys));
      Logger.info('CO_PLAYBACK', '【CoPlay][ReceiveWant] share_data原始类型=' + typeof raw);
      if (typeof raw !== 'string') {
        Logger.error('CO_PLAYBACK', '【CoPlay][ReceiveWant] share_data不是原始字符串，禁止将对象或嵌套参数直接作为协播载荷');
        throw new Error('协播数据解析失败');
      }
      // 优先记录未经改写的原文；分片输出避免把系统单条日志截断误判为载荷截断。
      CoPlayInviteHandoff.logText('ReceiveShare', '华为分享完整原始载荷', raw);
      CoPlayInviteHandoff.logText('ReceiveWant', '入口 want.parameters 全量键值', JSON.stringify(parameters));
      let payload: SessionInvitePayload;
      // ShareKit 的文本记录在部分发送路径会把 JSON 字符串再次 JSON.stringify。
      // 先按标准 JSON 解析一次；若结果是字符串，仅解码这一层传输包装，再解析业务对象。
      // 不接受 data/payload 等任意嵌套对象，避免误把系统封装当作业务载荷。
      let businessRaw: string = raw.trim();
      try {
        let decoded: Object = JSON.parse(businessRaw) as Object;
        if (typeof decoded === 'string') {
          businessRaw = decoded as string;
          decoded = JSON.parse(businessRaw) as Object;
        }
        if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
          throw new Error('分享内容不是协播 JSON 对象');
        }
        payload = decoded as SessionInvitePayload;
      } catch (error) {
        Logger.error('MEDIA_SESSION', '【CoPlay][ParseInvite] 分享文本解析失败，原文长度=' + raw.length + '，错误=' + String(error));
        throw new Error('协播数据解析失败：分享内容不是有效的协播 JSON');
      }
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        Logger.error('CO_PLAYBACK', '【CoPlay][ParseInvite] 顶层必须为协播对象，不接受二次序列化字符串或嵌套解包');
        throw new Error('协播数据解析失败');
      }
      const payloadKeys: string[] = Object.keys(payload);
      CoPlayInviteHandoff.logText('ParseInvite', '顶层全部字段键名', JSON.stringify(payloadKeys));
      for (const key of payloadKeys) {
        if (key !== 'sessionId' && key.toLowerCase() === 'sessionid') {
          Logger.error('CO_PLAYBACK', '【CoPlay][ParseInvite] 会话字段大小写错误，实际key=' + key + '，要求key=sessionId');
        }
      }
      CoPlayInviteHandoff.logText('ParseInvite', 'sessionId，类型=' + typeof payload.sessionId, String(payload.sessionId));
      CoPlayInviteHandoff.logText('ParseInvite', 'vodId，类型=' + typeof payload.vodId, String(payload.vodId));
      CoPlayInviteHandoff.logText('ParseInvite', 'currentMs，类型=' + typeof payload.currentMs, String(payload.currentMs));
      CoPlayInviteHandoff.logText('ParseInvite', 'episodeIndex，类型=' + typeof payload.episodeIndex, String(payload.episodeIndex));
      CoPlayInviteHandoff.logText('ParseInvite', 'videoJson，类型=' + typeof payload.videoJson, String(payload.videoJson));
      const validSessionId: boolean = typeof payload.sessionId === 'string' && payload.sessionId.length > 0 &&
        payload.sessionId !== 'null' && payload.sessionId !== 'undefined';
      Logger.info('MEDIA_SESSION', '【CoPlay][ParseInvite] 顶层解析完成，原文字符数=' + raw.length +
      '，sessionId有效=' + validSessionId + '，sessionId字符数=' +
      (typeof payload.sessionId === 'string' ? payload.sessionId.length : 0) +
      '，videoJson字符数=' + (typeof payload.videoJson === 'string' ? payload.videoJson.length : 0));
      if (!validSessionId) {
        Logger.error('MEDIA_SESSION', '【CoPlay][ParseInvite] 原始分享顶层缺少有效sessionId，尚未进入页面路由');
      }
      return this.validateSessionInvite(payload);
    } catch (error) {
      Logger.error('MEDIA_SESSION', '读取华为分享协播载荷失败：' + String(error));
      throw new Error(error instanceof Error ? error.message : '协播数据解析失败');
    }
  }

  private queueShareError(message: string): void {
    try {
      this.pendingShareError = message;
      this.showPendingShareError();
    } catch (_) { Logger.error('SCHEME', '记录分享错误提示失败'); }
  }

  private showPendingShareError(): void {
    try {
      if (!this.ready || !this.stage || !this.pendingShareError) { return; }
      this.stage.getMainWindowSync().getUIContext().getPromptAction().showToast({ message: this.pendingShareError });
      this.pendingShareError = '';
    } catch (_) { Logger.error('SCHEME', '显示分享错误提示失败'); }
  }

  private async readCoPlayTextFile(uri: string): Promise<string> {
    if (!uri || !/\.txt(?:[?#].*)?$/i.test(uri)) { throw new Error('不是协播同步分享 TXT 文件'); }
    let input: fileIo.File | undefined;
    try {
      // Harmony 文档/文件分享通常将可读文件 URI 放在 Want.uri；沿用项目已使用的 fileIo URI 读取方式。
      input = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(input.fd).size;
      if (size <= 0 || size > 2 * 1024 * 1024) { throw new Error('协播 TXT 文件为空或超过 2MB'); }
      const buffer = new ArrayBuffer(size);
      const count: number = fileIo.readSync(input.fd, buffer);
      if (count !== size) { throw new Error('协播 TXT 文件读取不完整'); }
      const raw: string = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeWithStream(new Uint8Array(buffer)).replace(/^\uFEFF/, '').trim();
      if (!raw) { throw new Error('协播 TXT 文件内容为空'); }
      Logger.info('MEDIA_SESSION', '外部 TXT 协播文件读取成功，字符数=' + raw.length);
      return raw;
    } catch (error) {
      Logger.error('MEDIA_SESSION', '读取外部协播 TXT 文件失败：' + String(error));
      throw new Error('无法读取协播 TXT 文件，请从文件管理器通过“打开方式”重新选择无音影视');
    } finally {
      if (input) { try { fileIo.closeSync(input); } catch (_) { /* 文件可能已由系统关闭 */ } }
    }
  }

  private async captureSharedWant(want: Want, source: string): Promise<void> {
    const revision: number = ++this.shareRevision;
    try {
      const uri: string = wantUri(want) || '';
      // 从文件管理器、聊天软件等通过“打开方式”传入的协播同步分享 TXT，
      // 读取完整文本后复用同一套协播 JSON 校验、缓存和播放器入会流程。
      if (wantAction(want) === 'ohos.want.action.viewData' && /\.txt(?:[?#].*)?$/i.test(uri)) {
        const rawText: string = await this.readCoPlayTextFile(uri);
        if (revision !== this.shareRevision) { return; }
        const normalizedParameters: Record<string, Object> = {};
        normalizedParameters['ohos.extra.param.key.share_data'] = rawText;
        const normalizedWant: Want = { action: 'ohos.want.action.sendData', uri: uri, parameters: normalizedParameters };
        Logger.info('MEDIA_SESSION', '外部打开 TXT 已转入协播分享解析流程，来源=' + source);
        await this.captureSharedWant(normalizedWant, source + '-TXT');
        return;
      }
      // 目标应用被 ShareKit 直接唤起时，分享数据可能封装在 Want 内部，未暴露为 share_data 字符串。
      // 官方 getSharedData(want) 负责解出 SharedRecord；随后才把 record.content 交给业务 JSON 解析器。
      let receiveWant: Want = want;
      const shareKey: string = 'ohos.extra.param.key.share_data';
      const shareParameters = want.parameters;
      const directRaw = shareParameters ? shareParameters[shareKey] : undefined;
      if (wantAction(want) === 'ohos.want.action.sendData' && typeof directRaw !== 'string') {
        const sharedRaw: string | undefined = await CoPlayShareService.readRaw(want);
        if (revision !== this.shareRevision) { return; }
        if (typeof sharedRaw === 'string' && sharedRaw.trim().length > 0) {
          const normalizedParameters: Record<string, Object> = {};
          if (shareParameters) {
            for (const key of Object.keys(shareParameters)) {
              normalizedParameters[key] = shareParameters[key] as Object;
            }
          }
          normalizedParameters[shareKey] = sharedRaw;
          receiveWant = { action: wantAction(want), uri: wantUri(want), parameters: normalizedParameters };
          CoPlayInviteHandoff.logText('ReceiveShare', 'UIAbility 经 ShareKit 提取的原始分享文本', sharedRaw);
        } else {
          Logger.warn('CO_PLAYBACK', '【CoPlay][ReceiveShare] UIAbility 被 sendData 唤起，但 getSharedData 未返回可用文本');
        }
      }
      let invite: MediaSessionInvite | undefined = this.readHuaweiShareInvite(receiveWant);
      // 系统分享缺少指定 key 时直接结束，不猜测其他载荷，也不重放尚在等待协议的旧邀请。
      if (!invite && wantAction(want) === 'ohos.want.action.sendData') {
        this.pendingSessionInvite = undefined;
        this.pendingShare = undefined;
        this.pendingShareError = '';
        this.clearAgreementTimer();
        return;
      }
      if (!invite) { invite = this.parseSessionInvite(want, uri); }
      if (revision !== this.shareRevision) { return; }
      if (invite) {
        this.pendingSessionInvite = invite;
        this.pendingShare = undefined;
        this.pendingShareError = '';
        Logger.info('MEDIA_SESSION', '已校验系统分享会话邀请，来源=' + source + '，模式=' + invite.syncMode + '，接续时间=' + invite.currentMs + '毫秒');
        this.openSharedPlayer();
        return;
      }
      if (!uri) { return; }
      if (!/^wuyin:\/\/player\/?\?/i.test(uri)) {
        Logger.warn('SCHEME', '忽略非播放器 Scheme，来源=' + source);
        return;
      }
      // NFC、华为隔空投递、系统手势传输仍使用原来的普通影视分享入口。
      this.pendingShare = ShareService.parseLink(uri);
      this.pendingSessionInvite = undefined;
      if (!this.pendingShare) {
        Logger.error('SCHEME', '系统唤起参数无效，来源=' + source);
        this.queueShareError('影视分享参数无效，请让发送方重新分享或复制参数');
        return;
      }
      this.pendingShareError = '';
      Logger.info('SCHEME', '已解析系统唤起参数，来源=' + source + '，传输=' +
      this.pendingShare.shareChannel + '，集数=' + (this.pendingShare.sharedEpisodeIndex + 1) +
      '，接续进度=' + this.pendingShare.sharedPlayProgress + '秒');
      this.openSharedPlayer();
    } catch (error) {
      if (revision !== this.shareRevision) { return; }
      this.pendingShare = undefined;
      this.pendingSessionInvite = undefined;
      this.clearAgreementTimer();
      const message: string = error instanceof Error ? error.message : '';
      Logger.error('MEDIA_SESSION', '捕获或校验分享参数失败，来源=' + source + '，原因=' + message);
      if (message === '协播数据解析失败' || message === '仅支持局域网协播' || message === '协播剧集信息损坏') {
        this.queueShareError(message);
      } else {
        this.queueShareError('协同同播入会失败');
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    this.ready = false;
    void this.initializeWindow(windowStage);
  }

  private async initializeQQOpenSdk(): Promise<void> {
    try {
      await TencentSDK.initializeQQOpenSdk(this.context);
      Logger.info('LOGIN_SDK', 'EntryAbility已完成QQ Open SDK初始化，appId=102091604');
    } catch (_) {
      // 不输出 SDK 原始异常，避免授权信息进入日志；初始化失败不能阻断页面加载。
      Logger.error('LOGIN_SDK', 'EntryAbility初始化QQ Open SDK失败，请检查SDK依赖、appId及querySchemes配置');
    }
  }

  private async initializeWindow(windowStage: window.WindowStage): Promise<void> {
    // 先恢复 AppConfig 与 AppState 的持久化配置，再创建页面。
    try {
      if (!this.configReady) {
        await AppConfig.init(this.context);
        await AppState.init(this.context);
        await NavTabs.init(this.context);
        await SocialStore.init(this.context);
        await ThemeService.init(this.context);
        ChatAlertService.init();
        this.configReady = true;
      }
    } catch (error) { Logger.error('GLOBAL_CONFIG', '恢复全局配置失败：' + String(error)); }
    if (this.stage !== windowStage) { return; }
    // 协议状态必须在入口页面和外部分享链接可用前从磁盘恢复。
    try { await AgreementService.restore(this.context); }
    catch (error) {
      Logger.error('UserAgreement', '恢复协议状态失败：' + String(error));
      try { AppStorage.setOrCreate('agreementAccepted', false); }
      catch (storageError) { Logger.error('UserAgreement', '重置协议状态失败：' + String(storageError)); }
    }
    if (this.stage !== windowStage) { return; }
    // 所有页面及路由共用透明系统栏；毛玻璃开关只控制应用组件材质。
    try { await ImmersiveService.attach(windowStage.getMainWindowSync()); }
    catch (error) { Logger.error('GLOBAL_IMMERSIVE', '准备应用窗口失败：' + String(error)); }
    if (this.stage !== windowStage) { return; }
    try {
      windowStage.loadContent('pages/Index', (error) => {
        try {
          if (this.stage !== windowStage) { return; }
          if (error && error.code) { Logger.error('SCHEME', '加载应用入口失败'); return; }
          this.ready = true;
          this.showPendingShareError();
          this.openSharedPlayer();
          // 冷启动时从通知栏点进来的聊天室，等首页加载完再跳。
          this.openPendingChatRoom();
          void ImmersiveService.apply(true);
        } catch (_) { Logger.error('SCHEME', '处理入口加载回调失败'); }
      });
    } catch (error) { Logger.error('SCHEME', '加载应用入口异常：' + String(error)); }
  }

  // 系统深浅色变化时实时刷新全局主题；“跟随系统”模式无需重启应用。
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      const isDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppState.syncSystemTheme(isDark);
      Logger.info('APP_THEME', '系统深浅色更新：' + (isDark ? '深色' : '浅色'));
    } catch (error) {
      Logger.error('APP_THEME', '同步系统深浅色失败：' + String(error));
    }
  }

  onForeground(): void {
    // 只恢复被动消息接收，不在前台回调中启动设备扫描或主动请求权限。
    void this.resumeLanReceiver();
    // 前台：应用内弹窗 + 提示音，同时清掉后台遗留的通知栏提醒。
    try { ChatAlertService.enterForeground(); }
    catch (error) { Logger.error('CHAT_ALERT', '前台启动聊天提醒失败：' + String(error)); }
    // 从通知栏点进来的聊天室，等界面就绪后补跳转。
    this.openPendingChatRoom();
    // 切回前台仍保持透明导航区域。
    try {
      void ImmersiveService.apply(true);
      this.showPendingShareError();
      this.openSharedPlayer();
    } catch (error) { Logger.error('GLOBAL_IMMERSIVE', '恢复前台沉浸状态失败：' + String(error)); }
  }

  onBackground(): void {
    try { CoPlayLanService.shared.suspend(); }
    catch (error) { Logger.error('CO_PLAYBACK', '【CoPlay][LAN] 后台停止扫描和消息监听失败：' + String(error)); }
    // 后台：开关打开时继续轮询并发系统通知栏提醒，否则停止轮询。
    try { ChatAlertService.enterBackground(); }
    catch (error) { Logger.error('CHAT_ALERT', '后台切换聊天提醒模式失败：' + String(error)); }
  }

  onDestroy(): void {
    try { CoPlayLanService.shared.destroy(); }
    catch (error) { Logger.error('CO_PLAYBACK', '【CoPlay][LAN] 销毁邀请接收服务失败：' + String(error)); }
    try { ChatAlertService.shutdown(); }
    catch (error) { Logger.error('CHAT_ALERT', '销毁聊天提醒服务失败：' + String(error)); }
  }

  onWindowStageDestroy(): void {
    try { CoPlayLanService.shared.suspend(); }
    catch (error) { Logger.error('CO_PLAYBACK', '【CoPlay][LAN] 窗口销毁停止扫描失败：' + String(error)); }
    this.ready = false;
    this.stage = undefined;
    ++this.shareRevision;
    this.pendingShare = undefined;
    this.pendingSessionInvite = undefined;
    this.pendingShareError = '';
    this.clearAgreementTimer();
    try { ShareService.clearPlayerHandoff(); }
    catch (_) { Logger.warn('SCHEME', '清理系统唤起临时参数失败'); }
    try { ImmersiveService.detach(); }
    catch (error) { Logger.error('GLOBAL_IMMERSIVE', '清理窗口监听失败：' + String(error)); }
  }

  private clearAgreementTimer(): void {
    try {
      if (this.agreementTimer !== -1) { clearInterval(this.agreementTimer); this.agreementTimer = -1; }
    } catch (_) { Logger.warn('SCHEME', '清理协议等待任务失败'); }
  }

  private waitForAgreement(): void {
    try {
      if (this.agreementTimer !== -1) { return; }
      Logger.info('SCHEME', '分享链接等待用户同意协议');
      this.agreementTimer = setInterval(() => {
        try {
          if (!this.ready || !this.stage || (!this.pendingShare && !this.pendingSessionInvite)) {
            this.clearAgreementTimer(); return;
          }
          if (AppStorage.get<boolean>('agreementAccepted') === true) {
            this.clearAgreementTimer(); this.openSharedPlayer();
          }
        } catch (_) { this.clearAgreementTimer(); Logger.error('SCHEME', '等待协议确认失败'); }
      }, 500);
    } catch (_) { Logger.error('SCHEME', '创建协议等待任务失败'); }
  }

  private sessionRouteParameters(invite: MediaSessionInvite, payloadKey: string): SessionRouteParameters {
    // 只交付页面真正读取的短字段；不展开 invite，不传入对象、videoJson、wzlj 或冗余选集副本。
    // 数值 0 使用 String 保留，禁止用 truthy 默认值误伤从零开始的进度和第零集索引。
    // 独立声明并显式标注具名接口，不在 RouterOptions.params 的 Object 上下文中创建字面量。
    const parameters: SessionRouteParameters = {
      coPlayEntry: '1',
        coPlayPayloadKey: String(payloadKey),
        sessionId: String(invite.sessionId),
        vodId: String(invite.vodId),
        currentMs: String(invite.currentMs),
        timestamp: String(invite.timestamp),
        episodeIndex: String(invite.episodeIndex),
        syncMode: String(invite.syncMode)
    };
    for (const key of Object.keys(parameters)) {
      const value: string = this.sessionRouteValue(parameters, key);
      if (typeof value !== 'string' || !value ||
        value === 'null' || value === 'undefined') {
        Logger.error('CO_PLAYBACK', '【CoPlay][RouteParams] 跳转前参数无效，key=' + key + '，类型=' + typeof value);
        throw new Error('协播参数丢失，无法入会');
      }
    }
    if (parameters.sessionId !== invite.sessionId) {
      throw new Error('协播sessionId在路由构造时发生变化');
    }
    return parameters;
  }

  private sessionRouteValue(parameters: SessionRouteParameters, key: string): string {
    // 具名接口按显式字段读取，避免再引入 Record 强转或 ArkTS 不支持的动态属性访问。
    switch (key) {
      case 'coPlayEntry': return parameters.coPlayEntry;
      case 'coPlayPayloadKey': return parameters.coPlayPayloadKey;
      case 'sessionId': return parameters.sessionId;
      case 'vodId': return parameters.vodId;
      case 'currentMs': return parameters.currentMs;
      case 'timestamp': return parameters.timestamp;
      case 'episodeIndex': return parameters.episodeIndex;
      case 'syncMode': return parameters.syncMode;
      default: throw new Error('协播路由参数键名无效');
    }
  }

  private async openSessionPlayer(invite: MediaSessionInvite): Promise<void> {
    const revision: number = this.shareRevision;
    const activeStage: window.WindowStage | undefined = this.stage;
    let payloadKey: string = '';
    try {
      if (!this.ready || !activeStage) { return; }
      // API26 Beta2 避免将超长 videoJson/wzlj 再塞入系统 Want 或页面路由。
      // 先完整落盘并校验回读，失败不跳转；sessionId 单独原样交付，不从缓存兜底掩盖丢参。
      payloadKey = CoPlayInviteHandoff.put(this.context, JSON.stringify(invite));
      const parameters: SessionRouteParameters = this.sessionRouteParameters(invite, payloadKey);
      const serialized: string = JSON.stringify(parameters);
      CoPlayInviteHandoff.logText('RouteParams', '跳转前 parameters 全量键值（所有值均为字符串）', serialized);
      CoPlayInviteHandoff.logText('RouteParams', '跳转前 parameters 全部键名', JSON.stringify(Object.keys(parameters)));
      for (const key of Object.keys(parameters)) {
        const value: string = this.sessionRouteValue(parameters, key);
        CoPlayInviteHandoff.logText('RouteParams', 'key=' + key + '，类型=' + typeof value + '，字符数=' + value.length, value);
      }
      CoPlayInviteHandoff.logText('RouteParams', '跳转前 sessionId', parameters.sessionId);
      Logger.info('MEDIA_SESSION', '【CoPlay][RouteParams] sessionId存在=' + Object.keys(parameters).includes('sessionId') +
      '，sessionId原串一致=' + (parameters.sessionId === invite.sessionId) +
      '，短参数总字符数=' + serialized.length +
      '，videoJson未进入路由=true，wzlj未进入路由=true，缓存videoJson字符数=' + invite.videoJson.length);
      Logger.info('MEDIA_SESSION', '【CoPlay][RouteParams] 长 videoJson 已改走本地缓存，不进入 Want/路由；沿用 router.pushUrl 显式交接，无二次 startAbility');
      // 选项与内部参数分别由具名接口约束；传入 SDK 重载前已完成显式类型检查。
      const routeOptions: SessionPlayerRouteOptions = {
        url: 'pages/PlayerPage',
          params: parameters
      };
      // 复用已有 PlayerPage，由 onPageShow 消费新参数；避免多个页面同时占用共享 AVPlayer。
      const result = await activeStage.getMainWindowSync().getUIContext().getRouter().pushUrl(
        routeOptions, router.RouterMode.Single);
      Logger.info('MEDIA_SESSION', '【CoPlay][RouteParams] router.pushUrl 返回结果=' + String(result) + '，sessionId=' + invite.sessionId + '，载荷缓存键=' + payloadKey);
    } catch (error) {
      if (payloadKey) { CoPlayInviteHandoff.remove(this.context, payloadKey); }
      const problem: BusinessError = error as BusinessError;
      Logger.error('MEDIA_SESSION', '【CoPlay][RouteParams] 打开同播邀请失败，交接方式=router.pushUrl，code=' + String(problem.code) + '，message=' + String(problem.message) + '，异常=' + String(error));
      // 旧路由请求失败不能清除更新的 Want，也不能向已销毁的窗口投递提示。
      if (revision !== this.shareRevision || activeStage !== this.stage) { return; }
      this.pendingSessionInvite = undefined;
      this.queueShareError(problem.message === '协播参数丢失，无法入会' ? problem.message : '协同同播入会失败');
    }
  }

  private openSharedPlayer(): void {
    try {
      if (!this.ready || !this.stage || (!this.pendingShare && !this.pendingSessionInvite)) { return; }
      // 外部链接不能绕过免责声明；同意后继续处理原链接。
      if (AppStorage.get<boolean>('agreementAccepted') !== true) { this.waitForAgreement(); return; }
      this.clearAgreementTimer();
      if (this.pendingSessionInvite) {
        const invite: MediaSessionInvite = this.pendingSessionInvite;
        this.pendingSessionInvite = undefined;
        void this.openSessionPlayer(invite);
        return;
      }
      if (!this.pendingShare) { return; }
      const value: SharedPlayerParams = this.pendingShare;
      this.pendingShare = undefined;
      // 普通影视分享仍由 Index 统一判断新建或复用，保留原交接流程。
      ShareService.publishPlayerHandoff(value);
      Logger.info('SCHEME', '已将系统分享参数交给 Index，集数=' + (value.sharedEpisodeIndex + 1) +
      '，接续进度=' + value.sharedPlayProgress + '秒');
    } catch (_) { Logger.error('SCHEME', '检查协议或交接分享参数失败'); }
  }
}

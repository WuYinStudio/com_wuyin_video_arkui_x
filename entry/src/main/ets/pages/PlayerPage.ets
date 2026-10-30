import { media } from '@kit.MediaKit';
import { window, router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState, PlayerImmersiveConfig, RecordVideoSource } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { DownloadService, DownloadRecord, DownloadState } from '../common/DownloadService';
import { LocalPlaybackService } from '../common/LocalPlaybackService';
import { Logger } from '../common/Logger';
import { ShareService, SharedPlayerRouteParams } from '../common/ShareService';
import { CoPlayInviteHandoff, CoPlayCachedInvite } from '../common/CoPlayInviteHandoff';
import { parseWzlj, WzljEpisode } from '../common/WzljParser';
import { Ui } from '../common/Ui';
import { PlayerGestureLayer } from '../components/PlayerGestureLayer';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { MediaSessionDialog, MediaSessionService, MediaSessionCommand, MediaSessionView } from '../components/MediaSessionDialog';
import { Quest3ControlService, Quest3CoPlayPayload, Quest3StatePacket } from '../common/Quest3ControlService';
import { DanmakuService, DanmakuItem, DanmakuSettings, DanmakuSearchResult } from '../common/DanmakuService';
import { MediaSniffer, SniffResult } from '../common/MediaSniffer';
import { PlatformApi } from '../common/compat/PlatformApi';
import { AccountApi } from '../common/AccountApi';
import { CommunityApi } from '../common/CommunityApi';
import { SocialStore } from '../common/SocialStore';
import { buildVideoCard, VideoShareArgs } from '../common/VideoCardBuilder';

export interface SearchVideoItem extends RecordVideoSource { yhm: string; feng: string; sfeng: string; data: string; tilie: string; wzlj: string; genxi: string; zyuanuuu: string; vodId: string; resourceType?: string; localPath?: string; }
export interface EpisodeItem { title: string; playUrl: string; }
export interface PlayerRoute { title: string; sourceUrl: string; }
export interface PlayerEpisode { title: string; routes: PlayerRoute[]; }
export interface SearchPlayerParams { yhm: string; feng: string; sfeng: string; data: string; tilie: string; wzlj: string; genxi: string; zyuanuuu: string; vodId: string; resourceType?: string; localPath?: string; }
interface PlayerShareRoute extends SearchVideoItem {
  /** 直播源标记：LiveTvPage 传 '1'，失败时不显示「播放异常」。 */
  live?: string;
  sharedEpisodeIndex?: number;
  sharedEpisodeTitle?: string;
  sharedPlayProgress?: number;
  sharedPlayUrl?: string;
  shareChannel?: string;
  shareRequestId?: number;
  fromShare?: boolean;
  sessionId?: string;
  currentMs?: number;
  timestamp?: number;
  episodeIndex?: number;
  videoJson?: string;
  syncMode?: string;
  coPlayEntry?: string;
  coPlayPayloadKey?: string;
}
// 仅在协播路由边界接受字符串数值，内部播放及普通分享继续使用原有数值类型。
interface CoPlayIncomingRoute {
  currentMs?: string | number;
  timestamp?: string | number;
  episodeIndex?: string | number;
  sharedEpisodeIndex?: string | number;
}
interface DanmakuRankedResult { result: DanmakuSearchResult; score: number; }
interface WindowRestoreState { orientation: window.Orientation; }

interface ScreenshotCreationConfig { title: string; fileNameExtension: string; photoType: photoAccessHelper.PhotoType; }
interface PlayerWatchRecord { vodId: string; selectIndex: number; playSec: number; videoName: string; }
enum PlayerDownloadPhase { READY = 'ready', SNIFFING = 'sniffing', DOWNLOADING = 'downloading', COMPLETED = 'completed' }

class PlayerEngine {
  private static shared?: media.AVPlayer;
  static async acquire(): Promise<media.AVPlayer> { if (!PlayerEngine.shared) { PlayerEngine.shared = await media.createAVPlayer(); } return PlayerEngine.shared; }
  static async release(): Promise<void> { const instance = PlayerEngine.shared; PlayerEngine.shared = undefined; if (instance) { await instance.release(); } }
}

@Entry
@Component
struct PlayerPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  // 与全局持久化配置共用同一 StorageLink，材质开关不改变系统栏沉浸状态。
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('onImmersiveChanged') private darkTheme: boolean = true;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @StorageLink('immersiveLeftInset') private leftSafeInset: number = 0;
  @StorageLink('immersiveRightInset') private rightSafeInset: number = 0;
  @StorageLink('favoriteVersion') @Watch('refreshFavorite') private favoriteRevision: number = 0;
  @StorageLink('downloadVersion') @Watch('refreshDownload') private downloadRevision: number = 0;
  // 只监听 Index 交接的本次系统请求，不持久化，也不从桌面启动读取分享资料。
  @StorageLink('playerSharedResumeVersion') @Watch('onSharedResumeChanged') private sharedResumeVersion: number = 0;
  @State private viewportWidth: number = 360;
  @State private viewportHeight: number = 640;
  @State private playerWidth: number = 360;
  @State private playerHeight: number = 360 * 6 / 19;
  @State private playerContainerHeight: number = 360 * 3 / 4;
  @State private topBarSpan: number = 0;
  @State private fullScreen: boolean = false;
  @State private controlsVisible: boolean = true;
  @State private danmakuEnabled: boolean = true;
  @State private danmakuPanelVisible: boolean = false;
  @State private danmakuInput: string = '';
  @State private danmakuMessages: string[] = [];
  @State private danmakuItems: DanmakuItem[] = [];
  @State private activeDanmakuItems: DanmakuItem[] = [];
  private lastDanmakuWindowSecond: number = -1;
  @State private danmakuFontSize: number = 20;
  @State private danmakuOpacity: number = 0.92;
  @State private danmakuSpeed: number = 1;
  @State private danmakuDensity: number = 70;
  @State private danmakuSyncEnabled: boolean = true;
  @State private danmakuSearchKeyword: string = '';
  @State private danmakuSearchResults: DanmakuSearchResult[] = [];
  @State private danmakuStatus: string = '支持在线搜索与导入本地弹幕文件';
  @State private danmakuLoading: boolean = false;
  @State private playing: boolean = false;
  @State private loading: boolean = false;
  @State private currentMs: number = 0;
  @State private durationMs: number = 0;
  @State private volumeValue: number = 1;
  @State private speedIndex: number = 1;
  @State private speedMenuVisible: boolean = false;
  @State private episodeMenuVisible: boolean = false;
  @State private episodeIndex: number = 0;
  @State private routeIndex: number = 0;
  @State private favoriteSelected: boolean = false;
  @State private favoriteScale: number = 1;
  @State private favoriteBusy: boolean = false;
  @State private errorText: string = '';
  @State private episodes: PlayerEpisode[] = [];
  @State private parsedEpisodes: EpisodeItem[] = [];
  @State private episodesExpanded: boolean = false;
  @State private episodesDescending: boolean = false;
  // 每行按钮 48vp，行间留白 8vp；展开高度跟随完整换行内容，不限制集数行数。
  @State private episodeContentTall: number = 56;
  @State private episodeViewportSpan: number = 0;
  private episodeScroller: Scroller = new Scroller();
  @State private missingParams: boolean = false;
  // 四种可视状态：待下载、嗅探中、下载中、已下载；暂停/失败显示可继续或重试的待下载状态。
  @State private downloadButtonState: PlayerDownloadPhase = PlayerDownloadPhase.READY;
  @State private downloadLabel: string = '下载本集';
  @State private downloadDetail: string = '';
  @State private downloadPercent: number = 0;
  @State private downloadSpeed: number = 0;
  @State private downloadProblem: boolean = false;
  @State private downloadCommandPending: boolean = false;
  @State private downloadControlPending: boolean = false;
  @State private ratioMenuVisible: boolean = false;
  @State private selectedRatio: string = '原画';
  @State private sessionDialogVisible: boolean = false;
  @State private receiverLocked: boolean = false;
  @State private isSlaveMode: boolean = false;
  @State private brightnessShade: number = 0;
  private sessionId: string = '';
  private joiningSession: boolean = false;
  private sessionService: MediaSessionService = new MediaSessionService();
  private quest3Service: Quest3ControlService = new Quest3ControlService();
  private quest3SessionId: string = 'quest3-' + String(Date.now());
  private sessionRevision: number = 0;
  private sessionSeekToleranceMs: number = 800;
  private pendingSessionId: string = '';
  // 仅用于同一路由去重，不用于恢复或自动重入会话。
  private consumedSessionInvite: string = '';
  private sessionNoticeAt: number = 0;
  private sessionViewCallback = (view: MediaSessionView): void => {
    try {
      if (this.disposed) { return; }
      let locked: boolean = false;
      if (view.active) {
        this.joiningSession = false;
        this.sessionId = view.sessionId;
        locked = !view.isHost;
      } else if (view.sessionId) {
        this.sessionId = view.sessionId;
        locked = view.mode === 'lan' || this.joiningSession;
      } else if (this.joiningSession && this.sessionId) {
        // join 内部先释放旧控制器；等待确认期间不能因此开放本地操作。
        locked = true;
      } else {
        this.clearSlaveState();
      }
      if (this.receiverLocked !== locked || this.isSlaveMode !== locked) { ++this.sessionRevision; }
      this.receiverLocked = locked;
      this.isSlaveMode = locked;
      if (!locked && !view.sessionId) { this.sessionId = ''; this.pendingSessionId = ''; }
      Logger.info('MEDIA_SESSION', '播放器会话状态，会话=' + this.sessionId + '，从机=' + this.isSlaveMode + '，已确认=' + view.active);
    } catch (error) { this.failSession('刷新播放器同播锁定失败', error); }
  };
  private fullScreenTransitionPending: boolean = false;
  private downloadRequestVersion: number = 0;
  private downloadPauseRequested: boolean = false;
  private pendingDownloadVideoId: string = '';
  private pendingDownloadEpisode: number = 0;
  // 尚未创建共享任务时的校验异常也保留在当前集的界面上，不因 finally 刷新被清空。
  private downloadFailureVideoId: string = '';
  private downloadFailureEpisode: number = 0;
  private downloadFailureText: string = '';
  private lastDownloadStatus: string = '';
  private videoWidth: number = 0;
  private videoHeight: number = 0;
  private video?: SearchVideoItem;
  // 分享参数只存在于本次系统唤起的路由及页面内存，不读写桌面启动缓存。
  private consumedShareParams?: PlayerShareRoute;
  private consumedShareRequestId: number = 0;
  private handoffPageVisible: boolean = false;
  private playbackEntryVersion: number = 0;
  private sharedSourceEpisodeIndex: number = -1;
  private pendingSharedProgressMs?: number;
  private sharedSeekIssued: boolean = false;
  // 保持同一个函数实例，页面退出时只注销自己注册的读取器，NFC 无需修改接口。
  private playbackProgressReader = (videoId: string, episodeIndex: number): number => {
    try {
      const activeIndex: number = this.sharedSourceEpisodeIndex >= 0 ? this.sharedSourceEpisodeIndex : this.episodeIndex;
      if (this.disposed || !this.video || this.video.vodId !== videoId || activeIndex !== episodeIndex) { return 0; }
      return Number.isFinite(this.currentMs) ? Math.max(0, this.currentMs / 1000) : 0;
    } catch (error) {
      Logger.warn('SHARE_RESUME', '读取 NFC 当前播放进度失败：' + String(error));
      return 0;
    }
  };
  // 本地文件句柄及合并缓存必须保留到 AVPlayer reset/release 完成。
  private localSourceFile?: fileIo.File;
  private preparedLocalPath: string = '';
  private sourceRequestVersion: number = 0;
  private sourceChangePending: boolean = false;
  private playbackResourceType: string = 'online';
  private playbackSourcePath: string = '';
  private resumeDecisionPending: boolean = false;
  private surfaceReady: boolean = false;
  private initializationStarted: boolean = false;
  private surfaceController: XComponentController = new XComponentController();
  private player?: media.AVPlayer;
  /** 直播源：失败时不弹「播放异常」错误卡，只提示可切换线路。 */
  private liveMode: boolean = false;
  @State private shareGroupVisible: boolean = false;
  @State private shareRooms: string[] = [];
  @State private shareFriends: string[] = [];
  private appWindow?: window.Window;
  private listeningWindow?: window.Window;
  private windowSizeCallback = (size: window.Size): void => {
    if (this.disposed) { return; }
    try {
      // 系统尺寸只在 API 边界换算，页面布局与安全间距均使用 vp。
      this.resizePlayer(this.getUIContext().px2vp(size.width), this.getUIContext().px2vp(size.height));
      ImmersiveService.publishSafeArea();
    } catch (error) { Logger.error('PLAYER_IMMERSIVE', '更新窗口安全布局失败：' + String(error)); }
  };
  private restoreState?: WindowRestoreState;
  private portraitWidth: number = 360;
  private portraitHeight: number = 640;
  private hideTimer: number = -1;
  private recordTimer: number = -1;
  private favoriteTimer: number = -1;
  private disposed: boolean = false;
  private completed: boolean = false;
  private seeking: boolean = false;
  private hovered: boolean = false;
  private switching: boolean = false;
  private pendingSource: string = '';
  private resumeMs: number = 0;
  private speedValues: media.PlaybackSpeed[] = [media.PlaybackSpeed.SPEED_FORWARD_0_75_X, media.PlaybackSpeed.SPEED_FORWARD_1_00_X, media.PlaybackSpeed.SPEED_FORWARD_1_25_X, media.PlaybackSpeed.SPEED_FORWARD_1_75_X, media.PlaybackSpeed.SPEED_FORWARD_2_00_X];
  private speedLabels: string[] = ['0.75×', '1.0×', '1.25×', '1.75×', '2.0×'];
  private ratioOptions: string[] = ['原画', '铺满屏幕', '16:9', '4:3', '21:9'];

  // 同播只在原播放器的控制入口外增加校验，不替换 AVPlayer 或 XComponent。
  private clearSlaveState(): void {
    try {
      ++this.sessionRevision;
      this.joiningSession = false; this.isSlaveMode = false; this.receiverLocked = false;
      this.sessionId = ''; this.pendingSessionId = ''; this.seeking = false;
    } catch (error) { Logger.error('MEDIA_SESSION', '清空从机会话状态失败：' + String(error)); }
  }
  private failSession(stage: string, error: Object): void {
    try {
      Logger.error('MEDIA_SESSION', stage + '：' + String(error));
      const involved: boolean = this.isSlaveMode || this.receiverLocked || !!this.sessionId || !!this.pendingSessionId;
      this.clearSlaveState();
      if (!involved) { return; }
      this.pendingSharedProgressMs = undefined; this.sharedSeekIssued = false; this.resumeMs = 0;
      void this.sessionService.release().catch((caught: Error): void => {
        Logger.error('MEDIA_SESSION', '失败后释放会话失败：' + String(caught));
      });
      this.toast('协同同播入会失败');
    } catch (caught) { Logger.error('MEDIA_SESSION', '协播异常兜底失败：' + String(caught)); }
  }
  private configureSession(): void {
    try {
      this.clearSlaveState();
      this.sessionDialogVisible = false; this.brightnessShade = 0; this.consumedSessionInvite = '';
      this.sessionService.configure(this.context(), (): MediaSessionCommand => this.sessionSnapshot(),
        async (command: MediaSessionCommand): Promise<void> => { await this.consumeSessionCommand(command); },
        (message: string): void => {
        try {
          if (this.disposed) { return; }
          if (message === '协同同播入会失败' || message === '协同播放会话已结束') {
            this.clearSlaveState();
            this.pendingSharedProgressMs = undefined; this.sharedSeekIssued = false;
          }
          this.toast(message);
        } catch (error) { this.failSession('处理协播会话通知失败', error); }
      });
      this.sessionService.subscribe(this.sessionViewCallback);
    } catch (error) { this.failSession('初始化播放器同播能力失败', error); }
  }
  private sessionSnapshot(): MediaSessionCommand {
    return { action: 'state', deviceId: '', currentMs: Math.max(0, this.currentMs), timestamp: Date.now(),
        episodeIndex: this.episodeIndex, speedIndex: this.speedIndex, playing: this.playing,
        routeIndex: this.routeIndex, ratio: this.selectedRatio,
        danmaku: this.danmakuSyncEnabled ? JSON.stringify(this.danmakuItems.filter((item: DanmakuItem) => item.timeSec >= this.currentMs / 1000 - 2).slice(0, 160)) : undefined };
  }
  private sessionControlBlocked(): boolean {
    if (!this.isSlaveMode && !this.receiverLocked) { return false; }
    try {
      if (Date.now() - this.sessionNoticeAt > 1500) {
        this.sessionNoticeAt = Date.now(); this.toast('协同同播中，仅主控设备可控制播放');
      }
    } catch (error) { Logger.warn('MEDIA_SESSION', '提示接收端控制锁定失败：' + String(error)); }
    return true;
  }
  private updateSessionSource(): void {
    try {
      const video: SearchVideoItem | undefined = this.video;
      if (!video) { return; }
      this.sessionService.setSource(video.vodId, video.tilie || video.yhm || '无音影视', JSON.stringify(video));
    } catch (error) {
      Logger.error('MEDIA_SESSION', '准备同播影视资料失败：' + String(error));
      if (this.isSlaveMode) { this.failSession('准备从机影视资料失败', error); }
    }
  }
  // ArkUI V1 的真实生命周期为 aboutToAppear，由其调用此入口，避免声明无效生命周期后不执行。
  onWillAppear(): void {
    try {
      const params: PlayerShareRoute | undefined = router.getParams() as PlayerShareRoute | undefined;
      // 直播频道由 LiveTvPage 以 live='1' 打开：失败时不显示「播放异常」。
      this.liveMode = params !== undefined && params.live === '1';
      CoPlayInviteHandoff.logText('PageParams', 'PlayerPage onWillAppear 全部路由键值', JSON.stringify(params) || 'undefined');
      CoPlayInviteHandoff.logText('PageParams', '全部参数键名', JSON.stringify(params ? Object.keys(params) : []));
      const receivedSessionId: string = params && typeof params.sessionId === 'string' ? params.sessionId : '';
      CoPlayInviteHandoff.logText('PageParams', '单独读取sessionId变量，原始类型=' + (params ? typeof params.sessionId : 'undefined'), receivedSessionId);
    } catch (error) { Logger.error('CO_PLAYBACK', '打印播放页路由参数失败：' + String(error)); }
  }
  private sessionRouteNumber(value: string | number | undefined, field: string): number {
    if (typeof value !== 'number' && (typeof value !== 'string' || !value.trim())) {
      throw new Error('同播路由缺少有效数值参数：' + field);
    }
    const parsed: number = Number(value);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > Number.MAX_SAFE_INTEGER) {
      throw new Error('同播路由数值参数无效：' + field);
    }
    return parsed;
  }
  private applySessionRoute(params: PlayerShareRoute, reusePage: boolean): boolean {
    const receivedSessionId: string = typeof params.sessionId === 'string' ? params.sessionId : '';
    const validSessionId: boolean = receivedSessionId.length > 0 && receivedSessionId !== 'null' && receivedSessionId !== 'undefined';
    if (!validSessionId) {
      const collaborative: boolean = params.coPlayEntry === '1' || params.coPlayPayloadKey !== undefined || Object.keys(params).includes('sessionId');
      if (!collaborative) { return false; }
      Logger.error('CO_PLAYBACK', '【路由未收到sessionId参数】协播入口缺少有效sessionId，原始类型=' + typeof params.sessionId + '，原始值=' + String(params.sessionId));
      const missingKey: string = 'missing:' + String(params.coPlayPayloadKey || '') + ':' + String(params.timestamp || '') + ':' + String(params.sessionId);
      if (this.consumedSessionInvite !== missingKey) {
        this.consumedSessionInvite = missingKey;
        this.toast('协播参数丢失，无法入会');
      }
      if (!reusePage) { this.missingParams = true; this.resumeDecisionPending = false; }
      return true;
    }
    const payloadKey: string = typeof params.coPlayPayloadKey === 'string' ? params.coPlayPayloadKey : '';
    const key: string = receivedSessionId + ':' + String(params.timestamp || 0) + ':' +
    String(params.currentMs) + ':' + String(params.episodeIndex === undefined ? params.sharedEpisodeIndex : params.episodeIndex) + ':' + payloadKey;
    if (key === this.consumedSessionInvite) { return true; }
    this.consumedSessionInvite = key;
    let receivedVideo: SearchVideoItem | undefined;
    try {
      this.joiningSession = true; this.isSlaveMode = true; this.receiverLocked = true;
      // sessionId 保留路由原串，不 trim、不裁剪，也不从缓存补值来掩盖丢参。
      this.sessionId = receivedSessionId;
      CoPlayInviteHandoff.logText('PageParams', '进入协播分支的sessionId原始变量', this.sessionId);
      ++this.sessionRevision;
      const raw: CoPlayIncomingRoute = params as CoPlayIncomingRoute;
      const currentMs: number = this.sessionRouteNumber(raw.currentMs, 'currentMs');
      if (this.sessionId.length > 256 || /[\u0000-\u001F\u007F]/.test(this.sessionId) ||
        typeof params.vodId !== 'string' || !params.vodId.trim()) {
        throw new Error('同播路由的会话、影片或进度无效');
      }
      if (params.syncMode !== undefined && params.syncMode !== 'lan') { throw new Error('仅支持局域网协播'); }
      const incomingIndex: number = this.sessionRouteNumber(raw.episodeIndex === undefined ? raw.sharedEpisodeIndex : raw.episodeIndex, 'episodeIndex');
      if (!Number.isInteger(incomingIndex)) { throw new Error('同播路由的选集索引无效'); }
      let videoJson: string | undefined = params.videoJson;
      if (params.coPlayEntry === '1' && !payloadKey) { throw new Error('协播路由缺少临时载荷键'); }
      if (payloadKey) {
        const cached: CoPlayCachedInvite = CoPlayInviteHandoff.read(this.context(), payloadKey);
        const timestamp: number = this.sessionRouteNumber(raw.timestamp, 'timestamp');
        if (cached.sessionId !== this.sessionId || cached.vodId !== params.vodId ||
          cached.currentMs !== currentMs || cached.episodeIndex !== incomingIndex || cached.timestamp !== timestamp || cached.syncMode !== 'lan') {
          throw new Error('协播路由与临时载荷不一致');
        }
        // 仅恢复到局部变量，禁止把超长 videoJson 写回 router 参数对象。
        videoJson = cached.videoJson;
        Logger.info('CO_PLAYBACK', '【CoPlay][PageParams] 缓存与路由sessionId一致=true，sessionId=' + this.sessionId +
        '，currentMs=' + currentMs + '，episodeIndex=' + incomingIndex + '，videoJson字符数=' + videoJson.length);
      }
      // 完整 videoJson 来自本次邀请缓存；旧版直传邀请仍走原兼容入口。
      const decoded: SearchVideoItem = typeof videoJson === 'string' ? JSON.parse(videoJson) as SearchVideoItem : params;
      if (!decoded || typeof decoded.yhm !== 'string' || !decoded.yhm.trim() ||
        typeof decoded.wzlj !== 'string' || !decoded.wzlj.trim()) { throw new Error('协播剧集信息损坏'); }
      const cleaned: string = decoded.wzlj.replaceAll('\t', '');
      receivedVideo = {
        yhm: decoded.yhm, feng: typeof decoded.feng === 'string' ? decoded.feng : '',
          sfeng: typeof decoded.sfeng === 'string' ? decoded.sfeng : '',
          data: typeof decoded.data === 'string' ? decoded.data : '',
          tilie: typeof decoded.tilie === 'string' && decoded.tilie ? decoded.tilie : decoded.yhm,
          wzlj: cleaned, genxi: typeof decoded.genxi === 'string' ? decoded.genxi : '',
          zyuanuuu: typeof decoded.zyuanuuu === 'string' ? decoded.zyuanuuu : '',
          vodId: params.vodId, resourceType: 'online', localPath: ''
      };
      const parsed: WzljEpisode[] = parseWzlj(cleaned);
      if (parsed.length === 0 || incomingIndex >= parsed.length) { throw new Error('协播选集为空或集数越界'); }
      const received: PlayerShareRoute = {
        yhm: receivedVideo.yhm, feng: receivedVideo.feng, sfeng: receivedVideo.sfeng, data: receivedVideo.data,
          tilie: receivedVideo.tilie, wzlj: receivedVideo.wzlj, genxi: receivedVideo.genxi,
          zyuanuuu: receivedVideo.zyuanuuu, vodId: receivedVideo.vodId,
          sharedEpisodeIndex: incomingIndex, sharedPlayProgress: Math.floor(currentMs) / 1000,
          shareChannel: '协同同播', fromShare: true, resourceType: 'online', localPath: ''
      };
      this.pendingSessionId = this.sessionId;
      Logger.info('CO_PLAYBACK', '协播路由校验通过，会话=' + this.sessionId + '，集数索引=' + incomingIndex +
      '，定位毫秒=' + currentMs + '，有效选集=' + parsed.length);
      // 复用原选集渲染、切源及 prepared 后 seek 链路，不替换普通播放逻辑。
      return this.applySharedPlayback(received, reusePage);
    } catch (error) {
      this.failSession('处理协播路由失败', error);
      if (reusePage) { return true; }
      if (receivedVideo) {
        // 影视信息可用时降级为普通播放；不再加入失败的会话，也不强制应用其进度。
        params.yhm = receivedVideo.yhm; params.feng = receivedVideo.feng; params.sfeng = receivedVideo.sfeng;
        params.data = receivedVideo.data; params.tilie = receivedVideo.tilie; params.wzlj = receivedVideo.wzlj;
        params.genxi = receivedVideo.genxi; params.zyuanuuu = receivedVideo.zyuanuuu;
        params.resourceType = 'online'; params.localPath = '';
        params.sharedEpisodeIndex = undefined; params.sharedPlayProgress = undefined;
        params.sharedPlayUrl = undefined; params.fromShare = undefined;
      }
      return false;
    } finally {
      // 本次路由已消费，复用页面由上方去重，不重复读取或保留超长临时文件。
      if (payloadKey) { CoPlayInviteHandoff.remove(this.context(), payloadKey); }
    }
  }
  private async joinPendingSession(): Promise<void> {
    try {
      if (this.disposed || !this.video || !this.pendingSessionId) { return; }
      const room: string = this.pendingSessionId; this.pendingSessionId = '';
      this.joiningSession = true;
      this.updateSessionSource();
      if (!this.isSlaveMode || this.sessionId !== room) { return; }
      Logger.info('MEDIA_SESSION', '开始注册邀请会话监听并入会，会话=' + room);
      await this.sessionService.join(room);
      if (this.disposed || this.sessionId !== room) { return; }
      const view: MediaSessionView = this.sessionService.snapshot();
      if (!view.sessionId) { throw new Error('系统会话入会未建立'); }
      // 成功提示由服务收到主控成员确认后发出，不以 createController 返回冒充入会成功。
    } catch (error) { this.failSession('按分享邀请加入会话失败', error); }
  }
  private openMediaSession(): void {
    try {
      if (this.disposed || !this.video) { return; }
      if (this.playbackResourceType === 'local') { this.toast('本地离线文件无法通过会话链接共享，请使用网络影视资源'); return; }
      this.closeControlMenus(); this.reveal(); this.updateSessionSource(); this.sessionDialogVisible = true;
    } catch (error) { Logger.error('MEDIA_SESSION', '打开同播弹窗失败：' + String(error)); this.toast('同播弹窗打开失败'); }
  }
  private async publishSessionState(): Promise<void> {
    try { if (!this.disposed) { await this.sessionService.publish(); } }
    catch (error) { Logger.error('MEDIA_SESSION', '同步播放器状态失败：' + String(error)); }
  }
  private async consumeSessionCommand(command: MediaSessionCommand): Promise<void> {
    const revision: number = this.sessionRevision;
    try {
      if (this.disposed || !this.isSlaveMode || !this.receiverLocked) { return; }
      if (!Number.isInteger(command.episodeIndex) || command.episodeIndex < 0 || command.episodeIndex >= this.episodes.length ||
        !Number.isFinite(command.currentMs) || command.currentMs < 0 || !Number.isFinite(command.timestamp) ||
        !Number.isInteger(command.speedIndex) || command.speedIndex < 0 || command.speedIndex >= this.speedValues.length) {
        throw new Error('主控同步指令包含无效时间、倍速或集数');
      }
      const targetEpisode: number = command.episodeIndex;
      if (this.danmakuSyncEnabled && command.danmaku && command.danmaku.length <= 160000) {
        try {
          const incoming = JSON.parse(command.danmaku) as DanmakuItem[];
          if (Array.isArray(incoming) && incoming.length <= 160 && incoming.every((item: DanmakuItem) => typeof item.text === 'string' && item.text.length <= 120 && Number.isFinite(item.timeSec) && item.timeSec >= 0)) { this.danmakuItems = incoming; }
        } catch (error) { Logger.warn('DANMAKU', '忽略无效的协播弹幕包：' + String(error)); }
      }
      Logger.info('MEDIA_SESSION', '接收主控同步，会话=' + this.sessionId + '，集数索引=' + targetEpisode);
      if (targetEpisode !== this.episodeIndex) { this.selectEpisode(targetEpisode, true); }
      // 等待原切源流程进入可控制状态；退出、移交或断开会使旧任务立即失效。
      let ready: boolean = false;
      for (let attempt: number = 0; attempt < 300; attempt++) {
        if (this.disposed || !this.receiverLocked || revision !== this.sessionRevision) { return; }
        const instance: media.AVPlayer | undefined = this.player;
        if (!this.switching && !this.sourceChangePending && instance &&
          (instance.state === 'prepared' || instance.state === 'playing' || instance.state === 'paused' || instance.state === 'completed')) { ready = true; break; }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
      }
      const instance: media.AVPlayer | undefined = this.player;
      if (this.disposed || !this.receiverLocked || revision !== this.sessionRevision) { return; }
      if (!ready || !instance) { throw new Error('等待协播播放源准备超时'); }
      if (this.speedIndex !== command.speedIndex) { instance.setSpeed(this.speedValues[command.speedIndex]); this.speedIndex = command.speedIndex; }
      if (command.routeIndex !== undefined && Number.isInteger(command.routeIndex) &&
        command.routeIndex >= 0 && command.routeIndex < (this.episodes[this.episodeIndex]?.routes.length || 0) &&
        command.routeIndex !== this.routeIndex) {
        this.routeIndex = command.routeIndex;
        await this.selectSource(true);
        // 线路重载会重置 AVPlayer，等待现有播放器准备流程结束后再对齐进度。
        for (let attempt: number = 0; attempt < 200; attempt++) {
          if (this.disposed || !this.receiverLocked || revision !== this.sessionRevision) { return; }
          const current: media.AVPlayer | undefined = this.player;
          if (!this.switching && !this.sourceChangePending && current &&
            (current.state === 'prepared' || current.state === 'playing' || current.state === 'paused')) { break; }
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
        }
      }
      if (command.ratio !== undefined && ['原画', '铺满屏幕'].includes(command.ratio) && command.ratio !== this.selectedRatio) {
        this.selectRatio(command.ratio);
      }
      const elapsed: number = command.playing ? Math.max(0, Math.min(15000, Date.now() - command.timestamp)) : 0;
      const requested: number = Math.floor(command.currentMs + elapsed * [0.75, 1, 1.25, 1.75, 2][command.speedIndex]);
      const target: number = Math.max(0, this.durationMs > 0 ? Math.min(this.durationMs - 1, requested) : requested);
      const difference: number = Math.abs(this.currentMs - target);
      if (difference >= this.sessionSeekToleranceMs) {
        instance.seek(target, PlatformApi.seekModeClosest()); this.currentMs = target;
        Logger.debug('MEDIA_SESSION', '按主控时间戳校准播放进度，误差毫秒=' + Math.floor(difference));
      }
      if (command.playing && instance.state !== 'playing') { await instance.play(); }
      else if (!command.playing && instance.state === 'playing') { await instance.pause(); }
    } catch (error) { if (!this.disposed && revision === this.sessionRevision) { this.failSession('应用主控播放指令失败', error); } }
  }
  private revealFromGesture(): void {
    try { this.closeControlMenus(); this.reveal(); }
    catch (error) { Logger.error('PLAYER_GESTURE', '显示控制栏失败：' + String(error)); }
  }
  private async seekFromGesture(targetMs: number): Promise<void> {
    try {
      if (this.disposed || this.sessionControlBlocked() || !this.player || this.durationMs <= 0) { return; }
      const target: number = Math.max(0, Math.min(this.durationMs - 1, Math.floor(targetMs)));
      this.player.seek(target, PlatformApi.seekModeClosest()); this.currentMs = target;
      this.reveal(); void this.saveWatchRecord(); await this.publishSessionState();
    } catch (error) { Logger.error('PLAYER_GESTURE', '手势定位进度失败：' + String(error)); }
  }
  private volumeFromGesture(level: number): void {
    try {
      if (this.disposed || this.sessionControlBlocked() || !Number.isFinite(level)) { return; }
      this.volumeValue = Math.max(0, Math.min(1, level)); this.player?.setVolume(this.volumeValue);
    } catch (error) { Logger.error('PLAYER_GESTURE', '手势调节音量失败：' + String(error)); }
  }
  private onImmersiveChanged(): void {
    if (this.disposed) { return; }
    try { void ImmersiveService.apply(); }
    catch (error) { Logger.error('PLAYER_IMMERSIVE', '同步全局材质及主题失败：' + String(error)); }
  }
  private restoreImmersiveWindow(): void {
    try { void ImmersiveService.apply(true); ImmersiveService.publishSafeArea(); }
    catch (error) { Logger.error('PLAYER_IMMERSIVE', '恢复全局沉浸失败：' + String(error)); }
  }
  private safeInset(value: number): number { return Number.isFinite(value) ? Math.max(0, value) : 0; }
  private safeBottom(): number { return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16; }
  private parseEpisodes(wzlj: string): EpisodeItem[] {
    try {
      if (this.isSlaveMode) {
        const result: EpisodeItem[] = parseWzlj(wzlj).map((episode: WzljEpisode): EpisodeItem => {
          return { title: episode.title, playUrl: episode.url };
        });
        if (result.length === 0) { throw new Error('协播选集解析结果为空'); }
        this.parsedEpisodes = result;
        return result;
      }
      const cleaned: string = wzlj.replace(/\t/g, '').trim().replace(/\s{2,}/g, ' ');
      const entries: string[] = cleaned ? cleaned.split('#').map((entry: string): string => entry.trim()).filter((entry: string): boolean => entry.length > 0) : [];
      const result: EpisodeItem[] = [];
      for (let index = 0; index < entries.length; index++) {
        const entry: string = entries[index]; const separator: number = entry.indexOf('$');
        if (separator <= 0 || separator >= entry.length - 1) { continue; }
        const title: string = entry.substring(0, separator).trim(); const playUrl: string = entry.substring(separator + 1).trim();
        if (title && playUrl) { const parsedEpisode: EpisodeItem = { title: title, playUrl: playUrl }; result.push(parsedEpisode); }
      }
      this.parsedEpisodes = result; return result;
    } catch (error) {
      this.parsedEpisodes = [];
      if (this.isSlaveMode) { this.failSession('解析协播选集失败', error); }
      return [];
    }
  }
  private clearSharedResume(requestId: number): void {
    try {
      const pending: SharedPlayerRouteParams | undefined = AppStorage.get<SharedPlayerRouteParams>('playerSharedResumeParams');
      if (!pending || pending.shareRequestId !== requestId) { return; }
      AppStorage.delete('playerSharedResumeParams');
      AppStorage.setOrCreate<number>('playerSharedResumeVersion', 0);
    } catch (error) { Logger.warn('SHARE_RESUME', '清空播放器临时分享包失败：' + String(error)); }
  }
  private onSharedResumeChanged(): void {
    try {
      // 隐藏在路由栈中的播放器不抢占交接；Index 返回目标页后由 onPageShow 消费。
      if (this.disposed || !this.handoffPageVisible) { return; }
      const pending: SharedPlayerRouteParams | undefined = AppStorage.get<SharedPlayerRouteParams>('playerSharedResumeParams');
      if (!pending) { return; }
      const requestId: number = pending.shareRequestId;
      if (!Number.isInteger(requestId) || requestId <= 0) {
        this.clearSharedResume(requestId);
        Logger.error('SHARE_RESUME', '忽略无效的系统接续请求序号');
        return;
      }
      if (requestId === this.consumedShareRequestId) {
        this.clearSharedResume(requestId);
        return;
      }
      // 复制白名单参数，避免播放器清理标记时修改 Index 仍用于记录日志的请求对象。
      const received: PlayerShareRoute = {
        yhm: pending.yhm, feng: pending.feng, sfeng: pending.sfeng, data: pending.data,
          tilie: pending.tilie, wzlj: pending.wzlj, genxi: pending.genxi, zyuanuuu: pending.zyuanuuu,
          vodId: pending.vodId, sharedEpisodeIndex: pending.sharedEpisodeIndex,
          sharedEpisodeTitle: pending.sharedEpisodeTitle, sharedPlayUrl: pending.sharedPlayUrl,
          sharedPlayProgress: pending.sharedPlayProgress, shareChannel: pending.shareChannel,
          shareRequestId: requestId, fromShare: true
      };
      // 在切源之前取走内存包；版本归零产生的监听不会重复应用同一请求。
      this.clearSharedResume(requestId);
      Logger.info('SHARE_RESUME', '播放页接收 Index 的复用请求，序号=' + requestId +
      '，接续进度=' + pending.sharedPlayProgress + '秒');
      this.applySharedPlayback(received, true);
    } catch (error) { Logger.error('SHARE_RESUME', '消费复用播放页的接续参数失败：' + String(error)); }
  }
  private clearSharedRoute(params: PlayerShareRoute): void {
    try {
      // 清除接续标记，不清除播放器仍需使用的影视资料与选集链接。
      if (typeof params.shareRequestId === 'number' && params.shareRequestId > 0) {
        this.consumedShareRequestId = params.shareRequestId;
      }
      params.sharedEpisodeIndex = undefined;
      params.sharedEpisodeTitle = undefined;
      params.sharedPlayProgress = undefined;
      params.sharedPlayUrl = undefined;
      params.shareChannel = undefined;
      params.shareRequestId = undefined;
      params.fromShare = undefined;
      this.consumedShareParams = params;
    } catch (error) { Logger.warn('PLAYER_HANDOFF', '清理已消费的分享参数失败：' + String(error)); }
  }
  private applySharedPlayback(params: PlayerShareRoute, reusePage: boolean): boolean {
    if (params.sharedEpisodeIndex === undefined && params.sharedPlayProgress === undefined) { return false; }
    if (params === this.consumedShareParams) { return true; }
    try {
      if (typeof params.shareRequestId === 'number' && params.shareRequestId > 0 &&
        params.shareRequestId === this.consumedShareRequestId) {
        this.clearSharedRoute(params);
        return true;
      }
      const incomingIndex: number = params.sharedEpisodeIndex === undefined ? 0 : params.sharedEpisodeIndex;
      const incomingProgress: number = params.sharedPlayProgress === undefined ? 0 : params.sharedPlayProgress;
      if (!Number.isInteger(incomingIndex) || incomingIndex < 0 ||
        !Number.isFinite(incomingProgress) || incomingProgress < 0 || incomingProgress > Number.MAX_SAFE_INTEGER / 1000) {
        throw new Error('系统分享的分集索引或播放进度无效');
      }
      if (typeof params.vodId !== 'string' || !params.vodId.trim() || typeof params.wzlj !== 'string') {
        throw new Error('系统分享缺少影视资料或选集链接');
      }
      const parsed: EpisodeItem[] = this.parseEpisodes(params.wzlj);
      if (parsed.length === 0) { throw new Error('系统分享没有可播放的选集'); }
      // 仅携带当前集的 Scheme 保留发送端原始索引；不伪造其余剧集的资源。
      const selectedIndex: number = parsed.length === 1 ? 0 : incomingIndex;
      if (selectedIndex >= parsed.length) { throw new Error('系统分享的选集索引超出资源范围'); }
      const sharedUrl: string = typeof params.sharedPlayUrl === 'string' && params.sharedPlayUrl.trim() ?
        params.sharedPlayUrl.trim() : parsed[selectedIndex].playUrl;
      if (!/^https?:\/\//i.test(sharedUrl)) { throw new Error('系统分享不是有效的网络播放链接'); }
      parsed[selectedIndex].playUrl = sharedUrl;
      const receivedVideo: SearchVideoItem = {
        yhm: params.yhm || params.tilie || '未命名影片', feng: params.feng || '', sfeng: params.sfeng || '',
          data: params.data || '', tilie: params.tilie || params.yhm || '未命名影片', wzlj: params.wzlj,
          genxi: params.genxi || '', zyuanuuu: params.zyuanuuu || '', vodId: params.vodId,
          resourceType: 'online', localPath: ''
      };
      const channel: string = params.shareChannel || '系统分享';
      const entryVersion: number = ++this.playbackEntryVersion;
      this.clearSharedRoute(params);
      if (reusePage) {
        // 失效旧页面的异步准备结果，但不取消 DownloadService 已接管的后台任务。
        this.downloadRequestVersion++;
        this.sourceRequestVersion++;
        this.pendingSource = '';
        this.sourceChangePending = false;
        this.downloadCommandPending = false;
        this.downloadControlPending = false;
        this.downloadPauseRequested = false;
        this.pendingDownloadVideoId = '';
        this.pendingDownloadEpisode = 0;
        this.downloadFailureVideoId = '';
        this.downloadFailureEpisode = 0;
        this.downloadFailureText = '';
        this.lastDownloadStatus = '';
      }
      this.video = receivedVideo;
      this.sharedSourceEpisodeIndex = parsed.length === 1 ? incomingIndex : -1;
      this.playbackResourceType = 'online';
      this.playbackSourcePath = sharedUrl;
      this.completed = false;
      this.missingParams = false;
      this.errorText = '';
      this.seeking = false;
      this.pendingSharedProgressMs = Math.floor(incomingProgress * 1000);
      this.sharedSeekIssued = false;
      this.episodes = parsed.map((episode: EpisodeItem): PlayerEpisode => {
        const route: PlayerRoute = { title: '默认线路', sourceUrl: episode.playUrl };
        const playerEpisode: PlayerEpisode = { title: episode.title, routes: [route] };
        return playerEpisode;
      });
      this.resetEpisodeScroll();
      this.refreshFavorite();
      this.refreshDownload();
      void this.initializeDownloads();
      void this.checkNetwork();
      // 显式系统分享进度优先，仅本次接续跳过历史提示；普通入口保留原续播流程。
      this.choosePlayback(selectedIndex, incomingProgress);
      this.startRecordTimer();
      Logger.info('PLAYER_HANDOFF', (reusePage ? '复用播放页' : '新建播放页') + '，来源=' + channel +
      '，发送端集数=' + (incomingIndex + 1) + '，接续进度=' + incomingProgress + '秒，参数已消费');
      if (reusePage && this.player) { void this.continueSharedSource(entryVersion, incomingProgress); }
      this.updateSessionSource(); void this.joinPendingSession();
      return true;
    } catch (error) {
      const collaborative: boolean = this.isSlaveMode || !!this.sessionId || !!this.pendingSessionId;
      this.clearSharedRoute(params);
      this.pendingSharedProgressMs = undefined;
      this.sharedSeekIssued = false;
      Logger.error('PLAYER_HANDOFF', '处理分享进度接续失败：' + String(error));
      if (collaborative) {
        this.failSession('准备协播选集或进度失败', error);
        if (!reusePage) {
          // 已校验的影视资料交还普通入口，保留原播放记录及选集业务。
          this.consumedShareParams = undefined;
          return false;
        }
      } else { this.pendingSessionId = ''; this.toast('影视接续参数无效，请让发送方重新分享'); }
      if (!reusePage) { this.missingParams = true; this.resumeDecisionPending = false; }
      return true;
    }
  }
  private async continueSharedSource(entryVersion: number, progress: number): Promise<void> {
    try {
      // 复用原播放器切源入口；等待旧切换释放锁，避免其回调覆盖新分享进度。
      while (this.switching && !this.disposed && entryVersion === this.playbackEntryVersion) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 30); });
      }
      if (this.disposed || entryVersion !== this.playbackEntryVersion || !this.player) { return; }
      this.currentMs = Math.floor(progress * 1000);
      this.resumeMs = this.currentMs;
      this.pendingSharedProgressMs = this.currentMs;
      this.sharedSeekIssued = false;
      await this.selectSource(true);
    } catch (error) {
      Logger.error('PLAYER_HANDOFF', '复用播放页切源接续失败：' + String(error));
      if (!this.disposed && entryVersion === this.playbackEntryVersion) {
        if (this.isSlaveMode) { this.failSession('复用页面协播切源失败', error); }
        else { this.toast('接续播放失败，请重试分享'); }
      }
    }
  }
  private receiveSharedRoute(): void {
    if (this.disposed) { return; }
    try {
      // Single 模式复用页面也记录本次短路由，便于与 EntryAbility 跳转前日志对照。
      this.onWillAppear();
      const params: PlayerShareRoute | undefined = router.getParams() as PlayerShareRoute | undefined;
      if (params) {
        if (this.applySessionRoute(params, true)) { return; }
        this.applySharedPlayback(params, true);
      }
    } catch (error) {
      Logger.error('PLAYER_HANDOFF', '读取复用播放页的分享参数失败：' + String(error));
      if (this.isSlaveMode) { this.failSession('读取复用页面协播参数失败', error); }
    }
  }
  private traceSharedPlayback(state: string): void {
    try {
      if (this.pendingSharedProgressMs === undefined) { return; }
      if (state === 'prepared') {
        // 只调整本次分享的定位目标，普通续播和播放器内核的 seek 入口保持不变。
        const requestedMs: number = this.pendingSharedProgressMs;
        const mediaDuration: number = this.player ? this.player.duration : 0;
        const targetMs: number = Number.isFinite(mediaDuration) && mediaDuration > 0 ?
          Math.min(requestedMs, Math.max(0, Math.floor(mediaDuration) - 1)) : requestedMs;
        this.resumeMs = targetMs;
        this.pendingSharedProgressMs = targetMs;
        this.sharedSeekIssued = targetMs > 0 || this.isSlaveMode;
        Logger.info('PLAYER_HANDOFF', '分享资源已准备，使用原续播定位入口，请求=' + requestedMs +
        '毫秒，目标=' + targetMs + '毫秒');
      } else if (state === 'playing' && this.pendingSharedProgressMs === 0 && !this.sharedSeekIssued) {
        this.pendingSharedProgressMs = undefined;
        this.sharedSeekIssued = false;
        Logger.info('PLAYER_HANDOFF', '分享资源已从零进度开始播放');
      }
    } catch (error) {
      Logger.warn('PLAYER_HANDOFF', '记录分享接续状态失败：' + String(error));
      if (this.isSlaveMode) { this.failSession('准备协播定位失败', error); }
    }
  }
  aboutToAppear(): void {
    this.playbackEntryVersion++;
    this.consumedShareParams = undefined;
    this.consumedShareRequestId = 0;
    this.handoffPageVisible = false;
    this.sharedSourceEpisodeIndex = -1;
    this.pendingSharedProgressMs = undefined;
    this.sharedSeekIssued = false;
    this.downloadRequestVersion++;
    this.sourceRequestVersion++;
    this.sourceChangePending = false;
    this.pendingSource = '';
    this.episodeMenuVisible = false;
    this.fullScreenTransitionPending = false;
    this.disposed = false; this.completed = false; this.missingParams = false; this.surfaceReady = false; this.initializationStarted = false; this.resumeDecisionPending = true; this.video = undefined; this.episodeIndex = 0; this.routeIndex = 0; this.currentMs = 0; this.resumeMs = 0; this.episodes = []; this.selectedRatio = '原画'; this.ratioMenuVisible = false; this.speedMenuVisible = false; this.videoWidth = 0; this.videoHeight = 0; this.favoriteScale = 1; this.favoriteBusy = false; this.downloadCommandPending = false; this.downloadControlPending = false; this.downloadPauseRequested = false; this.pendingDownloadVideoId = ''; this.pendingDownloadEpisode = 0; this.downloadFailureVideoId = ''; this.downloadFailureEpisode = 0; this.downloadFailureText = ''; this.downloadProblem = false; this.lastDownloadStatus = ''; this.updatePlayerLayout();
    this.configureSession();
    void this.restoreDanmakuSettings();
    this.onWillAppear();
    this.playbackResourceType = 'online'; this.playbackSourcePath = '';
    this.episodesExpanded = false; this.episodesDescending = false; this.episodeContentTall = 56; this.episodeViewportSpan = 0;
    this.restoreImmersiveWindow();
    void this.listenWindowSize();
    try { ShareService.setPlaybackProgressReader(this.playbackProgressReader); }
    catch (error) { Logger.error('SHARE_RESUME', '注册统一发送进度读取器失败：' + String(error)); }
    try {
      const params: PlayerShareRoute | undefined = router.getParams() as PlayerShareRoute | undefined;
      if (params && this.applySessionRoute(params, false)) { return; }
      if (params && this.applySharedPlayback(params, false)) { return; }
      if (!params || typeof params.vodId !== 'string' || !params.vodId.trim() || typeof params.wzlj !== 'string') { this.missingParams = true; this.resumeDecisionPending = false; return; }
      this.video = params;
      const parsed = this.parseEpisodes(params.wzlj);
      if (parsed.length === 0) { this.resumeDecisionPending = false; this.toast('当前影片尚未配置可播放资源'); return; }
      const routeLocalPath: string = typeof params.localPath === 'string' ? params.localPath.trim() : '';
      this.playbackResourceType = params.resourceType === 'local' || routeLocalPath.length > 0 || this.isLocalAddress(parsed[0].playUrl) ? 'local' : 'online';
      this.playbackSourcePath = this.playbackResourceType === 'local' && routeLocalPath ? routeLocalPath : parsed[0].playUrl;
      Logger.info('PLAYER_SOURCE', '进入播放页，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath));
      this.refreshFavorite(); this.refreshDownload();
      // 离线入口不启动网络检查、下载初始化、远程解析或鉴权请求。
      if (this.playbackResourceType !== 'local') { void this.initializeDownloads(); }
      this.episodes = parsed.map((episode: EpisodeItem): PlayerEpisode => {
        const route: PlayerRoute = { title: '默认线路', sourceUrl: this.playbackResourceType === 'local' && routeLocalPath && parsed.length === 1 ? routeLocalPath : episode.playUrl };
        const playerEpisode: PlayerEpisode = { title: episode.title, routes: [route] };
        return playerEpisode;
      });
      void this.loadWatchRecord(params.vodId); this.startRecordTimer();
      if (this.playbackResourceType !== 'local') { void this.checkNetwork(); }
      this.updateSessionSource(); void this.joinPendingSession();
    } catch (error) {
      if (this.isSlaveMode) { this.failSession('读取协播播放参数失败', error); }
      Logger.error('PLAYER_SOURCE', '读取播放参数失败，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) + '：' + String(error));
      this.missingParams = true; this.resumeDecisionPending = false; this.video = undefined; this.episodes = [];
    }
  }
  onPageShow(): void {
    try {
      this.handoffPageVisible = true;
      this.restoreImmersiveWindow();
      this.receiveSharedRoute();
      this.onSharedResumeChanged();
      this.refreshFavorite();
      this.refreshDownload();
      ShareService.setPlaybackProgressReader(this.playbackProgressReader);
    } catch (error) { Logger.error('SHARE_RESUME', '播放页显示时恢复接续状态失败：' + String(error)); }
  }
  onPageHide(): void {
    try { this.handoffPageVisible = false; }
    catch (error) { Logger.warn('SHARE_RESUME', '记录播放页隐藏状态失败：' + String(error)); }
  }
  private async initializeDownloads(): Promise<void> {
    if (this.playbackResourceType === 'local') { return; }
    const pageVersion: number = this.downloadRequestVersion;
    try { await DownloadService.init(this.context()); if (this.isDownloadRequestCurrent(pageVersion)) { this.refreshDownload(); } }
    catch (error) { Logger.error('PLAYER_DOWNLOAD', '初始化下载服务失败：' + String(error)); }
  }
  private isDownloadRequestCurrent(version: number): boolean { return !this.disposed && version === this.downloadRequestVersion; }
  private refreshFavorite(): void {
    if (this.disposed) { return; }
    try { this.favoriteSelected = !!this.video && AppState.isVideoFavorite(this.video); }
    catch (error) { Logger.error('PLAYER_FAVORITE', '刷新收藏状态失败：' + String(error)); }
  }
  private toggleFavorite(): void {
    const video = this.video;
    if (!video || !video.vodId.trim()) { this.toast('缺少影片资料，无法收藏'); return; }
    if (this.favoriteBusy || this.disposed) { return; }
    this.favoriteBusy = true;
    try {
      AppState.favoriteVideo(video);
      this.refreshFavorite();
      Logger.info('PLAYER_FAVORITE', (this.favoriteSelected ? '收藏影片：' : '取消收藏：') + video.vodId);
    } catch (error) {
      this.favoriteBusy = false; this.favoriteScale = 1;
      Logger.error('PLAYER_FAVORITE', String(error)); this.refreshFavorite(); this.toast('收藏操作失败，请重试'); return;
    }
    // 动效失败不能把已成功同步的收藏操作误报为业务状态。
    try {
      if (this.favoriteTimer !== -1) { clearTimeout(this.favoriteTimer); }
      this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => { this.favoriteScale = 0.88; });
      this.favoriteTimer = setTimeout(() => {
        this.favoriteTimer = -1; this.favoriteBusy = false;
        if (this.disposed) { return; }
        try { this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.favoriteScale = 1; }); }
        catch (error) { this.favoriteScale = 1; Logger.warn('PLAYER_FAVORITE', '恢复收藏按钮动效失败：' + String(error)); }
      }, 100);
    } catch (error) { this.favoriteBusy = false; this.favoriteScale = 1; Logger.warn('PLAYER_FAVORITE', '收藏按钮动效不可用：' + String(error)); }
    this.toast(this.favoriteSelected ? '已加入影视收藏' : '已取消影视收藏');
  }
  private currentDownload(): DownloadRecord | undefined {
    const video = this.video;
    return video ? DownloadService.snapshot().find((item: DownloadRecord) => item.videoId === video.vodId && item.episodeIndex === this.episodeIndex + 1) : undefined;
  }
  private downloadIsActive(task: DownloadRecord | undefined): boolean {
    return task !== undefined && (task.state === DownloadState.SNIFFING || task.state === DownloadState.RUNNING || task.state === DownloadState.QUEUED);
  }
  private canControlDownload(): boolean {
    // 创建命令仍在等待解析时，已发送到共享服务的任务也必须能够暂停。
    const episode = this.episodes[this.episodeIndex];
    return !this.disposed && !this.downloadControlPending && this.video !== undefined && episode !== undefined && episode.routes[this.routeIndex] !== undefined && (!this.downloadCommandPending || this.downloadIsActive(this.currentDownload()));
  }
  private async pauseDownloadTask(task: DownloadRecord): Promise<void> {
    if (this.disposed || this.downloadControlPending) { return; }
    const requestVersion: number = this.downloadRequestVersion;
    const interruptsCreation: boolean = this.downloadCommandPending && task.videoId === this.pendingDownloadVideoId && task.episodeIndex === this.pendingDownloadEpisode;
    const wasSniffing: boolean = task.state === DownloadState.SNIFFING;
    this.downloadControlPending = true;
    if (interruptsCreation) { this.downloadPauseRequested = true; }
    try {
      Logger.info('PLAYER_DOWNLOAD', '请求暂停嗅探或下载任务：' + task.id);
      await DownloadService.pause(task.id);
      if (this.isDownloadRequestCurrent(requestVersion)) { this.downloadToast(wasSniffing ? '地址嗅探已暂停' : '下载已暂停'); }
    } catch (error) {
      Logger.error('PLAYER_DOWNLOAD', '暂停任务失败：' + task.id + '，' + String(error));
      if (this.isDownloadRequestCurrent(requestVersion)) {
        if (interruptsCreation) { this.downloadPauseRequested = false; }
        this.downloadToast('暂停失败，请重试');
      }
    } finally {
      if (requestVersion === this.downloadRequestVersion) {
        this.downloadControlPending = false;
        if (!this.disposed) { this.refreshDownload(); }
      }
    }
  }
  private traceDownloadState(task?: DownloadRecord): void {
    const status: string = (this.video?.vodId || '') + ':' + (this.episodeIndex + 1) + ':' + (task ? task.state : this.downloadProblem ? 'prepare_failed' : this.downloadButtonState);
    if (status === this.lastDownloadStatus) { return; }
    this.lastDownloadStatus = status;
    if (task?.state === DownloadState.FAILED || this.downloadProblem) { Logger.warn('PLAYER_DOWNLOAD', '本集状态同步：' + status + '，' + this.downloadDetail); }
    else { Logger.info('PLAYER_DOWNLOAD', '本集状态同步：' + status); }
  }
  private refreshDownload(): void {
    if (this.disposed) { return; }
    const task = this.currentDownload();
    const preparing: boolean = this.downloadCommandPending && this.video?.vodId === this.pendingDownloadVideoId && this.episodeIndex + 1 === this.pendingDownloadEpisode;
    const preparationFailure: string = this.video?.vodId === this.downloadFailureVideoId && this.downloadFailureEpisode === this.episodeIndex + 1 ? this.downloadFailureText : '';
    this.downloadPercent = 0; this.downloadSpeed = 0; this.downloadDetail = ''; this.downloadProblem = false;
    if (!task) {
      // 初始化及地址预处理也要即时反馈；仅显示被点击的集数，切集后不串用状态。
      this.downloadButtonState = preparing ? PlayerDownloadPhase.SNIFFING : PlayerDownloadPhase.READY;
      this.downloadLabel = preparing ? '准备下载' : preparationFailure ? '重试下载' : '下载本集';
      this.downloadDetail = preparing ? '正在初始化下载服务并准备资源地址，权限与空间由下载服务校验' : preparationFailure;
      this.downloadProblem = !preparing && preparationFailure.length > 0;
      this.traceDownloadState(); return;
    }
    // 共享服务已接管此集的状态，页面不得继续用之前的准备异常覆盖任务状态。
    if (task.videoId === this.downloadFailureVideoId && task.episodeIndex === this.downloadFailureEpisode) { this.downloadFailureText = ''; }
    this.downloadSpeed = task.state === DownloadState.RUNNING && Number.isFinite(task.speedBytes) ? Math.max(0, task.speedBytes) : 0;
    // HLS 总字节数在分片全部完成前可能未知，使用服务统一计算的分片进度。
    const progress: number = Number.isFinite(task.progressPercent) ? task.progressPercent : 0;
    this.downloadPercent = Math.max(0, Math.min(100, Math.floor(progress)));
    if (task.state === DownloadState.SNIFFING) {
      const sniffPercent: number = Number.isFinite(task.sniffProgress) ? task.sniffProgress : 0;
      this.downloadPercent = Math.max(0, Math.min(100, Math.floor(sniffPercent)));
      this.downloadButtonState = PlayerDownloadPhase.SNIFFING; this.downloadLabel = '嗅探中 ' + this.downloadPercent + '%';
      this.downloadDetail = (task.message || '正在解析真实视频地址') + ' · 点击下载按钮可暂停嗅探';
    } else if (task.state === DownloadState.COMPLETED) {
      this.downloadButtonState = PlayerDownloadPhase.COMPLETED; this.downloadLabel = '✓ 已下载'; this.downloadPercent = 100;
      this.downloadDetail = '已保存至应用私有目录，可在下载管理中查看';
    } else if (task.state === DownloadState.RUNNING || task.state === DownloadState.QUEUED) {
      this.downloadButtonState = PlayerDownloadPhase.DOWNLOADING;
      this.downloadLabel = task.state === DownloadState.QUEUED ? '等待下载' : ((task.totalBytes > 0 || task.mediaKind === 'hls') ? '下载中 ' + this.downloadPercent + '%' : '下载中');
      this.downloadDetail = task.message ? task.message + ' · 点击可暂停' : (task.state === DownloadState.QUEUED ? '等待 Wi-Fi 或空闲下载名额 · 点击可暂停' : '点击暂停 · ' + this.byteText(task.receivedBytes) + (task.totalBytes > 0 ? ' / ' + this.byteText(task.totalBytes) : ''));
    } else {
      this.downloadButtonState = PlayerDownloadPhase.READY; this.downloadLabel = task.state === DownloadState.FAILED ? '重试下载' : '继续下载';
      this.downloadDetail = task.message || '下载已暂停'; this.downloadProblem = task.state === DownloadState.FAILED;
    }
    this.traceDownloadState(task);
  }
  private byteText(value: number): string {
    if (!Number.isFinite(value) || value < 0) { return '0.0 KB'; }
    if (value >= 1024 * 1024 * 1024) { return (value / (1024 * 1024 * 1024)).toFixed(1) + ' GB'; }
    if (value >= 1024 * 1024) { return (value / (1024 * 1024)).toFixed(1) + ' MB'; }
    return (value / 1024).toFixed(1) + ' KB';
  }
  private async downloadEpisode(): Promise<void> {
    if (this.disposed || this.downloadControlPending) { return; }
    if (this.playbackResourceType === 'local') {
      Logger.info('PLAYER_DOWNLOAD', '资源类型=local，路径=' + this.sourceLogPath(this.playbackSourcePath) + '，跳过重复下载及远程解析');
      this.downloadToast('当前为本地离线视频，无需重复下载'); return;
    }
    if (this.downloadCommandPending) {
      // enqueue/resume 可能仍在等待嗅探；不能因等待 Promise 而锁死暂停入口。
      const activeTask = this.currentDownload();
      if (activeTask && this.downloadIsActive(activeTask)) { await this.pauseDownloadTask(activeTask); }
      return;
    }
    const video = this.video; const episode = this.episodes[this.episodeIndex]; const route = episode?.routes[this.routeIndex];
    if (!video || !episode || !route) { Logger.warn('PLAYER_DOWNLOAD', '缺少剧集或线路'); this.downloadToast('当前线路不支持下载'); return; }
    // 在任何 await 之前捕获目标集数；生命周期版本还可隔离退出后迟到的页面回调。
    const selectedIndex: number = this.episodeIndex + 1;
    const source: string = route.sourceUrl.trim();
    const requestVersion: number = ++this.downloadRequestVersion;
    this.downloadPauseRequested = false;
    this.downloadFailureVideoId = video.vodId; this.downloadFailureEpisode = selectedIndex; this.downloadFailureText = '';
    this.pendingDownloadVideoId = video.vodId;
    this.pendingDownloadEpisode = selectedIndex;
    this.downloadCommandPending = true;
    this.refreshDownload();
    try {
      await DownloadService.init(this.context());
      if (!this.isDownloadRequestCurrent(requestVersion)) { return; }
      const task = DownloadService.snapshot().find((item: DownloadRecord) => item.videoId === video.vodId && item.episodeIndex === selectedIndex);
      if (task?.state === DownloadState.COMPLETED) {
        Logger.info('PLAYER_DOWNLOAD', '本集已经下载：' + video.vodId + '，集数=' + selectedIndex);
        this.downloadToast('本集已下载，可在管理页的下载管理中查看');
      } else if (task && this.downloadIsActive(task)) {
        // 嗅探也允许暂停，交由共享服务取消请求并使迟到的解析结果失效。
        await this.pauseDownloadTask(task);
      } else if (task) {
        Logger.info('PLAYER_DOWNLOAD', '请求继续或重试任务：' + task.id);
        await DownloadService.resume(task.id);
      } else {
        if (!/^https?:\/\//i.test(source)) { throw new Error('当前线路不是可下载的网络资源'); }
        Logger.info('PLAYER_DOWNLOAD', '请求嗅探及下载：' + video.vodId + '，集数=' + selectedIndex);
        const target: string = await this.preparePlaybackUrl(source);
        if (!this.isDownloadRequestCurrent(requestVersion)) { return; }
        await DownloadService.enqueue(video.vodId, video.tilie || video.yhm || '未命名影片', episode.title, selectedIndex, target, video.feng || '');
        if (this.isDownloadRequestCurrent(requestVersion) && !this.downloadPauseRequested) {
          // 入队持久化期间其他页面也可暂停或删除；只对仍有效的共享任务显示成功提示。
          const created = DownloadService.snapshot().find((item: DownloadRecord) => item.videoId === video.vodId && item.episodeIndex === selectedIndex);
          if (created?.state === DownloadState.FAILED) { throw new Error(created.message || '嗅探或启动下载失败，请重试'); }
          if (created && this.downloadIsActive(created)) { this.downloadToast(episode.title + '已加入下载队列'); }
          else { Logger.debug('PLAYER_DOWNLOAD', '入队结束时任务已被同步控制：' + video.vodId + '，集数=' + selectedIndex); }
        }
      }
    } catch (error) {
      const caught: Error = error as Error;
      const message: string = caught.message || String(error);
      if (this.isDownloadRequestCurrent(requestVersion) && this.downloadPauseRequested) {
        Logger.info('PLAYER_DOWNLOAD', '用户暂停后下载命令结束：' + message);
      } else {
        Logger.error('PLAYER_DOWNLOAD', '下载操作失败：' + message);
        if (this.isDownloadRequestCurrent(requestVersion)) {
          const notice: string = message && message !== 'undefined' ? message : '下载操作失败，请检查网络、权限与存储空间';
          this.downloadFailureVideoId = video.vodId; this.downloadFailureEpisode = selectedIndex; this.downloadFailureText = notice;
          this.downloadToast(notice);
        }
      }
    } finally {
      // 后台任务继续运行，但旧命令不能清除重新进入页面后的新命令状态。
      if (requestVersion === this.downloadRequestVersion) {
        this.pendingDownloadVideoId = ''; this.pendingDownloadEpisode = 0; this.downloadCommandPending = false;
        if (!this.disposed) { this.refreshDownload(); }
      }
    }
  }
  private async listenWindowSize(): Promise<void> {
    try {
      const target = await window.getLastWindow(this.context());
      if (this.disposed) { return; }
      this.listeningWindow = target;
      target.on('windowSizeChange', this.windowSizeCallback);
      await ImmersiveService.attach(target);
    } catch (error) { Logger.error('PLAYER_IMMERSIVE', '监听窗口并同步沉浸失败：' + String(error)); }
  }
  private resizePlayer(layoutSpan: number, layoutTall: number): void {
    if (!Number.isFinite(layoutSpan) || layoutSpan <= 0 || !Number.isFinite(layoutTall) || layoutTall <= 0) { return; }
    this.viewportWidth = layoutSpan; this.viewportHeight = layoutTall; this.updatePlayerLayout();
  }
  private async loadWatchRecord(vodId: string): Promise<void> {
    const entryVersion: number = this.playbackEntryVersion;
    try {
      const store = await preferences.getPreferences(this.context(), 'player_watch_history'); if (this.disposed || this.video?.vodId !== vodId || entryVersion !== this.playbackEntryVersion) { return; }
      const raw = String(await store.get('vod_' + vodId, '')); if (this.disposed || this.video?.vodId !== vodId || entryVersion !== this.playbackEntryVersion) { return; }
      if (raw) {
        const record = JSON.parse(raw) as PlayerWatchRecord;
        if (record.vodId === vodId && Number.isInteger(record.selectIndex) && record.selectIndex >= 0 && record.selectIndex < this.episodes.length && Number.isFinite(record.playSec) && record.playSec >= 0 && typeof record.videoName === 'string') {
          this.getUIContext().getPromptAction().showDialog({ title: '播放记录', message: '检测到上次播放记录，是否继续播放？', buttons: [{ text: '从头播放', color: this.accent() }, { text: '继续播放', color: this.accent() }] }).then((result) => { if (!this.disposed && this.video?.vodId === vodId && entryVersion === this.playbackEntryVersion) { result.index === 1 ? this.choosePlayback(record.selectIndex, record.playSec) : this.choosePlayback(0, 0); } }).catch(() => { if (!this.disposed && this.video?.vodId === vodId && entryVersion === this.playbackEntryVersion) { this.choosePlayback(0, 0); } }); return;
        }
      }
    } catch (_) { Logger.error('PlayerEngine', '读取播放记录失败'); }
    if (!this.disposed && this.video?.vodId === vodId && entryVersion === this.playbackEntryVersion) { this.choosePlayback(0, 0); }
  }
  private choosePlayback(index: number, playSec: number): void { if (this.disposed || !this.video || this.episodes.length === 0) { return; } this.episodeIndex = index; this.routeIndex = 0; this.currentMs = Math.floor(playSec * 1000); this.resumeMs = this.currentMs; this.resumeDecisionPending = false; this.refreshDownload(); this.startWhenReady(); }
  private startWhenReady(): void { if (!this.surfaceReady || this.initializationStarted || this.resumeDecisionPending || this.missingParams || this.episodes.length === 0 || this.disposed) { return; } this.initializationStarted = true; void this.initialize(); }
  private async saveWatchRecord(): Promise<void> { const video = this.video; if (!video || this.episodes.length === 0 || this.resumeDecisionPending || this.completed) { return; } try { const record: PlayerWatchRecord = { vodId: video.vodId, selectIndex: this.episodeIndex, playSec: Math.max(0, Math.floor(this.currentMs / 1000)), videoName: video.tilie || video.yhm || '' }; const store = await preferences.getPreferences(this.context(), 'player_watch_history'); if (!this.completed) { await store.put('vod_' + video.vodId, JSON.stringify(record)); await store.flush(); } } catch (_) { Logger.error('PlayerEngine', '写入播放记录失败'); } }
  private startRecordTimer(): void { this.clearRecordTimer(); this.recordTimer = setInterval(() => { if (!this.disposed && !this.completed && !this.resumeDecisionPending && this.playing) { void this.saveWatchRecord(); } }, 5000); }
  private clearRecordTimer(): void { if (this.recordTimer !== -1) { clearInterval(this.recordTimer); this.recordTimer = -1; } }
  private async clearWatchRecord(): Promise<void> { const vodId: string = this.video?.vodId || ''; if (!vodId) { return; } try { const store = await preferences.getPreferences(this.context(), 'player_watch_history'); await store.delete('vod_' + vodId); await store.flush(); } catch (_) { Logger.error('PlayerEngine', '清除播放记录失败'); } }
  private async checkNetwork(): Promise<void> {
    // ArkUI-X 未适配 connection.getDefaultNet()：不做播放前网络预检，
    // 网络异常由播放器状态回调与请求失败提示兜底。
    if (this.playbackResourceType === 'local') { return; }
  }
  aboutToDisappear(): void {
    this.disposed = true;
    this.handoffPageVisible = false;
    try { this.quest3Service.close(); } catch (error) { Logger.warn('QUEST3_WS', '播放器退出时释放 Quest3 链路失败：' + String(error)); }
    try {
      this.clearSlaveState(); this.sessionDialogVisible = false; this.consumedSessionInvite = '';
      this.sessionService.unsubscribe(this.sessionViewCallback); void this.sessionService.release();
    } catch (error) { Logger.warn('MEDIA_SESSION', '释放播放页同播资源失败：' + String(error)); }
    try { ShareService.clearPlaybackProgressReader(this.playbackProgressReader); }
    catch (error) { Logger.warn('SHARE_RESUME', '注销统一发送进度读取器失败：' + String(error)); }
    this.playbackEntryVersion++;
    this.consumedShareParams = undefined;
    this.pendingSharedProgressMs = undefined;
    this.sharedSeekIssued = false;
    this.sharedSourceEpisodeIndex = -1;
    this.downloadRequestVersion++;
    this.sourceRequestVersion++;
    this.sourceChangePending = false;
    this.pendingSource = '';
    if (this.listeningWindow) { try { this.listeningWindow.off('windowSizeChange', this.windowSizeCallback); } catch (_) { Logger.error('PlayerEngine', '移除窗口尺寸监听失败'); } this.listeningWindow = undefined; }
    if (this.favoriteTimer !== -1) { clearTimeout(this.favoriteTimer); this.favoriteTimer = -1; }
    this.clearTimer(); this.clearRecordTimer(); void this.saveWatchRecord();
    if (!this.missingParams && this.episodes.length > 0 && !this.completed) { try { AppState.record(this.episodeIndex + 1, this.currentMs / 1000, this.durationMs / 1000, this.video); } catch (_) {} }
    // 页面关闭不取消后台下载或全局沉浸；任务由共享服务及下载管理继续控制。
    void this.teardown();
  }
  private async teardown(): Promise<void> {
    try { if (this.fullScreen) { await this.leaveFullScreen(); } await PlayerEngine.release(); }
    catch (error) { Logger.error('PLAYER_SOURCE', '释放播放器失败，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) + '：' + String(error)); this.report('释放播放器资源失败'); }
    finally { this.player = undefined; this.closeLocalSource(); }
  }
  private report(message: string): void {
    Logger.error('PlayerEngine', message);
    if (this.disposed) { return; }
    if (this.liveMode) {
      // 直播源（m3u8）常见 401/超时：不显示「播放异常」错误卡，提示换线路即可。
      this.errorText = '';
      this.loading = false;
      this.reveal();
      return;
    }
    this.errorText = message;
    this.loading = false;
    this.reveal();
  }
  // PlayerPage 接入点：只序列化现有视频资料，不修改标准协播 JSON 字段。
  private quest3Payload(): Quest3CoPlayPayload {
    const video: SearchVideoItem | undefined = this.video;
    if (!video) { throw new Error('当前没有可同步的视频'); }
    const resolvedSessionId: string = this.sessionId || this.quest3SessionId;
    if (!resolvedSessionId || !/^[A-Za-z0-9_-]{1,256}$/.test(resolvedSessionId)) {
      Logger.error('MEDIA_SESSION', '拒绝生成协播载荷：sessionId 为空或格式非法');
      throw new Error('协播会话尚未建立，请先创建会话');
    }
    const serializedVideo: string = JSON.stringify(video);
    if (!serializedVideo || !serializedVideo.length) { throw new Error('协播视频载荷序列化失败'); }
    const payload: Quest3CoPlayPayload = {
      version: 1, vodId: video.vodId, sessionId: resolvedSessionId,
      currentMs: Math.max(0, Math.floor(this.currentMs)), timestamp: Date.now(),
      episodeIndex: Math.max(0, this.episodeIndex), videoJson: serializedVideo, sceneMode: 'plane'
    };
    return payload;
  }
  // Quest3 状态回传只更新业务播放状态，不读取 OpenXR 或手柄追踪数据。
  private onQuest3State(packet: Quest3StatePacket): void {
    try {
      if (this.disposed || !Number.isFinite(packet.currentMs) || packet.currentMs < 0) { return; }
      const target: number = Math.max(0, Math.floor(packet.currentMs));
      if (Math.abs(this.currentMs - target) > 1200) {
        this.currentMs = target; this.resumeMs = target;
        const activePlayer: media.AVPlayer | undefined = this.player;
        if (activePlayer && (activePlayer.state === 'prepared' || activePlayer.state === 'playing' || activePlayer.state === 'paused')) {
          activePlayer.seek(target, PlatformApi.seekModeClosest());
        }
      }
      if (packet.playState === 'playing' && this.player && this.player.state === 'paused') { void this.player.play(); this.playing = true; }
      else if ((packet.playState === 'paused' || packet.playState === 'ended') && this.player && this.player.state === 'playing') { void this.player.pause(); this.playing = false; }
      Logger.info('QUEST3_WS', 'Quest3 状态已同步，playState=' + packet.playState + '，currentMs=' + String(target));
    } catch (error) { Logger.error('QUEST3_WS', '处理 Quest3 状态回传失败：' + String(error)); }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private updateVideoSize(videoSpan: number, videoTall: number): void {
    try { if (this.disposed || !Number.isFinite(videoSpan) || !Number.isFinite(videoTall) || videoSpan <= 0 || videoTall <= 0) { return; } this.videoWidth = videoSpan; this.videoHeight = videoTall; if (this.selectedRatio === '原画') { this.updatePlayerLayout(); } }
    catch (_) { Logger.error('PlayerEngine', '更新视频原始尺寸失败'); }
  }
  private async initialize(): Promise<void> {
    try {
      const instance = await PlayerEngine.acquire(); if (this.disposed) { await PlayerEngine.release(); return; } this.player = instance;
      instance.on('stateChange', (state: string) => {
        if (this.disposed) { return; }
        try {
          this.traceSharedPlayback(state);
          if (state === 'initialized') {
            instance.surfaceId = this.surfaceController.getXComponentSurfaceId();
            instance.prepare().catch((error: Error) => { this.sourceFailure('准备视频失败', error); });
          } else if (state === 'prepared') {
            this.durationMs = instance.duration; instance.setVolume(this.volumeValue); instance.setSpeed(this.speedValues[this.speedIndex]);
            if (this.resumeMs > 0 || (this.isSlaveMode && this.pendingSharedProgressMs !== undefined)) {
              const target: number = Math.max(0, Math.floor(this.resumeMs));
              instance.seek(target, PlatformApi.seekModeClosest());
              if (this.isSlaveMode) { Logger.info('CO_PLAYBACK', 'AVPlayer 已准备并执行入会 seek，毫秒=' + target); }
              this.resumeMs = 0;
            }
            instance.play().catch((error: Error) => { this.sourceFailure('启动播放失败', error); });
          } else if (state === 'playing') { this.playing = true; this.loading = false; this.reveal(); }
          else if (state === 'paused') { this.playing = false; this.reveal(); }
          else if (state === 'completed') { this.playing = false; this.completed = true; this.clearRecordTimer(); this.reveal(); void this.clearWatchRecord(); }
          if (state === 'playing' || state === 'paused' || state === 'completed') { void this.publishSessionState(); }
        } catch (error) { this.sourceFailure('处理播放器状态失败', error as Error); }
      });
      instance.on('seekDone', (seekTime: number): void => {
        try {
          if (this.disposed || this.pendingSharedProgressMs === undefined || !this.sharedSeekIssued) { return; }
          Logger.info('PLAYER_HANDOFF', '分享进度定位完成，目标=' + this.pendingSharedProgressMs + '毫秒，实际=' + seekTime + '毫秒');
          this.pendingSharedProgressMs = undefined;
          this.sharedSeekIssued = false;
        } catch (error) {
          Logger.warn('PLAYER_HANDOFF', '记录分享定位完成状态失败：' + String(error));
          if (this.isSlaveMode) { this.failSession('处理协播定位完成回调失败', error); }
        }
      });
      instance.on('videoSizeChange', (videoSpan: number, videoTall: number) => { this.updateVideoSize(videoSpan, videoTall); });
      try { instance.videoScaleType = this.selectedRatio === '铺满屏幕' ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT; this.updatePlayerLayout(); } catch (_) { Logger.error('PlayerEngine', '设置播放器画面比例失败'); }
      instance.on('timeUpdate', (time: number) => { if (!this.seeking && !this.disposed) { this.currentMs = time; this.refreshDanmakuWindow(time); } }); instance.on('durationUpdate', (duration: number) => { if (!this.disposed) { this.durationMs = duration; } });
      instance.on('error', (error) => {
        if (this.disposed) { return; }
        try {
          if (this.isSlaveMode) { this.failSession('协播 AVPlayer 异常', error); }
          const error401: boolean = error.code === 401 || /\b401\b/.test(error.message || '');
          Logger.error('PLAYER_SOURCE', '资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) + '，错误码=' + error.code + (error401 ? '，401异常' : '') + (this.playbackResourceType === 'local' ? '，本地分支未发起远程鉴权' : ''));
          this.report(this.playbackResourceType === 'local' ? '本地视频播放失败，错误码 ' + error.code + '，请检查文件完整性或重新下载' : error.code === 499 ? 'HTTP499：请求已取消' : '播放异常，错误码 ' + error.code);
        } catch (caught) { Logger.error('PLAYER_SOURCE', '处理播放异常失败：' + String(caught)); this.report('播放失败，请重试'); }
      });
      await this.selectSource(this.resumeMs > 0);
    } catch (error) { this.sourceFailure('播放器初始化失败', error as Error); }
  }
  private routeLocalPath(): string {
    const video: SearchVideoItem | undefined = this.video;
    return video && typeof video.localPath === 'string' ? video.localPath.trim() : '';
  }
  private isLocalAddress(source: string): boolean { return source.startsWith('/') || /^file:\/\//i.test(source); }
    private sourceLogPath(source: string): string {
      // 网络日志不输出查询参数或片段，避免泄露签名等鉴权资料。
      if (this.isLocalAddress(source)) { return source; }
      return source.split(/[?#]/)[0].replace(/^(https?:\/\/)[^/@]+@/i, '$1');
    }
    private normalizeLocalPath(source: string): string {
      return LocalPlaybackService.checkedPath(source, this.context());
    }
    private closeLocalSource(): void {
      const opened: fileIo.File | undefined = this.localSourceFile;
      const preparedPath: string = this.preparedLocalPath;
      this.localSourceFile = undefined;
      this.preparedLocalPath = '';
      try { if (opened) { fileIo.closeSync(opened); } }
      catch (error) { Logger.warn('PLAYER_LOCAL', '关闭本地视频句柄失败，资源类型=local，路径=' + this.sourceLogPath(this.playbackSourcePath) + '：' + String(error)); }
      finally { LocalPlaybackService.cleanup(preparedPath); }
    }
    private async setLocalSource(instance: media.AVPlayer, source: string, requestVersion: number): Promise<void> {
      let preparedPath: string = '';
      try {
        const localPath: string = this.normalizeLocalPath(source);
        this.playbackSourcePath = localPath;
        LocalPlaybackService.checkedSize(localPath);
        const offlineManifest: boolean = /\.m3u8$/i.test(localPath);
        const readablePath: string = offlineManifest ? await LocalPlaybackService.prepareHls(localPath, this.context(),
          (): boolean => this.disposed || requestVersion !== this.sourceRequestVersion || this.player !== instance) : localPath;
        if (offlineManifest) { preparedPath = readablePath; }
        if (this.disposed || requestVersion !== this.sourceRequestVersion || this.player !== instance) {
          LocalPlaybackService.cleanup(preparedPath); return;
        }
        // 普通文件与离线合并缓存分别使用共享的严格校验入口。
        // 实际读取验证可读性，并保留文件 API 的 401 错误码；不触发 URL 播放或远程鉴权。
        const opened: fileIo.File = offlineManifest ?
          LocalPlaybackService.openPreparedFile(readablePath, this.context()) :
          LocalPlaybackService.openFile(localPath, this.context());
        this.localSourceFile = opened;
        this.preparedLocalPath = preparedPath;
        const fileSize: number = LocalPlaybackService.checkedSize(readablePath);
        // 普通文件及离线 HLS 合并文件统一使用 fdSrc，绝不将本地清单交给网络 URL 分支。
        instance.fdSrc = { fd: opened.fd, offset: 0, length: fileSize };
        Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，文件大小=' + fileSize +
        (offlineManifest ? '，离线分片已准备为本地媒体文件' : '') + '，使用文件描述符，已跳过远程解析及鉴权');
      } catch (error) {
        this.closeLocalSource();
        LocalPlaybackService.cleanup(preparedPath);
        // ArkTS 仅允许抛出 Error；包装异常时保留文件 API 错误码（包括 401）。
        const caught: BusinessError | undefined = error as BusinessError | undefined;
        const failure: Error = new Error(caught?.message || String(error) || '本地视频准备失败');
        if (caught && typeof caught.code === 'number') {
          const fileFailure: BusinessError = failure as BusinessError;
          fileFailure.code = caught.code;
        }
        throw failure;
      }
    }
    private sourceFailure(stage: string, error: Error): void {
      // 直播源（m3u8 常见 401）失败时完全静默：不弹错误码、不弹提示，只写日志。
      if (this.liveMode) {
        Logger.warn('PLAYER_SOURCE', '直播源播放失败（已静默）：' + stage + '，' + String((error as BusinessError).message || error));
        this.loading = false;
        this.reveal();
        return;
      }
      if (this.isSlaveMode) { this.failSession(stage, error); }
      const caught: BusinessError = error as BusinessError;
      const details: string = caught.message || String(error);
      const error401: boolean = caught.code === 401 || /\b401\b/.test(details);
      Logger.error('PLAYER_SOURCE', stage + '，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) +
      (typeof caught.code === 'number' ? '，错误码=' + caught.code : '') + (error401 ? '，401异常' : '') +
      (this.playbackResourceType === 'local' ? '，本地分支未发起远程鉴权' : ''));
      const localNotice: string = error401 ? '本地文件读取异常（错误码401），请检查文件完整性、访问权限或重新下载' :
        /^(本地|离线|当前离线)/.test(details) ? details : '请检查本地文件是否完整、可读取，或重新下载';
      this.report(this.playbackResourceType === 'local' ? stage + '：' + localNotice : stage + '，请检查网络及播放线路');
    }
    private async preparePlaybackUrl(original: string): Promise<string> {
      // 离线资源在入口阻断远程处理，即使其他业务误传网络地址也不会发起鉴权。
      if (this.playbackResourceType === 'local' || this.isLocalAddress(original)) { return this.normalizeLocalPath(original); }
      let target: string = original;
      try {
        const parts = /^(https?):\/\/([^\/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(original);
        if (parts && parts[2].split(':')[0].toLowerCase() === 'play.hhuus.com') { target = parts[1] + '://' + parts[2] + parts[3].replace(/\/+$/, '') + '/index.m3u8' + (parts[4] || '') + (parts[5] || ''); }
      } catch (error) { Logger.warn('PLAYER_SOURCE', '在线资源地址规范化失败：' + String(error)); return original; }
      return target;
    }
    /** 分享当前播放的影视到群聊：先拉群列表，再选一个发送卡片。 */
  private async shareToGroup(): Promise<void> {
    try {
      const rooms = await AccountApi.roomList();
      this.shareRooms = [];
      for (const room of rooms) {
        this.shareRooms.push(room.title);
      }
      this.shareFriends = [];
      try {
        const session = await CommunityApi.readSession();
        if (session.valid()) {
          const friends = await AccountApi.mutualFriends(session.user, session.pass);
          for (const friend of friends) {
            this.shareFriends.push(friend.name.length > 0 ? friend.name + '|' + friend.user : friend.user);
          }
          if (this.shareFriends.length === 0) {
            // 互关为空时退回本地好友列表
            for (const local of SocialStore.friendsList()) {
              this.shareFriends.push(local.name.length > 0 ? local.name + '|' + local.account : local.account);
            }
          }
        }
      } catch (error) {
        Logger.warn('PLAYER_SHARE', '拉取好友失败：' + String(error));
      }
      if (this.shareRooms.length === 0 && this.shareFriends.length === 0) {
        this.toast('还没有可分享的群聊或好友');
        return;
      }
      this.shareGroupVisible = true;
    } catch (error) {
      Logger.warn('PLAYER_SHARE', '拉取群列表失败：' + String(error));
      this.toast('拉取群列表失败');
    }
  }

  /** 把当前影视参数拼成卡片并发到指定群。 */
  private async sendCardToGroup(room: string): Promise<void> {
    try {
      const session = await CommunityApi.readSession();
      if (!session.valid()) {
        this.toast('请先登录后再分享');
        return;
      }
      const args: VideoShareArgs = new VideoShareArgs();
      args.vodId = this.video?.vodId || '';
      args.episodeIndex = this.episodeIndex + 1;
      args.wzlj = this.video?.wzlj || '';
      args.title = this.video?.tilie || this.video?.yhm || '无音影视';
      args.episodeTitle = this.episodes.length > this.episodeIndex && this.episodes[this.episodeIndex] !== undefined
        ? this.episodes[this.episodeIndex].title : '';
      args.cover = this.video?.feng || '';
      args.durationText = this.durationMs > 0 ? this.clockOfMs(this.durationMs) : '';
      const xml: string = buildVideoCard(args);
      try {
        await CommunityApi.sendChat(session, room, xml);
      } catch (error) {
        const text: string = String(error);
        if (text.indexOf('成功') < 0) { throw new Error(text); }
        Logger.info('PLAYER_SHARE', '群发送返回成功文案，按成功处理：' + text);
      }
      this.shareGroupVisible = false;
      this.toast('已分享到「' + room + '」');
    } catch (error) {
      Logger.error('PLAYER_SHARE', '分享到群失败：' + String(error));
      this.toast('分享失败：' + String(error));
    }
  }

  /** 分享到好友私聊（friendchat.php）。 */
  private async sendCardToFriend(display: string): Promise<void> {
    try {
      const account: string = display.indexOf('|') > 0 ? display.substring(display.indexOf('|') + 1) : display;
      const session = await CommunityApi.readSession();
      if (!session.valid()) {
        this.toast('请先登录后再分享');
        return;
      }
      const xml: string = this.buildShareCardXml();
      try {
        await AccountApi.sendFriendChat(session.user, session.pass, account, xml);
      } catch (error) {
        const text: string = String(error);
        if (text.indexOf('成功') < 0) { throw new Error(text); }
        Logger.info('PLAYER_SHARE', '好友发送返回成功文案，按成功处理：' + text);
      }
      this.shareGroupVisible = false;
      this.toast('已分享给好友');
    } catch (error) {
      Logger.error('PLAYER_SHARE', '分享给好友失败：' + String(error));
      this.toast('分享失败：' + String(error));
    }
  }

  /** 当前播放参数 → 卡片 XML。 */
  private buildShareCardXml(): string {
    const args: VideoShareArgs = new VideoShareArgs();
    args.vodId = this.video?.vodId || '';
    args.episodeIndex = this.episodeIndex + 1;
    args.wzlj = this.video?.wzlj || '';
    args.title = this.video?.tilie || this.video?.yhm || '无音影视';
    args.episodeTitle = this.episodes.length > this.episodeIndex && this.episodes[this.episodeIndex] !== undefined
      ? this.episodes[this.episodeIndex].title : '';
    args.cover = this.video?.feng || '';
    args.durationText = this.durationMs > 0 ? this.clockOfMs(this.durationMs) : '';
    return buildVideoCard(args);
  }

  private clockOfMs(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const min: number = Math.floor(total / 60);
    const sec: number = total % 60;
    return (min < 10 ? '0' : '') + String(min) + ':' + (sec < 10 ? '0' : '') + String(sec);
  }

  @Builder
  private shareGroupPanel() {
    Column({ space: '10vp' }) {
      Row() {
        Text('分享到群聊')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text('关闭')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor('#B3FFFFFF')
          .onClick(() => { this.shareGroupVisible = false; })
      }
        .width('100%')
      if (this.shareRooms.length > 0) {
        Text('群聊')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor('#99FFFFFF')
          .width('100%')
      }
      List({ space: '8vp' }) {
        ForEach(this.shareRooms, (room: string) => {
          ListItem() {
            Row() {
              Text(room)
                .fontSize(Ui.fs('14vp', this.fontScale))
                .fontColor('#FFFFFF')
                .maxLines(1)
                .layoutWeight(1)
              Text('发送')
                .fontSize(Ui.fs('11vp', this.fontScale))
                .fontColor('#FFD08A')
            }
              .width('100%')
              .padding({ top: '10vp', bottom: '10vp', left: '12vp', right: '12vp' })
              .borderRadius('12vp')
              .backgroundColor('#22FFFFFF')
              .onClick(() => { void this.sendCardToGroup(room); })
          }
        }, (room: string) => 'share-room-' + room)
      }
        .width('100%')
        .height(this.shareFriends.length > 0 ? '150vp' : '240vp')
        .scrollBar(BarState.Off)
      if (this.shareFriends.length > 0) {
        Text('好友')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor('#99FFFFFF')
          .width('100%')
        List({ space: '8vp' }) {
          ForEach(this.shareFriends, (friend: string) => {
            ListItem() {
              Row() {
                Text(friend.indexOf('|') > 0 ? friend.substring(0, friend.indexOf('|')) : friend)
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .layoutWeight(1)
                Text('发送')
                  .fontSize(Ui.fs('11vp', this.fontScale))
                  .fontColor('#FFD08A')
              }
                .width('100%')
                .padding({ top: '10vp', bottom: '10vp', left: '12vp', right: '12vp' })
                .borderRadius('12vp')
                .backgroundColor('#22FFFFFF')
                .onClick(() => { void this.sendCardToFriend(friend); })
            }
          }, (friend: string) => 'share-friend-' + friend)
        }
          .width('100%')
          .height('150vp')
          .scrollBar(BarState.Off)
      }
    }
      .width('88%')
      .constraintSize({ maxWidth: '460vp' })
      .padding('16vp')
      .borderRadius('18vp')
      .backgroundColor('#CC000000')
  }

    private async selectSource(keepPosition: boolean): Promise<void> {
      if (this.disposed) { return; }
      const requestVersion: number = ++this.sourceRequestVersion;
      let ownsSwitch: boolean = false;
      try {
        const episode = this.episodes[this.episodeIndex]; const route = episode?.routes[this.routeIndex];
        this.completed = false; this.refreshDownload(); this.resumeMs = keepPosition ? this.currentMs : 0;
        this.pendingSource = route ? route.sourceUrl.trim() : '';
        this.sourceChangePending = true;
        this.errorText = this.pendingSource ? '' : '当前集尚未配置真实播放资源';
        if (!this.player || this.switching) { return; }
        this.switching = true; ownsSwitch = true;
        const instance: media.AVPlayer = this.player;
        const source: string = this.pendingSource; this.pendingSource = ''; this.sourceChangePending = false;
        this.loading = source.length > 0;
        if (instance.state !== 'idle') { await instance.reset(); }
        this.closeLocalSource();
        if (this.disposed || requestVersion !== this.sourceRequestVersion || this.player !== instance) { return; }
        this.videoWidth = 0; this.videoHeight = 0; this.updatePlayerLayout(); this.currentMs = 0; this.durationMs = 0; this.playing = false;
        if (source) {
          const routeLocalPath: string = this.routeLocalPath();
          const localResource: boolean = this.video?.resourceType === 'local' || routeLocalPath.length > 0 || this.isLocalAddress(source);
          this.playbackResourceType = localResource ? 'local' : 'online'; this.playbackSourcePath = source;
          Logger.info('PLAYER_SOURCE', '切换播放源，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(source));
          if (localResource) { await this.setLocalSource(instance, source, requestVersion); }
          else {
            if (!/^https?:\/\//i.test(source)) { throw new Error('当前线路不是有效的网络播放资源'); }
            const target: string = await this.preparePlaybackUrl(source);
            if (this.disposed || requestVersion !== this.sourceRequestVersion || this.player !== instance) { return; }
            // 兜底：原有链路仍解析不出直链（页面/短链）时，交给公共嗅探服务再试一次。
            let playable: string = target;
            if (MediaSniffer.isPage(target) && !this.liveMode) {
              const resolved: SniffResult = await MediaSniffer.resolve(target);
              if (resolved.sniffed && resolved.url.length > 0) { playable = resolved.url; }
            }
            instance.url = playable;
          }
        }
      } catch (error) {
        if (!this.disposed && requestVersion === this.sourceRequestVersion) {
          const caught: Error = error as Error;
          this.sourceFailure('切换播放源失败', caught);
          if (this.playbackResourceType === 'local') { this.toast(caught.message || '本地视频不可读取，请重新下载'); }
        } else { Logger.debug('PLAYER_LOCAL', '忽略已取消的播放源准备结果，资源类型=' + this.playbackResourceType); }
      } finally {
        // 旧准备任务只能释放自己持有的切换锁；切集或退出后不得把迟到文件交给播放器。
        if (ownsSwitch) {
          this.switching = false;
          if (!this.disposed) {
            if (this.sourceChangePending) { void this.selectSource(this.resumeMs > 0); }
            else { this.reveal(); }
          }
        }
      }
    }
    private async togglePlay(): Promise<void> { this.reveal(); try { if (this.sessionControlBlocked() || !this.player) { return; } if (this.player.state === 'playing') { await this.player.pause(); } else if (this.player.state === 'paused' || this.player.state === 'prepared' || this.player.state === 'completed') { await this.player.play(); } else if (this.errorText) { await this.selectSource(false); } } catch (error) { this.sourceFailure('播放控制失败', error as Error); } }
    private clearTimer(): void { if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; } }
    private reveal(): void { this.clearTimer(); this.getUIContext().animateTo({ duration: 200 }, () => { this.controlsVisible = true; }); if (!this.playing || this.seeking || this.hovered || this.loading || this.errorText) { return; } this.hideTimer = setTimeout(() => { if (!this.disposed) { this.getUIContext().animateTo({ duration: 240 }, () => { this.controlsVisible = false; }); } }, 3500); }
    private toggleControls(): void {
      if (this.disposed) { return; }
      if (this.controlsVisible) {
        this.clearTimer();
        this.getUIContext().animateTo({ duration: 240 }, () => { this.controlsVisible = false; });
      } else { this.reveal(); }
    }
    private closeControlMenus(): void {
      this.ratioMenuVisible = false;
      this.speedMenuVisible = false;
      this.episodeMenuVisible = false;
    }
    private syncWindowDimensions(target?: window.Window): void {
      try { if (!target) { return; } const rect = target.getWindowProperties().windowRect; if (rect && rect.width > 0 && rect.height > 0) { this.resizePlayer(this.getUIContext().px2vp(rect.width), this.getUIContext().px2vp(rect.height)); } }
      catch (_) { Logger.error('PlayerEngine', '获取播放器窗口尺寸失败'); }
    }
    private async toggleFullScreen(): Promise<void> {
      if (this.fullScreenTransitionPending || this.disposed) { return; }
      this.fullScreenTransitionPending = true;
      try {
        if (this.fullScreen) { await this.leaveFullScreen(); return; }
        const target = await window.getLastWindow(this.context()); if (!target || this.disposed) { return; }
        this.appWindow = target; this.portraitWidth = this.viewportWidth; this.portraitHeight = this.viewportHeight;
        const restoreState: WindowRestoreState = { orientation: PlatformApi.preferredOrientation(target) };
        this.restoreState = restoreState;
        await target.setPreferredOrientation(window.Orientation.LANDSCAPE);
        // 横屏也保留可见的小白条与透明导航区域，不能把导航内容色设为透明。
        await ImmersiveService.attach(target);
        if (this.disposed) { await this.leaveFullScreen(); return; }
        this.closeControlMenus();
        // 仅更新尺寸与显隐，不 reset/release 播放器，也不更换 XComponent。
        this.fullScreen = true; this.syncWindowDimensions(target); this.updatePlayerLayout(); AppStorage.setOrCreate('playerFullScreen', true); this.reveal();
      } catch (error) {
        Logger.error('PLAYER_IMMERSIVE', '进入横屏沉浸失败：' + String(error));
        if (this.appWindow && this.restoreState) { await this.leaveFullScreen(); }
        if (!this.disposed) { this.toast('进入全屏失败'); }
      } finally { this.fullScreenTransitionPending = false; }
    }
    private async leaveFullScreen(): Promise<void> {
      this.fullScreenTransitionPending = true;
      try {
        const target = this.appWindow; const state = this.restoreState;
        if (target && state) { await target.setPreferredOrientation(state.orientation); }
      } catch (error) { Logger.error('PLAYER_IMMERSIVE', '恢复播放器方向失败：' + String(error)); }
      finally {
        try {
          this.fullScreen = false; this.danmakuPanelVisible = false; this.closeControlMenus(); this.resizePlayer(this.portraitWidth, this.portraitHeight); AppStorage.setOrCreate('playerFullScreen', false);
          if (!this.disposed) { this.reveal(); }
        } catch (error) { Logger.error('PLAYER_IMMERSIVE', '恢复非全屏控件布局失败：' + String(error)); }
        finally { this.appWindow = undefined; this.restoreState = undefined; }
        // 只恢复方向，不恢复旧窗口的非沉浸布局或实色系统栏。
        try { await ImmersiveService.apply(true); ImmersiveService.publishSafeArea(); }
        catch (error) { Logger.error('PLAYER_IMMERSIVE', '退出横屏时恢复全局沉浸失败：' + String(error)); }
        finally { this.fullScreenTransitionPending = false; }
      }
    }
    private async back(): Promise<void> {
      if (this.fullScreenTransitionPending) { return; }
      if (this.fullScreen) { await this.leaveFullScreen(); return; }
      try { if (Number(router.getLength()) > 1) { router.back(); } else { AppState.go('home'); } }
      catch (error) { Logger.warn('PLAYER_NAVIGATION', String(error)); AppState.go('home'); }
    }
    onBackPress(): boolean { if (this.sessionDialogVisible) { this.sessionDialogVisible = false; return true; } if (this.fullScreenTransitionPending) { return true; } if (this.fullScreen) { void this.leaveFullScreen(); return true; } return false; }
    private toast(message: string): void { try { this.getUIContext().getPromptAction().showToast({ message: message }); } catch (error) { Logger.warn('PLAYER_NOTICE', String(error)); } }
    private downloadToast(message: string): void {
      // 仅分支控制下载消息的展示，不拦截下载命令、状态同步或其他播放器提示。
      if (!this.fullScreen) { this.toast(message); }
    }
    private tablet(): boolean { return this.viewportWidth >= 600; }
    // 以下仅提供视觉取值（统一走液态玻璃令牌），不参与任何播放状态判断。
    private ink(): string { return Ui.ink(this.darkTheme); }
    private mutedInk(): string { return Ui.inkSoft(this.darkTheme); }
    private accent(): string { return Ui.accent(this.darkTheme); }
    private warningInk(): string { return Ui.danger(this.darkTheme); }
    private selectedSurface(): string { return Ui.accentSoft(this.darkTheme); }
    private canvas(): string { return Ui.pageBg(this.darkTheme); }
    private solidPanel(): string { return Ui.glassTintStrong(this.darkTheme); }
    private panel(): string { return Ui.glassTint(this.darkTheme); }
    private glassRadius(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
    private time(ms: number): string { const seconds = Math.floor(Math.max(0, ms) / 1000); return Math.floor(seconds / 60) + ':' + (seconds % 60).toString().padStart(2, '0'); }
    private ratioValue(): number { if (this.selectedRatio === '16:9') { return 16 / 9; } if (this.selectedRatio === '4:3') { return 4 / 3; } if (this.selectedRatio === '21:9') { return 21 / 9; } if (this.selectedRatio === '原画' && Number.isFinite(this.videoWidth) && Number.isFinite(this.videoHeight) && this.videoWidth > 0 && this.videoHeight > 0) { return this.videoWidth / this.videoHeight; } if (this.selectedRatio === '铺满屏幕' && this.viewportWidth > 0 && this.viewportHeight > 0) { return this.playerWidth / this.viewportHeight; } return 19 / 6; }
    private updatePlayerLayout(): void {
      try {
        // 全屏：容器固定占满屏幕（控制栏因此始终是屏幕宽度），
        // 视频画面由 AVPlayer 的 videoScaleType(FIT) 按源尺寸等比留黑并水平居中。
        const layoutSpan: number = this.viewportWidth * (this.tablet() && !this.fullScreen ? 0.68 : 1);
        if (!Number.isFinite(layoutSpan) || layoutSpan <= 0) { return; }
        const parentTall: number = this.fullScreen ? this.viewportHeight : layoutSpan * 3 / 4;
        if (!Number.isFinite(parentTall) || parentTall <= 0) { return; }
        const ratio: number = this.ratioValue(); if (!Number.isFinite(ratio) || ratio <= 0) { return; }
        const layoutTall: number = this.selectedRatio === '铺满屏幕' ? parentTall : Math.min(layoutSpan / ratio, parentTall);
        if (!Number.isFinite(layoutTall) || layoutTall <= 0) { return; }
        this.playerWidth = layoutSpan; this.playerContainerHeight = parentTall; this.playerHeight = layoutTall;
      } catch (_) { Logger.error('PlayerEngine', '更新播放器画面布局失败'); }
    }
    private selectRatio(ratio: string): void {
      if (!this.ratioOptions.includes(ratio)) { return; }
      try { const instance = this.player; if (instance) { instance.videoScaleType = ratio === '铺满屏幕' ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT; } this.selectedRatio = ratio; this.updatePlayerLayout(); Logger.info('PlayerEngine', '切换画面比例：' + ratio); }
      catch (_) { Logger.error('PlayerEngine', '切换画面比例失败'); } finally { this.ratioMenuVisible = false; this.reveal(); }
    }
    private selectSpeed(index: number): void {
      try { if (this.sessionControlBlocked() || !Number.isInteger(index) || index < 0 || index >= this.speedValues.length) { return; } this.player?.setSpeed(this.speedValues[index]); this.speedIndex = index; void this.publishSessionState(); }
      catch (_) { Logger.error('PlayerEngine', '切换播放倍速失败'); } finally { this.speedMenuVisible = false; this.reveal(); }
    }
    private orderedEpisodeIndices(): number[] {
      // 只改变显示索引，不反转播放数据；选中态、下载任务和播放记录始终使用原始集数索引。
      const originalIndices: number[] = this.episodes.map((_episode: PlayerEpisode, index: number): number => index);
      return this.episodesDescending ? originalIndices.reverse() : originalIndices;
    }
    private episodeViewportSize(): string {
      try {
        const contentTall: number = Number.isFinite(this.episodeContentTall) ? Math.max(56, this.episodeContentTall) : 56;
        // 展开使用完整内容高度，不再用固定高度限制为 2~3 行。
        return (this.episodesExpanded ? contentTall : 56) + 'vp';
      } catch (error) {
        Logger.warn('PLAYER_EPISODES', '计算选集容器高度失败：' + String(error));
        return '56vp';
      }
    }
    private episodeButtonMaxSpan(): string {
      return this.episodeViewportSpan > 8 ? (this.episodeViewportSpan - 8) + 'vp' : '100%';
    }
    private resetEpisodeScroll(): void {
      try { this.episodeScroller.scrollTo({ xOffset: 0, yOffset: 0 }); }
      catch (error) { Logger.warn('PLAYER_EPISODES', '重置选集滚动位置失败：' + String(error)); }
    }
    private toggleEpisodeExpansion(): void {
      if (this.disposed || this.episodes.length === 0) { return; }
      const nextExpanded: boolean = !this.episodesExpanded;
      // 收起前回到首行，避免留下滚动偏移或只显示半行按钮。
      this.resetEpisodeScroll();
      try {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => { this.episodesExpanded = nextExpanded; });
      } catch (error) {
        this.episodesExpanded = nextExpanded;
        Logger.warn('PLAYER_EPISODES', '选集展开收起动画不可用：' + String(error));
      }
    }
    private toggleEpisodeOrder(): void {
      if (this.disposed || this.episodes.length === 0) { return; }
      try {
        this.episodesDescending = !this.episodesDescending;
        this.resetEpisodeScroll();
        Logger.info('PLAYER_EPISODES', this.episodesDescending ? '选集切换为倒序' : '选集切换为正序');
      } catch (error) {
        Logger.error('PLAYER_EPISODES', '切换选集排序失败：' + String(error));
        this.toast('切换选集排序失败，请重试');
      }
    }
    private measureEpisodeContent(area: Area): void {
      if (this.disposed) { return; }
      try {
        const contentTall: number = Number(area.height);
        if (Number.isFinite(contentTall) && contentTall > 0 && Math.abs(contentTall - this.episodeContentTall) > 0.5) { this.episodeContentTall = contentTall; }
      } catch (error) { Logger.warn('PLAYER_EPISODES', '测量选集内容高度失败：' + String(error)); }
    }
    private measureEpisodeViewport(area: Area): void {
      if (this.disposed) { return; }
      try {
        const layoutSpan: number = Number(area.width);
        if (Number.isFinite(layoutSpan) && layoutSpan > 0 && Math.abs(layoutSpan - this.episodeViewportSpan) > 0.5) { this.episodeViewportSpan = layoutSpan; }
      } catch (error) { Logger.warn('PLAYER_EPISODES', '测量选集可用宽度失败：' + String(error)); }
    }
    private selectEpisode(index: number, fromSession: boolean = false): void {
      if (this.disposed || !Number.isInteger(index) || index < 0 || index >= this.episodes.length) { return; }
      try {
        if (!fromSession && this.sessionControlBlocked()) { return; }
        // 与原按钮点击流程一致；排序和展开操作不会调用此播放切换流程。
        if (index === this.episodeIndex) { this.reveal(); return; }
        this.playbackEntryVersion++;
        this.sharedSourceEpisodeIndex = -1;
        this.pendingSharedProgressMs = undefined;
        this.sharedSeekIssued = false;
        this.episodeIndex = index; this.routeIndex = 0; this.currentMs = 0; this.refreshDownload(); void this.selectSource(false); void this.saveWatchRecord();
      } catch (error) {
        Logger.error('PLAYER_EPISODES', '切换剧集失败：' + String(error));
        if (fromSession) { this.failSession('应用主控切集失败', error); }
        else { this.toast('切换剧集失败，请重试'); }
      }
    }
    private async shareCurrentEpisode(channel: string = 'share'): Promise<void> {
      try {
        const video: SearchVideoItem | undefined = this.video;
        const episode: PlayerEpisode | undefined = this.episodes[this.episodeIndex];
        const route: PlayerRoute | undefined = episode?.routes[this.routeIndex];
        if (!video || !episode || !route || !route.sourceUrl) { this.toast('当前剧集缺少可分享的播放链接'); return; }
        const shareIndex: number = this.sharedSourceEpisodeIndex >= 0 ? this.sharedSourceEpisodeIndex : this.episodeIndex;
        const playProgress: number = Number.isFinite(this.currentMs) ? Math.max(0, this.currentMs / 1000) : 0;
        Logger.info('PLAYER_HANDOFF', '打包当前集分享，来源=' + channel + '，集数=' + (shareIndex + 1) +
        '，接续进度=' + playProgress + '秒');
        // 第六个参数是渠道，第七个参数才是秒数；NFC 从注册的读取器取得同一进度。
        await ShareService.shareEpisode(this.context(), video, episode.title, route.sourceUrl, shareIndex, channel, playProgress);
      } catch (error) {
        Logger.error('PLAYER_HANDOFF', '发送当前播放进度失败：' + String(error));
        this.toast('隔空传送未完成');
      }
    }
    private async screenshot(): Promise<void> {
      const saved: boolean = await PlatformApi.saveWindowScreenshot(this.context());
      this.toast(saved ? '截图已保存' : '截图未保存，受保护的视频可能不支持截图，或当前平台暂不支持');
    }
    private measureTopBar(area: Area): void {
      if (this.disposed) { return; }
      const measuredSpan: number = Number(area.width);
      if (Number.isFinite(measuredSpan) && measuredSpan > 0 && Math.abs(measuredSpan - this.topBarSpan) > 0.5) { this.topBarSpan = measuredSpan; }
    }
    private topBarContentSpan(): number {
      // 窗口监听驱动播放器尺寸，区域监听补充平板分栏及安全区后的实际可用宽度；均为 vp。
      const outerInset: number = this.fullScreen ? 32 + this.safeInset(this.leftSafeInset) + this.safeInset(this.rightSafeInset) : 12;
      const availableSpan: number = this.topBarSpan > 0 ? this.topBarSpan : this.playerWidth - outerInset;
      return Math.max(1, availableSpan - 16);
    }
    private topIconSpan(): number { return this.fullScreen ? 24 : Math.max(24, Math.min(44, this.topBarContentSpan() / 10)); }
    private topControlGap(): number {
      // 全屏固定 16vp；非全屏保留原有响应式间距，并为新增的 24vp 图标预留空间。
      if (this.fullScreen) { return 16; }
      return Math.max(0, Math.min(16, (this.topBarContentSpan() - this.topIconSpan() * 4 - 204) / 7));
    }
    private topLabelSize(): string { return this.topBarContentSpan() >= 480 ? '14vp' : '12vp'; }
    @Builder private topIconButton(symbol: Resource, description: string, callback: () => void) {
      // 胶囊玻璃按钮：软玻璃底 + 细描边 + 背景模糊，尺寸与命中区沿用原逻辑。
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph(symbol).fontSize(Ui.fs('20vp', this.fontScale)).fontColor([Ui.ink(this.darkTheme)]);
      }.width(this.topIconSpan() + 'vp').height(this.fullScreen ? '24vp' : '44vp').padding('0vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius(this.fullScreen ? '12vp' : '22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        
        .accessibilityText(description)
        .onClick(() => { this.reveal(); callback(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private sessionIconButton() {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.wireless_projection')).fontSize(Ui.fs('24vp', this.fontScale)).fontColor([Ui.ink(this.darkTheme)]);
      }.width('24vp').height('24vp').padding('0vp').margin({ left: '0vp' })
        .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('12vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        .visibility(this.video !== undefined ? Visibility.Visible : Visibility.None).accessibilityText('协同同播')
        .onClick((): void => {
        try { this.openMediaSession(); }
        catch (error) { Logger.error('MEDIA_SESSION', '点击协同同播按钮失败：' + String(error)); }
      }).onTouch((event: TouchEvent): void => { event.stopPropagation(); });
    }
    @Builder private topSettingButton(symbol: Resource, label: string, description: string, callback: () => void) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: this.fullScreen ? 0 : 3 }) {
          SymbolGlyph(symbol).fontSize(Ui.fs('16vp', this.fontScale)).fontColor([Ui.ink(this.darkTheme)]);
          Text(label).fontSize(this.topLabelSize()).minFontSize('10vp').maxFontSize(this.topLabelSize()).fontColor(Ui.ink(this.darkTheme)).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .visibility(this.fullScreen ? Visibility.None : Visibility.Visible);
        }.width('100%').alignItems(VerticalAlign.Center).justifyContent(this.fullScreen ? FlexAlign.Center : FlexAlign.Start);
      }.layoutWeight(this.fullScreen ? 0 : 1).constraintSize({ minWidth: this.fullScreen ? '24vp' : '0vp', maxWidth: this.fullScreen ? '24vp' : '100%' })
        .height(this.fullScreen ? '24vp' : '44vp').padding({ left: this.fullScreen ? '0vp' : '4vp', right: this.fullScreen ? '0vp' : '4vp' })
        .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius(this.fullScreen ? '12vp' : '22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        
        .accessibilityText(description)
        .onClick(() => { this.reveal(); callback(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private topBar() {
      // 返回独占左侧；其余原控制项在同一个右侧 Row 中，全屏只改显隐和尺寸。
      Row({ space: this.fullScreen ? 16 : this.topControlGap() }) {
        // 全屏：左侧区域水平居中显示影视名 + 剧集。
        if (this.fullScreen) {
          Column({ space: '1vp' }) {
            Text(this.video?.tilie || this.video?.yhm || '无音影视')
              .fontSize(Ui.fs('13vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
            Text((this.liveMode ? '直播' : '第 ' + String(this.episodeIndex + 1) + ' 集') +
              (this.episodes.length > this.episodeIndex && this.episodes[this.episodeIndex] !== undefined ?
                ' · ' + this.episodes[this.episodeIndex].title : ''))
              .fontSize(Ui.fs('10vp', this.fontScale))
              .fontColor('#B3FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
          }
            .width(this.fullScreen ? '26%' : '0%')
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
        }
        // 返回按钮全局显示（竖屏与全屏都显示）。
        this.topIconButton($r('sys.symbol.chevron_left_circle'), '返回', () => { void this.back(); });
        Row({ space: this.topControlGap() }) {
          this.topIconButton($r('sys.symbol.share'), '分享到群', () => { void this.shareToGroup(); });
          this.topIconButton($r('sys.symbol.camera'), '截图', () => { void this.screenshot(); });
          this.topIconButton($r('sys.symbol.wireless_projection'), '投屏', () => { this.toast('尚未接入投屏服务'); });
          this.topIconButton($r('sys.symbol.square_grid_2x2'), '隔空传送', () => { void this.shareCurrentEpisode('airdrop'); });
          this.sessionIconButton();
          this.topSettingButton($r('sys.symbol.gearshape'), this.speedLabels[this.speedIndex], '播放倍速 ' + this.speedLabels[this.speedIndex], () => { this.ratioMenuVisible = false; this.episodeMenuVisible = false; this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.speedMenuVisible = !this.speedMenuVisible; }); });
          this.topSettingButton($r('sys.symbol.forward_end_fill'), '线路 ' + (this.routeIndex + 1), '切换播放线路，当前线路 ' + (this.routeIndex + 1), () => { if (this.sessionControlBlocked()) { return; } const count = this.episodes[this.episodeIndex]?.routes.length || 0; if (count < 2) { this.toast('暂无其他线路'); return; } this.routeIndex = (this.routeIndex + 1) % count; void this.selectSource(true); });
          this.topSettingButton($r('sys.symbol.square_grid_2x2'), '画面比例', '画面比例 ' + this.selectedRatio, () => { this.speedMenuVisible = false; this.episodeMenuVisible = false; this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.ratioMenuVisible = !this.ratioMenuVisible; }); });
          Column() {
            this.topIconButton($r('sys.symbol.list_number'), '选集，当前第 ' + (this.episodeIndex + 1) + ' 集', () => { this.ratioMenuVisible = false; this.speedMenuVisible = false; this.episodeMenuVisible = !this.episodeMenuVisible; });
          }.visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          Column() { this.favoriteButton(true); }.visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          Column() { this.downloadButton(true); }.visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
        }.layoutWeight(1).alignItems(VerticalAlign.Center).justifyContent(this.fullScreen ? FlexAlign.End : FlexAlign.Start);
      }.width('100%').height('52vp').padding({ left: '8vp', right: '8vp', top: '4vp', bottom: '4vp' }).alignItems(VerticalAlign.Center)
        .backgroundColor(Ui.glassTint(this.darkTheme)).backdropBlur(this.glassRadius()).borderRadius('26vp')
        
        .onAreaChange((_old: Area, area: Area) => { this.measureTopBar(area); })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); }).onHover((inside: boolean) => { this.hovered = inside; this.reveal(); });
    }
    @Builder private playbackIconButton() {
      // 页面唯一主行动点：品牌渐变圆形玻璃播放键。
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill')).fontSize(Ui.fs('22vp', this.fontScale)).fontColor(['#FFFFFF']);
      }.width('44vp').height('44vp').padding('0vp').borderRadius('22vp').backgroundColor(Color.Transparent)
        .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
        
        .accessibilityText(this.playing ? '暂停' : '播放')
        .onClick(() => { this.reveal(); void this.togglePlay(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private nextEpisodeIconButton() {
      // 始终挂载纯图标入口；末集通过 visibility 隐藏，主题和材质沿用控制栏。
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.forward_end_fill')).fontSize(Ui.fs('24vp', this.fontScale)).fontColor([Ui.ink(this.darkTheme)]);
      }.width('24vp').height('24vp').padding('0vp').margin({ left: '0vp' })
        .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('12vp')
        
        .visibility(this.episodeIndex < this.episodes.length - 1 ? Visibility.Visible : Visibility.None)
        .accessibilityText('下一集')
        .onClick(() => {
        try {
          const nextIndex: number = this.episodeIndex + 1;
          if (this.disposed || nextIndex >= this.episodes.length) {
            Logger.warn('PLAYER_EPISODES', '忽略下一集点击：页面已退出或没有下一集');
            return;
          }
          Logger.info('PLAYER_EPISODES', '底部控制栏请求播放下一集：第 ' + (nextIndex + 1) + ' 集');
          this.reveal();
          // 复用原选集入口，不另行修改播放、切源或记录逻辑。
          this.selectEpisode(nextIndex);
        } catch (error) {
          Logger.error('PLAYER_EPISODES', '底部控制栏下一集点击失败：' + String(error));
        }
      }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private fullScreenIconButton() {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph(this.fullScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right')).fontSize(Ui.fs('22vp', this.fontScale)).fontColor([Ui.ink(this.darkTheme)]);
      }.width('44vp').height('44vp').padding('0vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        .accessibilityText(this.fullScreen ? '退出全屏' : '全屏')
        .onClick(() => { this.reveal(); void this.toggleFullScreen(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private favoriteButton(compact: boolean = false) {
      // 顶栏沿用原星标、收藏动效与禁用条件，仅把材质换成玻璃胶囊。
      Button(compact ? (this.favoriteSelected ? '★' : '☆') : (this.favoriteSelected ? '★ 已收藏' : '☆ 收藏')).fontSize(Ui.fs('13vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.favoriteSelected ? Ui.accentStrong(this.darkTheme) : this.ink())
        .height(compact ? '24vp' : '44vp').constraintSize({ minWidth: compact ? '24vp' : '44vp', maxWidth: compact ? '24vp' : '100%' }).padding({ left: compact ? '0vp' : '12vp', right: compact ? '0vp' : '12vp' })
        .backgroundColor(this.favoriteSelected ? this.selectedSurface() : Ui.glassTintSoft(this.darkTheme))
        .borderRadius(compact ? '12vp' : '22vp')
        
        
        .scale({ x: this.favoriteScale, y: this.favoriteScale }).enabled(!this.favoriteBusy && this.video !== undefined).accessibilityText(this.favoriteSelected ? '取消影视收藏' : '收藏当前影片')
        .onClick(() => { this.reveal(); this.toggleFavorite(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private downloadButton(compact: boolean = false) {
      // 紧凑入口保留文字/完成勾选，不替换原图标；完整实时状态仍供无障碍和详情区使用。
      Button(compact ? (this.downloadButtonState === PlayerDownloadPhase.COMPLETED ? '✓' : '下载') : (this.downloadControlPending ? '暂停中…' : this.downloadLabel)).fontSize(Ui.fs(compact ? '10vp' : '13vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(this.downloadProblem ? this.warningInk() : this.downloadButtonState === PlayerDownloadPhase.COMPLETED ? this.ink() : Ui.accentStrong(this.darkTheme))
        .height(compact ? '24vp' : '44vp').constraintSize({ minWidth: compact ? '24vp' : '44vp', maxWidth: compact ? '24vp' : '100%' }).padding({ left: compact ? '0vp' : '12vp', right: compact ? '0vp' : '12vp' })
        .backgroundColor(this.downloadButtonState === PlayerDownloadPhase.COMPLETED || this.downloadProblem ? Ui.glassTintSoft(this.darkTheme) : this.selectedSurface())
        .borderRadius(compact ? '12vp' : '22vp')
        
        .enabled(this.canControlDownload())
        .accessibilityText((this.downloadControlPending ? '正在暂停下载任务' : this.downloadLabel) + (this.downloadDetail ? '，' + this.downloadDetail : ''))
        .onClick(() => { this.reveal(); void this.downloadEpisode(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private ratioPopup() {
      Column({ space: 8 }) {
        Text('画面比例').fontSize(Ui.fs('16vp', this.fontScale)).fontColor(this.ink()).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: '6vp' });
        ForEach(this.ratioOptions, (ratio: string) => {
          Button(ratio).width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.selectedRatio === ratio ? Ui.accentStrong(this.darkTheme) : this.ink()).backgroundColor(this.selectedRatio === ratio ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp').onClick(() => { this.selectRatio(ratio); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
        }, (ratio: string) => ratio);
      }.width('220vp').padding('16vp').backgroundColor(this.solidPanel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.9, y: 0.9 } }).onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .visibility(this.ratioMenuVisible ? Visibility.Visible : Visibility.None);
    }
    @Builder private speedPopup() {
      Column({ space: 8 }) {
        Text('播放倍速').fontSize(Ui.fs('16vp', this.fontScale)).fontColor(this.ink()).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: '6vp' });
        ForEach(this.speedLabels, (label: string, index: number) => {
          Button(label).width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.speedIndex === index ? Ui.accentStrong(this.darkTheme) : this.ink()).backgroundColor(this.speedIndex === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp').onClick(() => { this.selectSpeed(index); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
        }, (_label: string, index: number) => index.toString());
      }.width('220vp').padding('16vp').backgroundColor(this.solidPanel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.9, y: 0.9 } }).onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .visibility(this.speedMenuVisible ? Visibility.Visible : Visibility.None);
    }
    @Builder private episodePopup() {
      Column({ space: 12 }) {
        Text('选集 · ' + this.episodes.length + ' 集').fontSize(Ui.fs('18vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).width('100%');
        Scroll() {
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start, alignContent: FlexAlign.Start }) {
            ForEach(this.orderedEpisodeIndices(), (index: number) => {
              Button(this.episodes[index].title).fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.episodeIndex === index ? Ui.accentStrong(this.darkTheme) : this.ink()).height('48vp').padding({ left: '16vp', right: '16vp' })
                .backgroundColor(this.episodeIndex === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp').constraintSize({ maxWidth: '100%' }).margin({ right: '8vp', bottom: '8vp' })
                .onClick(() => { this.selectEpisode(index); this.episodeMenuVisible = false; this.reveal(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
            }, (index: number): string => index.toString());
          }.width('100%');
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto);
      }.width(Math.max(200, Math.min(360, this.viewportWidth - 32 - this.safeInset(this.leftSafeInset) - this.safeInset(this.rightSafeInset))) + 'vp')
        .height(Math.max(120, Math.min(360, this.viewportHeight - 48 - this.safeBottom())) + 'vp').padding('16vp')
        .backgroundColor(this.solidPanel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        
        .visibility(this.fullScreen && this.episodeMenuVisible ? Visibility.Visible : Visibility.None).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
  private async restoreDanmakuSettings(): Promise<void> {
    try {
      const settings: DanmakuSettings = await DanmakuService.loadSettings(this.context());
      if (this.disposed) { return; }
      this.danmakuEnabled = settings.enabled; this.danmakuFontSize = settings.fontSize;
      this.danmakuOpacity = settings.opacity; this.danmakuSpeed = settings.speed;
      this.danmakuDensity = settings.density; this.danmakuSyncEnabled = settings.syncEnabled;
    } catch (error) { Logger.warn('DANMAKU', '读取弹幕设置失败：' + String(error)); }
  }
  private async persistDanmakuSettings(): Promise<void> {
    try { await DanmakuService.saveSettings(this.context(), { enabled: this.danmakuEnabled, fontSize: this.danmakuFontSize, opacity: this.danmakuOpacity, speed: this.danmakuSpeed, density: this.danmakuDensity, syncEnabled: this.danmakuSyncEnabled }); }
    catch (error) { Logger.warn('DANMAKU', '保存弹幕设置失败：' + String(error)); }
  }
  private async importDanmakuFile(): Promise<void> {
    if (this.danmakuLoading) { return; }
    this.danmakuLoading = true;
    try {
      const uris: string[] = await new picker.DocumentViewPicker(this.context()).select(new picker.DocumentSelectOptions());
      if (uris.length === 0) { this.danmakuStatus = '已取消文件导入'; return; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const size: number = Number(fileIo.statSync(file.fd).size);
        if (size <= 0 || size > 8 * 1024 * 1024) { throw new Error('文件为空或超过 8MB'); }
        const data: ArrayBuffer = new ArrayBuffer(size);
        let read: number = 0;
        while (read < size) { const count: number = fileIo.readSync(file.fd, data, { offset: read, length: size - read }); if (count <= 0) { break; } read += count; }
        text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(data, 0, read));
      } finally { fileIo.closeSync(file); }
      const parsed: DanmakuItem[] = DanmakuService.parse(text);
      if (parsed.length === 0) { throw new Error('未识别到有效弹幕。支持 Bilibili XML、ASS、SRT 及逐行文本'); }
      this.danmakuItems = parsed; this.lastDanmakuWindowSecond = -1; this.refreshDanmakuWindow(this.currentMs, true); this.danmakuStatus = '已导入 ' + parsed.length + ' 条弹幕'; this.danmakuEnabled = true;
    } catch (error) { this.danmakuStatus = '导入失败：' + String(error); }
    finally { this.danmakuLoading = false; }
  }
  private normalizeDanmakuTitle(value: string): string {
    return value.toLowerCase().replace(/<[^>]*>/g, '').replace(/[\s\p{P}\p{S}【】（）《》「」『』]/gu, '').replace(/第(\d+)(集|话|期)/g, '$1');
  }
  private scoreDanmakuTitle(query: string, candidate: string): number {
    const q: string = this.normalizeDanmakuTitle(query);
    const c: string = this.normalizeDanmakuTitle(candidate);
    if (!q || !c) { return 0; }
    if (q === c) { return 1; }
    if (c.indexOf(q) >= 0 || q.indexOf(c) >= 0) { return Math.min(q.length, c.length) / Math.max(q.length, c.length) * 0.9 + 0.1; }
    let common: number = 0;
    const grams: string[] = q.length >= 2 ? q.match(/.{1,2}/g) || [] : [q];
    for (let i: number = 0; i < grams.length; i++) { if (c.indexOf(grams[i]) >= 0) { common++; } }
    return grams.length > 0 ? common / grams.length : 0;
  }
  private async searchDanmakuOnline(): Promise<void> {
    if (this.danmakuLoading) { return; }
    const keyword: string = (this.danmakuSearchKeyword || this.video?.tilie || this.video?.yhm || '').trim();
    this.danmakuLoading = true; this.danmakuStatus = '正在搜索并匹配在线弹幕…';
    try {
      let combinedResults: DanmakuSearchResult[] = [];
      let dandanError: string = '';
      try { combinedResults = combinedResults.concat(await DanmakuService.searchDandanPlay(keyword)); } catch (error) { dandanError = String(error); }
      try { combinedResults = combinedResults.concat(await DanmakuService.searchBilibili(keyword)); } catch (error) { if (combinedResults.length === 0) { this.danmakuStatus = '在线弹幕搜索失败：' + String(error); return; } }
      this.danmakuSearchResults = combinedResults;
      if (this.danmakuSearchResults.length === 0) { this.danmakuStatus = dandanError ? '弹弹play暂不可用，B站也未找到候选：' + dandanError : '没有找到匹配视频，可尝试补充年份或集数'; return; }
      const ranked: DanmakuRankedResult[] = this.danmakuSearchResults.map((result: DanmakuSearchResult): DanmakuRankedResult => { return { result: result, score: this.scoreDanmakuTitle(keyword, result.title) }; }).sort((a: DanmakuRankedResult, b: DanmakuRankedResult) => b.score - a.score);
      const best = ranked[0];
      const secondScore: number = ranked.length > 1 ? ranked[1].score : 0;
      // 仅在匹配度足够高且明显领先时自动加载，避免把同名作品或错误分集的弹幕套到影片上。
      if (best.score >= 0.78 && best.score - secondScore >= 0.12) {
        this.danmakuStatus = '自动匹配成功（' + Math.round(best.score * 100) + '%）：' + best.result.title;
        await this.loadOnlineDanmaku(best.result);
      } else {
        this.danmakuSearchResults = ranked.map((item) => item.result);
        this.danmakuStatus = '找到候选结果，请确认正确影片/分集后点击“加载”';
      }
    } catch (error) { this.danmakuStatus = '在线搜索失败：' + String(error); }
    finally { this.danmakuLoading = false; }
  }
  private async loadOnlineDanmaku(result: DanmakuSearchResult): Promise<void> {
    this.danmakuLoading = true; this.danmakuStatus = '正在加载' + (result.source === 'dandanplay' ? '弹弹play' : 'B站') + '在线弹幕…';
    try {
      const items: DanmakuItem[] = await DanmakuService.loadOnline(result);
      this.danmakuItems = items; this.lastDanmakuWindowSecond = -1; this.refreshDanmakuWindow(this.currentMs, true); this.danmakuEnabled = true; this.danmakuStatus = (result.source === 'dandanplay' ? '弹弹play' : 'B站') + '在线弹幕已加载：' + items.length + ' 条';
    } catch (error) { this.danmakuStatus = '加载失败：' + String(error); }
    finally { this.danmakuLoading = false; }
  }
  private refreshDanmakuWindow(timeMs: number, force: boolean = false): void {
    const second: number = Math.floor(Math.max(0, timeMs) / 1000);
    if (!force && second === this.lastDanmakuWindowSecond) { return; }
    this.lastDanmakuWindowSecond = second;
    const nowSec: number = Math.max(0, timeMs) / 1000;
    const durationSec: number = 10 / Math.max(0.5, this.danmakuSpeed);
    const minLane: number = Math.max(2, Math.floor(this.danmakuDensity / 10));
    // 只在播放秒数变化时扫描完整列表；同屏最多保留 40 条，避免大量 Text 同时参与布局。
    this.activeDanmakuItems = this.danmakuItems.filter((item: DanmakuItem) =>
      nowSec >= item.timeSec - 0.1 && nowSec <= item.timeSec + durationSec && (item.lane % 10) < minLane
    ).slice(0, 40);
  }

  private addManualDanmaku(text: string): void {
    const item: DanmakuItem = { id: 'manual-' + Date.now().toString(), text, timeSec: Math.max(0, this.currentMs / 1000), mode: 1, color: '#FFFFFF', lane: Math.floor(Math.random() * 8) };
    this.danmakuItems = [...this.danmakuItems, item].sort((a: DanmakuItem, b: DanmakuItem) => a.timeSec - b.timeSec).slice(-12000);
    this.danmakuMessages = [...this.danmakuMessages, text].slice(-30); this.danmakuEnabled = true;
  }
    @Builder private danmakuOverlay() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.danmakuEnabled) {
          ForEach(this.activeDanmakuItems, (item: DanmakuItem) => {
            Text(item.text).fontSize(Ui.fs(this.danmakuFontSize + 'vp', this.fontScale)).fontColor(item.color || '#FFFFFF')
              .fontWeight(FontWeight.Medium).textShadow({ radius: 3, color: '#DD000000', offsetX: 1, offsetY: 1 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Clip }).position({
                x: this.playerWidth - Math.max(0, this.currentMs / 1000 - item.timeSec) * 100 * this.danmakuSpeed,
                y: 14 + (item.lane % 10) * (this.danmakuFontSize + 8)
              })
              .opacity(this.danmakuOpacity).hitTestBehavior(HitTestMode.None);
          }, (item: DanmakuItem) => item.id);
        }
      }.width('100%').height('100%')
        .visibility(this.fullScreen && this.danmakuEnabled ? Visibility.Visible : Visibility.None)
        .hitTestBehavior(HitTestMode.None);
    }
    // 弹幕设置改用 ArkUI 原生 ContentCover 模态层，脱离播放器 Stack/手势层的命中测试。
    @Builder private danmakuSettingsCover() {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
          .onClick(() => { this.danmakuPanelVisible = false; });
        Scroll() {
          Column({ space: 12 }) {
            Row() {
              Text('弹幕设置').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).fontWeight(FontWeight.Medium).layoutWeight(1);
              Button('关闭').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).height('32vp').padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('16vp')
                
                .onClick(() => { this.danmakuPanelVisible = false; });
            }.width('100%');
            Row({ space: 8 }) {
              Text('弹幕显示').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme)).layoutWeight(1);
              Button(this.danmakuEnabled ? '已开启' : '已关闭').fontSize(Ui.fs('12vp', this.fontScale)).height('36vp').padding({ left: '14vp', right: '14vp' })
                .fontColor(this.danmakuEnabled ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
                .backgroundColor(this.danmakuEnabled ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
                .borderRadius('18vp')
                
                .onClick(() => { this.danmakuEnabled = !this.danmakuEnabled; void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('字号').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme));
              Button('A−').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).padding({ left: '12vp', right: '12vp' })
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('17vp')
                
                .onClick(() => { this.danmakuFontSize = Math.max(12, this.danmakuFontSize - 2); void this.persistDanmakuSettings(); });
              Text(this.danmakuFontSize + 'vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme));
              Button('A+').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).padding({ left: '12vp', right: '12vp' })
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('17vp')
                
                .onClick(() => { this.danmakuFontSize = Math.min(32, this.danmakuFontSize + 2); void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('透明度').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme));
              Slider({ value: this.danmakuOpacity * 100, min: 30, max: 100, step: 5 }).layoutWeight(1)
                .trackColor(Ui.divider(this.darkTheme)).selectedColor(Ui.accent(this.darkTheme)).blockColor(Ui.ink(this.darkTheme))
                .onChange((value: number) => { this.danmakuOpacity = value / 100; void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('滚动速度').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme));
              Slider({ value: this.danmakuSpeed, min: 0.5, max: 2, step: 0.25 }).layoutWeight(1)
                .trackColor(Ui.divider(this.darkTheme)).selectedColor(Ui.accent(this.darkTheme)).blockColor(Ui.ink(this.darkTheme))
                .onChange((value: number) => { this.danmakuSpeed = value; void this.persistDanmakuSettings(); });
              Text(this.danmakuSpeed.toFixed(2) + '×').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme));
            }.width('100%');
            Row({ space: 8 }) {
              Text('协播弹幕同步').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme)).layoutWeight(1);
              Button(this.danmakuSyncEnabled ? '开启' : '关闭').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).padding({ left: '14vp', right: '14vp' })
                .fontColor(this.danmakuSyncEnabled ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
                .backgroundColor(this.danmakuSyncEnabled ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
                .borderRadius('17vp')
                
                .onClick(() => { this.danmakuSyncEnabled = !this.danmakuSyncEnabled; void this.persistDanmakuSettings(); });
            }.width('100%');
            // 弹幕输入条与首页搜索条同一套玻璃配方：软玻璃底 + 全圆角 + 细描边 + 背景模糊。
            Row({ space: 8 }) {
              TextInput({ placeholder: '输入一条弹幕…', text: this.danmakuInput }).layoutWeight(1).height('44vp')
                .fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp').padding({ left: '16vp', right: '16vp' })
                
                .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
                .onChange((value: string) => { this.danmakuInput = value; });
              Button('发送').height('44vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor('#FFFFFF').padding({ left: '18vp', right: '18vp' }).backgroundColor(Color.Transparent)
                .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
                .borderRadius('22vp')
                .onClick(() => {
                const text = this.danmakuInput.trim();
                if (text.length > 0) { this.addManualDanmaku(text); this.danmakuInput = ''; void this.persistDanmakuSettings(); }
              });
            }.width('100%');
            Row({ space: 8 }) {
              Button(this.danmakuLoading ? '处理中…' : '导入本地文件').fontSize(Ui.fs('12vp', this.fontScale)).height('38vp').fontColor(Ui.ink(this.darkTheme)).padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('19vp')
                
                .enabled(!this.danmakuLoading).onClick(() => { void this.importDanmakuFile(); });
              Button('在线搜索').fontSize(Ui.fs('12vp', this.fontScale)).height('38vp').fontColor(Ui.accentStrong(this.darkTheme)).padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.accentSoft(this.darkTheme)).borderRadius('19vp')
                
                .enabled(!this.danmakuLoading).onClick(() => { void this.searchDanmakuOnline(); });
            }.width('100%');
            TextInput({ placeholder: '影片名 / 年份 / 分集', text: this.danmakuSearchKeyword }).height('40vp').fontSize(Ui.fs('13vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme)).placeholderColor(Ui.inkFaint(this.darkTheme)).caretColor(Ui.accent(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp').padding({ left: '14vp', right: '14vp' })
              
              .onChange((value: string) => { this.danmakuSearchKeyword = value; });
            ForEach(this.danmakuSearchResults.slice(0, 5), (result: DanmakuSearchResult) => {
              Row({ space: 8 }) {
                Text((result.source === 'dandanplay' ? '[弹弹play] ' : '[B站] ') + result.title).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).maxLines(2).layoutWeight(1);
                Button('加载').fontSize(Ui.fs('12vp', this.fontScale)).height('32vp').fontColor(Ui.accentStrong(this.darkTheme)).padding({ left: '12vp', right: '12vp' })
                  .backgroundColor(Ui.accentSoft(this.darkTheme)).borderRadius('16vp')
                  
                  .onClick(() => { void this.loadOnlineDanmaku(result); });
              }.width('100%').padding({ top: '4vp', bottom: '4vp' });
            }, (result: DanmakuSearchResult) => result.source + '-' + result.sourceId);
            Text(this.danmakuStatus).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%');
          }.width('100%').padding('20vp')
            .backgroundColor(Ui.glassTintStrong(this.darkTheme)).backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur)).borderRadius('24vp')
                
        }.width('88%').height('78%').constraintSize({ maxWidth: '560vp', maxHeight: '78%' })
          .scrollBar(BarState.Auto).align(Alignment.Center); // 不设置 Block，避免父级 Scroll 阻断内部按钮、Slider 和 TextInput 的命中测试
      }.width('100%').height('100%').padding('0vp').margin('0vp')
        .backgroundColor(Color.Transparent)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END]);
    }
    @Builder private controller() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          // 单独分组固定播放/暂停与下一集之间的 16vp 间距，其他控件间距不变。
          Row({ space: '16vp' }) {
            this.playbackIconButton();
            this.nextEpisodeIconButton();
          }.height('44vp').alignItems(VerticalAlign.Center);
          Text(this.time(this.currentMs)).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.ink());
          Slider({ value: this.currentMs, min: 0, max: Math.max(1, this.durationMs), step: 1000 }).layoutWeight(1).trackColor(Ui.divider(this.darkTheme)).selectedColor(this.accent()).blockColor(this.ink()).enabled(this.durationMs > 0 && !this.receiverLocked && !this.isSlaveMode)
            .onChange((value: number, mode: SliderChangeMode) => {
            if (this.isSlaveMode || this.receiverLocked) { return; }
            this.seeking = mode !== SliderChangeMode.End; this.currentMs = value; this.reveal();
            if (mode === SliderChangeMode.End) { try { this.player?.seek(value, PlatformApi.seekModeClosest()); void this.saveWatchRecord(); void this.publishSessionState(); } catch (_) { this.report('定位进度失败'); } }
          });
          Text(this.time(this.durationMs)).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.ink());
          if (this.fullScreen) {
            Button('弹幕').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.danmakuEnabled ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme)).height('34vp').padding({ left: '12vp', right: '12vp' })
              .backgroundColor(this.danmakuPanelVisible ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme)).borderRadius('17vp')
              
              .onClick(() => { this.danmakuPanelVisible = true; this.reveal(); });
          }
          this.fullScreenIconButton();
        }.width('100%').height('44vp').alignItems(VerticalAlign.Center);
      }.padding('10vp').width('100%').backgroundColor(this.panel()).backdropBlur(this.glassRadius()).borderRadius('26vp')
        
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.closeControlMenus(); } event.stopPropagation(); }).onHover((inside: boolean) => { this.hovered = inside; this.reveal(); });
    }
    @Builder private downloadProgressPanel() {
      Column({ space: 6 }) {
        // 切换全屏只更新 visibility；不清空消息、不重建进度控件。
        Row({ space: 6 }) {
          LoadingProgress().width('20vp').height('20vp').color(this.accent()).visibility(this.downloadButtonState === PlayerDownloadPhase.SNIFFING ? Visibility.Visible : Visibility.None);
          Text(this.downloadDetail).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.downloadProblem ? this.warningInk() : this.mutedInk()).layoutWeight(1).maxLines(3)
            .visibility(this.fullScreen ? Visibility.None : Visibility.Visible);
          Blank().visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          Text(this.byteText(this.downloadSpeed) + '/s').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.accent())
            .visibility(this.downloadButtonState === PlayerDownloadPhase.DOWNLOADING ? Visibility.Visible : Visibility.None);
        }.width('100%').alignItems(VerticalAlign.Center)
          .visibility(!this.fullScreen || this.downloadButtonState === PlayerDownloadPhase.SNIFFING || this.downloadButtonState === PlayerDownloadPhase.DOWNLOADING ? Visibility.Visible : Visibility.None);
        Progress({ value: this.downloadPercent, total: 100, type: ProgressType.Linear }).width('100%').color(this.accent()).backgroundColor(Ui.divider(this.darkTheme))
          .accessibilityText((this.downloadButtonState === PlayerDownloadPhase.SNIFFING ? '地址嗅探进度 ' : '下载进度 ') + this.downloadPercent + '%')
          .visibility((this.downloadButtonState !== PlayerDownloadPhase.READY || this.downloadPercent > 0) && (!this.fullScreen || this.downloadButtonState !== PlayerDownloadPhase.COMPLETED) ? Visibility.Visible : Visibility.None);
      }.width('100%').padding('10vp').backgroundColor(this.panel()).borderRadius('24vp')
        
        
        .visibility(this.downloadDetail.length > 0 && (!this.fullScreen || (this.downloadButtonState !== PlayerDownloadPhase.COMPLETED && (this.downloadButtonState !== PlayerDownloadPhase.READY || this.downloadPercent > 0))) ? Visibility.Visible : Visibility.None)
        .onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private episodeSelector() {
      Column({ space: 12 }) {
        // 选集标题整行可点击；与排序、下载和集数按钮分离，避免切集时误触展开收起。
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text('选集 · ' + this.episodes.length + ' 集').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(this.ink()).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.episodesExpanded ? '收起' : '展开').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.mutedInk());
            Text('⌄').fontSize(Ui.fs('20vp', this.fontScale)).fontColor(this.accent()).rotate({ angle: this.episodesExpanded ? 180 : 0 });
          }.width('100%');
        }.width('100%').height('44vp').padding(0).backgroundColor(Color.Transparent).borderRadius('8vp')
          .accessibilityText('选集，共 ' + this.episodes.length + ' 集，' + (this.episodesExpanded ? '已展开，点击收起' : '已收起，点击展开'))
          .onClick(() => { this.toggleEpisodeExpansion(); });
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, alignContent: FlexAlign.Start }) {
          Button(this.episodesDescending ? '↑ 倒序' : '↓ 正序').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.accentStrong(this.darkTheme)).height('44vp').constraintSize({ minWidth: '76vp' }).padding({ left: '12vp', right: '12vp' })
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp').margin({ right: '8vp', bottom: '8vp' })
            .accessibilityText(this.episodesDescending ? '当前倒序排列，点击切换正序' : '当前正序排列，点击切换倒序')
            .onClick(() => { this.toggleEpisodeOrder(); });
          Column() { this.downloadButton(); }.margin({ bottom: '8vp' });
        }.width('100%');
        this.downloadProgressPanel();
        Text('下载前自动校验网络权限与存储空间，视频保存到应用私有目录').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.mutedInk()).width('100%')
          .visibility(this.downloadDetail.length === 0 ? Visibility.Visible : Visibility.None);
        // 保持同一棵换行布局，动画仅改变视口高度；折叠只显示首行，展开完整展示所有行。
        // 内部不拦截滚动手势，超出屏幕的集数由页面外层 Scroll 统一竖向滚动。
        Scroll(this.episodeScroller) {
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start, alignContent: FlexAlign.Start }) {
            ForEach(this.orderedEpisodeIndices(), (index: number) => {
              Button(this.episodes[index].title).fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.episodeIndex === index ? Ui.accentStrong(this.darkTheme) : this.ink()).height('48vp').padding({ left: '16vp', right: '16vp' }).backgroundColor(this.episodeIndex === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme)).borderRadius('24vp')
                
                .constraintSize({ maxWidth: this.episodeButtonMaxSpan() }).margin({ right: '8vp', bottom: '8vp' })
                .onClick(() => { this.selectEpisode(index); });
            }, (index: number): string => index.toString());
          }.width('100%').constraintSize({ minHeight: '56vp' }).onAreaChange((_old: Area, area: Area) => { this.measureEpisodeContent(area); });
        }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).enableScrollInteraction(false).edgeEffect(EdgeEffect.None)
          .width('100%').height(this.episodeViewportSize()).clip(true).onAreaChange((_old: Area, area: Area) => { this.measureEpisodeViewport(area); });
      }.width('100%');
    }
    @Builder private infoPanel() {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Text(this.video?.tilie || this.video?.yhm || '影片详情').fontSize(Ui.fs('20vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
          this.favoriteButton();
        }.width('100%');
        if (this.video?.genxi) { Text(this.video.genxi).fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.mutedInk()).width('100%'); }
        this.episodeSelector();
      }.padding('16vp').width('100%').backgroundColor(this.panel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        
    }
    build() {
      if (this.missingParams || this.episodes.length === 0) {
        Column({ space: 16 }) {
          Text(this.missingParams ? '无法打开播放页：缺少影片信息' : '当前影片尚未配置可播放资源').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(this.ink());
          Button('返回').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor('#FFFFFF').padding({ left: '24vp', right: '24vp' }).backgroundColor(Color.Transparent)
            .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
            .borderRadius('22vp')
            .onClick(() => { void this.back(); });
        }.padding({ top: '24vp', bottom: (24 + this.safeBottom()) + 'vp', left: (24 + this.safeInset(this.leftSafeInset)) + 'vp', right: (24 + this.safeInset(this.rightSafeInset)) + 'vp' })
          .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.canvas())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Flex({ direction: this.tablet() && !this.fullScreen ? FlexDirection.Row : FlexDirection.Column }) {
            Stack({ alignContent: Alignment.Center }) {
              Stack({ alignContent: Alignment.Center }) {
                XComponent({ id: 'wuyin-player-surface', type: XComponentType.SURFACE, controller: this.surfaceController }).width('100%').height('100%').backgroundColor('#000000').onLoad(() => { this.surfaceReady = true; this.startWhenReady(); });
                // 亮度遮罩仅覆盖视频，并完全退出命中测试；窗口亮度由手势层的 AppBrightnessUtil 管理。
                Column().width('100%').height('100%').backgroundColor(`rgba(0,0,0,${this.brightnessShade})`).hitTestBehavior(HitTestMode.None);
                PlayerGestureLayer({
                  currentMs: this.currentMs, durationMs: this.durationMs, volumeValue: this.volumeValue,
                    // 沿用既有手势层锁定接口，使入会等待阶段也受从机状态约束。
                  receiverLocked: this.isSlaveMode || this.receiverLocked,
                    onReveal: (): void => { this.revealFromGesture(); },
                    onToggleControls: (): void => { this.toggleControls(); },
                    onToggle: async (): Promise<void> => { await this.togglePlay(); },
                    onSeek: async (targetMs: number): Promise<void> => { await this.seekFromGesture(targetMs); },
                    onVolume: (level: number): void => { this.volumeFromGesture(level); },
                    onBrightnessMask: (level: number): void => {
                    try { if (!this.disposed && !this.isSlaveMode && !this.receiverLocked) { this.brightnessShade = Math.max(0, Math.min(0.95, level)); } }
                    catch (error) { Logger.warn('PLAYER_GESTURE', '更新视频亮度遮罩失败：' + String(error)); }
                  }
                });
                if (this.loading || this.errorText) {
                  Column({ space: 12 }) {
                    if (this.loading && !this.errorText) { LoadingProgress().width('32vp').height('32vp').color(this.accent()); }
                    Text(this.errorText || '加载中…').fontColor(this.errorText ? this.warningInk() : this.ink()).fontSize(Ui.fs('15vp', this.fontScale)).textAlign(TextAlign.Center);
                  }.padding('20vp').constraintSize({ maxWidth: '90%' }).backgroundColor(this.panel()).borderRadius('24vp')
                                
                    .align(Alignment.Center).hitTestBehavior(HitTestMode.None);
                }
              }.width('100%').height(this.playerHeight + 'vp').backgroundColor('#000000');
              // 控制层后绘制，位于手势层之上；空白区域透传，按钮自身停止事件传播。
              Column() {
                // 全屏：显示顶部控制栏（返回图标隐藏）；竖屏：只显示返回键。
                if (this.fullScreen) {
                  this.topBar();
                } else {
                  Row() {
                    this.topIconButton($r('sys.symbol.chevron_left_circle'), '返回', () => { void this.back(); });
                  }
                    .width('100%')
                    .padding({ left: this.safeInset(12) + 'vp', top: '0vp' })
                    .justifyContent(FlexAlign.Start)
                }
                Column() { this.downloadProgressPanel(); }.width('100%')
                  .visibility(this.fullScreen && this.downloadDetail.length > 0 && this.downloadButtonState !== PlayerDownloadPhase.COMPLETED && (this.downloadButtonState !== PlayerDownloadPhase.READY || this.downloadPercent > 0) ? Visibility.Visible : Visibility.None);
                Blank().hitTestBehavior(HitTestMode.None);
                this.controller();
              }.width('100%').height('100%')
                  .hitTestBehavior(HitTestMode.Transparent).visibility(this.controlsVisible ? Visibility.Visible : Visibility.None);
            }.width(this.playerWidth + 'vp').height(this.playerContainerHeight + 'vp').backgroundColor('#000000').onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.closeControlMenus(); } }).onHover((inside: boolean) => { this.hovered = inside; this.reveal(); });
            // 原收藏、下载及选集区域不移除，退出全屏后恢复原位置及展开/滚动状态。
            Scroll() {
              Column() { this.infoPanel(); }.width('100%')
                .padding({ top: '10vp', left: '10vp', right: '10vp', bottom: (10 + this.safeBottom()) + 'vp' }).alignItems(HorizontalAlign.Start);
            }.width(this.tablet() ? '32%' : '100%').layoutWeight(this.fullScreen ? 0 : 1).scrollBar(BarState.Off)
              .visibility(this.fullScreen ? Visibility.None : Visibility.Visible);
          }.width('100%').height('100%').backgroundColor(this.canvas()).onAreaChange((_old: Area, area: Area) => { this.resizePlayer(Number(area.width), Number(area.height)); });
          Stack({ alignContent: Alignment.Center }) {
            Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme)).onClick(() => { this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.closeControlMenus(); }); });
            this.ratioPopup();
            this.speedPopup();
            this.episodePopup();
          }.width('100%').height('100%')
            .visibility(this.ratioMenuVisible || this.speedMenuVisible || (this.fullScreen && this.episodeMenuVisible) ? Visibility.Visible : Visibility.None)
            .padding({ bottom: this.safeBottom() + 'vp', left: this.fullScreen ? this.safeInset(this.leftSafeInset) + 'vp' : '0vp', right: this.fullScreen ? this.safeInset(this.rightSafeInset) + 'vp' : '0vp' });
          this.danmakuOverlay();
          MediaSessionDialog({ visible: this.sessionDialogVisible, service: this.sessionService,
              quest3Service: this.quest3Service,
              getQuestPayload: (): Quest3CoPlayPayload => this.quest3Payload(),
              getQuestCurrentMs: (): number => this.currentMs,
              getQuestEpisodeIndex: (): number => this.episodeIndex,
              getQuestSpeed: (): number => [0.75, 1, 1.25, 1.75, 2][this.speedIndex],
              onQuestState: (packet: Quest3StatePacket): void => this.onQuest3State(packet),
              onClose: (): void => {
              try { this.sessionDialogVisible = false; this.reveal(); }
              catch (error) { Logger.warn('MEDIA_SESSION', '关闭同播浮层失败：' + String(error)); }
            }
          });
          // 播放中同样展示聊天室实时提醒（顶部弹窗不拦截视频手势，7 秒自动收起）。
          ChatNoticeBanner()
          if (this.shareGroupVisible) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('#66000000')
                .onClick(() => { this.shareGroupVisible = false; })
              this.shareGroupPanel()
            }
              .width('100%')
              .height('100%')
          }
        }.width('100%').height('100%').backgroundColor(this.canvas())
        // 当前 SDK 没有 SafeAreaType.None 命名成员；零类型掩码表示不启用安全区避让。
          // 根容器统一扩展进状态栏（不再让系统预留安全区），
          // 再用 padding.top = 状态栏高度把内容摆回可见区域。
          .expandSafeArea([SafeAreaType.SYSTEM],
            this.fullScreen ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .padding({
            left: this.fullScreen ? '0vp' : this.safeInset(this.leftSafeInset) + 'vp',
            right: this.fullScreen ? '0vp' : this.safeInset(this.rightSafeInset) + 'vp',
            top: this.fullScreen ? '0vp' : (this.safeInset(24) * 2) + 'vp'
          })
          .bindContentCover(this.danmakuPanelVisible, this.danmakuSettingsCover(), { modalTransition: ModalTransition.NONE });
      }
    }
  }

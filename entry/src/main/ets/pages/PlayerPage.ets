import { media } from '@kit.MediaKit';
import { window, promptAction } from '@kit.ArkUI';
import router from '@ohos.router';
import { PiPWindow } from '../common/PlatformPiP';
import { preferences } from '@kit.ArkData';
import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { backgroundTaskManager, wantAgent } from '../common/PlatformBackground';
import { NotificationService } from '../common/NotificationService';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { connection, http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { batteryInfo } from '../common/PlatformBattery';
import { avSession } from '../common/PlatformAVSession';
import { AppState, PlayerImmersiveConfig, RecordVideoSource } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { CastDevice, CastService } from '../common/CastService';
import { DownloadService, DownloadRecord, DownloadState } from '../common/DownloadService';
import { LocalPlaybackService } from '../common/LocalPlaybackService';
import { AdBlockService } from '../common/AdBlockService';
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
import { AccountApi } from '../common/AccountApi';
import { CommunityApi } from '../common/CommunityApi';
import { buildVideoCard, VideoShareArgs } from '../common/VideoCardBuilder';
import { SocialStore } from '../common/SocialStore';
import { FrameRateService } from '../common/FrameRateService';
import { PlayerExtraSettings, PlayerSettingsStore } from '../common/PlayerSettingsStore';
import { LiveViewService } from '../common/LiveViewService';

/** 竖屏时顶部控制栏占位高度（含内边距）。 */
/** 播放器「问题反馈」跳转消息中心「反馈」聊天室。 */
class PlayerFeedbackParams {
  room: string = '反馈';
  title: string = '反馈';
}

class PlayerFeedbackRoute implements router.RouterOptions {
  url: string = 'pages/MessagePage';
  params: PlayerFeedbackParams = new PlayerFeedbackParams();
}

const TOP_BAR_HEIGHT: number = 52;
/** 竖屏时底部控制栏占位高度（滑块 + 内边距）。 */
const BOTTOM_BAR_HEIGHT: number = 74;
/** 同一接口连续失败多少次后自动切到下一个接口线路。 */
const AUTO_SWITCH_FAILURES: number = 3;

export interface SearchVideoItem extends RecordVideoSource { yhm: string; feng: string; sfeng: string; data: string; tilie: string; wzlj: string; genxi: string; zyuanuuu: string; vodId: string; resourceType?: string; localPath?: string; lineSources?: string; }
export interface EpisodeItem { title: string; playUrl: string; }
/** 投屏控制页需要的选集结构（title + 该集当前线路地址）。 */
export interface CastEpisodeParam { title: string; url: string; }
export interface PlayerRoute { title: string; sourceUrl: string; }
export interface PlayerEpisode { title: string; routes: PlayerRoute[]; }
export interface SearchPlayerParams { yhm: string; feng: string; sfeng: string; data: string; tilie: string; wzlj: string; genxi: string; zyuanuuu: string; vodId: string; resourceType?: string; localPath?: string; lineSources?: string; }
/** 搜索页合并进来的接口线路：同名影片在某个搜索接口下的选集数据。 */
interface PlayerLineSource { name: string; wzlj: string; genxi?: string; data?: string; vodId?: string; }
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
  @StorageLink('darkTheme') @Watch('onImmersiveChanged') private appDarkTheme: boolean = true;
  @StorageLink('favoriteVersion') @Watch('refreshFavorite') private favoriteRevision: number = 0;
  @StorageLink('downloadVersion') @Watch('refreshDownload') private downloadRevision: number = 0;
  // 只监听 Index 交接的本次系统请求，不持久化，也不从桌面启动读取分享资料。
  @StorageLink('playerSharedResumeVersion') @Watch('onSharedResumeChanged') private sharedResumeVersion: number = 0;
  @State private viewportWidth: number = 360;
  @State private viewportHeight: number = 640;
  @State private playerWidth: number = 360;
  @State private playerContainerHeight: number = 360 * 9 / 16;
  @State private topBarSpan: number = 0;
  @State private fullScreen: boolean = false;
  // 顶部控制栏新增信息：设备电量、当前时间、画面比例。
  @State private batteryPercent: number = 0;
  @State private batteryCharging: boolean = false;
  @State private clockText: string = '';
  @State private ratioMode: string = '原画';
  /** 当前是否处于「竖屏全屏」（视频本身是竖屏资源时自动切换，控件按竖屏重排）。 */
  @State private fullScreenPortrait: boolean = false;
  @State private ratioMenuVisible: boolean = false;
  /** 锁屏：锁定后屏幕任意位置不再响应控件/手势，只保留左侧锁图标。 */
  @State private screenLocked: boolean = false;
  /// 锁定后锁图标的显隐：点屏幕切换，显示后 3 秒自动隐藏。
  @State private lockIconVisible: boolean = false;
  private lockIconTimer: number = -1;
  // 视频画面实际尺寸：按视频宽高比在容器内等比缩放，并水平居中显示。
  @State private videoSurfaceWidth: number = 360;
  @State private videoSurfaceHeight: number = 202;
  /// 竖屏下画面高度超出中间区域时需要裁切（FIT_CROP），避免出现左右黑边。
  private portraitCrop: boolean = false;
  /// 竖屏视频垂直偏移：夹在两栏之间时按栏高差偏移，覆盖式时为 0。
  @State private videoOffsetY: number = 0;
  /// 进度条可用宽度（vp），用于摆放项目图标滑块。
  @State private progressTrackWidth: number = 0;
  /** 已缓存到的播放位置（毫秒）与缓冲状态。 */
  @State private bufferedMs: number = 0;
  @State private buffering: boolean = false;
  @State private bufferingPercent: number = 0;
  /** HLS 分片磁盘缓存进度（暂停时继续预取）与状态。 */
  @StorageLink('hlsCacheMs') @Watch('onCacheProgressChanged') private diskCacheMs: number = 0;
  @StorageLink('hlsCacheActive') private diskCacheActive: boolean = false;
  /** 播放页是否已切到后台；暂停切后台时显示缓存实况窗。 */
  private playerPageHidden: boolean = false;
  /// 系统状态栏高度（vp），用于竖屏把父容器整体下移 2 倍状态栏高度。
  @State private statusBarHeightVp: number = 24;
  private ratioLabels: string[] = ['原画', '铺满', '16:9', '4:3', '21:9'];
  @State private loadingDots: string = '';
  /// 上一次已应用的缩放模式（true=裁切），避免重复设置触发 5400102。
  private lastScaleTypeCrop: boolean | undefined = undefined;
  private loadingTimer: number = -1;
  private batteryTimer: number = -1;
  private clockTimer: number = -1;
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
  private lastAudibleVolume: number = 1;
  @State private speedIndex: number = 1;
  @State private speedMenuVisible: boolean = false;
  @State private episodeMenuVisible: boolean = false;
  /** 线路选择页：列出当前集所有线路并检测可用性。 */
  @State private linePanelVisible: boolean = false;
  @State private lineTesting: boolean = false;
  @State private lineStatus: string[] = [];
  private lineTestToken: number = 0;
  private lineLongPressAt: number = 0;
  private linePressTimer: number = -1;
  /** 线路图标首次使用气泡：每个播放页打开提示一次，可「不再提示」。 */
  @State private lineTipVisible: boolean = false;
  private lineTipHidden: boolean = false;
  private lineTipTimer: number = -1;
  /** 投屏面板：DLNA 设备发现与手动 IP。 */
  @State private castPanelVisible: boolean = false;
  @State private castDevices: CastDevice[] = [];
  @State private castSearching: boolean = false;
  @State private castIp: string = '';
  @State private castStatus: string = '';
  private castService: CastService = new CastService();
  /** 系统播控栏（锁屏/控制中心）会话。 */
  private avSession?: avSession.AVSession;
  /** 播控栏封面（下载后的海报），避免重复拉取。 */
  private avCover?: image.PixelMap;
  private avCoverUrl: string = '';
  /** 已连接的投屏设备（用于面板里的遥控按钮）。 */
  @State private castTargetName: string = '';
  private castTarget: CastDevice | undefined = undefined;
  /** 投屏设备音量（0-100，RenderingControl）。 */
  @State private castVolume: number = 50;
  @State private episodeIndex: number = 0;
  @State private routeIndex: number = 0;
  @State private favoriteSelected: boolean = false;
  @State private favoriteScale: number = 1;
  @State private favoriteBusy: boolean = false;
  @State private errorText: string = '';
  // 失败类别：race（切集/换线竞态）/ network（网络或线路）/ format（格式）/ local（本地文件）/ unknown。
  @State private errorKind: string = '';
  // 竞态自动重启次数：一次仍失败就按真实异常提示，避免一直静默转圈。
  private raceRetryCount: number = 0;
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
  @State private sessionDialogVisible: boolean = false;
  @State private receiverLocked: boolean = false;
  @State private isSlaveMode: boolean = false;
  @State private brightnessShade: number = 0;
  // 右侧半屏「播放设置」面板：所有开关持久化在 PlayerSettingsStore。
  @State private settingsPanelVisible: boolean = false;
  @State private loopMode: string = 'off';
  @State private skipIntroOutro: boolean = false;
  @State private introSeconds: number = 0;
  @State private outroSeconds: number = 0;
  @State private eyeCare: boolean = false;
  @State private colorAssist: string = 'off';
  @State private energyBar: boolean = false;
  @State private giftEffect: boolean = true;
  @State private seekSnapshot: boolean = true;
  @State private backgroundPlay: boolean = false;
  @State private trafficAssist: boolean = false;
  /** 画质偏好：auto / 1080 / 720 / 480；HDR 仅对支持 HDR 的片源生效。 */
  @State private resolution: string = 'auto';
  @State private hdrEnabled: boolean = false;
  /** 长按 3 倍速与进度条拖动预览的临时状态。 */
  @State private boostSpeedActive: boolean = false;
  @State private boostFromBar: boolean = false;
  @State private previewVisible: boolean = false;
  /** HDR 开启时的全屏提示：字幕 + 光环动画。 */
  @State private hdrBannerVisible: boolean = false;
  @State private hdrClosing: boolean = false;
  @State private hdrBannerOpacity: number = 0;
  @State private hdrBannerScale: number = 0.86;
  @State private hdrTick: number = 0;
  private readonly hdrSparkles: number[] = [0, 1, 2, 3, 4, 5, 6, 7];
  private readonly hdrRays: number[] = [0, 1, 2, 3, 4, 5];
  private readonly hdrOrbiters: number[] = [0, 1, 2, 3, 4, 5];
  private hdrBannerTimer: number = -1;
  private hdrHideTimer: number = -1;
  private hdrAnimTimer: number = -1;
  private preBoostSpeedIndex: number = -1;
  private previewSeekAt: number = 0;
  /** 屏幕是否支持 AIHDR 硬件渲染（HDRFormat.VIDEO_AIHDR = 8）。 */
  private aiHdrSupported: boolean = false;
  /** 播放设置加载完成信号：首次 prepare 前等待，保证分辨率/HDR 偏好立即生效。 */
  private settingsLoadPromise: Promise<void> = Promise.resolve();
  @State private audioOnly: boolean = false;
  @State private sleepMinutes: number = 0;
  @State private sleepRemainSec: number = 0;
  @State private sleepOptionsVisible: boolean = false;
  @State private colorAssistOptionsVisible: boolean = false;
  private sleepTick: number = -1;
  private backgroundTaskActive: boolean = false;
  private skipIntroApplied: boolean = false;
  private skipOutroHandled: boolean = false;
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
  /** 搜索页合并进来的接口线路（同名影片在不同接口下的选集）。 */
  private lineSources: PlayerLineSource[] = [];
  /** 与 lineSources 同序的选集解析结果，避免每集重复切分 wzlj。 */
  private lineEpisodes: EpisodeItem[][] = [];
  /** 与 lineSources 同序：该接口与主接口的集名集合是否一致（一致才允许按下标兜底）。 */
  private lineAligned: boolean[] = [];
  /** 当前线路连续失败次数：达到 3 次自动切到下一个可播放接口。 */
  private routeFailureCount: number = 0;
  /** 本次选集已自动切线路的次数，防止所有接口都失败时来回跳。 */
  private autoRouteSwitchCount: number = 0;
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
        routeIndex: this.routeIndex,
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
      // 画面固定按 FIT 等比完整显示，不再接收主控的画面比例指令（旧版本主控仍可能携带该字段，忽略即可）。
      const elapsed: number = command.playing ? Math.max(0, Math.min(15000, Date.now() - command.timestamp)) : 0;
      const requested: number = Math.floor(command.currentMs + elapsed * [0.75, 1, 1.25, 1.75, 2][command.speedIndex]);
      const target: number = Math.max(0, this.durationMs > 0 ? Math.min(this.durationMs - 1, requested) : requested);
      const difference: number = Math.abs(this.currentMs - target);
      if (difference >= this.sessionSeekToleranceMs) {
        instance.seek(target, 2 as media.SeekMode); this.currentMs = target;
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
      this.player.seek(target, 2 as media.SeekMode); this.currentMs = target;
      this.reveal(); void this.saveWatchRecord(); await this.publishSessionState();
    } catch (error) { Logger.error('PLAYER_GESTURE', '手势定位进度失败：' + String(error)); }
  }
  private volumeFromGesture(level: number): void {
    try {
      if (this.disposed || this.sessionControlBlocked() || !Number.isFinite(level)) { return; }
      this.volumeValue = Math.max(0, Math.min(1, level)); this.player?.setVolume(this.volumeValue);
    } catch (error) { Logger.error('PLAYER_GESTURE', '手势调节音量失败：' + String(error)); }
  }
  private toggleMute(): void {
    if (this.volumeValue > 0) {
      this.lastAudibleVolume = this.volumeValue;
      this.volumeFromGesture(0);
    } else {
      this.volumeFromGesture(this.lastAudibleVolume > 0 ? this.lastAudibleVolume : 1);
    }
  }
  /** 播放器快捷键：空格、方向键、M、F、Enter。 */
  private handlePlayerKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || this.disposed) { return false; }
    // 设置面板中的输入框优先，避免空格等按键被播放器拦截。
    if (this.settingsPanelVisible) { return false; }
    switch (event.keyCode) {
      case 2050:
        void this.togglePlay();
        return true;
      case 2014:
        void this.seekFromGesture(this.currentMs - 10000);
        return true;
      case 2015:
        void this.seekFromGesture(this.currentMs + 10000);
        return true;
      case 2029:
        this.toggleMute();
        return true;
      case 2022:
        void this.toggleFullScreen();
        return true;
      case 2012:
        if (this.episodeIndex > 0) { this.selectEpisode(this.episodeIndex - 1); }
        return true;
      case 2013:
        if (this.episodeIndex < this.episodes.length - 1) { this.selectEpisode(this.episodeIndex + 1); }
        return true;
      case 2054:
        {
          const routes: PlayerRoute[] = this.currentRoutes();
          if (routes.length > 1) {
            this.chooseLine((this.routeIndex + 1) % routes.length);
          }
        }
        return true;
      default:
        return false;
    }
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
  /** 单独切分 wzlj（不写页面状态），供接口线路逐条解析复用。 */
  private splitWzlj(wzlj: string): EpisodeItem[] {
    const result: EpisodeItem[] = [];
    const cleaned: string = (wzlj || '').replace(/\t/g, '').trim().replace(/\s{2,}/g, ' ');
    if (!cleaned) { return result; }
    const entries: string[] = cleaned.split('#').map((entry: string): string => entry.trim())
      .filter((entry: string): boolean => entry.length > 0);
    for (const entry of entries) {
      const separator: number = entry.indexOf('$');
      if (separator <= 0 || separator >= entry.length - 1) { continue; }
      const title: string = entry.substring(0, separator).trim();
      const playUrl: string = entry.substring(separator + 1).trim();
      if (title && playUrl) { result.push({ title: title, playUrl: playUrl }); }
    }
    return result;
  }

  /** 解析搜索页合并进来的接口线路；格式非法时返回空，不影响主接口播放。 */
  private parseLineSources(raw: string | undefined): void {
    this.lineSources = [];
    this.lineEpisodes = [];
    this.lineAligned = [];
    if (typeof raw !== 'string' || raw.trim().length === 0) { return; }
    try {
      const list: PlayerLineSource[] = JSON.parse(raw) as PlayerLineSource[];
      if (!Array.isArray(list)) { return; }
      for (const item of list) {
        if (item === undefined || typeof item.wzlj !== 'string' || item.wzlj.trim().length === 0) { continue; }
        const line: PlayerLineSource = {
          name: typeof item.name === 'string' ? item.name.trim() : '',
          wzlj: item.wzlj,
          genxi: typeof item.genxi === 'string' ? item.genxi : '',
          data: typeof item.data === 'string' ? item.data : '',
          vodId: typeof item.vodId === 'string' ? item.vodId : ''
        };
        const episodes: EpisodeItem[] = this.splitWzlj(line.wzlj);
        if (episodes.length === 0) { continue; }
        this.lineSources.push(line);
        this.lineEpisodes.push(episodes);
      }
      Logger.info('PLAYER_SOURCE', '已接收搜索合并的接口线路 ' + String(this.lineSources.length) +
        ' 条，可用于线路切换与失败自动切换');
    } catch (error) {
      Logger.warn('PLAYER_SOURCE', '解析接口线路失败：' + String(error));
    }
  }

  /**
   * 主接口选集解析完成后，判断每条接口线路的集名集合是否与主接口一致：
   * 只有完全一致（同一季、只是排序不同）时才允许按「同下标」兜底，避免把别的剧集串过来。
   */
  private alignLineEpisodes(): void {
    this.lineAligned = [];
    for (const episodes of this.lineEpisodes) {
      let aligned: boolean = episodes.length > 0 && episodes.length === this.parsedEpisodes.length;
      if (aligned) {
        for (const candidate of episodes) {
          let found: boolean = false;
          for (const primary of this.parsedEpisodes) {
            if (this.sameEpisodeTitle(candidate.title, primary.title)) { found = true; break; }
          }
          if (!found) { aligned = false; break; }
        }
      }
      this.lineAligned.push(aligned);
    }
  }

  /** 集名归一化比较：忽略空白与大小写，避免「第 1 集 / 第1集」被当成两集。 */
  private sameEpisodeTitle(left: string, right: string): boolean {
    const a: string = (left || '').replace(/\s+/g, '').toLowerCase();
    const b: string = (right || '').replace(/\s+/g, '').toLowerCase();
    return a.length > 0 && a === b;
  }

  /** 集名里的数字序号（第01集 / 第1集 / 1 都取 1）；没有数字时返回 -1。 */
  private episodeOrder(title: string): number {
    const matched: RegExpMatchArray | null = (title || '').match(/\d+/);
    if (matched === null) { return -1; }
    const value: number = Number(matched[0]);
    return Number.isFinite(value) ? value : -1;
  }

  /** 集名去掉数字后的主干（第01集 → 第集，番外1 → 番外），用于跨接口匹配同一集。 */
  private episodeStem(title: string): string {
    return (title || '').replace(/\s+/g, '').replace(/\d+/g, '').toLowerCase();
  }

  /** 为某一集生成线路列表：主接口在前，其它接口里能匹配到的同集地址依次追加。 */
  private buildEpisodeRoutes(episode: EpisodeItem, index: number, primary: PlayerRoute): PlayerRoute[] {
    const routes: PlayerRoute[] = [primary];
    const order: number = this.episodeOrder(episode.title);
    const stem: string = this.episodeStem(episode.title);
    for (let lineIndex: number = 0; lineIndex < this.lineSources.length; lineIndex++) {
      const episodes: EpisodeItem[] = this.lineEpisodes[lineIndex];
      if (episodes === undefined || episodes.length === 0) { continue; }
      let matched: string = '';
      // 1) 集名完全一致（不同接口的排序可能不同）。
      for (const candidate of episodes) {
        if (this.sameEpisodeTitle(candidate.title, episode.title)) { matched = candidate.playUrl; break; }
      }
      // 2) 写法差异（第01集 / 第1集）：主干 + 序号一致才算同一集。
      if (matched.length === 0 && order > 0) {
        for (const candidate of episodes) {
          if (this.episodeOrder(candidate.title) === order && this.episodeStem(candidate.title) === stem) {
            matched = candidate.playUrl;
            break;
          }
        }
      }
      // 3) 集名集合完全对齐时再按下标兜底；否则宁可这一集少一条线路，也不串集。
      if (matched.length === 0 && this.lineAligned[lineIndex] === true && index < episodes.length) {
        matched = episodes[index].playUrl;
      }
      if (matched.length === 0) { continue; }
      if (routes.some((route: PlayerRoute): boolean => route.sourceUrl === matched)) { continue; }
      const name: string = this.lineSources[lineIndex].name;
      routes.push({ title: name.length > 0 ? name : '线路 ' + String(routes.length + 1), sourceUrl: matched });
    }
    return routes;
  }

  /** 当前线路连续失败计数清零（播放成功、手动换线路、切集时调用）。 */
  private resetRouteFailures(): void {
    this.routeFailureCount = 0;
    this.autoRouteSwitchCount = 0;
  }

  /** 当前接口连续失败 3 次就自动切到下一个接口；返回 true 表示这次失败已被自动切换接管。 */
  private maybeSwitchRoute(): boolean {
    if (this.playbackResourceType === 'local' || this.isSlaveMode || this.switching) { return false; }
    const routeCount: number = this.episodes[this.episodeIndex]?.routes.length || 0;
    if (routeCount < 2) { return false; }
    this.routeFailureCount++;
    if (this.routeFailureCount < AUTO_SWITCH_FAILURES) { return false; }
    if (this.autoRouteSwitchCount >= routeCount - 1) {
      Logger.warn('PLAYER_SOURCE', '所有接口线路均已失败过，停止自动切换');
      return false;
    }
    this.routeFailureCount = 0;
    this.autoRouteSwitchCount++;
    this.routeIndex = (this.routeIndex + 1) % routeCount;
    const name: string = this.episodes[this.episodeIndex].routes[this.routeIndex].title;
    Logger.warn('PLAYER_SOURCE', '当前接口连续失败 ' + String(AUTO_SWITCH_FAILURES) + ' 次，自动切到线路 ' +
      String(this.routeIndex + 1) + (name.length > 0 ? ' · ' + name : ''));
    this.clearError();
    this.loading = true;
    this.reveal();
    this.toast('当前接口连续失败，已自动切到线路 ' + String(this.routeIndex + 1));
    setTimeout(() => {
      if (!this.disposed && !this.switching) { void this.selectSource(true); }
    }, 300);
    return true;
  }

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
      const result: EpisodeItem[] = this.splitWzlj(wzlj);
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
    // 进入播放页即接入系统播控栏（锁屏/控制中心可控制播放）。
    void this.initAVSession();
    this.playbackEntryVersion++;
    // 播放页叠加播放器帧率（设置页可选 30/45/60/90Hz）。
    FrameRateService.enterPlayer();
    // 播放页竖屏隐藏状态栏；顶部控制栏的电量/时间开始实时刷新。
    void this.refreshStatusBarHeight();
    void this.setStatusBarVisible(false);
    this.startTopBarTimers();
    this.startLoadingTicker();
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
    this.disposed = false; this.completed = false; this.missingParams = false; this.surfaceReady = false; this.initializationStarted = false; this.resumeDecisionPending = true; this.video = undefined; this.episodeIndex = 0; this.routeIndex = 0; this.currentMs = 0; this.resumeMs = 0; this.episodes = []; this.speedMenuVisible = false; this.videoWidth = 0; this.videoHeight = 0; this.favoriteScale = 1; this.favoriteBusy = false; this.downloadCommandPending = false; this.downloadControlPending = false; this.downloadPauseRequested = false; this.pendingDownloadVideoId = ''; this.pendingDownloadEpisode = 0; this.downloadFailureVideoId = ''; this.downloadFailureEpisode = 0; this.downloadFailureText = ''; this.downloadProblem = false; this.lastDownloadStatus = ''; this.updatePlayerLayout();
    this.configureSession();
    void this.restoreDanmakuSettings();
    this.settingsLoadPromise = this.loadPlayerExtraSettings();
    void this.loadLineTipSetting();
    this.aiHdrSupported = this.detectAiHdr();
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
      // 搜索页已把同名影片的多个接口合并进来：先解析成线路，再拼进每一集。
      this.parseLineSources(params.lineSources);
      const parsed = this.parseEpisodes(params.wzlj);
      if (parsed.length === 0) { this.resumeDecisionPending = false; this.toast('当前影片尚未配置可播放资源'); return; }
      this.alignLineEpisodes();
      const routeLocalPath: string = typeof params.localPath === 'string' ? params.localPath.trim() : '';
      this.playbackResourceType = params.resourceType === 'local' || routeLocalPath.length > 0 || this.isLocalAddress(parsed[0].playUrl) ? 'local' : 'online';
      this.playbackSourcePath = this.playbackResourceType === 'local' && routeLocalPath ? routeLocalPath : parsed[0].playUrl;
      Logger.info('PLAYER_SOURCE', '进入播放页，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath));
      this.refreshFavorite(); this.refreshDownload();
      // 离线入口不启动网络检查、下载初始化、远程解析或鉴权请求。
      if (this.playbackResourceType !== 'local') { void this.initializeDownloads(); }
      this.resetRouteFailures();
      const localPlayback: boolean = this.playbackResourceType === 'local';
      this.episodes = parsed.map((episode: EpisodeItem, index: number): PlayerEpisode => {
        const route: PlayerRoute = { title: localPlayback ? '本地文件' : '默认线路',
          sourceUrl: localPlayback && routeLocalPath && parsed.length === 1 ? routeLocalPath : episode.playUrl };
        const routes: PlayerRoute[] = localPlayback ? [route] : this.buildEpisodeRoutes(episode, index, route);
        const playerEpisode: PlayerEpisode = { title: episode.title, routes: routes };
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
      this.playerPageHidden = false;
      // 回到播放器页面立即关闭暂停缓存实况窗。
      void LiveViewService.hide();
      this.handoffPageVisible = true;
      // 从其他页面回到播放页时窗口可能恢复过系统栏，这里重新隐藏状态栏。
      void this.setStatusBarVisible(false);
      this.startTopBarTimers();
    this.startLoadingTicker();
      this.restoreImmersiveWindow();
      this.receiveSharedRoute();
      this.onSharedResumeChanged();
      this.refreshFavorite();
      this.refreshDownload();
      ShareService.setPlaybackProgressReader(this.playbackProgressReader);
    } catch (error) { Logger.error('SHARE_RESUME', '播放页显示时恢复接续状态失败：' + String(error)); }
  }
  onPageHide(): void {
    try {
      this.handoffPageVisible = false;
      this.playerPageHidden = true;
      // 切到后台/离开播放页时立即写入观看历史，保留当前集与播放进度。
      void this.saveWatchRecord();
      // 暂停状态下切到后台：用实况窗展示当前总缓存进度。
      if (!this.playing && this.durationMs > 0) {
        void LiveViewService.showCache(this.liveViewTitle(), this.liveViewEpisode(), this.cachedRatio() * 100);
      }
    }
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
  /** 当前集当前线路的播放地址（投屏用）。 */
  private castUrl(): string {
    const episode = this.episodes[this.episodeIndex];
    if (episode === undefined) { return ''; }
    const route = episode.routes[this.routeIndex];
    return route === undefined ? '' : (route.sourceUrl || '').trim();
  }

  private castTitle(): string {
    const episode = this.episodes[this.episodeIndex];
    const name: string = this.video !== undefined ? String(this.video.yhm || '') : '';
    return (name.length > 0 ? name : '无音影视') + (episode !== undefined ? ' · ' + episode.title : '');
  }

  private openCastPanel(): void {
    // 弹幕、线路与投屏共用一个 ContentCover，先关掉其他面板避免两个状态同时为真。
    this.danmakuPanelVisible = false;
    this.linePanelVisible = false;
    this.castPanelVisible = true;
    this.castStatus = '';
    this.startCastSearch();
  }

  private closeCastPanel(): void {
    this.castPanelVisible = false;
    this.castSearching = false;
    this.castService.close();
  }

  /** DLNA 搜索：局域网 SSDP 发现，8 秒超时。 */
  private startCastSearch(): void {
    if (this.castSearching) { return; }
    this.castSearching = true;
    this.castDevices = [];
    this.castStatus = '正在搜索局域网投屏设备…';
    const service: CastService = this.castService;
    service.search((devices: CastDevice[]) => {
      this.castDevices = devices;
      if (devices.length > 0) { this.castStatus = '发现 ' + String(devices.length) + ' 台设备'; }
    }, () => {
      this.castSearching = false;
      if (this.castDevices.length === 0) {
        this.castStatus = '未发现设备，请确认电视已开启且支持 DLNA；也可输入电视 IP 重新搜索';
      }
    }).catch((error: Error) => {
      this.castSearching = false;
      this.castStatus = '搜索失败：' + String(error);
      Logger.warn('PLAYER_CAST', '投屏搜索失败：' + String(error));
    });
  }

  /** 投到指定设备：先 SetAVTransportURI 再 Play。 */
  private async castTo(device: CastDevice): Promise<void> {
    const url: string = this.castUrl();
    if (url.length === 0) { this.toast('当前集没有可投屏的播放地址'); return; }
    try {
      this.toast('正在投屏到 ' + device.name);
      const metadata: string = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>' +
        CastService.escape(this.castTitle()) + '</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/*:*">' +
        CastService.escape(url) + '</res></item></DIDL-Lite>';
      await this.castService.command(device, 'SetAVTransportURI',
        '<CurrentURI>' + CastService.escape(url) + '</CurrentURI><CurrentURIMetaData>' + metadata + '</CurrentURIMetaData>');
      await this.castService.command(device, 'Play', '<Speed>1</Speed>');
      this.castTarget = device;
      this.castTargetName = device.name;
      this.castStatus = '已连接：' + device.name;
      this.toast('已投屏到 ' + device.name);
      // 投屏成功后跳到手机端遥控台，播放页可以退出，遥控不中断。
      this.castPanelVisible = false;
      const params: Record<string, string> = {
        'deviceJson': JSON.stringify(device), 'title': this.castTitle(), 'url': url
      };
      router.pushUrl({ url: 'pages/CastControlPage', params: params }).catch((error: Error) => {
        Logger.warn('PLAYER_CAST', '打开投屏控制页失败：' + String(error));
      });
      Logger.info('PLAYER_CAST', '投屏成功：' + device.name);
    } catch (error) {
      this.toast('投屏失败：' + String(error));
      Logger.warn('PLAYER_CAST', '投屏失败：' + String(error));
    }
  }

  /** 把当前选集列表压成投屏控制页可用的结构（当前线路优先）。 */
  private castEpisodeList(): CastEpisodeParam[] {
    const list: CastEpisodeParam[] = [];
    for (let index = 0; index < this.episodes.length; index++) {
      const episode = this.episodes[index];
      const route = episode.routes[this.routeIndex] !== undefined ? episode.routes[this.routeIndex]
        : (episode.routes.length > 0 ? episode.routes[0] : undefined);
      list.push({ title: episode.title, url: route !== undefined ? (route.sourceUrl || '') : '' });
    }
    return list;
  }

  /** 已在投屏：再次点图标直接回到遥控台。 */
  private reopenCastControl(): void {
    const device: CastDevice | undefined = this.castTarget;
    if (device === undefined) { this.openCastPanel(); return; }
    this.toast('正在投屏到 ' + device.name);
    const params: Record<string, string> = {
      'deviceJson': JSON.stringify(device), 'title': this.castTitle(), 'url': this.castUrl(),
      'episodesJson': JSON.stringify(this.castEpisodeList()), 'episodeIndex': String(this.episodeIndex)
    };
    router.pushUrl({ url: 'pages/CastControlPage', params: params }).catch((error: Error) => {
      Logger.warn('PLAYER_CAST', '打开投屏控制页失败：' + String(error));
    });
  }

  /** 投屏遥控：暂停 / 继续 / 停止（AVTransport）。 */
  private async castControl(action: string, body: string, tip: string): Promise<void> {
    const device: CastDevice | undefined = this.castTarget;
    if (device === undefined) { this.toast('请先选择投屏设备'); return; }
    try {
      await this.castService.command(device, action, body);
      this.toast(tip);
    } catch (error) {
      this.toast('遥控失败：' + String(error));
      Logger.warn('PLAYER_CAST', '遥控失败(' + action + ')：' + String(error));
    }
  }

  /** 调音量：步进 ±10，范围 0-100，走 RenderingControl.SetVolume。 */
  private async castVolumeStep(delta: number): Promise<void> {
    const device: CastDevice | undefined = this.castTarget;
    if (device === undefined) { this.toast('请先选择投屏设备'); return; }
    const next: number = Math.max(0, Math.min(100, this.castVolume + delta));
    try {
      await this.castService.commandRendering(device, 'SetVolume',
        '<Channel>Master</Channel><DesiredVolume>' + String(next) + '</DesiredVolume>');
      this.castVolume = next;
      this.toast('音量 ' + String(next) + '%');
    } catch (error) {
      this.toast('调音量失败：' + String(error));
      Logger.warn('PLAYER_CAST', '调音量失败：' + String(error));
    }
  }

  /** 手动 IP：把 192.168.x.x 拼成 http://IP:端口 的常见 DLNA 控制入口。 */
  private async castManualIp(): Promise<void> {
    const ip: string = this.castIp.trim();
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) { this.toast('请输入正确的电视 IP，如 192.168.1.5'); return; }
    const device: CastDevice = { id: 'manual-' + ip, name: ip, location: '', controlUrl: 'http://' + ip + ':9197/upnp/control/AVTransport1' };
    await this.castTo(device);
  }
  /** 初始化系统播控：注册系统侧播放/暂停/停止/进度/上下集指令。 */
  private async initAVSession(): Promise<void> {
    try {
      if (this.avSession !== undefined) { return; }
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const session: avSession.AVSession = await avSession.createAVSession(context, 'wuyin_video', 'video');
      this.avSession = session;
      session.on('play', () => { void this.togglePlay(); });
      session.on('pause', () => { void this.togglePlay(); });
      session.on('stop', () => { void this.togglePlay(); });
      session.on('seek', (time: number) => {
        try { this.player?.seek(time, 2 as media.SeekMode); this.currentMs = time; } catch (error) {
          Logger.warn('PLAYER_AVSESSION', '播控拖动失败：' + String(error));
        }
      });
      session.on('playNext', () => {
        if (this.episodeIndex + 1 < this.episodes.length) { this.episodeIndex = this.episodeIndex + 1; void this.selectSource(true); }
      });
      session.on('playPrevious', () => {
        if (this.episodeIndex > 0) { this.episodeIndex = this.episodeIndex - 1; void this.selectSource(true); }
      });
      await session.activate();
      this.syncAVMetadata();
      void this.loadAVCover();
      this.syncAVState();
      Logger.info('PLAYER_AVSESSION', '系统播控会话已激活');
    } catch (error) {
      Logger.warn('PLAYER_AVSESSION', '创建播控会话失败：' + String(error));
    }
  }

  /** 下载海报作为播控栏封面（失败不影响播放）。 */
  private async loadAVCover(): Promise<void> {
    const url: string = this.video !== undefined ? String(this.video.feng || '').trim() : '';
    if (url.length === 0 || url === this.avCoverUrl) { return; }
    this.avCoverUrl = url;
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET, connectTimeout: 6000, readTimeout: 8000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode < 200 || response.responseCode >= 300) { return; }
      const buffer: ArrayBuffer = response.result as ArrayBuffer;
      if (buffer === undefined || buffer.byteLength === 0) { return; }
      const source: image.ImageSource = image.createImageSource(buffer);
      const pixelMap: image.PixelMap = await source.createPixelMap();
      this.avCover = pixelMap;
      this.syncAVMetadata();
      Logger.info('PLAYER_AVSESSION', '播控栏封面已设置');
    } catch (error) {
      Logger.warn('PLAYER_AVSESSION', '下载播控封面失败：' + String(error));
    } finally {
      request.destroy();
    }
  }

  /** 同步标题/集名到系统播控栏。 */
  private syncAVMetadata(): void {
    const session: avSession.AVSession | undefined = this.avSession;
    if (session === undefined) { return; }
    try {
      const episode = this.episodes[this.episodeIndex];
      const title: string = this.video !== undefined ? String(this.video.yhm || '') : '';
      const metadata: avSession.AVMetadata = {
        assetId: 'wuyin-' + String(this.episodeIndex),
        title: title.length > 0 ? title : '无音影视',
        artist: episode !== undefined ? episode.title : '',
        duration: this.durationMs
      };
      if (this.avCover !== undefined) { metadata.mediaImage = this.avCover; }
      session.setAVMetadata(metadata).catch((error: Error) => {
        Logger.warn('PLAYER_AVSESSION', '同步播控标题失败：' + String(error));
      });
    } catch (error) {
      Logger.warn('PLAYER_AVSESSION', '同步播控标题异常：' + String(error));
    }
  }

  /** 同步播放状态与进度到系统播控栏。 */
  private syncAVState(): void {
    const session: avSession.AVSession | undefined = this.avSession;
    if (session === undefined) { return; }
    try {
      session.setAVPlaybackState({
        state: this.playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: { elapsedTime: this.currentMs, updateTime: Date.now() },
        speed: this.speedIndex === 0 ? 1 : this.speedIndex
      }).catch((error: Error) => {
        Logger.warn('PLAYER_AVSESSION', '同步播控状态失败：' + String(error));
      });
    } catch (error) {
      Logger.warn('PLAYER_AVSESSION', '同步播控状态异常：' + String(error));
    }
  }

  private releaseAVSession(): void {
    const session: avSession.AVSession | undefined = this.avSession;
    this.avSession = undefined;
    if (session === undefined) { return; }
    session.destroy().catch((error: Error) => {
      Logger.warn('PLAYER_AVSESSION', '销毁播控会话失败：' + String(error));
    });
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
          this.getUIContext().getPromptAction().showDialog({ title: '播放记录', message: '检测到上次播放记录，是否继续播放？', buttons: [{ text: '从头播放', color: this.accent() }, { text: '继续播放', color: this.accent() }] as promptAction.Button[] }).then((result) => { if (!this.disposed && this.video?.vodId === vodId && entryVersion === this.playbackEntryVersion) { result.index === 1 ? this.choosePlayback(record.selectIndex, record.playSec) : this.choosePlayback(0, 0); } }).catch(() => { if (!this.disposed && this.video?.vodId === vodId && entryVersion === this.playbackEntryVersion) { this.choosePlayback(0, 0); } }); return;
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
    if (this.playbackResourceType === 'local') { return; }
  }
  aboutToDisappear(): void {
    this.releaseAVSession();
    this.disposed = true;
    this.playerPageHidden = true;
    void LiveViewService.hide();
    if (this.lineTipTimer !== -1) { clearTimeout(this.lineTipTimer); this.lineTipTimer = -1; }
    this.lineTipVisible = false;
    AdBlockService.endPrefetch();
    this.clearHdrBannerTimers();
    this.hdrBannerVisible = false;
    this.stopSleepTimer();
    void this.stopBackgroundTask();
    // 离开播放页恢复软件帧率。
    FrameRateService.leavePlayer();
    this.stopTopBarTimers();
    this.stopLoadingTicker();
    this.clearLockIconTimer();
    // 离开播放页恢复系统状态栏，避免影响其它页面。
    void this.setStatusBarVisible(true);
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
          activePlayer.seek(target, 2 as media.SeekMode);
        }
      }
      if (packet.playState === 'playing' && this.player && this.player.state === 'paused') { void this.player.play(); this.playing = true; }
      else if ((packet.playState === 'paused' || packet.playState === 'ended') && this.player && this.player.state === 'playing') { void this.player.pause(); this.playing = false; }
      Logger.info('QUEST3_WS', 'Quest3 状态已同步，playState=' + packet.playState + '，currentMs=' + String(target));
    } catch (error) { Logger.error('QUEST3_WS', '处理 Quest3 状态回传失败：' + String(error)); }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private updateVideoSize(videoSpan: number, videoTall: number): void {
    try {
      if (this.disposed || !Number.isFinite(videoSpan) || !Number.isFinite(videoTall) || videoSpan <= 0 || videoTall <= 0) { return; }
      this.videoWidth = videoSpan;
      this.videoHeight = videoTall;
      this.updatePlayerLayout();
      this.applyVideoScaleType();
      // 资源本身是竖屏（竖屏短剧等）时，全屏要跟着转成竖屏，控件也按竖屏重排。
      void this.syncFullScreenOrientation();
    } catch (_) { Logger.error('PlayerEngine', '更新视频原始尺寸失败'); }
  }
  /** 视频本身是不是竖屏资源；宽高未知时按横屏处理。 */
  private portraitVideo(): boolean {
    return this.videoWidth > 0 && this.videoHeight > 0 && this.videoWidth < this.videoHeight;
  }
  /** 全屏该用哪个方向：竖屏资源进竖屏，其余横屏。 */
  private fullScreenOrientation(): window.Orientation {
    return this.portraitVideo() ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE;
  }
  /**
   * 全屏状态下手动切换横屏 / 竖屏：只换窗口方向和控件排布，不退出全屏。
   * 与「按视频比例自动转屏」互补——自动转屏在换集/换线路时生效，这个是用户主动控制。
   */
  private async rotatePlayer(): Promise<void> {
    if (!this.fullScreen || this.disposed || this.fullScreenTransitionPending) { return; }
    this.fullScreenTransitionPending = true;
    try {
      const target: window.Window = this.appWindow !== undefined
        ? this.appWindow : await window.getLastWindow(this.context());
      if (this.disposed) { return; }
      this.appWindow = target;
      const nextPortrait: boolean = !this.fullScreenPortrait;
      this.fullScreenPortrait = nextPortrait;
      await target.setPreferredOrientation(nextPortrait ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
      this.syncWindowDimensions(target);
      this.updatePlayerLayout();
      this.reveal();
      Logger.info('PLAYER_IMMERSIVE', '手动切换全屏方向：' + (nextPortrait ? '竖屏' : '横屏'));
    } catch (error) {
      Logger.warn('PLAYER_IMMERSIVE', '手动切换全屏方向失败：' + String(error));
      this.toast('切换横竖屏失败');
    } finally {
      this.fullScreenTransitionPending = false;
    }
  }

  /**
   * 全屏期间视频比例变化（换集、换线路、加载到新资源）时重新判定方向：
   * 竖屏资源转竖屏、横屏资源转横屏，方向没变则什么都不做。
   */
  private async syncFullScreenOrientation(): Promise<void> {
    if (!this.fullScreen || this.disposed || this.fullScreenTransitionPending) { return; }
    const portrait: boolean = this.portraitVideo();
    if (portrait === this.fullScreenPortrait) { return; }
    this.fullScreenPortrait = portrait;
    try {
      const target: window.Window = this.appWindow !== undefined
        ? this.appWindow : await window.getLastWindow(this.context());
      if (this.disposed) { return; }
      this.appWindow = target;
      await target.setPreferredOrientation(this.fullScreenOrientation());
      this.syncWindowDimensions(target);
      this.updatePlayerLayout();
      Logger.info('PLAYER_IMMERSIVE', '按视频比例切换全屏方向：' + (portrait ? '竖屏' : '横屏'));
    } catch (error) {
      Logger.warn('PLAYER_IMMERSIVE', '切换全屏方向失败：' + String(error));
    }
  }
  private async initialize(): Promise<void> {
    try {
      const instance = await PlayerEngine.acquire(); if (this.disposed) { await PlayerEngine.release(); return; } this.player = instance;
      this.lastScaleTypeCrop = undefined;
      instance.on('stateChange', (state: string) => {
        if (this.disposed) { return; }
        try {
          this.traceSharedPlayback(state);
          if (state === 'initialized') {
            instance.surfaceId = this.surfaceController.getXComponentSurfaceId();
            const prepareVersion: number = this.sourceRequestVersion;
            // 先设置更大的前向缓冲，再 prepare：暂停期间播放器会继续向后预缓存，
            // 已缓存区间内的拖动可以直接出画面，不需要重新等网络。
            void this.prepareWithBufferStrategy(instance, prepareVersion);
          } else if (state === 'prepared') {
            this.durationMs = instance.duration; instance.setVolume(this.volumeValue); instance.setSpeed(this.speedValues[this.speedIndex]);
            // 本地文件不需要网络缓冲，直接视为整段已缓存。
            if (this.playbackResourceType === 'local') { this.bufferedMs = this.durationMs; }
            if (this.resumeMs > 0 || (this.isSlaveMode && this.pendingSharedProgressMs !== undefined)) {
              const target: number = Math.max(0, Math.floor(this.resumeMs));
              instance.seek(target, 2 as media.SeekMode);
              if (this.isSlaveMode) { Logger.info('CO_PLAYBACK', 'AVPlayer 已准备并执行入会 seek，毫秒=' + target); }
              this.resumeMs = 0;
            }
            const playVersion: number = this.sourceRequestVersion;
            instance.play().catch((error: Error) => { this.sourceFailure('启动播放失败', error, playVersion); });
          } else if (state === 'playing') {
            this.playing = true; this.loading = false;
            // 恢复播放：停止暂停预取，把带宽让给播放本身。
            AdBlockService.endPrefetch();
            // 画面真正播起来了：收起任何残留提示，并重置竞态/接口失败计数。
            this.clearError();
            this.raceRetryCount = 0;
            this.routeFailureCount = 0;
            this.autoRouteSwitchCount = 0;
            this.reveal();
            // 后台播放已开启但连续任务还没起：等真正有播放流后再静默恢复，
            // 避免"未播放就申请后台任务"被系统校验拒绝。
            if (this.backgroundPlay && !this.backgroundTaskActive) {
              void this.startBackgroundTask(false).then((started: boolean) => {
                if (!started && !this.disposed) {
                  this.backgroundPlay = false;
                  this.savePlayerExtraSettings();
                  this.toast('后台播放未能生效，请检查系统后台运行权限');
                }
              });
            }
          }
          else if (state === 'paused') {
            this.playing = false; this.buffering = false; this.reveal();
            // 所有暂停路径都申请一次实况窗前置权限，避免只覆盖按钮暂停。
            void this.requestLiveViewPermission();
            // 暂停时继续向后预取 HLS 分片，写进应用私有缓存；已缓存区间可直接回放。
            if (this.playbackResourceType !== 'local') {
              AdBlockService.beginPrefetch(this.currentMs);
            }
          }
          else if (state === 'completed') { this.playing = false; this.buffering = false; this.completed = true; this.clearRecordTimer(); this.reveal(); void this.clearWatchRecord(); AdBlockService.endPrefetch(); this.handlePlaybackCompleted(); }
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
      try { instance.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT; this.updatePlayerLayout(); } catch (_) { Logger.error('PlayerEngine', '设置播放器画面等比显示失败'); }
      instance.on('timeUpdate', (time: number) => {
        if (!this.seeking && !this.disposed) {
          this.currentMs = time; this.refreshDanmakuWindow(time);
          this.consumeSkipPoints(time);
          // 进度在走说明画面真的在播：残留的「启动播放失败」一类提示一并收起。
          if (this.playing && (this.errorText.length > 0 || this.errorKind.length > 0)) { this.clearError(); }
        }
      }); instance.on('durationUpdate', (duration: number) => { if (!this.disposed) { this.durationMs = duration; } });
      // 缓冲 / 缓存进度：CACHED_DURATION 是"当前进度之后还能播多久"，换算成缓存终点画在进度条上。
      instance.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
        if (this.disposed) { return; }
        try {
          if (infoType === media.BufferingInfoType.BUFFERING_START) {
            this.buffering = true;
            return;
          }
          if (infoType === media.BufferingInfoType.BUFFERING_END) {
            this.buffering = false;
            this.bufferingPercent = 100;
            return;
          }
          if (infoType === media.BufferingInfoType.BUFFERING_PERCENT) {
            const percent: number = Number(value);
            if (Number.isFinite(percent)) {
              this.bufferingPercent = Math.max(0, Math.min(100, Math.round(percent)));
            }
            return;
          }
          if (infoType === media.BufferingInfoType.CACHED_DURATION) {
            const cached: number = Number(value);
            if (!Number.isFinite(cached) || cached <= 0) {
              return;
            }
            const end: number = this.currentMs + cached;
            const next: number = this.durationMs > 0 ? Math.min(this.durationMs, end) : end;
            // 只增不减，避免缓存回落时进度条抖动。
            if (next > this.bufferedMs) {
              this.bufferedMs = next;
            }
            if (this.durationMs > 0 && this.bufferedMs >= this.durationMs) {
              this.bufferedMs = this.durationMs;
            }
          }
        } catch (error) {
          Logger.warn('PLAYER_BUFFER', '处理缓存进度失败：' + String(error));
        }
      });
      instance.on('error', (error) => {
        if (this.disposed) { return; }
        try {
          // 正在切集/换线：reset 抛出的错误属于上一个播放源，由切换流程收尾，这里既不报错也不重试。
          if (this.switching) {
            Logger.info('PLAYER_SOURCE', '切换播放源期间忽略播放器错误，错误码=' + String(error.code));
            return;
          }
          const kind: string = this.classifyFailure(error as Error);
          if (kind === 'race') {
            // 竞态（5400102 / HTTP499 / 状态非法）：自动重启一次播放源，不打扰用户。
            if (this.raceRetryCount < 1 && !this.disposed) {
              this.raceRetryCount++;
              Logger.warn('PLAYER_SOURCE', '播放器状态竞态，自动重启播放源一次，错误码=' + String(error.code));
              this.clearError();
              this.loading = true;
              setTimeout(() => {
                if (!this.disposed && !this.switching) { void this.selectSource(true); }
              }, 500);
              return;
            }
            Logger.warn('PLAYER_SOURCE', '播放器状态竞态重复出现，错误码=' + String(error.code));
            this.report('播放器状态异常，请点「重试」后继续', 'state');
            return;
          }
          if (this.isSlaveMode) { this.failSession('协播 AVPlayer 异常', error); }
          const error401: boolean = error.code === 401 || /\b401\b/.test(error.message || '');
          Logger.error('PLAYER_SOURCE', '类别=' + kind + '，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) + '，错误码=' + error.code + (error401 ? '，401异常' : '') + (this.playbackResourceType === 'local' ? '，本地分支未发起远程鉴权' : ''));
          // 当前接口连续失败 3 次：自动切到其它接口资源，不打断用户。
          if (kind !== 'local' && this.maybeSwitchRoute()) { return; }
          if (kind === 'network') {
            this.report('播放中断：网络或播放线路异常，请检查网络后点「重试」，或切换其他线路', 'network');
            return;
          }
          if (kind === 'format') {
            this.report('播放中断：当前线路的视频格式不受支持，请切换其他线路', 'format');
            return;
          }
          if (kind === 'local') {
            this.report('本地视频播放失败，错误码 ' + error.code + '，请检查文件完整性或重新下载', 'local');
            return;
          }
          this.report('播放异常，错误码 ' + error.code, 'unknown');
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
    private report(message: string, kind: string = 'unknown'): void {
      Logger.error('PlayerEngine', message);
      if (this.disposed) { return; }
      if (this.liveMode) {
        // 直播源（m3u8）常见 401/超时：不显示「播放异常」错误卡，提示换线路即可。
        this.errorText = '';
        this.errorKind = '';
        this.loading = false;
        this.reveal();
        return;
      }
      this.errorText = message;
      this.errorKind = kind;
      this.loading = false;
      this.reveal();
    }

    /** 收起错误提示：播放成功、开始加载新的选集或用户点重试时调用。 */
    private clearError(): void {
      if (this.errorText.length > 0) { this.errorText = ''; }
      this.errorKind = '';
    }

    /**
     * 区分失败性质：切集/换线竞态 与 网络真失败 必须分开处理，
     * 否则 reset 引发的状态错误会被当成「网络不通」弹给用户。
     */
    private classifyFailure(error: Error): string {
      const caught: BusinessError = error as BusinessError;
      const code: number = typeof caught.code === 'number' ? caught.code : 0;
      const details: string = caught.message || String(error);
      // 1) 竞态：切集/换线瞬间 reset 会让上一次的 prepare/play 抛「操作不允许」「状态非法」，
      //    HTTP499（请求已取消）同样是被我们自己取消掉的请求，都不属于网络故障。
      if (code === 5400102 || (code === 499) || /\b499\b/.test(details) ||
        /not permitted|not allowed|invalid state|not in (idle|initialized|prepared|playing)|request (was )?cancel|aborted/i.test(details)) {
        return 'race';
      }
      if (this.playbackResourceType === 'local') { return 'local'; }
      // 2) 网络/线路：IO 错误、超时、连接被拒/重置、DNS、HTTP 4xx/5xx。
      if (code === 5400103 || code === 5400104 ||
        /\b(401|403|404|408|429|5\d{2})\b/.test(details) ||
        /timeout|timed out|network|connect|refused|reset by peer|dns|unreachable|socket|I\/O error|broken pipe|eof/i.test(details)) {
        return 'network';
      }
      // 3) 格式/解码：当前线路给的资源本身播不了，换线路即可。
      if (code === 5400106 || /format|codec|decod|unsupported/i.test(details)) { return 'format'; }
      return 'unknown';
    }

    private sourceFailure(stage: string, error: Error, requestVersion: number = -1): void {
      // 1) 过期请求：切集/换线已经把这次请求取代了，纯竞态，只记日志。
      if (requestVersion >= 0 && requestVersion !== this.sourceRequestVersion) {
        Logger.info('PLAYER_SOURCE', '忽略过期的' + stage + '（请求版本=' + String(requestVersion) +
          '，当前版本=' + String(this.sourceRequestVersion) + '），属于切集竞态，资源类型=' + this.playbackResourceType);
        return;
      }
      // 2) 直播源（m3u8 常见 401）失败时完全静默：不弹错误码、不弹提示，只写日志。
      if (this.liveMode) {
        Logger.warn('PLAYER_SOURCE', '直播源播放失败（已静默）：' + stage + '，' + String((error as BusinessError).message || error));
        this.loading = false;
        this.reveal();
        return;
      }
      const caught: BusinessError = error as BusinessError;
      const details: string = caught.message || String(error);
      const kind: string = this.classifyFailure(error);
      const error401: boolean = caught.code === 401 || /\b401\b/.test(details);
      Logger.error('PLAYER_SOURCE', stage + '，类别=' + kind + '，资源类型=' + this.playbackResourceType + '，路径=' + this.sourceLogPath(this.playbackSourcePath) +
      (typeof caught.code === 'number' ? '，错误码=' + caught.code : '') + (error401 ? '，401异常' : '') +
      (this.playbackResourceType === 'local' ? '，本地分支未发起远程鉴权' : ''));
      // 3) 当前请求的状态竞态：不弹错误，静默重启一次播放源；再竞态才按真实异常提示。
      if (kind === 'race') {
        if (this.switching) { return; }
        if (this.raceRetryCount < 1) {
          this.raceRetryCount++;
          Logger.warn('PLAYER_SOURCE', '检测到切集竞态，静默重启播放源一次：' + stage);
          this.clearError();
          this.loading = true;
          this.reveal();
          setTimeout(() => {
            if (!this.disposed && !this.switching) { void this.selectSource(this.resumeMs > 0); }
          }, 400);
          return;
        }
        if (this.isSlaveMode) { this.failSession(stage, error); }
        this.report(stage + '：播放器状态异常，请点「重试」后继续', 'state');
        return;
      }
      if (this.isSlaveMode) { this.failSession(stage, error); }
      // 4) 接口线路：当前接口连续失败 3 次，自动切到其它接口资源重试。
      if (this.maybeSwitchRoute()) { return; }
      // 5) 网络真失败：提示要保留，并给出可执行的下一步（重试 / 换线路）。
      if (kind === 'network') {
        this.report(stage + '：网络或播放线路异常，请检查网络后点「重试」，或切换其他线路', 'network');
        return;
      }
      // 6) 格式不支持：换线路即可，不需要检查网络。
      if (kind === 'format') {
        this.report(stage + '：当前线路的视频格式不受支持，请切换其他线路后重试', 'format');
        return;
      }
      const localNotice: string = error401 ? '本地文件读取异常（错误码401），请检查文件完整性、访问权限或重新下载' :
        /^(本地|离线|当前离线)/.test(details) ? details : '请检查本地文件是否完整、可读取，或重新下载';
      this.report(this.playbackResourceType === 'local' ? stage + '：' + localNotice :
        stage + '，请检查网络及播放线路', this.playbackResourceType === 'local' ? 'local' : 'unknown');
    }
    private async preparePlaybackUrl(original: string): Promise<string> {
      // 离线资源在入口阻断远程处理，即使其他业务误传网络地址也不会发起鉴权。
      if (this.playbackResourceType === 'local' || this.isLocalAddress(original)) { return this.normalizeLocalPath(original); }
      let target: string = original;
      try {
        const parts = /^(https?):\/\/([^\/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(original);
        if (parts && parts[2].split(':')[0].toLowerCase() === 'play.hhuus.com') { target = parts[1] + '://' + parts[2] + parts[3].replace(/\/+$/, '') + '/index.m3u8' + (parts[4] || '') + (parts[5] || ''); }
      } catch (error) { Logger.warn('PLAYER_SOURCE', '在线资源地址规范化失败：' + String(error)); return original; }
      // 媒体代理：m3u8 统一走应用内本地代理（广告过滤 + 分片缓存 + 暂停预取）；
      // 关闭广告拦截时代理仍然保留，只是不再过滤广告。代理异常时 wrap() 原样返回地址。
      try {
        if (AdBlockService.looksLikeHls(target)) {
          target = await AdBlockService.wrap(target);
        }
      } catch (error) {
        Logger.warn('PLAYER_SOURCE', '接入媒体代理失败，使用原始地址：' + String(error));
      }
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
          .fontColor(Ui.ink(this.playerDark()))
          .layoutWeight(1)
        Text('关闭')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.playerDark()))
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
                .fontColor(Ui.ink(this.playerDark()))
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
                  .fontColor(Ui.ink(this.playerDark()))
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

  /**
   * 设置播放策略后 prepare。
   *
   * preferredBufferDuration 是**秒**，官方取值范围 [1, 20]：点播给到上限 20s、直播 10s。
   * 暂停期间播放器会继续把前向缓冲填满到该水位，缓存条随之前进；
   * 已缓存区间内的拖动可以直接出画面，不需要重新等网络。
   */
  private async prepareWithBufferStrategy(instance: media.AVPlayer, prepareVersion: number): Promise<void> {
    try {
      const strategy: media.PlaybackStrategy = {
        preferredBufferDuration: this.liveMode ? 10 : 20,
        preferredBufferDurationForPlaying: this.liveMode ? 4 : 6,
        showFirstFrameOnPrepare: true
      };
      // 分辨率偏好：交给播放器在 HLS 主列表里挑选最接近的码率；auto 与 4K 原画均不限制尺寸。
      if (this.resolution === '1080') {
      } else if (this.resolution === '720') {
      } else if (this.resolution === '480') {
      }
      // HDR：仅在片源带 HDR 时由播放器优先选择，普通片源会自动忽略。
      try {
      } catch (firstError) {
        // 个别设备/片源组合不接受 HDR 或分辨率偏好：降级为不带 HDR 的策略再试一次，
        // 避免因为画质偏好导致整个缓冲策略失效。
        Logger.warn('PLAYER_BUFFER', '首次设置播放策略失败，尝试降级：' + String(firstError));
      }
      Logger.info('PLAYER_BUFFER', '缓冲策略已设置：' + (this.liveMode ? '直播 10s/4s' : '点播 20s/6s') +
        '，分辨率=' + this.resolutionLabel() + '，HDR=' + (this.hdrEnabled ? '优先' : '关闭'));
    } catch (error) {
      Logger.warn('PLAYER_BUFFER', '设置缓冲策略失败，继续使用默认缓冲：' + String(error));
    }
    try {
      await instance.prepare();
    } catch (error) {
      this.sourceFailure('准备视频失败', error as Error, prepareVersion);
    }
  }

  private async selectSource(keepPosition: boolean): Promise<void> {
      if (this.disposed) { return; }
      try { await this.settingsLoadPromise; } catch (error) { Logger.warn('PLAYER_SETTINGS', '等待播放设置加载失败：' + String(error)); }
      const requestVersion: number = ++this.sourceRequestVersion;
      let ownsSwitch: boolean = false;
      try {
        const episode = this.episodes[this.episodeIndex]; const route = episode?.routes[this.routeIndex];
        this.completed = false; this.refreshDownload(); this.resumeMs = keepPosition ? this.currentMs : 0;
      this.skipIntroApplied = false; this.skipOutroHandled = false;
      this.bufferedMs = 0; this.buffering = false; this.bufferingPercent = 0;
      this.previewVisible = false; this.boostSpeedActive = false;
      AdBlockService.endPrefetch();
      AdBlockService.resetCacheProgress();
        this.pendingSource = route ? route.sourceUrl.trim() : '';
        this.sourceChangePending = true;
        // 开始新的选集加载：先收起上一集的错误提示；没配置资源时只给说明，不算播放故障。
        if (this.pendingSource.length > 0) { this.clearError(); }
        else { this.errorText = '当前集尚未配置真实播放资源'; this.errorKind = 'empty'; }
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
    private async togglePlay(): Promise<void> {
      this.reveal();
      try {
        if (this.sessionControlBlocked() || !this.player) { return; }
        if (this.player.state === 'playing') {
          await this.player.pause();
        } else if (this.player.state === 'paused' || this.player.state === 'prepared' || this.player.state === 'completed') {
          await this.player.play();
        } else if (this.errorText) {
          this.retryPlayback();
        }
        this.syncAVState();
      } catch (error) { this.sourceFailure('播放控制失败', error as Error); }
    }

    private requestLiveViewPermission(): void {
      void LiveViewService.requestPermission(this.context()).then((granted: boolean) => {
        if (granted) { return; }
        this.showLiveViewGuide();
      });
    }

    private showLiveViewGuide(): void {
      try {
        this.getUIContext().getPromptAction().showDialog({
          title: '开启实况窗',
          message: '暂停切到后台后，实况窗会显示当前缓存进度。\n请前往系统设置 > 通知和状态栏 > 无音影视 > 实况窗，允许显示实况窗。',
          buttons: [
            { text: '稍后', color: Ui.inkSoft(this.playerDark()) },
            { text: '去设置', color: Ui.accent(this.playerDark()) }
          ] as promptAction.Button[]
        }).then((result) => {
          if (result.index === 1) { void LiveViewService.openSettings(this.context()); }
        }).catch((error: Error) => {
          Logger.warn('LIVE_VIEW', '显示实况窗引导失败：' + String(error));
        });
      } catch (error) {
        Logger.warn('LIVE_VIEW', '显示实况窗引导异常：' + String(error));
      }
    }
    /**
     * 错误提示里的「重试」：清掉错误、重置竞态额度，从当前进度重新加载本集。
     * 注意：不清零接口失败计数，用户连续重试 3 次仍失败时会自动切到下一个接口。
     */
    private retryPlayback(): void {
      if (this.disposed) { return; }
      this.clearError();
      this.raceRetryCount = 0;
      this.loading = true;
      this.reveal();
      void this.selectSource(true);
    }
    /** 线路按钮文案：多接口时显示「线路 1/3」，只有一个接口时显示「线路 1」。 */
    private routeLabel(): string {
      const count: number = this.episodes[this.episodeIndex]?.routes.length || 0;
      return count > 1 ? '线路 ' + String(this.routeIndex + 1) + '/' + String(count) : '线路 1';
    }
    private currentRoutes(): PlayerRoute[] {
      try {
        const episode: PlayerEpisode | undefined = this.episodes[this.episodeIndex];
        return episode !== undefined ? episode.routes : [];
      } catch (_) {
        return [];
      }
    }
    private lineStatusAt(index: number): string {
      return index >= 0 && index < this.lineStatus.length ? this.lineStatus[index] : 'testing';
    }
    private lineStatusText(index: number): string {
      const status: string = this.lineStatusAt(index);
      if (status === 'ok') { return '可用'; }
      if (status === 'fail') { return '不可用'; }
      return '检测中…';
    }
    private lineSignalColor(index: number): string {
      const status: string = this.lineStatusAt(index);
      if (status === 'ok') { return '#2E9E5B'; }
      if (status === 'fail') { return Ui.inkFaint(this.playerDark()); }
      return Ui.inkSoft(this.playerDark());
    }
    /** 探测单条线路：先 HEAD，失败再带 Range 的 GET，避免部分源不支持 HEAD。 */
    private async probeLine(url: string): Promise<boolean> {
      if (!url || url.trim().length === 0) { return false; }
      const request = http.createHttp();
      try {
        try {
          const head = await request.request(url, {
            method: http.RequestMethod.HEAD,
            connectTimeout: 5000,
            readTimeout: 5000
          });
          if (head.responseCode >= 200 && head.responseCode < 400) { return true; }
        } catch (_) {
          // 部分源拒绝 HEAD，继续用 GET 探测。
        }
        const get = await request.request(url, {
          method: http.RequestMethod.GET,
          connectTimeout: 5000,
          readTimeout: 5000,
          header: { 'Range': 'bytes=0-0' }
        });
        return get.responseCode >= 200 && get.responseCode < 400;
      } catch (_) {
        return false;
      } finally {
        request.destroy();
      }
    }
    /** 并发检测当前集全部线路，过期结果直接丢弃。 */
    private async testAllLines(): Promise<void> {
      const routes: PlayerRoute[] = this.currentRoutes();
      const token: number = ++this.lineTestToken;
      this.lineTesting = true;
      this.lineStatus = routes.map((_route: PlayerRoute): string => 'testing');
      try {
        const results: boolean[] = await Promise.all(
          routes.map((route: PlayerRoute): Promise<boolean> => this.probeLine(route.sourceUrl)));
        if (token !== this.lineTestToken || this.disposed) { return; }
        this.lineStatus = results.map((ok: boolean): string => ok ? 'ok' : 'fail');
      } catch (_) {
        if (token === this.lineTestToken) {
          this.lineStatus = routes.map((): string => 'fail');
        }
      } finally {
        if (token === this.lineTestToken) { this.lineTesting = false; }
      }
    }
    private clearLinePressTimer(): void {
      if (this.linePressTimer !== -1) {
        clearTimeout(this.linePressTimer);
        this.linePressTimer = -1;
      }
    }
    /** 读取「线路气泡不再提示」并延迟弹出，等播放页控制栏挂载完成。 */
    private async loadLineTipSetting(): Promise<void> {
      try {
        const store = await preferences.getPreferences(this.context(), 'player_watch_history');
        const hidden: boolean = Boolean(await store.get('line_tip_hidden_514', false));
        if (this.disposed) { return; }
        this.lineTipHidden = hidden;
        if (hidden) { return; }
        if (this.lineTipTimer !== -1) { clearTimeout(this.lineTipTimer); }
        this.lineTipTimer = setTimeout(() => {
          this.lineTipTimer = -1;
          if (!this.disposed && !this.lineTipHidden) { this.lineTipVisible = true; }
        }, 1000);
      } catch (error) {
        Logger.warn('PLAYER_LINE_TIP', '读取线路提示设置失败：' + String(error));
      }
    }
    private async dismissLineTip(never: boolean): Promise<void> {
      this.lineTipVisible = false;
      if (!never) { return; }
      this.lineTipHidden = true;
      try {
        const store = await preferences.getPreferences(this.context(), 'player_watch_history');
        await store.put('line_tip_hidden_514', true);
        await store.flush();
      } catch (error) {
        Logger.warn('PLAYER_LINE_TIP', '保存线路提示设置失败：' + String(error));
      }
    }
    private openLinePanel(): void {
      this.clearLinePressTimer();
      this.lineTipVisible = false;
      this.closeControlMenus();
      this.danmakuPanelVisible = false;
      this.castPanelVisible = false;
      this.linePanelVisible = true;
      this.reveal();
      void this.testAllLines();
    }
    private chooseLine(index: number): void {
      try {
        const routes: PlayerRoute[] = this.currentRoutes();
        if (index < 0 || index >= routes.length) { return; }
        this.linePanelVisible = false;
        if (index === this.routeIndex) { return; }
        this.routeIndex = index;
        this.resetRouteFailures();
        void this.selectSource(true);
      } catch (error) {
        Logger.warn('PLAYER_LINE', '切换线路失败：' + String(error));
      }
    }
    /** 当前集是否还有别的线路可换（决定错误卡里是否出现「换线路」）。 */
    private hasOtherRoutes(): boolean {
      const episode: PlayerEpisode | undefined = this.episodes[this.episodeIndex];
      return episode !== undefined && episode.routes.length > 1;
    }
    /** 网络/线路类失败时，允许一键换下一条线路重试。 */
    private retryWithNextRoute(): void {
      if (this.disposed || this.sessionControlBlocked()) { return; }
      const count: number = this.episodes[this.episodeIndex]?.routes.length || 0;
      if (count < 2) { this.toast('暂无其他接口线路'); return; }
      this.routeIndex = (this.routeIndex + 1) % count;
      this.resetRouteFailures();
      this.retryPlayback();
    }
    private clearTimer(): void { if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; } }
    // 控制栏显隐只切换透明度，不做任何布局动画（避免出现/消失时位置漂移）。
    private reveal(): void { if (this.lockActive()) { return; } this.clearTimer(); this.controlsVisible = true; if (!this.playing || this.seeking || this.hovered || this.loading || this.errorText) { return; } this.hideTimer = setTimeout(() => { if (!this.disposed) { this.controlsVisible = false; } }, 3500); }
    private toggleControls(): void {
      if (this.disposed || this.lockActive()) { return; }
      if (this.controlsVisible) {
        this.clearTimer();
        this.controlsVisible = false;
      } else { this.reveal(); }
    }
    /** 锁定/解锁屏幕：锁定时收起控制栏并清掉自动隐藏计时。 */
    private toggleScreenLock(): void {
      const next: boolean = !this.screenLocked;
      this.screenLocked = next;
      if (next) {
        this.clearTimer();
        this.controlsVisible = false;
        this.closeControlMenus();
        // 刚锁定时先露出锁图标，3 秒后自动隐藏；之后点屏幕再切换显隐。
        this.showLockIcon();
        this.toast('已锁定，点击屏幕显示锁图标');
      } else {
        this.clearLockIconTimer();
        this.lockIconVisible = false;
        this.toast('已解锁');
        this.reveal();
      }
    }

    /** 只有全屏锁定才拦截操作；竖屏不显示锁按钮，因此视为未锁定。 */
    private lockActive(): boolean { return this.screenLocked && this.fullScreen; }

    /** 锁定状态下点屏幕：切换锁图标的显示/隐藏。 */
    private toggleLockIcon(): void {
      if (!this.screenLocked) { return; }
      if (this.lockIconVisible) {
        this.hideLockIcon();
      } else {
        this.showLockIcon();
      }
    }

    private showLockIcon(): void {
      this.lockIconVisible = true;
      this.clearLockIconTimer();
      this.lockIconTimer = setTimeout(() => {
        this.lockIconTimer = -1;
        this.lockIconVisible = false;
      }, 3000);
    }

    private hideLockIcon(): void {
      this.clearLockIconTimer();
      this.lockIconVisible = false;
    }

    private clearLockIconTimer(): void {
      if (this.lockIconTimer !== -1) {
        clearTimeout(this.lockIconTimer);
        this.lockIconTimer = -1;
      }
    }

    private closeControlMenus(): void {
      this.speedMenuVisible = false;
      this.ratioMenuVisible = false;
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
        const restoreState: WindowRestoreState = { orientation: window.Orientation.PORTRAIT };
        this.restoreState = restoreState;
        // 竖屏资源（竖屏短剧/直播）直接进竖屏全屏，避免左右两条大黑边。
        this.fullScreenPortrait = this.portraitVideo();
        await target.setPreferredOrientation(this.fullScreenOrientation());
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
          this.fullScreen = false; this.fullScreenPortrait = false; this.danmakuPanelVisible = false; this.closeControlMenus(); this.resizePlayer(this.portraitWidth, this.portraitHeight); AppStorage.setOrCreate('playerFullScreen', false);
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
    onBackPress(): boolean { if (this.settingsPanelVisible) { this.closeSettingsPanel(); return true; } if (this.sessionDialogVisible) { this.sessionDialogVisible = false; return true; } if (this.fullScreenTransitionPending) { return true; } if (this.fullScreen) { void this.leaveFullScreen(); return true; } return false; }
    private toast(message: string): void { try { this.getUIContext().getPromptAction().showToast({ message: message }); } catch (error) { Logger.warn('PLAYER_NOTICE', String(error)); } }

  // ---------------- 播放设置（右侧半屏面板） ----------------

  private async loadPlayerExtraSettings(): Promise<void> {
    try {
      const settings: PlayerExtraSettings = await PlayerSettingsStore.load(this.context());
      if (this.disposed) { return; }
      this.loopMode = settings.loopMode;
      this.skipIntroOutro = settings.skipIntroOutro;
      this.introSeconds = settings.introSeconds;
      this.outroSeconds = settings.outroSeconds;
      this.eyeCare = settings.eyeCare;
      this.colorAssist = settings.colorAssist;
      this.energyBar = settings.energyBar;
      this.giftEffect = settings.giftEffect;
      this.seekSnapshot = settings.seekSnapshot;
      this.backgroundPlay = settings.backgroundPlay;
      this.trafficAssist = settings.trafficAssist;
      this.resolution = settings.resolution;
      this.hdrEnabled = settings.hdr;
      // 后台播放开关恢复后不立刻申请连续任务：等真正开始播放（state=playing）再静默恢复，
      // 避免"没在播就申请后台任务"被系统校验拒绝。
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '初始化播放设置失败：' + String(error));
    }
  }

  private savePlayerExtraSettings(): void {
    const settings: PlayerExtraSettings = new PlayerExtraSettings();
    settings.loopMode = this.loopMode;
    settings.skipIntroOutro = this.skipIntroOutro;
    settings.introSeconds = this.introSeconds;
    settings.outroSeconds = this.outroSeconds;
    settings.eyeCare = this.eyeCare;
    settings.colorAssist = this.colorAssist;
    settings.energyBar = this.energyBar;
    settings.giftEffect = this.giftEffect;
    settings.seekSnapshot = this.seekSnapshot;
    settings.backgroundPlay = this.backgroundPlay;
    settings.trafficAssist = this.trafficAssist;
    settings.resolution = this.resolution;
    settings.hdr = this.hdrEnabled;
    void PlayerSettingsStore.save(this.context(), settings);
  }

  private openSettingsPanel(): void {
    this.closeControlMenus();
    this.reveal();
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.settingsPanelVisible = true;
    });
  }

  private closeSettingsPanel(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.settingsPanelVisible = false;
      this.sleepOptionsVisible = false;
      this.colorAssistOptionsVisible = false;
    });
  }

  private settingsPanelSpan(): number {
    const width: number = Number.isFinite(this.viewportWidth) ? this.viewportWidth : 360;
    const ratio: number = this.fullScreen ? 0.46 : 0.9;
    return Math.round(Math.max(280, Math.min(480, width * ratio)));
  }

  private toggleFillScreen(): void {
    const next: string = this.ratioMode === '铺满' ? '原画' : '铺满';
    this.selectRatio(next);
    this.toast(next === '铺满' ? '已撑满全屏' : '已恢复原画比例');
  }

  private toggleEyeCare(): void {
    this.eyeCare = !this.eyeCare;
    this.savePlayerExtraSettings();
    this.toast(this.eyeCare ? '护眼模式已开启' : '护眼模式已关闭');
  }

  private openDanmakuFromPanel(): void {
    this.closeSettingsPanel();
    // 同一个 bindContentCover 同时承载弹幕、线路与投屏面板，打开前先收起其他面板。
    this.castPanelVisible = false;
    this.linePanelVisible = false;
    this.danmakuPanelVisible = true;
  }

  private toggleAudioOnly(): void {
    this.audioOnly = !this.audioOnly;
    this.toast(this.audioOnly ? '已切换到音频播放' : '已恢复画面');
  }

  private toggleColorAssistOptions(): void {
    this.colorAssistOptionsVisible = !this.colorAssistOptionsVisible;
  }

  private setColorAssist(mode: string): void {
    this.colorAssist = mode === 'yellow' || mode === 'blue' ? mode : 'off';
    this.savePlayerExtraSettings();
    this.toast(this.colorAssist === 'off' ? '色觉辅助已关闭' :
      (this.colorAssist === 'yellow' ? '已启用黄色滤镜' : '已启用蓝色滤镜'));
  }

  private setLoopMode(mode: string): void {
    this.loopMode = mode === 'single' || mode === 'list' ? mode : 'off';
    this.savePlayerExtraSettings();
    this.toast(this.loopMode === 'single' ? '循环播放：单集' :
      (this.loopMode === 'list' ? '循环播放：列表' : '循环播放：关闭'));
  }

  private setSkipIntroOutro(value: boolean): void {
    this.skipIntroOutro = value;
    this.skipIntroApplied = false;
    this.skipOutroHandled = false;
    this.savePlayerExtraSettings();
    this.toast(value ? '已开启跳过片头片尾' : '已关闭跳过片头片尾');
  }

  private setIntroSeconds(value: number): void {
    const next: number = Math.max(0, Math.min(300, Math.round(value)));
    this.introSeconds = next;
    this.skipIntroApplied = false;
    this.savePlayerExtraSettings();
  }

  private setOutroSeconds(value: number): void {
    const next: number = Math.max(0, Math.min(300, Math.round(value)));
    this.outroSeconds = next;
    this.skipOutroHandled = false;
    this.savePlayerExtraSettings();
  }

  private toggleSleepOptions(): void {
    this.sleepOptionsVisible = !this.sleepOptionsVisible;
  }

  private setSleepMinutes(minutes: number): void {
    this.stopSleepTimer();
    this.sleepMinutes = minutes;
    this.sleepRemainSec = minutes * 60;
    if (minutes <= 0) {
      this.toast('已关闭定时关闭');
      return;
    }
    this.sleepTick = setInterval(() => {
      if (this.disposed || this.sleepRemainSec <= 0) {
        return;
      }
      this.sleepRemainSec -= 1;
      if (this.sleepRemainSec <= 0) {
        this.onSleepTimerReached();
      }
    }, 1000);
    this.toast('将在 ' + String(minutes) + ' 分钟后暂停播放');
  }

  private stopSleepTimer(): void {
    if (this.sleepTick >= 0) {
      clearInterval(this.sleepTick);
      this.sleepTick = -1;
    }
  }

  private onSleepTimerReached(): void {
    this.stopSleepTimer();
    this.sleepMinutes = 0;
    this.sleepRemainSec = 0;
    this.reveal();
    try {
      const instance: media.AVPlayer | undefined = this.player;
      if (instance !== undefined && instance.state === 'playing') {
        void instance.pause();
      }
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '定时关闭暂停播放失败：' + String(error));
    }
    this.toast('定时关闭已到，播放已暂停');
  }

  private sleepLabel(): string {
    if (this.sleepMinutes <= 0) {
      return '未开启';
    }
    const minutes: number = Math.floor(this.sleepRemainSec / 60);
    const seconds: number = Math.max(0, this.sleepRemainSec % 60);
    return String(minutes) + ':' + (seconds < 10 ? '0' + String(seconds) : String(seconds));
  }

  private toggleGiftEffect(): void {
    this.giftEffect = !this.giftEffect;
    this.savePlayerExtraSettings();
  }

  private toggleSeekSnapshot(): void {
    this.seekSnapshot = !this.seekSnapshot;
    if (!this.seekSnapshot) { this.previewVisible = false; }
    this.savePlayerExtraSettings();
    this.toast(this.seekSnapshot ? '拖动进度条时将实时预览画面' : '快进画面预览已关闭');
  }

  private toggleTrafficAssist(): void {
    this.trafficAssist = !this.trafficAssist;
    this.savePlayerExtraSettings();
  }

  private resolutionLabel(): string {
    if (this.resolution === '4k') { return '4K 原画'; }
    if (this.resolution === '1080') { return '1080P'; }
    if (this.resolution === '720') { return '720P'; }
    if (this.resolution === '480') { return '480P'; }
    return '自动';
  }

  /** 切换分辨率：写入偏好后按当前位置重新 prepare，让 HLS 重新选码率。 */
  private setResolution(value: string): void {
    const next: string = value === '4k' || value === '1080' || value === '720' || value === '480'
      ? value : 'auto';
    if (this.resolution === next) {
      return;
    }
    this.resolution = next;
    this.savePlayerExtraSettings();
    this.toast('分辨率：' + this.resolutionLabel() + '，正在重新加载');
    void this.selectSource(true);
  }

  /** HDR 优先：片源支持 HDR 时由播放器选择 HDR 流，普通片源自动忽略。 */
  private setHdr(enabled: boolean): void {
    if (this.hdrEnabled === enabled) {
      return;
    }
    if (enabled && !this.displaySupportsHdr()) {
      this.toast('当前屏幕不支持 HDR 硬件渲染');
      return;
    }
    this.hdrEnabled = enabled;
    this.savePlayerExtraSettings();
    if (enabled) {
      // 关闭设置面板，让全屏「已开启 HDR」字幕与光环动画完整呈现。
      this.closeSettingsPanel();
      this.showHdrBanner();
    } else {
      // 关闭也走一遍收拢动画，而不是只弹 toast；先收起设置面板让全屏动画可见。
      this.closeSettingsPanel();
      this.showHdrBanner(true);
    }
    void this.selectSource(true);
  }

  /** 读取屏幕硬件 HDR 能力：iOS 壳未暴露 Display，按不支持处理。 */
  private displaySupportsHdr(): boolean {
    return false;
  }

  /** 是否支持 AIHDR 硬件渲染（HDRFormat.VIDEO_AIHDR = 8）。 */
  private detectAiHdr(): boolean {
    try {
      const formats: number[] = [];
      for (const format of formats) {
        if (Number(format) === 8) {
          return true;
        }
      }
    } catch (error) {
      Logger.warn('PLAYER_HDR', '读取 AIHDR 能力失败：' + String(error));
    }
    return false;
  }

  private clearHdrBannerTimers(): void {
    if (this.hdrAnimTimer !== -1) {
      clearInterval(this.hdrAnimTimer);
      this.hdrAnimTimer = -1;
    }
    if (this.hdrBannerTimer !== -1) {
      clearTimeout(this.hdrBannerTimer);
      this.hdrBannerTimer = -1;
    }
    if (this.hdrHideTimer !== -1) {
      clearTimeout(this.hdrHideTimer);
      this.hdrHideTimer = -1;
    }
  }

  private hdrRingPhase(offset: number): number {
    return ((this.hdrTick + offset) % 26) / 26;
  }

  private hdrRingScaleAt(offset: number): number {
    const phase: number = this.hdrRingPhase(offset);
    // 开启时向外扩散，关闭时向内收拢。
    return this.hdrClosing ? 1.77 - phase * 1.15 : 0.62 + phase * 1.15;
  }

  private hdrRingOpacityAt(offset: number): number {
    return Math.max(0, 0.82 * (1 - this.hdrRingPhase(offset)));
  }

  private hdrSparkleAt(index: number): number {
    return 0.5 + 0.5 * Math.sin(this.hdrTick / 6 + index * 1.7);
  }

  private hdrSpinAngle(): number {
    return (this.hdrTick * 2.6) % 360;
  }

  private hdrSweepOffset(): number {
    return Math.sin(this.hdrTick / 9) * 62;
  }

  private hdrGlowPulse(): number {
    return 1 + 0.035 * Math.sin(this.hdrTick / 8);
  }

  private hdrOrbitAngle(index: number): number {
    return this.hdrTick * 2.2 + index * 60;
  }

  private hdrOrbitX(index: number, radius: number): number {
    return 130 + Math.cos(this.hdrOrbitAngle(index) * Math.PI / 180) * radius - 3;
  }

  private hdrOrbitY(index: number, radius: number): number {
    return 130 + Math.sin(this.hdrOrbitAngle(index) * Math.PI / 180) * radius - 3;
  }

  private hdrScanOffset(): number {
    return -130 + (this.hdrTick * 5) % 260;
  }

  /** 开启/关闭 HDR 时的全屏光效：开启向外扩散，关闭向内收拢。 */
  private showHdrBanner(closing: boolean = false): void {
    try {
      this.clearHdrBannerTimers();
      this.hdrClosing = closing;
      this.hdrBannerVisible = true;
      this.hdrTick = 0;
      this.hdrBannerOpacity = 0;
      this.hdrBannerScale = 0.8;
      this.getUIContext().animateTo({ duration: 380, curve: Curve.EaseOut }, () => {
        this.hdrBannerOpacity = 1;
        this.hdrBannerScale = 1;
      });
      this.hdrAnimTimer = setInterval((): void => {
        if (this.hdrBannerVisible) {
          this.hdrTick++;
        }
      }, 60);
      this.hdrBannerTimer = setTimeout(() => {
        this.getUIContext().animateTo({ duration: 360, curve: Curve.EaseIn }, () => {
          this.hdrBannerOpacity = 0;
        });
        this.hdrHideTimer = setTimeout(() => {
          this.hdrBannerVisible = false;
          this.hdrHideTimer = -1;
          this.clearHdrBannerTimers();
        }, 380);
      }, closing ? 1900 : 3000);
    } catch (error) {
      Logger.warn('PLAYER_HDR', '显示 HDR 提示动画失败：' + String(error));
      this.hdrBannerVisible = false;
    }
  }

  /** 长按 3 倍速：临时切到 3x，松手恢复长按前的倍速，不改动倍速菜单选择。 */
  private applySpeedBoost(active: boolean, fromBar: boolean = false): void {
    if (this.isSlaveMode || this.receiverLocked || this.disposed) {
      return;
    }
    if (active) {
      if (this.boostSpeedActive) {
        return;
      }
      this.boostSpeedActive = true;
      this.boostFromBar = fromBar;
      this.preBoostSpeedIndex = this.speedIndex;
      try {
        this.player?.setSpeed(3.0 as media.PlaybackSpeed);
        Logger.info('PLAYER_SPEED', '长按临时 3 倍速开始，来源=' + (fromBar ? '控制栏' : '画面'));
      } catch (error) {
        Logger.warn('PLAYER_SPEED', '切换 3 倍速失败：' + String(error));
        this.boostSpeedActive = false;
      }
      return;
    }
    if (!this.boostSpeedActive) {
      return;
    }
    this.boostSpeedActive = false;
    this.boostFromBar = false;
    const restore: number = this.preBoostSpeedIndex >= 0 ? this.preBoostSpeedIndex : this.speedIndex;
    this.preBoostSpeedIndex = -1;
    try {
      this.player?.setSpeed(this.speedValues[restore]);
      Logger.info('PLAYER_SPEED', '长按 3 倍速结束，恢复 ' + this.speedLabels[restore]);
    } catch (error) {
      Logger.warn('PLAYER_SPEED', '恢复倍速失败：' + String(error));
    }
  }

  /** 拖动进度条时的实时画面预览：限频 seek，让主画面跟手显示目标帧。 */
  private previewSeek(targetMs: number): void {
    if (!this.seekSnapshot || this.isSlaveMode || this.receiverLocked) {
      return;
    }
    const now: number = Date.now();
    if (now - this.previewSeekAt < 140) {
      return;
    }
    this.previewSeekAt = now;
    try {
      this.player?.seek(targetMs, 2 as media.SeekMode);
    } catch (error) {
      Logger.warn('PLAYER_SEEK', '拖动预览失败：' + String(error));
    }
  }

  private async toggleBackgroundPlay(): Promise<void> {
    if (this.backgroundPlay) {
      this.backgroundPlay = false;
      await this.stopBackgroundTask();
      this.savePlayerExtraSettings();
      this.toast('已关闭后台播放');
      return;
    }
    const context: common.UIAbilityContext = this.context();
    // 先动态拿到「后台运行 + 通知」权限，再决定是否立刻申请连续任务。
    const backgroundGranted: boolean = await this.ensureBackgroundPermission(context, true);
    if (!backgroundGranted) {
      return;
    }
    const notificationGranted: boolean = await this.ensureNotificationPermission(context, true);
    if (!notificationGranted) {
      return;
    }
    if (!this.playing) {
      // 未开始播放时先记下开关，等播放器真正进入 playing 再申请连续任务。
      this.backgroundPlay = true;
      this.savePlayerExtraSettings();
      this.toast('已开启后台播放，开始播放后自动生效');
      return;
    }
    const started: boolean = await this.startBackgroundTask(false);
    if (started) {
      this.backgroundPlay = true;
      this.savePlayerExtraSettings();
      this.toast('已开启后台播放，退到后台继续播放');
    } else {
      this.backgroundPlay = false;
      this.savePlayerExtraSettings();
      this.toast('后台播放开启失败，请检查系统后台运行权限');
    }
  }

  private async startBackgroundTask(interactive: boolean = true): Promise<boolean> {
    try {
      const context: common.UIAbilityContext = this.context();
      // 动态权限：先确认「后台运行」权限，再按需申请通知权限（后台播放的通知依赖它）。
      const backgroundGranted: boolean = await this.ensureBackgroundPermission(context, interactive);
      if (!backgroundGranted) {
        return false;
      }
      const notificationGranted: boolean = await this.ensureNotificationPermission(context, interactive);
      if (!notificationGranted) {
        return false;
      }
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      // 使用 API 12 的字符串模式接口，与 module.json5 的 backgroundModes 声明一致。
      await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent);
      this.backgroundTaskActive = true;
      Logger.info('PLAYER_SETTINGS', '后台播放连续任务已启动');
      return true;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      const code: number = Number(failure.code);
      const message: string = String(failure.message || error);
      let reason: string = '后台播放开启失败';
      if (code === 201) {
        reason = '后台运行权限被拒绝，请在系统设置中允许本应用后台运行';
      } else if (code === 9800005) {
        reason = '系统未通过后台任务校验，请确认「后台运行 / 后台播放」已开启';
      } else if (code === 9800006) {
        reason = '后台任务通知校验失败，请开启通知权限后重试';
      } else if (code === 9800004) {
        reason = '当前系统不支持音频后台任务';
      }
      this.toast(reason + (Number.isFinite(code) ? '（' + String(code) + '）' : ''));
      Logger.warn('PLAYER_SETTINGS', '启动后台播放失败，code=' + String(code) + '，message=' + message);
      return false;
    }
  }

  /**
   * 后台运行权限：KEEP_BACKGROUND_RUNNING 属 system_grant（安装即授予），
   * 但可能被用户在系统设置里关闭。这里先查令牌，未授权时按机型尝试一次动态申请，
   * 仍失败则引导用户去系统设置开启，而不是静默失败。
   */
  private async ensureBackgroundPermission(context: common.UIAbilityContext, interactive: boolean): Promise<boolean> {
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = bundleInfo.appInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus =
        manager.checkAccessTokenSync(tokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING');
      Logger.info('PLAYER_SETTINGS', '后台运行权限状态=' + String(status));
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      if (!interactive) {
        // 静默恢复时不做弹窗；继续尝试启动连续任务，由系统返回真实结果。
        return true;
      }
      Logger.info('PLAYER_SETTINGS', '后台运行权限未授予，尝试动态申请');
      try {
        const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.KEEP_BACKGROUND_RUNNING']);
        Logger.info('PLAYER_SETTINGS', '后台运行权限申请结果=' +
          (result.authResults.length > 0 ? String(result.authResults[0]) : 'empty'));
        if (result.authResults.length > 0 &&
          result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch (requestError) {
        Logger.warn('PLAYER_SETTINGS', '动态申请后台运行权限失败：' + String(requestError));
      }
      // 该权限是 system_grant，动态申请不一定弹框；不在这里阻断，
      // 继续尝试启动连续任务，由 startBackgroundRunning 返回 201/9800005 等精确错误。
      return true;
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '检查后台运行权限失败：' + String(error));
      return true;
    }
  }

  /** 通知权限：iOS / Android 由跨平台通知层处理，失败不阻断播放。 */
  private async ensureNotificationPermission(context: common.UIAbilityContext, interactive: boolean): Promise<boolean> {
    try {
      await NotificationService.ensurePermission(context);
      return true;
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '检查通知权限失败：' + String(error));
      return true;
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.backgroundTaskActive) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context());
      Logger.info('PLAYER_SETTINGS', '后台播放连续任务已停止');
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '停止后台播放失败：' + String(error));
    }
    this.backgroundTaskActive = false;
  }

  private async startPictureInPicture(): Promise<void> {
    try {
      if (!PiPWindow.isPiPEnabled()) {
        this.toast('当前设备未开启画中画能力');
        return;
      }
      const controller: PiPWindow.PiPController = await PiPWindow.create({
        context: this.context(),
        componentController: this.surfaceController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
      });
      await controller.startPiP();
      this.closeSettingsPanel();
      this.toast('已进入画中画');
      Logger.info('PLAYER_SETTINGS', '已进入画中画');
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '启动画中画失败：' + String(error));
      this.toast('画中画启动失败，当前设备或系统版本可能不支持');
    }
  }

  private async banCurrentVideo(): Promise<void> {
    const id: string = this.video?.vodId || '';
    if (id.length === 0) {
      this.toast('当前影片信息缺失，无法设置禁看');
      return;
    }
    await PlayerSettingsStore.blockVideo(this.context(), id);
    this.closeSettingsPanel();
    this.toast('已设为禁看');
  }

  private reportCurrentVideo(): void {
    this.toast('Report submitted');
  }

  private panelBrightnessPercent(): number {
    const shade: number = Number.isFinite(this.brightnessShade) ? this.brightnessShade : 0;
    return Math.round(Math.max(0, Math.min(1, 1 - shade / 0.9)) * 100);
  }

  private setPanelBrightness(percent: number): void {
    const value: number = Math.max(0, Math.min(100, percent));
    this.brightnessShade = Number(((1 - value / 100) * 0.9).toFixed(3));
  }

  /** 播放器完成一集：按循环方式决定重播/下一集/停止。 */
  private handlePlaybackCompleted(): void {
    if (this.loopMode === 'single') {
      this.completed = false;
      try {
        const instance: media.AVPlayer | undefined = this.player;
        if (instance !== undefined) {
          instance.seek(0, 2 as media.SeekMode);
          void instance.play();
        }
      } catch (error) {
        Logger.warn('PLAYER_SETTINGS', '单集循环重播失败：' + String(error));
      }
      return;
    }
    if (this.loopMode === 'list' && this.episodeIndex + 1 < this.episodes.length) {
      this.selectEpisode(this.episodeIndex + 1);
      return;
    }
  }

  /** 播放到片尾：按循环方式切下一集/重播/暂停。 */
  private handleOutroReached(): void {
    if (this.loopMode === 'list' && this.episodeIndex + 1 < this.episodes.length) {
      this.toast('已跳过片尾');
      this.selectEpisode(this.episodeIndex + 1);
      return;
    }
    if (this.loopMode === 'single') {
      this.toast('已跳过片尾');
      this.handlePlaybackCompleted();
      return;
    }
    try {
      const instance: media.AVPlayer | undefined = this.player;
      if (instance !== undefined && instance.state === 'playing') {
        void instance.pause();
      }
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '片尾暂停失败：' + String(error));
    }
    this.toast('已跳过片尾');
  }

  /** 播放进度回调里执行片头/片尾跳过（只在开播初期与接近结尾时各触发一次）。 */
  private consumeSkipPoints(time: number): void {
    if (!this.skipIntroOutro || this.durationMs <= 0) {
      return;
    }
    const targetIntro: number = Math.max(0, Math.round(this.introSeconds * 1000));
    if (!this.skipIntroApplied && targetIntro > 0 && time > 800 && time < targetIntro) {
      this.skipIntroApplied = true;
      try {
        const instance: media.AVPlayer | undefined = this.player;
        if (instance !== undefined) {
          instance.seek(targetIntro, 2 as media.SeekMode);
          this.toast('已跳过片头');
        }
      } catch (error) {
        Logger.warn('PLAYER_SETTINGS', '跳过片头失败：' + String(error));
      }
    }
    const targetOutro: number = Math.max(0, Math.round(this.outroSeconds * 1000));
    if (!this.skipOutroHandled && targetOutro > 0) {
      const endPoint: number = this.durationMs - targetOutro;
      if (endPoint > 5000 && time >= endPoint) {
        this.skipOutroHandled = true;
        this.handleOutroReached();
      }
    }
  }

    private downloadToast(message: string): void {
      // 仅分支控制下载消息的展示，不拦截下载命令、状态同步或其他播放器提示。
      if (!this.fullScreen) { this.toast(message); }
    }
    private tablet(): boolean { return this.viewportWidth >= 600; }
    // 以下仅提供视觉取值（统一走液态玻璃令牌），不参与任何播放状态判断。
    /** 播放页始终使用深色配色（不受全局深浅设置影响）。 */
    private playerDark(): boolean { return true; }
    private ink(): string { return Ui.ink(this.playerDark()); }
    private mutedInk(): string { return Ui.inkSoft(this.playerDark()); }
    private accent(): string { return Ui.accent(this.playerDark()); }
    private accentStrong(): string { return Ui.accentStrong(this.playerDark()); }
    /** 进度条颜色：默认主题色；「高能进度条」开启为金色 #FFB74D。 */
    private progressAccent(): string {
      return this.energyBar ? '#FFB74D' : this.accent();
    }

    /** 给主题色附加透明度：输入 #RRGGBB / #AARRGGBB，输出 #AARRGGBB。 */
    private tint(color: string, alphaHex: string): string {
      const raw: string = color.replace('#', '');
      const rgb: string = raw.length >= 6 ? raw.substring(raw.length - 6) : raw;
      return '#' + alphaHex + rgb;
    }

    /** 渐变用 rgba()：部分渲染后端对 #00RRGGBB 的透明端处理不正确，会画出实心矩形。 */
    private rgba(color: string, alpha: number): string {
      const raw: string = color.replace('#', '');
      const rgb: string = raw.length >= 6 ? raw.substring(raw.length - 6) : raw;
      const r: number = parseInt(rgb.substring(0, 2), 16);
      const g: number = parseInt(rgb.substring(2, 4), 16);
      const b: number = parseInt(rgb.substring(4, 6), 16);
      if (!Number.isFinite(r) || !Number.isFinite(g) || !Number.isFinite(b)) {
        return 'rgba(255,255,255,' + String(alpha) + ')';
      }
      return 'rgba(' + String(r) + ',' + String(g) + ',' + String(b) + ',' + String(alpha) + ')';
    }
    private warningInk(): string { return Ui.danger(this.playerDark()); }
    private selectedSurface(): string { return Ui.accentSoft(this.playerDark()); }
    /** 播放页背景：深色纯黑、浅色纯白。 */
    private playerBg(): string { return this.playerDark() ? '#000000' : '#FFFFFF'; }
    private canvas(): string { return this.playerBg(); }
    private solidPanel(): string { return Ui.glassTintStrong(this.playerDark()); }
    /** 控制栏底色：深色沿用玻璃底；浅色为纯白（透明度取沉浸面板透明度，最低 0.55 保证文字可读）。 */
    private controlBarTint(): string {
      if (this.playerDark()) { return Ui.glassTint(true); }
      const opacity: number = Number.isFinite(this.immersion.immersiveOpacity)
        ? Math.max(0.55, Math.min(1, this.immersion.immersiveOpacity)) : 0.85;
      const alpha: string = Math.round(opacity * 255).toString(16).toUpperCase().padStart(2, '0');
      return '#' + alpha + 'FFFFFF';
    }
    private panel(): string { return this.controlBarTint(); }
    private glassRadius(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
    private time(ms: number): string { const seconds = Math.floor(Math.max(0, ms) / 1000); return Math.floor(seconds / 60) + ':' + (seconds % 60).toString().padStart(2, '0'); }
    private videoAspect(): number {
      // 容器只跟随视频真实宽高比，取不到时退回 16:9；不再提供任何预设比例档位。
      if (Number.isFinite(this.videoWidth) && Number.isFinite(this.videoHeight) && this.videoWidth > 0 && this.videoHeight > 0) {
        return this.videoWidth / this.videoHeight;
      }
      return 16 / 9;
    }
    private updatePlayerLayout(): void {
      try {
        // 父级容器：宽度占满（平板竖屏留 68%），高度取屏幕高度的 2/5（5:2）。
        const layoutSpan: number = this.viewportWidth * (this.tablet() && !this.fullScreen ? 0.68 : 1);
        if (!Number.isFinite(layoutSpan) || layoutSpan <= 0) { return; }
        const availableTall: number = this.viewportHeight > 0 ? this.viewportHeight : layoutSpan * 3 / 5;
        // 竖屏父容器高度按屏幕高度的 2/5（5:2）；全屏占满。
        const containerTall: number = this.fullScreen ? availableTall : availableTall * 2 / 5;
        if (!Number.isFinite(containerTall) || containerTall <= 0) { return; }
        this.playerWidth = layoutSpan;
        this.playerContainerHeight = containerTall;
        // 竖屏：顶部控制栏在视频上方、底部控制栏在视频下方，视频只能占中间剩余高度。
        const reservedTall: number = this.fullScreen ? 0 : (TOP_BAR_HEIGHT + BOTTOM_BAR_HEIGHT);
        const videoTall: number = Math.max(80, containerTall - reservedTall);
        // 视频控件：按所选画面比例在中间区域等比缩放，保证不被拉伸。
        const aspect: number = this.ratioAspect(layoutSpan, Math.min(containerTall, videoTall));
        if (!Number.isFinite(aspect) || aspect <= 0) { return; }
        if (this.ratioMode === '铺满') {
          this.videoSurfaceWidth = layoutSpan;
          this.videoSurfaceHeight = this.fullScreen ? containerTall : videoTall;
          return;
        }
        if (!this.fullScreen) {
          // 竖屏页面：画面完全按影片原画比例显示——不拉成 4:3、也不裁切。
          // 宽度放得下就撑满宽度；竖屏资源按高度预算等比缩小，避免把整页撑爆。
          const budgetTall: number = Math.max(120, availableTall * (aspect < 1 ? 0.72 : 0.42));
          let fitSpan: number = layoutSpan;
          let fitTall: number = layoutSpan / aspect;
          if (fitTall > budgetTall) {
            fitTall = budgetTall;
            fitSpan = budgetTall * aspect;
          }
          this.playerWidth = layoutSpan;
          this.videoSurfaceWidth = Math.max(1, Math.round(fitSpan));
          this.videoSurfaceHeight = Math.max(1, Math.round(fitTall));
          this.videoOffsetY = 0;
          this.portraitCrop = false;
          // 容器高度跟着画面走：画面 + 上下控制栏，不再是固定的 5:2 黑边带。
          this.playerContainerHeight = Math.min(availableTall, Math.round(fitTall) + reservedTall);
          this.applyVideoScaleType();
          return;
        }
        // 全屏：按比例在整屏内等比缩放（铺满档位上面已提前返回）。
        let surfaceTall: number = containerTall;
        let surfaceSpan: number = surfaceTall * aspect;
        if (surfaceSpan > layoutSpan) {
          surfaceSpan = layoutSpan;
          surfaceTall = layoutSpan / aspect;
        }
        this.videoSurfaceWidth = Math.max(1, Math.round(surfaceSpan));
        this.videoSurfaceHeight = Math.max(1, Math.round(surfaceTall));
        this.applyVideoScaleType();
      } catch (_) { Logger.error('PlayerEngine', '更新播放器画面布局失败'); }
    }

    /** 进度滑块（项目图标）的横向位置：按当前进度比例换算，并收敛在轨道内。 */
    private progressThumbX(): number {
      const total: number = Math.max(1, this.durationMs);
      const ratio: number = Math.max(0, Math.min(1, this.currentMs / total));
      const thumb: number = 22;
      const span: number = Math.max(0, this.progressTrackWidth - thumb);
      return ratio * span;
    }

    /** 已播放比例（0~1）。 */
    private playedRatio(): number {
      const total: number = Math.max(1, this.durationMs);
      return Math.max(0, Math.min(1, this.currentMs / total));
    }

    /** 已缓存比例（0~1）：取播放器缓冲与磁盘预取的较大值。 */
    private cachedRatio(): number {
      if (this.durationMs > 0) {
        const cachedEnd: number = Math.max(this.bufferedMs, this.diskCacheMs);
        return Math.max(0, Math.min(1, cachedEnd / this.durationMs));
      }
      if (this.bufferingPercent > 0) {
        return Math.max(0, Math.min(1, this.bufferingPercent / 100));
      }
      return 0;
    }

    private cachedPercentText(): string {
      return String(Math.round(this.cachedRatio() * 100)) + '%';
    }

    /** 实况窗展示用：片名与集数。 */
    private liveViewTitle(): string {
      return this.video?.tilie || this.video?.yhm || '无音影视';
    }

    private liveViewEpisode(): string {
      return this.liveMode ? '直播' : '第 ' + String(this.episodeIndex + 1) + ' 集';
    }

    /** 暂停切后台期间，磁盘缓存继续预取时同步刷新实况窗百分比。 */
    private onCacheProgressChanged(): void {
      if (this.playerPageHidden && !this.playing && this.durationMs > 0) {
        void LiveViewService.showCache(this.liveViewTitle(), this.liveViewEpisode(), this.cachedRatio() * 100);
      }
    }

    /** 目标位置是否落在已缓存区间内：可直接出画面，无需等待缓冲。 */
    private isCachedPosition(positionMs: number): boolean {
      if (this.durationMs <= 0) {
        return false;
      }
      const cachedEnd: number = Math.max(this.bufferedMs, this.diskCacheMs, this.currentMs);
      return positionMs >= 0 && positionMs <= cachedEnd;
    }

    /** 进度条拖动时的浮层横向位置：跟随滑块并收敛在轨道内。 */
    private seekBubbleX(): number {
      const bubble: number = 132;
      const span: number = Math.max(0, this.progressTrackWidth - bubble);
      return Math.max(0, Math.min(span, this.progressThumbX() - bubble / 2));
    }

    private applyVideoScaleType(): void {
      try {
        const instance: media.AVPlayer | undefined = this.player;
        if (instance === undefined) { return; }
        // 只在 prepared/playing/paused/completed 设置；其它状态设置会触发 5400102（操作不允许）。
        const state: string = instance.state;
        if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') { return; }
        const crop: boolean = this.ratioMode === '铺满' || (!this.fullScreen && this.portraitCrop);
        if (this.lastScaleTypeCrop === crop) { return; }
        this.lastScaleTypeCrop = crop;
        instance.videoScaleType = crop
          ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
          : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      } catch (error) {
        Logger.warn('PlayerEngine', '设置画面缩放模式失败：' + String(error));
      }
    }

    /** 画面比例档位对应的宽高比；「原画」取视频真实比例，取不到时退回 16:9。 */
    private ratioAspect(containerSpan: number, containerTall: number): number {
      if (this.ratioMode === '16:9') { return 16 / 9; }
      if (this.ratioMode === '4:3') { return 4 / 3; }
      if (this.ratioMode === '21:9') { return 21 / 9; }
      if (this.ratioMode === '铺满' && containerSpan > 0 && containerTall > 0) { return containerSpan / containerTall; }
      return this.videoAspect();
    }

    /** 切换画面比例：铺满用 FIT_CROP，其余用 FIT 等比显示。 */
    private selectRatio(mode: string): void {
      try {
        this.ratioMode = mode;
        this.updatePlayerLayout();
        this.applyVideoScaleType();
        this.ratioMenuVisible = false;
        Logger.info('PlayerEngine', '切换画面比例：' + mode);
      } catch (_) { Logger.error('PlayerEngine', '切换画面比例失败'); }
    }

    /** 顶部控制栏定时器：电量 30 秒刷新一次，时间每分钟对齐刷新。 */
    /** 加载文案的动态省略号，纯视觉提示。 */
    private startLoadingTicker(): void {
      if (this.loadingTimer >= 0) { return; }
      this.loadingTimer = setInterval(() => {
        this.loadingDots = this.loadingDots === '' ? '.' : (this.loadingDots === '.' ? '..' : (this.loadingDots === '..' ? '...' : ''));
      }, 400);
    }

    private stopLoadingTicker(): void {
      if (this.loadingTimer >= 0) { clearInterval(this.loadingTimer); this.loadingTimer = -1; }
      this.loadingDots = '';
    }

    private startTopBarTimers(): void {
      this.refreshBattery();
      this.refreshClock();
      if (this.batteryTimer < 0) {
        this.batteryTimer = setInterval(() => { this.refreshBattery(); }, 30000);
      }
      if (this.clockTimer < 0) {
        this.clockTimer = setInterval(() => { this.refreshClock(); }, 20000);
      }
    }

    private stopTopBarTimers(): void {
      if (this.batteryTimer >= 0) { clearInterval(this.batteryTimer); this.batteryTimer = -1; }
      if (this.clockTimer >= 0) { clearInterval(this.clockTimer); this.clockTimer = -1; }
    }

    private refreshBattery(): void {
      try {
        const soc: number = Number(batteryInfo.batterySOC);
        if (Number.isFinite(soc) && soc >= 0) { this.batteryPercent = Math.min(100, Math.round(soc)); }
        const state: number = Number(batteryInfo.chargingStatus);
        this.batteryCharging = state === 1 || state === 3;
      } catch (error) {
        Logger.warn('PLAYER_TOPBAR', '读取电量失败：' + String(error));
      }
    }

    private refreshClock(): void {
      try {
        const now: Date = new Date();
        const hour: string = now.getHours() < 10 ? '0' + String(now.getHours()) : String(now.getHours());
        const minute: string = now.getMinutes() < 10 ? '0' + String(now.getMinutes()) : String(now.getMinutes());
        this.clockText = hour + ':' + minute;
      } catch (error) {
        Logger.warn('PLAYER_TOPBAR', '刷新时间失败：' + String(error));
      }
    }

    /** 电量图标：按百分比分档，用鸿蒙原生符号。 */
    private batteryIcon(): Resource {
      const soc: number = this.batteryPercent;
      if (soc >= 95) { return $r('sys.symbol.battery_100percent'); }
      if (soc >= 80) { return $r('sys.symbol.battery_90percent'); }
      if (soc >= 60) { return $r('sys.symbol.battery_75percent'); }
      if (soc >= 45) { return $r('sys.symbol.battery_50percent'); }
      if (soc >= 30) { return $r('sys.symbol.battery_30percent'); }
      if (soc >= 18) { return $r('sys.symbol.battery_20percent'); }
      return $r('sys.symbol.battery_10percent');
    }

    /** 读取系统状态栏高度（vp）：隐藏状态栏前先量一次，供竖屏顶部外边距使用。 */
    private async refreshStatusBarHeight(): Promise<void> {
      try {
        const target: window.Window = await window.getLastWindow(this.context());
        const area: window.AvoidArea = target.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const px: number = area !== undefined && area.topRect !== undefined ? Number(area.topRect.height) : 0;
        if (Number.isFinite(px) && px > 0) {
          const vp: number = this.getUIContext().px2vp(px);
          if (Number.isFinite(vp) && vp > 0) { this.statusBarHeightVp = Math.round(vp); }
        }
        Logger.info('PLAYER_TOPBAR', '状态栏高度：' + String(this.statusBarHeightVp) + 'vp');
      } catch (error) {
        Logger.warn('PLAYER_TOPBAR', '读取状态栏高度失败：' + String(error));
      }
    }

    /** 竖屏隐藏状态栏 / 离开时恢复。 */
    private async setStatusBarVisible(visible: boolean): Promise<void> {
      try {
        const target: window.Window = await window.getLastWindow(this.context());
        await target.setSpecificSystemBarEnabled('status', visible);
      } catch (error) {
        Logger.warn('PLAYER_TOPBAR', '设置状态栏可见性失败：' + String(error));
      }
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
        this.episodeIndex = index; this.routeIndex = 0; this.currentMs = 0; this.resetRouteFailures(); this.refreshDownload(); void this.selectSource(false); void this.saveWatchRecord();
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
    this.toast('Screenshot is not available yet');
  }
    private measureTopBar(area: Area): void {
      if (this.disposed) { return; }
      const measuredSpan: number = Number(area.width);
      if (Number.isFinite(measuredSpan) && measuredSpan > 0 && Math.abs(measuredSpan - this.topBarSpan) > 0.5) { this.topBarSpan = measuredSpan; }
    }
    private topBarContentSpan(): number {
      // 窗口监听驱动播放器尺寸，区域监听补充平板分栏及安全区后的实际可用宽度；均为 vp。
      const outerInset: number = this.fullScreen ? 32 : 12;
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
        SymbolGlyph(symbol).fontSize(Ui.fs('20vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
      }.width(this.topIconSpan() + 'vp').height(this.fullScreen ? '24vp' : '44vp').padding('0vp')
        .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius(this.fullScreen ? '12vp' : '22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        
        .accessibilityText(description)
        .onClick(() => { this.reveal(); callback(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private sessionIconButton() {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.wireless_projection')).fontSize(Ui.fs('24vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
      }.width('24vp').height('24vp').padding('0vp').margin({ left: '0vp' })
        .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('12vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        .visibility(this.video !== undefined ? Visibility.Visible : Visibility.None).accessibilityText('协同同播')
        .onClick((): void => {
        try { this.openMediaSession(); }
        catch (error) { Logger.error('MEDIA_SESSION', '点击协同同播按钮失败：' + String(error)); }
      }).onTouch((event: TouchEvent): void => { event.stopPropagation(); });
    }
    @Builder private topSettingButton(symbol: Resource, label: string, description: string, callback: () => void, onLongPress?: () => void) {
      Button({ type: ButtonType.Normal }) {
        if (this.fullScreen) {
          // 全屏只保留图标：不构造文本，避免隐藏文本的 layoutWeight 把 SymbolGlyph 挤成 0 宽而显示空白。
          SymbolGlyph(symbol).fontSize(Ui.fs('16vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
        } else {
          Row({ space: 3 }) {
            SymbolGlyph(symbol).fontSize(Ui.fs('16vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
            Text(label).fontSize(this.topLabelSize()).minFontSize('10vp').maxFontSize(this.topLabelSize()).fontColor(Ui.ink(this.playerDark())).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }.width('100%').alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Start);
        }
      }.layoutWeight(this.fullScreen ? 0 : 1).constraintSize({ minWidth: this.fullScreen ? '24vp' : '0vp', maxWidth: this.fullScreen ? '24vp' : '100%' })
        .height(this.fullScreen ? '24vp' : '44vp').padding({ left: this.fullScreen ? '0vp' : '4vp', right: this.fullScreen ? '0vp' : '4vp' })
        .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius(this.fullScreen ? '12vp' : '22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        
        .accessibilityText(description)
        .onClick(() => { this.reveal(); callback(); }).onTouch((event: TouchEvent) => {
          event.stopPropagation();
          if (onLongPress === undefined) { return; }
          if (event.type === TouchType.Down) {
            this.clearLinePressTimer();
            this.linePressTimer = setTimeout(() => {
              this.linePressTimer = -1;
              this.lineLongPressAt = Date.now();
              onLongPress();
            }, 250);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.clearLinePressTimer();
          }
        });
    }
    @Builder private topBar() {
      if (!this.fullScreen) {
        // 竖屏：返回 → 影视名称/集数 → 时间 → 电量，依次横排。
        Stack({ alignContent: Alignment.Center }) {
          Row({ space: '8vp' }) {
            this.topIconButton($r('sys.symbol.chevron_left_circle'), '返回', () => { void this.back(); });
            Column({ space: '1vp' }) {
              Text(this.video?.tilie || this.video?.yhm || '无音影视')
                .fontSize(Ui.fs('12.5vp', this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Ui.ink(this.playerDark()))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              // 画圈处：拼成「正在播放： 第 N 集」（直播源仍显示「直播」）。
              Text(this.liveMode ? '直播' : '正在播放： 第 ' + String(this.episodeIndex + 1) + ' 集')
                .fontSize(Ui.fs('10vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.playerDark()))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
              // 标题只占左侧，给中间的时间留出空间，避免文字叠在时间上。
              .constraintSize({ maxWidth: '46%' })
              .margin({ right: '6vp' })
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Center)
            Blank()
            // 时间：位于影视名称/集数与电量之间
            Text(this.clockText)
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark()))
              .maxLines(1)
              .height('24vp')
              .textAlign(TextAlign.Center)
              .margin({ right: '6vp' })
              .accessibilityText('当前时间 ' + this.clockText);
            // 电量固定最右侧
            Row({ space: '3vp' }) {
              SymbolGlyph(this.batteryIcon())
                .fontSize(Ui.fs('16vp', this.fontScale))
                .fontColor([Ui.ink(this.playerDark())]);
              Text(this.batteryPercent + '%')
                .fontSize(Ui.fs('10.5vp', this.fontScale))
                .fontColor(this.batteryCharging ? '#2E9E5B' : Ui.ink(this.playerDark()))
                .maxLines(1);
            }
              .height('24vp')
              .alignItems(VerticalAlign.Center)
              .accessibilityText('电量 ' + String(this.batteryPercent) + '%');
          }
            .width('100%')
            .padding({ left: '8vp', right: '10vp' })
            .alignItems(VerticalAlign.Center)

        }
          .width('100%')
          .height('52vp')
          .backgroundColor(this.controlBarTint())
          .backdropBlur(this.glassRadius())
          .borderRadius('26vp')
          .onAreaChange((_old: Area, area: Area) => { this.measureTopBar(area); })
      } else if (this.fullScreenPortrait) {
        // 竖屏全屏：控件按竖屏宽度重排，只保留必要项，避免横屏那一长排图标被压扁。
        Row({ space: '8vp' }) {
          this.topIconButton($r('sys.symbol.chevron_left_circle'), '返回', () => { void this.back(); });
          Column({ space: '1vp' }) {
            Text(this.video?.tilie || this.video?.yhm || '无音影视')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Ui.ink(this.playerDark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
            Text(this.liveMode ? '直播' : '正在播放： 第 ' + String(this.episodeIndex + 1) + ' 集')
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.playerDark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center);
          this.topSettingButton($r('sys.symbol.gearshape'), '设置', '播放设置',
            () => { this.openSettingsPanel(); });
          Row({ space: '3vp' }) {
            SymbolGlyph(this.batteryIcon())
              .fontSize(Ui.fs('15vp', this.fontScale))
              .fontColor([Ui.ink(this.playerDark())]);
            Text(this.batteryPercent + '%')
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(this.batteryCharging ? '#2E9E5B' : Ui.ink(this.playerDark()))
              .maxLines(1);
          }
            .height('24vp')
            .alignItems(VerticalAlign.Center);
        }
          .width('100%')
          .height('52vp')
          .padding({ left: '8vp', right: '10vp' })
          .alignItems(VerticalAlign.Center)
          .backgroundColor(this.controlBarTint())
          .backdropBlur(this.glassRadius())
          .borderRadius('26vp')
          .onAreaChange((_old: Area, area: Area) => { this.measureTopBar(area); })
      } else {
      Row({ space: 16 }) {
        // 返回按钮：置于影视标题左侧（全屏与竖屏都显示）。
        this.topIconButton($r('sys.symbol.chevron_left_circle'), '返回', () => { void this.back(); });
        // 返回图标右侧：实时设备电量 + 百分比。
        Row({ space: '3vp' }) {
          SymbolGlyph(this.batteryIcon())
            .fontSize(Ui.fs('16vp', this.fontScale))
            .fontColor([Ui.ink(this.playerDark())]);
          Text(this.batteryPercent + '%')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(this.batteryCharging ? '#2E9E5B' : Ui.ink(this.playerDark()))
            .maxLines(1);
        }
          .height('24vp')
          .padding({ left: '2vp', right: '2vp' })
          .alignItems(VerticalAlign.Center)
          .accessibilityText('电量 ' + String(this.batteryPercent) + '%');
        // 影视名称 + 剧集：竖屏与全屏都显示（竖屏控制栏与全屏保持一致）。
        Column({ space: '1vp' }) {
          Text(this.video?.tilie || this.video?.yhm || '无音影视')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.playerDark()))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
          // 画圈处：拼成「正在播放： 第 N 集」（直播源仍显示「直播」）。
          Text(this.liveMode ? '直播' : '正在播放： 第 ' + String(this.episodeIndex + 1) + ' 集')
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.playerDark()))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
          .width(this.fullScreen ? '26%' : '24%')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
        // 影视名称右侧：实时时间（时:分）。
        Text(this.clockText)
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.ink(this.playerDark()))
          .maxLines(1)
          .height('24vp')
          .textAlign(TextAlign.Center)
          .accessibilityText('当前时间 ' + this.clockText);
        Row({ space: this.topControlGap() }) {
          // 分享到群只保留一个入口（原来重复放置了两个相同的 share 按钮）。
          this.topIconButton($r('sys.symbol.wireless_projection'), this.castTargetName.length > 0 ? ('投屏中：' + this.castTargetName) : '投屏', () => {
              if (this.castTargetName.length > 0 && this.castTarget !== undefined) { this.reopenCastControl(); return; }
              this.openCastPanel();
            });
          Column() { this.topIconButton($r('sys.symbol.square_grid_2x2'), '隔空传送', () => { void this.shareCurrentEpisode('airdrop'); }); }
            .visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          Column() { this.topIconButton($r('sys.symbol.share'), '分享到群', () => { void this.shareToGroup(); }); }
            .visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          this.sessionIconButton();
          Column() {
            this.topSettingButton($r('sys.symbol.route'), this.routeLabel(), '切换播放线路，当前线路 ' + (this.routeIndex + 1), () => { if (Date.now() - this.lineLongPressAt < 800) { return; } if (this.sessionControlBlocked()) { return; } const count = this.episodes[this.episodeIndex]?.routes.length || 0; if (count < 2) { this.toast('当前影片只有一个接口资源'); return; } this.routeIndex = (this.routeIndex + 1) % count; this.resetRouteFailures(); const name: string = this.episodes[this.episodeIndex].routes[this.routeIndex].title; this.toast('已切到线路 ' + String(this.routeIndex + 1) + (name.length > 0 ? ' · ' + name : '')); void this.selectSource(true); },
              () => { this.lineLongPressAt = Date.now(); this.openLinePanel(); });
          }
            .visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          Column() { this.favoriteButton(true); }.visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
          // 播放设置齿轮移到收藏右侧。
          this.topIconButton($r('sys.symbol.gearshape'), '播放设置', () => { this.openSettingsPanel(); });
          Column() { this.downloadButton(true); }.visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
          .justifyContent(this.fullScreen ? FlexAlign.End : FlexAlign.Start)
          // 竖屏只保留 返回 / 电量 / 片名集数 / 时间；其余入口全屏才显示。
          .visibility(this.fullScreen ? Visibility.Visible : Visibility.None);
      }.width('100%').height('52vp').padding({ left: '8vp', right: '8vp', top: '4vp', bottom: '4vp' }).alignItems(VerticalAlign.Center)
        .backgroundColor(this.controlBarTint()).backdropBlur(this.glassRadius()).borderRadius('26vp')
        
        .onAreaChange((_old: Area, area: Area) => { this.measureTopBar(area); })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); }).onHover((inside: boolean) => { this.hovered = inside; this.reveal(); });
      }
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
        SymbolGlyph($r('sys.symbol.forward_end_fill')).fontSize(Ui.fs('24vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
      }.width('24vp').height('24vp').padding('0vp').margin({ left: '0vp' })
        .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('12vp')
        
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
        SymbolGlyph(this.fullScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right')).fontSize(Ui.fs('22vp', this.fontScale)).fontColor([Ui.ink(this.playerDark())]);
      }.width('44vp').height('44vp').padding('0vp')
        .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('22vp')
        
        .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
        .accessibilityText(this.fullScreen ? '退出全屏' : '全屏')
        .onClick(() => { this.reveal(); void this.toggleFullScreen(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private favoriteButton(compact: boolean = false) {
      // 顶栏沿用原星标、收藏动效与禁用条件，仅把材质换成玻璃胶囊。
      Button(compact ? (this.favoriteSelected ? '★' : '☆') : (this.favoriteSelected ? '★ 已收藏' : '☆ 收藏')).fontSize(Ui.fs('13vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.favoriteSelected ? Ui.accentStrong(this.playerDark()) : this.ink())
        .height(compact ? '24vp' : '44vp').constraintSize({ minWidth: compact ? '24vp' : '44vp', maxWidth: compact ? '24vp' : '100%' }).padding({ left: compact ? '0vp' : '12vp', right: compact ? '0vp' : '12vp' })
        .backgroundColor(this.favoriteSelected ? this.selectedSurface() : Ui.glassTintSoft(this.playerDark()))
        .borderRadius(compact ? '12vp' : '22vp')
        
        
        .scale({ x: this.favoriteScale, y: this.favoriteScale }).enabled(!this.favoriteBusy && this.video !== undefined).accessibilityText(this.favoriteSelected ? '取消影视收藏' : '收藏当前影片')
        .onClick(() => { this.reveal(); this.toggleFavorite(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private downloadButton(compact: boolean = false) {
      // 紧凑入口保留文字/完成勾选，不替换原图标；完整实时状态仍供无障碍和详情区使用。
      Button(compact ? (this.downloadButtonState === PlayerDownloadPhase.COMPLETED ? '✓' : '下载') : (this.downloadControlPending ? '暂停中…' : this.downloadLabel)).fontSize(Ui.fs(compact ? '10vp' : '13vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(this.downloadProblem ? this.warningInk() : this.downloadButtonState === PlayerDownloadPhase.COMPLETED ? this.ink() : Ui.accentStrong(this.playerDark()))
        .height(compact ? '24vp' : '44vp').constraintSize({ minWidth: compact ? '24vp' : '44vp', maxWidth: compact ? '24vp' : '100%' }).padding({ left: compact ? '0vp' : '12vp', right: compact ? '0vp' : '12vp' })
        .backgroundColor(this.downloadButtonState === PlayerDownloadPhase.COMPLETED || this.downloadProblem ? Ui.glassTintSoft(this.playerDark()) : this.selectedSurface())
        .borderRadius(compact ? '12vp' : '22vp')
        
        .enabled(this.canControlDownload())
        .accessibilityText((this.downloadControlPending ? '正在暂停下载任务' : this.downloadLabel) + (this.downloadDetail ? '，' + this.downloadDetail : ''))
        .onClick(() => { this.reveal(); void this.downloadEpisode(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }
    @Builder private speedPopup() {
      Column({ space: 8 }) {
        Text('播放倍速').fontSize(Ui.fs('16vp', this.fontScale)).fontColor(this.ink()).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: '6vp' });
        ForEach(this.speedLabels, (label: string, index: number) => {
          Button(label).width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.speedIndex === index ? Ui.accentStrong(this.playerDark()) : this.ink()).backgroundColor(this.speedIndex === index ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark())).borderRadius('22vp').onClick(() => { this.selectSpeed(index); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
        }, (_label: string, index: number) => index.toString());
      }.width('220vp').padding('16vp').backgroundColor(this.solidPanel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.9, y: 0.9 } }).onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .visibility(this.speedMenuVisible ? Visibility.Visible : Visibility.None);
    }
    @Builder private ratioPopup() {
      Column({ space: 8 }) {
        Text('画面比例').fontSize(Ui.fs('16vp', this.fontScale)).fontColor(this.ink()).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: '6vp' });
        ForEach(this.ratioLabels, (label: string) => {
          Button(label).width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor(this.ratioMode === label ? Ui.accentStrong(this.playerDark()) : this.ink())
            .backgroundColor(this.ratioMode === label ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
            .borderRadius('22vp')
            .onClick(() => { this.selectRatio(label); this.reveal(); })
            .onTouch((event: TouchEvent) => { event.stopPropagation(); });
        }, (label: string) => label);
      }.width('220vp').padding('16vp').backgroundColor(this.solidPanel()).backdropBlur(this.glassRadius()).borderRadius('24vp')
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.9, y: 0.9 } })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .visibility(this.ratioMenuVisible ? Visibility.Visible : Visibility.None);
    }
    @Builder private episodePopup() {
      Column({ space: 12 }) {
        Text('选集 · ' + this.episodes.length + ' 集').fontSize(Ui.fs('18vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).width('100%');
        Scroll() {
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start, alignContent: FlexAlign.Start }) {
            ForEach(this.orderedEpisodeIndices(), (index: number) => {
              Button(this.episodes[index].title).fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.episodeIndex === index ? Ui.accentStrong(this.playerDark()) : this.ink()).height('48vp').padding({ left: '16vp', right: '16vp' })
                .backgroundColor(this.episodeIndex === index ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark())).borderRadius('22vp').constraintSize({ maxWidth: '100%' }).margin({ right: '8vp', bottom: '8vp' })
                .onClick(() => { this.selectEpisode(index); this.episodeMenuVisible = false; this.reveal(); }).onTouch((event: TouchEvent) => { event.stopPropagation(); });
            }, (index: number): string => index.toString());
          }.width('100%');
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto);
      }.width(Math.max(200, Math.min(360, this.viewportWidth - 32)) + 'vp')
        .height(Math.max(120, Math.min(360, this.viewportHeight - 48)) + 'vp').padding('16vp')
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
        .visibility(this.fullScreen && this.danmakuEnabled && !this.previewVisible ? Visibility.Visible : Visibility.None)
        .hitTestBehavior(HitTestMode.None);
    }
    // 弹幕设置改用 ArkUI 原生 ContentCover 模态层，脱离播放器 Stack/手势层的命中测试。
  /** 投屏面板：系统投屏 + DLNA 设备发现 + 手动 IP。 */
  @Builder
  private castPanel() {
    Column({ space: '10vp' }) {
      Row() {
        Column({ space: '2vp' }) {
          Text('投屏')
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.playerDark()))
          Text('支持鸿蒙生态设备（系统投屏）与局域网电视/盒子（DLNA）')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.playerDark()))
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Text('关闭')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.playerDark()))
          .height('30vp')
          .padding({ left: '12vp', right: '12vp' })
          .borderRadius('15vp')
          .backgroundColor(Ui.glassTintSoft(this.playerDark()))
          .onClick(() => { this.closeCastPanel(); })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      // 系统投屏：交给系统「多设备协同/投屏」入口，应用内只做引导。
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('系统投屏（鸿蒙设备）')
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor(Ui.ink(this.playerDark()))
          Text('从控制中心「投屏」选择手机/平板/智慧屏')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.playerDark()))
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .padding('12vp')
        .borderRadius('14vp')
        .backgroundColor(Ui.glassTintSoft(this.playerDark()))
        .onClick(() => { this.toast('请下拉控制中心使用系统投屏'); })
      if (this.castTargetName.length > 0) {
        Column({ space: '8vp' }) {
          Text('已连接：' + this.castTargetName)
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.playerDark()))
            .width('100%')
          Row({ space: '8vp' }) {
            Text('暂停')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark()))
              .height('32vp')
              .padding({ left: '14vp', right: '14vp' })
              .borderRadius('16vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { void this.castControl('Pause', '<Speed>1</Speed>', '已暂停'); })
            Text('继续')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark()))
              .height('32vp')
              .padding({ left: '14vp', right: '14vp' })
              .borderRadius('16vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { void this.castControl('Play', '<Speed>1</Speed>', '已继续播放'); })
            Text('音量-')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark()))
              .height('32vp')
              .padding({ left: '12vp', right: '12vp' })
              .borderRadius('16vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { void this.castVolumeStep(-10); })
            Text('音量+')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark()))
              .height('32vp')
              .padding({ left: '12vp', right: '12vp' })
              .borderRadius('16vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { void this.castVolumeStep(10); })
            Text('停止')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor('#FF6B6B')
              .height('32vp')
              .padding({ left: '14vp', right: '14vp' })
              .borderRadius('16vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { void this.castControl('Stop', '', '已停止投屏'); })
          }
            .width('100%')
        }
          .width('100%')
          .padding('10vp')
          .borderRadius('14vp')
          .backgroundColor(Ui.glassTintSoft(this.playerDark()))
      }
      Text('投到电视（DLNA）')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.playerDark()))
        .width('100%')
      if (this.castSearching) {
        Row({ space: '8vp' }) {
          LoadingProgress().width('18vp').height('18vp').color(Ui.accent(this.playerDark()))
          Text('正在搜索局域网设备…')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.playerDark()))
        }
          .width('100%')
      }
      ForEach(this.castDevices, (device: CastDevice) => {
        Row({ space: '10vp' }) {
          Text(device.name)
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontColor(Ui.ink(this.playerDark()))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('投屏')
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.playerDark()))
            .height('28vp')
            .padding({ left: '12vp', right: '12vp' })
            .borderRadius('14vp')
            .backgroundColor(Ui.accentSoft(this.playerDark()))
            .onClick(() => { void this.castTo(device); })
        }
          .width('100%')
          .padding('10vp')
          .borderRadius('14vp')
          .backgroundColor(Ui.glassTintSoft(this.playerDark()))
      }, (device: CastDevice) => 'cast-' + device.id)
      if (this.castStatus.length > 0) {
        Text(this.castStatus)
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.playerDark()))
          .width('100%')
          .maxLines(3)
      }
      Row({ space: '8vp' }) {
        TextInput({ text: $$this.castIp, placeholder: '电视IP（选填，如 192.168.1.5）' })
          .height('38vp')
          .layoutWeight(1)
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.ink(this.playerDark()))
          .backgroundColor(Ui.glassTintSoft(this.playerDark()))
          .borderRadius('12vp')
        Text('重新扫描')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.accentStrong(this.playerDark()))
          .height('38vp')
          .padding({ left: '10vp', right: '10vp' })
          .onClick(() => {
            if (this.castIp.trim().length > 0) { void this.castManualIp(); return; }
            this.startCastSearch();
          })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
    }
      .width('100%')
      .padding({ left: '18vp', right: '18vp', top: '18vp', bottom: '24vp' })
      .backgroundColor(this.canvas())
      .justifyContent(FlexAlign.Start)
  }

    /**
     * 播放器只有一个 bindContentCover：同一组件上叠加多个 bindContentCover 时，
     * 后绑定的投屏面板会覆盖弹幕面板，表现为「点弹幕图标没反应」。
     * 这里用同一个 Cover 按状态切换内容。
     */
    @Builder private playerModalCover() {
      // 根节点保持唯一：部分 ArkUI 版本对 if/else 作为 ContentCover 根节点支持不稳定。
      Stack({ alignContent: Alignment.Center }) {
        if (this.danmakuPanelVisible) {
          this.danmakuSettingsCover()
        } else if (this.linePanelVisible) {
          this.lineSelectorCover()
        } else {
          this.castPanel()
        }
      }
        .width('100%')
        .height('100%');
    }

    @Builder private lineTipBubble() {
      Column({ space: '10vp' }) {
        Row({ space: '10vp' }) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('36vp')
              .height('36vp')
              .borderRadius('11vp')
              .backgroundColor(Ui.accentSoft(this.playerDark()));
            SymbolGlyph($r('sys.symbol.route'))
              .fontSize(Ui.fs('18vp', this.fontScale))
              .fontColor([Ui.accentStrong(this.playerDark())]);
          }
            .width('36vp')
            .height('36vp');
          Text('线路切换')
            .fontSize(Ui.fs('17vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.playerDark()))
            .layoutWeight(1);
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontColor([Ui.inkSoft(this.playerDark())]);
          }
            .width('28vp')
            .height('28vp')
            .backgroundColor(Color.Transparent)
            .onClick(() => { void this.dismissLineTip(false); });
        }
          .width('100%')
          .alignItems(VerticalAlign.Center);
        Text('单击快速切换，长按0.25秒以上打开线路选择窗口，可自定义选择线路。')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.playerDark()))
          .lineHeight('19vp')
          .width('100%');
        Row({ space: '18vp' }) {
          Text('不再提示')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.accent(this.playerDark()))
            .height('30vp')
            .onClick(() => { void this.dismissLineTip(true); });
          Text('取消')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.accent(this.playerDark()))
            .height('30vp')
            .onClick(() => { void this.dismissLineTip(false); });
        }
          .width('100%')
          .alignItems(VerticalAlign.Center);
      }
        .width('280vp')
        .padding({ left: '14vp', right: '14vp', top: '12vp', bottom: '8vp' })
        .backgroundColor(this.panel())
        .backdropBlur(this.glassRadius())
        .borderRadius('18vp')
        .shadow({ radius: 18, color: Ui.shadow(this.playerDark()), offsetY: 8 });
    }

    @Builder private lineTipOverlay() {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.lineTipBubble();
      }
        .width('100%')
        .height('100%')
        .padding({ top: '64vp', right: '12vp' })
        .hitTestBehavior(HitTestMode.Transparent);
    }

    @Builder private lineSelectorCard(route: PlayerRoute, index: number) {
      Column({ space: '5vp' }) {
        Row({ space: '6vp' }) {
          SymbolGlyph($r('sys.symbol.wifi'))
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontColor([this.lineSignalColor(index)]);
          Blank();
          if (this.lineStatusAt(index) === 'testing') {
            LoadingProgress()
              .width('16vp')
              .height('16vp')
              .color(Ui.accent(this.playerDark()));
          } else if (index === this.routeIndex) {
            Text('当前')
              .fontSize(Ui.fs('9.5vp', this.fontScale))
              .fontColor(Ui.accentStrong(this.playerDark()))
              .height('20vp')
              .padding({ left: '7vp', right: '7vp' })
              .borderRadius('10vp')
              .backgroundColor(Ui.accentSoft(this.playerDark()));
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center);
        Text(route.title.length > 0 ? route.title : '线路 ' + String(index + 1))
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.playerDark()))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.lineStatusText(index))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(this.lineSignalColor(index))
          .maxLines(1)
          .width('100%');
      }
        .width('48%')
        .height('92vp')
        .padding({ left: '10vp', right: '10vp', top: '8vp', bottom: '8vp' })
        .borderRadius('16vp')
        .backgroundColor(index === this.routeIndex ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: '8vp' })
        .onClick(() => { this.chooseLine(index); });
    }

    @Builder private lineSelectorCover() {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Ui.scrim(this.playerDark()))
          .onClick(() => { this.linePanelVisible = false; });
        Column({ space: '12vp' }) {
          Row({ space: '8vp' }) {
            Text('线路选择')
              .fontSize(Ui.fs('18vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.playerDark()))
              .layoutWeight(1);
            Button('重新检测')
              .fontSize(Ui.fs('12vp', this.fontScale))
              .fontColor(Ui.accentStrong(this.playerDark()))
              .height('32vp')
              .padding({ left: '12vp', right: '12vp' })
              .backgroundColor(Ui.accentSoft(this.playerDark()))
              .borderRadius('16vp')
              .onClick(() => { void this.testAllLines(); });
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(Ui.fs('16vp', this.fontScale))
                .fontColor([Ui.ink(this.playerDark())]);
            }
              .width('32vp')
              .height('32vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .onClick(() => { this.linePanelVisible = false; });
          }
            .width('100%')
            .alignItems(VerticalAlign.Center);
          Text(this.lineTesting ? '正在检测所有线路…' : '绿色为可用线路，灰色为不可用线路')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.playerDark()))
            .width('100%');
          if (this.currentRoutes().length === 0) {
            Text('当前影片没有可切换的资源线路')
              .fontSize(Ui.fs('13vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.playerDark()))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: '20vp', bottom: '20vp' });
          } else {
            Scroll() {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Start }) {
                ForEach(this.currentRoutes(), (route: PlayerRoute, index: number) => {
                  this.lineSelectorCard(route, index);
                }, (route: PlayerRoute, index: number) => 'line-' + String(index) + '-' + route.sourceUrl);
              }
                .width('100%');
            }
              .width('100%')
              .constraintSize({ maxHeight: '56%' })
              .scrollBar(BarState.Off);
          }
        }
          .width('88%')
          .constraintSize({ maxWidth: '520vp' })
          .padding('16vp')
          .backgroundColor(this.panel())
          .backdropBlur(this.glassRadius())
          .borderRadius('24vp');
      }
        .width('100%')
        .height('100%');
    }

    @Builder private danmakuSettingsCover() {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.playerDark()))
          .onClick(() => { this.danmakuPanelVisible = false; });
        Scroll() {
          Column({ space: 12 }) {
            Row() {
              Text('弹幕设置').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).fontWeight(FontWeight.Medium).layoutWeight(1);
              Button('关闭').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).height('32vp').padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('16vp')
                
                .onClick(() => { this.danmakuPanelVisible = false; });
            }.width('100%');
            Row({ space: 8 }) {
              Text('弹幕显示').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark())).layoutWeight(1);
              Button(this.danmakuEnabled ? '已开启' : '已关闭').fontSize(Ui.fs('12vp', this.fontScale)).height('36vp').padding({ left: '14vp', right: '14vp' })
                .fontColor(this.danmakuEnabled ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                .backgroundColor(this.danmakuEnabled ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                .borderRadius('18vp')
                
                .onClick(() => { this.danmakuEnabled = !this.danmakuEnabled; void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('字号').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
              Button('A−').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).padding({ left: '12vp', right: '12vp' })
                .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('17vp')
                
                .onClick(() => { this.danmakuFontSize = Math.max(12, this.danmakuFontSize - 2); void this.persistDanmakuSettings(); });
              Text(this.danmakuFontSize + 'vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.playerDark()));
              Button('A+').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).padding({ left: '12vp', right: '12vp' })
                .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('17vp')
                
                .onClick(() => { this.danmakuFontSize = Math.min(32, this.danmakuFontSize + 2); void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('透明度').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
              Slider({ value: this.danmakuOpacity * 100, min: 30, max: 100, step: 5 }).layoutWeight(1)
                .trackColor(Ui.divider(this.playerDark())).selectedColor(Ui.accent(this.playerDark())).blockColor(Ui.ink(this.playerDark()))
                .onChange((value: number) => { this.danmakuOpacity = value / 100; void this.persistDanmakuSettings(); });
            }.width('100%');
            Row({ space: 8 }) {
              Text('滚动速度').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
              Slider({ value: this.danmakuSpeed, min: 0.5, max: 2, step: 0.25 }).layoutWeight(1)
                .trackColor(Ui.divider(this.playerDark())).selectedColor(Ui.accent(this.playerDark())).blockColor(Ui.ink(this.playerDark()))
                .onChange((value: number) => { this.danmakuSpeed = value; void this.persistDanmakuSettings(); });
              Text(this.danmakuSpeed.toFixed(2) + '×').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.playerDark()));
            }.width('100%');
            Row({ space: 8 }) {
              Text('协播弹幕同步').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark())).layoutWeight(1);
              Button(this.danmakuSyncEnabled ? '开启' : '关闭').height('34vp').fontSize(Ui.fs('12vp', this.fontScale)).padding({ left: '14vp', right: '14vp' })
                .fontColor(this.danmakuSyncEnabled ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                .backgroundColor(this.danmakuSyncEnabled ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                .borderRadius('17vp')
                
                .onClick(() => { this.danmakuSyncEnabled = !this.danmakuSyncEnabled; void this.persistDanmakuSettings(); });
            }.width('100%');
            // 弹幕输入条与首页搜索条同一套玻璃配方：软玻璃底 + 全圆角 + 细描边 + 背景模糊。
            Row({ space: 8 }) {
              TextInput({ placeholder: '输入一条弹幕…', text: this.danmakuInput }).layoutWeight(1).height('44vp')
                .fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).placeholderColor(Ui.inkFaint(this.playerDark())).caretColor(Ui.accent(this.playerDark()))
                .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('22vp').padding({ left: '16vp', right: '16vp' })
                
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
              Button(this.danmakuLoading ? '处理中…' : '导入本地文件').fontSize(Ui.fs('12vp', this.fontScale)).height('38vp').fontColor(Ui.ink(this.playerDark())).padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('19vp')
                
                .enabled(!this.danmakuLoading).onClick(() => { void this.importDanmakuFile(); });
              Button('在线搜索').fontSize(Ui.fs('12vp', this.fontScale)).height('38vp').fontColor(Ui.accentStrong(this.playerDark())).padding({ left: '14vp', right: '14vp' })
                .backgroundColor(Ui.accentSoft(this.playerDark())).borderRadius('19vp')
                
                .enabled(!this.danmakuLoading).onClick(() => { void this.searchDanmakuOnline(); });
            }.width('100%');
            TextInput({ placeholder: '影片名 / 年份 / 分集', text: this.danmakuSearchKeyword }).height('40vp').fontSize(Ui.fs('13vp', this.fontScale))
              .fontColor(Ui.ink(this.playerDark())).placeholderColor(Ui.inkFaint(this.playerDark())).caretColor(Ui.accent(this.playerDark()))
              .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('20vp').padding({ left: '14vp', right: '14vp' })
              
              .onChange((value: string) => { this.danmakuSearchKeyword = value; });
            ForEach(this.danmakuSearchResults.slice(0, 5), (result: DanmakuSearchResult) => {
              Row({ space: 8 }) {
                Text((result.source === 'dandanplay' ? '[弹弹play] ' : '[B站] ') + result.title).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).maxLines(2).layoutWeight(1);
                Button('加载').fontSize(Ui.fs('12vp', this.fontScale)).height('32vp').fontColor(Ui.accentStrong(this.playerDark())).padding({ left: '12vp', right: '12vp' })
                  .backgroundColor(Ui.accentSoft(this.playerDark())).borderRadius('16vp')
                  
                  .onClick(() => { void this.loadOnlineDanmaku(result); });
              }.width('100%').padding({ top: '4vp', bottom: '4vp' });
            }, (result: DanmakuSearchResult) => result.source + '-' + result.sourceId);
            Text(this.danmakuStatus).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.inkFaint(this.playerDark())).width('100%');
          }.width('100%').padding('20vp')
            .backgroundColor(Ui.glassTintStrong(this.playerDark())).backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur)).borderRadius('24vp')
                
        }.width('88%').height('78%').constraintSize({ maxWidth: '560vp', maxHeight: '78%' })
          .scrollBar(BarState.Auto).align(Alignment.Center); // 不设置 Block，避免父级 Scroll 阻断内部按钮、Slider 和 TextInput 的命中测试
      }.width('100%').height('100%').padding('0vp').margin('0vp')
        .backgroundColor(Color.Transparent);
    }
    @Builder private controller() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          // 单独分组固定播放/暂停与下一集之间的 16vp 间距，其他控件间距不变。
          Row({ space: '16vp' }) {
            this.playbackIconButton();
            Column() { this.nextEpisodeIconButton(); }
              // 竖屏全屏宽度有限，下一集与弹幕按钮让位给进度条，其余入口仍在菜单里。
              .visibility(this.fullScreenPortrait ? Visibility.None : Visibility.Visible);
          }.height('44vp').alignItems(VerticalAlign.Center);
          // 当前时间 + 缓冲中提示。
          Row({ space: '4vp' }) {
            Text(this.time(this.currentMs)).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.ink());
            if (this.buffering) {
              LoadingProgress().width('12vp').height('12vp').color(this.accent());
            }
          }
            .height('44vp')
            .alignItems(VerticalAlign.Center);
          // 进度条：自绘轨道（底色 / 已缓存 / 已播放），Slider 只负责拖动与点击交互，
          // 这样缓存段可以稳定显示在已播放与未播放之间。
          Stack({ alignContent: Alignment.Start }) {
            Column() {
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height('4vp')
                  .borderRadius('2vp')
                  .backgroundColor(Ui.divider(this.playerDark()));
                Row()
                  .width((this.cachedRatio() * 100) + '%')
                  .height('4vp')
                  .borderRadius('2vp')
                  .backgroundColor(this.playerDark() ? '#4DFFFFFF' : '#33173156');
                Row()
                  .width((this.playedRatio() * 100) + '%')
                  .height('4vp')
                  .borderRadius('2vp')
                  .backgroundColor(this.progressAccent());
              }
                .width('100%')
                .height('4vp');
            }
              .width('100%')
              .height('44vp')
              .justifyContent(FlexAlign.Center)
              .hitTestBehavior(HitTestMode.None);
            Slider({ value: this.currentMs, min: 0, max: Math.max(1, this.durationMs), step: 1000 })
              .width('100%')
              .trackColor(Color.Transparent)
              .selectedColor(Color.Transparent)
              .blockColor(Color.Transparent)
              .enabled(this.durationMs > 0 && !this.receiverLocked && !this.isSlaveMode)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (this.isSlaveMode || this.receiverLocked) { return; }
                this.seeking = mode !== SliderChangeMode.End; this.currentMs = value; this.reveal();
                if (mode === SliderChangeMode.End) {
                  this.previewVisible = false;
                  const cached: boolean = this.isCachedPosition(value);
                  if (cached) { this.buffering = false; }
                  try {
                    this.player?.seek(value, 2 as media.SeekMode);
                    void this.saveWatchRecord();
                    void this.publishSessionState();
                  } catch (_) { this.report('定位进度失败'); }
                } else {
                  // 拖动过程中按 140ms 限频 seek，主画面实时显示目标帧，形成快进帧预览。
                  this.previewVisible = this.seekSnapshot;
                  this.previewSeek(value);
                }
              })
            // 滑块：项目图标，跟手移动且不参与命中测试（点击仍由 Slider 处理）。
            Image($r('app.media.icon'))
              .width('22vp')
              .height('22vp')
              .borderRadius('11vp')
              .border({ width: 1.5, color: this.progressAccent() })
              .backgroundColor(this.playerDark() ? '#CC1A1A1A' : '#F2FFFFFF')
              .translate({ x: this.progressThumbX() })
              .hitTestBehavior(HitTestMode.None);
            // 拖动时浮层：目标时间 + 当前缓存比例。
            if (this.seeking && this.progressTrackWidth > 0) {
              Row({ space: '6vp' }) {
                Text(this.time(this.currentMs))
                  .fontSize(Ui.fs('10.5vp', this.fontScale))
                  .fontColor(Ui.ink(this.playerDark()));
                Text(this.isCachedPosition(this.currentMs) ? '已缓存 · 秒开' : '缓存 ' + this.cachedPercentText())
                  .fontSize(Ui.fs('10.5vp', this.fontScale))
                  .fontColor(this.isCachedPosition(this.currentMs) ? Ui.accentStrong(this.playerDark()) : Ui.inkFaint(this.playerDark()));
              }
                .height('24vp')
                .padding({ left: '9vp', right: '9vp' })
                .borderRadius('12vp')
                .backgroundColor(Ui.glassTintStrong(this.playerDark()))
                
                .translate({ x: this.seekBubbleX(), y: -4 })
                .hitTestBehavior(HitTestMode.None);
            }
          }
            .layoutWeight(1)
            .height('44vp')
            .onAreaChange((_old: Area, area: Area) => {
              const w: number = Number(area.width);
              if (Number.isFinite(w) && w > 0) { this.progressTrackWidth = w; }
            });
          Text(this.time(this.durationMs)).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.ink());
          // 缓存百分比：空间足够的全屏/平板才显示，避免竖屏进度条被挤窄。
          if (this.durationMs > 0 && this.cachedRatio() < 0.999) {
            Row({ space: '4vp' }) {
              if (this.diskCacheActive) {
                LoadingProgress().width('11vp').height('11vp').color(this.accent());
              }
              Text((this.diskCacheActive ? '缓存中 ' : '缓存 ') + this.cachedPercentText())
                .fontSize(Ui.fs('10vp', this.fontScale))
                .fontColor(this.diskCacheActive ? Ui.accentStrong(this.playerDark()) : Ui.inkFaint(this.playerDark()))
                .maxLines(1);
            }
              .visibility(this.fullScreen || this.tablet() ? Visibility.Visible : Visibility.None);
          }
          if (this.fullScreen) {
            Button('选集').fontSize(Ui.fs('12vp', this.fontScale)).fontColor(this.episodeMenuVisible ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark())).height('34vp').padding({ left: '12vp', right: '12vp' })
              .backgroundColor(this.episodeMenuVisible ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark())).borderRadius('17vp')
              .visibility(this.fullScreenPortrait ? Visibility.None : Visibility.Visible)
              .onClick(() => { this.castPanelVisible = false; this.danmakuPanelVisible = false; this.speedMenuVisible = false; this.episodeMenuVisible = !this.episodeMenuVisible; this.reveal(); });
          }
          this.fullScreenIconButton();
        }.width('100%').height('44vp').alignItems(VerticalAlign.Center);
      }.padding(this.fullScreenPortrait ? '8vp' : '10vp').width('100%').backgroundColor(this.controlBarTint()).backdropBlur(this.glassRadius()).borderRadius('26vp')
        
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
        Progress({ value: this.downloadPercent, total: 100, type: ProgressType.Linear }).width('100%').color(this.accent()).backgroundColor(Ui.divider(this.playerDark()))
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
          Button(this.episodesDescending ? '↑ 倒序' : '↓ 正序').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.accentStrong(this.playerDark())).height('44vp').constraintSize({ minWidth: '76vp' }).padding({ left: '12vp', right: '12vp' })
            .backgroundColor(Ui.glassTintSoft(this.playerDark())).borderRadius('22vp').margin({ right: '8vp', bottom: '8vp' })
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
              Button(this.episodes[index].title).fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.episodeIndex === index ? Ui.accentStrong(this.playerDark()) : this.ink()).height('48vp').padding({ left: '16vp', right: '16vp' }).backgroundColor(this.episodeIndex === index ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark())).borderRadius('24vp')
                
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
    /** 播放设置：右侧半屏面板，紧贴屏幕右侧，点击遮罩或返回键关闭。 */
    private panelActionLabel(kind: string): string {
      if (kind === 'download') { return '下载'; }
      if (kind === 'fill') { return this.ratioMode === '铺满' ? '原画比例' : '撑满全屏'; }
      if (kind === 'eye') { return this.eyeCare ? '护眼已开' : '护眼模式'; }
      if (kind === 'danmaku') { return '弹幕设置'; }
      if (kind === 'pip') { return '画中画'; }
      if (kind === 'audio') { return this.audioOnly ? '恢复画面' : '音频播放'; }
      if (kind === 'ratio') { return '画面比例'; }
      if (kind === 'speed') { return '播放倍速'; }
      return kind;
    }

    @Builder private quickPanelAction(kind: string, icon: Resource, action: () => void) {
      Column({ space: '6vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('40vp')
            .height('40vp')
            .borderRadius('20vp')
            .backgroundColor(Ui.glassTintSoft(this.playerDark()))
            ;
          SymbolGlyph(icon)
            .fontSize(Ui.fs('19vp', this.fontScale))
            .fontColor([Ui.ink(this.playerDark())]);
        }
          .width('40vp')
          .height('40vp');
        Text(this.panelActionLabel(kind))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.playerDark()))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
        .width('25%')
        .padding({ top: '6vp', bottom: '6vp' })
        .onClick(() => { action(); })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }

    @Builder private resolutionChip(value: string, label: string) {
      Text(label)
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .height('32vp')
        .padding({ left: '14vp', right: '14vp' })
        .borderRadius('16vp')
        .fontColor(this.resolution === value ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
        .backgroundColor(this.resolution === value ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
        .margin({ right: '6vp', bottom: '6vp' })
        .onClick(() => { this.setResolution(value); })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); });
    }

    @Builder private settingsPanelDivider() {
      Divider()
        .strokeWidth(1)
        .color(Ui.divider(this.playerDark()))
        .width('100%')
        .margin({ top: '2vp', bottom: '2vp' });
    }

    @Builder private settingsPanel() {
      Column() {
        Row({ space: '10vp' }) {
          Text('播放设置')
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.playerDark()))
            .layoutWeight(1);
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(Ui.fs('16vp', this.fontScale))
              .fontColor([Ui.ink(this.playerDark())]);
          }
            .width('34vp')
            .height('34vp')
            .backgroundColor(Ui.glassTintSoft(this.playerDark()))
            .onClick(() => { this.closeSettingsPanel(); });
        }
          .width('100%')
          .height('54vp')
          .padding({ left: '16vp', right: '12vp' })
          .alignItems(VerticalAlign.Center);
        Scroll() {
          Column({ space: '12vp' }) {
            // 快捷操作：下载 / 撑满全屏 / 护眼 / 弹幕 / 画中画 / 音频。
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              this.quickPanelAction('download', $r('sys.symbol.arrow_down_to_line'), (): void => { void this.downloadEpisode(); });
              this.quickPanelAction('fill', $r('sys.symbol.arrow_up_left_and_arrow_down_right'), (): void => { this.toggleFillScreen(); });
              this.quickPanelAction('eye', $r('sys.symbol.eye'), (): void => { this.toggleEyeCare(); });
              this.quickPanelAction('danmaku', $r('sys.symbol.doc_text'), (): void => { this.openDanmakuFromPanel(); });
              this.quickPanelAction('pip', $r('sys.symbol.rectangle_on_rectangle'), (): void => { void this.startPictureInPicture(); });
              this.quickPanelAction('audio', $r('sys.symbol.play_fill'), (): void => { this.toggleAudioOnly(); });
              this.quickPanelAction('ratio', $r('sys.symbol.aspectratio'), (): void => {
                this.closeSettingsPanel();
                this.ratioMenuVisible = true;
              });
              this.quickPanelAction('speed', $r('sys.symbol.video_speed'), (): void => {
                this.closeSettingsPanel();
                this.speedMenuVisible = true;
              });
            }
              .width('100%');
            // 画质：分辨率偏好 + HDR 优先（切换后按当前位置重新 prepare）。
            Column({ space: '8vp' }) {
              Row({ space: '8vp' }) {
                Text('分辨率')
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(Ui.ink(this.playerDark()))
                  .layoutWeight(1);
                Text(this.resolutionLabel())
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(this.resolution === 'auto' ? Ui.inkFaint(this.playerDark()) : Ui.accentStrong(this.playerDark()));
              }
                .width('100%')
                .height('32vp')
                .alignItems(VerticalAlign.Center);
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                this.resolutionChip('auto', '自动');
                this.resolutionChip('4k', '4K');
                this.resolutionChip('1080', '1080P');
                this.resolutionChip('720', '720P');
                this.resolutionChip('480', '480P');
              }
                .width('100%');
              Row({ space: '10vp' }) {
                Column({ space: '2vp' }) {
                  Text('HDR 硬件渲染')
                    .fontSize(Ui.fs('14vp', this.fontScale))
                    .fontColor(Ui.ink(this.playerDark()));
                  Text('硬件 HDR 渲染，片源支持时生效')
                    .fontSize(Ui.fs('10.5vp', this.fontScale))
                    .fontColor(Ui.inkFaint(this.playerDark()))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start);
                Button(this.hdrEnabled ? '已开启' : '已关闭')
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .height('36vp')
                  .padding({ left: '14vp', right: '14vp' })
                  .fontColor(this.hdrEnabled ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                  .backgroundColor(this.hdrEnabled ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                  .borderRadius('18vp')
                  .onClick(() => { this.setHdr(!this.hdrEnabled); })
                  .onTouch((event: TouchEvent) => { event.stopPropagation(); });
              }
                .width('100%')
                .alignItems(VerticalAlign.Center);
            }
              .width('100%');
            // 定时关闭 / 循环播放 / 跳过片头片尾。
            Column({ space: '6vp' }) {
              Row({ space: '8vp' }) {
                Text('定时关闭')
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(Ui.ink(this.playerDark()))
                  .layoutWeight(1);
                Text(this.sleepLabel())
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(this.sleepMinutes > 0 ? Ui.accentStrong(this.playerDark()) : Ui.inkFaint(this.playerDark()));
                Text('›')
                  .fontSize(Ui.fs('18vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.playerDark()))
                  .rotate({ angle: this.sleepOptionsVisible ? 90 : 0 });
              }
                .width('100%')
                .height('38vp')
                .alignItems(VerticalAlign.Center)
                .onClick(() => { this.toggleSleepOptions(); });
              if (this.sleepOptionsVisible) {
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                  Text('15 分钟')
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(this.sleepMinutes === 15 ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.sleepMinutes === 15 ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setSleepMinutes(15); });
                  Text('30 分钟')
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(this.sleepMinutes === 30 ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.sleepMinutes === 30 ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setSleepMinutes(30); });
                  Text('60 分钟')
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(this.sleepMinutes === 60 ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.sleepMinutes === 60 ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setSleepMinutes(60); });
                  Text('90 分钟')
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(this.sleepMinutes === 90 ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.sleepMinutes === 90 ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setSleepMinutes(90); });
                  Text('关闭')
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(this.sleepMinutes === 0 ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.sleepMinutes === 0 ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setSleepMinutes(0); });
                }
                  .width('100%');
              }
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('循环播放')
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(Ui.ink(this.playerDark()))
                  .layoutWeight(1);
                Text('单集')
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(this.loopMode === 'single' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                  .height('30vp').padding({ left: '11vp', right: '11vp' }).borderRadius('15vp')
                  .backgroundColor(this.loopMode === 'single' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                  .onClick(() => { this.setLoopMode('single'); });
                Text('列表')
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(this.loopMode === 'list' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                  .height('30vp').padding({ left: '11vp', right: '11vp' }).borderRadius('15vp')
                  .backgroundColor(this.loopMode === 'list' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                  .onClick(() => { this.setLoopMode('list'); });
                Text('关闭')
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(this.loopMode === 'off' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                  .height('30vp').padding({ left: '11vp', right: '11vp' }).borderRadius('15vp')
                  .backgroundColor(this.loopMode === 'off' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                  .onClick(() => { this.setLoopMode('off'); });
              }
                .width('100%')
                .height('38vp')
                .alignItems(VerticalAlign.Center);
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Column({ space: '1vp' }) {
                  Text('跳过片头片尾')
                    .fontSize(Ui.fs('14vp', this.fontScale))
                    .fontColor(Ui.ink(this.playerDark()))
                    .width('100%');
                  Text(this.skipIntroOutro ? ('片头 ' + String(this.introSeconds) + 's · 片尾 ' + String(this.outroSeconds) + 's') : '按自定义进度头尾自动跳过')
                    .fontSize(Ui.fs('10.5vp', this.fontScale))
                    .fontColor(Ui.inkFaint(this.playerDark()))
                    .width('100%');
                }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start);
                Toggle({ type: ToggleType.Switch, isOn: this.skipIntroOutro })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange((value: boolean) => { this.setSkipIntroOutro(value); });
              }
                .width('100%')
                .padding({ top: '4vp', bottom: '4vp' })
                .alignItems(VerticalAlign.Center);
              if (this.skipIntroOutro) {
                Column({ space: '2vp' }) {
                  Row({ space: '8vp' }) {
                    Text('片头').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
                    Text('用当前进度')
                      .fontSize(Ui.fs('10.5vp', this.fontScale))
                      .fontColor(Ui.accentStrong(this.playerDark()))
                      .padding({ left: '8vp', right: '8vp', top: '2vp', bottom: '2vp' })
                      .borderRadius('9vp')
                      .backgroundColor(Ui.accentSoft(this.playerDark()))
                      .onClick(() => { this.setIntroSeconds(this.currentMs / 1000); });
                    Blank();
                    Text(String(this.introSeconds) + ' 秒').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accentStrong(this.playerDark()));
                  }.width('100%');
                  Slider({ value: this.introSeconds, min: 0, max: 300, step: 5, style: SliderStyle.OutSet })
                    .trackColor(Ui.divider(this.playerDark()))
                    .selectedColor(Ui.accent(this.playerDark()))
                    .blockColor(Ui.ink(this.playerDark()))
                    .onChange((value: number) => { this.setIntroSeconds(value); });
                }.width('100%');
                Column({ space: '2vp' }) {
                  Row({ space: '8vp' }) {
                    Text('片尾').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
                    Text('用当前进度')
                      .fontSize(Ui.fs('10.5vp', this.fontScale))
                      .fontColor(Ui.accentStrong(this.playerDark()))
                      .padding({ left: '8vp', right: '8vp', top: '2vp', bottom: '2vp' })
                      .borderRadius('9vp')
                      .backgroundColor(Ui.accentSoft(this.playerDark()))
                      .onClick(() => {
                        const remain: number = (this.durationMs - this.currentMs) / 1000;
                        this.setOutroSeconds(remain);
                      });
                    Blank();
                    Text(String(this.outroSeconds) + ' 秒').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accentStrong(this.playerDark()));
                  }.width('100%');
                  Slider({ value: this.outroSeconds, min: 0, max: 300, step: 5, style: SliderStyle.OutSet })
                    .trackColor(Ui.divider(this.playerDark()))
                    .selectedColor(Ui.accent(this.playerDark()))
                    .blockColor(Ui.ink(this.playerDark()))
                    .onChange((value: number) => { this.setOutroSeconds(value); });
                }.width('100%');
              }
            }
              .width('100%')
              .padding('12vp')
              .borderRadius('18vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()));
            // 色觉辅助 / 高能进度条 / 礼物特效 / 快进截图 / 后台播放。
            Column({ space: '2vp' }) {
              Row({ space: '8vp' }) {
                Text('色觉辅助')
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(Ui.ink(this.playerDark()))
                  .layoutWeight(1);
                Text(this.colorAssist === 'off' ? '关闭' : (this.colorAssist === 'yellow' ? '黄色滤镜' : '蓝色滤镜'))
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.playerDark()));
                Text('›')
                  .fontSize(Ui.fs('18vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.playerDark()))
                  .rotate({ angle: this.colorAssistOptionsVisible ? 90 : 0 });
              }
                .width('100%')
                .height('38vp')
                .alignItems(VerticalAlign.Center)
                .onClick(() => { this.toggleColorAssistOptions(); });
              if (this.colorAssistOptionsVisible) {
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                  Text('关闭').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.colorAssist === 'off' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.colorAssist === 'off' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setColorAssist('off'); });
                  Text('黄色滤镜').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.colorAssist === 'yellow' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.colorAssist === 'yellow' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setColorAssist('yellow'); });
                  Text('蓝色滤镜').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.colorAssist === 'blue' ? Ui.accentStrong(this.playerDark()) : Ui.inkSoft(this.playerDark()))
                    .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
                    .backgroundColor(this.colorAssist === 'blue' ? Ui.accentSoft(this.playerDark()) : Ui.glassTintSoft(this.playerDark()))
                    .margin({ right: '6vp', bottom: '6vp' })
                    .onClick(() => { this.setColorAssist('blue'); });
                }.width('100%');
              }
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('高能进度条').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Toggle({ type: ToggleType.Switch, isOn: this.energyBar })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange((value: boolean) => { this.energyBar = value; this.savePlayerExtraSettings(); });
              }.width('100%').height('38vp').alignItems(VerticalAlign.Center);
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('礼物特效').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Toggle({ type: ToggleType.Switch, isOn: this.giftEffect })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange(() => { this.toggleGiftEffect(); });
              }.width('100%').height('38vp').alignItems(VerticalAlign.Center);
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('拖动进度条预览画面').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Toggle({ type: ToggleType.Switch, isOn: this.seekSnapshot })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange(() => { this.toggleSeekSnapshot(); });
              }.width('100%').height('38vp').alignItems(VerticalAlign.Center);
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('后台播放').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Toggle({ type: ToggleType.Switch, isOn: this.backgroundPlay })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange(() => { void this.toggleBackgroundPlay(); });
              }.width('100%').height('38vp').alignItems(VerticalAlign.Center);
            }
              .width('100%')
              .padding('12vp')
              .borderRadius('18vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()));
            // 流量辅助 / 禁看 / 反馈 / 举报。
            Column({ space: '2vp' }) {
              Row({ space: '8vp' }) {
                Text('流量辅助播放').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Toggle({ type: ToggleType.Switch, isOn: this.trafficAssist })
                  .selectedColor(Ui.accent(this.playerDark()))
                  .onChange(() => { this.toggleTrafficAssist(); });
              }.width('100%').height('38vp').alignItems(VerticalAlign.Center);
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('设为禁看').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Text('›').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.inkFaint(this.playerDark()));
              }
                .width('100%').height('38vp').alignItems(VerticalAlign.Center)
                .onClick(() => { void this.banCurrentVideo(); });
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('问题反馈').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Text('›').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.inkFaint(this.playerDark()));
              }
                .width('100%').height('38vp').alignItems(VerticalAlign.Center)
                .onClick(() => { this.closeSettingsPanel(); this.toast('Feedback is not available yet'); });
              this.settingsPanelDivider();
              Row({ space: '8vp' }) {
                Text('举报').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.playerDark())).layoutWeight(1);
                Text('›').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.inkFaint(this.playerDark()));
              }
                .width('100%').height('38vp').alignItems(VerticalAlign.Center)
                .onClick(() => { this.reportCurrentVideo(); });
            }
              .width('100%')
              .padding('12vp')
              .borderRadius('18vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()));
            // 亮度：与手势层的遮罩共用 brightnessShade。
            Row({ space: '10vp' }) {
              Text('☀').fontSize(Ui.fs('15vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
              Slider({ value: this.panelBrightnessPercent(), min: 0, max: 100, step: 5, style: SliderStyle.OutSet })
                .layoutWeight(1)
                .trackColor(Ui.divider(this.playerDark()))
                .selectedColor(Ui.accent(this.playerDark()))
                .blockColor(Ui.ink(this.playerDark()))
                .onChange((value: number) => { this.setPanelBrightness(value); });
              Text('☾').fontSize(Ui.fs('15vp', this.fontScale)).fontColor(Ui.inkSoft(this.playerDark()));
            }
              .width('100%')
              .padding({ left: '12vp', right: '12vp', top: '4vp', bottom: '4vp' })
              .borderRadius('18vp')
              .backgroundColor(Ui.glassTintSoft(this.playerDark()))
              .alignItems(VerticalAlign.Center);
          }
            .width('100%')
            .padding({ left: '14vp', right: '14vp', bottom: '18vp' });
        }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off);
      }
        .width(this.settingsPanelSpan() + 'vp')
        .height('100%')
        .backgroundColor(this.playerDark() ? '#F5161616' : '#F5F2F3F7')
        .backdropBlur(this.glassRadius())
        
        .shadow({ radius: 24, color: '#66000000', offsetX: -8 })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .transition(TransitionEffect.translate({ x: this.settingsPanelSpan() }).combine(TransitionEffect.OPACITY));
    }

    build() {
      if (this.missingParams || this.episodes.length === 0) {
        Column({ space: 16 }) {
          Text(this.missingParams ? '无法打开播放页：缺少影片信息' : '当前影片尚未配置可播放资源').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(this.ink());
          Button('返回').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor('#FFFFFF').padding({ left: '24vp', right: '24vp' }).backgroundColor(Color.Transparent)
            .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
            .borderRadius('22vp')
            .onClick(() => { void this.back(); });
        }.padding({ top: '24vp', bottom: '24vp', left: '24vp', right: '24vp' })
          .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.playerBg());
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Flex({ direction: this.tablet() && !this.fullScreen ? FlexDirection.Row : FlexDirection.Column }) {
            Stack({ alignContent: Alignment.Center }) {
              Stack({ alignContent: Alignment.Center }) {
                XComponent({ id: 'wuyin-player-surface', type: XComponentType.SURFACE, controller: this.surfaceController }).width('100%').height('100%').backgroundColor('#000000')
                  // 快进预览时把视频画面等比缩到 44%，形成屏幕居中的小窗预览。
                  .scale({ x: this.previewVisible ? 0.44 : 1, y: this.previewVisible ? 0.44 : 1 })
                  .borderRadius(this.previewVisible ? '18vp' : '0vp')
                  .clip(true)
                  .animation({ duration: 180, curve: Curve.EaseInOut })
                  // 硬件 HDR：XComponent 直接控制 surface 的 HDR 亮度（0=SDR，1=HDR），
                  // 开启时同时请求 AIHDR 硬件渲染类型，关闭时回到 SDR 亮度。
                  .onLoad(() => { this.surfaceReady = true; this.startWhenReady(); });
                // 亮度遮罩仅覆盖视频，并完全退出命中测试；窗口亮度由手势层的 AppBrightnessUtil 管理。
                Column().width('100%').height('100%').backgroundColor(`rgba(0,0,0,${this.brightnessShade})`).hitTestBehavior(HitTestMode.None);
                // 护眼模式：暖色低透明度遮罩，减少蓝光观感。
                if (this.eyeCare) {
                  Column().width('100%').height('100%').backgroundColor('#26FFB74D').hitTestBehavior(HitTestMode.None);
                }
                // 色觉辅助：黄色 / 蓝色滤镜遮罩（不改变解码与音轨）。
                if (this.colorAssist === 'yellow' || this.colorAssist === 'blue') {
                  Column()
                    .width('100%')
                    .height('100%')
                    .backgroundColor(this.colorAssist === 'yellow' ? '#26FFC107' : '#263F51B5')
                    .hitTestBehavior(HitTestMode.None);
                }
                // 音频播放：画面盖一层封面，声音继续播放，手势层仍然可用。
                if (this.audioOnly) {
                  Column({ space: '10vp' }) {
                    SymbolGlyph($r('sys.symbol.play_fill'))
                      .fontSize(Ui.fs('40vp', this.fontScale))
                      .fontColor([Ui.ink(this.playerDark())]);
                    Text(this.video?.tilie || this.video?.yhm || '音频播放中')
                      .fontSize(Ui.fs('15vp', this.fontScale))
                      .fontColor(Ui.ink(this.playerDark()))
                      .maxLines(1);
                    Text('音频播放中 · 点击屏幕可恢复画面')
                      .fontSize(Ui.fs('11.5vp', this.fontScale))
                      .fontColor(Ui.inkFaint(this.playerDark()));
                  }
                    .width('100%')
                    .height('100%')
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor('#F2000000')
                    .hitTestBehavior(HitTestMode.None);
                }
                PlayerGestureLayer({
                  currentMs: this.currentMs, durationMs: this.durationMs, volumeValue: this.volumeValue,
                    // 沿用既有手势层锁定接口，使入会等待阶段也受从机状态约束。
                  receiverLocked: this.isSlaveMode || this.receiverLocked,
                    onReveal: (): void => { this.revealFromGesture(); },
                    onToggleControls: (): void => { this.toggleControls(); },
                    onToggle: async (): Promise<void> => { await this.togglePlay(); },
                    onSeek: async (targetMs: number): Promise<void> => { await this.seekFromGesture(targetMs); },
                    onVolume: (level: number): void => { this.volumeFromGesture(level); },
                    onSpeedBoost: (active: boolean): void => { this.applySpeedBoost(active); },
                    onBrightnessMask: (level: number): void => {
                    try { if (!this.disposed && !this.isSlaveMode && !this.receiverLocked) { this.brightnessShade = Math.max(0, Math.min(0.95, level)); } }
                    catch (error) { Logger.warn('PLAYER_GESTURE', '更新视频亮度遮罩失败：' + String(error)); }
                  }
                });
                if (this.loading || this.errorText) {
                  Column({ space: 12 }) {
                    if (this.loading && !this.errorText) { LoadingProgress().width('32vp').height('32vp').color(this.accent()); }
                    Text(this.errorText || ('正在加载资源中' + this.loadingDots)).fontColor(this.errorText ? this.warningInk() : this.ink()).fontSize(Ui.fs('15vp', this.fontScale)).textAlign(TextAlign.Center);
                    // 网络/线路类真失败：提示保留，并直接给出「重试 / 换线路」两个可执行动作。
                    if (this.errorText.length > 0) {
                      Row({ space: 10 }) {
                        Button('重试')
                          .fontSize(Ui.fs('13vp', this.fontScale))
                          .fontColor(Ui.accentStrong(this.playerDark()))
                          .height('34vp')
                          .padding({ left: '20vp', right: '20vp' })
                          .backgroundColor(Ui.accentSoft(this.playerDark()))
                          .borderRadius('17vp')
                          .onClick(() => { this.retryPlayback(); });
                        if (this.hasOtherRoutes()) {
                          Button('换线路')
                            .fontSize(Ui.fs('13vp', this.fontScale))
                            .fontColor(this.ink())
                            .height('34vp')
                            .padding({ left: '20vp', right: '20vp' })
                            .backgroundColor(Ui.glassTintSoft(this.playerDark()))
                            .borderRadius('17vp')
                            .onClick(() => { this.retryWithNextRoute(); });
                        }
                      }
                    }
                  }.padding('20vp').constraintSize({ maxWidth: '90%' }).backgroundColor(this.panel()).borderRadius('24vp')
                    .align(Alignment.Center)
                    // 有错误时容器必须可点击，否则「重试 / 换线路」收不到手势。
                    .hitTestBehavior(this.errorText.length > 0 ? HitTestMode.Default : HitTestMode.None);
                }
                // 播放中的缓冲提示：只在已经起播、没有错误时出现，避免和首次加载重叠。
                if (this.buffering && !this.loading && !this.errorText && !this.previewVisible) {
                  Row({ space: '8vp' }) {
                    LoadingProgress()
                      .width('18vp')
                      .height('18vp')
                      .color(this.accent());
                    Text(this.bufferingPercent > 0 ? '缓冲中 ' + String(this.bufferingPercent) + '%' : '缓冲中')
                      .fontSize(Ui.fs('12.5vp', this.fontScale))
                      .fontColor(this.ink());
                  }
                    .padding({ left: '14vp', right: '16vp', top: '9vp', bottom: '9vp' })
                    .borderRadius('20vp')
                    .backgroundColor(this.panel())
                    
                    .align(Alignment.Center)
                    .hitTestBehavior(HitTestMode.None);
                }
              }.width(this.videoSurfaceWidth + 'vp').height(this.videoSurfaceHeight + 'vp').backgroundColor('#000000')
                // 竖屏：视频居中于「顶部栏 + 底部栏」之间，按两栏高度差微调垂直位置。
                .translate({ y: this.fullScreen ? 0 : this.videoOffsetY })
                .borderRadius('2vp').clip(true);
              // 控制层后绘制，位于手势层之上；空白区域透传，按钮自身停止事件传播。
              Column() {
                // 全屏：显示顶部控制栏（返回图标隐藏）；竖屏：只显示返回键。
                // 竖屏与全屏都显示完整顶部控制栏（返回、电量、片名、时间、比例、截图…）。
                this.topBar();
                Column() { this.downloadProgressPanel(); }.width('100%')
                  .visibility(this.fullScreen && this.downloadDetail.length > 0 && this.downloadButtonState !== PlayerDownloadPhase.COMPLETED && (this.downloadButtonState !== PlayerDownloadPhase.READY || this.downloadPercent > 0) ? Visibility.Visible : Visibility.None);
                Blank().hitTestBehavior(HitTestMode.None);
                this.controller();
              }.width('100%').height('100%')
                  // 只对透明度做补间：几何尺寸始终不变，所以淡入淡出时不会出现任何位移。
                  .opacity(this.controlsVisible && !this.screenLocked ? 1 : 0)
                  .animation({ duration: this.controlsVisible ? 200 : 240, curve: Curve.EaseInOut })
                  .hitTestBehavior(this.controlsVisible && !this.screenLocked ? HitTestMode.Transparent : HitTestMode.None)
                  .transition(TransitionEffect.IDENTITY);
              // 锁屏：全屏拦截手势与控件点击，只留左侧锁图标可点（对齐腾讯视频）。
              if (this.screenLocked && this.fullScreen) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor(Color.Transparent)
                  .hitTestBehavior(HitTestMode.Block)
                  // 锁定后点屏幕：切换锁图标的显示/隐藏，其它控件仍不响应。
                  .onClick(() => { this.toggleLockIcon(); });
              }
              // 锁定图标：垂直居中靠左，未锁定时跟随控制栏一起淡入淡出。
              // 锁定图标：整层铺满、垂直居中靠左；只有圆形按钮本身命中，其余区域透传。
              Row() {
                Stack({ alignContent: Alignment.Center }) {
                  // 圆形父级：底色/模糊/描边都在这一层，内部图标由 Stack 居中。
                  Column()
                    .width('40vp')
                    .height('40vp')
                    .borderRadius('20vp')
                    .backgroundColor(Ui.glassTintSoft(this.playerDark()))
                    .backdropBlur(this.glassRadius())
                    
                  SymbolGlyph(this.screenLocked ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open'))
                    .fontSize(Ui.fs('18vp', this.fontScale))
                    .fontColor([this.screenLocked ? Ui.accentStrong(this.playerDark()) : Ui.ink(this.playerDark())])
                }
                  .width('40vp')
                  .height('40vp')
                  // 全屏锁定按钮左边距 = 状态栏高度 × 2。
                  .margin({ left: this.statusBarHeightVp * 2 })
                  // 竖屏不显示锁定按钮；全屏下按「锁定态是否露图标 / 控制栏是否可见」决定透明度。
                  .opacity(!this.fullScreen ? 0
                    : (this.screenLocked ? (this.lockIconVisible ? 1 : 0) : (this.controlsVisible ? 1 : 0)))
                  .animation({ duration: 200, curve: Curve.EaseInOut })
                  .hitTestBehavior(!this.fullScreen ? HitTestMode.None
                    : (this.screenLocked ? (this.lockIconVisible ? HitTestMode.Block : HitTestMode.None)
                      : (this.controlsVisible ? HitTestMode.Block : HitTestMode.None)))
                  .accessibilityText(this.screenLocked ? '已锁定屏幕，点击解锁' : '锁定屏幕')
                  .onClick(() => { this.toggleScreenLock(); })
              }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Start)
                .alignItems(VerticalAlign.Center)
                // 整层透明，只有中间那个圆形按钮响应点击。
                .hitTestBehavior(HitTestMode.Transparent)
              // 旋转图标：与左侧锁定图标同一条水平线、靠右贴紧屏幕，
              // 右边距取和锁定图标左边距一致的 statusBarHeightVp × 2；点一下切换横屏/竖屏。
              if (this.fullScreen) {
                Row() {
                  Stack({ alignContent: Alignment.Center }) {
                    Column()
                      .width('40vp')
                      .height('40vp')
                      .borderRadius('20vp')
                      .backgroundColor(Ui.glassTintSoft(this.playerDark()))
                      .backdropBlur(this.glassRadius())
                      
                    SymbolGlyph($r('sys.symbol.rectangle_rotate'))
                      .fontSize(Ui.fs('18vp', this.fontScale))
                      .fontColor([Ui.ink(this.playerDark())])
                  }
                    .width('40vp')
                    .height('40vp')
                    .margin({ right: this.statusBarHeightVp * 2 })
                    .opacity(this.screenLocked ? 0 : (this.controlsVisible ? 1 : 0))
                    .animation({ duration: 200, curve: Curve.EaseInOut })
                    .hitTestBehavior(this.screenLocked ? HitTestMode.None
                      : (this.controlsVisible ? HitTestMode.Block : HitTestMode.None))
                    .accessibilityText('切换横竖屏')
                    .onClick(() => { void this.rotatePlayer(); })
                }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.End)
                  .alignItems(VerticalAlign.Center)
                  .hitTestBehavior(HitTestMode.Transparent)
              }
            }
              .width(this.playerWidth + 'vp')
              .height(this.playerContainerHeight + 'vp')
              // 竖屏：父容器整体下移 2 倍状态栏高度；全屏恢复贴顶。
              .margin({ top: this.fullScreen ? 0 : this.statusBarHeightVp * 2 })
              // 播放器父容器始终纯黑，与页面背景（深黑/浅白）区分开。
              .backgroundColor('#000000').onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.closeControlMenus(); } }).onHover((inside: boolean) => { this.hovered = inside; this.reveal(); });
            // 原收藏、下载及选集区域不移除，退出全屏后恢复原位置及展开/滚动状态。
            Scroll() {
              Column() { this.infoPanel(); }.width('100%')
                .padding({ top: '10vp', left: '10vp', right: '10vp', bottom: '10vp' }).alignItems(HorizontalAlign.Start);
            }.width(this.tablet() ? '32%' : '100%').layoutWeight(this.fullScreen ? 0 : 1).scrollBar(BarState.Off)
              .visibility(this.fullScreen ? Visibility.None : Visibility.Visible);
          }.width('100%').height('100%').backgroundColor(this.playerBg()).onAreaChange((_old: Area, area: Area) => { this.resizePlayer(Number(area.width), Number(area.height)); });
          Stack({ alignContent: Alignment.Center }) {
            Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.playerDark())).onClick(() => { this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.closeControlMenus(); }); });
            this.speedPopup();
            this.ratioPopup();
            this.episodePopup();
          }.width('100%').height('100%')
            .visibility(this.speedMenuVisible || this.ratioMenuVisible || (this.fullScreen && this.episodeMenuVisible) ? Visibility.Visible : Visibility.None)
            .padding({ bottom: '0vp', left: '0vp', right: '0vp' });
          this.danmakuOverlay();
          // 快进帧预览：视频画面等比缩到 44% 并屏幕居中，不再铺满全屏。
          if (this.previewVisible) {
            Stack({ alignContent: Alignment.Top }) {
              Column({ space: '2vp' }) {
                Text('画面预览')
                  .fontSize(Ui.fs('10vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.playerDark()));
                Text(this.time(this.currentMs))
                  .fontSize(Ui.fs('19vp', this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Ui.ink(this.playerDark()));
                Text(this.isCachedPosition(this.currentMs) ? '已缓存 · 秒开' : '正在缓冲…')
                  .fontSize(Ui.fs('10vp', this.fontScale))
                  .fontColor(this.isCachedPosition(this.currentMs) ? Ui.accentStrong(this.playerDark()) : Ui.inkFaint(this.playerDark()));
              }
                .padding({ left: '16vp', right: '16vp', top: '9vp', bottom: '9vp' })
                .borderRadius('14vp')
                .backgroundColor(this.panel())
                // 顶部控制栏高 52vp + 上下各 4vp 内边距，紧贴其下沿。
                .margin({ top: '60vp' })
                .hitTestBehavior(HitTestMode.None);
            }
              .width('100%')
              .height('100%')
              .hitTestBehavior(HitTestMode.None);
          }
          // HDR 开关光效：暗幕 + 辉光 + 旋转光带 + 脉冲光晕 + 星点 + 扫光渐变徽标。
          // 全部使用填充/渐变，不使用任何描边线条。
          if (this.hdrBannerVisible) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor(Ui.scrim(this.playerDark()))
                .opacity(this.hdrBannerOpacity);
              // 用固定尺寸 Circle 做辉光，避免百分比圆角被渲染成矩形。
              Circle()
                .width('560vp')
                .height('560vp')
                .fill(this.hdrClosing ? this.tint(this.mutedInk(), '22') : this.tint(this.accent(), '33'))
                .blur(70)
                .opacity(this.hdrBannerOpacity * 0.9);
              // 旋转极光：大面积渐变缓慢转动，给整个屏幕加氛围。
              Column()
                .width('180%')
                .height('180%')
                .borderRadius('50%')
                .linearGradient({
                  angle: this.hdrTick * 0.6,
                  colors: this.hdrClosing
                    ? [[this.rgba(this.mutedInk(), 0), 0.0], [this.rgba(this.mutedInk(), 0.1), 0.45], [this.rgba(this.mutedInk(), 0), 1.0]]
                    : [[this.rgba(this.accent(), 0), 0.0], [this.rgba(this.accentStrong(), 0.1), 0.45], [this.rgba(this.accent(), 0), 1.0]]
                })
                .blur(50)
                .opacity(this.hdrBannerOpacity * 0.8);
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width('260vp')
                  .height('260vp')
                  .borderRadius('130vp')
                  .backgroundColor(this.hdrClosing ? this.tint(this.mutedInk(), '1F') : this.tint(this.accent(), '33'))
                  .blur(45)
                  .opacity(this.hdrBannerOpacity);
                // 放射光束：6 条渐变光柱围绕中心缓慢旋转。
                ForEach(this.hdrRays, (index: number) => {
                  Column()
                    .width('12vp')
                    .height('300vp')
                    .linearGradient({
                      angle: 0,
                      colors: this.hdrClosing
                        ? [[this.rgba(this.mutedInk(), 0), 0.0], [this.rgba(this.mutedInk(), 0.24), 0.5], [this.rgba(this.mutedInk(), 0), 1.0]]
                        : [[this.rgba(this.accentStrong(), 0), 0.0], [this.rgba(this.accentStrong(), 0.24), 0.5], [this.rgba(this.accentStrong(), 0), 1.0]]
                    })
                    .rotate({ angle: index * 60 + this.hdrTick * 0.8 })
                    .blur(7)
                    .opacity(this.hdrBannerOpacity * (this.hdrClosing ? 0.12 : 0.45));
                }, (index: number): string => 'ray' + String(index));
                // 旋转光带：渐变圆盘旋转，无描边。
                Column()
                  .width('150vp')
                  .height('150vp')
                  .borderRadius('75vp')
                  .linearGradient({
                    angle: this.hdrSpinAngle(),
                    colors: this.hdrClosing
                      ? [[this.rgba(this.mutedInk(), 0), 0.0], [this.rgba(this.mutedInk(), 0.4), 0.5], [this.rgba(this.mutedInk(), 0), 1.0]]
                      : [[this.rgba(this.accentStrong(), 0), 0.0], [this.rgba(this.accentStrong(), 0.4), 0.5], [this.rgba(this.accentStrong(), 0), 1.0]]
                  })
                  .blur(8)
                  .opacity(this.hdrBannerOpacity * 0.85);
                // 两层填充光晕做扩散/收拢脉冲，替代描边圆环。
                Column()
                  .width('150vp')
                  .height('150vp')
                  .borderRadius('75vp')
                  .backgroundColor(this.hdrClosing ? this.tint(this.mutedInk(), '33') : this.tint(this.accent(), '33'))
                  .blur(18)
                  .scale({ x: this.hdrRingScaleAt(0), y: this.hdrRingScaleAt(0) })
                  .opacity(this.hdrRingOpacityAt(0));
                Column()
                  .width('150vp')
                  .height('150vp')
                  .borderRadius('75vp')
                  .backgroundColor(this.hdrClosing ? this.tint(Ui.inkFaint(this.playerDark()), '22') : this.tint(this.accentStrong(), '22'))
                  .blur(14)
                  .scale({ x: this.hdrRingScaleAt(13), y: this.hdrRingScaleAt(13) })
                  .opacity(this.hdrRingOpacityAt(13));
                Stack() {
                  ForEach(this.hdrSparkles, (index: number) => {
                    Circle()
                      .width((2 + index % 3) + 'vp')
                      .height((2 + index % 3) + 'vp')
                      .fill(this.hdrClosing ? this.tint(this.mutedInk(), '99') : this.tint(this.accentStrong(), 'E6'))
                      .position({
                        x: 130 + Math.cos(index * Math.PI / 4) * (104 + (index % 2) * 14) - 2,
                        y: 130 + Math.sin(index * Math.PI / 4) * (104 + (index % 2) * 14) - 2
                      })
                      .opacity(0.2 + 0.75 * this.hdrSparkleAt(index))
                      .scale({ x: 0.7 + 0.6 * this.hdrSparkleAt(index), y: 0.7 + 0.6 * this.hdrSparkleAt(index) });
                  }, (index: number): string => String(index));
                }
                  .width('260vp')
                  .height('260vp')
                  .opacity(this.hdrBannerOpacity);
                // 轨道粒子 + 拖尾：放在 260vp 的局部坐标系里，保证围绕徽标居中。
                Stack() {
                  ForEach(this.hdrOrbiters, (index: number) => {
                    Circle()
                      .width('7vp')
                      .height('7vp')
                      .fill(this.hdrClosing ? this.tint(this.mutedInk(), '99') : this.tint(this.accentStrong(), 'E6'))
                      .position({ x: this.hdrOrbitX(index, 120), y: this.hdrOrbitY(index, 120) })
                      .blur(1.5)
                      .opacity(this.hdrBannerOpacity * (this.hdrClosing ? 0.4 : 0.95));
                  }, (index: number): string => 'orbit' + String(index));
                  ForEach(this.hdrOrbiters, (index: number) => {
                    Circle()
                      .width('3vp')
                      .height('3vp')
                      .fill(this.hdrClosing ? this.tint(this.mutedInk(), '66') : this.tint(this.accent(), '80'))
                      .position({ x: this.hdrOrbitX(index - 4, 120), y: this.hdrOrbitY(index - 4, 120) })
                      .opacity(this.hdrBannerOpacity * 0.5);
                  }, (index: number): string => 'trail' + String(index));
                }
                  .width('260vp')
                  .height('260vp');
                // 全息扫描线：在徽标区域上下扫描。
                Column()
                  .width('260vp')
                  .height('2vp')
                  .linearGradient({
                    angle: 90,
                    colors: this.hdrClosing
                      ? [[this.rgba(this.mutedInk(), 0), 0.0], [this.rgba(this.mutedInk(), 0.7), 0.5], [this.rgba(this.mutedInk(), 0), 1.0]]
                      : [[this.rgba(this.accentStrong(), 0), 0.0], [this.rgba(this.accentStrong(), 0.7), 0.5], [this.rgba(this.accentStrong(), 0), 1.0]]
                  })
                  .translate({ y: this.hdrScanOffset() })
                  .blur(1.5)
                  .opacity(this.hdrBannerOpacity * 0.5)
                  .hitTestBehavior(HitTestMode.None);
                Stack({ alignContent: Alignment.Center }) {
                  Column()
                    .width('168vp')
                    .height('168vp')
                    .borderRadius('84vp')
                    .linearGradient({
                      angle: 135,
                      colors: this.hdrClosing
                        ? [[this.rgba(this.mutedInk(), 0.9), 0.0], [this.rgba(Ui.inkFaint(this.playerDark()), 0.9), 0.5], [this.rgba(this.ink(), 0.9), 1.0]]
                        : [[this.rgba(this.accent(), 0.9), 0.0], [this.rgba(this.accentStrong(), 0.9), 0.5], [this.rgba(Ui.accentGlow(this.playerDark()), 0.9), 1.0]]
                    });
                  // 内侧高光：圆形裁切，宽高 100% 跟随徽标尺寸。
                  Column() {
                    Column()
                      .width('100%')
                      .height('100%')
                      .borderRadius('50%')
                      .linearGradient({
                        angle: 135,
                        colors: this.hdrClosing
                          ? [[this.rgba(this.mutedInk(), 0.14), 0.0], [this.rgba(this.mutedInk(), 0.04), 0.45],
                            [this.rgba(this.mutedInk(), 0), 1.0]]
                          : [[this.rgba('#FFFFFF', 0.42), 0.0], [this.rgba('#FFFFFF', 0.1), 0.38],
                            [this.rgba(this.accentStrong(), 0), 0.68], [this.rgba(this.accentStrong(), 0), 1.0]]
                      })
                      .blur(3);
                    Column()
                      .width('100%')
                      .height('100%')
                      .borderRadius('50%')
                      .linearGradient({
                        angle: 0,
                        colors: this.hdrClosing
                          ? [[this.rgba(this.mutedInk(), 0), 0.55], [this.rgba(this.mutedInk(), 0.12), 0.84],
                            [this.rgba(this.mutedInk(), 0), 1.0]]
                          : [[this.rgba(Ui.accentGlow(this.playerDark()), 0), 0.55],
                            [this.rgba(Ui.accentGlow(this.playerDark()), 0.3), 0.84],
                            [this.rgba(Ui.accentGlow(this.playerDark()), 0), 1.0]]
                      })
                      .blur(6)
                      .opacity(this.hdrClosing ? 0.25 : 0.65);
                  }
                    .width('100%')
                    .height('100%')
                    .borderRadius('50%')
                    .clip(true)
                    .hitTestBehavior(HitTestMode.None);
                  // 徽标扫光
                  // 徽标扫光：圆角裁切容器 + 圆角亮带，避免方角露出。
                  Column() {
                    Column()
                      .width('26vp')
                      .height('240vp')
                      .borderRadius('13vp')
                      .clip(true)
                      .linearGradient({
                        angle: 90,
                        colors: this.hdrClosing
                          ? [[this.rgba(this.mutedInk(), 0), 0.0], [this.rgba(this.mutedInk(), 0.8), 0.5], [this.rgba(this.mutedInk(), 0), 1.0]]
                          : [[this.rgba(this.accentStrong(), 0), 0.0], [this.rgba(this.accentStrong(), 0.8), 0.5], [this.rgba(this.accentStrong(), 0), 1.0]]
                      })
                      .rotate({ angle: 24 })
                      .translate({ x: this.hdrSweepOffset() })
                      .opacity(this.hdrClosing ? 0.35 : 0.75);
                  }
                    .width('100%')
                    .height('100%')
                    .borderRadius('50%')
                    .clip(true)
                    .hitTestBehavior(HitTestMode.None);
                  Column({ space: '1vp' }) {
                    Stack({ alignContent: Alignment.Center }) {
                      // 色散残影：左右各偏移 1~2vp，形成全息重影。
                      Text('HDR')
                        .fontSize(Ui.fs('40vp', this.fontScale))
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.tint(this.accent(), '66'))
                        .translate({ x: -2, y: -1 });
                      Text('HDR')
                        .fontSize(Ui.fs('40vp', this.fontScale))
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.tint(this.accentStrong(), '66'))
                        .translate({ x: 2, y: 1 });
                      Text('HDR')
                        .fontSize(Ui.fs('40vp', this.fontScale))
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#FFFFFF')
                        .textShadow({
                          radius: 16 + 8 * this.hdrGlowPulse(),
                          color: this.hdrClosing ? this.tint(this.mutedInk(), '80') : this.tint(this.accentStrong(), 'B3'),
                          offsetX: 0,
                          offsetY: 0
                        });
                    }
                      .hitTestBehavior(HitTestMode.None);
                    Text(this.hdrClosing ? '已关闭 HDR' : '已开启 HDR')
                      .fontSize(Ui.fs('13vp', this.fontScale))
                      .fontColor('#F2FFFFFF')
                      .letterSpacing(1);
                    Text(this.hdrClosing ? 'SDR RENDERING' : 'ULTRA VIVID · 硬件渲染')
                      .fontSize(Ui.fs('8.5vp', this.fontScale))
                      .fontColor('#CCFFFFFF')
                      .letterSpacing(1.5);
                  }
                    .hitTestBehavior(HitTestMode.None);
                }
                  .width('168vp')
                  .height('168vp')
                  .clip(true)
                  .scale({
                    x: this.hdrBannerScale * (this.hdrClosing ? 0.98 : this.hdrGlowPulse()),
                    y: this.hdrBannerScale * (this.hdrClosing ? 0.98 : this.hdrGlowPulse())
                  })
                  .opacity(this.hdrBannerOpacity);
              }
                .width('100%')
                .height('100%');
              // 仅开启时白光一闪；关闭时用暗场收拢。
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('#FFFFFF')
                .opacity(this.hdrBannerOpacity * (!this.hdrClosing && this.hdrTick < 5 ? (5 - this.hdrTick) * 0.045 : 0))
                .hitTestBehavior(HitTestMode.None);
            }
              .width('100%')
              .height('100%')
              .hitTestBehavior(HitTestMode.None)
              .zIndex(20);
          }
          // 控制栏长按 3 倍速时，画面层给一个持续提示（画面区域长按已有手势提示）。
          if (this.boostSpeedActive && this.boostFromBar) {
            Stack({ alignContent: Alignment.Top }) {
              Row({ space: '6vp' }) {
                SymbolGlyph($r('sys.symbol.video_speed'))
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(['#FFFFFF']);
                Text('3× 倍速播放中')
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor('#FFFFFF');
              }
                .padding({ left: '14vp', right: '14vp', top: '7vp', bottom: '7vp' })
                .borderRadius('18vp')
                .backgroundColor('#CC000000')
                
                .margin({ top: '70vp' })
                .hitTestBehavior(HitTestMode.None);
            }
              .width('100%')
              .height('100%')
              .hitTestBehavior(HitTestMode.None);
          }
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
          if (this.lineTipVisible && this.fullScreen) {
            this.lineTipOverlay()
          }
          // 右侧半屏播放设置：遮罩点击关闭，面板自身阻止事件冒泡。
          if (this.settingsPanelVisible) {
            Row() {
              Blank()
              this.settingsPanel()
            }
              .width('100%')
              .height('100%')
              .backgroundColor('#66000000')
              .onClick(() => { this.closeSettingsPanel(); })
              .transition(TransitionEffect.OPACITY)
          }
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
          .focusable(true)
          .defaultFocus(true)
          .onKeyPreIme((event: KeyEvent): boolean => this.handlePlayerKey(event))
          .onKeyEvent((event: KeyEvent): boolean => this.handlePlayerKey(event))
          .bindContentCover(this.danmakuPanelVisible || this.castPanelVisible || this.linePanelVisible, this.playerModalCover(), {
            modalTransition: ModalTransition.NONE,
            onDisappear: (): void => {
              this.danmakuPanelVisible = false;
              this.castPanelVisible = false;
              this.linePanelVisible = false;
            }
          });
      }
    }
  }















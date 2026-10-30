import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import { AppState, Film, PlayerImmersiveConfig } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { NavTabs } from '../common/NavTabs';
import { NavigationScroll } from '../common/NavigationScroll';
import { SocialStore } from '../common/SocialStore';
import { ThemeService } from '../common/ThemeService';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, GlassIconButton, GlassSearchBar, LiquidNav, SectionHeader,
  SegmentedGlassTabs } from '../common/UiWidgets';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { FilmTile } from './Shared';
import { SearchPage } from './SearchPage';
import { CategoryPage } from './CategoryPage';
import { SettingPage } from './SettingPage';
import { ManagePage } from './ManagePage';
import { MyPage } from './MyPage';
import { MessageCenterPage } from './MessageCenterPage';
import { ForumPage } from './ForumPage';
import { LiveTvPage } from './LiveTvPage';
import { HistoryStrip } from '../components/HistoryStrip';
import { schemeHost, schemeValue } from '../common/ArkCard';

// 暴风首页接口条目：保留轮播和综艺所需的原始字段。
interface HomeSource {
  name?: string;
  aword?: string;
  still?: string;
  banner?: string;
  focus?: string;
  poster?: string;
  gifstill?: string;
  mid?: string | number;
  update?: string;
  score?: string | number;
  actor?: string;
  // 轮播元信息为可选字段；接口未提供时展示明确的缺省文案，不编造数据。
  rank?: string | number;
  year?: string | number;
  episodes?: string | number;
  genre?: string;
  type?: string;
  tags?: string | string[];
}

// 首区块为 focus 轮播，第二个区块为猜你喜欢。
interface HomeBlock {
  template?: string;
  contents?: HomeSource[];
}
interface HomeResponse {
  blocks?: HomeBlock[];
}

// 轮播实体保留接口原始图片、资源 ID 及影片信息。
interface Banner {
  itemIndex: number;
  title: string;
  introduction: string;
  stillImage: string;
  bannerImage: string;
  focusImage: string;
  posterImage: string;
  displayImage: string;
  mid: string;
  updateText: string;
  scoreText: string;
  actorText: string;
  rankText: string;
  yearText: string;
  episodeText: string;
  genreTags: string[];
}

// 所有绝对布局尺寸都是 vp；比例布局仍使用百分比，不引入像素布局。
interface BannerFrame {
  sceneTall: number;
  coverWide: number;
  coverTall: number;
  contentInset: number;
  contentGap: number;
  largeScene: boolean;
}
interface BannerPresentation {
  headline: string;
  summary: string;
  starLabel: string;
  scoreLabel: string;
  rankLabel: string;
  yearLabel: string;
  episodeLabel: string;
  genreTags: string[];
  coverImage: string;
}

// 猜你喜欢综艺实体，最多读取第二个区块的前八条。
interface VarietyItem {
  itemIndex: number;
  title: string;
  introduction: string;
  mid: string;
  stillImage: string;
  bannerImage: string;
  focusImage: string;
  posterImage: string;
  gifStillImage: string;
  updateText: string;
  scoreText: string;
  displayImage: string;
}

/**
 * 首页宿主管：首页内容 + 搜索/分类/管理/设置/我的等业务页 + 液态玻璃底栏。
 * 本轮重做视觉层（页头、搜索、题材分组、轮播、快捷入口、综艺、精选网格、底栏），
 * 数据请求、缓存、定时器、滚动显隐、路由与业务状态保持原有行为不变。
 */
@Component
export struct HomePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('page') @Watch('onPageChanged') page: string = 'home';
  // 我的页面点击收藏/下载时，把目标子页索引传给管理页，避免跳到未注册的独立路由。
  @StorageLink('manageInitialTab') private manageInitialTab: number = 0;
  // AppState 的 Preferences 整体归档负责重启持久化，StorageLink 负责页面实时同步。
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('onImmersiveChanged') darkTheme: boolean = true;
  // 安全区由窗口服务统一发布为 vp，页面不再单独查询或缓存过期的手势条尺寸。
  @StorageLink('immersiveStatusBarInset') @Watch('onTopInsetChanged') private statusBarInset: number = 24;
  @StorageLink('immersiveTopInset') @Watch('onTopInsetChanged') private topSafeInset: number = 24;
  @StorageLink('immersiveBottomInset') @Watch('onBottomInsetChanged') private bottomSafeInset: number = 16;
  @StorageLink('immersiveLeftInset') private leftSafeInset: number = 0;
  @StorageLink('immersiveRightInset') private rightSafeInset: number = 0;
  // 设置页「界面尺寸 · Dock 栏大小」：变化时重新计算内嵌业务页的底栏避让高度。
  @StorageLink('dockScale') @Watch('onDockScaleChanged') private dockScale: number = 1;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 780;
  @State selected: string = '首页';
  @State query: string = '';
  @State pressed: string = '';
  @State bannerItems: Banner[] = [];
  @State private failedBannerCovers: number[] = [];
  @State varietyItems: VarietyItem[] = [];
  @State failedVarietyImages: number[] = [];
  @State currentBannerIndex: number = 0;
  @State bannerLoading: boolean = false;
  @State varietyLoading: boolean = false;
  @State bannerLoadingAlpha: number = 0;
  @State varietyLoadingAlpha: number = 0;
  @State bannerMessage: string = '';
  @State varietyMessage: string = '';
  @State bannerPressed: boolean = false;
  @State varietyPressed: string = '';
  private readonly homeScroller: Scroller = new Scroller();
  // 推荐 Grid 与外层 Scroll 分别上报实际滚动位置，避免在影片区滚动时遗漏显隐事件。
  private readonly homeGridScroller: Scroller = new Scroller();
  // 已移除顶部导航「找片」标签及其绑定；剩余五项按原有分类顺序显示。
  private labels: string[] = ['首页', '电影', '电视剧', '动漫', '综艺'];
  private shortcuts: string[] = ['我要功能', '我要反馈', '精选壁纸', '全网站', '电影'];
  private icons: string[] = ['＋', '✉', '▧', '◎', '▶'];
  private readonly homeAddress: string = 'http://www.baofeng.com/po/v10/config/channelhome?nav_id=203&pg=1&cp=fr4k0se&cl=newweb_baofeng';
  private bannerTimer: number = -1;
  private bannerFadeTimer: number = -1;
  private varietyFadeTimer: number = -1;
  private imageWaitTimer: number = -1;
  private requestVersion: number = 0;
  private pageAlive: boolean = false;
  private sliding: boolean = false;
  private firstBannerImagePending: boolean = false;

  /** 处理 wuyinvideo:// 深链（Android intent-filter / iOS URL Types 进入）。 */
  private consumeDeepLink(): void {
    try {
      const uri: string = AppStorage.get<string>('deepLinkUri') || '';
      if (uri.length === 0) { return; }
      AppStorage.delete('deepLinkUri');
      const host: string = schemeHost(uri);
      Logger.info('HOME', '处理深链：host=' + host + '，uri=' + uri);
      if (host === 'play') {
        const vodId: string = schemeValue(uri, 'vodId');
        const episode: string = schemeValue(uri, 'episodeIndex');
        const wzlj: string = schemeValue(uri, 'wzlj');
        const title: string = schemeValue(uri, 'title');
        const cover: string = schemeValue(uri, 'cover');
        if (wzlj.length === 0) {
          Logger.warn('HOME', '深链 play 缺少 wzlj，只能打开播放器空壳：' + uri);
          this.toast('该分享缺少播放地址（wzlj），请从 App 内分享');
        }
        const params: Record<string, string> = {
          'vodId': vodId, 'episodeIndex': episode, 'wzlj': wzlj, 'tilie': title, 'yhm': title, 'feng': cover
        };
        void router.pushUrl({ url: 'pages/PlayerPage', params: params });
        return;
      }
      if (host === 'post') {
        const postId: string = schemeValue(uri, 'postId');
        const params: Record<string, string> = { 'postId': postId };
        void router.pushUrl({ url: 'pages/ForumDetailPage', params: params });
        return;
      }
      if (host === 'live') {
        const liveId: string = schemeValue(uri, 'liveId');
        Logger.info('HOME', '深链直播：' + liveId);
        AppState.go('live');
        return;
      }
      if (host === 'joinSession') {
        const sessionId: string = schemeValue(uri, 'sessionId');
        const vodId: string = schemeValue(uri, 'vodId');
        const episode: string = schemeValue(uri, 'episodeIndex');
        const params: Record<string, string> = {
          'sessionId': sessionId, 'vodId': vodId, 'episodeIndex': episode, 'coPlayEntry': 'deeplink'
        };
        void router.pushUrl({ url: 'pages/PlayerPage', params: params });
        return;
      }
      if (host === 'audio') {
        AppState.go('message');
        return;
      }
      if (host === 'download' || host === 'notice') {
        AppState.go('message');
      }
    } catch (error) {
      Logger.warn('HOME', '处理深链失败：' + String(error));
    }
  }

  aboutToAppear(): void {
    this.consumeDeepLink();
    this.pageAlive = true;
    try {
      NavigationScroll.reset(this.page, '进入导航宿主');
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context) {
        // 底部导航顺序与 AppState 的偏好共用同一个 wuyin 存储，但两者互不覆盖。
        void NavTabs.init(context);
        void SocialStore.init(context);
        void ThemeService.init(context);
        void AppState.init(context).catch((error: Error) => {
          Logger.error('HomeImmersive', '初始化共享配置失败：' + String(error));
        });
      }
      void ImmersiveService.apply(true);
      ImmersiveService.publishSafeArea();
      this.onTopInsetChanged();
      this.publishNavClearance();
    } catch (error) {
      Logger.error('HomeImmersive', '恢复全局沉浸失败：' + String(error));
    }
    void this.loadHomeContent();
  }
  aboutToDisappear(): void {
    this.pageAlive = false;
    this.requestVersion++;
    this.firstBannerImagePending = false;
    this.sliding = false;
    this.stopBannerTimer();
    this.clearFadeTimers();
    // 页面离开不撤销窗口沉浸，避免下一页系统导航区短暂恢复实色。
  }
  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('HomeImmersive', '同步全局主题及材质失败：' + String(error));
    }
  }
  private onTopInsetChanged(): void {
    try {
      const measuredStatus: number = Number.isFinite(this.statusBarInset) ? Math.max(0, this.statusBarInset) : 24;
      Logger.info('HomeBanner', '系统状态栏高度=' + measuredStatus + 'vp，首页顶部安全内边距=' + this.safeTop() + 'vp');
    } catch (error) {
      Logger.error('HomeBanner', '同步状态栏高度失败：' + String(error));
    }
  }
  private onBottomInsetChanged(): void {
    // 手势条高度变化时同步刷新内嵌业务页的底栏占位高度。
    this.publishNavClearance();
  }
  private onDockScaleChanged(): void {
    try {
      this.publishNavClearance();
      Logger.info('HomeImmersive', 'Dock 栏尺寸已更新，缩放=' + String(this.dockScale));
    } catch (error) {
      Logger.error('HomeImmersive', '更新 Dock 栏尺寸失败：' + String(error));
    }
  }
  private safeTop(): number {
    try {
      const statusInset: number = Number.isFinite(this.statusBarInset) ? Math.max(0, this.statusBarInset) : 24;
      const cutoutInset: number = Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
      // 同一区域只取最大值，状态栏与挖孔不重复叠加。
      return Math.max(statusInset, cutoutInset);
    } catch (error) {
      Logger.error('HomeBanner', '计算首页顶部安全内边距失败，使用 24vp：' + String(error));
      return 24;
    }
  }
  private onPageChanged(): void {
    try {
      NavigationScroll.reset(this.page, '切换页面');
      void ImmersiveService.apply(true);
      if (this.fullScreenBusinessPage()) {
        Logger.info('HomeImmersive', '搜索/分类/管理/设置页面全屏显示，宿主不预留底部导航或系统安全区');
      }
      if (this.page === 'home') { this.startBannerTimer(); }
      else { this.stopBannerTimer(); }
    } catch (error) {
      Logger.error('HomeImmersive', '切换页面时同步沉浸失败：' + String(error));
    }
  }
  private fullScreenBusinessPage(): boolean {
    // 消息/论坛/直播/搜索/分类/管理/设置/我的：页面与列表占满窗口，悬浮导航只叠加显示，
    // 不压缩内容区域，也不为底部安全区额外留白（内容可以一直铺到屏幕底部）。
    return this.page === 'search' || this.page === 'category' || this.page === 'manage' ||
      this.page === 'settings' || this.page === 'mine' || this.page === 'profile' ||
      this.page === 'message' || this.page === 'forum' || this.page === 'live';
  }
  private safeBottom(): number {
    return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16;
  }
  private contentWidth(): number {
    return Math.max(0, this.viewportWidth - Math.max(0, this.leftSafeInset) - Math.max(0, this.rightSafeInset));
  }
  /** 去掉左右留白、并在宽屏上居中限宽后的可用内容宽度。 */
  private contentW(): number {
    const raw: number = this.contentWidth();
    const gutter: number = Ui.gutter(raw);
    return Math.max(260, Math.min(raw - gutter * 2, 1180));
  }
  private gutter(): number { return Ui.gutter(this.contentWidth()); }
  private tablet(): boolean { return Ui.isTablet(this.contentWidth()); }
  private landscape(): boolean { return this.viewportHeight > 0 && this.viewportWidth > this.viewportHeight * 1.15; }
  private navHeight(): number {
    return Ui.navBarHeight(this.contentWidth(), this.viewportHeight, this.dockScale);
  }
  private navStripHeight(): number {
    return Ui.navStripHeight(this.contentWidth(), this.viewportHeight, this.dockScale);
  }
  private navigationClearance(): number {
    // 渐进模糊带已移除，只保留底栏本体与手势条的避让高度。
    return Ui.navClearance(this.contentWidth(), this.viewportHeight, this.safeBottom(), this.dockScale);
  }
  // 内嵌业务页（搜索/分类/管理/设置/我的）共用同一份底栏占位高度，避免列表末尾被底栏遮住。
  private publishNavClearance(): void {
    try {
      const value: number = Ui.navClearance(this.contentWidth(), this.viewportHeight, this.safeBottom(), this.dockScale);
      const previous: number | undefined = AppStorage.get<number>('navClearance');
      if (previous === undefined || !Number.isFinite(previous) || Math.abs(previous - value) > 0.5) {
        AppStorage.setOrCreate<number>('navClearance', value);
      }
    } catch (error) {
      Logger.warn('HomeImmersive', '发布底栏占位高度失败：' + String(error));
    }
  }
  private beginHomeScroll(scrollSource: string, scroller: Scroller): void {
    if (!this.pageAlive || this.page !== 'home') { return; }
    try { NavigationScroll.begin('home', scrollSource, scroller); }
    catch (error) { Logger.error('HomeNavigationScroll', '开始滚动监听失败，来源=' + scrollSource + '：' + String(error)); }
  }
  private reportHomeScroll(scrollSource: string, scroller: Scroller, scrollState: ScrollState): void {
    if (!this.pageAlive || this.page !== 'home') { return; }
    try {
      // 共享服务读取 currentOffset，记录 vp 位置及导航状态；不将回调增量当作绝对位置。
      NavigationScroll.report('home', scrollSource, scroller, scrollState);
    } catch (error) {
      Logger.error('HomeNavigationScroll', '上报滚动位置失败，来源=' + scrollSource + '：' + String(error));
    }
  }
  private endHomeScroll(scrollSource: string, scroller: Scroller): void {
    if (!this.pageAlive || this.page !== 'home') { return; }
    try { NavigationScroll.end('home', scrollSource, scroller); }
    catch (error) { Logger.error('HomeNavigationScroll', '结束滚动监听失败，来源=' + scrollSource + '：' + String(error)); }
  }
  private stopBannerTimer(): void {
    if (this.bannerTimer !== -1) { clearTimeout(this.bannerTimer); this.bannerTimer = -1; }
  }
  private clearFadeTimers(): void {
    if (this.bannerFadeTimer !== -1) { clearTimeout(this.bannerFadeTimer); this.bannerFadeTimer = -1; }
    if (this.varietyFadeTimer !== -1) { clearTimeout(this.varietyFadeTimer); this.varietyFadeTimer = -1; }
    if (this.imageWaitTimer !== -1) { clearTimeout(this.imageWaitTimer); this.imageWaitTimer = -1; }
  }
  // 用单次五秒定时器控制索引；手指按住时停表，松开后重新计满五秒。
  private startBannerTimer(): void {
    this.stopBannerTimer();
    if (!this.pageAlive || this.sliding || this.page !== 'home' || this.firstBannerImagePending || this.bannerItems.length < 2) { return; }
    this.bannerTimer = setTimeout(() => {
      this.bannerTimer = -1;
      if (!this.pageAlive || this.sliding || this.page !== 'home' || this.bannerItems.length < 2) { return; }
      try {
        const lastIndex: number = this.bannerItems.length - 1;
        this.currentBannerIndex = this.currentBannerIndex >= lastIndex ? 0 : this.currentBannerIndex + 1;
      } catch (_) { Logger.error('HomeModule', '轮播索引切换失败'); }
      this.startBannerTimer();
    }, 5000);
  }
  // 依次读取 blocks[0].contents；focus 优先，其余图片依序回退。
  private parseBanners(block?: HomeBlock): Banner[] {
    const result: Banner[] = [];
    const contents: HomeSource[] = block?.contents ?? [];
    for (let index: number = 0; index < contents.length; index++) {
      try {
        const source: HomeSource = contents[index];
        const focusImage: string = source.focus ?? '';
        const bannerImage: string = source.banner ?? '';
        const stillImage: string = source.still ?? '';
        const posterImage: string = source.poster ?? '';
        const displayImage: string = focusImage || bannerImage || posterImage || stillImage;
        if (!displayImage) { continue; }
        const rawTags: string | string[] = source.tags ?? source.genre ?? source.type ?? '';
        const genreTags: string[] = typeof rawTags === 'string' ? rawTags.split(/[、,，/|·\s]+/) : rawTags.slice();
        result.push({ itemIndex: index, title: source.name ?? '', introduction: source.aword ?? '',
            stillImage: stillImage, bannerImage: bannerImage, focusImage: focusImage, posterImage: posterImage,
            displayImage: displayImage, mid: String(source.mid ?? ''), updateText: source.update ?? '',
            scoreText: String(source.score ?? ''), actorText: source.actor ?? '',
            rankText: String(source.rank ?? ''), yearText: String(source.year ?? ''),
            episodeText: String(source.episodes ?? ''), genreTags: genreTags });
      } catch (_) { Logger.error('HomeModule', '解析轮播条目 ' + index + ' 失败'); }
    }
    return result;
  }
  // 第二个区块最多取八条；每条统一渲染为单行滚动的固定尺寸卡片。
  private parseVarieties(block?: HomeBlock): VarietyItem[] {
    const result: VarietyItem[] = [];
    const contents: HomeSource[] = block?.contents ?? [];
    for (let index: number = 0; index < Math.min(8, contents.length); index++) {
      try {
        const source: HomeSource = contents[index];
        const stillImage: string = source.still ?? '';
        const posterImage: string = source.poster ?? '';
        const bannerImage: string = source.banner ?? '';
        const focusImage: string = source.focus ?? '';
        result.push({ itemIndex: index, title: source.name ?? '', introduction: source.aword ?? '',
            mid: String(source.mid ?? ''), stillImage: stillImage, bannerImage: bannerImage,
            focusImage: focusImage, posterImage: posterImage, gifStillImage: source.gifstill ?? '',
            updateText: source.update ?? '', scoreText: String(source.score ?? ''),
            displayImage: posterImage || stillImage || bannerImage || focusImage });
      } catch (_) { Logger.error('HomeRecommendFix', '解析综艺条目 ' + index + ' 失败'); }
    }
    return result;
  }
  // 应用私有沙盒使用应用自身文件权限，无需申请公共媒体库运行时权限。
  private cacheDirectory(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.filesDir + '/无音影视/轮播图';
  }
  // 索引加地址摘要：同索引图片更新后不会错误复用旧缓存。
  private imageCacheKey(address: string, kind: string, index: number): string {
    let hash: number = 2166136261;
    for (let position: number = 0; position < address.length; position++) {
      hash = Math.imul(hash ^ address.charCodeAt(position), 16777619);
    }
    return kind + '_' + index + '_' + (hash >>> 0).toString(16);
  }
  private async cachedImage(address: string, kind: string, index: number): Promise<string> {
    if (!address) { return ''; }
    let path: string = '';
    let request: http.HttpRequest | undefined;
    try {
      const directory: string = this.cacheDirectory();
      path = directory + '/' + this.imageCacheKey(address, kind, index) + '.jpg';
      try {
        if (fs.accessSync(path) && fs.statSync(path).size > 0) { return 'file://' + path; }
      } catch (_) { Logger.info('HomeModule', '图片缓存未命中 ' + kind + '_' + index); }
      try {
        if (!fs.accessSync(directory)) { fs.mkdirSync(directory, true); }
      } catch (_) {
        // accessSync 在目录不存在时可能抛错；递归创建仍在外层异常保护中。
        fs.mkdirSync(directory, true);
      }
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(address, {
        method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 15000,
          expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode !== 200) {
        if (kind === 'variety') { Logger.error('HomeRecommendFix', '海报请求 HTTP ' + response.responseCode + '，条目 ' + index); }
        throw new Error('图片请求状态异常');
      }
      const bytes: ArrayBuffer = response.result as ArrayBuffer;
      if (!bytes.byteLength) { throw new Error('空图片'); }
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, bytes); } finally { fs.closeSync(file); }
      return 'file://' + path;
    } catch (_) {
      // 图片链接可能带签名参数，不记录完整链接或异常对象。
      Logger.error(kind === 'variety' ? 'HomeRecommendFix' : 'HomeModule', '图片缓存失败或超时 ' + kind + '_' + index);
      return address;
    } finally {
      if (request) { request.destroy(); }
    }
  }
  // 图片在后台逐张缓存；网络请求完成即可先渲染，后续缓存不阻塞加载过渡。
  private async cacheRemainingImages(banners: Banner[], varieties: VarietyItem[], version: number): Promise<void> {
    for (let index: number = 1; index < banners.length; index++) {
      if (!this.pageAlive || version !== this.requestVersion) { return; }
      try {
        const localImage: string = await this.cachedImage(banners[index].displayImage, 'banner', banners[index].itemIndex);
        if (!this.pageAlive || version !== this.requestVersion) { return; }
        banners[index].displayImage = localImage;
        this.bannerItems = banners.slice();
      } catch (_) { Logger.error('HomeModule', '处理轮播图片失败 ' + index); }
    }
    for (let index: number = 0; index < varieties.length; index++) {
      if (!this.pageAlive || version !== this.requestVersion) { return; }
      try {
        const localImage: string = await this.cachedImage(varieties[index].displayImage, 'variety', varieties[index].itemIndex);
        if (!this.pageAlive || version !== this.requestVersion) { return; }
        varieties[index].displayImage = localImage;
        if (localImage.startsWith('file://')) {
          this.failedVarietyImages = this.failedVarietyImages.filter((failed: number) => failed !== varieties[index].itemIndex);
        }
        this.varietyItems = varieties.slice();
      } catch (_) { Logger.error('HomeRecommendFix', '处理综艺图片失败 ' + index); }
    }
  }
  // 统一请求一次接口，分别解析首区块轮播与第二个区块综艺。
  private async loadHomeContent(): Promise<void> {
    const version: number = ++this.requestVersion;
    this.stopBannerTimer();
    this.clearFadeTimers();
    this.firstBannerImagePending = false;
    this.sliding = false;
    this.currentBannerIndex = 0;
    this.bannerItems = [];
    this.failedBannerCovers = [];
    this.varietyItems = [];
    this.failedVarietyImages = [];
    this.bannerLoading = true;
    this.varietyLoading = true;
    this.bannerLoadingAlpha = 1;
    this.varietyLoadingAlpha = 1;
    this.bannerMessage = '';
    this.varietyMessage = '';
    let request: http.HttpRequest | undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(this.homeAddress, {
        method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 15000,
          expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200) {
        Logger.error('HomeModule', response.responseCode === 499 ? 'HTTP499 请求取消' :
          response.responseCode === 404 ? 'HTTP404 接口不存在' : '接口 HTTP ' + response.responseCode);
        Logger.error('HomeRecommendFix', response.responseCode === 499 ? 'HTTP499 推荐请求取消' :
          '推荐请求 HTTP ' + response.responseCode);
        Logger.error('HomeTabSwitch', '首页接口请求失败 HTTP ' + response.responseCode);
        throw new Error('HTTP 状态异常');
      }
      let payload: HomeResponse;
      try {
        payload = JSON.parse(String(response.result)) as HomeResponse;
      } catch (_) {
        Logger.error('HomeRecommendFix', '推荐数据 JSON 解析错误');
        Logger.error('HomeTabSwitch', '首页数据 JSON 解析错误');
        throw new Error('JSON 解析错误');
      }
      if (!Array.isArray(payload.blocks)) {
        Logger.error('HomeRecommendFix', '推荐数据 blocks 格式错误');
        Logger.error('HomeTabSwitch', '首页数据 blocks 格式错误');
        throw new Error('blocks 格式错误');
      }
      const blocks: HomeBlock[] = payload.blocks;
      if (blocks.length > 0 && blocks[0].template !== 'focus') { Logger.info('HomeModule', '首区块不是 focus 模板'); }
      const banners: Banner[] = this.parseBanners(blocks[0]);
      const varieties: VarietyItem[] = this.parseVarieties(blocks[1]);
      // 首图优先下载到沙盒；完成后再渲染，其他图片在后台缓存。
      if (banners.length > 0) {
        banners[0].displayImage = await this.cachedImage(banners[0].displayImage, 'banner', banners[0].itemIndex);
      }
      if (!this.pageAlive || version !== this.requestVersion) { return; }
      this.firstBannerImagePending = banners.length > 0;
      this.bannerItems = banners;
      this.varietyItems = varieties;
      this.currentBannerIndex = 0;
      this.bannerMessage = banners.length ? '' : '暂无轮播内容';
      this.varietyMessage = varieties.length ? '' : '暂无综艺内容';
      if (this.firstBannerImagePending) {
        // 图片加载事件无法触发时也要释放遮罩。
        this.imageWaitTimer = setTimeout(() => {
          this.imageWaitTimer = -1;
          if (this.pageAlive && version === this.requestVersion) {
            Logger.error('HomeModule', '首张轮播图片等待超时');
            this.firstBannerRendered();
          }
        }, 12000);
      }
      Logger.info('HomeModule', '首页数据加载完成');
      void this.cacheRemainingImages(banners, varieties, version);
    } catch (_) {
      Logger.error('HomeModule', '首页请求失败：可能为超时、网络异常或 JSON 解析错误');
      Logger.error('HomeRecommendFix', '推荐请求失败：可能为超时、网络异常或数据错误');
      Logger.error('HomeTabSwitch', '首页接口请求或解析失败');
      if (this.pageAlive && version === this.requestVersion) {
        this.bannerMessage = '轮播图加载失败，点击重试';
        this.varietyMessage = '综艺加载失败，点击重试';
      }
    } finally {
      if (request) { request.destroy(); }
      if (this.pageAlive && version === this.requestVersion && !this.firstBannerImagePending && this.bannerLoading) {
        this.dismissLoading(version);
      }
    }
  }
  // 首张图片完成解码或加载失败后，以 300ms 过渡退出加载状态。
  private firstBannerRendered(): void {
    if (!this.firstBannerImagePending || !this.pageAlive) { return; }
    this.firstBannerImagePending = false;
    if (this.imageWaitTimer !== -1) { clearTimeout(this.imageWaitTimer); this.imageWaitTimer = -1; }
    this.startBannerTimer();
    this.dismissLoading(this.requestVersion);
  }
  private dismissLoading(version: number): void {
    if (this.bannerFadeTimer !== -1) { clearTimeout(this.bannerFadeTimer); this.bannerFadeTimer = -1; }
    if (this.varietyFadeTimer !== -1) { clearTimeout(this.varietyFadeTimer); this.varietyFadeTimer = -1; }
    this.bannerFadeTimer = setTimeout(() => {
      this.bannerFadeTimer = -1;
      if (!this.pageAlive || version !== this.requestVersion) { return; }
      this.getUIContext().animateTo({ duration: 300 }, () => {
        this.bannerLoadingAlpha = 0;
        this.varietyLoadingAlpha = 0;
      });
      this.varietyFadeTimer = setTimeout(() => {
        this.varietyFadeTimer = -1;
        if (this.pageAlive && version === this.requestVersion) {
          this.bannerLoading = false;
          this.varietyLoading = false;
        }
      }, 300);
    }, 0);
  }
  // 保留原脚本“百变综艺”的后续扩展入口。
  private 百变综艺(): void {
  }
  // 点击轮播和综艺卡片时将 mid 带入播放器全局状态。
  private openResource(mid: string, title: string, description: string): void {
    try {
      if (!mid) { this.getUIContext().getPromptAction().showToast({ message: '该资源暂无影片 ID' }); return; }
      const film: Film = new Film(Number(mid) || 0, title, '综艺', description);
      AppStorage.setOrCreate('playerMid', mid);
      AppState.play(film);
      Logger.info('HomeModule', '打开资源 mid=' + mid);
    } catch (_) { Logger.error('HomeModule', '打开播放页面失败'); }
  }
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) { Logger.error('HomeModule', '提示信息显示失败：' + String(error)); }
  }
  private films(): Film[] {
    // 首页继续展示随机推荐；其余四个分类按影片类型筛选。
    return AppState.films.filter((film: Film) => this.selected === '首页' || film.genre === this.selected);
  }
  /** 用指定关键词打开搜索页（轮播/猜你喜欢/为你精选点卡片时调用）。 */
  private openSearchWith(keyword: string): void {
    const name: string = (keyword || '').trim();
    if (name.length === 0) { return; }
    this.query = name;
    this.search();
  }

  private search(): void { AppStorage.setOrCreate('searchQuery', this.query); AppState.go('search'); }
  private shortcut(label: string): void {
    if (label === '电影') { this.selected = '电影'; return; }
    this.toast(label + '服务尚未配置');
  }
  private tagIndex(): number {
    const found: number = this.labels.indexOf(this.selected);
    return found >= 0 ? found : 0;
  }
  private ink(): string { return Ui.ink(this.darkTheme); }
  private varietyCardWidth(): number { return this.tablet() ? 176 : 132; }
  private varietyPosterHeight(): number { return this.tablet() ? 264 : 196; }
  private filmTileHeight(): number { return this.tablet() ? 300 : 208; }
  private gridTemplate(): string {
    const count: number = Math.min(Ui.columns(this.contentWidth()), Math.max(1, this.films().length));
    const columns: number = this.landscape() && !this.tablet() ? Math.min(2, count) : count;
    let template: string = '';
    for (let index: number = 0; index < Math.max(1, columns); index++) {
      template = template + (index === 0 ? '1fr' : ' 1fr');
    }
    return template;
  }
  private gridRows(): number {
    const columns: number = this.gridTemplate().split(' ').length;
    return Math.max(1, Math.ceil(this.films().length / Math.max(1, columns)));
  }
  private heroHeight(): number {
    const availableWidth: number = this.contentW();
    if (this.landscape()) {
      return Math.round(Math.max(150, Math.min(this.viewportHeight * 0.5, this.tablet() ? 260 : 210)));
    }
    if (this.tablet()) { return Math.round(Math.min(420, Math.max(286, availableWidth * 0.44))); }
    return Math.round(Math.min(302, Math.max(236, availableWidth * 0.76)));
  }

  // ArkUI 声明式 Builder 不支持直接嵌套 try 语句。
  // 渲染所需尺寸、文案在普通方法内用 try-catch 准备；图片和交互回调独立捕获异常。
  private bannerFrame(): BannerFrame {
    try {
      const usableWide: number = this.contentW();
      const largeScene: boolean = this.tablet();
      const coverWide: number = largeScene ? 128 : 90;
      return {
        sceneTall: this.heroHeight(), coverWide: coverWide, coverTall: coverWide * 1.5,
          contentInset: largeScene ? 18 : 14, contentGap: largeScene ? 18 : 12, largeScene: largeScene
      };
    } catch (error) {
      Logger.error('HomeBanner', '计算轮播布局失败，使用 vp 默认布局：' + String(error));
      return { sceneTall: 260, coverWide: 90, coverTall: 135, contentInset: 14, contentGap: 12, largeScene: false };
    }
  }
  private bannerPresentation(item: Banner): BannerPresentation {
    try {
      const rawScore: number = Number.parseFloat(item.scoreText);
      const validScore: boolean = Number.isFinite(rawScore) && rawScore >= 0 && rawScore <= 10;
      const filledStars: number = validScore ? Math.max(0, Math.min(5, Math.round(rawScore / 2))) : 0;
      const rawRank: string = item.rankText.trim();
      const rawYear: string = item.yearText.trim();
      const rawEpisodes: string = item.episodeText.trim();
      const cleanTags: string[] = item.genreTags.map((tag: string) => tag.trim())
        .filter((tag: string) => tag.length > 0)
        .filter((tag: string, index: number, tags: string[]) => tags.indexOf(tag) === index)
        .slice(0, this.tablet() ? 3 : 2);
      return {
        headline: item.title.trim() || '未命名影片',
          summary: item.introduction.trim() || item.actorText.trim() || '暂无简介',
          starLabel: '★'.repeat(filledStars) + '☆'.repeat(5 - filledStars),
          scoreLabel: validScore ? rawScore.toFixed(1) + '分' : '暂无评分',
          rankLabel: rawRank ? '排名 ' + (/^\d+$/.test(rawRank) ? '#' : '') + rawRank : '排名暂无',
          yearLabel: rawYear ? rawYear + (/^\d{4}$/.test(rawYear) ? '年' : '') : '年份未知',
          episodeLabel: rawEpisodes ? (/^\d+$/.test(rawEpisodes) ? '全' + rawEpisodes + '集' : rawEpisodes) :
          (item.updateText.trim() || '集数未知'),
          genreTags: cleanTags.length > 0 ? cleanTags : ['题材待补充'],
          coverImage: item.posterImage || item.stillImage || item.bannerImage || item.focusImage || item.displayImage
      };
    } catch (error) {
      Logger.error('HomeBanner', '准备轮播渲染信息失败，显示缺省内容：' + String(error));
      return {
        headline: '影片信息暂不可用', summary: '请稍后重试', starLabel: '☆☆☆☆☆', scoreLabel: '暂无评分',
          rankLabel: '排名暂无', yearLabel: '年份未知', episodeLabel: '集数未知',
          genreTags: ['题材待补充'], coverImage: ''
      };
    }
  }
  private onBannerBackgroundReady(itemIndex: number, loadFailed: boolean): void {
    try {
      if (loadFailed) { Logger.error('HomeModule', '轮播图片显示失败 ' + itemIndex); }
      if (this.bannerItems.length > 0 && itemIndex === this.bannerItems[0].itemIndex) {
        this.firstBannerRendered();
      }
    } catch (error) {
      Logger.error('HomeBanner', '处理轮播背景渲染事件失败：' + String(error));
    }
  }
  private onBannerCoverFailed(itemIndex: number): void {
    try {
      if (!this.failedBannerCovers.includes(itemIndex)) {
        this.failedBannerCovers = this.failedBannerCovers.concat(itemIndex);
        Logger.warn('HomeBanner', '轮播封面显示失败，使用本地占位图，条目=' + itemIndex);
      }
    } catch (error) {
      Logger.error('HomeBanner', '处理轮播封面渲染事件失败：' + String(error));
    }
  }

  // ---------------- 视觉层 ----------------

  @Builder
  private brandMark() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('36vp').height('36vp').borderRadius('12vp')
        .linearGradient({ angle: 135, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
        .shadow({ radius: 14, color: Ui.accentGlow(this.darkTheme), offsetY: 5 })
      Text('无')
        .fontSize(Ui.fs('17vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
    }
      .width('36vp').height('36vp')
  }

  @Builder
  private brandRow() {
    Row({ space: 10 }) {
      this.brandMark()
      Column({ space: 1 }) {
        Text('无音影视')
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .maxLines(1)
        Text('光影有声 · 静赏好片')
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GlassIconButton({
        iconSize: 38,
        symbol: $r('sys.symbol.camera'),
        accessibilityLabel: '识图找片',
        onTap: (): void => { this.toast('相机识片服务尚未配置'); }
      })
      GlassIconButton({
        iconSize: 38,
        symbol: $r('sys.symbol.timer'),
        accessibilityLabel: '观看历史',
        onTap: (): void => { AppState.go('history'); }
      })
    }
      .width('100%')
      .height('40vp')
      .alignItems(VerticalAlign.Center)
  }

  @Builder
  private tagStrip() {
    SegmentedGlassTabs({
      labels: this.labels,
      active: this.tagIndex(),
      trackWidth: this.contentW(),
      trackHeight: this.tablet() ? 48 : 44,
      compact: Ui.isCompact(this.contentWidth()),
      onSelect: (index: number): void => {
        this.getUIContext().animateTo({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn }, () => {
          this.selected = this.labels[Math.max(0, Math.min(this.labels.length - 1, index))];
        });
      }
    })
  }

  @Builder
  private header() {
    Row() {
      Column({ space: 10 }) {
        this.brandRow()
        GlassSearchBar({
          query: this.query,
          placeholder: this.tablet() ? '搜索影片、演员、导演或剧集' : '搜索影片 / 演员 / 导演',
          showButton: true,
          onQueryChange: (text: string): void => { this.query = text; },
          onSubmit: (): void => { this.search(); }
        })
        this.tagStrip()
      }
        .width(this.contentW())
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: this.safeTop() + 6, bottom: 10 })
  }

  @Builder
  private heroPlayPill() {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.play_fill')).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(['#FFFFFF'])
      Text('立即观看').fontSize(Ui.fs('12vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').maxLines(1)
    }
      .height('32vp')
      .padding({ left: '13vp', right: '15vp' })
      .borderRadius('16vp')
      .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
      .shadow({ radius: 12, color: Ui.accentGlow(this.darkTheme), offsetY: 3 })
  }

  @Builder
  private bannerSlide(item: Banner) {
    // 每次渲染只准备一次完整文案与布局，避免各文本节点重复解析接口字段。
    this.bannerScene(item, this.bannerFrame(), this.bannerPresentation(item))
  }

  @Builder
  private bannerScene(item: Banner, frame: BannerFrame, details: BannerPresentation) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(item.displayImage).width('100%').height('100%').objectFit(ImageFit.Cover)
        .onComplete(() => { this.onBannerBackgroundReady(item.itemIndex, false); })
        .onError(() => { this.onBannerBackgroundReady(item.itemIndex, true); })
      // 顶部压暗：让角标在亮画面上也能读清（铺满整块，靠渐变停靠点控制范围）
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#7A000000', 0], ['#00000000', 0.3]] })
      // 底部压暗：承载标题、简介与按钮
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.2], ['#8C050810', 0.58], ['#F2050810', 1]]
        })
      Column() {
        Row({ space: 6 }) {
          Row({ space: 4 }) {
            Text('★').fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme))
            Text(details.scoreLabel).fontSize(Ui.fs('11.5vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').maxLines(1)
          }
            .height('24vp').padding({ left: '9vp', right: '9vp' })
            .borderRadius('12vp')
            .backgroundColor('#33FFFFFF')
            .border({ width: 1, color: '#40FFFFFF' })
          if (details.rankLabel.length > 0 && details.rankLabel !== '排名暂无') {
            Row() {
              Text(details.rankLabel).fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor('#E6FFFFFF').maxLines(1)
            }
              .height('24vp').padding({ left: '9vp', right: '9vp' })
              .borderRadius('12vp')
              .backgroundColor('#26000000')
              .border({ width: 1, color: '#2EFFFFFF' })
          }
          Blank()
          Row({ space: 3 }) {
            Text((this.currentBannerIndex + 1) + ' / ' + Math.max(1, this.bannerItems.length))
              .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor('#E6FFFFFF').maxLines(1)
          }
            .height('24vp').padding({ left: '9vp', right: '9vp' })
            .borderRadius('12vp')
            .backgroundColor('#26000000')
            .border({ width: 1, color: '#2EFFFFFF' })
        }
          .width('100%')
        Blank()
        Row({ space: frame.contentGap }) {
          Column({ space: 7 }) {
            Text(details.headline)
              .fontSize(Ui.fs(frame.largeScene ? '30vp' : '22vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(details.summary)
              .fontSize(Ui.fs(frame.largeScene ? '14vp' : '12vp', this.fontScale))
              .fontColor('#E0E8F5')
              .maxLines(frame.largeScene ? 2 : 1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Row({ space: 6 }) {
              ForEach(details.genreTags, (tag: string) => {
                Row() {
                  Text(tag).fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor('#E6FFFFFF').maxLines(1)
                }
                  .height('22vp').padding({ left: '8vp', right: '8vp' })
                  .borderRadius('11vp')
                  .backgroundColor('#1FFFFFFF')
                  .border({ width: 1, color: '#33FFFFFF' })
              }, (tag: string) => tag)
              Row() {
                Text(details.yearLabel + ' · ' + details.episodeLabel)
                  .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor('#B3FFFFFF').maxLines(1)
              }
                .height('22vp').padding({ left: '8vp', right: '8vp' })
                .borderRadius('11vp')
                .backgroundColor('#1FFFFFFF')
            }
              .width('100%')
            Row({ space: 10 }) {
              this.heroPlayPill()
              Blank()
              Text('查看详情 ›')
                .fontSize(Ui.fs('11.5vp', this.fontScale))
                .fontColor('#D9FFFFFF')
                .maxLines(1)
            }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: '2vp' })
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          if (details.coverImage.length > 0 && !this.failedBannerCovers.includes(item.itemIndex)) {
            Column() {
              Image(details.coverImage)
                .width('100%')
                .height(frame.coverTall + 'vp')
                .objectFit(ImageFit.Cover)
                .borderRadius('14vp')
                .onError(() => { this.onBannerCoverFailed(item.itemIndex); })
            }
              .width(frame.coverWide + 'vp')
              .padding('3vp')
              .borderRadius('18vp')
              .backgroundColor('#26FFFFFF')
              .border({ width: 1, color: '#40FFFFFF' })
              .shadow({ radius: 18, color: '#8C000000', offsetY: 8 })
              .alignSelf(ItemAlign.Center)
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
      }
        .width('100%')
        .height('100%')
        .padding({
          left: frame.contentInset + 'vp',
          right: frame.contentInset + 'vp',
          top: (frame.contentInset + 2) + 'vp',
          bottom: (frame.contentInset + 2) + 'vp'
        })
        .alignItems(HorizontalAlign.Start)
    }
      .height('100%').width('100%')
      .borderRadius(this.tablet() ? '30vp' : '26vp')
      .clip(true)
      .backgroundColor(Ui.genreTop('电影', this.darkTheme))
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
      .scale({ x: this.bannerPressed ? 0.985 : 1, y: this.bannerPressed ? 0.985 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .onClick(() => { this.openSearchWith(item.title); })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.97, y: 0.97 })))
  }

  @Builder
  private hero() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.bannerItems.length > 0) {
        Swiper() {
          ForEach(this.bannerItems, (item: Banner) => {
            this.bannerSlide(item)
          }, (item: Banner) => 'hero-' + item.itemIndex)
        }
          .height('100%')
          .width('100%')
          .index(this.currentBannerIndex)
          .onChange((index: number) => {
            try {
              this.currentBannerIndex = index;
            } catch (error) {
              Logger.error('HomeBanner', '更新轮播索引失败：' + String(error));
            }
          })
          .onTouch((event: TouchEvent) => {
            try {
              if (event.type === TouchType.Down) {
                this.sliding = true;
                this.bannerPressed = true;
                this.stopBannerTimer();
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.sliding = false;
                this.bannerPressed = false;
                this.startBannerTimer();
              }
            } catch (error) {
              Logger.error('HomeBanner', '处理轮播手势失败：' + String(error));
            }
          })
          .autoPlay(false)
          .loop(true)
          .duration(450)
        // 指示器由页面右上角的“当前 / 总数”玻璃胶囊承担，隐藏 Swiper 自带圆点。
          .indicator(Indicator.dot().color('#00000000').selectedColor('#00000000')
          .itemWidth('1vp').itemHeight('1vp'))
      } else if (!this.bannerLoading) {
        Column({ space: 10 }) {
          Text('◍').fontSize(Ui.fs('34vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).opacity(0.7)
          Text(this.bannerMessage).fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme)).maxLines(1)
          Text('轻触重试').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
        }
          .width('100%')
          .height(this.heroHeight())
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 150,
            colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
          })
          .onClick(() => { void this.loadHomeContent(); })
      }
      if (this.bannerLoading) {
        Column() {
          LoadingProgress().width('34vp').height('34vp').color(Ui.accent(this.darkTheme))
        }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Ui.scrim(this.darkTheme))
          .opacity(this.bannerLoadingAlpha)
          .transition(TransitionEffect.OPACITY)
      }
    }
      .height(this.heroHeight())
      .width('100%')
      .borderRadius(this.tablet() ? '30vp' : '26vp')
      .clip(true)
      .backgroundColor(Ui.card(this.darkTheme))
  }

  @Builder
  private quickActions() {
    // 原五个快捷入口已移除，改为「观影记录」横条（本地播放历史）。
    HistoryStrip()
  }

  @Builder
  private varietyCard(item: VarietyItem) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (item.displayImage.length > 0 && !this.failedVarietyImages.includes(item.itemIndex)) {
          Image(item.displayImage)
            .width('100%')
            .height(this.varietyPosterHeight() + 'vp')
            .objectFit(ImageFit.Cover)
            .onError(() => {
              if (!this.failedVarietyImages.includes(item.itemIndex)) {
                Logger.error('HomeRecommendFix', '海报显示失败 ' + item.itemIndex);
                this.failedVarietyImages = this.failedVarietyImages.concat(item.itemIndex);
              }
            })
        } else {
          Column() {
            Text(Ui.genreGlyph('综艺'))
              .fontSize(Ui.fs(this.tablet() ? '76vp' : '56vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .opacity(0.22)
          }
            .width('100%')
            .height(this.varietyPosterHeight() + 'vp')
            .justifyContent(FlexAlign.Center)
            .linearGradient({
              angle: 150,
              colors: [[Ui.genreTop('综艺', this.darkTheme), 0], [Ui.genreBottom('综艺', this.darkTheme), 1]]
            })
        }
        Column()
          .width('100%').height('100%')
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.32], ['#8C000000', 1]]
          })
        if (item.scoreText.length > 0) {
          Row({ space: 3 }) {
            Text('★').fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme))
            Text(item.scoreText).fontSize(Ui.fs('10.5vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').maxLines(1)
          }
            .height('21vp').padding({ left: '7vp', right: '7vp' })
            .borderRadius('11vp')
            .backgroundColor('#33000000')
            .border({ width: 1, color: '#33FFFFFF' })
            .margin({ top: '8vp', right: '8vp' })
        }
      }
        .width('100%')
        .height(this.varietyPosterHeight() + 'vp')
        .borderRadius(this.tablet() ? '20vp' : '18vp')
        .clip(true)
        .backgroundColor(Ui.card(this.darkTheme))
        .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
        .shadow({ radius: 14, color: Ui.shadowSoft(this.darkTheme), offsetY: 7 })
      Text(item.title)
        .fontSize(Ui.fs(this.tablet() ? '14vp' : '12.5vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(item.introduction || item.updateText || '暂无简介')
        .fontSize(Ui.fs(this.tablet() ? '11.5vp' : '10.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
      .width(this.varietyCardWidth())
      .scale({ x: this.varietyPressed === item.mid ? 0.96 : 1, y: this.varietyPressed === item.mid ? 0.96 : 1 })
      .animation({ duration: UiMotion.FAST, curve: Curve.FastOutSlowIn })
      .accessibilityText(item.title)
      .onTouch((event: TouchEvent) => { this.varietyPressed = event.type === TouchType.Down ? item.mid : ''; })
      .onClick(() => { this.openSearchWith(item.title); })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })))
  }

  @Builder
  private varietySection() {
    Column({ space: 12 }) {
      SectionHeader({
        title: '猜你喜欢',
        subtitle: '综艺 · 编辑每日更新',
        actionText: '换一批',
        viewportWidth: this.contentWidth(),
        onAction: (): void => { void this.loadHomeContent(); }
      })
      if (this.varietyItems.length > 0) {
        Scroll() {
          Row({ space: this.tablet() ? 14 : 12 }) {
            ForEach(this.varietyItems, (item: VarietyItem) => {
              this.varietyCard(item)
            }, (item: VarietyItem) => 'variety-' + item.itemIndex)
          }
            .padding({ left: 0, right: 0 })
        }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(this.varietyPosterHeight() + 56)
      } else if (!this.varietyLoading) {
        Column({ space: 8 }) {
          Text(this.varietyMessage || '暂无综艺内容')
            .fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          Text('轻触重试').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
        }
          .width('100%')
          .height('120vp')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.card(this.darkTheme))
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
          .onClick(() => { void this.loadHomeContent(); })
      } else {
        Row() {
          LoadingProgress().width('26vp').height('26vp').color(Ui.accent(this.darkTheme))
        }
          .width('100%')
          .height('120vp')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.card(this.darkTheme))
          .opacity(this.varietyLoadingAlpha)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private featuredSection() {
    Column({ space: 12 }) {
      SectionHeader({
        title: this.selected === '首页' ? '为你精选' : this.selected,
        subtitle: this.selected === '首页' ? '按观看口味混排的今日片单' : '全部' + this.selected + '，共 ' + this.films().length + ' 部',
        viewportWidth: this.contentWidth()
      })
      if (this.films().length > 0) {
        Grid(this.homeGridScroller) {
          ForEach(this.films(), (film: Film) => {
            GridItem() {
              FilmTile({ film: film, tablet: this.tablet() })
            }
          }, (film: Film) => 'film-' + film.id)
        }
          .columnsTemplate(this.gridTemplate())
          .columnsGap(this.tablet() ? 18 : 14)
          .rowsGap(this.tablet() ? 18 : 14)
          .width('100%')
          .height(this.gridRows() * (this.filmTileHeight() + (this.tablet() ? 18 : 14)))
          .onScrollStart(() => { this.beginHomeScroll('films', this.homeGridScroller); })
          .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
            this.reportHomeScroll('films', this.homeGridScroller, scrollState);
          })
          .onScrollStop(() => { this.endHomeScroll('films', this.homeGridScroller); })
      } else {
        Column({ space: 8 }) {
          Text('◌').fontSize(Ui.fs('28vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).opacity(0.8)
          Text('该分类暂无影片').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme))
          Text('切换到「首页」查看全部推荐').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
        }
          .width('100%')
          .height('160vp')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.card(this.darkTheme))
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private home() {
    Column() {
      this.header()
      Scroll(this.homeScroller) {
        Row() {
          Column({ space: this.tablet() ? 24 : 20 }) {
            this.hero()
            this.quickActions()
            this.varietySection()
            this.featuredSection()
          }
            .width(this.contentW())
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: this.navigationClearance() + 24 })
        }
          .width('100%')
          .justifyContent(FlexAlign.Center)
      }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onScrollStart(() => { this.beginHomeScroll('content', this.homeScroller); })
        .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
          this.reportHomeScroll('content', this.homeScroller, scrollState);
        })
        .onScrollStop(() => { this.endHomeScroll('content', this.homeScroller); })
    }
      .width('100%')
      .height('100%')
  }

  @Builder
  private businessPage() {
    if (this.page === 'search') {
      SearchPage().width('100%').height('100%')
    } else if (this.page === 'message') {
      // 新增的消息 Tab：好友 / 群聊 / 聊天室三合一，内部按宽度自适应手机与平板布局。
      MessageCenterPage().width('100%').height('100%')
    } else if (this.page === 'forum') {
      // 论坛作为底栏入口嵌入时不显示返回按钮，避免 router.back() 退出应用。
      ForumPage({ embedded: true }).width('100%').height('100%')
    } else if (this.page === 'live') {
      LiveTvPage({ embedded: true }).width('100%').height('100%')
    } else if (this.page === 'category') {
      CategoryPage().width('100%').height('100%')
    } else if (this.page === 'manage') {
      ManagePage({ initialTab: this.manageInitialTab }).width('100%').height('100%')
    } else if (this.page === 'settings') {
      SettingPage().width('100%').height('100%')
    } else if (this.page === 'mine' || this.page === 'profile') {
      // 将原“我的”占位内容独立为组件，保留文案、返回入口与既有业务状态。
      MyPage().width('100%').height('100%')
    } else {
      Column({ space: 16 }) {
        Text(this.page === 'player' ? AppState.current.name : '无音影视')
          .fontSize(Ui.fs('22vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
        Text(this.page === 'player' ? '当前影片尚未配置可播放资源' : '此业务页面尚未接入')
          .fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme))
        Row() {
          Text('返回首页').fontSize(Ui.fs('14vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        }
          .height('44vp').padding({ left: '22vp', right: '22vp' }).borderRadius('22vp')
          .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
          .onClick(() => { AppState.go('home'); })
      }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层：底色 + 极光柔光，所有页面共享同一张"底片"
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 1 : 0.9 })
      if (this.page === 'home') {
        this.home()
      } else {
        // 搜索、分类、管理与设置不预留悬浮栏空间；其他业务页面保持原有避让布局。
        Column() {
          this.businessPage()
        }
          .width('100%')
          .height('100%')
          .padding({ bottom: this.fullScreenBusinessPage() ? '0vp' : this.navigationClearance() + 'vp' })
      }
      // 底栏 + 底栏上方的渐进模糊：是整屏 Stack 的最后一个孩子，所以模糊只作用于它上方的正文，
      // 且模糊带的高度固定，超过栏顶的正文完全不受影响。
      LiquidNav({
        viewportWidth: this.contentWidth(),
        viewportHeight: this.viewportHeight,
        safeBottom: this.safeBottom()
      })
      // 聊天室实时消息提醒：顶部弹窗跟随底栏同层叠加，不拦截页面其它区域的点击。
      ChatNoticeBanner()
    }
      .width('100%').height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
    // 首页扩展到顶部后仅用 safeTop 做一次内边距；其他业务页保持原有安全区策略。
      .expandSafeArea(this.page === 'home' || this.page === 'category' ?
      [SafeAreaType.SYSTEM, SafeAreaType.CUTOUT] : [SafeAreaType.SYSTEM], this.fullScreenBusinessPage()
      ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END]
      : this.page === 'home' ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
      .padding({
        left: this.fullScreenBusinessPage() ? '0vp' : Math.max(0, this.leftSafeInset) + 'vp',
        right: this.fullScreenBusinessPage() ? '0vp' : Math.max(0, this.rightSafeInset) + 'vp'
      })
      .onAreaChange((_oldArea: Area, area: Area) => {
        try {
          const nextWidth: number = Number(area.width);
          const nextHeight: number = Number(area.height);
          if (nextWidth > 0 && nextWidth !== this.viewportWidth) {
            this.viewportWidth = nextWidth;
            ImmersiveService.publishSafeArea();
          }
          if (nextHeight > 0 && Math.abs(nextHeight - this.viewportHeight) > 1) {
            this.viewportHeight = nextHeight;
          }
          this.publishNavClearance();
        } catch (error) {
          Logger.error('HomeImmersive', '更新页面安全布局失败：' + String(error));
        }
      })
  }
}

import { Theme } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { CategoryBatch, CategoryFilters, CategoryService, CategoryVideo } from '../common/CategoryService';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, GlassChip } from '../common/UiWidgets';
import { TapUI } from './TapUI';
import { SymbolIcons } from '../common/SymbolIcons';

enum FilterLayer {
  FORM,
    TYPE,
    AREA,
    YEAR,
    ORDER
}

// 独立分类组件；搜索仍使用原 SearchPage 和原 searchQuery 存储键。
@Component
export struct CategoryPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveConfig') @Watch('materialChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('materialChanged') private darkTheme: boolean = true;
  @StorageLink('themeMode') @Watch('materialChanged') private themeMode: string = 'system';
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private viewportSize: number = 360;
  @State private xingshi: string | null = '电影';
  @State private leixing: string = '';
  @State private diqu: string = '';
  @State private shijian: string = '';
  @State private paixin: string = 'hot';
  @State private formIndex: number = 1;
  @State private typeIndex: number = 0;
  @State private areaIndex: number = 0;
  @State private yearIndex: number = 0;
  @State private orderIndex: number = 0;
  @State private fllba: CategoryVideo[] = [];
  @State private pagl: number = 1;
  @State private loadingFirst: boolean = false;
  @State private loadingMore: boolean = false;
  @State private refreshing: boolean = false;
  @State private debouncePending: boolean = false;
  @State private noMore: boolean = false;
  @State private firstMessage: string = '';
  @State private emptyMessage: string = '暂无资源';
  @State private pagingMessage: string = '';
  @State private pressedKey: string = '';
  @State private hoveredKey: string = '';
  @State private failedImages: string[] = [];
  @State private visibleImageKeys: string[] = [];
  @State private loadedImageKeys: string[] = [];
  @State private headerProgress: number = 0;
  @State private filterExpanded: boolean = true;
  // 初始高度给足（5 行筛选项），避免首帧测量偏小导致「排序」行被裁切。
  @State private filterPanelTall: number = 320;
  @State private skeletonPhase: number = 0;
  private lastFlowOffset: number = 0;
  private filterScrollTravel: number = 0;
  private filterAnimationUntil: number = 0;
  private readonly flowMaxWide: number = 1200;
  private readonly skeletonKeys: number[] = [0, 1, 2, 3, 4, 5, 6, 7];
  private readonly flowScroller: Scroller = new Scroller();
  private readonly filterScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private requestVersion: number = 0;
  private requestDebounceTimer: number = -1;
  private skeletonTimer: number = -1;
  private pageAlive: boolean = false;
  private activeRequest: http.HttpRequest | undefined = undefined;
  private readonly formLabels: string[] = ['电视剧', '电影', '动漫', '综艺'];
  private readonly movieLabels: string[] = ['全部', '动作', '战争', '恐怖', '爱情', '喜剧', '古装', '犯罪', '惊悚', '丧尸', '爱情', '科幻', '动画', '剧情', '武侠', '家庭', '悬疑', '奇幻', '历史', '青春', '冒险', '传记', '歌舞', '音乐', '网络大电影', '其他'];
  private readonly tvLabels: string[] = ['全部', '古装', '都市', '言情', '武侠', '战争', '青春', '喜剧', '家庭', '伦理', '谍战', '军旅', '犯罪', '动作', '奇幻', '神话', '剧情', '历史', '经典', '乡村', '情景', '科幻', '动作', '神话', '奇幻', '剧情', '历史', '情景', '网剧', '其他'];
  private readonly comicLabels: string[] = ['全部', '热血', '冒险', '战争', '搞笑', '科幻', '动作', '励志', '情感', '少女', '校园', '推理', '萝莉', '机战', '百合', '少年', '运动', '社会', '原创'];
  private readonly varietyLabels: string[] = ['全部', '情感', '真人秀', '脱口秀', '音乐', '选秀', '生活', '养成', '访谈', '晚会', '美食', '曲艺', '游戏互动', '播报', '旅游', '求职', '网综'];
  private readonly areaLabels: string[] = ['全部', '内地', '香港', '台湾', '韩国', '日本', '印度', '法国', '美国', '德国', '英国', '泰国', '欧洲地区', '东南亚地区', '其他'];
  private readonly yearLabels: string[] = ['全部', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015', '2014', '2013', '2012', '2011', '2010', '2009', '2008', '2007', '2006', '2005', '2004', '2003', '2002', '2001', '2000', '90年代', '八十年代', '七十年代'];
  private readonly orderLabels: string[] = ['热门', '更新', '评价'];
  private readonly orderValues: string[] = ['hot', 'pubtime', 'rating'];

  aboutToAppear(): void {
    this.pageAlive = true;
    this.startSkeletonSweep();
    // 分类页由宿主嵌入，组件显示时复用 onPageShow 的日志埋点。
    this.onPageShow();
    this.materialChanged();
    void this.fenlei();
  }

  onPageShow(): void {
    Logger.info('CategoryPage', '分类页面进入，当前选中筛选参数：' + this.filterDescription());
  }

  aboutToDisappear(): void {
    this.pageAlive = false;
    this.stopSkeletonSweep();
    this.requestVersion++;
    this.clearRequestDebounce();
    this.cancelRequest();
    // Image 仅持有 URL，由 ArkUI 释放解码资源；移除列表和可见性引用，不清理其他页面的图片缓存。
    this.visibleImageKeys = [];
    this.failedImages = [];
    this.loadedImageKeys = [];
    this.fllba = [];
    this.pressedKey = '';
    this.hoveredKey = '';
    this.refreshing = false;
    this.debouncePending = false;
    this.loadingFirst = false;
    this.loadingMore = false;
    Logger.info('CategoryPage', '分类页面退出，已取消未完成请求、清除防抖定时器并释放卡片图片引用');
  }

  onWillApplyTheme(_theme: Theme): void {
    // 系统主题资源由 ArkUI 刷新，显式主题沿用全局 darkTheme。
    this.materialChanged();
  }

  private animateState(update: () => void): void {
    if (!this.pageAlive) {
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, update);
  }

  private materialChanged(): void {
    try {
      // 与管理页相同，材质开关不改变分类页的全屏布局。
      void ImmersiveService.apply(true);
    } catch (error) {
      Logger.error('CategoryPage', '同步分类页沉浸配置失败：' + String(error));
    }
  }

  private startSkeletonSweep(): void {
    if (this.skeletonTimer !== -1) {
      return;
    }
    this.skeletonTimer = setInterval(() => {
      if (this.pageAlive) {
        this.skeletonPhase = this.skeletonPhase === 0 ? 1 : 0;
      }
    }, 900);
  }

  private stopSkeletonSweep(): void {
    if (this.skeletonTimer !== -1) {
      clearInterval(this.skeletonTimer);
      this.skeletonTimer = -1;
    }
  }

  private isTablet(): boolean {
    return this.viewportSize >= 600;
  }

  private isDesktop(): boolean {
    return this.viewportSize >= 1200;
  }

  private listWide(): number {
    // 仅列表限制最大宽度；列数和卡片宽度使用相同的有效列表宽度，避免大屏卡片溢出。
    return Math.min(this.viewportSize, this.flowMaxWide);
  }

  private columnCount(): number {
    // 与管理页个人收藏使用相同的自适应列数规则。
    return Math.max(2, Math.min(6, Math.floor(this.listWide() / 150)));
  }

  private columnTemplate(): string {
    return new Array<string>(this.columnCount()).fill('1fr').join(' ');
  }

  private columnGap(): number {
    return 16;
  }

  private rowGap(): number {
    return 20;
  }

  private cardWide(): number {
    const availableWide: number = (this.listWide() - 48 - (this.columnCount() - 1) * this.columnGap()) / this.columnCount();
    return Math.min(520, Math.max(1, availableWide));
  }

  private posterWide(): number {
    // 卡片沿用个人收藏的 8vp 内边距；封面尺寸不采用图片固有尺寸。
    return Math.max(1, this.cardWide() - 16);
  }

  private posterTall(): number {
    return this.posterWide() * 3 / 2;
  }

  private textScale(): number {
    // 个人收藏卡片的文字及内部间距保持统一。
    return 1;
  }

  private cardInset(): string {
    return '8vp';
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private pageTone(): ResourceColor {
    // 页面底色统一走设计令牌：深色近黑冷蓝、浅色雾白，不再写死深浅二元色。
    return Ui.pageBg(this.darkTheme);
  }

  private normalInk(): Resource {
    return this.themeMode === 'system' ? $r('app.color.category_unselected_text') :
      this.darkTheme ? $r('app.color.category_unselected_dark') : $r('app.color.category_unselected_light');
  }

  private selectedInk(): Resource {
    return this.themeMode === 'system' ? $r('app.color.category_selected_text') :
      this.darkTheme ? $r('app.color.category_selected_dark') : $r('app.color.category_selected_light');
  }

  private glassRadius(): number {
    if (!this.immersiveConfig.immersiveEnable) {
      return 0;
    }
    const configuredRadius: number = this.immersiveConfig.immersiveBlur;
    return Number.isFinite(configuredRadius) ? Math.max(0, Math.min(100, configuredRadius)) : 0;
  }

  private materialAlpha(): number {
    const configuredAlpha: number = this.immersiveConfig.immersiveOpacity;
    return Number.isFinite(configuredAlpha) ? Math.max(0.15, Math.min(0.85, configuredAlpha * 0.65)) : 0.5;
  }

  private panelTone(): ResourceColor {
    // 玻璃面板底色：材质越强底色越实，既保证"液态玻璃"质感也保证文字对比度。
    const surfaceMix: number = Math.min(1, this.materialAlpha() + this.headerProgress * 0.25);
    return surfaceMix > 0.5 ? Ui.glassTintStrong(this.darkTheme) : Ui.glassTint(this.darkTheme);
  }

  private cardTone(): ResourceColor {
    return Ui.card(this.darkTheme);
  }

  private cardInk(): string {
    return Ui.ink(this.darkTheme);
  }

  private cardSecondary(): string {
    return Ui.inkSoft(this.darkTheme);
  }

  private panelGlowRadius(): number {
    return 14;
  }

  private panelGlowTone(): string {
    return Ui.shadowSoft(this.darkTheme);
  }

  private panelRimTone(): string {
    return Ui.cardBorderSoft(this.darkTheme);
  }

  private labelsFor(layer: FilterLayer): string[] {
    switch (layer) {
      case FilterLayer.FORM: return this.formLabels;
      case FilterLayer.TYPE:
        switch (this.xingshi) {
        case '电视剧': return this.tvLabels;
        case '动漫': return this.comicLabels;
        case '综艺': return this.varietyLabels;
        default: return this.movieLabels;
      }
      case FilterLayer.AREA: return this.areaLabels;
      case FilterLayer.YEAR: return this.yearLabels;
      case FilterLayer.ORDER: return this.orderLabels;
      default: return [];
    }
  }

  private layerTitle(layer: FilterLayer): string {
    switch (layer) {
      case FilterLayer.FORM: return '形式';
      case FilterLayer.TYPE: return '类型';
      case FilterLayer.AREA: return '地区';
      case FilterLayer.YEAR: return '年代';
      case FilterLayer.ORDER: return '排序';
      default: return '';
    }
  }

  private indexFor(layer: FilterLayer): number {
    switch (layer) {
      case FilterLayer.FORM: return this.formIndex;
      case FilterLayer.TYPE: return this.typeIndex;
      case FilterLayer.AREA: return this.areaIndex;
      case FilterLayer.YEAR: return this.yearIndex;
      case FilterLayer.ORDER: return this.orderIndex;
      default: return -1;
    }
  }

  private selectFilter(layer: FilterLayer, index: number): void {
    const labels: string[] = this.labelsFor(layer);
    if (!Number.isInteger(index) || index < 0 || index >= labels.length || index === this.indexFor(layer)) {
      return;
    }
    const value: string = labels[index] === '全部' ? '' : labels[index];
    this.animateState(() => {
      switch (layer) {
        case FilterLayer.FORM:
          this.formIndex = index;
          this.xingshi = labels[index];
          this.typeIndex = 0;
          this.leixing = '';
          break;
        case FilterLayer.TYPE:
          this.typeIndex = index;
          this.leixing = value;
          break;
        case FilterLayer.AREA:
          this.areaIndex = index;
          this.diqu = value;
          break;
        case FilterLayer.YEAR:
          this.yearIndex = index;
          this.shijian = value;
          break;
        case FilterLayer.ORDER:
          this.orderIndex = index;
          this.paixin = this.orderValues[index];
          break;
      }
    });
    if (layer === FilterLayer.FORM) {
      this.filterScrollers[FilterLayer.TYPE].scrollTo({ xOffset: 0, yOffset: 0 });
    }
    Logger.info('CategoryPage', 'Tab切换，更新筛选参数：' + this.filterDescription() +
    '，切换层级：' + this.layerTitle(layer) + '，选中项：' + labels[index]);
    // 筛选状态立即更新，接口事件仅合并最后 300ms 的输入；旧响应不能混入新结果。
    this.scheduleFirstPage();
  }

  private filters(): CategoryFilters {
    return { xingshi: this.xingshi, leixing: this.leixing, diqu: this.diqu, shijian: this.shijian, paixin: this.paixin };
  }

  private filterDescription(): string {
    return '形式xingshi=' + String(this.xingshi) +
    '，类型leixing=' + (this.leixing || '全部（不加入query）') +
    '，地区diqu=' + (this.diqu || '全部（不加入query）') +
    '，年代shijian=' + (this.shijian || '全部（不加入query）') +
    '，排序paixin=' + this.paixin;
  }

  private clearRequestDebounce(): void {
    if (this.requestDebounceTimer !== -1) {
      clearTimeout(this.requestDebounceTimer);
      this.requestDebounceTimer = -1;
    }
  }

  private scheduleFirstPage(): void {
    if (!this.pageAlive) {
      return;
    }
    this.clearRequestDebounce();
    this.requestVersion++;
    this.cancelRequest();
    this.animateState(() => {
      this.debouncePending = true;
      this.loadingFirst = true;
      this.loadingMore = false;
      this.refreshing = false;
      this.firstMessage = '';
      this.pagingMessage = '';
    });
    this.requestDebounceTimer = setTimeout(() => {
      this.requestDebounceTimer = -1;
      if (!this.pageAlive) {
        return;
      }
      this.debouncePending = false;
      void this.fenlei();
    }, 300);
  }

  private cancelRequest(): void {
    const previousRequest: http.HttpRequest | undefined = this.activeRequest;
    this.activeRequest = undefined;
    if (previousRequest) {
      try {
        previousRequest.destroy();
        Logger.info('CategoryPage', '已取消旧分类请求，避免过期响应及并发加载');
      } catch (error) {
        Logger.warn('CategoryPage', '释放旧分类请求失败：' + String(error));
      }
    }
  }

  private releaseRequest(request: http.HttpRequest): void {
    // 被筛选切换取消的请求已经释放，不二次 destroy。
    if (this.activeRequest !== request) {
      return;
    }
    this.activeRequest = undefined;
    try {
      request.destroy();
    } catch (error) {
      Logger.warn('CategoryPage', '释放分类请求失败：' + String(error));
    }
  }

  private async fenlei(refreshMode: boolean = false): Promise<void> {
    if (!this.pageAlive || this.activeRequest !== undefined || this.debouncePending) {
      return;
    }
    const version: number = ++this.requestVersion;
    // 首次加载、刷新、分页共用 activeRequest 锁；筛选切换只允许取消后启动新请求。
    this.animateState(() => {
      this.loadingFirst = !refreshMode || this.fllba.length === 0;
      this.loadingMore = false;
      this.refreshing = refreshMode;
      this.pagl = 1;
      if (!refreshMode) {
        this.fllba = [];
        this.failedImages = [];
        this.visibleImageKeys = [];
        this.loadedImageKeys = [];
      }
      this.pressedKey = '';
      this.hoveredKey = '';
      this.firstMessage = '';
      this.emptyMessage = '暂无资源';
      this.pagingMessage = '';
      this.noMore = false;
    });
    if (!refreshMode) {
      this.headerProgress = 0;
      this.resetFilterPanel();
      try {
        this.flowScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      } catch (error) {
        Logger.warn('CategoryPage', '瀑布流尚未挂载，保留第一页归位状态：' + String(error));
      }
    }
    let request: http.HttpRequest | undefined = undefined;
    const currentFilters: CategoryFilters = this.filters();
    const requestUrl: string = CategoryService.address(currentFilters, 1);
    try {
      request = http.createHttp();
      this.activeRequest = request;
      const batch: CategoryBatch = await CategoryService.load(request, currentFilters, 1);
      Logger.info('CategoryPage', '分类接口请求成功，返回条目数量：' + batch.videos.length +
      '，size=' + batch.size + '，pn=1，本次请求完整URL：' + requestUrl);
      if (!this.pageAlive || version !== this.requestVersion) {
        Logger.warn('CategoryPage', '忽略已失效的分类响应，本次请求完整URL：' + requestUrl);
        return;
      }
      this.animateState(() => {
        this.emptyMessage = batch.totalNum === 0 ? '暂无匹配影视资源' : '暂无资源';
        this.fllba = batch.size === -1 ? [] : batch.videos;
        this.failedImages = [];
        // 刷新保留相同 key 的可见状态；新列表中的离屏图片不创建 Image。
        this.visibleImageKeys = this.visibleImageKeys.filter((key: string) =>
          batch.videos.some((video: CategoryVideo) => video.key === key));
        this.loadedImageKeys = this.loadedImageKeys.filter((key: string) =>
          batch.videos.some((video: CategoryVideo) => video.key === key));
        this.noMore = batch.size <= 0 || batch.sourceCount === 0;
      });
    } catch (error) {
      Logger.error('CategoryPage', '分类接口请求失败，本次请求完整URL：' + requestUrl +
      '，错误信息：' + String(error));
      if (this.pageAlive && version === this.requestVersion) {
        this.animateState(() => {
          this.firstMessage = '分类加载失败，请检查网络后重试';
        });
      }
    } finally {
      if (request) {
        this.releaseRequest(request);
      }
      if (this.pageAlive && version === this.requestVersion) {
        this.animateState(() => {
          this.loadingFirst = false;
          this.refreshing = false;
        });
      }
    }
  }

  private async fenleiRefresh(pagl: number): Promise<void> {
    if (!this.pageAlive || this.loadingFirst || this.loadingMore || this.refreshing || this.debouncePending ||
      this.activeRequest !== undefined || this.noMore || !Number.isInteger(pagl) || pagl < 2) {
      return;
    }
    const version: number = this.requestVersion;
    this.animateState(() => {
      this.loadingMore = true;
      this.pagingMessage = '';
    });
    let request: http.HttpRequest | undefined = undefined;
    const currentFilters: CategoryFilters = this.filters();
    const requestUrl: string = CategoryService.address(currentFilters, pagl);
    try {
      request = http.createHttp();
      this.activeRequest = request;
      const batch: CategoryBatch = await CategoryService.load(request, currentFilters, pagl);
      Logger.info('CategoryPage', '分类接口请求成功，返回条目数量：' + batch.videos.length +
      '，pn=' + pagl + '，size=' + batch.size + '，本次分页完整URL：' + requestUrl);
      if (!this.pageAlive || version !== this.requestVersion) {
        Logger.warn('CategoryPage', '忽略已失效的分类分页响应，本次分页完整URL：' + requestUrl);
        return;
      }
      this.animateState(() => {
        if (batch.size <= 0 || batch.sourceCount === 0) {
          this.noMore = true;
        } else {
          // 保留之前的影片，新卡片复用同一搜索跳转逻辑。
          this.fllba = this.fllba.concat(batch.videos);
        }
      });
    } catch (error) {
      Logger.error('CategoryPage', '分页请求失败，本次分页完整URL：' + requestUrl +
      '，错误信息：' + String(error));
      if (this.pageAlive && version === this.requestVersion) {
        this.animateState(() => {
          this.pagl = Math.max(1, pagl - 1);
          this.pagingMessage = '加载失败，点击重试';
        });
      }
    } finally {
      if (request) {
        this.releaseRequest(request);
      }
      if (this.pageAlive && version === this.requestVersion) {
        this.animateState(() => { this.loadingMore = false; });
      }
    }
  }

  private loadNextPage(retry: boolean = false): void {
    if (!this.pageAlive || this.loadingFirst || this.loadingMore || this.refreshing || this.debouncePending ||
      this.activeRequest !== undefined || this.noMore || this.fllba.length === 0 || this.firstMessage ||
      (!!this.pagingMessage && !retry)) {
      return;
    }
    this.pagl++;
    const pagingUrl: string = CategoryService.address(this.filters(), this.pagl);
    Logger.info('CategoryPage', '触发分页加载，当前页码pagl=' + this.pagl +
    '，分页拼接完整URL：' + pagingUrl + '，请求参数：' + this.filterDescription() +
    '，是否分页重试：' + retry);
    void this.fenleiRefresh(this.pagl);
  }

  private refreshFirstPage(): void {
    if (!this.pageAlive || this.loadingFirst || this.loadingMore || this.debouncePending || this.activeRequest !== undefined) {
      this.refreshing = false;
      return;
    }
    const refreshUrl: string = CategoryService.address(this.filters(), 1);
    Logger.info('CategoryPage', '用户下拉刷新分类，拼接URL：' + refreshUrl + '，请求参数：' + this.filterDescription());
    void this.fenlei(true);
  }

  private retryFirstPage(): void {
    const retryUrl: string = CategoryService.address(this.filters(), 1);
    Logger.info('CategoryPage', '用户点击重新加载，使用当前筛选参数重试请求，拼接URL：' +
    retryUrl + '，请求参数：' + this.filterDescription());
    if (!this.loadingFirst && !this.loadingMore && !this.refreshing && !this.debouncePending) {
      void this.fenlei();
    }
  }

  private openSearch(title: string): void {
    AppStorage.setOrCreate('searchQuery', title);
    AppState.go('search');
  }

  private imageFailed(key: string): void {
    if (this.pageAlive && !this.failedImages.includes(key)) {
      Logger.warn('CategoryPage', '封面加载失败，使用蓝色播放占位图标，影片key=' + key);
      this.animateState(() => {
        this.failedImages = this.failedImages.concat(key);
        this.loadedImageKeys = this.loadedImageKeys.filter((loadedKey: string) => loadedKey !== key);
      });
    }
  }

  private imageLoaded(key: string): void {
    if (!this.pageAlive || !this.visibleImageKeys.includes(key) || this.failedImages.includes(key) ||
      this.loadedImageKeys.includes(key)) {
      return;
    }
    this.animateState(() => { this.loadedImageKeys = this.loadedImageKeys.concat(key); });
  }

  private imagePending(video: CategoryVideo): boolean {
    return !!video.img && !this.failedImages.includes(video.key) && !this.loadedImageKeys.includes(video.key);
  }

  private imageVisibility(key: string, isVisible: boolean): void {
    if (!this.pageAlive) {
      return;
    }
    if (isVisible && !this.visibleImageKeys.includes(key)) {
      this.visibleImageKeys = this.visibleImageKeys.concat(key);
    } else if (!isVisible && this.visibleImageKeys.includes(key)) {
      // 离屏时卸载 Image，避免大列表同时持有解码后的封面。
      this.visibleImageKeys = this.visibleImageKeys.filter((visibleKey: string) => visibleKey !== key);
      this.loadedImageKeys = this.loadedImageKeys.filter((loadedKey: string) => loadedKey !== key);
    }
  }

  private syncBottomNavigation(nextHidden: boolean, reason: string): void {
    // 只同步分类页的临时导航状态；宿主沿用现有平移动画、触摸禁用及读屏隐藏处理。
    // 不改变 immersiveConfig，也不影响其他页面或筛选区域的滚动逻辑。
    if (!this.pageAlive || AppStorage.get<string>('page') !== 'category') {
      return;
    }
    try {
      const previousHidden: boolean = AppStorage.get<boolean>('navigationBarHidden') ?? false;
      if (AppStorage.has('navigationBarHidden') && previousHidden === nextHidden) {
        return;
      }
      AppStorage.setOrCreate<boolean>('navigationBarHidden', nextHidden);
      Logger.debug('CategoryPage', '分类底部导航栏=' + (nextHidden ? '隐藏' : '展开') +
      '，原因=' + reason + '，滚动位置=' + this.lastFlowOffset + 'vp');
    } catch (error) {
      Logger.warn('CategoryPage', '同步分类底部导航显隐失败，保留原有列表及筛选逻辑：' + String(error));
    }
  }

  private resetFilterPanel(): void {
    this.lastFlowOffset = 0;
    this.filterScrollTravel = 0;
    this.filterAnimationUntil = Date.now() + 300;
    this.animateState(() => { this.filterExpanded = true; });
    this.syncBottomNavigation(false, '分类列表归位');
  }

  private measureFilterPanel(area: Area): void {
    const measuredTall: number = typeof area.height === 'number' ? area.height : Number.parseFloat(String(area.height));
    if (Number.isFinite(measuredTall) && measuredTall > 0 && Math.abs(measuredTall - this.filterPanelTall) > 0.5) {
      this.filterPanelTall = measuredTall;
    }
  }

  private beginFilterScroll(): void {
    if (!this.pageAlive) {
      return;
    }
    this.filterScrollTravel = 0;
    try {
      const currentOffset: number = this.flowScroller.currentOffset().yOffset;
      if (Number.isFinite(currentOffset)) {
        this.lastFlowOffset = Math.max(0, currentOffset);
      }
    } catch (error) {
      Logger.warn('CategoryPage', '初始化筛选区域滚动方向失败：' + String(error));
    }
  }

  private updateHeaderProgress(scrollState: ScrollState = ScrollState.Idle): void {
    if (!this.pageAlive) {
      return;
    }
    try {
      const scrollPosition: number = this.flowScroller.currentOffset().yOffset;
      if (!Number.isFinite(scrollPosition)) {
        return;
      }
      const currentOffset: number = Math.max(0, scrollPosition);
      const progress: number = Math.max(0, Math.min(1, currentOffset / 160));
      if (Math.abs(progress - this.headerProgress) > 0.01) {
        this.headerProgress = progress;
      }
      const scrollDelta: number = currentOffset - this.lastFlowOffset;
      this.lastFlowOffset = currentOffset;
      // 布局收缩及展开产生的偏移不作为手势方向，避免筛选区域反复闪动。
      if (scrollState === ScrollState.Idle || Date.now() < this.filterAnimationUntil) {
        this.filterScrollTravel = 0;
        return;
      }
      if ((scrollDelta > 0 && this.filterScrollTravel < 0) || (scrollDelta < 0 && this.filterScrollTravel > 0)) {
        this.filterScrollTravel = 0;
      }
      this.filterScrollTravel += scrollDelta;
      let shouldExpand: boolean = this.filterExpanded;
      if (currentOffset <= 1 || this.filterScrollTravel <= -12) {
        shouldExpand = true;
        this.syncBottomNavigation(false, currentOffset <= 1 ? '到达列表顶部' : '向上滚动');
      } else if (this.filterScrollTravel >= 12) {
        shouldExpand = false;
        this.syncBottomNavigation(true, '向下滚动');
      }
      if (shouldExpand !== this.filterExpanded) {
        this.filterScrollTravel = 0;
        this.filterAnimationUntil = Date.now() + 300;
        this.animateState(() => { this.filterExpanded = shouldExpand; });
        Logger.debug('CategoryPage', '列表滚动位置=' + currentOffset + 'vp，筛选区域=' +
        (shouldExpand ? '展开' : '收起') + '，标题保持显示，过渡=300ms');
      }
    } catch (error) {
      Logger.warn('CategoryPage', '读取分类滚动位置失败，保留顶部材质状态：' + String(error));
    }
  }

  private metadata(video: CategoryVideo): string {
    const ratingLabel: string = video.rating !== null && Number.isFinite(video.rating) ?
      '★' + video.rating.toFixed(1) : '暂无评分';
    const typeLabel: string = video.type || '类型未知';
    const yearLabel: string = video.date || '年份未知';
    return typeLabel + ' · ' + yearLabel + ' · ' + ratingLabel;
  }

  private cardAccessibility(video: CategoryVideo): string {
    return video.title + '，' + this.metadata(video) + '，地区：' + video.area +
    '，演员：' + video.actor + '，简介：' + video.intro + '，点击进入搜索';
  }

  private measureViewport(area: Area): void {
    const measuredSize: number = typeof area.width === 'number' ? area.width : Number.parseFloat(String(area.width));
    // 宿主和分类根容器均占满窗口，不重复扣减系统或导航安全区。
    if (Number.isFinite(measuredSize) && measuredSize > 0 && Math.abs(measuredSize - this.viewportSize) > 0.5) {
      this.viewportSize = measuredSize;
    }
  }

  @Builder
  private filterChip(layer: FilterLayer, label: string, index: number) {
    // 统一玻璃胶囊；选中态由 GlassChip 内部换算品牌淡底与描边。
    GlassChip({
      label: label,
      selected: this.indexFor(layer) === index,
      compact: !this.isTablet(),
      onTap: (): void => { this.selectFilter(layer, index); }
    })
      .accessibilityText(this.layerTitle(layer) + '，' + label + (this.indexFor(layer) === index ? '，已选中' : ''))
  }

  @Builder
  private filterRow(layer: FilterLayer) {
    Row({ space: 8 }) {
      Text(this.layerTitle(layer))
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(this.normalInk())
        .width('30vp')
        .maxLines(1)
        .flexShrink(0)
      Scroll(this.filterScrollers[layer]) {
        Row({ space: 6 }) {
          // 保留重复标签，使用层级和索引作 key，不丢弃任何选项。
          ForEach(this.labelsFor(layer), (label: string, index: number) => {
            this.filterChip(layer, label, index)
          }, (label: string, index: number) => String(layer) + '-' + index + '-' + label)
        }
          .height('36vp')
          .alignItems(VerticalAlign.Center)
      }
        .layoutWeight(1)
        .height('36vp')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .clip(true)
    }.width('100%')
  }

  @Builder
  private filterPanel() {
    // 只改变外层高度和透明度，保留五行筛选组件及各行原有滚动位置。
    Column() {
      Column({ space: 6 }) {
        // 顶层指示条：说明当前是筛选区，并用箭头提示展开/收起。
        Row({ space: 6 }) {
          Text('筛选')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selectedInk())
            .maxLines(1)
          Blank()
          Text(this.filterExpanded ? '收起' : '展开')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(this.normalInk())
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.arrow_down_circle'))
            .fontSize(Ui.fs('15vp', this.fontScale))
            .fontColor([this.normalInk()])
            .rotate({ angle: this.filterExpanded ? 180 : 0 })
            .onClick(() => { this.toggleFilterPanel(); })
            .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        }
          .width('100%')
          .height('28vp')
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.toggleFilterPanel(); })
        this.filterRow(FilterLayer.FORM)
        this.filterRow(FilterLayer.TYPE)
        this.filterRow(FilterLayer.AREA)
        this.filterRow(FilterLayer.YEAR)
        this.filterRow(FilterLayer.ORDER)
      }
        .width('100%')
        .flexShrink(0)
        .padding({ left: '14vp', right: '14vp', top: '10vp', bottom: '10vp' })
        .borderRadius(Ui.R_LG)
        .linearGradient({
          angle: 135,
          colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
        })
        .backdropBlur(this.glassRadius())
        .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
        .shadow({ radius: this.panelGlowRadius(), color: this.panelGlowTone(), offsetY: 8 })
        // 横向滚动筛选条必须裁切在圆角卡片内，避免末项胶囊画出卡片边界。
        .clip(true)
        .onAreaChange((_previous: Area, current: Area) => { this.measureFilterPanel(current); })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
    }
      .width('100%')
      .padding({ left: '14vp', right: '14vp', top: '6vp', bottom: '8vp' })
      .height(this.filterExpanded ? (this.filterPanelTall + 14) + 'vp' : '0vp')
      .flexShrink(0)
      .opacity(this.filterExpanded ? 1 : 0)
      .clip(true)
      .hitTestBehavior(this.filterExpanded ? HitTestMode.Default : HitTestMode.None)
      .accessibilityLevel(this.filterExpanded ? 'auto' : 'no-hide-descendants')
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private skeletonBlock(blockWide: string, blockTall: string, cornerRadius: string) {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width('38%')
        .height('180%')
        .linearGradient({
          angle: 90,
          colors: [[Ui.glassSheenClear(), 0], [Ui.accentGlow(this.darkTheme), 0.5], [Ui.glassSheenClear(), 1]]
        })
        .rotate({ angle: -18 })
        .translate({ x: (this.skeletonPhase === 0 ? -this.cardWide() * 0.75 : this.cardWide() * 0.75) + 'vp' })
        .opacity(0.45 + this.materialAlpha() * 0.55)
        .animation({ duration: 900, curve: Curve.EaseInOut })
    }
      .width(blockWide)
      .height(blockTall)
      .backgroundColor(Ui.accentSoft(this.darkTheme))
      .borderRadius(cornerRadius)
      .clip(true)
      .accessibilityLevel('no')
  }

  @Builder
  private cardTextSkeleton() {
    Column({ space: 9 }) {
      this.skeletonBlock('85%', '12vp', '6vp')
      this.skeletonBlock('92%', '14vp', '6vp')
      Column({ space: 6 }) {
        this.skeletonBlock('100%', '12vp', '6vp')
        this.skeletonBlock('78%', '12vp', '6vp')
      }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .accessibilityLevel('no')
      .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
  }

  @Builder
  private filmCardSkeleton() {
    Column({ space: 9 }) {
      Stack() {
        this.skeletonBlock('100%', '100%', '16vp')
      }
        .width(this.posterWide() + 'vp')
        .height(this.posterTall() + 'vp')
        .aspectRatio(2 / 3)
        .borderRadius('16vp')
        .clip(true)
      this.cardTextSkeleton()
    }
      .width(this.cardWide() + 'vp')
      .constraintSize({ maxWidth: '520vp', minHeight: '260vp' })
      .padding(this.cardInset())
      .borderRadius(Ui.R_MD)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 14, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .clip(true)
      .accessibilityLevel('no')
  }

  @Builder
  private posterPlaceholder(video: CategoryVideo, showSkeleton: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (showSkeleton) {
        this.skeletonBlock('100%', '100%', '16vp')
      } else {
        // 与 FilmTile 同一视觉语言：题材渐变底 + 题材首字水印 + 播放占位。
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 150,
            colors: [[Ui.genreTop(this.xingshi || '电影', this.darkTheme), 0],
              [Ui.genreBottom(this.xingshi || '电影', this.darkTheme), 1]]
          })
        Text(Ui.genreGlyph(this.xingshi || '电影'))
          .fontSize(Ui.fs(64 * this.textScale() + 'vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .opacity(0.16)
          .translate({ x: 26, y: -14 })
        // 顶部柔光：玻璃罩反光，跟随 Blank 贴在封面顶部。
        Column() {
          Column()
            .width('100%')
            .height('45%')
            .linearGradient({ angle: 180, colors: [[Ui.glassSheenTop(this.darkTheme), 0], [Ui.glassSheenClear(), 1]] })
            .opacity(0.5)
          Blank()
        }
          .width('100%')
          .height('100%')
        Column({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(Ui.fs(20 * this.textScale() + 'vp', this.fontScale))
            .fontColor(['#FFFFFF'])
            .padding('10vp')
            .backgroundColor('#26FFFFFF')
            .border({ width: 1, color: '#40FFFFFF' })
            .borderRadius('40vp')
          Text('暂无封面')
            .fontSize(Ui.fs(11 * this.textScale() + 'vp', this.fontScale))
            .fontColor('#E6FFFFFF')
            .maxLines(1)
        }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
      }
    }
      .width('100%')
      .height('100%')
      .accessibilityText(video.title + (showSkeleton ? '，封面加载中' : '，封面占位，蓝色播放图标'))
      .accessibilityLevel('no')
      .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
  }

  @Builder
  private filmCard(video: CategoryVideo) {
    Column({ space: 9 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (!video.img || this.failedImages.includes(video.key) || !this.loadedImageKeys.includes(video.key)) {
          this.posterPlaceholder(video, this.imagePending(video))
        }
        if (this.visibleImageKeys.includes(video.key) && video.img && !this.failedImages.includes(video.key)) {
          Image(video.img)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius('16vp')
            .clip(true)
            .opacity(this.loadedImageKeys.includes(video.key) ? 1 : 0)
            .animation({ duration: 300, curve: Curve.EaseInOut })
            .accessibilityText(video.title + '封面')
            .accessibilityLevel('no')
            .onComplete(() => { this.imageLoaded(video.key); })
            .onError(() => { this.imageFailed(video.key); })
            .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
        }
        // 底部压暗：保证角标与占位文案在亮画面上仍可读。
        if (this.loadedImageKeys.includes(video.key) && !this.failedImages.includes(video.key)) {
          Column() {
            Blank()
            Column()
              .width('100%')
              .height('40%')
              .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#8C000000', 1]] })
          }
            .width('100%')
            .height('100%')
        }
        // 豆瓣式评分角标
        if (video.rating !== null && Number.isFinite(video.rating)) {
          Row({ space: 3 }) {
            Text('★').fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme))
            Text(video.rating.toFixed(1))
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(1)
          }
            .height('22vp')
            .padding({ left: '8vp', right: '8vp' })
            .borderRadius('11vp')
            .backgroundColor('#33000000')
            .border({ width: 1, color: '#33FFFFFF' })
            .margin({ top: '8vp', right: '8vp' })
        }
      }
      // 图片、占位及骨架共用实际列宽推导的固定 2:3 容器，避免无界高度撑大图片。
        .width(this.posterWide() + 'vp')
        .height(this.posterTall() + 'vp')
        .aspectRatio(2 / 3)
        .borderRadius('16vp')
        .clip(true)
        .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
      if (this.imagePending(video)) {
        this.cardTextSkeleton()
      } else {
        Row({ space: 6 }) {
          GlassChip({ label: video.type || '类型未知', compact: true })
          Text(video.date || '年份未知')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(this.cardSecondary())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Text(video.title)
          .fontSize(Ui.fs('14vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.cardInk())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(video.intro)
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(this.cardSecondary())
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
      .width(this.cardWide() + 'vp')
      .constraintSize({ maxWidth: '520vp', minHeight: '260vp' })
      .padding(this.cardInset())
      .borderRadius(Ui.R_MD)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({
        radius: this.isDesktop() && this.hoveredKey === video.key ? 26 : 14,
        color: this.isDesktop() && this.hoveredKey === video.key ? Ui.accentGlow(this.darkTheme) : Ui.shadowSoft(this.darkTheme),
        offsetY: this.isDesktop() && this.hoveredKey === video.key ? 10 : 8
      })
      .translate({ y: this.isDesktop() && this.hoveredKey === video.key ? '-6vp' : '0vp' })
      .scale({ x: this.pressedKey === video.key ? 0.97 : 1, y: this.pressedKey === video.key ? 0.97 : 1 })
      .clip(true)
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
      .accessibilityGroup(true)
      .accessibilityText(this.cardAccessibility(video))
      .onVisibleAreaChange([0, 0.01], (isVisible: boolean, _ratio: number) => { this.imageVisibility(video.key, isVisible); })
      .onHover((isHover: boolean) => { this.hoveredKey = this.isDesktop() && isHover ? video.key : ''; })
      .onTouch((event: TouchEvent) => { this.pressedKey = event.type === TouchType.Down ? video.key : ''; })
      .onClick(() => {
      Logger.info('CategoryPage', '点击影视卡片，影视标题：' + video.title + '，准备跳转搜索页');
      this.openSearch(video.title);
    })
  }

  @Builder
  private flowFooter() {
    Row({ space: 8 }) {
      if (this.loadingMore) {
        LoadingProgress().width('20vp').height('20vp').color(Ui.accent(this.darkTheme)).accessibilityText('正在加载更多分类资源')
        Text('正在加载…').fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme)).maxLines(1)
      } else {
        Text(this.noMore ? '没有更多内容啦～' : this.pagingMessage || '上拉加载更多')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(this.noMore ? Ui.inkFaint(this.darkTheme) : Ui.inkSoft(this.darkTheme))
          .maxLines(1)
          .padding({ left: '14vp', right: '14vp', top: '8vp', bottom: '8vp' })
          .borderRadius('18vp')
          .backgroundColor(this.cardTone())
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
          .accessibilityText(this.noMore ? '没有更多内容啦' : this.pagingMessage || '上拉加载更多')
          .onClick(() => { if (!this.noMore) { this.loadNextPage(true); } })
      }
    }
      .width('100%')
      .height('52vp')
      .justifyContent(FlexAlign.Center)
      .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
  }

  @Builder
  private retryButton() {
    GhostButton({
      label: '重新加载',
      compact: true,
      onTap: (): void => { this.retryFirstPage(); }
    })
      .accessibilityText('重新加载，使用当前筛选条件重试分类请求')
  }

  @Builder
  private emptyState() {
    Column({ space: 12 }) {
      // 玻璃空态：圆盘柔光 + 标题 + 提示，失败时下方追加玻璃重试按钮。
      EmptyState({
        title: this.firstMessage || this.emptyMessage,
        hint: this.firstMessage ? '检查网络后点击下方按钮重试' : '换一组筛选条件，或稍后再来看看',
        icon: SymbolIcons.list()
      })
        .accessibilityText(this.firstMessage || this.emptyMessage)
      if (this.firstMessage) {
        this.retryButton()
      }
    }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: '16vp', right: '16vp', top: '16vp', bottom: '0vp' })
      .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底层：页面底色渐变 + 极光柔光，与首页共用同一张底片。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 1 : 0.9 })
      Column() {
        // 标题及搜索入口始终显示，仅其下方筛选面板随列表滚动收起或展开。
        TapUI({ title: '分类.筛选', showTabs: false, showSearch: true, viewportSize: this.viewportSize,
            topSafeInset: this.safeTop(), materialProgress: this.headerProgress,
            onSearch: () => { this.openSearch(''); } })
        this.filterPanel()
        Refresh({ refreshing: $$this.refreshing }) {
          Stack() {
            if (this.loadingFirst) {
              WaterFlow() {
                ForEach(this.skeletonKeys, (key: number) => {
                  FlowItem() {
                    this.filmCardSkeleton()
                  }
                    .width(this.cardWide() + 'vp')
                }, (key: number) => 'category-skeleton-' + key)
              }
                .columnsTemplate(this.columnTemplate())
                .columnsGap(this.columnGap() + 'vp')
                .rowsGap(this.rowGap() + 'vp')
                .width('100%')
                .height('100%')
                .padding({ left: '24vp', right: '24vp', top: '12vp', bottom: '0vp' })
                .scrollBar(BarState.Off)
                .accessibilityText('正在加载分类资源')
                .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
            } else if (this.fllba.length === 0) {
              this.emptyState()
            } else {
              Column() {
                if (this.firstMessage) {
                  Row() {
                    Row({ space: 10 }) {
                      Text(this.firstMessage).fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(this.normalInk()).layoutWeight(1).maxLines(2)
                      this.retryButton()
                    }
                      .layoutWeight(1)
                      .padding({ left: '14vp', right: '14vp', top: '8vp', bottom: '8vp' })
                      .borderRadius(Ui.R_LG)
                      .backgroundColor(this.panelTone())
                      .border({ width: 1, color: this.panelRimTone() })
                      .shadow({ radius: this.panelGlowRadius(), color: this.panelGlowTone(), offsetY: 4 })
                  }
                    .width('100%')
                    .padding({ left: '16vp', right: '16vp', top: '8vp', bottom: '8vp' })
                    .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
                }
                WaterFlow({ scroller: this.flowScroller, footer: this.flowFooter }) {
                  ForEach(this.fllba, (video: CategoryVideo) => {
                    // 条目按实际列宽布局，不使用整表百分比宽度的居中 Row，避免卡片向右偏移及裁切。
                    FlowItem() {
                      this.filmCard(video)
                    }
                      .width(this.cardWide() + 'vp')
                  }, (video: CategoryVideo) => video.key)
                }
                  .columnsTemplate(this.columnTemplate())
                  .columnsGap(this.columnGap() + 'vp')
                  .rowsGap(this.rowGap() + 'vp')
                  .width('100%')
                  .layoutWeight(1)
                  .constraintSize({ minHeight: '0vp' })
                  // 不再为底栏 / 手势条预留底部占位：卡片流铺到屏幕最底部，悬浮玻璃底栏只叠加显示。
                  .padding({ left: '24vp', right: '24vp', top: '12vp', bottom: '0vp' })
                  .scrollBar(BarState.Off)
                  .onReachEnd(() => { this.loadNextPage(); })
                  .onScrollStart(() => { this.beginFilterScroll(); })
                  .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => { this.updateHeaderProgress(scrollState); })
                  .onScrollStop(() => { this.updateHeaderProgress(); })
              }
                .width('100%')
                .height('100%')
                .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
            }
          }.width('100%').height('100%')
        }
          .width(this.listWide() + 'vp')
          .layoutWeight(1)
          .constraintSize({ minHeight: '0vp', maxWidth: this.flowMaxWide + 'vp' })
          .alignSelf(ItemAlign.Center)
          .onRefreshing(() => { this.refreshFirstPage(); })
          .accessibilityText('分类资源列表，支持下拉刷新和上拉加载更多')
      }
        .width('100%')
        .height('100%')
        .constraintSize({ minHeight: '0vp' })
    }
      .width('100%')
      .height('100%')
      .constraintSize({ minHeight: '0vp' })
    // 页面及列表延伸到系统栏和底部悬浮导航下层，不额外预留导航安全区。
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .backgroundColor(this.pageTone())
      .animation({ duration: 300, curve: Curve.EaseInOut })
      .onAreaChange((_previous: Area, current: Area) => { this.measureViewport(current); })
  }

  /** 手动点「收起 / 展开」：切换筛选面板。 */
  private toggleFilterPanel(): void {
    this.animateState(() => { this.filterExpanded = !this.filterExpanded; });
    Logger.debug('CategoryPage', '手动切换筛选区域=' + (this.filterExpanded ? '展开' : '收起'));
  }
}

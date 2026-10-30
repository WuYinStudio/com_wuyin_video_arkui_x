import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { DownloadService, DownloadRecord, DownloadState } from '../common/DownloadService';
import { Logger } from '../common/Logger';
import { ImmersiveService } from '../common/ImmersiveService';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui } from '../common/Ui';
import { AuroraBackdrop } from '../common/UiWidgets';
import { PlayHistoryPage } from './PlayHistoryPage';
import { FavoritePage } from './FavoritePage';
import { DownloadPage } from './DownloadPage';
import { TapUI } from './TapUI';

// 只负责管理页容器；记录、收藏、下载仍由原有子页面处理。
// 管理和分类共用从本页提取的 TapUI，不维护第二套顶部样式和交互。
@Component
export struct ManagePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveConfig') @Watch('materialChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('materialChanged') private darkTheme: boolean = true;
  // 保留宿主传参接口；全屏内容不使用系统栏或底部导航占位。
  @Prop embedded: boolean = false;
  @Prop bottomNavigationInset: number = 0;
  @StorageLink('favoriteVersion') @Watch('refreshLibrarySummary') private favoriteRevision: number = 0;
  @StorageLink('downloadVersion') @Watch('refreshLibrarySummary') private downloadRevision: number = 0;
  @Prop @Watch('initialTabChanged') initialTab: number = 0;
  @State private activeTab: number = 0;
  @State private viewportSize: number = 360;
  @State private favoriteCount: number = 0;
  @State private downloadCount: number = 0;
  @State private activeDownloadCount: number = 0;
  @State private completedDownloadCount: number = 0;
  private tabsController: TabsController = new TabsController();
  private readonly labels: string[] = ['观看历史', '个人收藏', '下载管理'];

  aboutToAppear(): void {
    try {
      void ImmersiveService.apply(true);
      this.activeTab = this.normalizedIndex(this.initialTab);
      NavigationScroll.selectManageTab(this.activeTab);
      this.refreshLibrarySummary();
      Logger.info('ManagePage', '进入全屏文件管理，内容延伸至底部导航下层，Tab=' + this.labels[this.activeTab]);
      this.materialChanged();
    } catch (error) {
      Logger.error('ManagePage', '初始化管理页沉浸布局失败：' + String(error));
    }
  }

  aboutToDisappear(): void {
    // 离开管理页不恢复旧系统栏，下一页继续使用全局沉浸配置。
    Logger.debug('ManagePage', '离开文件管理容器');
  }

  private refreshLibrarySummary(): void {
    // 容器与播放器、子页面观察相同版本号；不缓存独立任务或收藏副本。
    // 即使 TabContent 延迟创建，管理页摘要也会立即反映另一页面的操作。
    try {
      const records: DownloadRecord[] = DownloadService.snapshot();
      const favorites: number = AppState.favorites.length;
      const active: number = records.filter((item: DownloadRecord) => item.state === DownloadState.SNIFFING || item.state === DownloadState.QUEUED || item.state === DownloadState.RUNNING).length;
      const completed: number = records.filter((item: DownloadRecord) => item.state === DownloadState.COMPLETED).length;
      if (favorites !== this.favoriteCount) {
        Logger.debug('MANAGE_FAVORITE', '实时同步收藏数量：' + favorites);
      }
      if (records.length !== this.downloadCount || active !== this.activeDownloadCount || completed !== this.completedDownloadCount) {
        Logger.debug('MANAGE_DOWNLOAD', '实时同步下载摘要，总数=' + records.length + '，进行中=' + active + '，已完成=' + completed);
      }
      this.favoriteCount = favorites;
      this.downloadCount = records.length;
      this.activeDownloadCount = active;
      this.completedDownloadCount = completed;
    } catch (error) {
      Logger.error('MANAGE_SYNC', '同步收藏和下载摘要失败：' + String(error));
    }
  }

  private summaryText(): string {
    return this.activeTab === 1
      ? '已收藏 ' + this.favoriteCount + ' 部影片 · 与播放器实时同步'
      : '共 ' + this.downloadCount + ' 集 · 进行中 ' + this.activeDownloadCount + ' 集 · 已完成 ' + this.completedDownloadCount + ' 集';
  }

  private normalizedIndex(index: number): number {
    if (!Number.isFinite(index)) {
      return 0;
    }
    return Math.max(0, Math.min(this.labels.length - 1, Math.floor(index)));
  }

  private initialTabChanged(): void {
    this.selectTab(this.normalizedIndex(this.initialTab));
  }

  private materialChanged(): void {
    try {
      // 同步材质时仍保持全屏沉浸布局，不因配置变化恢复系统栏避让。
      void ImmersiveService.apply(true);
      Logger.info('ManagePage', (this.materialActive() ? '开启' : '关闭') + '管理页沉浸材质，强度=' + this.materialScale());
    } catch (error) {
      Logger.error('ManagePage', '同步管理页导航材质失败：' + String(error));
    }
  }

  private materialScale(): number {
    if (!this.immersiveConfig.immersiveEnable) {
      return 0;
    }
    const configured: number = this.immersiveConfig.immersiveBlur;
    return Number.isFinite(configured) ? Math.max(0, Math.min(1, configured / 40)) : 0.5;
  }

  private materialActive(): boolean {
    return this.immersiveConfig.immersiveEnable && this.materialScale() > 0;
  }

  private selectTab(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.labels.length) {
      Logger.warn('ManagePage', '忽略无效管理 Tab：' + index);
      return;
    }
    if (index === this.activeTab) {
      return;
    }
    try {
      this.activeTab = index;
      NavigationScroll.selectManageTab(index);
      this.tabsController.changeIndex(index);
      Logger.info('ManagePage', '选择管理 Tab：' + this.labels[index]);
    } catch (error) {
      Logger.error('ManagePage', '切换管理 Tab 失败：' + String(error));
    }
  }

  private pageChanged(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.labels.length || index === this.activeTab) {
      return;
    }
    try {
      this.activeTab = index;
      NavigationScroll.selectManageTab(index);
      Logger.info('ManagePage', '滑动切换管理 Tab：' + this.labels[index]);
    } catch (error) {
      Logger.error('ManagePage', '同步管理 Tab 失败：' + String(error));
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 1 : 0.9 })
      Column({ space: '14vp' }) {
        TapUI({
          title: '文件管理',
            showTabs: true,
            showSearch: false,
            viewportSize: this.viewportSize,
            activeTab: this.activeTab,
            labels: this.labels,
            favoriteCount: this.favoriteCount,
            downloadCount: this.downloadCount,
            onTabSelect: (index: number): void => { this.selectTab(index); }
        })

        if (this.activeTab !== 0) {
          Text(this.summaryText())
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
            .width('100%')
            .flexShrink(0)
            .padding({ left: '20vp', right: '20vp' })
            .maxLines(2);
        }

        // 每个子页撑满 Tabs 分配的剩余空间，不以卡片内容或固定数值撑高页面。
        // embedded 模式不补偿安全区；列表末项允许进入底部导航下层（末尾额外预留底栏占位）。
        Tabs({ barPosition: BarPosition.Start, index: this.activeTab, controller: this.tabsController }) {
          TabContent() {
            Column() {
              PlayHistoryPage({ embedded: true }).width('100%').height('100%');
            }.width('100%').height('100%').constraintSize({ minHeight: '0vp' });
          }
          TabContent() {
            Column() {
              FavoritePage({ embedded: true }).width('100%').height('100%');
            }.width('100%').height('100%').constraintSize({ minHeight: '0vp' });
          }
          TabContent() {
            Column() {
              DownloadPage({ embedded: true }).width('100%').height('100%');
            }.width('100%').height('100%').constraintSize({ minHeight: '0vp' });
          }
        }
          .barHeight('0vp')
          .width('100%')
          .layoutWeight(1)
          .constraintSize({ minHeight: '0vp' })
          .clip(true)
          .scrollable(true)
          .animationDuration(260)
          // 不再为底栏 / 手势条预留底部占位：列表铺到屏幕最底部，悬浮玻璃底栏只叠加显示。
          .onChange((index: number) => {
          this.pageChanged(index);
        });
      }
        .width('100%')
        .height('100%')
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
    // 根容器扩展到系统栏及挖孔区域，不增加防遮挡或导航占位。
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .onAreaChange((_previous: Area, current: Area) => {
      try {
        const nextSize: number = Number(current.width);
        if (Number.isFinite(nextSize) && nextSize > 0 && nextSize !== this.viewportSize) {
          this.viewportSize = nextSize;
        }
      } catch (error) {
        Logger.error('ManagePage', '更新管理页全屏布局失败：' + String(error));
      }
    });
  }
}

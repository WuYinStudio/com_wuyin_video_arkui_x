import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { GlassSearchEntry, SegmentedGlassTabs } from '../common/UiWidgets';

/**
 * 管理 / 分类页共用的顶部导航。
 *
 * 视觉：页标题 + 液态玻璃搜索入口 + 分段玻璃 Tab（选中项是移动的玻璃胶囊）。
 * 行为：与旧版完全一致 —— 标题、搜索入口显隐、Tab 选中回调、收藏/下载数量无障碍文案，
 *      以及主题/材质变化时同步窗口沉浸。
 */
@Component
export struct TapUI {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveConfig') @Watch('materialChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('materialChanged') private darkTheme: boolean = true;
  @StorageLink('themeMode') private themeMode: string = 'system';
  @Prop title: string = '文件管理';
  @Prop showTabs: boolean = true;
  @Prop showSearch: boolean = false;
  @Prop viewportSize: number = 360;
  // 默认值保持管理页原有布局；分类页传入实时状态栏安全区和滚动进度。
  @Prop topSafeInset: number = 0;
  @Prop materialProgress: number = 0;
  @Prop activeTab: number = 0;
  @Prop labels: string[] = ['观看历史', '个人收藏', '下载管理'];
  @Prop favoriteCount: number = 0;
  @Prop downloadCount: number = 0;
  onTabSelect: (index: number) => void = (_index: number): void => {};
  onSearch: () => void = (): void => {};

  private materialChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('TapUI', '同步顶部导航材质失败：' + String(error));
    }
  }

  private ink(): ResourceColor {
    if (!this.showTabs) {
      return this.themeMode === 'system' ? $r('app.color.category_unselected_text') :
        this.darkTheme ? $r('app.color.category_unselected_dark') : $r('app.color.category_unselected_light');
    }
    return Ui.ink(this.darkTheme);
  }

  private tablet(): boolean { return Ui.isTablet(this.viewportSize); }
  private gutter(): number { return Ui.gutter(this.viewportSize); }
  private safeInset(): number {
    return !this.showTabs && Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 0;
  }
  private trackWidth(): number {
    return Math.max(200, Math.min(this.viewportSize - this.gutter() * 2, 720));
  }
  private titleSize(): string { return this.tablet() ? '30vp' : '26vp'; }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(this.titleSize())
            .fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.showTabs ? '收藏、历史与离线下载集中管理' : '按题材、地区、年份和排序快速筛选')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      if (this.showSearch) {
        GlassSearchEntry({
          placeholder: '搜索影片 / 演员 / 导演',
          onTap: (): void => { this.onSearch(); }
        })
      }
      if (this.showTabs) {
        Row() {
          SegmentedGlassTabs({
            labels: this.labels,
            active: this.activeTab,
            trackWidth: this.trackWidth(),
            trackHeight: this.tablet() ? 48 : 44,
            compact: this.labels.length > 4,
            onSelect: (index: number): void => { this.onTabSelect(index); }
          })
        }
          .width('100%')
          .justifyContent(FlexAlign.Start)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: this.gutter(),
        right: this.gutter(),
        top: this.safeInset() + (this.tablet() ? 22 : 18),
        bottom: 10
      })
  }
}

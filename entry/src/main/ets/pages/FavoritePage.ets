import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig, WatchRecord } from '../common/AppState';
import { Logger } from '../common/Logger';
import { ImmersiveService } from '../common/ImmersiveService';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GlassIconButton } from '../common/UiWidgets';
import { SearchVideoItem } from './PlayerPage';
import { SymbolIcons } from '../common/SymbolIcons';

/**
 * 个人收藏（文件管理页内嵌子页之一）。
 *
 * 视觉：内容区改为液态玻璃卡片栅格 —— 每张卡是半透明玻璃 + 1vp 亮描边 + 柔和投影，
 *      海报 14vp 圆角、底部叠主色渐变进度条，名称/播放状态/进度分三层排版，
 *      「取消收藏」是卡片底部的玻璃胶囊（危险色文字），按下整卡内缩到 0.97。
 * 行为：收藏数据来源、播放路由、取消收藏确认框、长按取消与列表滚动上报全部保持原样。
 */
@Component
export struct FavoritePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop embedded: boolean = false;
  @StorageLink('page') private currentRoute: string = 'home';
  @StorageLink('immersiveConfig') @Watch('syncImmersive') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('syncImmersive') private darkTheme: boolean = true;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @StorageLink('immersiveLeftInset') private leftSafeInset: number = 0;
  @StorageLink('immersiveRightInset') private rightSafeInset: number = 0;
  @StorageLink('favoriteVersion') @Watch('refresh') private favoriteRevision: number = 0;
  @StorageLink('historyVersion') @Watch('refresh') private dataVersion: number = 0;
  @State private items: WatchRecord[] = [];
  @State private viewportSize: number = 360;
  @State private openingId: string = '';
  @State private pendingRemovalId: string = '';
  // 仅用于按下反馈（scale 0.97），不参与任何收藏业务判断。
  @State private pressedId: string = '';
  private readonly favoriteScroller: Scroller = new Scroller();
  private disposed: boolean = false;
  private lifecycleVersion: number = 0;

  aboutToAppear(): void {
    try {
      this.disposed = false;
      this.lifecycleVersion++;
      this.openingId = '';
      this.pendingRemovalId = '';
      this.pressedId = '';
      this.syncImmersive();
      this.refresh();
      if (!this.embedded) { NavigationScroll.reset(this.currentRoute, '进入个人收藏'); }
      Logger.info('FAVORITE', '进入个人收藏');
    } catch (error) {
      Logger.error('FAVORITE', '初始化收藏页面失败：' + String(error));
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.lifecycleVersion++;
    this.openingId = '';
    this.pendingRemovalId = '';
    this.pressedId = '';
  }

  private syncImmersive(): void {
    try { void ImmersiveService.apply(); }
    catch (error) { Logger.error('FAVORITE', '同步沉浸配置失败：' + String(error)); }
  }

  private safeInset(value: number, fallback: number = 0): number {
    return Number.isFinite(value) ? Math.max(0, value) : fallback;
  }

  private refresh(): void {
    if (this.disposed) { return; }
    try {
      // 收藏变更直接观察共享版本，不依赖播放历史保存或重新进入管理页。
      this.items = AppState.favorites.map((id: number): WatchRecord => {
        const saved = AppState.favoriteRecords.find((item: WatchRecord) => item.id === id)
          || AppState.history.find((item: WatchRecord) => item.id === id);
        if (saved) { return saved; }
        const film = AppState.films.find((item) => item.id === id);
        const record = new WatchRecord();
        record.id = id;
        record.name = film?.name || '未命名收藏';
        if (film?.source) {
          record.vodId = String(film.id);
          record.wzlj = '正片$' + film.source;
        }
        return record;
      });
    } catch (error) { Logger.error('FAVORITE_SYNC', '刷新收藏列表失败：' + String(error)); }
  }

  // ---------- 设计令牌（深浅模式统一由 Ui 决定，页面内不再出现写死的十六进制色） ----------
  private ink(): string { return Ui.ink(this.darkTheme); }
  private secondary(): string { return Ui.inkSoft(this.darkTheme); }
  private accent(): string { return Ui.accent(this.darkTheme); }
  private selectedSurface(): string { return Ui.accentSoft(this.darkTheme); }
  private destructiveInk(): string { return Ui.danger(this.darkTheme); }
  private panel(): string { return Ui.glassTintSoft(this.darkTheme); }
  private columnTemplate(): string {
    const count: number = Math.max(2, Math.min(6, Math.floor(this.viewportSize / 150)));
    return new Array<string>(count).fill('1fr').join(' ');
  }

  // ---------- 卡片内进度（只读既有记录字段，不改变数据） ----------
  private hasProgress(record: WatchRecord): boolean {
    return Number.isFinite(record.duration) && record.duration > 0;
  }
  private progressPercent(record: WatchRecord): number {
    if (!this.hasProgress(record) || !Number.isFinite(record.position)) { return 0; }
    return Math.max(0, Math.min(100, (record.position / record.duration) * 100));
  }
  private progressWidth(record: WatchRecord): string {
    return this.progressPercent(record).toFixed(1) + '%';
  }
  private clockText(secondsValue: number): string {
    const safe: number = Number.isFinite(secondsValue) ? Math.floor(Math.max(0, secondsValue)) : 0;
    const minutes: number = Math.floor(safe / 60);
    const rest: number = safe % 60;
    return minutes + ':' + (rest < 10 ? '0' + rest : String(rest));
  }
  private progressLabel(record: WatchRecord): string {
    return this.clockText(record.position) + ' / ' + this.clockText(record.duration);
  }

  private toast(message: string): void {
    if (this.disposed) { return; }
    try { this.getUIContext().getPromptAction().showToast({ message: message }); }
    catch (error) { Logger.warn('FAVORITE_NOTICE', String(error)); }
  }
  private async open(record: WatchRecord): Promise<void> {
    if (this.disposed || this.openingId || this.pendingRemovalId) { return; }
    if (typeof record.vodId !== 'string' || !record.vodId.trim() || typeof record.wzlj !== 'string' || !record.wzlj.trim()) {
      Logger.warn('FAVORITE', '旧收藏缺少播放资源');
      this.toast('这条旧收藏缺少播放地址，请重新搜索影片');
      return;
    }
    const video: SearchVideoItem = {
      vodId: record.vodId, tilie: record.name, yhm: record.name, feng: record.cover,
        sfeng: '', data: '', wzlj: record.wzlj, genxi: '', zyuanuuu: ''
    };
    const pageVersion: number = this.lifecycleVersion;
    this.openingId = String(record.id);
    try {
      Logger.info('FAVORITE', '打开收藏影片：' + record.name);
      await router.pushUrl({ url: 'pages/PlayerPage', params: video });
    } catch (error) {
      Logger.error('FAVORITE', '打开收藏失败：' + String(error));
      if (!this.disposed && pageVersion === this.lifecycleVersion) { this.toast('打开播放器失败'); }
    } finally {
      if (pageVersion === this.lifecycleVersion) { this.openingId = ''; }
    }
  }
  private async confirmRemove(record: WatchRecord): Promise<void> {
    if (this.disposed || this.pendingRemovalId || this.openingId) { return; }
    const pageVersion: number = this.lifecycleVersion;
    this.pendingRemovalId = String(record.id);
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '取消收藏', message: '是否取消收藏「' + record.name + '」？',
          buttons: [{ text: '保留', color: this.secondary() }, { text: '取消收藏', color: this.destructiveInk() }]
      });
      if (this.disposed || pageVersion !== this.lifecycleVersion || result.index !== 1) { return; }
      // 对话框等待期间播放器可能已取消收藏，使用幂等操作，不能意外重新收藏。
      AppState.setFavorite(record.id, false);
      this.refresh();
      Logger.info('FAVORITE', '取消收藏并同步播放器：' + record.name);
      this.toast('已取消收藏');
    } catch (error) {
      Logger.error('FAVORITE', '取消收藏失败：' + String(error));
      if (!this.disposed && pageVersion === this.lifecycleVersion) { this.toast('取消收藏失败'); }
    } finally {
      if (pageVersion === this.lifecycleVersion) { this.pendingRemovalId = ''; }
    }
  }

  /** 收藏卡：海报 + 渐变进度 + 名称 + 状态/进度 + 玻璃胶囊删除按钮。 */
  @Builder
  private favoriteCard(record: WatchRecord) {
    Column({ space: '10vp' }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(record.cover || $r('app.media.icon')).width('100%').aspectRatio(2 / 3)
          .objectFit(ImageFit.Cover).borderRadius('14vp').accessibilityText(record.name + '封面');
        if (this.hasProgress(record)) {
          Row() {
            Row() {
              Row()
                .width(this.progressWidth(record))
                .height('100%')
                .borderRadius('2vp')
                .linearGradient({ angle: 110, colors: [[Ui.accent(this.darkTheme), 0], [Ui.accentStrong(this.darkTheme), 1]] })
            }
              .width('100%')
              .height('4vp')
              .borderRadius('2vp')
              .backgroundColor('#4D000000')
              .clip(true)
          }
            .width('100%')
            .padding({ left: '8vp', right: '8vp', bottom: '8vp' })
        }
      }
        .width('100%')
      Column({ space: '2vp' }) {
        Text(record.name).width('100%').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(this.ink())
          .fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Row({ space: '6vp' }) {
          Text(this.openingId === String(record.id) ? '正在打开…' : '点击播放')
            .fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.accent()).maxLines(1);
          Blank()
          if (this.hasProgress(record)) {
            Text(this.progressLabel(record)).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(this.secondary())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
      }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      // 保留原有的显式取消入口（含“确认中…”进行态与禁用判断），视觉上收成玻璃胶囊。
      Button(this.pendingRemovalId === String(record.id) ? '确认中…' : '取消收藏')
        .width('100%').height('34vp').fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(this.destructiveInk())
        .backgroundColor(this.panel()).borderRadius('17vp')
        .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
        .enabled(!this.pendingRemovalId && !this.openingId)
        .accessibilityText('取消收藏' + record.name)
        .onClick(() => { void this.confirmRemove(record); });
    }
      .width('100%')
      .padding('9vp')
      .borderRadius('20vp')
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 14, color: Ui.shadowSoft(this.darkTheme), offsetY: 7 })
      .scale({
        x: this.pressedId === String(record.id) ? 0.97 : 1,
        y: this.pressedId === String(record.id) ? 0.97 : 1
      })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(record.name + '，点击播放，可使用取消收藏按钮或长按取消收藏')
      .onTouch((event: TouchEvent) => {
        this.pressedId = event.type === TouchType.Down ? String(record.id) : '';
      })
      .onClick(() => { void this.open(record); })
      .gesture(LongPressGesture().onAction(() => { void this.confirmRemove(record); }));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底片：页面底色竖向渐变（内嵌页不自带极光遮罩，这里加上柔光但不拦截手势）。
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 0.9 : 0.7 })
      Column({ space: '12vp' }) {
        if (!this.embedded) {
          Row({ space: '10vp' }) {
            GlassIconButton({
              iconSize: 36,
              symbol: $r('sys.symbol.chevron_left_circle'),
              accessibilityLabel: '返回',
              onTap: (): void => { AppState.go('home'); }
            })
            Text('个人收藏').fontSize(Ui.fs('20vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
              .layoutWeight(1).maxLines(1);
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
        }
        // 摘要玻璃胶囊：保持原来的汇总文案，只换成玻璃材质。
        Row({ space: '8vp' }) {
          Row() {
            Text('★').fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme));
          }
            .width('22vp').height('22vp').borderRadius('11vp').justifyContent(FlexAlign.Center)
            .backgroundColor(this.selectedSurface())
            .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
          Text('共 ' + this.items.length + ' 部 · 点击播放，按钮或长按取消收藏')
            .fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary()).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
          .width('100%')
          .height('34vp')
          .padding({ left: '6vp', right: '12vp' })
          .borderRadius('17vp')
          .backgroundColor(this.panel())
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .shadow({ radius: 10, color: Ui.shadowSoft(this.darkTheme), offsetY: 4 })
        if (this.items.length === 0) {
          Column() {
            EmptyState({ title: '暂无收藏', hint: '在播放器中收藏喜欢的影片', icon: SymbolIcons.trophy() })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          Grid(this.favoriteScroller) {
            ForEach(this.items, (record: WatchRecord) => {
              GridItem() { this.favoriteCard(record); }
            }, (record: WatchRecord) => String(record.id));
          }.columnsTemplate(this.columnTemplate()).columnsGap('12vp').rowsGap('12vp')
            .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
            .onScrollStart(() => {
            NavigationScroll.begin(this.embedded ? 'manage' : this.currentRoute, 'favorites', this.favoriteScroller);
          })
            .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
            NavigationScroll.report(this.embedded ? 'manage' : this.currentRoute, 'favorites', this.favoriteScroller, scrollState);
          })
            .onScrollStop(() => {
            NavigationScroll.end(this.embedded ? 'manage' : this.currentRoute, 'favorites', this.favoriteScroller);
          });
        }
      }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      // 嵌入管理页时安全区由宿主统一处理，列表不再保留固定底部空白。
        .padding({
        left: (Ui.gutter(this.viewportSize) + (this.embedded ? 0 : this.safeInset(this.leftSafeInset))) + 'vp',
          right: (Ui.gutter(this.viewportSize) + (this.embedded ? 0 : this.safeInset(this.rightSafeInset))) + 'vp',
          top: (8 + (this.embedded ? 0 : this.safeInset(this.topSafeInset, 24))) + 'vp',
          bottom: (this.embedded ? 0 : this.safeInset(this.bottomSafeInset, 16)) + 'vp'
      })
    }
      .width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], this.embedded ? [] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_old: Area, current: Area) => {
      try {
        const next: number = Number(current.width);
        if (Number.isFinite(next) && next > 0) { this.viewportSize = next; }
      } catch (error) {
        Logger.error('FAVORITE', '更新收藏列表布局失败：' + String(error));
      }
    });
  }
}

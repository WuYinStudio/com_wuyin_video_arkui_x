import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { AppState, PlayerImmersiveConfig, WatchRecord } from '../common/AppState';
import { ShareService } from '../common/ShareService';
import { SearchVideoItem } from './PlayerPage';
import { HistoryArchive } from '../common/HistoryArchive';
import { Logger } from '../common/Logger';
import { ImmersiveService } from '../common/ImmersiveService';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GlassIconButton, PrimaryButton } from '../common/UiWidgets';
import { SymbolIcons } from '../common/SymbolIcons';

// 与播放器的 player_watch_history 存储格式一致，避免匿名对象作为恢复数据类型。
interface HistoryPlaybackResume {
  vodId: string;
  selectIndex: number;
  playSec: number;
  videoName: string;
}

/**
 * 观看历史（文件管理页内嵌子页之一）。
 *
 * 视觉：顶部说明与多选按钮改成玻璃胶囊，批量操作是玻璃胶囊条，
 *      保留规则输入改成玻璃胶囊输入框（仍是 Number 键盘、仍是同一份状态），
 *      历史卡为玻璃卡片：封面 14vp 圆角 + 名称 + 时间 + 集数胶囊 + 主色渐变进度 + 播放角标，
 *      右侧滑动操作换成玻璃圆钮（分享用 accent，删除用 danger）。
 * 行为：清除/批量/删除/播放/分享/导入导出/时长与条数设置全部保持原样。
 */
@Component
export struct PlayHistoryPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop embedded: boolean = false;
  @StorageLink('immersiveConfig') @Watch('syncImmersive') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('syncImmersive') private dark: boolean = true;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @StorageLink('immersiveLeftInset') private leftSafeInset: number = 0;
  @StorageLink('immersiveRightInset') private rightSafeInset: number = 0;
  @StorageLink('historyVersion') @Watch('historyChanged') private historyVersion: number = 0;
  @StorageLink('historyLimit') private storedLimit: number = 100;
  @StorageLink('historyExpiryDays') private storedExpiry: number = 0;
  @State private records: WatchRecord[] = [];
  @State private viewportWidth: number = 360;
  @State private selected: number[] = [];
  @State private selecting: boolean = false;
  @State private limitText: string = '100';
  @State private expiryText: string = '0';
  @State private busy: boolean = false;
  // 仅用于卡片按下反馈（scale 0.97），不参与任何历史业务判断。
  @State private pressedId: string = '';
  // 管理页历史列表独立上报 vp 绝对位置，不影响右滑、多选及独立页面的交互。
  private readonly historyScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    try {
      this.syncImmersive();
      this.limitText = String(AppState.historyLimit);
      this.expiryText = String(AppState.historyExpiryDays);
      this.refresh();
      Logger.info('HISTORY', '进入播放历史');
    } catch (error) {
      Logger.error('HISTORY', '初始化播放历史失败：' + String(error));
    }
  }
  private syncImmersive(): void {
    try { void ImmersiveService.apply(); }
    catch (error) { Logger.error('HISTORY', '同步沉浸配置失败：' + String(error)); }
  }
  private safeInset(value: number): number { return Number.isFinite(value) ? Math.max(0, value) : 0; }
  private historyChanged(): void { this.refresh(); }
  private refresh(): void {
    try {
      AppState.cleanHistory();
      this.records = AppState.history.slice();
      this.selected = this.selected.filter((id: number) => this.records.some((record: WatchRecord) => record.id === id));
    } catch (error) {
      Logger.error('HISTORY', '刷新播放历史失败：' + String(error));
    }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ message: message }); }
  private tablet(): boolean { return this.viewportWidth >= 600; }
  private columns(): number { return this.viewportWidth >= 1000 ? 3 : this.tablet() ? 2 : 1; }
  private cardWidth(): number {
    return Math.max(0, (this.viewportWidth - (this.tablet() ? 48 : 32) - (this.columns() - 1) * 12) / this.columns());
  }
  private coverWidth(): number { return Math.min(this.tablet() ? 156 : 128, Math.max(64, this.cardWidth() * 0.34)); }
  // ---------- 设计令牌（深浅模式统一由 Ui 决定，页面内不再出现写死的十六进制色） ----------
  private ink(): string { return Ui.ink(this.dark); }
  private secondary(): string { return Ui.inkSoft(this.dark); }
  private panel(): string { return Ui.glassTintSoft(this.dark); }
  private materialScale(): number {
    const configured: number = this.immersiveConfig.immersiveBlur;
    return this.immersiveConfig.immersiveEnable && Number.isFinite(configured)
      ? Math.max(0, Math.min(1, configured / 50)) : 0;
  }
  private title(record: WatchRecord): string { return record.name || AppState.films.find(film => film.id === record.id)?.name || '未知影片'; }
  private progress(record: WatchRecord): string {
    const seconds: number = Math.floor(Math.max(0, record.position));
    const elapsed: string = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
    return '上次播放 ' + elapsed + (record.duration > 0 ? ' / ' + Math.floor(record.duration / 60) + ':' + String(Math.floor(record.duration % 60)).padStart(2, '0') : '');
  }
  /** 进度条宽度（百分比字符串）；无时长时整条按 0 处理，不伪造进度。 */
  private hasProgress(record: WatchRecord): boolean {
    return Number.isFinite(record.duration) && record.duration > 0;
  }
  private progressPercent(record: WatchRecord): number {
    if (!this.hasProgress(record) || !Number.isFinite(record.position)) { return 0; }
    return Math.max(0, Math.min(100, (record.position / record.duration) * 100));
  }
  private barWidth(record: WatchRecord): string {
    return this.progressPercent(record).toFixed(1) + '%';
  }
  private toggle(id: number): void {
    this.selected = this.selected.includes(id) ? this.selected.filter((value: number) => value !== id) : this.selected.concat(id);
  }
  private async open(record: WatchRecord): Promise<void> {
    if (this.selecting) { this.toggle(record.id); return; }
    if (!record.vodId || !record.wzlj) {
      Logger.warn('HISTORY', '旧记录缺少播放地址，记录=' + record.id);
      this.toast('这条旧记录缺少播放地址，请重新搜索影片播放');
      return;
    }
    const params: SearchVideoItem = { vodId: record.vodId, yhm: this.title(record), tilie: this.title(record),
        feng: record.cover || '', sfeng: '', data: '', wzlj: record.wzlj, genxi: '', zyuanuuu: '' };
    const resume: HistoryPlaybackResume = {
      vodId: record.vodId,
        selectIndex: Math.max(0, Math.floor(record.episode) - 1),
        playSec: Math.max(0, record.position),
        videoName: this.title(record)
    };
    try {
      const store = await preferences.getPreferences(this.context(), 'player_watch_history');
      await store.put('vod_' + record.vodId, JSON.stringify(resume));
      await store.flush();
      const film = AppState.films.find(item => item.id === record.id);
      if (film) { AppState.current = film; }
      Logger.info('HISTORY', '恢复播放：' + this.title(record) + '，第' + record.episode + '集');
      await router.pushUrl({ url: 'pages/PlayerPage', params: params });
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('打开播放器失败'); }
  }
  private async share(record: WatchRecord): Promise<void> {
    if (!record.vodId || !record.wzlj) {
      Logger.warn('HISTORY', '旧记录缺少分享地址，记录=' + record.id);
      this.toast('这条旧记录缺少分享链接');
      return;
    }
    const episodes: string[] = record.wzlj.split('#').map((item: string) => item.trim())
      .filter((item: string) => { const separator: number = item.indexOf('$'); return separator > 0 && separator < item.length - 1; });
    const entry: string = episodes[Math.max(0, Math.min(episodes.length - 1, Math.floor(record.episode) - 1))] || '';
    const separator: number = entry.indexOf('$');
    if (separator <= 0) { this.toast('这条记录没有可分享的播放链接'); return; }
    const video: SearchVideoItem = { vodId: record.vodId, yhm: this.title(record), tilie: this.title(record),
        feng: record.cover || '', sfeng: '', data: '', wzlj: record.wzlj, genxi: '', zyuanuuu: '' };
    try {
      Logger.info('HISTORY', '分享：' + this.title(record));
      await ShareService.shareEpisode(this.context(), video, entry.substring(0, separator).trim(), entry.substring(separator + 1).trim());
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('分享未完成'); }
  }
  private async remove(ids: number[]): Promise<void> {
    try {
      await AppState.removeHistory(ids);
      this.refresh();
      Logger.info('HISTORY', '删除历史，条数=' + ids.length);
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('删除失败'); }
  }
  private async confirmClear(): Promise<void> {
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({ title: '清空播放历史？', message: '此操作无法撤销。',
          buttons: [{ text: '取消', color: this.secondary() }, { text: '清空', color: Ui.danger(this.dark) }] });
      if (result.index === 1) {
        await AppState.clearHistory(); this.selected = []; this.selecting = false; this.refresh();
        Logger.info('HISTORY', '清空播放历史');
      }
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('清空失败'); }
  }
  private async saveOptions(): Promise<void> {
    try {
      await AppState.setHistoryOptions(Number(this.limitText), Number(this.expiryText));
      this.limitText = String(AppState.historyLimit); this.expiryText = String(AppState.historyExpiryDays);
      this.refresh(); this.toast('播放历史规则已保存');
      Logger.info('HISTORY', '更新保留规则');
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('保存失败'); }
  }
  private async exportRecords(): Promise<void> {
    if (this.busy) { return; } this.busy = true;
    try {
      AppState.cleanHistory();
      if (await HistoryArchive.exportFile(this.context(), AppState.history)) { this.toast('播放历史已导出'); }
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('导出失败：' + String(error)); }
    finally { this.busy = false; }
  }
  private async importRecords(): Promise<void> {
    if (this.busy) { return; } this.busy = true;
    try {
      const incoming: WatchRecord[] | undefined = await HistoryArchive.importFile(this.context());
      if (!incoming) { return; }
      const result = await this.getUIContext().getPromptAction().showDialog({ title: '导入播放历史',
          message: '读取到 ' + incoming.length + ' 条记录。请选择合并或覆盖现有记录。',
          buttons: [{ text: '取消', color: this.secondary() }, { text: '合并', color: Ui.success(this.dark) },
            { text: '覆盖', color: Ui.danger(this.dark) }] });
      if (result.index === 1 || result.index === 2) {
        await AppState.importHistory(incoming, result.index === 2);
        this.refresh(); this.toast('导入完成');
        Logger.info('HISTORY', result.index === 2 ? '覆盖导入历史' : '合并导入历史');
      }
    } catch (error) { Logger.error('HISTORY', String(error)); this.toast('导入失败：' + String(error)); }
    finally { this.busy = false; }
  }

  /** 右滑操作：玻璃圆钮，分享用主色、删除用危险色，回调仍是 share / remove。 */
  @Builder private historyActions(record: WatchRecord) {
    Row({ space: '8vp' }) {
      Button('分享').width('56vp').height('56vp').fontSize(Ui.fs('11.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(Ui.accent(this.dark)).backgroundColor(this.panel())
        .borderRadius('28vp')
        .border({ width: 1, color: Ui.glassRingAccent(this.dark) })
        .shadow({ radius: 10, color: Ui.shadowSoft(this.dark), offsetY: 4 })
        .accessibilityText('分享')
        .onClick(() => { void this.share(record); });
      Button('删除').width('56vp').height('56vp').fontSize(Ui.fs('11.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(Ui.danger(this.dark)).backgroundColor(this.panel())
        .borderRadius('28vp')
        .border({ width: 1, color: Ui.danger(this.dark) })
        .shadow({ radius: 10, color: Ui.shadowSoft(this.dark), offsetY: 4 })
        .accessibilityText('删除')
        .onClick(() => { void this.remove([record.id]); });
    }.padding({ left: '8vp', right: '12vp' }).alignItems(VerticalAlign.Center);
  }

  @Builder private historyCard(record: WatchRecord) {
    Row({ space: '10vp' }) {
      if (this.selecting) {
        Checkbox().select(this.selected.includes(record.id)).selectedColor(Ui.accent(this.dark))
          .onChange(() => { this.toggle(record.id); });
      }
      Image(record.cover || $r('app.media.icon')).width(this.coverWidth() + 'vp').aspectRatio(16 / 9)
        .objectFit(ImageFit.Cover).borderRadius('14vp')
        .border({ width: 1, color: Ui.glassRingSoft(this.dark) });
      Column({ space: '5vp' }) {
        Row({ space: '8vp' }) {
          Text(this.title(record)).fontSize(Ui.fs(this.tablet() ? '18vp' : '15vp', this.fontScale)).fontWeight(FontWeight.Bold)
            .fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
          if (record.time.length > 0) {
            Text(record.time).fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.dark))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '42%' });
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Row({ space: '8vp' }) {
          // 集数胶囊：与 GlassChip 同一材质，但保持只读，避免吃掉卡片的播放点击。
          Row() {
            Text('第 ' + record.episode + ' 集').fontSize(Ui.fs('10.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
              .fontColor(Ui.accentStrong(this.dark)).maxLines(1);
          }
            .height('22vp').padding({ left: '9vp', right: '9vp' })
            .borderRadius('11vp')
            .backgroundColor(Ui.accentSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingAccent(this.dark) })
          Text(this.progress(record)).fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        if (this.hasProgress(record)) {
          Row() {
            Row()
              .width(this.barWidth(record))
              .height('100%')
              .borderRadius('3vp')
              .linearGradient({
                angle: 110,
                colors: [[Ui.accent(this.dark), 0], [Ui.accentStrong(this.dark), 1]]
              })
          }
            .width('100%')
            .height('5vp')
            .borderRadius('3vp')
            .backgroundColor(Ui.divider(this.dark))
            .clip(true)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      if (!this.selecting) {
        Row() {
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(Ui.fs('14vp', this.fontScale)).fontColor([Ui.accent(this.dark)]);
        }
          .width('32vp').height('32vp').borderRadius('16vp').justifyContent(FlexAlign.Center)
          .backgroundColor(Ui.accentSoft(this.dark))
          .border({ width: 1, color: Ui.glassRingAccent(this.dark) })
          .hitTestBehavior(HitTestMode.None);
      }
    }
      .width('100%')
      .constraintSize({ minHeight: this.tablet() ? '114vp' : '98vp' })
      .padding('10vp')
      .borderRadius('20vp')
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.dark), 0], [Ui.cardBottom(this.dark), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.dark) })
      .shadow({ radius: 14, color: Ui.shadowSoft(this.dark), offsetY: 7 })
      .clip(true)
      .scale({
        x: this.pressedId === String(record.id) ? 0.97 : 1,
        y: this.pressedId === String(record.id) ? 0.97 : 1
      })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.title(record) + '，第 ' + record.episode + ' 集，' + this.progress(record))
      .onTouch((event: TouchEvent) => {
        this.pressedId = event.type === TouchType.Down ? String(record.id) : '';
      })
      .onClick(() => { void this.open(record); })
      .gesture(LongPressGesture().onAction(() => { this.selecting = true; this.toggle(record.id); }));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.dark), 0], [Ui.pageBgAlt(this.dark), 1]]
        })
      AuroraBackdrop({ intensity: this.dark ? 0.9 : 0.7 })
      Column({ space: '12vp' }) {
        Row({ space: '10vp' }) {
          if (!this.embedded) {
            GlassIconButton({
              iconSize: 36,
              symbol: $r('sys.symbol.chevron_left_circle'),
              accessibilityLabel: '返回',
              onTap: (): void => { AppState.go('home'); }
            })
            Text('播放历史').fontSize(Ui.fs(this.tablet() ? '24vp' : '20vp', this.fontScale)).fontWeight(FontWeight.Bold)
              .fontColor(this.ink()).layoutWeight(1).maxLines(1);
          } else {
            Row({ space: '6vp' }) {
              Column()
                .width('6vp').height('6vp').borderRadius('3vp')
                .backgroundColor(Ui.accent(this.dark))
              Text('右滑分享或删除 · 长按多选').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
            }
              .layoutWeight(1)
              .alignItems(VerticalAlign.Center)
          }
          Button(this.selecting ? '完成' : '多选').height('32vp').fontSize(Ui.fs('12vp', this.fontScale)).fontWeight(FontWeight.Medium)
            .padding({ left: '14vp', right: '14vp' })
            .fontColor(this.selecting ? Ui.accentStrong(this.dark) : this.ink())
            .backgroundColor(this.selecting ? Ui.accentSoft(this.dark) : this.panel())
            .borderRadius('16vp')
            .border({
              width: 1,
              color: this.selecting ? Ui.glassRingAccent(this.dark) : Ui.glassRingSoft(this.dark)
            })
            .onClick(() => { this.selecting = !this.selecting; this.selected = []; });
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        // 批量操作条：整条玻璃胶囊，内部三枚小胶囊横向滚动。
        Scroll() {
          Row({ space: '8vp' }) {
            Button('导入').fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '16vp', right: '16vp' })
              .fontColor(Ui.ink(this.dark)).backgroundColor(this.panel()).borderRadius('17vp')
              .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
              .opacity(this.busy ? 0.5 : 1)
              .enabled(!this.busy)
              .onClick(() => { void this.importRecords(); });
            Button('导出').fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '16vp', right: '16vp' })
              .fontColor(Ui.ink(this.dark)).backgroundColor(this.panel()).borderRadius('17vp')
              .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
              .opacity(this.busy ? 0.5 : 1)
              .enabled(!this.busy)
              .onClick(() => { void this.exportRecords(); });
            Button('一键清空').fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '16vp', right: '16vp' })
              .fontColor(Ui.danger(this.dark)).backgroundColor(this.panel()).borderRadius('17vp')
              .border({ width: 1, color: Ui.danger(this.dark) })
              .opacity(this.busy ? 0.5 : 1)
              .enabled(!this.busy)
              .onClick(() => { void this.confirmClear(); });
          }
            .height('100%')
            .padding({ left: '8vp', right: '8vp' })
            .alignItems(VerticalAlign.Center)
        }
          .width('100%')
          .height('50vp')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .borderRadius('25vp')
          .linearGradient({
            angle: 118,
            colors: [
              [Ui.glassSheenTop(this.dark), 0],
              [Ui.glassTintSoft(this.dark), 0.42],
              [Ui.glassSheenClear(), 1]
            ]
          })
          .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
          .shadow({ radius: 12, color: Ui.shadowSoft(this.dark), offsetY: 4 })
          .clip(true)
        // 保留规则：玻璃卡片 + 胶囊输入框（类型、光标、onChange 与原来一致）。
        Row({ space: '8vp' }) {
          Text('上限').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary()).maxLines(1);
          TextInput({ text: this.limitText }).layoutWeight(1).height('36vp').type(InputType.Number)
            .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.ink()).caretColor(Ui.accent(this.dark))
            .backgroundColor(this.panel()).borderRadius('18vp')
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .padding({ left: '10vp', right: '10vp' })
            .onChange((value: string) => { this.limitText = value; });
          Text('过期天数').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary()).maxLines(1);
          TextInput({ text: this.expiryText }).layoutWeight(1).height('36vp').type(InputType.Number)
            .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.ink()).caretColor(Ui.accent(this.dark))
            .backgroundColor(this.panel()).borderRadius('18vp')
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .padding({ left: '10vp', right: '10vp' })
            .onChange((value: string) => { this.expiryText = value; });
          PrimaryButton({ label: '保存', compact: true, onTap: (): void => { void this.saveOptions(); } })
        }
          .width('100%')
          .padding({ left: '12vp', right: '12vp', top: '10vp', bottom: '10vp' })
          .borderRadius('20vp')
          .backgroundColor(Ui.card(this.dark))
          .border({ width: 1, color: Ui.cardBorder(this.dark) })
          .shadow({ radius: 14, color: Ui.shadowSoft(this.dark), offsetY: 6 })
          .backdropBlur(Math.round(this.materialScale() * 20))
          .clip(true)
        if (this.selecting && this.selected.length > 0) {
          Button('删除已选 ' + this.selected.length + ' 条').width('100%').height('40vp').fontSize(Ui.fs('13vp', this.fontScale))
            .fontWeight(FontWeight.Medium).fontColor(Ui.danger(this.dark))
            .backgroundColor(this.panel()).borderRadius('20vp')
            .border({ width: 1, color: Ui.danger(this.dark) })
            .onClick(() => { void this.remove(this.selected); });
        }
        if (this.records.length === 0) {
          Column() {
            EmptyState({ title: '暂无播放历史', hint: '播放影片后，记录会自动显示在这里', icon: SymbolIcons.doc() })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          List({ space: '12vp', scroller: this.historyScroller }) {
            ForEach(this.records, (record: WatchRecord) => {
              ListItem() { this.historyCard(record); }
                .swipeAction({ start: this.selecting ? undefined : () => { this.historyActions(record); }, edgeEffect: SwipeEdgeEffect.Spring });
            }, (record: WatchRecord) => String(record.id));
          }.lanes(this.columns(), '12vp').width('100%').layoutWeight(1).scrollBar(BarState.Auto)
            .onScrollStart(() => {
            if (this.embedded) { NavigationScroll.begin('manage', 'history', this.historyScroller); }
          })
            .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
            if (this.embedded) { NavigationScroll.report('manage', 'history', this.historyScroller, scrollState); }
          })
            .onScrollStop(() => {
            if (this.embedded) { NavigationScroll.end('manage', 'history', this.historyScroller); }
          });
        }
      }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: ((this.tablet() ? 24 : 16) + (this.embedded ? 0 : this.safeInset(this.leftSafeInset))) + 'vp',
          right: ((this.tablet() ? 24 : 16) + (this.embedded ? 0 : this.safeInset(this.rightSafeInset))) + 'vp',
          top: (8 + (this.embedded ? 0 : this.safeInset(this.topSafeInset))) + 'vp',
          bottom: (this.embedded ? 0 : this.safeInset(this.bottomSafeInset)) + 'vp'
        })
    }
      .width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], this.embedded ? [] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .onAreaChange((_old: Area, area: Area) => {
      try {
        const size: number = Number(area.width);
        if (Number.isFinite(size) && size > 0) { this.viewportWidth = size; }
      } catch (error) { Logger.error('HISTORY', '更新列表布局失败：' + String(error)); }
    });
  }
}

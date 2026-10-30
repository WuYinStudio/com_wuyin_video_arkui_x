import { router } from '@kit.ArkUI';
import { AccountApi, RankEntry } from '../common/AccountApi';
import { Logger } from '../common/Logger';
import { SymbolIcons } from '../common/SymbolIcons';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';

/**
 * 排行榜页：等级 / 金币 / 获赞 / 粉丝，数据来自 admin_rank.php（最多 100 人）。
 */
@Entry
@Component
struct RankPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private kind: string = 'level';
  @State private entries: RankEntry[] = [];
  @State private loading: boolean = false;
  @State private viewportWidth: number = 360;
  private topSafeInset: number = 24;

  aboutToAppear(): void {
    void this.load('level');
  }

  private async load(kind: string): Promise<void> {
    this.kind = kind;
    this.loading = true;
    try {
      const list: RankEntry[] = await AccountApi.rankList(kind);
      this.entries = list.slice(0, 100);
      Logger.info('RANK_PAGE', '榜单已加载：type=' + kind + '，条数=' + String(this.entries.length));
    } catch (error) {
      Logger.warn('RANK_PAGE', '加载榜单失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private unit(): string {
    if (this.kind === 'money') { return '金币'; }
    if (this.kind === 'praise') { return '获赞'; }
    if (this.kind === 'fans') { return '粉丝'; }
    return '经验';
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    void router.replaceUrl({ url: 'pages/Index' });
  }

  @Builder
  private tab(label: string, kind: string) {
    Text(label)
      .fontSize(Ui.fs('13vp', this.fontScale))
      .fontWeight(this.kind === kind ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.kind === kind ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
      .height('34vp')
      .padding({ left: '14vp', right: '14vp' })
      .borderRadius('17vp')
      .backgroundColor(this.kind === kind ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.kind === kind ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
      .onClick(() => { void this.load(kind); })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        Row({ space: '10vp' }) {
          GhostButton({ label: '返回', compact: true, onTap: (): void => { this.goBack(); } })
          Column({ space: '2vp' }) {
            Text('排行榜')
              .fontSize(Ui.fs('20vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text('全服排行榜 · 前 100 名')
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          if (this.loading) {
            LoadingProgress().width('18vp').height('18vp').color(Ui.accent(this.darkTheme))
          }
        }
          .width('100%')
          .padding({ left: '16vp', right: '16vp', top: (this.safeTop() + 6) + 'vp' })
        Row({ space: '8vp' }) {
          this.tab('等级', 'level')
          this.tab('金币', 'money')
          this.tab('获赞', 'praise')
          this.tab('粉丝', 'fans')
        }
          .width('100%')
          .padding({ left: '16vp', right: '16vp', top: '6vp', bottom: '8vp' })
        List({ space: '6vp' }) {
          ForEach(this.entries, (entry: RankEntry) => {
            ListItem() {
              Row({ space: '10vp' }) {
                Text(String(entry.rank))
                  .fontSize(Ui.fs('12.5vp', this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(entry.rank <= 3 ? Ui.gold(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                  .width('28vp')
                  .textAlign(TextAlign.Center)
                Text(entry.name)
                  .fontSize(Ui.fs('13.5vp', this.fontScale))
                  .fontColor(Ui.ink(this.darkTheme))
                  .maxLines(1)
                  .layoutWeight(1)
                Text(String(entry.value) + ' ' + this.unit())
                  .fontSize(Ui.fs('11.5vp', this.fontScale))
                  .fontColor(Ui.inkSoft(this.darkTheme))
              }
                .width('100%')
                .padding({ left: '10vp', right: '10vp', top: '9vp', bottom: '9vp' })
                .borderRadius('12vp')
                .backgroundColor(this.darkTheme ? Ui.card(this.darkTheme) : '#FFFFFF')
                .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
            }
          }, (entry: RankEntry) => 'rank-' + String(entry.rank) + entry.user)
        }
          .width('100%')
          .layoutWeight(1)
          .constraintSize({ maxWidth: this.tablet() ? '760vp' : '100%' })
          .padding({ left: '16vp', right: '16vp', bottom: '24vp' })
          .scrollBar(BarState.Off)
      }
        .width('100%')
        .height('100%')
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const width: number = Number(newValue.width);
          if (Number.isFinite(width) && width > 0) { this.viewportWidth = width; }
        } catch (error) {
          Logger.warn('RANK_PAGE', '更新宽度失败：' + String(error));
        }
      })
  }
}

import { router } from '@kit.ArkUI';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { UserTitle, UserTitles } from '../common/UserTitles';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

class TitleRankParams {
  level: string = '';
}

/**
 * 全部头衔 / 等级排行展示（1~100 级）。
 *
 * 入口：聊天页点击消息头部的等级头衔胶囊 → 带当前等级跳进来，
 * 列表里会把"我的等级"高亮出来，并按 13 级起的分档渐变展示。
 */
@Entry
@Component
struct TitleRankPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private viewportWidth: number = 360;
  @State private current: number = 0;
  private topSafeInset: number = 24;
  private readonly listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.jumpToCurrent();
    try {
      const params: TitleRankParams | undefined = router.getParams() as TitleRankParams | undefined;
      if (params !== undefined && params.level !== undefined) {
        const parsed: number = Number(params.level);
        this.current = Number.isFinite(parsed) ? parsed : 0;
      }
    } catch (error) {
      Logger.warn('TITLE_RANK', '读取路由参数失败：' + String(error));
    }
  }

  private jumpToCurrent(): void {
    if (this.current <= 1) { return; }
    setTimeout(() => {
      try { this.listScroller.scrollToIndex(this.current - 1); }
      catch (error) { Logger.warn('TITLE_RANK', '定位当前等级失败：' + String(error)); }
    }, 120);
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
    void replaceRoute({ url: 'pages/Index' });
  }

  @Builder
  private row(item: UserTitle) {
    Row({ space: '10vp' }) {
      Text(String(item.level))
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(item.level === this.current ? Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme))
        .width('34vp')
        .textAlign(TextAlign.Center)
      if (item.level >= 13) {
        Text(item.name)
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(UserTitles.gradientOf(String(item.level), '')[2])
          .height('24vp')
          .padding({ left: '10vp', right: '10vp' })
          .borderRadius('12vp')
          .linearGradient({
            angle: 90,
            colors: [
              [UserTitles.gradientOf(String(item.level), '')[0], 0],
              [UserTitles.gradientOf(String(item.level), '')[1], 1]
            ]
          })
      } else {
        Text(item.name)
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(item.honor ? item.darkColor : Ui.ink(this.darkTheme))
          .height('24vp')
          .padding({ left: '10vp', right: '10vp' })
          .borderRadius('12vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      }
      Blank()
      if (item.level === this.current) {
        Text('我的等级')
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.accentStrong(this.darkTheme))
      }
    }
      .width('100%')
      .padding({ left: '12vp', right: '12vp', top: '6vp', bottom: '6vp' })
      .borderRadius('12vp')
      .backgroundColor(item.level === this.current ? Ui.accentSoft(this.darkTheme) : Color.Transparent)
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        Row({ space: '10vp' }) {
          GhostButton({ label: '返回', compact: true, onTap: (): void => { this.goBack(); } })
          Column({ space: '2vp' }) {
            Text('全部头衔')
              .fontSize(Ui.fs('22vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text('1 ~ ' + String(UserTitles.TABLE.length) + ' 级 · 聊天室等级头衔排行')
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .padding({ left: '16vp', right: '16vp', top: (this.safeTop() + 6) + 'vp' })
        List({ space: '2vp', scroller: this.listScroller }) {
          ForEach(UserTitles.TABLE, (item: UserTitle) => {
            ListItem() {
              this.row(item)
            }
          }, (item: UserTitle) => 'title-' + String(item.level))
        }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: '12vp', right: '12vp', top: '8vp' })
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
          Logger.warn('TITLE_RANK', '更新宽度失败：' + String(error));
        }
      })
  }
}

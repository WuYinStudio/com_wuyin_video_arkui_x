import { AppState, Film } from '../common/AppState';
import { Ui, UiMotion } from '../common/Ui';

/**
 * 影片卡：首页「为你精选」网格的唯一卡片样式。
 *
 * 接口没有返回封面，因此用"题材渐变 + 首字水印"生成稳定且好看的占位画面，
 * 再叠加真实的评分、集数、简介。整张卡片是 24vp 圆角的玻璃+渐变混合体，
 * 按下时轻微内缩，松手回弹。
 */
@Component
export struct FilmTile {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop film: Film;
  @Prop tablet: boolean = false;
  @StorageLink('darkTheme') dark: boolean = true;
  @State private pressed: boolean = false;

  private tileHeight(): number { return this.tablet ? 300 : 208; }
  private radius(): number { return this.tablet ? 26 : 22; }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 题材渐变底
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 150,
          colors: [[Ui.genreTop(this.film.genre, this.dark), 0], [Ui.genreBottom(this.film.genre, this.dark), 1]]
        })
      // 首字水印：不用图片也有海报感
      Text(Ui.genreGlyph(this.film.genre))
        .fontSize(Ui.fs(this.tablet ? '150vp' : '104vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .opacity(0.14)
        .translate({ x: this.tablet ? 116 : 78, y: -34 })
      // 顶部柔光 + 底部压暗：两层都铺满整卡，避免依赖 Stack 对齐
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.glassSheenTop(this.dark), 0], [Ui.glassSheenClear(), 0.42]]
        })
        .opacity(0.5)
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#00000000', 0.26], ['#99000000', 0.6], ['#E6000000', 1]]
        })
      // 顶部角标 + 底部信息的纵向结构：Blank 撑开，避免使用绝对定位
      Column() {
        Row({ space: 6 }) {
          Row() {
            Text(this.film.genre)
              .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor('#FFFFFF').fontWeight(FontWeight.Medium).maxLines(1)
          }
            .height('22vp').padding({ left: '8vp', right: '8vp' })
            .borderRadius('11vp')
            .backgroundColor('#33FFFFFF')
            .border({ width: 1, color: '#4DFFFFFF' })
          Blank()
          Row({ space: 3 }) {
            Text('★').fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.gold(this.dark))
            Text(this.film.score.toFixed(1)).fontSize(Ui.fs('11vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          }
            .height('22vp').padding({ left: '8vp', right: '8vp' })
            .borderRadius('11vp')
            .backgroundColor('#26000000')
            .border({ width: 1, color: '#33FFFFFF' })
        }
          .width('100%')
        Blank()
        Column({ space: 4 }) {
          Text(this.film.name)
            .fontSize(Ui.fs(this.tablet ? '19vp' : '16vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.film.description)
            .fontSize(Ui.fs(this.tablet ? '12.5vp' : '11.5vp', this.fontScale))
            .fontColor('#E6FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 6 }) {
            Text(this.film.year + ' · ' + this.film.region + ' · 全' + this.film.episodes + '集')
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor('#B3FFFFFF')
              .maxLines(1)
              .layoutWeight(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row() {
              SymbolGlyph($r('sys.symbol.play_fill')).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(['#FFFFFF'])
            }
              .width('26vp').height('26vp').borderRadius('13vp')
              .justifyContent(FlexAlign.Center)
              .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
              .shadow({ radius: 8, color: Ui.accentGlow(this.dark), offsetY: 2 })
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
        }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .height('100%')
        .padding({ left: '12vp', right: '12vp', top: '12vp', bottom: '12vp' })
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .height(this.tileHeight())
      .borderRadius(this.radius())
      .clip(true)
      .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.dark), offsetY: 10 })
      .scale({ x: this.pressed ? 0.97 : 1, y: this.pressed ? 0.97 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .hoverEffect(HoverEffect.None)
      .accessibilityText(this.film.name + '，' + this.film.genre + '，点击播放')
      .onTouch((event: TouchEvent) => { this.pressed = event.type === TouchType.Down; })
      .onClick(() => { AppState.play(this.film); })
  }
}

/** 兼容旧调用的页面标题：改为玻璃胶囊样式，避免与新设计体系割裂。 */
@Component
export struct PageTitle {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop title: string;
  @StorageLink('darkTheme') dark: boolean = true;
  @StorageLink('immersiveTopInset') private topInset: number = 24;

  build() {
    Column() {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          Text('‹').fontSize(Ui.fs('26vp', this.fontScale)).fontColor(Ui.ink(this.dark))
        }
          .width('36vp').height('36vp').borderRadius('18vp')
          .backgroundColor(Ui.glassTintSoft(this.dark))
          .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
          .onClick(() => AppState.go('home'))
        Text(this.title)
          .fontSize(Ui.fs('19vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.dark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }
        .width('100%')
        .height('54vp')
        .padding({ left: '9vp', right: '14vp' })
        .borderRadius('27vp')
        .backgroundColor(Ui.glassTint(this.dark))
        .border({ width: 1, color: Ui.glassRing(this.dark) })
        .shadow({ radius: 14, color: Ui.shadowSoft(this.dark), offsetY: 5 })
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: this.topInset + 8, left: 16, right: 16 })
  }
}

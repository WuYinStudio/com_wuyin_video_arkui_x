/*
 * 无音影视 · 液态玻璃组件库
 *
 * 这里的组件是"整机唯一一套材质"：首页底栏、各页面搜索条、分类/管理 Tab、页头、
 * 卡片、按钮全部复用同一套玻璃配方（底色 + 背景模糊 + 斜向高光 + 1vp 描边 + 投影），
 * 因此深浅模式切换、全局沉浸强度调整时视觉完全一致。
 *
 * 性能约束：背景模糊（backdropBlur）只用在"必须透过内容"的容器上
 * （底栏、搜索条、Tab、页头、抽屉）。普通卡片用半透明底色 + 渐变高光模拟玻璃，
 * 避免滚动时出现几十个实时模糊节点。
 */
import { AppState, PlayerImmersiveConfig } from './AppState';
import { Logger } from './Logger';
import { NavTabs } from './NavTabs';
import { SymbolIcons } from './SymbolIcons';
import { Ui, UiMotion } from './Ui';

/** 极光背景：三团极低饱和的柔光，给纯色底增加"空气感"，不拦截任何手势。 */
@Component
export struct AuroraBackdrop {
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop intensity: number = 1;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(560).height(560).borderRadius(280)
        .radialGradient({
          center: [280, 280], radius: 280,
          colors: [[Ui.auroraViolet(this.dark), 0], [Ui.auroraFade(), 1]]
        })
        .translate({ x: -160, y: -240 })
        .opacity(Math.max(0, Math.min(1, this.intensity)))
      Column()
        .width(520).height(520).borderRadius(260)
        .radialGradient({
          center: [260, 260], radius: 260,
          colors: [[Ui.auroraCyan(this.dark), 0], [Ui.auroraFade(), 1]]
        })
        .translate({ x: 190, y: 20 })
        .opacity(Math.max(0, Math.min(1, this.intensity)) * 0.9)
      Column()
        .width(480).height(480).borderRadius(240)
        .radialGradient({
          center: [240, 240], radius: 240,
          colors: [[Ui.auroraRose(this.dark), 0], [Ui.auroraFade(), 1]]
        })
        .translate({ x: -120, y: 430 })
        .opacity(Math.max(0, Math.min(1, this.intensity)) * 0.75)
    }
      .width('100%').height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 液态玻璃搜索条：首页与搜索页、分类页共用同一实例。
 * - 聚焦时描边转为品牌色并放大光晕，取消聚焦后缓动回落。
 * - 末尾的"搜索"按钮使用品牌渐变，是全应用唯一的强行动点。
 */
@Component
export struct GlassSearchBar {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop query: string = '';
  @Prop placeholder: string = '搜索影片 / 演员 / 导演';
  @Prop showButton: boolean = true;
  @Prop compact: boolean = false;
  @State private focused: boolean = false;
  onQueryChange: (text: string) => void = (_text: string): void => {};
  onSubmit: () => void = (): void => {};
  onFocusChange: (focused: boolean) => void = (_focused: boolean): void => {};

  private barHeight(): number { return this.compact ? 44 : 50; }
  private radius(): number { return this.barHeight() / 2; }
  private glassBlurRadius(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
  private ringColor(): string { return this.focused ? Ui.accentRing(this.dark) : Ui.glassRing(this.dark); }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 玻璃高光：左上更亮，右下几乎透明，模拟一层薄薄的水膜。
      Row()
        .width('100%').height('100%')
        .linearGradient({
          angle: 118,
          colors: [
            [Ui.glassSheenTop(this.dark), 0],
            [Ui.glassSheenMid(this.dark), 0.46],
            [Ui.glassSheenClear(), 1]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(Ui.fs(this.compact ? '17vp' : '18vp', this.fontScale))
          .fontColor([this.focused ? Ui.accent(this.dark) : Ui.inkFaint(this.dark)])
        TextInput({ placeholder: this.placeholder, text: this.query })
          .layoutWeight(1)
          .height('100%')
          .fontSize(Ui.fs(this.compact ? '14vp' : '15vp', this.fontScale))
          .fontColor(Ui.ink(this.dark))
          .placeholderColor(Ui.inkFaint(this.dark))
          .caretColor(Ui.accent(this.dark))
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0, top: 0, bottom: 0 })
          .onChange((text: string) => { this.onQueryChange(text); })
          .onFocus(() => {
            this.focused = true;
            this.onFocusChange(true);
          })
          .onBlur(() => {
            this.focused = false;
            this.onFocusChange(false);
          })
          .onSubmit(() => { this.onSubmit(); })
        if (this.query.length > 0) {
          Row() {
            Text('×').fontSize(Ui.fs('15vp', this.fontScale)).fontColor(Ui.inkSoft(this.dark)).fontWeight(FontWeight.Medium)
          }
            .width('22vp').height('22vp').borderRadius('11vp')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Ui.glassTintStrong(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .accessibilityText('清空搜索内容')
            .onClick(() => {
              this.onQueryChange('');
            })
        }
        if (this.showButton) {
          Row() {
            Text('搜索').fontSize(Ui.fs('13vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          }
            .height(this.barHeight() - 14)
            .padding({ left: '14vp', right: '14vp' })
            .borderRadius((this.barHeight() - 14) / 2)
            .linearGradient({
              angle: 110,
              colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
            })
            .shadow({ radius: 12, color: Ui.accentGlow(this.dark), offsetY: 3 })
            .accessibilityText('执行搜索')
            .onClick(() => { this.onSubmit(); })
        }
      }
        .width('100%')
        .height('100%')
        .padding({ left: '16vp', right: '7vp' })
    }
      .width('100%')
      .height(this.barHeight())
      .padding({ left: 0, right: 0 })
      .borderRadius(this.radius())
      .backgroundColor(Ui.glassTint(this.dark))
      .backdropBlur(this.glassBlurRadius())
      .border({ width: 1, color: this.ringColor() })
      .shadow({
        radius: this.focused ? 22 : 10,
        color: this.focused ? Ui.accentGlow(this.dark) : Ui.shadow(this.dark),
        offsetY: this.focused ? 6 : 4
      })
      .clip(true)
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }
}

/** 只读搜索入口（点击后跳转搜索页），用于分类页等不需要就地输入的页面。 */
@Component
export struct GlassSearchEntry {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop placeholder: string = '搜索影片 / 演员 / 导演';
  @Prop compact: boolean = false;
  @State private pressed: boolean = false;
  onTap: () => void = (): void => {};

  private barHeight(): number { return this.compact ? 44 : 50; }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width('100%').height('100%')
        .linearGradient({
          angle: 118,
          colors: [
            [Ui.glassSheenTop(this.dark), 0],
            [Ui.glassSheenMid(this.dark), 0.46],
            [Ui.glassSheenClear(), 1]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
      Row({ space: 9 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(Ui.fs(this.compact ? '17vp' : '18vp', this.fontScale))
          .fontColor([Ui.accent(this.dark)])
        Text(this.placeholder)
          .fontSize(Ui.fs(this.compact ? '14vp' : '15vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row() {
          Text('搜索').fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor('#FFFFFF')
        }
          .height(this.barHeight() - 16)
          .padding({ left: '13vp', right: '13vp' })
          .borderRadius((this.barHeight() - 16) / 2)
          .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
          .shadow({ radius: 10, color: Ui.accentGlow(this.dark), offsetY: 2 })
      }
        .width('100%').height('100%')
        .padding({ left: '16vp', right: '8vp' })
    }
      .width('100%')
      .height(this.barHeight())
      .borderRadius(this.barHeight() / 2)
      .backgroundColor(Ui.glassTint(this.dark))
      .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
      .border({ width: 1, color: Ui.glassRing(this.dark) })
      .shadow({ radius: 10, color: Ui.shadow(this.dark), offsetY: 4 })
      .clip(true)
      .scale({ x: this.pressed ? 0.985 : 1, y: this.pressed ? 0.985 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.placeholder)
      .onTouch((event: TouchEvent) => { this.pressed = event.type === TouchType.Down; })
      .onClick(() => { this.onTap(); })
  }
}

/** 圆形玻璃图标按钮（页头、图片角标、列表操作）。 */
@Component
export struct GlassIconButton {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop iconSize: number = 40;
  @Prop strong: boolean = false;
  @State private pressed: boolean = false;
  symbol: Resource = $r('sys.symbol.house');
  accessibilityLabel: string = '';
  onTap: () => void = (): void => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.symbol)
        .fontSize(Ui.fs((this.iconSize * 0.46) + 'vp', this.fontScale))
        .fontColor([this.strong ? Ui.accent(this.dark) : Ui.ink(this.dark)])
    }
      .width(this.iconSize).height(this.iconSize)
      .borderRadius(this.iconSize / 2)
      .backgroundColor(this.strong ? Ui.accentSoft(this.dark) : Ui.glassTintSoft(this.dark))
      .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
      .border({ width: 1, color: this.strong ? Ui.glassRingAccent(this.dark) : Ui.glassRingSoft(this.dark) })
      .shadow({ radius: 8, color: Ui.shadowSoft(this.dark), offsetY: 3 })
      .clip(true)
      .scale({ x: this.pressed ? 0.9 : 1, y: this.pressed ? 0.9 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.accessibilityLabel)
      .onTouch((event: TouchEvent) => { this.pressed = event.type === TouchType.Down; })
      .onClick(() => { this.onTap(); })
  }
}

/** 玻璃胶囊标签（题材、评分、集数、可选中的过滤器）。 */
@Component
export struct GlassChip {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop emphasize: boolean = false;
  @Prop compact: boolean = false;
  onTap: () => void = (): void => {};

  private chipHeight(): number { return this.compact ? 24 : 30; }
  private tone(): string {
    if (this.selected) { return Ui.accentSoft(this.dark); }
    return this.emphasize ? Ui.goldSoft(this.dark) : Ui.glassTintSoft(this.dark);
  }
  private labelColor(): string {
    if (this.selected) { return Ui.accentStrong(this.dark); }
    return this.emphasize ? Ui.gold(this.dark) : Ui.inkSoft(this.dark);
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(Ui.fs(this.compact ? '11vp' : '12vp', this.fontScale))
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.labelColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .height(this.chipHeight())
      .padding({ left: this.compact ? '9vp' : '11vp', right: this.compact ? '9vp' : '11vp' })
      .borderRadius(this.chipHeight() / 2)
      .backgroundColor(this.tone())
      .border({
        width: 1,
        color: this.selected ? Ui.glassRingAccent(this.dark) : Ui.cardBorderSoft(this.dark)
      })
      .onClick(() => { this.onTap(); })
  }
}

/**
 * 分段玻璃 Tab（首页题材切换、管理页三个子页切换共用）。
 * 选中背景是一枚"胶囊玻璃"，位置随 active 用缓动函数滑动，端点保持完全圆角。
 */
@Component
export struct SegmentedGlassTabs {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop labels: string[] = [];
  @Prop active: number = 0;
  @Prop trackWidth: number = 320;
  @Prop trackHeight: number = 44;
  @Prop compact: boolean = false;
  @State private pressed: number = -1;
  @State private stretch: number = 1;
  onSelect: (index: number) => void = (_index: number): void => {};

  // 水平方向不再给轨道加内边距：指示器与每个 Tab 单元格都从 0 开始均分 trackWidth，
  // 避免 ArkUI 盒模型把 padding 算在 100% 宽之外导致指示器整体右移。
  private pad(): number { return 0; }
  private vPad(): number { return 4; }
  private segment(): number {
    const count: number = Math.max(1, this.labels.length);
    return Math.max(0, this.trackWidth / count);
  }
  private capsuleHeight(): number { return this.trackHeight - this.vPad() * 2; }
  private fontSize(): string {
    if (this.compact) { return '12.5vp'; }
    return this.labels.length > 4 ? '13.5vp' : '14.5vp';
  }

  private select(index: number): void {
    if (index === this.active) { return; }
    this.stretch = 1.14;
    setTimeout(() => { this.stretch = 1; }, 120);
    this.onSelect(index);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 移动的玻璃胶囊：拉伸-回弹制造"液体被甩过去"的错觉。
      Row()
        .width(Math.max(10, this.segment()))
        .height(this.capsuleHeight())
        .borderRadius(this.capsuleHeight() / 2)
        .linearGradient({
          angle: 145,
          colors: [
            [Ui.glassSheenTop(this.dark), 0],
            [Ui.accentSoft(this.dark), 0.42],
            [Ui.glassSheenMid(this.dark), 1]
          ]
        })
        .border({ width: 1, color: Ui.glassRingAccent(this.dark) })
        .translate({ x: this.segment() * this.active, y: this.vPad() })
        .scale({ x: this.stretch, y: 2 - this.stretch })
        .animation({ duration: UiMotion.LIQUID, curve: Curve.FastOutSlowIn })
        .hitTestBehavior(HitTestMode.None)
      Row() {
        ForEach(this.labels, (label: string, index: number) => {
          Column() {
            Text(label)
              .fontSize(this.fontSize())
              .fontWeight(this.active === index ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.active === index ? Ui.accentStrong(this.dark) : Ui.inkSoft(this.dark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
          }
            .layoutWeight(1)
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .scale({ x: this.pressed === index ? 0.94 : 1, y: this.pressed === index ? 0.94 : 1 })
            .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
            .accessibilityText(label + (this.active === index ? '，已选中' : '，点击切换'))
            .onTouch((event: TouchEvent) => {
              this.pressed = event.type === TouchType.Down ? index : -1;
            })
            .onClick(() => { this.select(index); })
        }, (label: string) => label)
      }
        .width(this.trackWidth)
        .height('100%')
    }
      .width(this.trackWidth)
      .height(this.trackHeight)
      .borderRadius(this.trackHeight / 2)
      .backgroundColor(Ui.glassTint(this.dark))
      .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
      .border({ width: 1, color: Ui.glassRing(this.dark) })
      .shadow({ radius: 12, color: Ui.shadowSoft(this.dark), offsetY: 4 })
      .clip(true)
  }
}

/**
 * 底栏上方的渐进模糊（Progressive Blur）。
 *
 * 实现方式：把一条固定高度的区域切成若干条水平窄带，每条窄带单独做背景模糊，
 * 模糊半径从"贴近底栏处最大"向"顶部为零"平滑下降。因为每条窄带只覆盖自己那一条，
 * 所以模糊强度沿竖直方向真实渐变，不会像单层 backdropBlur 那样整片糊死；
 * 顶部边界之外（正文区域）没有任何节点，正文永远不会被糊到。
 *
 * 最后再叠一层"透明 → 玻璃色"的竖直渐变，既掩盖窄带之间的接缝，
 * 又让模糊区与底栏的玻璃底色衔接成一体。
 */
@Component
export struct ProgressiveBlur {
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop stripHeight: number = 112;
  @Prop maxBlur: number = 22;
  @Prop slices: number = 12;
  @Prop glassTintMix: number = 1;

  private bandHeight(): number {
    const count: number = Math.max(1, this.slices);
    return Math.max(1, this.stripHeight / count);
  }
  private bandBlur(index: number): number {
    const count: number = Math.max(1, this.slices);
    // index=0 在最下方（紧贴底栏），模糊最强；index 越大越靠上，越接近 0。
    const depth: number = (count - index) / count;
    return this.maxBlur * Math.pow(depth, 1.25);
  }
  private bandIndexes(): number[] {
    const result: number[] = [];
    const count: number = Math.max(1, this.slices);
    for (let index: number = 0; index < count; index++) {
      result.push(index);
    }
    return result;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      ForEach(this.bandIndexes(), (index: number) => {
        Row()
          .width('100%')
          .height(this.bandHeight())
          .backdropBlur(this.bandBlur(index))
          .translate({ y: -(index * this.bandHeight()) })
          .hitTestBehavior(HitTestMode.None)
      }, (index: number) => index.toString())
      Row()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [Ui.glassSheenClear(), 0],
            [Ui.glassTintSoft(this.dark), 0.62],
            [Ui.glassTint(this.dark), 1]
          ]
        })
        .opacity(Math.max(0, Math.min(1, this.glassTintMix)))
        .hitTestBehavior(HitTestMode.None)
    }
      .width('100%')
      .height(this.stripHeight)
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 液态玻璃底栏 + 底栏上方的渐进模糊。
 *
 * - 五个入口沿用原有路由（home/category/manage/settings/mine），功能不变。
 * - 选中项背后是一枚圆形玻璃球：切换时以"先拉长后回弹"的方式滑到新位置（液态轮廓），
 *   并带一个延迟跟随的尾迹球，形成液体被拖拽的观感。
 * - 向下滚动时整条底栏（含渐进模糊）一起下沉隐藏，向上滚动立即回落。
 */
@Component
export struct LiquidNav {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('page') @Watch('onRouteChanged') private page: string = 'home';
  @StorageLink('navTabKeys') private navTabKeys: string[] = NavTabs.DEFAULT_KEYS;
  @StorageLink('navigationBarHidden') private hidden: boolean = false;
  // 设置页「界面尺寸 · Dock 栏大小」：0.85~1.25 倍，只缩放底栏本体与图标文字。
  @StorageLink('dockScale') private dockScaleValue: number = 1;
  // 「全局字体大小」同样作用于底栏图标与标签，保证与页面正文的比例一致。
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop viewportWidth: number = 360;
  @Prop viewportHeight: number = 780;
  @Prop safeBottom: number = 16;
  @State private pressed: string = '';
  @State private stretchX: number = 1;
  @State private stretchY: number = 1;
  // Tab 项由全局配置发布；底栏本身仍使用原来的玻璃造型、圆形指示器与切换动画。
  private routes(): string[] { return NavTabs.sanitize(this.navTabKeys); }

  private tablet(): boolean { return Ui.isTablet(this.viewportWidth); }
  private landscape(): boolean {
    return this.viewportHeight > 0 && this.viewportWidth > this.viewportHeight * 1.15;
  }
  /**
   * 设置页发布的自定义 Dock 缩放系数，已收敛到 0.85~1.25。
   * 注意：方法名不能叫 scale —— 会与 ArkUI 内置的通用属性 scale 冲突（10505001）。
   */
  private dockFactor(): number { return Ui.dockScale(this.dockScaleValue); }
  private barWidth(): number {
    const limit: number = this.tablet() ? 620 : 460;
    const cap: number = this.landscape() ? 420 : limit;
    return Math.max(0, Math.min(this.viewportWidth - (this.tablet() ? 48 : 24), cap));
  }
  private barHeight(): number {
    const base: number = this.landscape() ? 62 : (this.tablet() ? 84 : 70);
    return Math.round(base * this.dockFactor());
  }
  private bubbleSize(): number {
    const base: number = this.landscape() ? 48 : (this.tablet() ? 62 : 54);
    return Math.round(base * this.dockFactor());
  }
  // 指示器与 Tab 单元格必须使用同一套水平坐标。
  // Row 的 padding 会参与 ArkUI 的盒模型计算，单独给气泡补 pad 会产生固定横向偏移；
  // 这里将内边距归零，barWidth 直接均分给每个 Tab，气泡与图标中心严格同点。
  private pad(): number { return 0; }
  private cell(): number {
    const count: number = Math.max(1, this.routes().length);
    return Math.max(0, (this.barWidth() - this.pad() * 2) / count);
  }
  private activeIndex(): number {
    const found: number = this.routes().indexOf(this.page);
    return found >= 0 ? found : 0;
  }
  private bubbleX(): number {
    return this.pad() + this.cell() * this.activeIndex() + (this.cell() - this.bubbleSize()) / 2;
  }
  private bubbleY(): number { return (this.barHeight() - this.bubbleSize()) / 2; }
  private stripHeight(): number {
    const base: number = this.landscape() ? 54 : (this.tablet() ? 96 : 78);
    return Math.round(base * this.dockFactor());
  }
  private glassBlur(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
  /** 图标/标签的综合缩放：Dock 缩放 × 全局字体缩放，上限 1.45 倍避免撑破底栏。 */
  private contentScale(): number {
    return Math.min(1.45, this.dockFactor() * Ui.fontScale(this.fontScale));
  }
  private iconSize(): string {
    const base: number = this.landscape() ? 20 : (this.tablet() ? 26 : 23);
    return Math.round(base * this.contentScale() * this.countFactor()) + 'vp';
  }
  private labelSize(): string {
    const base: number = this.landscape() ? 9.5 : (this.tablet() ? 12 : 10.5);
    return (Math.round(base * this.contentScale() * this.countFactor() * 10) / 10) + 'vp';
  }
  /** Tab 数量多时（例如开启消息/论坛/直播后 7~8 个）整体缩小图标与文字，避免横向挤压。 */
  private countFactor(): number {
    const count: number = this.routes().length;
    if (count <= 6) { return 1; }
    return count >= 8 ? 0.82 : 0.9;
  }
  private hiddenOffset(): number { return this.barHeight() + this.safeBottom + 40; }

  private onRouteChanged(): void {
    this.pressed = '';
    // 液态位移：先横向拉长、纵向压扁，再回到正圆，视觉上像被惯性和表面张力推过去。
    this.stretchX = 1.26;
    this.stretchY = 0.82;
    setTimeout(() => {
      this.stretchX = 1;
      this.stretchY = 1;
    }, 150);
  }

  // 全部入口统一走鸿蒙原生 sys.symbol（映射集中在 SymbolIcons，方便一处替换）。
  private navSymbol(route: string): Resource {
    return SymbolIcons.tab(route, this.page === route);
  }
  private tint(route: string): string {
    return this.page === route ? Ui.accentStrong(this.dark) : Ui.inkFaint(this.dark);
  }

  @Builder
  private navCell(route: string, index: number) {
    Column({ space: this.tablet() ? 5 : 3 }) {
      SymbolGlyph(this.navSymbol(route))
        .fontSize(this.iconSize())
        .fontColor([this.tint(route)])
      Text(NavTabs.title(route))
        .fontSize(this.labelSize())
        .fontWeight(this.page === route ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.tint(route))
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .scale({ x: this.pressed === route ? 0.88 : 1, y: this.pressed === route ? 0.88 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(NavTabs.title(route) + (this.page === route ? '，已选中' : '，点击切换'))
      .onTouch((event: TouchEvent) => {
        this.pressed = event.type === TouchType.Down ? route : '';
      })
      .onClick(() => {
        try {
          Logger.info('LiquidNav', '导航切换 ' + this.page + ' -> ' + route);
          // 直接点底栏“管理”时回到观看历史；从我的页面跳转时保留目标子页索引。
          if (route === 'manage') {
            AppStorage.setOrCreate<number>('manageInitialTab', 0);
          }
          this.getUIContext().animateTo({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn }, () => {
            AppState.go(route);
          });
        } catch (error) {
          Logger.error('LiquidNav', '导航切换失败：' + String(error));
          AppState.go(route);
        }
      })
  }

  build() {
    Column() {
      // 用 TopStart 作为子控件原点：选中球靠 translate(y) 精确落到底栏垂直中心，
      // 不能使用 Alignment.Start（左中对齐），否则会再叠加一次垂直居中造成下沉。
      Stack({ alignContent: Alignment.TopStart }) {
        // 玻璃本体
        Row()
          .width('100%').height('100%')
          .linearGradient({
            angle: 118,
            colors: [
              [Ui.glassSheenTop(this.dark), 0],
              [Ui.glassSheenMid(this.dark), 0.5],
              [Ui.glassSheenClear(), 1]
            ]
          })
          .hitTestBehavior(HitTestMode.None)
        // 圆形选中指示器：只保留玻璃渐变，不再叠尾迹、柔光斑或外发光。
        Column() {
          Column()
            .width(this.bubbleSize())
            .height(this.bubbleSize())
            .borderRadius(this.bubbleSize() / 2)
            .linearGradient({
              angle: 152,
              colors: [
                [Ui.glassSheenTop(this.dark), 0],
                [Ui.glassTintStrong(this.dark), 0.5],
                [Ui.glassSheenMid(this.dark), 1]
              ]
            })
        }
          .width(this.bubbleSize())
          .height(this.bubbleSize())
          .scale({ x: this.stretchX, y: this.stretchY })
          .translate({ x: this.bubbleX(), y: this.bubbleY() })
          .animation({ duration: UiMotion.LIQUID, curve: Curve.FastOutSlowIn })
          .hitTestBehavior(HitTestMode.None)
        Row() {
          ForEach(this.routes(), (route: string, index: number) => {
            this.navCell(route, index)
          }, (route: string) => route)
        }
          .width('100%')
          .height('100%')
          .padding({ left: this.pad(), right: this.pad() })
      }
        .width(this.barWidth())
        .height(this.barHeight())
        .borderRadius(this.barHeight() / 2)
        .backgroundColor(Ui.glassTint(this.dark))
        .backdropBlur(this.glassBlur())
        .shadow({ radius: 26, color: Ui.shadow(this.dark), offsetY: 10 })
        .clip(true)
        .hoverEffect(HoverEffect.None)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: Math.max(0, this.safeBottom) + 8 })
      .translate({ y: this.hidden ? this.hiddenOffset() : 0 })
      .animation({ duration: this.page === 'category' ? 300 : 240, curve: Curve.FastOutSlowIn })
      .hitTestBehavior(this.hidden ? HitTestMode.None : HitTestMode.Default)
      .accessibilityLevel(this.hidden ? 'no-hide-descendants' : 'auto')
  }
}

/** 页面标题栏：左返回 + 标题/副标题 + 右侧文字动作，本身是一块悬浮玻璃。 */
@Component
export struct PageHeader {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topInset: number = 24;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = true;
  @Prop actionText: string = '';
  @Prop gutter: number = 16;
  onBack: () => void = (): void => { AppState.go('home'); };
  onAction: () => void = (): void => {};

  private glassBlurRadius(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
  private safeTop(): number { return Number.isFinite(this.topInset) ? Math.max(0, this.topInset) : 24; }

  build() {
    Column() {
      Row({ space: 10 }) {
        if (this.showBack) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_left_circle'))
              .fontSize(Ui.fs('22vp', this.fontScale))
              .fontColor([Ui.ink(this.dark)])
          }
            .width('36vp').height('36vp').borderRadius('18vp')
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .accessibilityText('返回')
            .onClick(() => { this.onBack(); })
        }
        Column({ space: 1 }) {
          Text(this.title)
            .fontSize(Ui.fs('19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.dark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        if (this.actionText.length > 0) {
          Row() {
            Text(this.actionText).fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
              .fontColor(Ui.accent(this.dark)).maxLines(1)
          }
            .height('34vp')
            .padding({ left: '13vp', right: '13vp' })
            .borderRadius('17vp')
            .backgroundColor(Ui.accentSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingAccent(this.dark) })
            .accessibilityText(this.actionText)
            .onClick(() => { this.onAction(); })
        }
      }
        .width('100%')
        .height('54vp')
        .padding({ left: '9vp', right: '9vp' })
        .borderRadius('27vp')
        .backgroundColor(Ui.glassTint(this.dark))
        .backdropBlur(this.glassBlurRadius())
        .border({ width: 1, color: Ui.glassRing(this.dark) })
        .shadow({ radius: 16, color: Ui.shadowSoft(this.dark), offsetY: 6 })
        .clip(true)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    // 安全区与左右留白放在玻璃之外，避免玻璃被拉得过宽。
      .padding({ top: this.safeTop() + 8, left: this.gutter, right: this.gutter })
  }
}

/** 区块标题：主标题 + 副标题 + 可选"更多"胶囊。 */
@Component
export struct SectionHeader {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop actionText: string = '';
  @Prop viewportWidth: number = 360;
  onAction: () => void = (): void => {};

  build() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(Ui.fs(Ui.fsSection(this.viewportWidth), this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.dark))
          .maxLines(1)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale))
            .fontColor(Ui.inkFaint(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      if (this.actionText.length > 0) {
        Row() {
          Text(this.actionText).fontSize(Ui.fs('12vp', this.fontScale)).fontColor(Ui.inkSoft(this.dark)).maxLines(1)
        }
          .height('28vp')
          .padding({ left: '11vp', right: '11vp' })
          .borderRadius('14vp')
          .backgroundColor(Ui.glassTintSoft(this.dark))
          .border({ width: 1, color: Ui.cardBorderSoft(this.dark) })
          .onClick(() => { this.onAction(); })
      }
    }
      .width('100%')
      .alignItems(VerticalAlign.Center)
  }
}

/** 玻璃卡片容器：统一圆角、描边、内阴影与内边距，内容通过尾随闭包传入。 */
@Component
export struct GlassCard {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop radius: number = 24;
  @Prop contentPadding: number = 16;
  @Prop withBlur: boolean = false;
  @Prop strong: boolean = false;
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
  }

  build() {
    Column() {
      this.content()
    }
      .width('100%')
      .padding(this.contentPadding)
      .borderRadius(this.radius)
      .linearGradient({
        angle: 135,
        colors: [
          [this.strong ? Ui.cardTop(this.dark) : Ui.card(this.dark), 0],
          [Ui.cardBottom(this.dark), 1]
        ]
      })
      .border({ width: 1, color: Ui.cardBorder(this.dark) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.dark), offsetY: 8 })
      .backdropBlur(this.withBlur ? Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur) : 0)
      .clip(true)
  }
}

/** 主行动按钮：品牌渐变胶囊。 */
@Component
export struct PrimaryButton {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop label: string = '';
  @Prop compact: boolean = false;
  @State private pressed: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(Ui.fs(this.compact ? '13vp' : '15vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)
    }
      .height(this.compact ? 38 : 48)
      .padding({ left: this.compact ? '18vp' : '24vp', right: this.compact ? '18vp' : '24vp' })
      .borderRadius(this.compact ? 19 : 24)
      .linearGradient({
        angle: 110,
        colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
      })
      .shadow({ radius: 16, color: Ui.accentGlow(this.dark), offsetY: 6 })
      .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.label)
      .onTouch((event: TouchEvent) => { this.pressed = event.type === TouchType.Down; })
      .onClick(() => { this.onTap(); })
  }
}

/** 次要行动按钮：玻璃胶囊。 */
@Component
export struct GhostButton {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @Prop label: string = '';
  @Prop compact: boolean = false;
  @State private pressed: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(Ui.fs(this.compact ? '12.5vp' : '14vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.dark))
        .maxLines(1)
    }
      .height(this.compact ? 34 : 44)
      .padding({ left: this.compact ? '14vp' : '18vp', right: this.compact ? '14vp' : '18vp' })
      .borderRadius(this.compact ? 17 : 22)
      .backgroundColor(Ui.glassTintSoft(this.dark))
      .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
      .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
      .shadow({ radius: 8, color: Ui.shadowSoft(this.dark), offsetY: 3 })
      .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.label)
      .onTouch((event: TouchEvent) => { this.pressed = event.type === TouchType.Down; })
      .onClick(() => { this.onTap(); })
  }
}

/** 空状态：玻璃圆盘 + 标题 + 提示。 */
@Component
export struct EmptyState {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private dark: boolean = true;
  @Prop title: string = '暂无内容';
  @Prop hint: string = '';
  @Prop glyph: string = '◎';
  /** 传入后优先用鸿蒙原生符号渲染图标（glyph 作为兜底）。 */
  icon?: Resource = undefined;
  onTap: () => void = (): void => {};

  build() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('84vp').height('84vp').borderRadius('42vp')
          .radialGradient({
            center: [42, 42], radius: 42,
            colors: [[Ui.accentSoft(this.dark), 0], [Ui.auroraFade(), 1]]
          })
        if (this.icon !== undefined) {
          SymbolGlyph(this.icon)
            .fontSize(Ui.fs('30vp', this.fontScale))
            .fontColor([Ui.inkFaint(this.dark)])
            .opacity(0.85)
        } else {
          Text(this.glyph)
            .fontSize(Ui.fs('30vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.dark))
            .opacity(0.85)
        }
      }
        .width('84vp').height('84vp')
      Text(this.title).fontSize(Ui.fs('15vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.ink(this.dark))
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
    }
      .width('100%')
      .padding({ top: '42vp', bottom: '42vp' })
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.onTap(); })
  }
}

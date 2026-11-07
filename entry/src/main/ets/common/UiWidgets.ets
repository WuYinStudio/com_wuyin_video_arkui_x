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
import uiMaterial from '@ohos.arkui.uiMaterial';
import { registerGlass, unregisterGlass, setParams, setTint, startRender, stopRender, setTouchPosition, triggerRipple } from './GlassCompat';
import { AppState, PlayerImmersiveConfig } from './AppState';
import { Logger } from './Logger';
import { NavTabs } from './NavTabs';
import { SymbolIcons } from './SymbolIcons';
import { Ui, UiMotion } from './Ui';
import { WallpaperBackdrop } from './WallpaperBackdrop';

/**
 * 极光背景：三团极低饱和的柔光，给纯色底增加"空气感"，不拦截任何手势。
 *
 * 这里同时挂载「本地导入背景」图层（图片 / GIF / 循环视频）：所有页面本来就在
 * 页面底色之上调用 AuroraBackdrop，因此动态背景会自动跟随到全部页面，
 * 播放器页不调用它，保持播放器画面纯净。没有导入背景时该图层不渲染任何节点。
 */
@Component
export struct AuroraBackdrop {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('wallpaperMediaUri') private mediaUri: string = '';
  @StorageLink('wallpaperId') private wallpaperId: string = '';
  @Prop intensity: number = 1;
  /** 宿主页面/标签页是否在前台；首页在非 home Tab 时传 false，避免后台标签页也持有视频解码器。 */
  @Prop hostVisible: boolean = true;

  /**
   * 极光强度：有本地背景时压到三成左右。
   * 首页原本用 intensity=1，三团大光斑叠在视频/图片上会把背景糊成一片主题色；
   * 压低后背景保持清晰，同时保留一点主题色调。
   */
  private hasWallpaper(): boolean {
    return this.mediaUri.length > 0 || this.wallpaperId.length > 0;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.hasWallpaper()) {
        WallpaperBackdrop({ hostVisible: this.hostVisible })
      }
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
        .fontColor([this.strong ? Ui.accent(this.dark) : Ui.icon(this.dark)])
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
  // 设置页「Dock 栏外观」：样式 liquid / blur / glow + 强度 + 低电量自适应。
  @StorageLink('dockStyle') private dockStyle: string = 'glow';
  // LiquidGlass 原生渲染实例（XComponent + OpenGL ES）
  private glassId: string = 'dockglass_' + Math.floor(Math.random() * 1000000);
  /// 原生 LiquidGlass 渲染开关：着色器当前在真机上不稳定（会整块黑/无效果），先关闭走 ArkUI 背景模糊。
  private readonly useNativeGlass: boolean = false;
  @StorageLink('dockIntensity') private dockIntensity: number = 70;
  @StorageLink('dockBatteryAuto') private dockBatteryAuto: boolean = true;
  @StorageLink('dockBatteryThreshold') private dockBatteryThreshold: number = 20;
  @StorageLink('dockBatteryPercent') private dockBatteryPercent: number = 100;
  // 「全局字体大小」同样作用于底栏图标与标签，保证与页面正文的比例一致。
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop viewportWidth: number = 360;
  @Prop viewportHeight: number = 780;
  @Prop safeBottom: number = 16;
  @State private pressed: string = '';
  @State private hovered: string = '';
  @State private stretchX: number = 1;
  @State private stretchY: number = 1;
  // 长按拖动：滑块跟随手指，按滑动速度做物理挤压缩放。
  @State private dockDragging: boolean = false;
  @State private dockDragX: number = 0;
  @State private dockDragStartX: number = 0;
  @State private dockDragMoved: boolean = false;
  @State private dockDragIndex: number = -1;
  // 拖动速度归一化后的挤压强度（0~1）。
  @State private dockSqueezeValue: number = 0.35;
  /// 按压时的物理挤压脉冲（true=收紧），驱动滑块与底栏的呼吸式形变。
  @State private squeezePulse: boolean = false;
  private squeezeTimer: number = -1;
  /// 当前挤压基准倍率（拖动速度会改变它）。
  private squeezeBase: number = 1;
  // 沉浸光感：触摸光斑位置（仅 glow 样式生效，颜色取自主题）。
  @State private touchGlowX: number = -1;
  @State private touchGlowOn: boolean = false;
  // 长按拖动的原始触摸判定（不用 gesture，避免被 Tab 的 onClick 抢走）。
  private dockPressTimer: number = -1;
  private dockTouchStartX: number = 0;
  private dockTouchLastX: number = 0;
  private dockTouchLastTs: number = 0;
  private dockSuppressClickUntil: number = 0;
  // Tab 项由全局配置发布；底栏本身仍使用原来的玻璃造型、圆形指示器与切换动画。
  aboutToDisappear(): void {
    try {
      stopRender(this.glassId);
      unregisterGlass(this.glassId);
    } catch (_) { /* 原生层已释放时忽略 */ }
  }

  /** LiquidGlass：注册实例、下发强度参数并启动 GPU 渲染。 */
  private startGlassRender(): void {
    try {
      registerGlass(this.glassId);
      setParams(this.glassId,
        // 0.35~0.6：半透明玻璃薄雾，下面的 backdropBlur 负责真实背景虚化。
        Math.min(0.6, 0.35 + this.dockFactorIntensity() * 0.25),
        Math.max(0, this.dockFactorIntensity() * 12),
        Math.min(0.1, 0.03 + this.dockFactorIntensity() * 0.05),
        1.2);
      // 主题色调：深色模式把玻璃薄雾压暗，浅色模式保持近白。
      if (this.dark) { setTint(this.glassId, 0.22, 0.24, 0.28); }
      else { setTint(this.glassId, 0.96, 0.97, 0.99); }
      startRender(this.glassId);
    } catch (error) {
      Logger.warn('DOCK_GLASS', '启动 LiquidGlass 失败：' + String(error));
    }
  }

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
    const width: number = this.viewportWidth;
    const available: number = Math.max(0, width - (Ui.isDesktop(width) ? 96 : (this.tablet() ? 48 : 24)));
    let preferred: number = 460;
    if (Ui.isTv(width)) { preferred = 840; }
    else if (Ui.isDesktop(width)) { preferred = 720; }
    else if (this.tablet()) { preferred = 620; }
    // 手机横屏保持原有收窄逻辑，平板/PC/智慧屏不参与该限制。
    if (this.landscape() && !this.tablet()) { preferred = Math.min(preferred, 420); }
    return Math.max(0, Math.min(available, preferred));
  }
  private barHeight(): number {
    return Ui.navBarHeight(this.viewportWidth, this.viewportHeight, this.dockScaleValue);
  }
  /** 大屏使用更克制的圆角；手机保持胶囊。 */
  private barRadius(): number {
    const width: number = this.viewportWidth;
    if (Ui.isTv(width)) { return 32; }
    if (Ui.isDesktop(width)) { return 28; }
    if (this.tablet()) { return 28; }
    return this.barHeight() / 2;
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
    if (this.dockDragging) { return this.dockDragX; }
    return this.pad() + this.cell() * this.activeIndex() + (this.cell() - this.bubbleSize()) / 2;
  }
  /** 沉浸光感的触摸光斑直径。 */
  private glowSize(): number { return Math.round(this.bubbleSize() * 2.6); }
  /** 光斑跟随手指的横向位置，边缘做收敛避免溢出底栏。 */
  private glowX(): number {
    const size: number = this.glowSize();
    const raw: number = this.touchGlowX < 0 ? this.bubbleX() + this.bubbleSize() / 2 : this.touchGlowX;
    return Math.max(-size * 0.25, Math.min(this.barWidth() - size * 0.75, raw - size / 2));
  }
  /** 触摸光感：三种样式下都点亮，颜色取主题色（accentGlow + accentSoft）。 */
  private glowVisible(): boolean {
    return this.touchGlowOn && !this.hidden;
  }

  /** 底栏触摸总入口：按下即进入拖动（无长按延迟），横向位移驱动滑块，松手吸附。 */
  private handleDockTouch(event: TouchEvent): void {
    if (this.hidden) { return; }
    const touch: TouchEvent | undefined = event;
    const x: number = touch.touches.length > 0 ? touch.touches[0].x : 0;
    if (event.type === TouchType.Down) {
      this.clearDockPressTimer();
      this.dockTouchStartX = x;
      this.dockTouchLastX = x;
      this.dockTouchLastTs = Date.now();
      // 三种样式都点亮触摸光斑（颜色跟随主题）。
      this.touchGlowX = x;
      this.touchGlowOn = true;
      // LiquidGlass：把触点归一化坐标交给 GPU，按下时触发涟漪。
      if (this.dockStyle === 'liquid') {
        try {
          const nx: number = Math.max(0, Math.min(1, x / Math.max(1, this.barWidth())));
          setTouchPosition(this.glassId, nx, 0.5);
          triggerRipple(this.glassId, nx, 0.5, 1.0);
        } catch (_) { /* 原生层未就绪时忽略 */ }
      }
      // 长按 0.005 秒即接管滑块（几乎瞬时）；无位移松手仍按点击处理。
      this.dockPressTimer = setTimeout(() => {
        this.dockPressTimer = -1;
        if (!this.dockDragging) {
          this.beginDockDrag();
          this.dockDragMoved = false;
        }
      }, 5);
      return;
    }
    if (event.type === TouchType.Move) {
      this.touchGlowX = x;
      this.dockTouchLastX = x;
      if (this.dockStyle === 'liquid') {
        try { setTouchPosition(this.glassId, Math.max(0, Math.min(1, x / Math.max(1, this.barWidth()))), 0.5); } catch (_) { /* 忽略 */ }
      }
      if (this.dockDragging) {
        const now: number = Date.now();
        const elapsed: number = Math.max(1, now - this.dockTouchLastTs);
        const velocity: number = (x - this.dockTouchLastX) / elapsed * 1000;
        this.dockTouchLastX = x;
        this.dockTouchLastTs = now;
        this.updateDockDrag(x, velocity);
      } else if (Math.abs(x - this.dockTouchStartX) > 8) {
        // 长按还没成立就大幅滑动：视为普通滑动，取消长按判定。
        this.clearDockPressTimer();
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.clearDockPressTimer();
      this.touchGlowOn = false;
      // 抬手时 touches 为空，用最后一次记录的横坐标判定落点。
      const endX: number = x > 0 ? x : this.dockTouchLastX;
      if (!this.dockDragging) {
        // 轻点（未满 0.2 秒）：按落点 Tab 切换。
        this.switchDockTab(this.indexAt(endX));
        return;
      }
      if (this.dockDragging) {
        if (this.dockDragMoved) {
          // 真正拖动过：抑制本次松手触发的 Tab onClick，避免重复切页。
          this.dockSuppressClickUntil = Date.now() + 320;
          this.endDockDrag();
        } else {
          // 没有位移：当成点击，落到按下位置的 Tab 上。
          const target: number = this.indexAt(endX);
          this.cancelDockDrag();
          this.switchDockTab(target);
        }
      }
    }
  }

  /** 按序号切换底栏 Tab（拖动松手与零延迟点击共用）。 */
  private switchDockTab(target: number): void {
    const routes: string[] = this.routes();
    if (target < 0 || target >= routes.length) { return; }
    if (routes[target] === this.page) { return; }
    try {
      if (routes[target] === 'manage') { AppStorage.setOrCreate<number>('manageInitialTab', 0); }
      this.getUIContext().animateTo({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn }, () => {
        AppState.go(routes[target]);
      });
    } catch (error) {
      Logger.error('LiquidNav', '切换导航失败：' + String(error));
      AppState.go(routes[target]);
    }
  }

  private clearDockPressTimer(): void {
    if (this.dockPressTimer !== -1) {
      clearTimeout(this.dockPressTimer);
      this.dockPressTimer = -1;
    }
  }

  /** 滑块可移动范围（0 ~ 底栏宽度 - 滑块直径）。 */
  private bubbleMaxX(): number { return Math.max(0, this.barWidth() - this.bubbleSize()); }
  /** 当前手指位置对应的 Tab 序号。 */
  private indexAt(x: number): number {
    const count: number = Math.max(1, this.routes().length);
    const relative: number = (x + this.bubbleSize() / 2) / Math.max(1, this.barWidth());
    const index: number = Math.floor(relative * count);
    return Math.max(0, Math.min(count - 1, index));
  }
  /** 拖动挤压强度：速度越快顶得越明显（0~1），用于鼓包高度。 */
  private dockSqueeze(): number {
    return Math.max(0, Math.min(1, this.dockSqueezeValue));
  }

  /** 按下/拖动时滑块直径要大于底栏高度，宽高同步放大保持正圆。 */
  private pressedBubbleScale(): number {
    const target: number = this.barHeight() * 1.24;
    return Math.max(1, target / Math.max(1, this.bubbleSize()));
  }
  /** 长按开始拖动：滑块跟手，并先给出一个轻微的"被捏起"形变。 */
  private beginDockDrag(): void {
    if (this.hidden) { return; }
    this.dockDragging = true;
    this.dockDragMoved = false;
    this.dockDragIndex = this.activeIndex();
    this.dockDragX = this.bubbleXInner();
    this.dockDragStartX = this.dockDragX;
    this.dockSqueezeValue = 0.35;
    // 按下即启动挤压脉冲动画。
    this.startSqueezePulse();
  }
  /** 不进入拖动时的静态位置（避免 bubbleX 在拖动时返回 dragX 造成自引用）。 */
  private bubbleXInner(): number {
    return this.pad() + this.cell() * this.activeIndex() + (this.cell() - this.bubbleSize()) / 2;
  }
  /** 拖动中：滑块中心直接跟手（手指 x - 半径），并按速度等比放大。 */
  private updateDockDrag(fingerX: number, velocityX: number): void {
    if (!this.dockDragging) { return; }
    this.dockDragMoved = true;
    // 让滑块中心始终落在手指下方，而不是只按位移增量平移。
    const followX: number = fingerX - this.bubbleSize() / 2;
    const nextX: number = Math.max(0, Math.min(this.bubbleMaxX(), followX));
    this.dockDragX = nextX;
    this.dockDragIndex = this.indexAt(nextX);
    // 速度只影响等比放大（宽高同步），滑块始终保持正圆且直径大于底栏高度。
    const speed: number = Math.min(1, Math.abs(velocityX) / 1800);
    this.squeezeBase = this.pressedBubbleScale() * (1 + 0.12 * speed);
    this.dockSqueezeValue = 0.25 + 0.75 * speed;
    this.applySqueeze();
  }
  /** 按压期间的物理挤压动画：每 260ms 在「收紧 / 回弹」之间往复。 */
  private startSqueezePulse(): void {
    this.stopSqueezePulse();
    this.squeezeBase = this.pressedBubbleScale();
    this.squeezePulse = true;
    this.applySqueeze();
    this.squeezeTimer = setInterval(() => {
      this.squeezePulse = !this.squeezePulse;
      this.applySqueeze();
    }, 260);
  }

  private stopSqueezePulse(): void {
    if (this.squeezeTimer !== -1) {
      clearInterval(this.squeezeTimer);
      this.squeezeTimer = -1;
    }
    this.squeezePulse = false;
  }

  /** 把基准倍率与脉冲合成到滑块缩放上（宽高同步，保持正圆）。 */
  private applySqueeze(): void {
    const factor: number = this.squeezePulse ? 0.96 : 1.02;
    this.stretchX = this.squeezeBase * factor;
    this.stretchY = this.squeezeBase * factor;
    // 底栏鼓包跟着一起呼吸。
    this.dockSqueezeValue = this.squeezePulse ? 0.25 : 0.9;
  }

  /** 复位拖动相关状态（切页、点击、失焦时兜底）。 */
  private resetDockDragState(): void {
    this.stopSqueezePulse();
    this.dockDragging = false;
    this.dockDragMoved = false;
    this.dockSqueezeValue = 0.35;
    this.stretchX = 1;
    this.stretchY = 1;
    this.touchGlowOn = false;
    this.clearDockPressTimer();
  }

  /** 松手：吸附到最近 Tab，命中其它 Tab 时切换页面。 */
  private endDockDrag(): void {
    if (!this.dockDragging) { return; }
    this.stopSqueezePulse();
    const target: number = this.dockDragIndex;
    const moved: boolean = this.dockDragMoved;
    this.dockDragging = false;
    this.dockDragMoved = false;
    // 回弹到正圆，交给液态缓动。
    this.stretchX = 1;
    this.stretchY = 1;
    if (!moved && target === this.activeIndex()) { return; }
    const routes: string[] = this.routes();
    if (target >= 0 && target < routes.length && routes[target] !== this.page) {
      try {
        if (routes[target] === 'manage') { AppStorage.setOrCreate<number>('manageInitialTab', 0); }
        this.getUIContext().animateTo({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn }, () => {
          AppState.go(routes[target]);
        });
      } catch (error) {
        Logger.error('LiquidNav', '拖动切换导航失败：' + String(error));
        AppState.go(routes[target]);
      }
    }
  }
  /** 取消拖动（长按后没移动就松手）：回到当前选中位置。 */
  private cancelDockDrag(): void {
    if (!this.dockDragging) { return; }
    this.stopSqueezePulse();
    this.dockDragging = false;
    this.dockDragMoved = false;
    this.stretchX = 1;
    this.stretchY = 1;
  }
  private bubbleY(): number { return (this.barHeight() - this.bubbleSize()) / 2; }
  private stripHeight(): number {
    const base: number = this.landscape() ? 54 : (this.tablet() ? 96 : 78);
    return Math.round(base * this.dockFactor());
  }
  private glassBlur(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }

  /** 实际强度系数：强度设置 × 低电量降级（电量越低越弱，最低 35%）。 */
  private dockFactorIntensity(): number {
    const base: number = Math.max(0, Math.min(100, this.dockIntensity)) / 100;
    if (!this.dockBatteryAuto || this.dockBatteryThreshold <= 0 || this.dockBatteryPercent > this.dockBatteryThreshold) {
      return base;
    }
    const ratio: number = Math.max(0, Math.min(1, this.dockBatteryPercent / this.dockBatteryThreshold));
    return Math.max(0.35, base * (0.45 + 0.55 * ratio));
  }
  /** 三种样式的模糊倍率：高斯模糊最强、液态玻璃基准、沉浸光感略强。 */
  private styleBlurFactor(): number {
    if (this.dockStyle === 'blur') { return 1.45; }
    if (this.dockStyle === 'glow') { return 1.15; }
    // Liquid Glass：厚重虚化 + 多层高光模拟玻璃折射。
    return 1.6;
  }
  /**
   * 系统级「沉浸光感」材质（HarmonyOS 6 / API 26 的 uiMaterial.ImmersiveMaterial）：
   * 由系统材质层实现光照与折射，比自绘着色器更接近真实液态玻璃。
   */
  private dockSystemMaterial(): uiMaterial.Material | undefined {
    try {
      if (!uiMaterial.isImmersiveMaterialSupported()) { return undefined; }
      const style: uiMaterial.ImmersiveStyle = this.dockStyle === 'blur'
        ? uiMaterial.ImmersiveStyle.REGULAR
        : (this.dockStyle === 'glow' ? uiMaterial.ImmersiveStyle.THICK : uiMaterial.ImmersiveStyle.THIN);
      return new uiMaterial.ImmersiveMaterial({ style: style });
    } catch (error) {
      Logger.warn('DOCK_GLASS', '系统沉浸材质不可用：' + String(error));
      return undefined;
    }
  }
  /**
   * 底栏底色：透明度跟随「沉浸外观 · Dock 栏透明度」。
   * 模糊越强 → 底色越淡（更透，玻璃折射感越明显）；模糊为 0 时回到较实的底色。
   */
  private dockTint(): string {
    const level: number = Math.max(0, Math.min(81, this.glassBlur())) / 81;
    const alpha: number = Math.round((0.62 - 0.34 * level) * 255);
    const hex: string = alpha.toString(16).toUpperCase().padStart(2, '0');
    return this.dark ? '#' + hex + '141A26' : '#' + hex + 'FFFFFF';
  }

  /** 液态玻璃底色：极低不透明度，把画面让给原生渲染层。 */
  private dockTintLiquid(): string {
    const level: number = Math.max(0, Math.min(81, this.glassBlur())) / 81;
    const alpha: number = Math.round((0.34 - 0.24 * level) * 255);
    const hex: string = alpha.toString(16).toUpperCase().padStart(2, '0');
    return this.dark ? '#' + hex + '141A26' : '#' + hex + 'FFFFFF';
  }


  /** 底栏背景模糊半径。 */
  private dockBlur(): number {
    return Math.max(0, this.glassBlur()) * (0.35 + this.dockFactorIntensity() * 1.25) * this.styleBlurFactor();
  }
  /** 底栏原生模糊材质：按样式选系统材质档位。 */
  private nativeBlurStyle(): BlurStyle {
    if (this.dockStyle === 'blur') { return BlurStyle.COMPONENT_ULTRA_THICK; }
    if (this.dockStyle === 'glow') { return BlurStyle.COMPONENT_THICK; }
    return BlurStyle.COMPONENT_REGULAR;
  }
  /** 滑块原生模糊材质：比底栏再厚一档，保证选中态可辨。 */
  private nativeBubbleBlurStyle(): BlurStyle {
    if (this.dockStyle === 'blur') { return BlurStyle.COMPONENT_ULTRA_THICK; }
    return BlurStyle.COMPONENT_THICK;
  }
  /**
   * 高亮层配色：
   * - liquid（Liquid Glass）：斜向白光反射 + 边缘高光，最接近 iOS 26 的液态玻璃；
   * - glow（沉浸光感）：主题色柔光；
   * - blur（高斯模糊）：不叠高光（透明度为 0）。
   */
  private sheenColors(): Array<[ResourceColor, number]> {
    if (this.dockStyle === 'glow') {
      return [
        [Ui.accentGlow(this.dark), 0],
        [Ui.accentSoft(this.dark), 0.5],
        ['#00000000', 1]
      ];
    }
    if (this.dockStyle === 'liquid') {
      return [
        ['#66FFFFFF', 0],
        ['#33FFFFFF', 0.32],
        ['#14FFFFFF', 0.62],
        ['#00000000', 1]
      ];
    }
    return [[Ui.glassSheenTop(this.dark), 0], [Ui.glassSheenClear(), 1]];
  }
  /** 玻璃边缘高光：Liquid Glass 需要一圈亮边来表现厚度与折射。 */
  private dockBorderColor(): string {
    if (this.dockStyle === 'liquid') {
      return this.dark ? '#40FFFFFF' : '#59FFFFFF';
    }
    return Ui.glassRingSoft(this.dark);
  }

  /** 液态高亮层的透明度：高斯模糊样式不叠高光。 */
  private sheenOpacity(): number {
    // 高光层配色恢复：高斯模糊样式不叠高光，其余按强度控制亮度。
    if (this.dockStyle === 'blur') { return 0; }
    return Math.min(1, 0.45 + this.dockFactorIntensity() * 0.55);
  }
  /** 沉浸光感：主题色光晕；其它样式沿用普通投影。 */
  private dockShadowColor(): string {
    // 恢复：沉浸光感用主题色光晕，其余用中性投影。
    return this.dockStyle === 'glow' ? Ui.accentGlow(this.dark) : Ui.shadow(this.dark);
  }
  private dockShadowRadius(): number {
    return Math.round((this.dockStyle === 'glow' ? 30 : 26) * (0.6 + this.dockFactorIntensity() * 0.6));
  }
  /** 高斯模糊样式加一道细描边，让边缘更清晰。 */
  private dockBorderWidth(): number { return this.dockStyle === 'blur' || this.dockStyle === 'liquid' ? 1 : 0; }
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
    // 切页后复位拖动状态，避免滑块卡在被按下的放大形态。
    this.resetDockDragState();
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
      .borderRadius('14vp')
      .backgroundColor(this.hovered === route ? Ui.accentSoft(this.dark) : '#00000000')
      .shadow({
        radius: this.hovered === route ? 14 : 0,
        color: this.hovered === route ? Ui.accentGlow(this.dark) : '#00000000',
        offsetY: 0
      })
      .scale({
        x: this.pressed === route ? 0.88 : (this.hovered === route ? 1.06 : 1),
        y: this.pressed === route ? 0.88 : (this.hovered === route ? 1.06 : 1)
      })
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
      .onHover((isHover: boolean) => {
        this.hovered = isHover ? route : (this.hovered === route ? '' : this.hovered);
      })
      .accessibilityText(NavTabs.title(route) + (this.page === route ? '，已选中' : '，点击切换'))
      .onTouch((event: TouchEvent) => {
        this.pressed = event.type === TouchType.Down ? route : '';
      })
      .onClick(() => {
        if (Date.now() < this.dockSuppressClickUntil) { return; }
        this.resetDockDragState();
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
        // 玻璃本体斜向渐变高光。
        Row()
          .width('100%').height('100%')
          .linearGradient({
            angle: this.dockStyle === 'liquid' ? 105 : 118,
            colors: this.sheenColors()
          })
          .opacity(this.sheenOpacity())
          .hitTestBehavior(HitTestMode.None)
        // 恢复：液态玻璃三层（顶部镜面弧 / 底部内反射 / 厚度描边）。
        if (this.dockStyle === 'liquid') {
          Column()
            .width('92%')
            .height('52%')
            .borderRadius(this.barHeight())
            .linearGradient({
              angle: 180,
              colors: [['#F2FFFFFF', 0], ['#66FFFFFF', 0.55], ['#00FFFFFF', 1]]
            })
            .opacity(0.6)
            .translate({ x: this.barWidth() * 0.04, y: 1 })
            .hitTestBehavior(HitTestMode.None)
          Column()
            .width('86%')
            .height('34%')
            .borderRadius(this.barHeight())
            .linearGradient({
              angle: 0,
              colors: [['#00FFFFFF', 0], ['#4DFFFFFF', 1]]
            })
            .opacity(0.5)
            .translate({ x: this.barWidth() * 0.07, y: this.barHeight() * 0.62 })
            .hitTestBehavior(HitTestMode.None)
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(this.barRadius())
            .border({ width: '1.5vp', color: '#4DFFFFFF' })
            .hitTestBehavior(HitTestMode.None)
        }
        // 沉浸光感：触摸处浮现主题色柔光（颜色取 Ui.accentGlow / accentSoft，随主题切换）。
        if (this.glowVisible()) {
          Column()
            .width(this.glowSize())
            .height(this.glowSize())
            .borderRadius(this.glowSize() / 2)
            .radialGradient({
              center: [this.glowSize() / 2, this.glowSize() / 2],
              radius: this.glowSize() / 2,
              colors: [
                [Ui.accentGlow(this.dark), 0],
                [Ui.accentSoft(this.dark), 0.55],
                ['#00000000', 1]
              ]
            })
            .opacity(0.85)
            .translate({ x: this.glowX(), y: (this.barHeight() - this.glowSize()) / 2 })
            .animation({ duration: 180, curve: Curve.EaseOut })
            .hitTestBehavior(HitTestMode.None)
        }
        // 拖动时：滑块从内部把底栏向外顶出一块鼓包，形成液体被挤压的观感。
        if (this.dockDragging) {
          Column()
            .width(Math.round(this.bubbleSize() * 1.42))
            .height(Math.round(this.barHeight() * (1 + 0.16 * this.dockSqueeze())))
            .borderRadius(this.barHeight())
            .backgroundColor(Ui.glassTint(this.dark))
            .backdropBlur(this.dockStyle === 'liquid' ? 0 : this.dockBlur())
            .border({ width: 1, color: this.dockBorderColor() })
            .translate({
              x: this.bubbleX() + (this.bubbleSize() - Math.round(this.bubbleSize() * 1.42)) / 2,
              y: (this.barHeight() - Math.round(this.barHeight() * (1 + 0.16 * this.dockSqueeze()))) / 2
            })
            .animation({ duration: this.dockDragging ? 0 : 200, curve: Curve.EaseOut })
            .hitTestBehavior(HitTestMode.None)
        }
        // 圆形选中指示器：跨平台统一使用 ArkUI 玻璃渐变 + backdropBlur。
        Column() {
          Column()
            .width(this.bubbleSize())
            .height(this.bubbleSize())
            .borderRadius(this.bubbleSize() / 2)
            .linearGradient({
              angle: 152,
              colors: this.dark
                ? [['#8C000000', 0], ['#4D000000', 0.52], ['#1A000000', 1]]
                : [['#8CFFFFFF', 0], ['#4DFFFFFF', 0.52], ['#1AFFFFFF', 1]]
            })
            .backdropBlur(18)
        }
          .width(this.bubbleSize())
          .height(this.bubbleSize())
          .scale({ x: this.stretchX, y: this.stretchY })
          .translate({ x: this.bubbleX(), y: this.bubbleY() })
          // 拖动中跟手（零时长），松手后回到液态缓动。
          .animation({ duration: this.dockDragging ? 0 : UiMotion.LIQUID, curve: Curve.FastOutSlowIn })
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
        .borderRadius(this.barRadius())
        // 恢复：系统沉浸材质 + 半透明底色 + 背景模糊，再叠 AppleUI 透镜。
        .systemMaterial(this.dockSystemMaterial())
        .backgroundColor(this.dockTint())
        .backdropBlur(this.dockBlur())
        .border({ width: this.dockBorderWidth(), color: this.dockBorderColor() })
        .shadow({ radius: this.dockShadowRadius(), color: this.dockShadowColor(), offsetY: 10 })
        // 拖动时滑块直径大于底栏高度，需要放开裁剪让它完整露出。
        .clip(!this.dockDragging)
        .hoverEffect(HoverEffect.None)
        // 长按拖动用 onTouch 自行判定：Tab 自带 onClick，用 gesture 会被子组件抢走识别权。
        .onTouch((event: TouchEvent) => { this.handleDockTouch(event); })

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
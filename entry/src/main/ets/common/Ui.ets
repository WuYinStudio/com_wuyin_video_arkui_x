/*
 * 无音影视 · 液态玻璃设计系统（令牌层）
 *
 * 说明：
 * 1. 这里只放"纯值"（颜色字符串、圆角、间距、断点、字阶），不放任何 UI 组件，
 *    因此各页面、各共用组件都可以安全引用，不会产生循环依赖。
 * 2. 深浅模式由 @StorageLink('darkTheme') 发布的布尔值驱动（与 AppState 一致），
 *    所有取值方法都显式接收 dark，页面函数体里不要硬编码十六进制色值。
 * 3. 材质（毛玻璃）强度统一由 immersiveConfig 换算，保证"搜索条 / 底栏 / 卡片"
 *    在全局设置变化时同步变糊或变清，不会出现两套材质。
 * 4. 主题商城通过 ThemeService 提供 27 套主色与自定义背景；这里的品牌色、页面底色、
 *    主色全部转发到 ThemeService，因此旧页面无需逐个改造即可跟随主题。
 */
import { ThemeService } from './ThemeService';

/** 全局动效时长（毫秒），统一节奏：快=按压反馈，中=常规过渡，慢=液态位移。 */
export class UiMotion {
  static readonly PRESS: number = 140;
  static readonly FAST: number = 180;
  static readonly BASE: number = 240;
  static readonly SLOW: number = 380;
  static readonly LIQUID: number = 460;
}

/** 半径、间距、断点、字阶与配色。 */
export class Ui {
  // ---------- 品牌色（跟随当前主题） ----------
  static brandFrom(): string { return ThemeService.brandFrom(); }
  static brandMid(): string { return ThemeService.brandMid(); }
  static brandTo(): string { return ThemeService.brandTo(); }
  static readonly BRAND_WARM: string = '#FF7A9C';

  // ---------- 圆角 ----------
  static readonly R_XS: number = 10;
  static readonly R_SM: number = 14;
  static readonly R_MD: number = 18;
  static readonly R_LG: number = 24;
  static readonly R_XL: number = 30;
  static readonly R_PILL: number = 999;

  // ---------- 间距 ----------
  static readonly S_XS: number = 6;
  static readonly S_SM: number = 10;
  static readonly S_MD: number = 14;
  static readonly S_LG: number = 18;
  static readonly S_XL: number = 24;
  static readonly S_XXL: number = 32;

  // ---------- 多端断点（vp） ----------
  static isTablet(width: number): boolean {
    return Number.isFinite(width) && width >= 600;
  }
  static isWide(width: number): boolean {
    return Number.isFinite(width) && width >= 1000;
  }
  static isCompact(width: number): boolean {
    return !Number.isFinite(width) || width < 380;
  }
  /** 页面左右留白：手机 16，折叠/平板 24，宽屏 32。 */
  static gutter(width: number): number {
    if (!Number.isFinite(width)) { return 16; }
    if (width >= 1000) { return 32; }
    if (width >= 600) { return 24; }
    return width < 360 ? 14 : 16;
  }
  /** 内容最大宽度：宽屏居中，避免大屏上内容被拉成超宽行。 */
  static contentMax(width: number): number {
    return Ui.isWide(width) ? 1180 : width;
  }
  /** 影片网格列数。 */
  static columns(width: number): number {
    if (width >= 1180) { return 4; }
    if (width >= 900) { return 3; }
    if (width >= 600) { return 2; }
    return 1;
  }

  // ---------- 字阶（返回 vp 字符串，直接可用于 .fontSize） ----------
  static fsDisplay(width: number): string { return Ui.isTablet(width) ? '34vp' : (Ui.isCompact(width) ? '24vp' : '27vp'); }
  static fsHero(width: number): string { return Ui.isTablet(width) ? '32vp' : '23vp'; }
  static fsSection(width: number): string { return Ui.isTablet(width) ? '24vp' : '20vp'; }
  static fsTitle(width: number): string { return Ui.isTablet(width) ? '20vp' : '17vp'; }
  static fsBody(width: number): string { return Ui.isTablet(width) ? '15vp' : '14vp'; }
  static fsCaption(width: number): string { return Ui.isTablet(width) ? '13vp' : '11.5vp'; }

  // ---------- 全局界面尺寸（设置页「界面尺寸」可调，AppStorage 键 fontScale / dockScale） ----------
  /** 全局字体缩放区间：0.85 倍（紧凑）~ 1.30 倍（大字号）。 */
  static readonly FONT_SCALE_MIN: number = 0.85;
  static readonly FONT_SCALE_MAX: number = 1.30;
  /** 底部 Dock 栏缩放区间：0.85 倍（小）~ 1.25 倍（大）。 */
  static readonly DOCK_SCALE_MIN: number = 0.85;
  static readonly DOCK_SCALE_MAX: number = 1.25;
  static readonly DEFAULT_FONT_SCALE: number = 1;
  static readonly DEFAULT_DOCK_SCALE: number = 1;

  /** 把任意来源的缩放值收敛到 [min, max]，非法值回落到 def。 */
  static clampScale(value: number, min: number, max: number, def: number = 1): number {
    const numeric: number = Number(value);
    if (!Number.isFinite(numeric)) { return def; }
    return Math.max(min, Math.min(max, numeric));
  }
  static fontScale(value: number): number {
    return Ui.clampScale(value, Ui.FONT_SCALE_MIN, Ui.FONT_SCALE_MAX, Ui.DEFAULT_FONT_SCALE);
  }
  static dockScale(value: number): number {
    return Ui.clampScale(value, Ui.DOCK_SCALE_MIN, Ui.DOCK_SCALE_MAX, Ui.DEFAULT_DOCK_SCALE);
  }
  /**
   * 全局字体缩放：把字面量字号（如 '14.5vp'）按 scale 换算成新的 vp 字符串。
   * 页面把 scale 作为 `@StorageLink('fontScale')` 传入，缩放值变化时本页随之重建。
   */
  static fs(size: string, scale: number = 1): string {
    if (!size) { return size; }
    const text: string = String(size).trim();
    const numeric: number = parseFloat(text);
    if (!Number.isFinite(numeric)) { return size; }
    const factor: number = Ui.fontScale(scale);
    if (Math.abs(factor - 1) < 0.001) { return text; }
    const scaled: number = Math.round(numeric * factor * 10) / 10;
    return scaled + 'vp';
  }
  /** 字号缩放百分比文案：1.15 => '115%'。 */
  static scalePercent(scale: number, fallback: number = 100): string {
    const numeric: number = Number(scale);
    if (!Number.isFinite(numeric)) { return String(fallback) + '%'; }
    return String(Math.round(numeric * 100)) + '%';
  }

  // ---------- 背景 ----------
  /** 页面底色：优先使用自定义背景，其次使用当前主题底色。 */
  static pageBg(dark: boolean): string { return ThemeService.pageBg(dark); }
  static pageBgAlt(dark: boolean): string { return ThemeService.pageBgAlt(dark); }

  /** 极光光晕（radialGradient 用），alpha 已内置。 */
  static auroraViolet(dark: boolean): string { return dark ? '#7A5CFF66' : '#8B7BFF3D'; }
  static auroraCyan(dark: boolean): string { return dark ? '#00C2FF4D' : '#41C6FF33'; }
  static auroraRose(dark: boolean): string { return dark ? '#FF4D7D33' : '#FF86A629'; }
  static auroraFade(): string { return '#00000000'; }

  // ---------- 文本 ----------
  static ink(dark: boolean): string { return dark ? '#F4F7FF' : '#0C1728'; }
  static inkSoft(dark: boolean): string { return dark ? '#A7B4C9' : '#4F6178'; }
  static inkFaint(dark: boolean): string { return dark ? '#6E7E95' : '#8493A6'; }
  static inkOnMedia(dark: boolean): string { return '#FFFFFF'; }

  // ---------- 主色 ----------
  static accent(dark: boolean): string { return ThemeService.accent(dark); }
  static accentStrong(dark: boolean): string { return ThemeService.accentStrong(dark); }
  /** 主色淡底（选中态、标签底）。 */
  static accentSoft(dark: boolean): string { return ThemeService.accentSoft(dark); }
  static accentRing(dark: boolean): string { return ThemeService.accentRing(dark); }
  static accentGlow(dark: boolean): string { return ThemeService.accentGlow(dark); }
  static gold(dark: boolean): string { return dark ? '#FFCF87' : '#B4740C'; }
  static goldSoft(dark: boolean): string { return dark ? '#33FFCF87' : '#1FB4740C'; }

  // ---------- 液态玻璃 ----------
  /** 玻璃底色：深色是"墨玻璃"，浅色是"乳白玻璃"。 */
  static glassTint(dark: boolean): string { return dark ? '#8C141A26' : '#A6FFFFFF'; }
  static glassTintStrong(dark: boolean): string { return dark ? '#BF181F2E' : '#D9FFFFFF'; }
  static glassTintSoft(dark: boolean): string { return dark ? '#66101620' : '#8CFFFFFF'; }
  /** 玻璃描边：高光在上、侧壁略暗，制造厚度感。浅色模式用极淡的墨蓝细边，保证白底上也有轮廓。 */
  static glassRing(dark: boolean): string { return dark ? '#2EFFFFFF' : '#1A173156'; }
  static glassRingSoft(dark: boolean): string { return dark ? '#1AFFFFFF' : '#12173156'; }
  static glassRingAccent(dark: boolean): string { return ThemeService.accentRing(dark); }
  static glassSheenTop(dark: boolean): string { return dark ? '#2BFFFFFF' : '#F2FFFFFF'; }
  static glassSheenMid(dark: boolean): string { return dark ? '#0AFFFFFF' : '#33FFFFFF'; }
  static glassSheenClear(): string { return '#00FFFFFF'; }
  /** 底栏/搜索条下方的投影。 */
  static shadow(dark: boolean): string { return dark ? '#A6000000' : '#26375199'; }
  static shadowSoft(dark: boolean): string { return dark ? '#66000000' : '#17375199'; }

  // ---------- 卡片 ----------
  static card(dark: boolean): string { return dark ? '#0DFFFFFF' : '#D9FFFFFF'; }
  static cardTop(dark: boolean): string { return dark ? '#14FFFFFF' : '#F2FFFFFF'; }
  static cardBottom(dark: boolean): string { return dark ? '#08FFFFFF' : '#CCFFFFFF'; }
  static cardBorder(dark: boolean): string { return dark ? '#1AFFFFFF' : '#14173156'; }
  static cardBorderSoft(dark: boolean): string { return dark ? '#10FFFFFF' : '#0F173156'; }
  static divider(dark: boolean): string { return dark ? '#14FFFFFF' : '#14173156'; }

  // ---------- 功能色 ----------
  static danger(dark: boolean): string { return dark ? '#FF8A9B' : '#D5314C'; }
  static success(dark: boolean): string { return dark ? '#6FE3B0' : '#128C63'; }
  static scrim(dark: boolean): string { return dark ? '#B3050810' : '#5908111F'; }

  // ---------- 材质强度 ----------
  /** 统一把全局沉浸配置换算成 backdropBlur 半径；关闭时返回 0。 */
  static blur(enabled: boolean, configured: number): number {
    if (!enabled) { return 0; }
    const value: number = Number.isFinite(configured) ? configured : 20;
    return Math.max(0, Math.min(60, value * 1.35));
  }
  /** 玻璃材质的基础模糊（与全局配置解耦的下限），保证"液态玻璃"始终有质感。 */
  static glassBlur(enabled: boolean, configured: number): number {
    const base: number = Ui.blur(enabled, configured);
    return enabled ? Math.max(14, base) : 0;
  }

  /** 底栏 / 底栏上方渐进模糊带 / 手势条的总占位高度（内嵌业务页的列表末尾避让）。 */
  static navBarHeight(width: number, viewportHeight: number, scale: number = 1): number {
    const landscape: boolean = viewportHeight > 0 && width > viewportHeight * 1.15;
    const base: number = landscape ? 62 : (Ui.isTablet(width) ? 84 : 70);
    return Math.round(base * Ui.dockScale(scale));
  }
  static navStripHeight(width: number, viewportHeight: number, scale: number = 1): number {
    const landscape: boolean = viewportHeight > 0 && width > viewportHeight * 1.15;
    const base: number = landscape ? 54 : (Ui.isTablet(width) ? 96 : 78);
    return Math.round(base * Ui.dockScale(scale));
  }
  static navClearance(width: number, viewportHeight: number, safeBottom: number, scale: number = 1): number {
    // 底栏上方的渐进模糊已移除，不再为它预留 78~96vp 的空白区域。
    return Ui.navBarHeight(width, viewportHeight, scale) + Math.max(0, safeBottom) + 16;
  }

  // ---------- 影片占位封面配色（接口无图时使用，按题材稳定取色） ----------
  static genreTop(genre: string, dark: boolean): string {
    switch (genre) {
      case '电影': return dark ? '#2B3A6E' : '#C9D6FF';
      case '电视剧': return dark ? '#1F3F52' : '#C6E9F2';
      case '动漫': return dark ? '#4A2A57' : '#F2D3F7';
      case '综艺': return dark ? '#4E3423' : '#FFE0C2';
      default: return dark ? '#243149' : '#D5E1F5';
    }
  }
  static genreBottom(genre: string, dark: boolean): string {
    switch (genre) {
      case '电影': return dark ? '#141B33' : '#93A9F5';
      case '电视剧': return dark ? '#0F2029' : '#8FCBE0';
      case '动漫': return dark ? '#241229' : '#D7A7E8';
      case '综艺': return dark ? '#241708' : '#FFC391';
      default: return dark ? '#111A28' : '#AFC4E4';
    }
  }
  /** 占位封面中央的大号符号（用题材首字，避免引入新图标资源）。 */
  static genreGlyph(genre: string): string {
    return genre && genre.length > 0 ? genre.substring(0, 1) : '影';
  }
}

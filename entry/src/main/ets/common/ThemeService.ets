import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppState, PlayerImmersiveConfig } from './AppState';
import { Logger } from './Logger';

export class ThemePreset {
  id: string = '';
  name: string = '';
  lightAccent: string = '';
  darkAccent: string = '';
  lightStrong: string = '';
  darkStrong: string = '';
  lightSoft: string = '';
  darkSoft: string = '';
  lightRing: string = '';
  darkRing: string = '';
  lightGlow: string = '';
  darkGlow: string = '';
  lightBg: string = '';
  lightBgAlt: string = '';
  darkBg: string = '';
  darkBgAlt: string = '';
  brandFrom: string = '';
  brandMid: string = '';
  brandTo: string = '';
}

export class WallpaperPreset {
  id: string = '';
  name: string = '';
  lightTop: string = '';
  lightBottom: string = '';
  darkTop: string = '';
  darkBottom: string = '';
}

class ThemeSeed {
  id: string;
  name: string;
  accent: string;

  constructor(id: string, name: string, accent: string) {
    this.id = id;
    this.name = name;
    this.accent = accent;
  }
}

/**
 * 27 套主题 + 自定义背景。
 *
 * 颜色统一由这里派生，Ui.ets 只负责读取；切换主题时替换一次 immersiveConfig 对象，
 * 借助各页面已有的 @StorageLink('immersiveConfig') 触发重绘，不需要逐页加主题监听。
 */
export class ThemeService {
  static readonly DEFAULT_THEME: string = 'aurora-blue';
  private static readonly STORE_KEY_THEME: string = 'themeId';
  private static readonly STORE_KEY_WALLPAPER: string = 'wallpaperId';
  private static store?: preferences.Preferences;
  private static initialized: boolean = false;
  private static currentId: string = ThemeService.DEFAULT_THEME;
  private static wallpaperId: string = '';
  private static cache: ThemePreset[] = [];

  private static readonly SEEDS: ThemeSeed[] = [
    new ThemeSeed('aurora-blue', '极光蓝', '#4B7BFF'),
    new ThemeSeed('mint', '薄荷青', '#22C7B8'),
    new ThemeSeed('twilight', '暮光紫', '#8B5CF6'),
    new ThemeSeed('sakura', '樱花粉', '#FF6FAE'),
    new ThemeSeed('amber', '琥珀橙', '#FF9A3D'),
    new ThemeSeed('emerald', '翡翠绿', '#10B981'),
    new ThemeSeed('ocean', '深海蓝', '#2563EB'),
    new ThemeSeed('nebula', '星云紫', '#A855F7'),
    new ThemeSeed('coral', '珊瑚红', '#FF5A5F'),
    new ThemeSeed('lemon', '柠檬黄', '#EAB308'),
    new ThemeSeed('forest', '森林绿', '#16A34A'),
    new ThemeSeed('glacier', '冰川灰', '#64748B'),
    new ThemeSeed('lava', '熔岩红', '#DC2626'),
    new ThemeSeed('peach', '蜜桃橙', '#FB7185'),
    new ThemeSeed('sky', '天空蓝', '#0EA5E9'),
    new ThemeSeed('lavender', '薰衣草', '#7C6CF6'),
    new ThemeSeed('lime', '青柠', '#84CC16'),
    new ThemeSeed('milktea', '奶茶棕', '#A16207'),
    new ThemeSeed('graphite', '石墨黑', '#475569'),
    new ThemeSeed('rosegold', '玫瑰金', '#E11D48'),
    new ThemeSeed('silver', '月光银', '#94A3B8'),
    new ThemeSeed('jade', '翡翠', '#059669'),
    new ThemeSeed('marine', '海洋', '#0891B2'),
    new ThemeSeed('violet', '紫罗兰', '#9333EA'),
    new ThemeSeed('sunset', '落日', '#F97316'),
    new ThemeSeed('ice', '冰川蓝', '#38BDF8'),
    new ThemeSeed('cherry', '樱桃', '#F43F5E')
  ];

  private static readonly WALLPAPERS: WallpaperPreset[] = ThemeService.buildWallpapers();

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (ThemeService.initialized) {
      return;
    }
    try {
      ThemeService.store = await preferences.getPreferences(context, 'wuyin');
      const savedTheme: string = String(await ThemeService.store.get(ThemeService.STORE_KEY_THEME, ThemeService.DEFAULT_THEME));
      const savedWallpaper: string = String(await ThemeService.store.get(ThemeService.STORE_KEY_WALLPAPER, ''));
      ThemeService.currentId = ThemeService.validTheme(savedTheme) ? savedTheme : ThemeService.DEFAULT_THEME;
      ThemeService.wallpaperId = ThemeService.validWallpaper(savedWallpaper) ? savedWallpaper : '';
      AppStorage.setOrCreate<string>('themeId', ThemeService.currentId);
      AppStorage.setOrCreate<string>('wallpaperId', ThemeService.wallpaperId);
      ThemeService.initialized = true;
      Logger.info('THEME_STORE', '主题已恢复：' + ThemeService.currentId + '，背景=' + ThemeService.wallpaperId);
    } catch (error) {
      Logger.error('THEME_STORE', '读取主题配置失败：' + String(error));
    }
  }

  static themes(): ThemePreset[] {
    if (ThemeService.cache.length > 0) {
      return ThemeService.cache;
    }
    const result: ThemePreset[] = [];
    for (const seed of ThemeService.SEEDS) {
      result.push(ThemeService.createPreset(seed));
    }
    ThemeService.cache = result;
    return result;
  }

  static wallpapers(): WallpaperPreset[] {
    return ThemeService.WALLPAPERS;
  }

  static active(): ThemePreset {
    const id: string = ThemeService.currentId;
    for (const item of ThemeService.themes()) {
      if (item.id === id) {
        return item;
      }
    }
    return ThemeService.themes()[0];
  }

  static currentThemeId(): string {
    return ThemeService.currentId;
  }

  static currentWallpaperId(): string {
    return ThemeService.wallpaperId;
  }

  static wallpaper(): WallpaperPreset | undefined {
    if (!ThemeService.wallpaperId) {
      return undefined;
    }
    for (const item of ThemeService.WALLPAPERS) {
      if (item.id === ThemeService.wallpaperId) {
        return item;
      }
    }
    return undefined;
  }

  static applyTheme(id: string): boolean {
    if (!ThemeService.validTheme(id)) {
      return false;
    }
    ThemeService.currentId = id;
    AppStorage.setOrCreate<string>('themeId', id);
    ThemeService.signalChange();
    ThemeService.persistTheme(id);
    Logger.info('THEME_STORE', '应用主题：' + id);
    return true;
  }

  static applyWallpaper(id: string): void {
    const next: string = ThemeService.validWallpaper(id) ? id : '';
    ThemeService.wallpaperId = next;
    AppStorage.setOrCreate<string>('wallpaperId', next);
    ThemeService.signalChange();
    ThemeService.persistWallpaper(next);
    Logger.info('THEME_STORE', next.length > 0 ? '应用自定义背景：' + next : '恢复默认背景');
  }

  static pageBg(dark: boolean): string {
    const wall: WallpaperPreset | undefined = ThemeService.wallpaper();
    if (wall !== undefined) {
      return dark ? wall.darkTop : wall.lightTop;
    }
    return dark ? ThemeService.active().darkBg : ThemeService.active().lightBg;
  }

  static pageBgAlt(dark: boolean): string {
    const wall: WallpaperPreset | undefined = ThemeService.wallpaper();
    if (wall !== undefined) {
      return dark ? wall.darkBottom : wall.lightBottom;
    }
    return dark ? ThemeService.active().darkBgAlt : ThemeService.active().lightBgAlt;
  }

  static accent(dark: boolean): string {
    return dark ? ThemeService.active().darkAccent : ThemeService.active().lightAccent;
  }

  static accentStrong(dark: boolean): string {
    return dark ? ThemeService.active().darkStrong : ThemeService.active().lightStrong;
  }

  static accentSoft(dark: boolean): string {
    return dark ? ThemeService.active().darkSoft : ThemeService.active().lightSoft;
  }

  static accentRing(dark: boolean): string {
    return dark ? ThemeService.active().darkRing : ThemeService.active().lightRing;
  }

  static accentGlow(dark: boolean): string {
    return dark ? ThemeService.active().darkGlow : ThemeService.active().lightGlow;
  }

  static brandFrom(): string {
    return ThemeService.active().brandFrom;
  }

  static brandMid(): string {
    return ThemeService.active().brandMid;
  }

  static brandTo(): string {
    return ThemeService.active().brandTo;
  }

  private static createPreset(seed: ThemeSeed): ThemePreset {
    const item: ThemePreset = new ThemePreset();
    item.id = seed.id;
    item.name = seed.name;
    item.lightAccent = ThemeService.mix(seed.accent, '#0B1220', 0.12);
    item.darkAccent = ThemeService.mix(seed.accent, '#FFFFFF', 0.24);
    item.lightStrong = ThemeService.mix(seed.accent, '#0B1220', 0.28);
    item.darkStrong = ThemeService.mix(seed.accent, '#FFFFFF', 0.46);
    item.lightSoft = ThemeService.alpha(seed.accent, '24');
    item.darkSoft = ThemeService.alpha(seed.accent, '38');
    item.lightRing = ThemeService.alpha(seed.accent, '80');
    item.darkRing = ThemeService.alpha(seed.accent, 'A0');
    item.lightGlow = ThemeService.alpha(seed.accent, '4D');
    item.darkGlow = ThemeService.alpha(seed.accent, '66');
    item.lightBg = ThemeService.mix('#FFFFFF', seed.accent, 0.035);
    item.lightBgAlt = ThemeService.mix('#F4F6FB', seed.accent, 0.065);
    item.darkBg = ThemeService.mix('#212121', seed.accent, 0.04);
    item.darkBgAlt = ThemeService.mix('#171A21', seed.accent, 0.075);
    item.brandFrom = ThemeService.mix(seed.accent, '#FFFFFF', 0.04);
    item.brandMid = ThemeService.mix(seed.accent, '#6E6BFF', 0.42);
    item.brandTo = ThemeService.mix(seed.accent, '#9B5CFF', 0.68);
    return item;
  }

  private static buildWallpapers(): WallpaperPreset[] {
    const list: WallpaperPreset[] = [];
    const seeds: string[][] = [
      ['aurora-night', '极光夜', '#0B1026', '#1A2A6C', '#05070F', '#101A3A'],
      ['dusk', '暮色', '#2B1055', '#7597DE', '#160A2B', '#3A4B78'],
      ['lime', '青柠', '#134E5E', '#71B280', '#0A2A31', '#2E5A3D'],
      ['sakura', '樱雾', '#FFDEE9', '#B5FFFC', '#4A2A38', '#1E3A3A'],
      ['deepsea', '深海', '#000428', '#004E92', '#000214', '#002A50'],
      ['amber', '琥珀', '#FF8008', '#FFC837', '#4A2503', '#5A3A08'],
      ['stardust', '星尘', '#3A1C71', '#D76D77', '#1C0D38', '#5A2E34'],
      ['pine', '松林', '#0F2027', '#2C5364', '#071014', '#162A33'],
      ['rose', '玫瑰', '#F8CDDA', '#1D2B64', '#3A1E28', '#101A3A'],
      ['glacier-sky', '冰川', '#E0EAFC', '#CFDEF3', '#2A3448', '#3A4A66'],
      ['lava', '熔岩', '#200122', '#6F0000', '#120014', '#3A0000'],
      ['mist', '薄雾', '#B993D6', '#8CA6DB', '#3A2A48', '#2A3A5A']
    ];
    for (const seed of seeds) {
      const item: WallpaperPreset = new WallpaperPreset();
      item.id = seed[0];
      item.name = seed[1];
      item.lightTop = seed[2];
      item.lightBottom = seed[3];
      item.darkTop = seed[4];
      item.darkBottom = seed[5];
      list.push(item);
    }
    return list;
  }

  private static validTheme(id: string): boolean {
    for (const item of ThemeService.themes()) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  private static validWallpaper(id: string): boolean {
    if (!id) {
      return false;
    }
    for (const item of ThemeService.WALLPAPERS) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  /** 替换一次沉浸配置对象，复用各页面已有的 StorageLink 触发主题重绘。 */
  private static signalChange(): void {
    const version: number = (AppStorage.get<number>('themeVersion') || 0) + 1;
    AppStorage.setOrCreate<number>('themeVersion', version);
    const config: PlayerImmersiveConfig = AppState.immersiveConfig;
    const next: PlayerImmersiveConfig = {
      immersiveEnable: config.immersiveEnable,
      immersiveBlur: config.immersiveBlur,
      immersiveOpacity: config.immersiveOpacity,
      autoColorEnable: config.autoColorEnable
    };
    AppStorage.setOrCreate<PlayerImmersiveConfig>('immersiveConfig', next);
  }

  private static persistTheme(id: string): void {
    const store: preferences.Preferences | undefined = ThemeService.store;
    if (store === undefined) {
      return;
    }
    const target: preferences.Preferences = store;
    target.put(ThemeService.STORE_KEY_THEME, id).then(() => target.flush()).catch((error: Error) => {
      Logger.error('THEME_STORE', '保存主题失败：' + String(error));
    });
  }

  private static persistWallpaper(id: string): void {
    const store: preferences.Preferences | undefined = ThemeService.store;
    if (store === undefined) {
      return;
    }
    const target: preferences.Preferences = store;
    target.put(ThemeService.STORE_KEY_WALLPAPER, id).then(() => target.flush()).catch((error: Error) => {
      Logger.error('THEME_STORE', '保存背景失败：' + String(error));
    });
  }

  private static mix(first: string, second: string, ratio: number): string {
    const a: string = ThemeService.normalize(first);
    const b: string = ThemeService.normalize(second);
    const r: number = Math.round(parseInt(a.substring(0, 2), 16) * (1 - ratio) + parseInt(b.substring(0, 2), 16) * ratio);
    const g: number = Math.round(parseInt(a.substring(2, 4), 16) * (1 - ratio) + parseInt(b.substring(2, 4), 16) * ratio);
    const bl: number = Math.round(parseInt(a.substring(4, 6), 16) * (1 - ratio) + parseInt(b.substring(4, 6), 16) * ratio);
    return '#' + ThemeService.hex(r) + ThemeService.hex(g) + ThemeService.hex(bl);
  }

  private static alpha(base: string, alphaHex: string): string {
    return '#' + alphaHex + ThemeService.normalize(base);
  }

  private static normalize(value: string): string {
    let result: string = value.startsWith('#') ? value.substring(1) : value;
    if (result.length > 6) {
      result = result.substring(result.length - 6);
    }
    while (result.length < 6) {
      result = '0' + result;
    }
    return result.toUpperCase();
  }

  private static hex(value: number): string {
    const clamped: number = Math.max(0, Math.min(255, value));
    const text: string = clamped.toString(16).toUpperCase();
    return text.length < 2 ? '0' + text : text;
  }
}

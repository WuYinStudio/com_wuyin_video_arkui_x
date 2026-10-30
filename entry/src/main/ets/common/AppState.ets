import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Logger } from './Logger';
import { ImmersiveService } from './ImmersiveService';

export interface PlayerImmersiveConfig {
  immersiveEnable: boolean;
  immersiveBlur: number;
  immersiveOpacity: number;
  autoColorEnable: boolean;
}
export class ImmersiveConfig {
  enabled: boolean = true;
  blur: number = 20;
  opacity: number = 0.8;
  dark: boolean = true;
  autoColorEnable: boolean = true;
}
export class Film {
  id: number = 0;
  name: string = '';
  genre: string = '';
  region: string = '中国';
  year: string = '2025';
  score: number = 8.5;
  description: string = '';
  source: string = '';
  episodes: number = 12;
  constructor(id: number, name: string, genre: string, description: string) {
    this.id = id; this.name = name; this.genre = genre; this.description = description;
  }
}
export class WatchRecord {
  id: number = 0;
  episode: number = 1;
  position: number = 0;
  duration: number = 0;
  time: string = '';
  name: string = '';
  cover: string = '';
  vodId: string = '';
  wzlj: string = '';
}
export interface RecordVideoSource {
  vodId: string;
  tilie: string;
  yhm: string;
  feng: string;
  wzlj: string;
}
interface RecordRouteParams {
  vodId?: string;
  tilie?: string;
  yhm?: string;
  feng?: string;
  wzlj?: string;
}
export class AppState {
  static config: ImmersiveConfig = new ImmersiveConfig();
  static playerKernel: string = 'ijk';
  static themeMode: string = 'system';
  // 聊天提醒：提示音 / 顶部弹窗 / 免打扰，均由设置页开关持久化后发布到 AppStorage。
  static chatSoundEnabled: boolean = true;
  static chatBannerEnabled: boolean = true;
  static chatDndEnabled: boolean = false;
  // 提醒弹窗位置：top（默认，贴紧屏幕正上方）/ center / bottom；offset 为垂直微调（vp）。
  static chatAlertPosition: string = 'top';
  static chatAlertOffset: number = 0;
  // 后台通知栏提醒：应用退到后台时继续轮询，并通过系统通知栏提醒新消息。
  static chatBackgroundNotify: boolean = true;
  // 界面尺寸：底部 Dock 栏缩放与全局字体缩放（1 = 原始尺寸）。
  static dockScale: number = 1;
  static fontScale: number = 1;
  private static systemDark: boolean = true;
  private static publishedDark: boolean = true;
  private static favoritesLoaded: boolean = false;
  private static favoriteEdits: Map<number, boolean> = new Map();
  private static persistence: Promise<void> = Promise.resolve();
  static immersiveConfig: PlayerImmersiveConfig = {
    immersiveEnable: true, immersiveBlur: 20, immersiveOpacity: 0.8, autoColorEnable: true
  };
  static films: Film[] = [new Film(1, '星河之旅', '电影', '穿越星海，寻找生命的答案'), new Film(2, '山海之间', '电视剧', '在烟火人间，遇见温暖故事'), new Film(3, '风起少年', '动漫', '奔赴属于少年的冒险'), new Film(4, '周末漫游', '综艺', '一起发现城市里的美好'), new Film(5, '长夜微光', '电影', '每一束微光都值得守护'), new Film(6, '远方来信', '电视剧', '让思念抵达远方')];
  static favorites: number[] = [];
  static favoriteRecords: WatchRecord[] = [];
  static history: WatchRecord[] = [];
  static historyLimit: number = 100;
  static historyExpiryDays: number = 0;
  static current: Film = AppState.films[0];
  static context?: common.UIAbilityContext;
  private static prefs?: preferences.Preferences;
  static async init(context: common.UIAbilityContext): Promise<void> {
    AppState.context = context;
    // 先读取系统深浅色，再把“跟随系统”的主题模式换算成实际 darkTheme。
    try {
      AppState.systemDark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      Logger.warn('APP_THEME', '读取系统深浅色失败，沿用上次缓存：' + String(error));
    }
    AppState.publish();
    Logger.init(context);
    try {
      AppState.prefs = await preferences.getPreferences(context, 'wuyin');
      AppState.config.enabled = Boolean(await AppState.prefs.get('enabled', true));
      AppState.config.blur = Number(await AppState.prefs.get('blur', 20));
      AppState.config.opacity = Number(await AppState.prefs.get('opacity', 0.8));
      AppState.config.autoColorEnable = Boolean(await AppState.prefs.get('autoColorEnable', true));
      // 整体归档与 @StorageLink 使用同一配置结构；旧版本分项设置仍可迁移。
      try {
        const savedImmersive: string = String(await AppState.prefs.get('immersiveConfig', ''));
        if (savedImmersive) {
          const restored = JSON.parse(savedImmersive) as PlayerImmersiveConfig;
          if (restored) {
            if (typeof restored.immersiveEnable === 'boolean') { AppState.config.enabled = restored.immersiveEnable; }
            if (Number.isFinite(restored.immersiveBlur)) { AppState.config.blur = Math.max(0, Math.min(100, restored.immersiveBlur)); }
            if (Number.isFinite(restored.immersiveOpacity)) { AppState.config.opacity = Math.max(0, Math.min(1, restored.immersiveOpacity)); }
            if (typeof restored.autoColorEnable === 'boolean') { AppState.config.autoColorEnable = restored.autoColorEnable; }
          }
        }
      } catch (error) { Logger.warn('IMMERSIVE_CONFIG', '读取沉浸配置失败，保留兼容设置：' + String(error)); }
      const savedMode: string = String(await AppState.prefs.get('themeMode', 'system'));
      AppState.themeMode = savedMode === 'dark' || savedMode === 'light' ? savedMode : 'system';
      AppState.config.dark = AppState.themeMode === 'system' ? AppState.systemDark : AppState.themeMode === 'dark';
      const savedKernel = String(await AppState.prefs.get('playerKernel', 'ijk'));
      AppState.playerKernel = savedKernel === 'av' ? 'av' : 'ijk';
      AppState.chatSoundEnabled = Boolean(await AppState.prefs.get('chatSoundEnabled', true));
      AppState.chatBannerEnabled = Boolean(await AppState.prefs.get('chatBannerEnabled', true));
      AppState.chatDndEnabled = Boolean(await AppState.prefs.get('chatDndEnabled', false));
      AppState.chatAlertPosition = AppState.validAlertPosition(String(await AppState.prefs.get('chatAlertPosition', 'top')));
      AppState.chatAlertOffset = AppState.validAlertOffset(Number(await AppState.prefs.get('chatAlertOffset', 0)));
      AppState.chatBackgroundNotify = Boolean(await AppState.prefs.get('chatBackgroundNotify', true));
      AppState.dockScale = AppState.validScale(Number(await AppState.prefs.get('dockScale', 1)), 0.85, 1.25);
      AppState.fontScale = AppState.validScale(Number(await AppState.prefs.get('fontScale', 1)), 0.85, 1.30);
      Logger.enabled = Boolean(await AppState.prefs.get('logging', true));
      await AppState.loadFavorites();
      AppState.historyLimit = AppState.validLimit(Number(await AppState.prefs.get('historyLimit', 100)));
      AppState.historyExpiryDays = AppState.validExpiry(Number(await AppState.prefs.get('historyExpiryDays', 0)));
      AppState.history = JSON.parse(String(await AppState.prefs.get('history', '[]'))) as WatchRecord[];
      if (!Array.isArray(AppState.history)) { AppState.history = []; }
      AppState.snapshotFavorites();
      AppState.cleanHistory();
      AppState.publish();
      AppState.notifyFavorites();
      AppStorage.setOrCreate('logging', Logger.enabled);
      await AppState.save();
    } catch (error) { Logger.error('PREFERENCES', String(error)); }
  }
  private static async loadFavorites(): Promise<void> {
    const store = AppState.prefs;
    if (!store) { return; }
    let savedFavorites: number[] = [];
    let savedRecords: WatchRecord[] = [];
    // 两项归档分别捕获异常，单项损坏不能中断主题、收藏及其他设置初始化。
    try {
      const parsed = JSON.parse(String(await store.get('favorites', '[]'))) as number[];
      if (!Array.isArray(parsed)) { throw new Error('收藏标识归档格式错误'); }
      savedFavorites = parsed.filter((id: number, index: number) => Number.isInteger(id) && parsed.indexOf(id) === index);
    } catch (error) { Logger.error('FAVORITE_LOAD', '读取收藏标识失败：' + String(error)); }
    try {
      const parsed = JSON.parse(String(await store.get('favoriteRecords', '[]'))) as WatchRecord[];
      if (!Array.isArray(parsed)) { throw new Error('收藏资料归档格式错误'); }
      for (const item of parsed) {
        if (!item || !Number.isInteger(item.id) || savedRecords.some((record: WatchRecord) => record.id === item.id)) { continue; }
        const record = new WatchRecord();
        record.id = item.id;
        record.vodId = typeof item.vodId === 'string' ? item.vodId : '';
        record.name = typeof item.name === 'string' ? item.name : '未命名影片';
        record.cover = typeof item.cover === 'string' ? item.cover : '';
        record.wzlj = typeof item.wzlj === 'string' ? item.wzlj : '';
        record.time = typeof item.time === 'string' ? item.time : '';
        record.episode = Number.isInteger(item.episode) && item.episode > 0 ? item.episode : 1;
        record.position = Number.isFinite(item.position) ? Math.max(0, item.position) : 0;
        record.duration = Number.isFinite(item.duration) ? Math.max(0, item.duration) : 0;
        savedRecords.push(record);
      }
    } catch (error) { Logger.error('FAVORITE_LOAD', '读取收藏资料归档失败：' + String(error)); }
    // 将初始化期间的操作逐项覆盖到磁盘快照，而不是丢弃整份原收藏列表。
    // 读取期间新增的影片资料也一起合并，取消的影片不会被旧归档重新选中。
    for (const id of AppState.favoriteEdits.keys()) {
      if (AppState.favoriteEdits.get(id)) {
        if (!savedFavorites.includes(id)) { savedFavorites.push(id); }
        const current = AppState.favoriteRecords.find((record: WatchRecord) => record.id === id);
        if (current) { savedRecords = savedRecords.filter((record: WatchRecord) => record.id !== id).concat(current); }
      } else {
        savedFavorites = savedFavorites.filter((value: number) => value !== id);
        savedRecords = savedRecords.filter((record: WatchRecord) => record.id !== id);
      }
    }
    AppState.favorites = savedFavorites;
    AppState.favoriteRecords = savedRecords;
    AppState.favoritesLoaded = true;
    AppState.favoriteEdits.clear();
    AppState.snapshotFavorites();
    AppState.notifyFavorites();
    Logger.info('FAVORITE_LOAD', '收藏归档同步完成，数量=' + AppState.favorites.length);
  }
  static syncSystemTheme(isDark: boolean): void {
    AppState.systemDark = isDark;
    if (AppState.themeMode !== 'system') { return; }
    AppState.config.dark = isDark;
    AppState.publish();
    Logger.info('APP_THEME', '系统主题更新：' + (isDark ? '深色' : '浅色'));
  }
  static async setThemeMode(mode: string): Promise<void> {
    AppState.themeMode = mode === 'dark' || mode === 'light' ? mode : 'system';
    AppState.config.dark = AppState.themeMode === 'system' ? AppState.systemDark : AppState.themeMode === 'dark';
    AppState.publish();
    await AppState.save();
    Logger.info('APP_THEME', '应用主题模式：' + AppState.themeMode);
  }
  static publish(): void {
    AppState.immersiveConfig = {
      immersiveEnable: AppState.config.enabled,
        immersiveBlur: AppState.config.blur,
        immersiveOpacity: AppState.config.opacity,
        autoColorEnable: AppState.config.autoColorEnable
    };
    AppStorage.setOrCreate('immersiveConfig', AppState.immersiveConfig);
    AppStorage.setOrCreate('immersiveEnabled', AppState.config.enabled);
    AppStorage.setOrCreate('immersiveBlur', AppState.config.blur);
    AppStorage.setOrCreate('immersiveOpacity', AppState.config.opacity);
    AppState.publishedDark = AppState.config.dark;
    AppStorage.setOrCreate('darkTheme', AppState.config.dark);
    AppStorage.setOrCreate('themeMode', AppState.themeMode);
    AppStorage.setOrCreate('playerKernel', AppState.playerKernel);
    AppStorage.setOrCreate('chatSoundEnabled', AppState.chatSoundEnabled);
    AppStorage.setOrCreate('chatBannerEnabled', AppState.chatBannerEnabled);
    AppStorage.setOrCreate('chatDndEnabled', AppState.chatDndEnabled);
    AppStorage.setOrCreate('chatAlertPosition', AppState.chatAlertPosition);
    AppStorage.setOrCreate('chatAlertOffset', AppState.chatAlertOffset);
    AppStorage.setOrCreate('chatBackgroundNotify', AppState.chatBackgroundNotify);
    AppStorage.setOrCreate('dockScale', AppState.dockScale);
    AppStorage.setOrCreate('fontScale', AppState.fontScale);
    AppStorage.setOrCreate('historyLimit', AppState.historyLimit);
    AppStorage.setOrCreate('historyExpiryDays', AppState.historyExpiryDays);
    AppStorage.setOrCreate('favoriteVersion', AppStorage.get<number>('favoriteVersion') || 0);
    AppStorage.setOrCreate('historyVersion', (AppStorage.get<number>('historyVersion') || 0) + 1);
    // 全局主题及设置变化直接同步透明系统栏，不依赖某个页面重新出现。
    void ImmersiveService.apply();
  }
  private static notifyFavorites(): void {
    AppStorage.setOrCreate('favoriteVersion', (AppStorage.get<number>('favoriteVersion') || 0) + 1);
  }
  private static validLimit(value: number): number {
    return Number.isFinite(value) ? Math.max(1, Math.min(10000, Math.floor(value))) : 100;
  }
  private static validExpiry(value: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(3650, Math.floor(value))) : 0;
  }
  private static validScale(value: number, min: number, max: number): number {
    return Number.isFinite(value) ? Math.max(min, Math.min(max, Math.round(value * 100) / 100)) : 1;
  }
  private static validAlertPosition(value: string): string {
    const text: string = value.trim().toLowerCase();
    return text === 'center' || text === 'bottom' ? text : 'top';
  }
  private static validAlertOffset(value: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(200, Math.round(value))) : 0;
  }
  static cleanHistory(): void {
    const seen: number[] = [];
    const now = Date.now();
    AppState.history = AppState.history.filter((item: WatchRecord) => {
      if (!item || !Number.isFinite(item.id) || seen.includes(item.id)) { return false; }
      if (AppState.historyExpiryDays > 0) {
        const timestamp = Date.parse(item.time);
        if (Number.isFinite(timestamp) && now - timestamp > AppState.historyExpiryDays * 86400000) { return false; }
      }
      seen.push(item.id);
      return true;
    }).slice(0, AppState.historyLimit);
  }
  private static async removePlayback(records: WatchRecord[]): Promise<void> {
    if (!AppState.context || records.length === 0) { return; }
    try {
      const store = await preferences.getPreferences(AppState.context, 'player_watch_history');
      for (const item of records) { if (item.vodId) { await store.delete('vod_' + item.vodId); } }
      await store.flush();
    } catch (error) { Logger.error('HISTORY_DELETE', String(error)); }
  }
  static async setHistoryOptions(limit: number, expiryDays: number): Promise<void> {
    const previous = AppState.history.slice();
    AppState.historyLimit = AppState.validLimit(limit);
    AppState.historyExpiryDays = AppState.validExpiry(expiryDays);
    AppState.cleanHistory();
    await AppState.removePlayback(previous.filter((item: WatchRecord) => !AppState.history.some((kept: WatchRecord) => kept.vodId === item.vodId)));
    await AppState.save();
  }
  static async removeHistory(ids: number[]): Promise<void> {
    const removed = AppState.history.filter((item: WatchRecord) => ids.includes(item.id));
    AppState.snapshotFavorites();
    AppState.history = AppState.history.filter((item: WatchRecord) => !ids.includes(item.id));
    await AppState.removePlayback(removed);
    await AppState.save();
  }
  static async clearHistory(): Promise<void> {
    const removed = AppState.history.slice();
    AppState.snapshotFavorites();
    AppState.history = [];
    await AppState.removePlayback(removed);
    await AppState.save();
  }
  private static async syncImportedPlayback(records: WatchRecord[]): Promise<void> {
    if (!AppState.context) { return; }
    try {
      const store = await preferences.getPreferences(AppState.context, 'player_watch_history');
      for (const item of records) {
        if (!item.vodId || !item.wzlj || !Number.isFinite(item.episode) || !Number.isFinite(item.position)) { continue; }
        await store.put('vod_' + item.vodId, JSON.stringify({
          vodId: item.vodId,
            selectIndex: Math.max(0, Math.floor(item.episode) - 1),
            playSec: Math.max(0, Math.floor(item.position)),
            videoName: item.name || ''
        }));
      }
      await store.flush();
    } catch (error) { Logger.error('HISTORY_IMPORT', String(error)); }
  }
  static async importHistory(records: WatchRecord[], overwrite: boolean): Promise<void> {
    const previous = AppState.history.slice();
    AppState.snapshotFavorites();
    AppState.history = overwrite ? records : records.concat(AppState.history.filter((item: WatchRecord) => !records.some((incoming: WatchRecord) => incoming.id === item.id)));
    AppState.cleanHistory();
    await AppState.removePlayback(previous.filter((item: WatchRecord) => !AppState.history.some((kept: WatchRecord) => kept.vodId === item.vodId)));
    await AppState.save();
    await AppState.syncImportedPlayback(AppState.history);
  }
  private static snapshotFavorites(): void {
    const seen: number[] = [];
    AppState.favoriteRecords = AppState.favoriteRecords.filter((item: WatchRecord) => {
      if (!item || !AppState.favorites.includes(item.id) || seen.includes(item.id)) { return false; }
      seen.push(item.id); return true;
    });
    for (const id of AppState.favorites) {
      if (AppState.favoriteRecords.some((item: WatchRecord) => item.id === id)) { continue; }
      const record = AppState.history.find((item: WatchRecord) => item.id === id);
      if (record) { AppState.favoriteRecords.push(record); }
    }
  }
  static save(): Promise<void> {
    // 兼容原设置页直接修改 config.dark；系统回调先 publish，不会误转为手动模式。
    if (AppState.config.dark !== AppState.publishedDark) { AppState.themeMode = AppState.config.dark ? 'dark' : 'light'; }
    AppState.snapshotFavorites();
    AppState.publish();
    const config = new ImmersiveConfig();
    config.enabled = AppState.config.enabled; config.blur = AppState.config.blur;
    config.opacity = AppState.config.opacity; config.dark = AppState.config.dark;
    config.autoColorEnable = AppState.config.autoColorEnable;
    const immersiveSnapshot: string = JSON.stringify(AppState.immersiveConfig);
    const mode: string = AppState.themeMode;
    const kernel: string = AppState.playerKernel;
    const logging: boolean = Logger.enabled;
    const chatSound: boolean = AppState.chatSoundEnabled;
    const chatBanner: boolean = AppState.chatBannerEnabled;
    const chatDnd: boolean = AppState.chatDndEnabled;
    const chatAlertPosition: string = AppState.chatAlertPosition;
    const chatAlertOffset: number = AppState.chatAlertOffset;
    const chatBackgroundNotify: boolean = AppState.chatBackgroundNotify;
    const dockScale: number = AppState.dockScale;
    const fontScale: number = AppState.fontScale;
    const favorites: string = JSON.stringify(AppState.favorites);
    const favoriteRecords: string = JSON.stringify(AppState.favoriteRecords);
    const history: string = JSON.stringify(AppState.history);
    const historyLimit: number = AppState.historyLimit;
    const historyExpiryDays: number = AppState.historyExpiryDays;
    // 串行写入捕获的快照，快速收藏/取消时旧 flush 不会覆盖较新的选择。
    // 收藏加载前不写入不完整的列表，避免初始化期间的一次点击清空其他已存收藏。
    const writeFavorites: boolean = AppState.favoritesLoaded;
    AppState.persistence = AppState.persistence.then(async () => {
      try {
        const p = AppState.prefs;
        if (!p) { return; }
        await p.put('enabled', config.enabled);
        await p.put('blur', config.blur);
        await p.put('opacity', config.opacity);
        await p.put('immersiveConfig', immersiveSnapshot);
        await p.put('dark', config.dark);
        await p.put('themeMode', mode);
        await p.put('autoColorEnable', config.autoColorEnable);
        await p.put('playerKernel', kernel);
        await p.put('logging', logging);
        await p.put('chatSoundEnabled', chatSound);
        await p.put('chatBannerEnabled', chatBanner);
        await p.put('chatDndEnabled', chatDnd);
        await p.put('chatAlertPosition', chatAlertPosition);
        await p.put('chatAlertOffset', chatAlertOffset);
        await p.put('chatBackgroundNotify', chatBackgroundNotify);
        await p.put('dockScale', dockScale);
        await p.put('fontScale', fontScale);
        if (writeFavorites) {
          await p.put('favorites', favorites);
          await p.put('favoriteRecords', favoriteRecords);
        }
        await p.put('history', history);
        await p.put('historyLimit', historyLimit);
        await p.put('historyExpiryDays', historyExpiryDays);
        await p.flush();
      } catch (error) { Logger.error('SAVE', String(error)); }
    });
    return AppState.persistence;
  }
  static async setPlayerKernel(kernel: string): Promise<void> {
    AppState.playerKernel = kernel === 'av' ? 'av' : 'ijk';
    AppState.publish();
    await AppState.save();
  }
  /** 设置页「聊天提醒」：提示音 / 顶部弹窗 / 免打扰，立即发布到全局。 */
  static async setChatNoticeOptions(sound: boolean, banner: boolean, dnd: boolean): Promise<void> {
    AppState.chatSoundEnabled = sound;
    AppState.chatBannerEnabled = banner;
    AppState.chatDndEnabled = dnd;
    AppState.publish();
    await AppState.save();
  }
  /** 设置页「聊天提醒 · 弹窗位置」：top（默认贴紧屏幕正上方）/ center / bottom + 垂直微调。 */
  static async setChatAlertPlacement(position: string, offset: number): Promise<void> {
    AppState.chatAlertPosition = AppState.validAlertPosition(position);
    AppState.chatAlertOffset = AppState.validAlertOffset(offset);
    AppState.publish();
    await AppState.save();
  }
  /** 设置页「聊天提醒 · 后台通知栏提醒」。 */
  static async setChatBackgroundNotify(enabled: boolean): Promise<void> {
    AppState.chatBackgroundNotify = enabled;
    AppState.publish();
    await AppState.save();
  }
  /** 设置页「界面尺寸」：底部 Dock 缩放与全局字体缩放，立即发布到全局。 */
  static async setUiScales(dock: number, font: number): Promise<void> {
    AppState.dockScale = AppState.validScale(dock, 0.85, 1.25);
    AppState.fontScale = AppState.validScale(font, 0.85, 1.30);
    AppState.publish();
    await AppState.save();
  }
  static async restoreUiScales(): Promise<void> {
    AppState.dockScale = 1;
    AppState.fontScale = 1;
    AppState.publish();
    await AppState.save();
  }
  static go(page: string): void {
    Logger.info('NAVIGATION', page);
    AppStorage.setOrCreate('page', page);
  }
  static play(film: Film): void { AppState.current = film; AppState.go('player'); }
  static setFavorite(id: number, selected: boolean): void {
    if (!Number.isFinite(id)) { throw new Error('收藏标识无效'); }
    if (!AppState.favoritesLoaded) { AppState.favoriteEdits.set(id, selected); }
    if (AppState.favorites.includes(id) === selected) { return; }
    AppState.favorites = selected ? AppState.favorites.concat(id) : AppState.favorites.filter((value: number) => value !== id);
    AppState.snapshotFavorites();
    AppState.notifyFavorites();
    Logger.info('FAVORITE', (selected ? '收藏影片：' : '取消收藏：') + id);
    void AppState.save();
  }
  static favorite(id: number): void { AppState.setFavorite(id, !AppState.favorites.includes(id)); }
  static videoId(key: string): number {
    let hash: number = 0;
    for (let index: number = 0; index < key.length; index++) { hash = (Math.imul(31, hash) + key.charCodeAt(index)) | 0; }
    return hash;
  }
  static isVideoFavorite(video: RecordVideoSource): boolean {
    return AppState.favorites.includes(AppState.videoId(video.vodId));
  }
  static favoriteVideo(video: RecordVideoSource): void {
    if (!video.vodId || !video.vodId.trim()) { throw new Error('缺少影片标识，无法收藏'); }
    const id: number = AppState.videoId(video.vodId);
    if (!AppState.favorites.includes(id)) {
      const record = new WatchRecord();
      record.id = id; record.vodId = video.vodId;
      record.name = video.tilie || video.yhm || '未命名影片'; record.cover = video.feng; record.wzlj = video.wzlj;
      record.time = new Date().toISOString();
      AppState.favoriteRecords = AppState.favoriteRecords.filter((item: WatchRecord) => item.id !== id).concat(record);
    }
    AppState.favorite(id);
  }
  static record(episode: number, position: number, duration: number, video?: RecordVideoSource): void {
    let source: RecordVideoSource | undefined = video;
    if (!source) {
      try {
        const params = router.getParams() as RecordRouteParams | undefined;
        if (params && typeof params.vodId === 'string' && params.vodId.trim() && typeof params.wzlj === 'string') {
          source = { vodId: params.vodId, tilie: params.tilie || '', yhm: params.yhm || '', feng: params.feng || '', wzlj: params.wzlj };
        }
      } catch (error) { Logger.error('HISTORY', String(error)); }
    }
    const record = new WatchRecord();
    const key: string = source?.vodId || '';
    record.id = key ? AppState.videoId(key) : AppState.current.id;
    record.episode = episode;
    record.position = position; record.duration = duration; record.time = new Date().toISOString();
    record.name = source?.tilie || source?.yhm || AppState.current.name;
    record.cover = source?.feng || '';
    record.vodId = key;
    record.wzlj = source?.wzlj || '';
    AppState.history = [record].concat(AppState.history.filter(item => item.id !== record.id));
    AppState.cleanHistory();
    void AppState.save();
  }
}

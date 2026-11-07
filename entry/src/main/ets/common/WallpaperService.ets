import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import { fileUri } from './PlatformFileUri';
import { FrameRateService } from './FrameRateService';
import { Logger } from './Logger';

/**
 * 一张本地导入的背景资源。
 *
 * 只保存"静态导出资源"：图片（jpg/png/webp/bmp）、动图（gif）、视频（mp4/mkv/ts/webm/mov）。
 * 视频用 ArkUI 原生 Video 组件静音循环播放，不接入任何外部渲染引擎，也不读取 WE 工程文件，
 * 因此只需要把用户导出的成品文件复制进应用沙箱即可。
 */
export class WallpaperMedia {
  /** 稳定 id（导入时间戳 + 序号，用于列表与当前选中项）。 */
  id: string = '';
  /** 原始文件名（展示用，不做重命名）。 */
  name: string = '';
  /** 沙箱内的绝对路径（持久化与删除用）。 */
  path: string = '';
  /** 组件可用的 file:// 沙箱 URI（Video / Image 的 src）。 */
  uri: string = '';
  /** 资源类型：video / gif / image。 */
  kind: string = 'image';
  /** 文件大小（字节，展示用）。 */
  bytes: number = 0;
  /** 导入时间（毫秒）。 */
  addedAt: number = 0;
}

/** 背景资源类型常量（避免各页面散落字符串字面量）。 */
export class WallpaperKind {
  static readonly VIDEO: string = 'video';
  static readonly GIF: string = 'gif';
  static readonly IMAGE: string = 'image';

  static label(kind: string): string {
    if (kind === WallpaperKind.VIDEO) { return '视频'; }
    if (kind === WallpaperKind.GIF) { return '动图'; }
    if (kind === WallpaperKind.IMAGE) { return '图片'; }
    return '背景';
  }

  static isVideo(kind: string): boolean { return kind === WallpaperKind.VIDEO; }
  static isDynamic(kind: string): boolean { return kind === WallpaperKind.VIDEO || kind === WallpaperKind.GIF; }
}

/** 背景播放参数（透明度 / 速率 / 帧率 / 动效）。 */
export class WallpaperTuning {
  /** 背景图层不透明度：0.2~1。 */
  opacity: number = 0.85;
  /** 播放速率：0.5 / 1 / 1.5。 */
  rate: number = 1;
  /** 动态背景帧率上限：0 表示跟随系统（不额外限制），其余为 24/30/60。 */
  frameHz: number = 0;
  /** 是否播放动效：关闭后动态背景停在首帧，省电优先。 */
  motion: boolean = true;
}

/**
 * 本地背景服务。
 *
 * 职责：
 * 1. 通过系统文件选择器导入图片 / GIF / 视频（含 Wallpaper Engine 导出的 mp4、gif），
 *    复制到 `filesDir/wallpapers` 后持久化索引，卸载前一直可离线使用；
 * 2. 维护当前选中的本地背景与播放参数，并发布到 AppStorage，供全局背景组件与设置页共享；
 * 3. 与 FrameRateService 联动：动态背景生效时按设置申请背景帧率，移除背景或暂停动效后恢复。
 *
 * 与 ThemeService 的分工：渐变壁纸仍由 ThemeService 管理，这里只负责"本地资源"，
 * ThemeService 是背景切换的唯一入口（应用本地背景时清空渐变壁纸，反之亦然），
 * 因此原有壁纸/主题切换逻辑不变。
 */
export class WallpaperService {
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_LIST: string = 'wallpaperMediaList';
  private static readonly KEY_ACTIVE: string = 'wallpaperMediaActive';
  private static readonly KEY_OPACITY: string = 'wallpaperOpacity';
  private static readonly KEY_RATE: string = 'wallpaperRate';
  private static readonly KEY_FRAME: string = 'wallpaperFrameHz';
  private static readonly KEY_MOTION: string = 'wallpaperMotion';
  private static readonly DIR_NAME: string = 'wallpapers';
  /** 单文件上限 512MB：足够大的 WE 循环视频，同时避免误选超大文件把应用私有空间撑爆。 */
  private static readonly MAX_BYTES: number = 512 * 1024 * 1024;
  /** 最多保留 12 个导入背景，超出后删除最早的文件。 */
  private static readonly MAX_ITEMS: number = 12;
  private static readonly VIDEO_EXTS: string[] = ['mp4', 'm4v', 'mkv', 'ts'];
  private static readonly IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'heic', 'heif', 'avif'];

  /** 播放速率挡位（与设置页滑块一致）。 */
  static readonly RATE_OPTIONS: number[] = [0.5, 1, 1.5];
  /** 动态背景帧率挡位：0 = 跟随系统。 */
  static readonly FRAME_OPTIONS: number[] = [0, 24, 30, 60];
  static readonly OPACITY_MIN: number = 0.2;

  private static store?: preferences.Preferences;
  private static baseDir: string = '';
  private static items: WallpaperMedia[] = [];
  private static activeId: string = '';
  private static tuning: WallpaperTuning = new WallpaperTuning();
  private static initialized: boolean = false;
  private static seq: number = 0;
  /** 拖动滑块时的落盘防抖：只改内存状态，停手 320ms 后再写磁盘。 */
  private static saveTimer: number = -1;
  /** 当前最上层路由页（标题 / 路径 / 栈序号）：只有它才渲染动态背景。 */
  private static topRoute: string = '';
  private static topRoutePath: string = '';
  private static topRouteIndex: number = -1;
  private static observerBound: boolean = false;
  private static publishedUri: string = '';
  private static publishedKind: string = '';

  /** 读取已保存的背景索引与播放参数；EntryAbility 启动时调用一次。 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (WallpaperService.initialized) {
      return;
    }
    try {
      WallpaperService.baseDir = context.filesDir + '/' + WallpaperService.DIR_NAME;
      WallpaperService.ensureDir();
      WallpaperService.store = await preferences.getPreferences(context, WallpaperService.STORE);
      const store: preferences.Preferences = WallpaperService.store;
      WallpaperService.items = WallpaperService.parseList(String(await store.get(WallpaperService.KEY_LIST, '[]')));
      WallpaperService.activeId = String(await store.get(WallpaperService.KEY_ACTIVE, ''));
      if (WallpaperService.currentMedia() === undefined) {
        WallpaperService.activeId = '';
      }
      WallpaperService.tuning.opacity = WallpaperService.clampOpacity(
        Number(await store.get(WallpaperService.KEY_OPACITY, 0.85)));
      WallpaperService.tuning.rate = WallpaperService.normalizeRate(
        Number(await store.get(WallpaperService.KEY_RATE, 1)));
      WallpaperService.tuning.frameHz = WallpaperService.normalizeFrame(
        Number(await store.get(WallpaperService.KEY_FRAME, 0)));
      WallpaperService.tuning.motion = Boolean(await store.get(WallpaperService.KEY_MOTION, true));
      WallpaperService.initialized = true;
      WallpaperService.publish();
      WallpaperService.bindRouteObserver(context);
      Logger.info('WALLPAPER_MEDIA', '本地背景已恢复：' + String(WallpaperService.items.length) +
        ' 个资源，当前=' + (WallpaperService.activeId || '无'));
    } catch (error) {
      Logger.error('WALLPAPER_MEDIA', '读取本地背景配置失败：' + String(error));
      // 读取失败时也发布一次默认值，避免背景组件拿不到初始状态。
      WallpaperService.publish();
    }
  }

  /** 已导入的背景列表（新导入的排在前面）。 */
  static list(): WallpaperMedia[] {
    return WallpaperService.items;
  }

  /** 当前生效的本地背景；未选择时为 undefined。 */
  static currentMedia(): WallpaperMedia | undefined {
    if (!WallpaperService.activeId) {
      return undefined;
    }
    for (const item of WallpaperService.items) {
      if (item.id === WallpaperService.activeId) {
        return item;
      }
    }
    return undefined;
  }

  static currentId(): string {
    return WallpaperService.activeId;
  }

  static has(id: string): boolean {
    if (!id) {
      return false;
    }
    for (const item of WallpaperService.items) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  static opacity(): number {
    return WallpaperService.tuning.opacity;
  }

  static rate(): number {
    return WallpaperService.tuning.rate;
  }

  static frameHz(): number {
    return WallpaperService.tuning.frameHz;
  }

  static motion(): boolean {
    return WallpaperService.tuning.motion;
  }

  /** 选中某个已导入背景（由 ThemeService 统一调用，保证渐变壁纸互斥）。 */
  static activate(id: string): boolean {
    if (!WallpaperService.has(id) || WallpaperService.activeId === id) {
      return WallpaperService.has(id);
    }
    WallpaperService.activeId = id;
    WallpaperService.publish();
    WallpaperService.persist();
    Logger.info('WALLPAPER_MEDIA', '应用本地背景：' + id);
    return true;
  }

  /** 取消本地背景（回到主题/渐变壁纸）。 */
  static deactivate(): void {
    if (!WallpaperService.activeId) {
      return;
    }
    WallpaperService.activeId = '';
    WallpaperService.publish();
    WallpaperService.persist();
    Logger.info('WALLPAPER_MEDIA', '已取消本地背景');
  }

  static setOpacity(value: number): void {
    const next: number = WallpaperService.clampOpacity(value);
    if (Math.abs(next - WallpaperService.tuning.opacity) < 0.001) {
      return;
    }
    WallpaperService.tuning.opacity = next;
    WallpaperService.publish();
    WallpaperService.schedulePersist();
  }

  static setRate(value: number): void {
    const next: number = WallpaperService.normalizeRate(value);
    if (Math.abs(next - WallpaperService.tuning.rate) < 0.001) {
      return;
    }
    WallpaperService.tuning.rate = next;
    WallpaperService.publish();
    WallpaperService.schedulePersist();
    Logger.info('WALLPAPER_MEDIA', '背景播放速率：' + String(next) + 'x');
  }

  static setFrameHz(value: number): void {
    const next: number = WallpaperService.normalizeFrame(value);
    if (next === WallpaperService.tuning.frameHz) {
      return;
    }
    WallpaperService.tuning.frameHz = next;
    WallpaperService.publish();
    WallpaperService.schedulePersist();
    Logger.info('WALLPAPER_MEDIA', '动态背景帧率：' + (next <= 0 ? '跟随系统' : String(next) + 'Hz'));
  }

  static setMotion(value: boolean): void {
    if (value === WallpaperService.tuning.motion) {
      return;
    }
    WallpaperService.tuning.motion = value;
    WallpaperService.publish();
    WallpaperService.schedulePersist();
    Logger.info('WALLPAPER_MEDIA', value ? '开启动态背景' : '暂停动态背景（保留首帧）');
  }

  /**
   * 打开系统文件选择器导入背景：支持多选，支持 WE 导出的 mp4 / gif / 图片。
   * 返回本次成功导入的资源（失败或取消时为空数组）。
   */
  static async importFromPicker(context: common.UIAbilityContext): Promise<WallpaperMedia[]> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.fileSuffixFilters = [
      '图片与动图 (.jpg,.jpeg,.png,.webp,.bmp,.gif)|.jpg,.jpeg,.png,.webp,.bmp,.gif',
      '视频 (.mp4,.mkv,.ts)|.mp4,.mkv,.ts'
    ];
    const uris: string[] = await new picker.DocumentViewPicker(context).select(options);    const created: WallpaperMedia[] = [];
    for (const uri of uris) {
      try {
        const media: WallpaperMedia | undefined = await WallpaperService.copyInto(uri);
        if (media !== undefined) {
          created.push(media);
        }
      } catch (error) {
        Logger.error('WALLPAPER_MEDIA', '导入背景失败：' + String(error));
      }
    }
    if (created.length > 0) {
      // 新导入的排在最前，便于立即看到并应用。
      WallpaperService.items = created.concat(WallpaperService.items);
      WallpaperService.trim();
      WallpaperService.persist();
      WallpaperService.publish();
      Logger.info('WALLPAPER_MEDIA', '导入背景成功：' + String(created.length) + ' 个');
    }
    return created;
  }

  /** 删除一个已导入背景（同时删除沙箱文件；若正在使用则回到主题背景）。 */
  static remove(id: string): void {
    const kept: WallpaperMedia[] = [];
    let removed: boolean = false;
    for (const item of WallpaperService.items) {
      if (item.id === id) {
        WallpaperService.deleteFile(item.path);
        removed = true;
      } else {
        kept.push(item);
      }
    }
    if (!removed) {
      return;
    }
    WallpaperService.items = kept;
    if (WallpaperService.activeId === id) {
      WallpaperService.activeId = '';
    }
    WallpaperService.persist();
    WallpaperService.publish();
    Logger.info('WALLPAPER_MEDIA', '删除本地背景：' + id);
  }

  /** 清空全部本地背景文件（不改变当前主题/渐变壁纸配置）。 */
  static removeAll(): void {
    for (const item of WallpaperService.items) {
      WallpaperService.deleteFile(item.path);
    }
    WallpaperService.items = [];
    WallpaperService.activeId = '';
    WallpaperService.persist();
    WallpaperService.publish();
    Logger.info('WALLPAPER_MEDIA', '已清空全部本地背景');
  }

  /** 把任意来源的速率收敛到 0.5 / 1 / 1.5 三挡中最近的一挡。 */
  static normalizeRate(value: number): number {
    if (!Number.isFinite(value)) {
      return 1;
    }
    let best: number = WallpaperService.RATE_OPTIONS[0];
    let distance: number = Math.abs(value - best);
    for (const option of WallpaperService.RATE_OPTIONS) {
      const next: number = Math.abs(value - option);
      if (next < distance) {
        best = option;
        distance = next;
      }
    }
    return best;
  }

  /** 把任意来源的帧率收敛到 0 / 24 / 30 / 60 四挡中最近的一挡。 */
  static normalizeFrame(value: number): number {
    if (!Number.isFinite(value) || value <= 0) {
      return 0;
    }
    let best: number = 0;
    let distance: number = Number.MAX_VALUE;
    for (const option of WallpaperService.FRAME_OPTIONS) {
      const next: number = Math.abs(value - option);
      if (next < distance) {
        best = option;
        distance = next;
      }
    }
    return best;
  }

  /** 帧率文案：0 显示"跟随系统"。 */
  static frameLabel(value: number): string {
    return value <= 0 ? '跟随系统' : String(value) + 'Hz';
  }

  /** 播放速率文案：0.5 / 1 / 1.5 三挡，省略多余的 0。 */
  static rateLabel(value: number): string {
    const rate: number = WallpaperService.normalizeRate(value);
    if (Math.abs(rate - 1) < 0.001) {
      return '1x';
    }
    return (Math.round(rate * 10) / 10).toString() + 'x';
  }

  /** 文件大小文案（KB / MB）。 */
  static formatBytes(bytes: number): string {
    const size: number = Number.isFinite(bytes) ? Math.max(0, bytes) : 0;
    if (size >= 1024 * 1024) {
      return (Math.round(size / 1024 / 1024 * 10) / 10).toString() + ' MB';
    }
    if (size >= 1024) {
      return Math.round(size / 1024).toString() + ' KB';
    }
    return size.toString() + ' B';
  }

  // ---------------- 内部实现 ----------------

  private static clampOpacity(value: number): number {
    if (!Number.isFinite(value)) {
      return 0.85;
    }
    return Math.max(WallpaperService.OPACITY_MIN, Math.min(1, value));
  }

  private static parseList(raw: string): WallpaperMedia[] {
    const result: WallpaperMedia[] = [];
    if (!raw) {
      return result;
    }
    let parsed: WallpaperMedia[] = [];
    try {
      parsed = JSON.parse(raw) as WallpaperMedia[];
    } catch (error) {
      Logger.warn('WALLPAPER_MEDIA', '背景索引解析失败：' + String(error));
      return result;
    }
    for (const saved of parsed) {
      if (saved === undefined || saved === null) {
        continue;
      }
      const media: WallpaperMedia = new WallpaperMedia();
      media.id = String(saved.id || '');
      media.name = String(saved.name || '');
      media.path = String(saved.path || '');
      media.kind = String(saved.kind || WallpaperKind.IMAGE);
      media.bytes = Number(saved.bytes || 0);
      media.addedAt = Number(saved.addedAt || 0);
      if (!media.id || !media.path || !WallpaperService.fileExists(media.path)) {
        continue;
      }
      media.uri = WallpaperService.uriOf(media.path);
      result.push(media);
    }
    return result;
  }

  private static uriOf(path: string): string {
    try {
      return fileUri.getUriFromPath(path);
    } catch (error) {
      Logger.warn('WALLPAPER_MEDIA', '生成文件 URI 失败：' + String(error));
      return path;
    }
  }

  private static fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private static ensureDir(): void {
    if (!WallpaperService.baseDir) {
      return;
    }
    try {
      if (!fs.accessSync(WallpaperService.baseDir)) {
        fs.mkdirSync(WallpaperService.baseDir);
      }
    } catch (error) {
      Logger.error('WALLPAPER_MEDIA', '创建背景目录失败：' + String(error));
    }
  }

  private static async copyInto(uri: string): Promise<WallpaperMedia | undefined> {
    const name: string = WallpaperService.fileNameOf(uri);
    const ext: string = WallpaperService.extensionOf(name);
    const kind: string = WallpaperService.kindOf(ext);
    if (!kind) {
      Logger.warn('WALLPAPER_MEDIA', '不支持的背景文件类型：' + name);
      return undefined;
    }
    WallpaperService.ensureDir();
    if (!WallpaperService.baseDir) {
      return undefined;
    }
    WallpaperService.seq = (WallpaperService.seq + 1) % 1000;
    const stamp: number = Date.now();
    const path: string = WallpaperService.baseDir + '/bg_' + stamp + '_' + WallpaperService.seq + '.' + ext;
    let size: number = 0;
    const source: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(source.fd, path);
    } finally {
      try {
        fs.closeSync(source);
      } catch (error) {
        Logger.warn('WALLPAPER_MEDIA', '关闭背景源文件失败：' + String(error));
      }
    }
    try {
      size = fs.statSync(path).size;
    } catch (error) {
      size = 0;
    }
    if (size <= 0 || size > WallpaperService.MAX_BYTES) {
      WallpaperService.deleteFile(path);
      Logger.warn('WALLPAPER_MEDIA', '背景文件大小不合法，已忽略：' + String(size) + ' 字节');
      return undefined;
    }
    const media: WallpaperMedia = new WallpaperMedia();
    media.id = 'bg_' + stamp + '_' + WallpaperService.seq;
    media.name = name;
    media.path = path;
    media.uri = WallpaperService.uriOf(path);
    media.kind = kind;
    media.bytes = size;
    media.addedAt = stamp;
    return media;
  }

  private static trim(): void {
    if (WallpaperService.items.length <= WallpaperService.MAX_ITEMS) {
      return;
    }
    const removed: WallpaperMedia[] = WallpaperService.items.splice(WallpaperService.MAX_ITEMS);
    for (const item of removed) {
      WallpaperService.deleteFile(item.path);
      if (WallpaperService.activeId === item.id) {
        WallpaperService.activeId = '';
      }
    }
  }

  private static deleteFile(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      Logger.warn('WALLPAPER_MEDIA', '删除背景文件失败：' + String(error));
    }
  }

  private static fileNameOf(uri: string): string {
    try {
      let text: string = uri;
      const query: number = text.indexOf('?');
      if (query >= 0) {
        text = text.substring(0, query);
      }
      const slash: number = text.lastIndexOf('/');
      if (slash >= 0) {
        text = text.substring(slash + 1);
      }
      const decoded: string = decodeURIComponent(text);
      return decoded.length > 0 ? decoded : '背景';
    } catch (error) {
      return '背景';
    }
  }

  private static extensionOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot >= name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  private static kindOf(ext: string): string {
    if (!ext) {
      return '';
    }
    if (ext === 'gif') {
      return WallpaperKind.GIF;
    }
    if (WallpaperService.VIDEO_EXTS.indexOf(ext) >= 0) {
      return WallpaperKind.VIDEO;
    }
    if (WallpaperService.IMAGE_EXTS.indexOf(ext) >= 0) {
      return WallpaperKind.IMAGE;
    }
    return '';
  }

  /**
   * 监听路由页显隐，只让「最上层可见页面」渲染动态背景。
   *
   * 背景图层是每页一份的（ArkUI 没有窗口级背景层）。被盖住的页面如果继续持有
   * Video，会占用解码器，而且返回上一层时旧视频的 Surface 往往已经失效，表现为
   * 「首页背景黑掉、别的页面正常」。这里把可见页发布到 AppStorage，背景组件在不可见时
   * 直接销毁 Video，重新可见时用同一份资源重建，Surface 就会重新挂载。
   */
  private static bindRouteObserver(context: common.UIAbilityContext): void {
    // iOS 壳没有 uiObserver，动态背景按“始终可见”处理，避免依赖不存在的模块。
    if (WallpaperService.observerBound) {
      return;
    }
    WallpaperService.observerBound = true;
    Logger.info('WALLPAPER_MEDIA', 'iOS 无 uiObserver，跳过页面显隐监听');
  }

  private static publishTopRoute(name: string, path: string, index: number): void {
    const safeIndex: number = Number.isFinite(index) ? Math.max(0, Math.round(index)) : -1;
    if (name === WallpaperService.topRoute && path === WallpaperService.topRoutePath &&
      safeIndex === WallpaperService.topRouteIndex) {
      return;
    }
    WallpaperService.topRoute = name;
    WallpaperService.topRoutePath = path;
    WallpaperService.topRouteIndex = safeIndex;
    AppStorage.setOrCreate<string>('wallpaperTopRoute', name);
    AppStorage.setOrCreate<string>('wallpaperTopRoutePath', path);
    AppStorage.setOrCreate<number>('wallpaperTopIndex', safeIndex);
    Logger.info('WALLPAPER_MEDIA', '当前显示页面：' + (path.length > 0 ? path : name) +
      '（栈序号 ' + String(safeIndex) + '）');
  }

  /**
   * 路由名比对：不同 API 版本返回的可能是 'WallpaperPage' 或 'pages/WallpaperPage'，
   * 因此精确相等或互为后缀都算同一页；任一侧为空时视为无法判断（由调用方决定回退）。
   */
  static sameRoute(first: string, second: string): boolean {
    const left: string = first ? first.trim() : '';
    const right: string = second ? second.trim() : '';
    if (left.length === 0 || right.length === 0) {
      return false;
    }
    return left === right || left.endsWith(right) || right.endsWith(left);
  }

  /** 把当前状态发布到 AppStorage：全局背景组件与设置页通过同一组键渲染。 */
  private static publish(): void {
    const active: WallpaperMedia | undefined = WallpaperService.currentMedia();
    const uri: string = active === undefined ? '' : active.uri;
    const kind: string = active === undefined ? '' : active.kind;
    if (uri !== WallpaperService.publishedUri || kind !== WallpaperService.publishedKind) {
      WallpaperService.publishedUri = uri;
      WallpaperService.publishedKind = kind;
      const version: number = (AppStorage.get<number>('wallpaperMediaVersion') || 0) + 1;
      AppStorage.setOrCreate<number>('wallpaperMediaVersion', version);
    }
    AppStorage.setOrCreate<string>('wallpaperMediaId', active === undefined ? '' : active.id);
    AppStorage.setOrCreate<string>('wallpaperMediaName', active === undefined ? '' : active.name);
    AppStorage.setOrCreate<string>('wallpaperMediaKind', kind);
    AppStorage.setOrCreate<string>('wallpaperMediaUri', uri);
    AppStorage.setOrCreate<number>('wallpaperOpacity', WallpaperService.tuning.opacity);
    AppStorage.setOrCreate<number>('wallpaperRate', WallpaperService.tuning.rate);
    AppStorage.setOrCreate<number>('wallpaperFrameHz', WallpaperService.tuning.frameHz);
    AppStorage.setOrCreate<boolean>('wallpaperMotion', WallpaperService.tuning.motion);
    AppStorage.setOrCreate<string>('wallpaperTopRoute', WallpaperService.topRoute);
    AppStorage.setOrCreate<string>('wallpaperTopRoutePath', WallpaperService.topRoutePath);
    AppStorage.setOrCreate<number>('wallpaperTopIndex', WallpaperService.topRouteIndex);
    // 只有"动态背景 + 开启动效"才向系统申请背景帧率；静态图片背景不改变整机刷新率。
    const dynamic: boolean = active !== undefined && WallpaperKind.isDynamic(kind) && WallpaperService.tuning.motion;
    FrameRateService.setWallpaperState(dynamic, WallpaperService.tuning.frameHz);
  }

  /** 播放参数变化频繁（拖动滑块），延迟合并落盘，避免每一帧都写 preferences。 */
  private static schedulePersist(): void {
    if (WallpaperService.saveTimer >= 0) {
      clearTimeout(WallpaperService.saveTimer);
    }
    WallpaperService.saveTimer = setTimeout(() => {
      WallpaperService.saveTimer = -1;
      WallpaperService.persist();
    }, 320);
  }

  private static persist(): void {
    const store: preferences.Preferences | undefined = WallpaperService.store;
    if (store === undefined) {
      return;
    }
    try {
      store.put(WallpaperService.KEY_LIST, JSON.stringify(WallpaperService.items));
      store.put(WallpaperService.KEY_ACTIVE, WallpaperService.activeId);
      store.put(WallpaperService.KEY_OPACITY, WallpaperService.tuning.opacity);
      store.put(WallpaperService.KEY_RATE, WallpaperService.tuning.rate);
      store.put(WallpaperService.KEY_FRAME, WallpaperService.tuning.frameHz);
      store.put(WallpaperService.KEY_MOTION, WallpaperService.tuning.motion);
      store.flush().catch((error: Error) => {
        Logger.error('WALLPAPER_MEDIA', '保存本地背景配置失败：' + String(error));
      });
    } catch (error) {
      Logger.error('WALLPAPER_MEDIA', '写入本地背景配置失败：' + String(error));
    }
  }
}

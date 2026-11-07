import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { Logger } from './Logger';

/** 一条本地语音记录。 */
export class VoiceFile {
  name: string = '';
  path: string = '';
  size: number = 0;
  /** 最后修改时间（毫秒时间戳） */
  modified: number = 0;
}

/**
 * 语音本地存储管理：私有目录、自动清理、手动删除。
 *
 * 规则（可在设置页改）：
 * - 音频数量超过上限（默认 20 个）时，删掉最旧的 10 个；
 * - 可按天数保留（默认 7 天，0 表示不限），超期自动删；
 * - 设置页「音频管理」可查看列表、单个删除、清空、立即清理。
 */
export class VoiceStore {
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_MAX: string = 'voiceMaxCount';
  private static readonly KEY_DAYS: string = 'voiceRetainDays';
  private static readonly KEY_AUTO: string = 'voiceAutoClean';
  /** 默认最多保留 20 条。 */
  static readonly DEFAULT_MAX: number = 20;
  /** 超出上限时一次删掉最旧的 10 条。 */
  static readonly BATCH: number = 10;
  static readonly DEFAULT_DAYS: number = 7;
  private static dir: string = '';
  private static store: preferences.Preferences | undefined = undefined;

  static async init(context: common.UIAbilityContext): Promise<void> {
    VoiceStore.dir = context.filesDir + '/voice';
    try {
      fs.mkdirSync(VoiceStore.dir);
    } catch (_) {
      // 已存在就忽略
    }
    try {
      VoiceStore.store = await preferences.getPreferences(context, VoiceStore.STORE);
    } catch (error) {
      Logger.warn('CHAT_VOICE', '读取语音存储配置失败：' + String(error));
    }
  }

  /** 私有录音目录。 */
  static directory(): string {
    return VoiceStore.dir;
  }

  /** 生成一个新的录音文件路径（默认 .wav）。 */
  static newPath(suffix: string = '.wav'): string {
    return VoiceStore.dir + '/voice_' + String(Date.now()) + suffix;
  }

  /** 列出所有本地语音，按时间从新到旧。 */
  static list(): VoiceFile[] {
    const items: VoiceFile[] = [];
    if (VoiceStore.dir.length === 0) { return items; }
    try {
      const names: string[] = fs.listFileSync(VoiceStore.dir);
      for (const name of names) {
        if (!name.startsWith('voice_')) { continue; }
        // 语音文件是 mp4（音频型），同时兼容早期录出的 mp3。
        const lower: string = name.toLowerCase();
        if (!lower.endsWith('.wav') && !lower.endsWith('.mp4') && !lower.endsWith('.mp3')) { continue; }
        const path: string = VoiceStore.dir + '/' + name;
        try {
          const stat: fs.Stat = fs.statSync(path);
          const item: VoiceFile = new VoiceFile();
          item.name = name;
          item.path = path;
          item.size = stat.size;
          item.modified = stat.mtime * 1000;
          items.push(item);
        } catch (_) {
          // 单个文件读不到就跳过
        }
      }
    } catch (error) {
      Logger.warn('CHAT_VOICE', '列出语音失败：' + String(error));
    }
    items.sort((a: VoiceFile, b: VoiceFile) => b.modified - a.modified);
    return items;
  }

  /** 占用空间（字节）。 */
  static totalBytes(items: VoiceFile[]): number {
    let total: number = 0;
    for (const item of items) { total += item.size; }
    return total;
  }

  /**
   * 上传前把录音复制成同名的 .mp4（内容不变，只改后缀，符合图床只收 mp4 的规则）。
   * 返回新文件路径；复制失败返回空串，调用方直接用原文件。
   */
  static uploadCopy(path: string): string {
    if (path.length === 0) { return ''; }
    const target: string = path.replace(/\.[A-Za-z0-9]+$/, '.mp4');
    if (target === path) { return path; }
    try {
      fs.copyFileSync(path, target);
      Logger.info('CHAT_VOICE', '上传副本已生成：' + target);
      return target;
    } catch (error) {
      Logger.warn('CHAT_VOICE', '生成 mp4 副本失败，改用原文件：' + String(error));
      return '';
    }
  }

  static deleteFile(name: string): void {
    if (VoiceStore.dir.length === 0 || name.length === 0) { return; }
    try {
      fs.unlinkSync(VoiceStore.dir + '/' + name);
    } catch (error) {
      Logger.warn('CHAT_VOICE', '删除语音失败：' + String(error));
    }
  }

  static clearAll(): void {
    for (const item of VoiceStore.list()) {
      VoiceStore.deleteFile(item.name);
    }
  }

  // ---------- 自动清理设置 ----------

  static maxCount(): number {
    if (VoiceStore.store === undefined) { return VoiceStore.DEFAULT_MAX; }
    const value: number = Number(VoiceStore.store.getSync(VoiceStore.KEY_MAX, VoiceStore.DEFAULT_MAX));
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : VoiceStore.DEFAULT_MAX;
  }

  /** 保留天数，0 表示不限。 */
  static retainDays(): number {
    if (VoiceStore.store === undefined) { return VoiceStore.DEFAULT_DAYS; }
    const value: number = Number(VoiceStore.store.getSync(VoiceStore.KEY_DAYS, VoiceStore.DEFAULT_DAYS));
    return Number.isFinite(value) && value >= 0 ? Math.floor(value) : VoiceStore.DEFAULT_DAYS;
  }

  static autoClean(): boolean {
    if (VoiceStore.store === undefined) { return true; }
    return Boolean(VoiceStore.store.getSync(VoiceStore.KEY_AUTO, true));
  }

  static async saveSettings(auto: boolean, maxCount: number, days: number): Promise<void> {
    if (VoiceStore.store === undefined) { return; }
    await VoiceStore.store.put(VoiceStore.KEY_AUTO, auto);
    await VoiceStore.store.put(VoiceStore.KEY_MAX, Math.max(1, Math.floor(maxCount)));
    await VoiceStore.store.put(VoiceStore.KEY_DAYS, Math.max(0, Math.floor(days)));
    await VoiceStore.store.flush();
  }

  /**
   * 执行自动清理：先按天数删过期，再按数量删最旧的（超上限一次删 10 个）。
   * 返回删掉的条数。
   */
  static enforce(): number {
    if (!VoiceStore.autoClean()) { return 0; }
    let removed: number = 0;
    const items: VoiceFile[] = VoiceStore.list();
    const days: number = VoiceStore.retainDays();
    if (days > 0) {
      const deadline: number = Date.now() - days * 24 * 60 * 60 * 1000;
      for (const item of items) {
        if (item.modified < deadline) {
          VoiceStore.deleteFile(item.name);
          removed++;
        }
      }
    }
    let rest: VoiceFile[] = VoiceStore.list();
    const max: number = VoiceStore.maxCount();
    if (rest.length > max) {
      // 超限时一次性删掉最旧的 10 条（不足 10 条就删到上限为止）。
      let toDelete: number = Math.min(VoiceStore.BATCH, rest.length - max);
      const oldest: VoiceFile[] = rest.slice().sort((a: VoiceFile, b: VoiceFile) => a.modified - b.modified);
      for (let index: number = 0; index < toDelete; index++) {
        VoiceStore.deleteFile(oldest[index].name);
        removed++;
      }
    }
    if (removed > 0) {
      Logger.info('CHAT_VOICE', '自动清理语音 ' + String(removed) + ' 条');
    }
    return removed;
  }

  static formatSize(bytes: number): string {
    if (bytes < 1024) { return String(bytes) + 'B'; }
    if (bytes < 1024 * 1024) { return String(Math.round(bytes / 1024)) + 'KB'; }
    return (Math.round(bytes / (1024 * 1024) * 10) / 10).toString() + 'MB';
  }

  static formatTime(ms: number): string {
    const date: Date = new Date(ms);
    const pad = (value: number): string => (value < 10 ? '0' : '') + String(value);
    return String(date.getMonth() + 1) + '/' + pad(date.getDate()) + ' ' +
      pad(date.getHours()) + ':' + pad(date.getMinutes());
  }
}

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

/** 一个本地表情：直链 + 加入时间（用于排序和导出）。 */
export class StickerItem {
  url: string = '';
  addedAt: number = 0;
}

/** 表情包 JSON 的整体结构；导出的文件名固定为「无音影视表情包.json」。 */
export class EmojiPackFile {
  name: string = '无音影视表情包';
  version: number = 1;
  updatedAt: number = 0;
  items: StickerItem[] = [];
}

/**
 * 本地表情包存储。
 *
 * 表情就是一条图片直链（动图/静态图都一样），所以只需要 url：
 * 上传走 ImageHostService，收藏直接记住消息里的直链。
 * 整体以一份 JSON 导出/导入，文件名「无音影视表情包」。
 */
export class EmojiStore {
  static readonly PACK_NAME: string = '无音影视表情包';
  static readonly FILE_NAME: string = '无音影视表情包';
  static readonly FILE_SUFFIX: string = '.json';
  /** 单个表情包最多保留的条数，避免偏好存储无限膨胀。 */
  static readonly MAX_ITEMS: number = 300;
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY: string = 'customStickers';
  private static store?: preferences.Preferences;
  private static context?: common.UIAbilityContext;
  private static items: StickerItem[] = [];

  static async init(context: common.UIAbilityContext): Promise<void> {
    EmojiStore.context = context;
    try {
      EmojiStore.store = await preferences.getPreferences(context, EmojiStore.STORE);
      const raw: string = String(await EmojiStore.store.get(EmojiStore.KEY, '[]'));
      EmojiStore.items = EmojiStore.parseItems(raw);
    } catch (error) {
      Logger.error('EMOJI_STORE', '读取本地表情失败：' + String(error));
      EmojiStore.items = [];
    }
  }

  /** 返回副本，调用方改数组不会影响存储。 */
  static list(): StickerItem[] {
    const copy: StickerItem[] = [];
    for (const item of EmojiStore.items) {
      const one: StickerItem = new StickerItem();
      one.url = item.url;
      one.addedAt = item.addedAt;
      copy.push(one);
    }
    return copy;
  }

  static count(): number {
    return EmojiStore.items.length;
  }

  static has(url: string): boolean {
    return EmojiStore.items.some((item: StickerItem) => item.url === url);
  }

  /** 加入一个表情；已存在或不是 http(s) 直链时返回 false。 */
  static async add(url: string): Promise<boolean> {
    const trimmed: string = url.trim();
    if (!/^https?:\/\//i.test(trimmed)) { return false; }
    if (EmojiStore.has(trimmed)) { return false; }
    const item: StickerItem = new StickerItem();
    item.url = trimmed;
    item.addedAt = Date.now();
    EmojiStore.items = [item].concat(EmojiStore.items).slice(0, EmojiStore.MAX_ITEMS);
    await EmojiStore.persist();
    return true;
  }

  static async remove(url: string): Promise<boolean> {
    const next: StickerItem[] = EmojiStore.items.filter((item: StickerItem) => item.url !== url);
    if (next.length === EmojiStore.items.length) { return false; }
    EmojiStore.items = next;
    await EmojiStore.persist();
    return true;
  }

  static async clear(): Promise<void> {
    EmojiStore.items = [];
    await EmojiStore.persist();
  }

  static pack(): EmojiPackFile {
    const pack: EmojiPackFile = new EmojiPackFile();
    pack.name = EmojiStore.PACK_NAME;
    pack.version = 1;
    pack.updatedAt = Date.now();
    pack.items = EmojiStore.list();
    return pack;
  }

  /** 导出到用户选择的位置，返回落盘路径；取消返回空串。 */
  static async exportPack(context: common.UIAbilityContext): Promise<string> {
    try {
      const json: string = JSON.stringify(EmojiStore.pack(), null, 2);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [EmojiStore.FILE_NAME + EmojiStore.FILE_SUFFIX];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) { return ''; }
      const target: string = uris[0];
      const file: fileIo.File = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, json);
      } finally {
        fileIo.closeSync(file);
      }
      Logger.info('EMOJI_STORE', '表情包已导出：' + target + '，共 ' + String(EmojiStore.items.length) + ' 个');
      return target;
    } catch (error) {
      Logger.error('EMOJI_STORE', '导出表情包失败：' + String(error));
      throw new Error('导出失败：' + String(error));
    }
  }

  /** 从 JSON 文件导入并合并，返回新增条数。 */
  static async importPack(context: common.UIAbilityContext): Promise<number> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = [EmojiStore.FILE_SUFFIX];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) { return 0; }
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        const bytes: Uint8Array = new Uint8Array(buffer).slice(0, read > 0 ? read : stat.size);
        text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      } finally {
        fileIo.closeSync(file);
      }
      const imported: StickerItem[] = EmojiStore.parseItems(text);
      const merged: StickerItem[] = EmojiStore.merge(imported);
      if (merged.length === EmojiStore.items.length) { return 0; }
      const added: number = merged.length - EmojiStore.items.length;
      EmojiStore.items = merged;
      await EmojiStore.persist();
      Logger.info('EMOJI_STORE', '表情包已导入，新增 ' + String(added) + ' 个');
      return added;
    } catch (error) {
      Logger.error('EMOJI_STORE', '导入表情包失败：' + String(error));
      throw new Error('导入失败：' + String(error));
    }
  }

  private static merge(incoming: StickerItem[]): StickerItem[] {
    const next: StickerItem[] = EmojiStore.list();
    for (const item of incoming) {
      if (!next.some((exist: StickerItem) => exist.url === item.url)) {
        next.unshift(item);
      }
    }
    return next.slice(0, EmojiStore.MAX_ITEMS);
  }

  /** 兼容三种 JSON 形态：标准对象、裸数组、数组里直接是字符串 URL。 */
  private static parseItems(raw: string): StickerItem[] {
    const text: string = raw.trim();
    if (text.length === 0) { return []; }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (_) {
      return [];
    }
    let candidates: Object[] = [];
    if (Array.isArray(parsed)) {
      candidates = parsed as Object[];
    } else {
      const pack: Record<string, Object> = parsed as Record<string, Object>;
      const items: Object | undefined = pack['items'];
      if (Array.isArray(items)) {
        candidates = items as Object[];
      }
    }
    const result: StickerItem[] = [];
    for (const candidate of candidates) {
      let url: string = '';
      let addedAt: number = 0;
      if (typeof candidate === 'string') {
        url = String(candidate);
      } else if (candidate !== null && typeof candidate === 'object') {
        const record: Record<string, Object> = candidate as Record<string, Object>;
        const value: Object | undefined = record['url'];
        if (typeof value === 'string') { url = String(value); }
        const stamp: Object | undefined = record['addedAt'];
        if (typeof stamp === 'number') { addedAt = Number(stamp); }
      }
      const trimmed: string = url.trim();
      if (!/^https?:\/\//i.test(trimmed)) { continue; }
      if (result.some((exist: StickerItem) => exist.url === trimmed)) { continue; }
      const item: StickerItem = new StickerItem();
      item.url = trimmed;
      item.addedAt = addedAt > 0 ? addedAt : Date.now();
      result.push(item);
    }
    return result.slice(0, EmojiStore.MAX_ITEMS);
  }

  private static async persist(): Promise<void> {
    if (EmojiStore.store === undefined) {
      if (EmojiStore.context === undefined) { throw new Error('表情存储未初始化'); }
      EmojiStore.store = await preferences.getPreferences(EmojiStore.context, EmojiStore.STORE);
    }
    await EmojiStore.store.put(EmojiStore.KEY, JSON.stringify(EmojiStore.items));
    await EmojiStore.store.flush();
  }
}

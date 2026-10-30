import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppState } from './AppState';
import { Logger } from './Logger';

export interface SearchSource {
  id: number;
  name: string;
  url: string;
  urls: string;
  img: string;
}
export interface VodItem {
  vod_name: string;
  vod_id: string;
  vod_pic: string;
  vod_class: string;
  vod_remarks: string;
  playUrl: string;
}
interface RawSource {
  id?: number;
  name?: string;
  url?: string;
  urls?: string;
  img?: string;
}
interface SourceDocument {
  userlist?: RawSource[];
}
interface StoredSourceDocument {
  userlist: SearchSource[];
}

// 搜索源导入优先级：本地导入 > 远端 > 旧缓存；三份数据分别保存以便离线及再次刷新。
export class SearchSources {
  static readonly DEFAULT_ADDRESS: string = 'https://api.y11.top/fileecho.php?id=1211';
  static readonly IMPORT_FILENAME: string = '无音影视资源线路.json';
  private static remote: SearchSource[] = [];
  private static imported: SearchSource[] = [];
  private static cache: SearchSource[] = [];
  private static address: string = SearchSources.DEFAULT_ADDRESS;
  private static initialized: boolean = false;
  private static importing: boolean = false;
  private static loading: boolean = false;
  private static prefs?: preferences.Preferences;

  static currentAddress(): string { return SearchSources.address; }
  static list(): SearchSource[] { return SearchSources.merge(); }
  private static merge(): SearchSource[] {
    const byId: Map<number, SearchSource> = new Map<number, SearchSource>();
    // 缓存只用于远端和导入均为空的离线回退，不能将已从新 JSON 删除的线路重新合并进列表。
    if (SearchSources.remote.length === 0 && SearchSources.imported.length === 0) {
      SearchSources.cache.forEach((item: SearchSource) => byId.set(item.id, item));
    }
    SearchSources.remote.forEach((item: SearchSource) => byId.set(item.id, item));
    SearchSources.imported.forEach((item: SearchSource) => byId.set(item.id, item));
    return Array.from(byId.values());
  }
  private static publish(): void {
    SearchSources.cache = SearchSources.merge();
    AppStorage.setOrCreate('searchSources', SearchSources.cache.slice());
    AppStorage.setOrCreate('searchSourceAddress', SearchSources.address);
  }
  static async init(): Promise<void> {
    if (SearchSources.initialized) { SearchSources.publish(); return; }
    if (!AppState.context) { throw new Error('应用上下文尚未初始化'); }
    const prefs = await preferences.getPreferences(AppState.context, 'wuyin-search');
    SearchSources.prefs = prefs;
    try {
      SearchSources.address = String(await prefs.get('address', SearchSources.DEFAULT_ADDRESS)).trim() || SearchSources.DEFAULT_ADDRESS;
      SearchSources.cache = SearchSources.parse(String(await prefs.get('cache', '{"userlist":[]}')), '缓存');
      SearchSources.remote = SearchSources.parse(String(await prefs.get('remote', '{"userlist":[]}')), '远端缓存');
      SearchSources.imported = SearchSources.parse(String(await prefs.get('imported', '{"userlist":[]}')), '本地导入缓存');
    } catch (error) {
      Logger.error('SearchEngineLoad', '读取搜索源缓存失败：' + String(error));
    }
    SearchSources.initialized = true;
    SearchSources.publish();
  }
  // JSON 解析：支持 userlist 文档及根数组，逐项绑定 SearchSource interface，不限制线路数量。
  private static parse(text: string, origin: string): SearchSource[] {
    const data: SourceDocument | RawSource[] = JSON.parse(text) as SourceDocument | RawSource[];
    let entries: RawSource[];
    if (Array.isArray(data)) {
      entries = data as RawSource[];
    } else if (data && Array.isArray((data as SourceDocument).userlist)) {
      entries = (data as SourceDocument).userlist as RawSource[];
    } else {
      throw new Error('缺少 userlist 数组或线路数组');
    }
    const result: SearchSource[] = [];
    entries.forEach((raw: RawSource, index: number) => {
      if (!raw || typeof raw.id !== 'number' || !Number.isFinite(raw.id) ||
        typeof raw.name !== 'string' || !raw.name.trim() ||
        typeof raw.url !== 'string' || !raw.url.trim() ||
        typeof raw.urls !== 'string' || !raw.urls.trim()) {
        Logger.warn('SearchEngineLoad', origin + '第 ' + (index + 1) + ' 条缺少 id/name/url/urls，已跳过');
        return;
      }
      const base: string = raw.urls.trim();
      const imagePath: string = typeof raw.img === 'string' ? raw.img.trim() : '';
      let imageUrl: string = '';
      if (imagePath) {
        if (/^https?:\/\//i.test(imagePath)) { imageUrl = imagePath; }
        else {
          const root: string = base.replace(/\/$/, '');
          imageUrl = root + '/' + imagePath.replace(/^\//, '');
        }
      }
      const item: SearchSource = {
        id: raw.id, name: raw.name.trim(), url: raw.url.trim(), urls: base, img: imageUrl
      };
      result.push(item);
    });
    // 非空 JSON 如果全部无效，视为解析失败，保留原有线路数据。
    if (entries.length > 0 && result.length === 0) { throw new Error(origin + '中没有有效的线路'); }
    return result;
  }
  private static async persist(): Promise<void> {
    SearchSources.publish();
    if (!SearchSources.prefs) { throw new Error('搜索源存储尚未初始化'); }
    const cacheDocument: StoredSourceDocument = { userlist: SearchSources.cache };
    const remoteDocument: StoredSourceDocument = { userlist: SearchSources.remote };
    const importedDocument: StoredSourceDocument = { userlist: SearchSources.imported };
    await SearchSources.prefs.put('address', SearchSources.address);
    await SearchSources.prefs.put('cache', JSON.stringify(cacheDocument));
    await SearchSources.prefs.put('remote', JSON.stringify(remoteDocument));
    await SearchSources.prefs.put('imported', JSON.stringify(importedDocument));
    await SearchSources.prefs.flush();
  }
  // 自定义远端地址持久化；设置页保存后搜索页下一次加载立即使用。
  static async saveAddress(value: string): Promise<void> {
    await SearchSources.init();
    const address: string = value.trim();
    if (!/^https?:\/\//i.test(address)) { throw new Error('请输入 http 或 https 地址'); }
    const previous: string = SearchSources.address;
    SearchSources.address = address;
    try {
      await SearchSources.persist();
      Logger.info('SearchEngineLoad', '已保存远端搜索源地址');
    } catch (error) {
      SearchSources.address = previous;
      SearchSources.publish();
      Logger.error('SearchEngineLoad', '保存远端地址失败：' + String(error));
      throw new Error('保存远端地址失败：' + String(error));
    }
  }
  // 远端接口拉取失败不修改任何已缓存线路；调用页面负责提示离线回退。
  static async refresh(): Promise<SearchSource[]> {
    await SearchSources.init();
    if (SearchSources.loading) { return SearchSources.list(); }
    SearchSources.loading = true;
    const request = http.createHttp();
    const previous: SearchSource[] = SearchSources.remote;
    const previousCache: SearchSource[] = SearchSources.cache;
    try {
      const response = await request.request(SearchSources.address, {
        method: http.RequestMethod.GET, connectTimeout: 8000, readTimeout: 10000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('远端服务错误 ' + response.responseCode);
      }
      const parsed: SearchSource[] = SearchSources.parse(String(response.result), '远端');
      // 刷新成功完整替换远端 JSON 线路；空数组也不能被旧缓存重新填充。
      SearchSources.remote = parsed;
      SearchSources.cache = [];
      await SearchSources.persist();
      Logger.info('SearchEngineLoad', '远端搜索源加载成功，共 ' + parsed.length + ' 条');
      return SearchSources.list();
    } catch (error) {
      SearchSources.remote = previous;
      SearchSources.cache = previousCache;
      SearchSources.publish();
      Logger.error('SearchEngineLoad', '远端拉取失败，使用本地缓存：' + String(error));
      throw new Error('远端拉取失败，使用本地缓存：' + String(error));
    } finally {
      request.destroy();
      SearchSources.loading = false;
    }
  }
  // 双页面共用文件选择器及导入锁；先校验文件名，再解析完整内容，成功后才覆盖同 id 条目。
  static async importFile(context: common.UIAbilityContext): Promise<boolean> {
    if (SearchSources.importing) { throw new Error('导入正在进行，请勿重复点击'); }
    SearchSources.importing = true;
    try {
      await SearchSources.init();
      const paths: string[] = await new picker.DocumentViewPicker(context).select(new picker.DocumentSelectOptions());
      if (paths.length === 0) { return false; }
      const filename: string = decodeURIComponent(paths[0].split('/').pop() || '').split('?')[0];
      if (filename !== SearchSources.IMPORT_FILENAME) { throw new Error('文件名必须为' + SearchSources.IMPORT_FILENAME); }
      const file = fileIo.openSync(paths[0], fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const size: number = Number(fileIo.statSync(file.fd).size);
        if (size <= 0 || size > 5 * 1024 * 1024) { throw new Error('文件为空或超过 5MB'); }
        const data: ArrayBuffer = new ArrayBuffer(size);
        let count: number = 0;
        while (count < size) {
          const chunk: number = fileIo.readSync(file.fd, data, { offset: count, length: size - count });
          if (chunk <= 0) { throw new Error('文件内容读取不完整'); }
          count += chunk;
        }
        text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(data));
      } finally { fileIo.closeSync(file); }
      const incoming: SearchSource[] = SearchSources.parse(text, '本地导入');
      if (incoming.length === 0) { throw new Error('文件中没有有效的搜索源'); }
      const merged: Map<number, SearchSource> = new Map<number, SearchSource>();
      SearchSources.imported.forEach((item: SearchSource) => merged.set(item.id, item));
      incoming.forEach((item: SearchSource) => merged.set(item.id, item));
      const previous: SearchSource[] = SearchSources.imported;
      SearchSources.imported = Array.from(merged.values());
      try { await SearchSources.persist(); }
      catch (error) {
        SearchSources.imported = previous;
        SearchSources.publish();
        Logger.error('SearchEngineLoad', '保存导入搜索源失败：' + String(error));
        throw new Error('保存导入搜索源失败：' + String(error));
      }
      Logger.info('SearchEngineLoad', '成功导入 ' + incoming.length + ' 条搜索源');
      return true;
    } catch (error) {
      Logger.error('SearchEngineLoad', '导入失败：' + String(error));
      throw new Error('导入失败：' + String(error));
    } finally { SearchSources.importing = false; }
  }
}

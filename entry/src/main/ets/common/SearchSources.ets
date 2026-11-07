import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { AppState } from './AppState';
import { Logger } from './Logger';

export interface SearchSource {
  /** 线路是否启用；false 时不参与搜索（默认启用）。 */
  enabled?: boolean;
  /** 源类型：cms（默认）/ tvbox / web / netdisk，见 SourceRules.SourceKind。 */
  kind?: string;
  /** 类型对应的扩展规则 JSON（搜索模板、Referer、嗅探正则、网盘接口等）。 */
  rule?: string;
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
  enabled?: boolean;
  kind?: string;
  rule?: string;
  urls?: string;
  img?: string;
}
interface SourceDocument {
  userlist?: RawSource[];
}
interface StoredSourceDocument {
  userlist: SearchSource[];
}

// 搜索源导入优先级：自定义规则 > 本地导入 > 远端 > 旧缓存；几份数据分别保存以便离线及再次刷新。
export class SearchSources {
  /**
   * 远端地址默认留空：应用不再内置任何影视接口，线路需由用户自行填写、导入或手动添加。
   * 这样与「自定义规则」保持同一套合规定位：应用只是播放/解析工具。
   */
  static readonly DEFAULT_ADDRESS: string = '';
  static readonly IMPORT_FILENAME: string = '无音影视资源线路.json';
  /** 自定义规则 id 从这个基数往上排，避开远端/导入 JSON 的普通 id。 */
  private static readonly CUSTOM_ID_BASE: number = 900000;
  private static remote: SearchSource[] = [];
  private static imported: SearchSource[] = [];
  private static custom: SearchSource[] = [];
  private static cache: SearchSource[] = [];
  private static address: string = SearchSources.DEFAULT_ADDRESS;
  private static initialized: boolean = false;
  private static importing: boolean = false;
  private static loading: boolean = false;
  private static prefs?: preferences.Preferences;

  static currentAddress(): string { return SearchSources.address; }
  static list(): SearchSource[] { return SearchSources.merge(); }
  /** 只有用户手动添加的规则，供设置页列表展示。 */
  static customList(): SearchSource[] { return SearchSources.custom.slice(); }
  /** 设置页可管理的全部本地/远端线路：远端 + 导入 + 自定义（同 id 以自定义为准）。 */
  static managedList(): SearchSource[] {
    const byId: Map<number, SearchSource> = new Map<number, SearchSource>();
    SearchSources.remote.forEach((item: SearchSource) => byId.set(item.id, item));
    SearchSources.imported.forEach((item: SearchSource) => byId.set(item.id, item));
    SearchSources.custom.forEach((item: SearchSource) => byId.set(item.id, item));
    return Array.from(byId.values());
  }
  private static merge(): SearchSource[] {
    const byId: Map<number, SearchSource> = new Map<number, SearchSource>();
    // 缓存只用于远端和导入均为空的离线回退，不能将已从新 JSON 删除的线路重新合并进列表。
    if (SearchSources.remote.length === 0 && SearchSources.imported.length === 0 && SearchSources.custom.length === 0) {
      SearchSources.cache.forEach((item: SearchSource) => byId.set(item.id, item));
    }
    SearchSources.remote.forEach((item: SearchSource) => byId.set(item.id, item));
    SearchSources.imported.forEach((item: SearchSource) => byId.set(item.id, item));
    // 自定义规则最后写入，同 id 时以用户手动配置的为准。
    SearchSources.custom.forEach((item: SearchSource) => byId.set(item.id, item));
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
      SearchSources.address = String(await prefs.get('address', '')).trim();
      SearchSources.cache = SearchSources.parse(String(await prefs.get('cache', '{"userlist":[]}')), '缓存');
      SearchSources.remote = SearchSources.parse(String(await prefs.get('remote', '{"userlist":[]}')), '远端缓存');
      SearchSources.imported = SearchSources.parse(String(await prefs.get('imported', '{"userlist":[]}')), '本地导入缓存');
      SearchSources.custom = SearchSources.parse(String(await prefs.get('custom', '{"userlist":[]}')), '自定义规则');
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
      const rawKind: string = typeof raw.kind === 'string' ? raw.kind.trim() : '';
      const rawRule: string = typeof raw.rule === 'string' ? raw.rule.trim() : '';
      const rawEnabled: boolean = raw.enabled !== false;
      let imageUrl: string = '';
      if (imagePath) {
        if (/^https?:\/\//i.test(imagePath)) { imageUrl = imagePath; }
        else {
          const root: string = base.replace(/\/$/, '');
          imageUrl = root + '/' + imagePath.replace(/^\//, '');
        }
      }
      const item: SearchSource = {
        id: raw.id, name: raw.name.trim(), url: raw.url.trim(), urls: base, img: imageUrl,
        kind: rawKind.length > 0 ? rawKind : 'cms', rule: rawRule, enabled: rawEnabled
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
    const customDocument: StoredSourceDocument = { userlist: SearchSources.custom };
    await SearchSources.prefs.put('address', SearchSources.address);
    await SearchSources.prefs.put('cache', JSON.stringify(cacheDocument));
    await SearchSources.prefs.put('remote', JSON.stringify(remoteDocument));
    await SearchSources.prefs.put('imported', JSON.stringify(importedDocument));
    await SearchSources.prefs.put('custom', JSON.stringify(customDocument));
    await SearchSources.prefs.flush();
  }
  // 自定义远端地址持久化；设置页保存后搜索页下一次加载立即使用。
  static async saveAddress(value: string): Promise<void> {
    await SearchSources.init();
    const address: string = (value || '').trim();
    // 允许留空：留空表示不使用远端接口，只靠本地导入与自定义规则。
    if (address.length > 0 && !/^https?:\/\//i.test(address)) { throw new Error('请输入 http 或 https 地址，或留空表示不使用远端接口'); }
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
    // 没有配置远端地址时直接返回本地已有的线路（导入/自定义规则），不发无意义的请求。
    if (SearchSources.address.trim().length === 0) {
      Logger.info('SearchEngineLoad', '未配置远端地址，跳过远端拉取，使用本地线路');
      return SearchSources.list();
    }
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
  /**
   * 新增自定义规则：只填「名称 + 搜索接口」即可用；urls（图片/选集用的站点根）不填就取接口的站点根。
   * 自定义规则与远端、导入线路并存，冲突时以自定义为准。
   */
  static async addCustom(name: string, url: string, urls: string = '', kind: string = 'cms',
    rule: string = ''): Promise<SearchSource> {
    await SearchSources.init();
    const ruleName: string = (name || '').trim();
    const api: string = (url || '').trim();
    if (ruleName.length === 0) { throw new Error('请填写规则名称'); }
    if (ruleName.length > 40) { throw new Error('规则名称最多 40 个字'); }
    const sourceKind: string = (kind || 'cms').trim();
    if (sourceKind !== 'web' && sourceKind !== 'netdisk' && !/^https?:\/\//i.test(api)) {
      throw new Error('搜索接口必须是 http 或 https 地址');
    }
    if ((sourceKind === 'web' || sourceKind === 'netdisk') && api.length === 0) {
      throw new Error('请填写页面地址或解析接口地址');
    }
    if (SearchSources.custom.some((item: SearchSource) => item.url === api)) {
      throw new Error('这条接口已经在自定义规则里了');
    }
    const item: SearchSource = {
      id: SearchSources.nextCustomId(),
      name: ruleName,
      url: api,
      urls: (urls || '').trim().length > 0 ? urls.trim() : SearchSources.originOf(api),
      img: '',
      kind: sourceKind,
      rule: (rule || '').trim(),
      enabled: true
    };
    const previous: SearchSource[] = SearchSources.custom.slice();
    SearchSources.custom = SearchSources.custom.concat([item]);
    try {
      await SearchSources.persist();
    } catch (error) {
      SearchSources.custom = previous;
      SearchSources.publish();
      Logger.error('SearchEngineLoad', '保存自定义规则失败：' + String(error));
      throw new Error('保存自定义规则失败：' + String(error));
    }
    Logger.info('SearchEngineLoad', '新增自定义规则：' + ruleName + '，id=' + item.id);
    return item;
  }

  /** 重命名自定义规则。 */
  /** 批量启用/停用（自定义规则）。 */
  static async setEnabled(ids: number[], enabled: boolean): Promise<void> {
    await SearchSources.init();
    if (ids.length === 0) { return; }
    const previousCustom: SearchSource[] = SearchSources.custom.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: item.enabled };
      return copy;
    });
    const previousImported: SearchSource[] = SearchSources.imported.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: item.enabled };
      return copy;
    });
    const previousRemote: SearchSource[] = SearchSources.remote.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: item.enabled };
      return copy;
    });
    SearchSources.custom = SearchSources.custom.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: ids.indexOf(item.id) >= 0 ? enabled : (item.enabled !== false) };
      return copy;
    });
    SearchSources.imported = SearchSources.imported.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: ids.indexOf(item.id) >= 0 ? enabled : (item.enabled !== false) };
      return copy;
    });
    SearchSources.remote = SearchSources.remote.map((item: SearchSource): SearchSource => {
      const copy: SearchSource = { id: item.id, name: item.name, url: item.url, urls: item.urls, img: item.img,
        kind: item.kind, rule: item.rule, enabled: ids.indexOf(item.id) >= 0 ? enabled : (item.enabled !== false) };
      return copy;
    });
    try {
      await SearchSources.persist();
      SearchSources.publish();
      Logger.info('SearchEngineLoad', (enabled ? '启用' : '停用') + '线路 ' + String(ids.length) + ' 条');
    } catch (error) {
      SearchSources.custom = previousCustom;
      SearchSources.imported = previousImported;
      SearchSources.remote = previousRemote;
      SearchSources.publish();
      throw new Error('更新线路状态失败：' + String(error));
    }
  }

  /** 批量删除本地线路（自定义 + 已导入）。 */
  static async removeMany(ids: number[]): Promise<number> {
    await SearchSources.init();
    let removed: number = 0;
    const keepCustom: SearchSource[] = [];
    for (const item of SearchSources.custom) {
      if (ids.indexOf(item.id) >= 0) { removed++; continue; }
      keepCustom.push(item);
    }
    const keepImported: SearchSource[] = [];
    for (const item of SearchSources.imported) {
      if (ids.indexOf(item.id) >= 0) { removed++; continue; }
      keepImported.push(item);
    }
    const keepRemote: SearchSource[] = [];
    for (const item of SearchSources.remote) {
      if (ids.indexOf(item.id) >= 0) { removed++; continue; }
      keepRemote.push(item);
    }
    if (removed === 0) { return 0; }
    const previousCustom: SearchSource[] = SearchSources.custom.slice();
    const previousImported: SearchSource[] = SearchSources.imported.slice();
    const previousRemote: SearchSource[] = SearchSources.remote.slice();
    SearchSources.custom = keepCustom;
    SearchSources.imported = keepImported;
    SearchSources.remote = keepRemote;
    try {
      await SearchSources.persist();
      SearchSources.publish();
      Logger.info('SearchEngineLoad', '批量删除线路 ' + String(removed) + ' 条');
      return removed;
    } catch (error) {
      SearchSources.custom = previousCustom;
      SearchSources.imported = previousImported;
      SearchSources.remote = previousRemote;
      SearchSources.publish();
      throw new Error('批量删除失败：' + String(error));
    }
  }

  /** 参与搜索的线路：只保留启用状态的。 */
  static enabledList(): SearchSource[] {
    return SearchSources.list().filter((item: SearchSource) => item.enabled !== false);
  }

  static async renameCustom(id: number, name: string): Promise<void> {
    await SearchSources.init();
    const ruleName: string = (name || '').trim();
    if (ruleName.length === 0) { throw new Error('请填写规则名称'); }
    if (ruleName.length > 40) { throw new Error('规则名称最多 40 个字'); }
    const previous: SearchSource[] = SearchSources.custom.slice();
    SearchSources.custom = SearchSources.custom.map((item: SearchSource): SearchSource => {
      if (item.id !== id) { return item; }
      return {
        enabled: item.enabled, kind: item.kind, rule: item.rule,
        id: item.id, name: ruleName, url: item.url, urls: item.urls, img: item.img
      };
    });
    try {
      await SearchSources.persist();
    } catch (error) {
      SearchSources.custom = previous;
      SearchSources.publish();
      throw new Error('重命名失败：' + String(error));
    }
  }

  /** 删除一条本地线路（自定义或导入）；同 id 以自定义为准。 */
  static async removeCustom(id: number): Promise<void> {
    await SearchSources.init();
    const previousCustom: SearchSource[] = SearchSources.custom.slice();
    const previousImported: SearchSource[] = SearchSources.imported.slice();
    const previousRemote: SearchSource[] = SearchSources.remote.slice();
    SearchSources.custom = SearchSources.custom.filter((item: SearchSource) => item.id !== id);
    SearchSources.imported = SearchSources.imported.filter((item: SearchSource) => item.id !== id);
    SearchSources.remote = SearchSources.remote.filter((item: SearchSource) => item.id !== id);
    if (SearchSources.custom.length === previousCustom.length &&
      SearchSources.imported.length === previousImported.length &&
      SearchSources.remote.length === previousRemote.length) { return; }
    try {
      await SearchSources.persist();
      SearchSources.publish();
    } catch (error) {
      SearchSources.custom = previousCustom;
      SearchSources.imported = previousImported;
      SearchSources.remote = previousRemote;
      SearchSources.publish();
      throw new Error('删除线路失败：' + String(error));
    }
    Logger.info('SearchEngineLoad', '已删除线路 id=' + id);
  }

  /** 试连自定义接口：返回给设置页展示的结果文案，不抛异常。 */
  static async probe(url: string): Promise<string> {
    const api: string = (url || '').trim();
    if (!/^https?:\/\//i.test(api)) { return '接口必须是 http 或 https 地址'; }
    const request = http.createHttp();
    try {
      const response = await request.request(api, {
        method: http.RequestMethod.GET, connectTimeout: 6000, readTimeout: 8000
      });
      const text: string = String(response.result || '');
      return '连接成功（HTTP ' + response.responseCode + '，返回 ' + text.length + ' 字节）';
    } catch (error) {
      return '连接失败：' + String(error);
    } finally {
      request.destroy();
    }
  }

  private static nextCustomId(): number {
    let max: number = SearchSources.CUSTOM_ID_BASE;
    SearchSources.custom.forEach((item: SearchSource) => { if (item.id > max) { max = item.id; } });
    return max + 1;
  }

  private static originOf(url: string): string {
    const matched = /^(https?:\/\/[^/?#]+)/i.exec(url);
    return matched !== null && matched.length > 1 ? matched[1] : url;
  }

  /** 导出当前已启用的自定义线路，文件名固定为 无音影视资源线路.json。 */
  static async exportEnabled(context: common.UIAbilityContext,
    rules?: SearchSource[]): Promise<boolean> {
    try {
      await SearchSources.init();
      const sourceRules: SearchSource[] = rules !== undefined ? rules : SearchSources.managedList();
      const enabled: SearchSource[] = sourceRules.filter(
        (item: SearchSource): boolean => item.enabled !== false);
      if (enabled.length === 0) { throw new Error('没有已启用的自定义线路'); }
      const targets: string[] = await new picker.DocumentViewPicker(context).save({
        newFileNames: [SearchSources.IMPORT_FILENAME],
        fileSuffixChoices: ['.json']
      });
      if (targets.length === 0) {
        Logger.info('SearchEngineLoad', '取消导出已启用线路');
        return false;
      }
      const text: string = JSON.stringify({
        version: 1,
        count: enabled.length,
        userlist: enabled
      }, null, 2);
      const encoded: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(text);
      // Picker 返回的是 file:// URI；直接写入目标文件，避免 copyFile 对 URI 支持不一致导致空文件。
      const file = fs.openSync(targets[0],
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        let written: number = 0;
        while (written < encoded.byteLength) {
          const chunk: Uint8Array = encoded.slice(written);
          const count: number = fs.writeSync(file.fd, chunk.buffer);
          if (count <= 0) { throw new Error('线路文件写入不完整'); }
          written += count;
        }
      } finally {
        fs.closeSync(file);
      }
      Logger.info('SearchEngineLoad', '已导出启用线路 ' + String(enabled.length) +
        ' 条，文件=' + targets[0] + '，字节=' + String(encoded.byteLength));
      return true;
    } catch (error) {
      Logger.error('SearchEngineLoad', '导出已启用线路失败：' + String(error));
      throw new Error('导出失败：' + String(error));
    }
  }

  /** 直接导入 JSON 文本（扫一扫识别线路二维码时使用），返回导入条数。 */
  static async importText(text: string, origin: string = '扫码导入'): Promise<number> {
    await SearchSources.init();
    const incoming: SearchSource[] = SearchSources.parse(text, origin);
    if (incoming.length === 0) { throw new Error('没有可导入的线路'); }
    const merged: Map<number, SearchSource> = new Map<number, SearchSource>();
    SearchSources.imported.forEach((item: SearchSource) => merged.set(item.id, item));
    incoming.forEach((item: SearchSource) => merged.set(item.id, item));
    const previous: SearchSource[] = SearchSources.imported;
    SearchSources.imported = Array.from(merged.values());
    try {
      await SearchSources.persist();
    } catch (error) {
      SearchSources.imported = previous;
      SearchSources.publish();
      throw new Error('保存导入线路失败：' + String(error));
    }
    Logger.info('SearchEngineLoad', '扫码导入线路 ' + String(incoming.length) + ' 条');
    return incoming.length;
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
      const file = fs.openSync(paths[0], fs.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const size: number = Number(fs.statSync(file.fd).size);
        if (size <= 0 || size > 5 * 1024 * 1024) { throw new Error('文件为空或超过 5MB'); }
        const data: ArrayBuffer = new ArrayBuffer(size);
        let count: number = 0;
        while (count < size) {
          const chunk: number = fs.readSync(file.fd, data, { offset: count, length: size - count });
          if (chunk <= 0) { throw new Error('文件内容读取不完整'); }
          count += chunk;
        }
        text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(data));
      } finally { fs.closeSync(file); }
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











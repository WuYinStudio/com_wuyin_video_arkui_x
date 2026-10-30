import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export interface DanmakuItem {
  id: string;
  text: string;
  timeSec: number;
  mode: number;
  color: string;
  lane: number;
}

export interface DanmakuSettings {
  enabled: boolean;
  fontSize: number;
  opacity: number;
  speed: number;
  density: number;
  syncEnabled: boolean;
}

export interface DanmakuSearchResult {
  title: string;
  bvid: string;
  cid: number;
  duration: number;
  source: string;
  sourceId: string;
}

// 弹弹play凭证配置。AppSecret 只放占位符，不要提交真实密钥到公开源码。
// 若要正式启用，请在本地构建配置中填写 AppSecret；生产发布更推荐由自有后端代签。
const DANDAN_APP_ID: string = 'cp2j9qfti5';
const DANDAN_APP_SECRET: string = 'c6ce9Avr2J7qarL6eb52jjv58dwhUhyZ';

export class DanmakuService {
  static defaults(): DanmakuSettings {
    return { enabled: true, fontSize: 20, opacity: 0.92, speed: 1, density: 70, syncEnabled: true };
  }

  static async loadSettings(context: common.UIAbilityContext): Promise<DanmakuSettings> {
    const result: DanmakuSettings = DanmakuService.defaults();
    try {
      const store = await preferences.getPreferences(context, 'danmaku_settings');
      const raw: string = await store.get('settings', '') as string;
      if (raw) {
        const parsed = JSON.parse(raw) as DanmakuSettings;
        result.enabled = parsed.enabled !== false;
        result.fontSize = DanmakuService.clamp(parsed.fontSize, 12, 32, 20);
        result.opacity = DanmakuService.clamp(parsed.opacity, 0.3, 1, 0.92);
        result.speed = DanmakuService.clamp(parsed.speed, 0.5, 2, 1);
        result.density = DanmakuService.clamp(parsed.density, 20, 100, 70);
        result.syncEnabled = parsed.syncEnabled !== false;
      }
    } catch (_) {}
    return result;
  }

  static async saveSettings(context: common.UIAbilityContext, settings: DanmakuSettings): Promise<void> {
    const store = await preferences.getPreferences(context, 'danmaku_settings');
    await store.put('settings', JSON.stringify(settings));
    await store.flush();
  }

  static parse(text: string): DanmakuItem[] {
    const content: string = text.replace(/^\uFEFF/, '');
    if (/<i\b[^>]*\bp=/.test(content) && /<d\b/.test(content)) { return DanmakuService.parseBiliXml(content); }
    if (/\[Script Info\]/i.test(content) || /Dialogue:/i.test(content)) { return DanmakuService.parseAss(content); }
    return DanmakuService.parseSrtOrText(content);
  }

  static parseBiliXml(xml: string): DanmakuItem[] {
    const result: DanmakuItem[] = [];
    const regex: RegExp = /<d\s+p="([^"]+)"[^>]*>([\s\S]*?)<\/d>/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(xml)) !== null && result.length < 12000) {
      const fields: string[] = match[1].split(',');
      const time: number = Number(fields[0]);
      if (!Number.isFinite(time) || time < 0) { continue; }
      const mode: number = Number(fields[1]) || 1;
      const colorNumber: number = Number(fields[3]) || 16777215;
      const text: string = DanmakuService.decodeXml(match[2]).replace(/\s+/g, ' ').trim();
      if (!text) { continue; }
      result.push({ id: 'dm' + result.length, text: text.slice(0, 120), timeSec: time, mode, color: '#' + colorNumber.toString(16).padStart(6, '0').slice(-6), lane: result.length % 12 });
    }
    return result.sort((a: DanmakuItem, b: DanmakuItem) => a.timeSec - b.timeSec);
  }

  static parseAss(ass: string): DanmakuItem[] {
    const result: DanmakuItem[] = [];
    const lines: string[] = ass.split(/\r?\n/);
    for (let i: number = 0; i < lines.length && result.length < 12000; i++) {
      const line: string = lines[i].trim();
      if (!/^Dialogue:/i.test(line)) { continue; }
      const body: string = line.replace(/^Dialogue:\s*/i, '');
      const fields: string[] = body.split(',');
      if (fields.length < 10) { continue; }
      const start: number = DanmakuService.parseClock(fields[1]);
      const end: number = DanmakuService.parseClock(fields[2]);
      const text: string = fields.slice(9).join(',').replace(/\{[^}]*\}/g, '').replace(/\\N/g, ' ').replace(/\\n/g, ' ').trim();
      if (!text || start < 0) { continue; }
      result.push({ id: 'dm' + result.length, text: text.slice(0, 120), timeSec: start, mode: 1, color: '#FFFFFF', lane: result.length % 12 });
      if (end > start && end - start > 60) { /* Ignore malformed timing without failing import. */ }
    }
    return result.sort((a: DanmakuItem, b: DanmakuItem) => a.timeSec - b.timeSec);
  }

  static parseSrtOrText(input: string): DanmakuItem[] {
    const result: DanmakuItem[] = [];
    const blocks: string[] = input.split(/\r?\n\s*\r?\n/);
    for (let i: number = 0; i < blocks.length && result.length < 12000; i++) {
      const lines: string[] = blocks[i].split(/\r?\n/).map((line: string) => line.trim()).filter((line: string) => line.length > 0);
      if (lines.length === 0) { continue; }
      let time: number = -1;
      let textLines: string[] = lines;
      for (let j: number = 0; j < lines.length; j++) {
        const timing = /(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->/.exec(lines[j]);
        if (timing) { time = DanmakuService.parseClock(timing[1]); textLines = lines.slice(j + 1); break; }
      }
      if (time < 0 && lines.length > 1 && /^\d+$/.test(lines[0])) { textLines = lines.slice(1); }
      const text: string = textLines.join(' ').replace(/<[^>]+>/g, '').trim();
      if (!text) { continue; }
      result.push({ id: 'dm' + result.length, text: text.slice(0, 120), timeSec: Math.max(0, time < 0 ? result.length * 3 : time), mode: 1, color: '#FFFFFF', lane: result.length % 12 });
    }
    return result.sort((a: DanmakuItem, b: DanmakuItem) => a.timeSec - b.timeSec);
  }

  static async searchBilibili(keyword: string): Promise<DanmakuSearchResult[]> {
    const term: string = keyword.trim();
    if (!term) { throw new Error('请输入影片名称后再搜索'); }
    const client = http.createHttp();
    try {
      const url: string = 'https://api.bilibili.com/x/web-interface/search/type?search_type=video&page=1&keyword=' + encodeURIComponent(term);
      const response: http.HttpResponse = await client.request(url, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, connectTimeout: 10000, readTimeout: 15000, maxLimit: 2 * 1024 * 1024, header: { 'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.bilibili.com/' } });
      if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('在线搜索返回 HTTP ' + response.responseCode); }
      const parsed = JSON.parse(String(response.result)) as Record<string, Object>;
      const data = parsed['data'] as Record<string, Object>;
      const list = data['result'] as Object[];
      const output: DanmakuSearchResult[] = [];
      if (Array.isArray(list)) {
        for (let i: number = 0; i < list.length && output.length < 15; i++) {
          const item = list[i] as Record<string, Object>;
          const cid: number = Number(item['cid']);
          const title: string = String(item['title'] || '').replace(/<[^>]*>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
          if (cid > 0 && title) { output.push({ title, bvid: String(item['bvid'] || ''), cid, duration: DanmakuService.parseClock(String(item['duration'] || '00:00:00')), source: 'bilibili', sourceId: String(cid) }); }
        }
      }
      return output;
    } finally { client.destroy(); }
  }

  static async searchDandanPlay(keyword: string): Promise<DanmakuSearchResult[]> {
    const term: string = keyword.trim();
    if (!term) { return []; }
    const path: string = '/api/v2/search/episodes';
    const url: string = 'https://api.dandanplay.net' + path + '?anime=' + encodeURIComponent(term) + '&v2=true';
    const responseText: string = await DanmakuService.dandanRequest(url, path);
    const parsed = JSON.parse(responseText) as Record<string, Object>;
    if (parsed['success'] === false) { throw new Error('弹弹play搜索失败：' + String(parsed['errorMessage'] || '未知错误')); }
    const output: DanmakuSearchResult[] = [];
    const addEpisode = (item: Record<string, Object>, animeTitle: string): void => {
      const episodeId: string = String(item['episodeId'] || item['id'] || '');
      const episodeTitle: string = String(item['episodeTitle'] || item['title'] || item['name'] || '');
      const combined: string = (animeTitle ? animeTitle + ' ' : '') + episodeTitle;
      if (episodeId && /^\d+$/.test(episodeId) && combined.trim()) {
        let exists: boolean = false;
        for (let j: number = 0; j < output.length; j++) { if (output[j].sourceId === episodeId) { exists = true; break; } }
        if (!exists) { output.push({ title: combined.trim(), bvid: '', cid: 0, duration: Number(item['duration'] || 0), source: 'dandanplay', sourceId: episodeId }); }
      }
    };
    const topEpisodes = parsed['episodes'] as Object[];
    if (Array.isArray(topEpisodes)) {
      for (let i: number = 0; i < topEpisodes.length && output.length < 15; i++) { addEpisode(topEpisodes[i] as Record<string, Object>, String(parsed['animeTitle'] || '')); }
    }
    const animes = parsed['animes'] as Object[];
    if (Array.isArray(animes)) {
      for (let i: number = 0; i < animes.length && output.length < 15; i++) {
        const anime = animes[i] as Record<string, Object>;
        const animeTitle: string = String(anime['animeTitle'] || anime['title'] || '');
        const episodes = anime['episodes'] as Object[];
        if (Array.isArray(episodes)) { for (let j: number = 0; j < episodes.length && output.length < 15; j++) { addEpisode(episodes[j] as Record<string, Object>, animeTitle); } }
        else if (anime['episodeId'] !== undefined) { addEpisode(anime, animeTitle); }
      }
    }
    return output;
  }

  static async loadDandanPlay(episodeId: string): Promise<DanmakuItem[]> {
    if (!/^\d+$/.test(episodeId)) { throw new Error('弹弹play节目编号无效'); }
    const path: string = '/api/v2/comment/' + episodeId;
    const responseText: string = await DanmakuService.dandanRequest('https://api.dandanplay.net' + path + '?withRelated=true', path);
    const parsed = JSON.parse(responseText) as Record<string, Object>;
    if (parsed['success'] === false) { throw new Error('弹弹play弹幕加载失败：' + String(parsed['errorMessage'] || '未知错误')); }
    const comments = parsed['comments'] as Object[];
    const output: DanmakuItem[] = [];
    if (Array.isArray(comments)) {
      for (let i: number = 0; i < comments.length && output.length < 12000; i++) {
        const item = comments[i] as Record<string, Object>;
        const text: string = String(item['text'] || item['commentText'] || item['message'] || item['content'] || '').trim();
        const timeSec: number = Number(item['time'] !== undefined ? item['time'] : item['timeSec']);
        if (!text || !Number.isFinite(timeSec) || timeSec < 0) { continue; }
        const colorValue: number = Number(item['color'] || 16777215);
        const modeValue: number = Number(item['mode'] || 1);
        output.push({ id: 'dd' + output.length, text: text.slice(0, 120), timeSec, mode: modeValue, color: '#' + Math.max(0, colorValue).toString(16).padStart(6, '0').slice(-6), lane: output.length % 12 });
      }
    }
    if (output.length === 0) { throw new Error('弹弹play没有返回可解析的弹幕'); }
    return output.sort((a: DanmakuItem, b: DanmakuItem) => a.timeSec - b.timeSec);
  }

  static async loadOnline(result: DanmakuSearchResult): Promise<DanmakuItem[]> {
    if (result.source === 'dandanplay') { return await DanmakuService.loadDandanPlay(result.sourceId); }
    return await DanmakuService.loadBilibili(result.cid);
  }

  private static async dandanRequest(url: string, path: string): Promise<string> {
    if (!DANDAN_APP_ID || !DANDAN_APP_SECRET || DANDAN_APP_SECRET === 'REPLACE_WITH_DANDANPLAY_APP_SECRET') {
      throw new Error('弹弹play尚未配置 AppSecret。请在 DanmakuService.ets 本地配置密钥，勿将密钥提交到公开仓库。');
    }
    const timestamp: string = String(Math.floor(Date.now() / 1000));
    const raw: string = DANDAN_APP_ID + timestamp + path + DANDAN_APP_SECRET;
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(raw) });
    const digest = await md.digest();
    const signature: string = new util.Base64Helper().encodeToStringSync(digest.data);
    const client = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, connectTimeout: 10000, readTimeout: 15000, maxLimit: 8 * 1024 * 1024, header: { 'X-AppId': DANDAN_APP_ID, 'X-Timestamp': timestamp, 'X-Signature': signature, 'Accept': 'application/json', 'User-Agent': 'WuyinHarmony/1.0' } });
      if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('弹弹play接口返回 HTTP ' + response.responseCode); }
      return String(response.result);
    } finally { client.destroy(); }
  }

  static async loadBilibili(cid: number): Promise<DanmakuItem[]> {
    if (!Number.isFinite(cid) || cid <= 0) { throw new Error('弹幕视频 ID 无效'); }
    const client = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request('https://comment.bilibili.com/' + Math.floor(cid) + '.xml', { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, connectTimeout: 10000, readTimeout: 15000, maxLimit: 8 * 1024 * 1024, header: { 'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.bilibili.com/' } });
      if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('弹幕源返回 HTTP ' + response.responseCode); }
      const result: DanmakuItem[] = DanmakuService.parseBiliXml(String(response.result));
      if (result.length === 0) { throw new Error('该视频没有可解析的弹幕，或在线接口限制了请求'); }
      return result;
    } finally { client.destroy(); }
  }

  private static decodeXml(value: string): string {
    return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#39;/g, "'").replace(/&amp;/g, '&');
  }

  private static parseClock(value: string): number {
    const match = /^(\d+):(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?$/.exec(value.trim());
    if (!match) { return -1; }
    const fraction: number = match[4] ? Number('0.' + match[4]) : 0;
    return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) + fraction;
  }

  private static clamp(value: number, min: number, max: number, fallback: number): number {
    const n: number = Number(value);
    return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
  }
}

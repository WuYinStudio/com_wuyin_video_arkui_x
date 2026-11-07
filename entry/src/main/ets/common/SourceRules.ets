import http from '@ohos.net.http';
import { Logger } from './Logger';
import { SearchSource } from './SearchSources';
import { DnsService } from './DnsService';

/**
 * 源规则引擎：把「一条源」扩展成可自定义的规则，支持四类数据源。
 *
 * - cms     ：苹果CMS V10 采集接口（?ac=detail&wd=关键词），现状能力；
 * - tvbox   ：TVBox 配置里的 site（api 多为苹果CMS，个别是 json 爬虫，按 cms 兼容处理）；
 * - web     ：网页资源嗅探，先取页面 HTML，再按规则正则提取 m3u8/mp4 直链；
 * - netdisk ：远程网盘资源，请求用户自建的解析接口（模板里 {share} 替换为分享链接/关键词）。
 *
 * 设计要点：所有类型最终都返回「CMS 形态的 JSON 文本」，这样搜索页的解析逻辑完全不用改。
 */

export class SourceKind {
  static readonly CMS: string = 'cms';
  static readonly TVBOX: string = 'tvbox';
  static readonly WEB: string = 'web';
  static readonly NETDISK: string = 'netdisk';

  static label(kind: string): string {
    if (kind === SourceKind.TVBOX) { return 'TVBox'; }
    if (kind === SourceKind.WEB) { return '网页嗅探'; }
    if (kind === SourceKind.NETDISK) { return '网盘'; }
    return 'CMS';
  }

  static normalize(kind: string): string {
    if (kind === SourceKind.TVBOX || kind === SourceKind.WEB || kind === SourceKind.NETDISK) { return kind; }
    return SourceKind.CMS;
  }
}

/** 一条源规则的可选配置，存成 JSON 放在 SearchSource.rule 里。 */
export class SourceRule {
  /** 搜索地址模板：{kw} 会被替换成关键词；不写占位符时按 CMS 规则追加 ?wd=。 */
  searchUrl: string = '';
  /** 网页嗅探的页面地址模板（同为 {kw} 占位）；为空时用 searchUrl。 */
  pageUrl: string = '';
  /** 网盘解析接口模板：支持 {share}（分享链接）、{kw}（关键词）。 */
  netdiskApi: string = '';
  /** 请求头 Referer / User-Agent（部分站点不带会被拒）。 */
  referer: string = '';
  userAgent: string = '';
  /** 网页嗅探用于提取直链的正则（不填用内置的媒体后缀正则）。 */
  mediaRegex: string = '';
  /** 结果标题前缀，便于在搜索列表里区分来源。 */
  note: string = '';
  /** TVBox 的 playUrl 代理前缀（json: 开头），拼接播放地址时前置并 URL 编码。 */
  playProxy: string = '';

  static parse(json: string): SourceRule {
    const rule: SourceRule = new SourceRule();
    const text: string = (json || '').trim();
    if (text.length === 0) { return rule; }
    try {
      const raw: Record<string, string> = JSON.parse(text) as Record<string, string>;
      rule.searchUrl = SourceRules.text(raw, 'searchUrl');
      rule.pageUrl = SourceRules.text(raw, 'pageUrl');
      rule.netdiskApi = SourceRules.text(raw, 'netdiskApi');
      rule.referer = SourceRules.text(raw, 'referer');
      rule.userAgent = SourceRules.text(raw, 'userAgent');
      rule.mediaRegex = SourceRules.text(raw, 'mediaRegex');
      rule.note = SourceRules.text(raw, 'note');
      rule.playProxy = SourceRules.text(raw, 'playProxy');
    } catch (error) {
      Logger.warn('SOURCE_RULE', '规则 JSON 解析失败，按默认规则处理：' + String(error));
    }
    return rule;
  }

  static stringify(rule: SourceRule): string {
    const raw: Record<string, string> = {
      'searchUrl': rule.searchUrl, 'pageUrl': rule.pageUrl, 'netdiskApi': rule.netdiskApi,
      'referer': rule.referer, 'userAgent': rule.userAgent, 'mediaRegex': rule.mediaRegex, 'note': rule.note,
      'playProxy': rule.playProxy
    };
    return JSON.stringify(raw);
  }
}

export interface RuleSource {
  name: string;
  url: string;
  urls: string;
  kind?: string;
  rule?: string;
}

/** CMS 形态返回体，用于把嗅探/网盘结果喂给搜索页的解析器。 */
class CmsRow {
  vod_id: string = '';
  vod_name: string = '';
  vod_pic: string = '';
  vod_remarks: string = '';
  vod_play_url: string = '';
  type_name: string = '';
}

class CmsBody {
  code: number = 1;
  msg: string = '数据列表';
  page: number = 1;
  pagecount: number = 1;
  limit: string = '20';
  total: number = 1;
  list: CmsRow[] = [];
}

class CmsRowLike {
  vod_id?: string | number;
  vod_name?: string;
  vod_pic?: string;
  vod_remarks?: string;
  vod_play_url?: string;
  vod_play_from?: string;
  vod_play_groups?: string[];
  vod_play_names?: string[];
  type_name?: string;
}

class CmsRoot {
  code?: number;
  list?: CmsRowLike[];
}

class TvboxSiteRaw {
  name?: string;
  api?: string;
  type?: number;
  searchable?: number;
  playUrl?: string;
}

class TvboxConfig {
  sites?: TvboxSiteRaw[];
}

/** TVBox 配置里的一个站点。 */
export class TvboxSite {
  name: string = '';
  api: string = '';
  type: number = 1;
  searchable: number = 1;
  /** TVBox 的 playUrl 代理（形如 json:http://host/?url=）。 */
  playUrl: string = '';
}

export class SourceRules {
  private static readonly MEDIA_PATTERN: RegExp = /https?:\/\/[^\s"'<>()\\]+?\.(?:m3u8|mp4|m4v|flv)(?:\?[^\s"'<>()\\]*)?/ig;

  static text(raw: Record<string, string>, key: string): string {
    try {
      const value: string | undefined = raw[key];
      return typeof value === 'string' ? value.trim() : '';
    } catch (_) {
      return '';
    }
  }

  /** 关键词替换：{kw}/{word} 占位优先；否则按苹果CMS 习惯拼 wd=（已带 wd= 的位置式追加）。 */
  static withKeyword(template: string, word: string): string {
    const url: string = SourceRules.searchReadyUrl((template || '').trim());
    const encoded: string = encodeURIComponent(word);
    if (url.indexOf('{kw}') >= 0) { return url.split('{kw}').join(encoded); }
    if (url.indexOf('{word}') >= 0) { return url.split('{word}').join(encoded); }
    if (/[?&]wd=$/i.test(url)) { return url + encoded; }
    if (url.indexOf('?') < 0) { return url + '?wd=' + encoded; }
    return url + '&wd=' + encoded;
  }

  /**
   * 把 TVBox 常见的「列表接口」改成「搜索接口」。
   * 苹果CMS 的 ?ac=list 只返回列表、不含 vod_play_url，搜索必须用 ac=detail；
   * 这里统一把 ac=list 替换为 ac=detail，缺少 ac 时补上。
   */
  static searchReadyUrl(url: string): string {
    try {
      const text: string = (url || '').trim();
      if (text.length === 0 || text.indexOf('provide/vod') < 0) { return text; }
      if (/[?&]ac=list/i.test(text)) { return text.replace(/ac=list/ig, 'ac=detail'); }
      if (/[?&]ac=/i.test(text)) { return text; }
      return text + (text.indexOf('?') < 0 ? '?ac=detail' : '&ac=detail');
    } catch (_) {
      return url;
    }
  }

  /** 给播放地址套上 TVBox 的 playUrl 代理（json: 前缀去掉后作为前缀，地址做 URL 编码）。 */
  static applyProxy(address: string, proxy: string): string {
    const link: string = (address || '').trim();
    const base: string = (proxy || '').trim();
    if (link.length === 0 || base.length === 0) { return link; }
    if (link.indexOf(base) === 0) { return link; }
    const clean: string = base.startsWith('json:') ? base.substring(5) : base;
    return clean + encodeURIComponent(link);
  }

  /**
   * 把苹果CMS/TVBox 的返回 JSON 归一成无音影视的接口形态。
   *
   * TVBox 与苹果CMS 的 vod_play_url 用 ''$'' 分隔多条线路，每条线路内用 # 分集、$ 分「集名/地址」；
   * 无音影视只认单条线路（# 分集 + $ 分集名与地址），所以这里挑出含 m3u8 的那一组（没有就取最后一组），
   * 并补上缺失的集名，避免播放器把多条线路当成一集。
   */
  static normalizeCms(text: string, proxy: string = ''): string {
    const body: string = (text || '').trim();
    if (body.length === 0 || body.charAt(0) !== '{') { return text; }
    try {
      const root: CmsRoot = JSON.parse(body) as CmsRoot;
      const rows: CmsRowLike[] | undefined = root.list;
      if (rows === undefined || !Array.isArray(rows)) { return text; }
      for (const row of rows) {
        const play: string = typeof row.vod_play_url === 'string' ? row.vod_play_url : '';
        if (play.length === 0) { continue; }
        const from: string = typeof row.vod_play_from === 'string' ? row.vod_play_from : '';
        const groups: string[] = play.split('$$$');
        const names: string[] = from.length > 0 ? from.split('$$$') : [];
        const normalized: string[] = [];
        for (const group of groups) {
          const packed: string = SourceRules.pickPlayGroup(group);
          if (packed.length > 0 && normalized.indexOf(packed) < 0) { normalized.push(packed); }
        }
        if (normalized.length === 0) { continue; }
        // 主线路优先含 m3u8 的那组，其余线路作为「可切换线路」一起下发。
        let primaryIndex: number = 0;
        for (let index = 0; index < normalized.length; index++) {
          if (normalized[index].toLowerCase().indexOf('.m3u8') >= 0) { primaryIndex = index; break; }
        }
        row.vod_play_url = SourceRules.proxyGroup(normalized[primaryIndex], proxy);
        const extra: string[] = [];
        const extraNames: string[] = [];
        for (let index = 0; index < normalized.length; index++) {
          if (index === primaryIndex) { continue; }
          extra.push(SourceRules.proxyGroup(normalized[index], proxy));
          extraNames.push(index < names.length ? names[index].trim() : '线路' + String(index + 1));
        }
        row.vod_play_groups = extra;
        row.vod_play_names = extraNames;
      }
      return JSON.stringify(root);
    } catch (error) {
      Logger.warn('SOURCE_RULE', 'CMS 返回归一失败，按原文使用：' + String(error));
      return text;
    }
  }

  /** 从  分组里挑一组可播放的线路，并规整成「集名#集名」。 */
  /** 给一条线路组里的每个播放地址套上 TVBox 的 playUrl 代理。 */
  private static proxyGroup(group: string, proxy: string): string {
    if (proxy.length === 0 || group.length === 0) { return group; }
    const episodes: string[] = group.split('#');
    const out: string[] = [];
    for (const episode of episodes) {
      const split: number = episode.indexOf('$');
      if (split < 0) {
        out.push('第' + String(out.length + 1) + '集$' + SourceRules.applyProxy(episode, proxy));
        continue;
      }
      out.push(episode.substring(0, split) + '$' + SourceRules.applyProxy(episode.substring(split + 1), proxy));
    }
    return out.join('#');
  }

  private static pickPlayGroup(play: string): string {
    let groups: string[] = play.split('$');
    if (groups.length === 0) { groups = [play]; }
    let chosen: string = groups[groups.length - 1];
    for (const group of groups) {
      if (group.toLowerCase().indexOf('.m3u8') >= 0) { chosen = group; break; }
    }
    const episodes: string[] = chosen.split('#');
    const out: string[] = [];
    for (let index = 0; index < episodes.length; index++) {
      const episode: string = episodes[index].trim();
      if (episode.length === 0) { continue; }
      if (episode.indexOf('$') < 0) {
        if (!/^https?:\/\//i.test(episode)) { continue; }
        out.push('第' + String(index + 1) + '集$' + episode);
        continue;
      }
      const split: number = episode.indexOf('$');
      const title: string = episode.substring(0, split).trim();
      const address: string = episode.substring(split + 1).trim();
      if (!/^https?:\/\//i.test(address)) { continue; }
      out.push((title.length > 0 ? title : '第' + String(index + 1) + '集') + '$' + address);
    }
    return out.join('#');
  }

  /**
   * 取一条源的搜索结果文本：统一产出 CMS 形态 JSON，交给搜索页现有解析器。
   * cms / tvbox 直接透传接口原文；web / netdisk 由这里包装成 list。
   */
  static async fetchText(source: SearchSource, word: string): Promise<string> {
    const kind: string = SourceKind.normalize(source.kind === undefined ? '' : source.kind);
    const rule: SourceRule = SourceRule.parse(source.rule === undefined ? '' : source.rule);
    if (kind === SourceKind.WEB) {
      return await SourceRules.fetchWeb(source, rule, word);
    }
    if (kind === SourceKind.NETDISK) {
      return await SourceRules.fetchNetdisk(source, rule, word);
    }
    // cms / tvbox：接口本身就是 CMS 形态，直接请求。
    const base: string = rule.searchUrl.length > 0 ? rule.searchUrl : source.url;
    const url: string = SourceRules.withKeyword(base, word);
    const body: string = await SourceRules.request(url, rule.referer, rule.userAgent);
    // 把 TVBox/苹果CMS 的多线路 vod_play_url 归一成无音影视的单线路格式。
    return SourceRules.normalizeCms(body, rule.playProxy);
  }

  /** 网页嗅探：抓页面 → 正则提直链 → 包装成一条「已嗅探到 N 个直链」的结果。 */
  private static async fetchWeb(source: SearchSource, rule: SourceRule, word: string): Promise<string> {
    const page: string = SourceRules.withKeyword(rule.pageUrl.length > 0 ? rule.pageUrl
      : (rule.searchUrl.length > 0 ? rule.searchUrl : source.url), word);
    const html: string = await SourceRules.request(page, rule.referer, rule.userAgent);
    // 一级：搜索结果页里直接带直链（多数短剧站把 m3u8 塞在 HTML 或内联 JSON 里）。
    const direct: string[] = SourceRules.extractMedia(html, rule.mediaRegex);
    if (direct.length > 0) {
      const playUrl: string = direct.map((link: string, index: number): string =>
        '直链' + String(index + 1) + '$' + link).join('#');
      return SourceRules.wrapCms(source.name, '嗅探到 ' + String(direct.length) + ' 条直链', playUrl, '');
    }
    // 二级：搜索结果页只有详情页链接时，逐个进详情页嗅探（最多 8 个）。
    const details: string[] = SourceRules.extractDetailLinks(html, page, 8);
    if (details.length === 0) {
      throw new Error('没有嗅探到直链，也没有可进入的详情链接（该站可能由 JS 渲染，需要它的接口）');
    }
    const rows: CmsRow[] = [];
    for (let index = 0; index < details.length; index++) {
      try {
        const referer: string = rule.referer.length > 0 ? rule.referer : page;
        const detailHtml: string = await SourceRules.request(details[index], referer, rule.userAgent);
        const media: string[] = SourceRules.extractMedia(detailHtml, rule.mediaRegex);
        if (media.length === 0) { continue; }
        const title: string = SourceRules.pageTitle(detailHtml);
        const playUrl: string = media.map((link: string, order: number): string =>
          '第' + String(order + 1) + '集$' + link).join('#');
        const row: CmsRow = new CmsRow();
        row.vod_id = String(Date.now()) + '-' + String(index);
        row.vod_name = title.length > 0 ? title : ('结果 ' + String(index + 1));
        row.vod_remarks = '嗅探到 ' + String(media.length) + ' 条直链';
        row.vod_play_url = playUrl;
        row.type_name = '资源';
        rows.push(row);
      } catch (error) {
        Logger.warn('SOURCE_RULE', '详情页嗅探失败：' + String(error));
      }
    }
    if (rows.length === 0) {
      throw new Error('详情页里也没有嗅探到可播放直链');
    }
    const body: CmsBody = new CmsBody();
    body.total = rows.length;
    body.list = rows;
    return JSON.stringify(body);
  }

  /** 提取详情页链接：同站、去重、排除资源类与站外地址。 */
  static extractDetailLinks(html: string, baseUrl: string, limit: number): string[] {
    const result: string[] = [];
    try {
      const origin: string = (/^https?:\/\/[^/]+/i.exec(baseUrl)?.[0] || '').toLowerCase();
      const pattern: RegExp = /href\s*=\s*[\u0022\u0027]([^\u0022\u0027]+)[\u0022\u0027]/ig;
      let matched: RegExpExecArray | null = pattern.exec(html);
      while (matched !== null) {
        const href: string = matched[1].trim();
        matched = pattern.exec(html);
        if (href.length === 0 || href.indexOf('javascript:') === 0 || href.indexOf('#') === 0) { continue; }
        if (/\.(?:png|jpe?g|gif|webp|svg|css|js|ico|woff2?)(?:\?|$)/i.test(href)) { continue; }
        if (/\.(?:m3u8|mp4|m4v|flv)(?:\?|$)/i.test(href)) { continue; }
        let absolute: string = href;
        if (href.indexOf('//') === 0) { absolute = 'https:' + href; }
        else if (href.indexOf('/') === 0) { absolute = origin + href; }
        else if (!/^https?:/i.test(href)) { continue; }
        if (origin.length > 0 && absolute.toLowerCase().indexOf(origin) !== 0) { continue; }
        if (result.indexOf(absolute) >= 0 || result.length >= limit) { continue; }
        result.push(absolute);
      }
    } catch (error) {
      Logger.warn('SOURCE_RULE', '解析详情链接失败：' + String(error));
    }
    return result;
  }

  /** 取 HTML 的 title 作为结果标题。 */
  static pageTitle(html: string): string {
    const matched: RegExpExecArray | null = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
    if (matched === null) { return ''; }
    return matched[1].replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim().substring(0, 60);
  }

  /** 网盘解析：请求用户自建接口（模板支持 {share}/{kw}），从返回 JSON 里取播放地址。 */
  private static async fetchNetdisk(source: SearchSource, rule: SourceRule, word: string): Promise<string> {
    const api: string = rule.netdiskApi.length > 0 ? rule.netdiskApi
      : (rule.searchUrl.length > 0 ? rule.searchUrl : source.url);
    const url: string = SourceRules.withKeyword(api.split('{share}').join(encodeURIComponent(word)), word);
    const body: string = await SourceRules.request(url, rule.referer, rule.userAgent);
    const playUrl: string = SourceRules.extractNetdiskPlayUrl(body);
    if (playUrl.length === 0) {
      throw new Error('网盘接口没有返回可播放地址（需返回 url/playUrl/direct 字段）');
    }
    return SourceRules.wrapCms(source.name, '网盘资源', '第1集$' + playUrl, '');
  }

  /** 从页面文本里按正则提取媒体直链（去重、最多 20 条）。 */
  static extractMedia(html: string, customRegex: string): string[] {
    const found: string[] = [];
    const push = (value: string): void => {
      const url: string = (value || '').trim();
      if (url.length === 0 || found.indexOf(url) >= 0 || found.length >= 20) { return; }
      found.push(url);
    };
    try {
      if (customRegex.trim().length > 0) {
        const custom: RegExp = new RegExp(customRegex, 'ig');
        let matched: RegExpExecArray | null = custom.exec(html);
        while (matched !== null) {
          push(matched.length > 1 ? matched[1] : matched[0]);
          matched = custom.exec(html);
        }
      }
      const builtin: RegExp = new RegExp(SourceRules.MEDIA_PATTERN.source, 'ig');
      let hit: RegExpExecArray | null = builtin.exec(html);
      while (hit !== null) {
        push(hit[0]);
        hit = builtin.exec(html);
      }
    } catch (error) {
      Logger.warn('SOURCE_RULE', '嗅探正则执行失败：' + String(error));
    }
    return found;
  }

  /** 网盘接口返回 JSON 中常见的播放字段。 */
  static extractNetdiskPlayUrl(body: string): string {
    try {
      const data: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const keys: string[] = ['url', 'playUrl', 'direct', 'm3u8', 'link'];
      for (const key of keys) {
        const value: Object | undefined = data[key];
        if (typeof value === 'string' && /^https?:\/\//i.test(value)) { return value; }
      }
      const list: Object | undefined = data['list'];
      if (Array.isArray(list) && list.length > 0) {
        const first: Object = list[0] as Object;
        if (typeof first === 'string' && /^https?:\/\//i.test(first)) { return first; }
        const nested: Record<string, Object> = first as Record<string, Object>;
        for (const key of keys) {
          const value: Object | undefined = nested[key];
          if (typeof value === 'string' && /^https?:\/\//i.test(value)) { return value; }
        }
      }
    } catch (error) {
      Logger.warn('SOURCE_RULE', '网盘接口返回解析失败：' + String(error));
    }
    return '';
  }

  private static wrapCms(name: string, remarks: string, playUrl: string, pic: string): string {
    const row: CmsRow = new CmsRow();
    row.vod_id = name + '-' + String(Date.now());
    row.vod_name = name;
    row.vod_pic = pic;
    row.vod_remarks = remarks;
    row.vod_play_url = playUrl;
    row.type_name = '资源';
    const body: CmsBody = new CmsBody();
    body.list = [row];
    return JSON.stringify(body);
  }

  private static async request(url: string, referer: string, userAgent: string): Promise<string> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {};
      if (referer.length > 0) { header['Referer'] = referer; }
      if (userAgent.length > 0) { header['User-Agent'] = userAgent; }
      // 按设置注入 DoH（阿里/腾讯），未开启时不干预 DNS。
      await DnsService.init();
      const doh: string = DnsService.endpoint();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 12000,
        header: header,
        expectDataType: http.HttpDataType.STRING
      };
      if (doh.length > 0) { options.dnsOverHttps = doh; }
      const response = await request.request(url, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('HTTP ' + response.responseCode);
      }
      return String(response.result || '');
    } finally {
      request.destroy();
    }
  }

  /** 解析 TVBox 配置（{ sites:[...] } 或 sites 数组），转成可导入的源列表。 */
  static parseTvbox(jsonText: string): TvboxSite[] {
    const result: TvboxSite[] = [];
    try {
      const config: TvboxConfig = JSON.parse(jsonText) as TvboxConfig;
      const sites: TvboxSiteRaw[] | undefined = config.sites;
      if (sites === undefined || !Array.isArray(sites)) { throw new Error('不是 TVBox 配置：缺少 sites 数组'); }
      for (const raw of sites) {
        const api: string = typeof raw.api === 'string' ? String(raw.api).trim() : '';
        const name: string = typeof raw.name === 'string' ? String(raw.name).trim() : '';
        if (api.length === 0 || name.length === 0 || !/^https?:\/\//i.test(api)) { continue; }
        const site: TvboxSite = new TvboxSite();
        site.name = name;
        site.api = api;
        site.type = typeof raw.type === 'number' ? Number(raw.type) : 1;
        site.searchable = typeof raw.searchable === 'number' ? Number(raw.searchable) : 1;
        site.playUrl = typeof raw.playUrl === 'string' ? String(raw.playUrl).trim() : '';
        if (site.searchable === 0) { continue; }
        result.push(site);
      }
    } catch (error) {
      Logger.warn('SOURCE_RULE', 'TVBox 配置解析失败：' + String(error));
      throw new Error('TVBox 配置解析失败：' + String(error));
    }
    if (result.length === 0) { throw new Error('TVBox 配置里没有可用站点'); }
    return result;
  }
}












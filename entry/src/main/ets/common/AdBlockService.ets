import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Logger } from './Logger';
import { asSocketLike } from './PlatformSocketLike';

/**
 * 广告拦截（HLS / m3u8 广告分片过滤）。
 *
 * 工作方式：
 * 1. 播放地址如果是 m3u8，就换成 `http://127.0.0.1:<port>/hls?u=<原始地址>`；
 * 2. 应用内起一个只监听回环地址的 TCP 代理，只代理「播放列表」这一层：
 *    - 拉取原始 m3u8，按规则剔除广告分片；
 *    - 普通分片地址改写成 CDN 绝对直链（不再经过应用），不增加流量与解码延迟；
 *    - 嵌套播放列表 / 多码率子列表仍走代理，保证广告过滤对每一层都生效；
 * 3. 任何一步失败（拉取失败、解析异常、上游拒绝）都 302 回原始地址，不影响正常播放。
 *
 * 不接入任何外部引擎，全部用系统 HTTP 客户端 + TCP Socket 完成；关闭开关后立即恢复直连。
 */
export class AdBlockService {
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_ENABLED: string = 'adBlockEnabled';
  private static readonly HOST: string = '127.0.0.1';
  private static readonly PORTS: number[] = [18089, 18090, 18091, 18092];
  private static readonly MAX_HEAD: number = 32 * 1024;
  private static readonly MAX_REDIRECT: number = 4;
  private static readonly USER_AGENT: string =
    'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36';

  private static store?: preferences.Preferences;
  private static enabled: boolean = true;
  private static server?: socket.TCPSocketServer;
  private static port: number = 0;
  private static starting?: Promise<number>;
  private static handled: number = 0;
  private static blocked: number = 0;
  /** HLS 分片磁盘缓存：暂停时继续预取，已缓存分片由本地代理直接回放。 */
  private static cacheDir: string = '';
  private static cacheBytes: number = 0;
  private static readonly MAX_CACHE_BYTES: number = 512 * 1024 * 1024;
  /** 单次暂停最多向后预取 10 分钟，避免一次暂停就把整部剧集下载完。 */
  private static readonly PREFETCH_WINDOW_MS: number = 10 * 60 * 1000;
  private static playlists: Map<string, CachedPlaylist> = new Map();
  private static lastPlaylistKey: string = '';
  private static prefetchToken: number = 0;
  private static prefetching: boolean = false;

  /** 启动时读取开关；由 EntryAbility 调用一次。 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      if (AdBlockService.store === undefined) {
        AdBlockService.store = await preferences.getPreferences(context, AdBlockService.STORE);
      }
      const store: preferences.Preferences = AdBlockService.store;
      const saved: boolean = Boolean(await store.get(AdBlockService.KEY_ENABLED, true));
      AdBlockService.enabled = saved;
      AppStorage.setOrCreate<boolean>('adBlockEnabled', saved);
      // 初始化 HLS 分片缓存目录，并统计已有缓存大小。
      AdBlockService.cacheDir = context.cacheDir + '/hls-cache';
      AdBlockService.ensureCacheDir();
      AdBlockService.scanCache();
      AppStorage.setOrCreate<number>('hlsCacheMs', 0);
      AppStorage.setOrCreate<number>('hlsCacheTotalMs', 0);
      AppStorage.setOrCreate<boolean>('hlsCacheActive', false);
      Logger.info('AD_BLOCK', '广告拦截配置已恢复：' + (saved ? '开启' : '关闭') +
        '，HLS 缓存=' + AdBlockService.byteText(AdBlockService.cacheBytes));
    } catch (error) {
      Logger.error('AD_BLOCK', '读取广告拦截配置失败：' + String(error));
      AppStorage.setOrCreate<boolean>('adBlockEnabled', AdBlockService.enabled);
    }
  }

  static isEnabled(): boolean {
    return AdBlockService.enabled;
  }

  static async setEnabled(value: boolean): Promise<void> {
    AdBlockService.enabled = value;
    AppStorage.setOrCreate<boolean>('adBlockEnabled', value);
    const store: preferences.Preferences | undefined = AdBlockService.store;
    if (store !== undefined) {
      try {
        await store.put(AdBlockService.KEY_ENABLED, value);
        await store.flush();
      } catch (error) {
        Logger.error('AD_BLOCK', '保存广告拦截开关失败：' + String(error));
      }
    }
    Logger.info('AD_BLOCK', value ? '已开启广告拦截' : '已关闭广告拦截');
  }

  /** 只处理 http(s) 的 m3u8；本地文件、直链视频、已代理地址都不处理。 */
  static looksLikeHls(url: string): boolean {
    if (!/^https?:\/\//i.test(url)) {
      return false;
    }
    if (url.indexOf(AdBlockService.HOST) >= 0) {
      return false;
    }
    return url.toLowerCase().indexOf('m3u8') >= 0;
  }

  /**
   * 把播放地址包装成本地代理地址；不可用或启动失败时返回原地址。
   * 即使关闭广告拦截也仍然代理 m3u8：本地代理同时承担分片磁盘缓存与暂停预取。
   */
  static async wrap(url: string): Promise<string> {
    if (!AdBlockService.looksLikeHls(url)) {
      return url;
    }
    try {
      const port: number = await AdBlockService.ensureServer();
      if (port <= 0) {
        return url;
      }
      Logger.info('AD_BLOCK', '播放地址已接入本地媒体代理：' + AdBlockService.shortUrl(url));
      return 'http://' + AdBlockService.HOST + ':' + String(port) + '/hls?u=' + encodeURIComponent(url);
    } catch (error) {
      Logger.warn('AD_BLOCK', '启动本地媒体代理失败，回退原始地址：' + String(error));
      return url;
    }
  }

  // ---------------- 本地代理 ----------------

  private static ensureServer(): Promise<number> {
    if (AdBlockService.port > 0) {
      return Promise.resolve(AdBlockService.port);
    }
    if (AdBlockService.starting === undefined) {
      AdBlockService.starting = AdBlockService.startServer();
    }
    return AdBlockService.starting;
  }

  private static async startServer(): Promise<number> {
    for (const port of AdBlockService.PORTS) {
      let server: socket.TCPSocketServer | undefined;
      try {
        server = socket.constructTCPSocketServerInstance();
        const listener: socket.TCPSocketServer = server;
        asSocketLike(listener).on('connect', (connection: socket.TCPSocketConnection): void => {
          AdBlockService.accept(connection);
        });
        asSocketLike(listener).on('error', (error: BusinessError): void => {
          Logger.warn('AD_BLOCK', '本地过滤代理异常：' + String(error));
        });
        await listener.listen({ address: AdBlockService.HOST, port: port, family: 1 });
        AdBlockService.server = listener;
        AdBlockService.port = port;
        Logger.info('AD_BLOCK', '本地过滤代理已启动：http://' + AdBlockService.HOST + ':' + String(port));
        return port;
      } catch (error) {
        Logger.warn('AD_BLOCK', '本地过滤代理端口 ' + String(port) + ' 不可用：' + String(error));
        if (server !== undefined) {
          try {
            await server.close();
          } catch (caught) {
            Logger.warn('AD_BLOCK', '释放代理端口失败：' + String(caught));
          }
        }
      }
    }
    Logger.error('AD_BLOCK', '本地过滤代理启动失败，播放将回退直连');
    return 0;
  }

  private static accept(connection: socket.TCPSocketConnection): void {
    let data: Uint8Array = new Uint8Array(0);
    let done: boolean = false;
    try {
      asSocketLike(connection).on('message', (info: socket.SocketMessageInfo): void => {
        if (done) {
          return;
        }
        try {
          const chunk: Uint8Array = new Uint8Array(info.message);
          if (data.length + chunk.length > AdBlockService.MAX_HEAD) {
            done = true;
            void AdBlockService.closeQuietly(connection);
            return;
          }
          const merged: Uint8Array = new Uint8Array(data.length + chunk.length);
          merged.set(data, 0);
          merged.set(chunk, data.length);
          data = merged;
          const headEnd: number = AdBlockService.headerEnd(data);
          if (headEnd < 0) {
            return;
          }
          done = true;
          const head: string = util.TextDecoder.create('utf-8').decodeToString(data.subarray(0, headEnd));
          void AdBlockService.handle(connection, head);
        } catch (error) {
          Logger.warn('AD_BLOCK', '读取代理请求失败：' + String(error));
          done = true;
          void AdBlockService.closeQuietly(connection);
        }
      });
      asSocketLike(connection).on('error', (error: BusinessError): void => {
        Logger.warn('AD_BLOCK', '代理连接异常：' + String(error));
      });
      asSocketLike(connection).on('close', (): void => {
        done = true;
      });
    } catch (error) {
      Logger.warn('AD_BLOCK', '建立代理连接失败：' + String(error));
      void AdBlockService.closeQuietly(connection);
    }
  }

  private static async handle(connection: socket.TCPSocketConnection, head: string): Promise<void> {
    try {
      const lines: string[] = head.split('\r\n');
      const request: string[] = (lines.length > 0 ? lines[0] : '').split(' ');
      const method: string = (request.length > 0 ? request[0] : 'GET').toUpperCase();
      const rawPath: string = request.length > 1 ? request[1] : '/';
      const question: number = rawPath.indexOf('?');
      const path: string = question >= 0 ? rawPath.substring(0, question) : rawPath;
      const query: string = question >= 0 ? rawPath.substring(question + 1) : '';
      const target: string = AdBlockService.queryValue(query, 'u');
      if (target.length === 0) {
        await AdBlockService.sendText(connection, '400 Bad Request', 'text/plain; charset=utf-8',
          'missing u', method === 'HEAD');
        return;
      }
      let range: string = '';
      for (const line of lines) {
        const lower: string = line.toLowerCase();
        if (lower.startsWith('range:')) {
          range = line.substring(6).trim();
        }
      }
      if (path === '/hls') {
        await AdBlockService.proxyPlaylist(connection, target, method === 'HEAD');
        return;
      }
      if (path === '/seg') {
        await AdBlockService.proxySegment(connection, target, range, method === 'HEAD');
        return;
      }
      await AdBlockService.sendText(connection, '404 Not Found', 'text/plain; charset=utf-8',
        'not found', method === 'HEAD');
    } catch (error) {
      Logger.warn('AD_BLOCK', '处理代理请求失败：' + String(error));
      await AdBlockService.closeQuietly(connection);
    }
  }

  /** 播放列表：抓取 → 过滤广告 → 分片改写为本地代理（可缓存）；失败优先用会话内缓存。 */
  private static async proxyPlaylist(connection: socket.TCPSocketConnection, target: string, headOnly: boolean): Promise<void> {
    let raw: string = '';
    try {
      const fetched: ProxyResponse = await AdBlockService.fetch(target);
      raw = fetched.text;
    } catch (error) {
      const cached: CachedPlaylist | undefined = AdBlockService.playlists.get(target);
      if (cached !== undefined && cached.text.length > 0) {
        Logger.info('AD_BLOCK', '播放列表拉取失败，使用会话缓存：' + AdBlockService.shortUrl(target));
        await AdBlockService.sendText(connection, '200 OK', 'application/vnd.apple.mpegurl; charset=utf-8',
          cached.text, headOnly);
        return;
      }
      Logger.warn('AD_BLOCK', '拉取播放列表失败，回退原始地址：' + String(error));
      await AdBlockService.sendRedirect(connection, target);
      return;
    }
    try {
      AdBlockService.handled++;
      if (raw.indexOf('#EXTM3U') < 0) {
        await AdBlockService.sendRedirect(connection, target);
        return;
      }
      const live: boolean = raw.indexOf('#EXT-X-ENDLIST') < 0;
      // 直播不做磁盘缓存，分片保持 CDN 直链；点播把分片改写到本地代理以便缓存。
      const cacheSegments: boolean = !live;
      const filtered: PlaylistResult = AdBlockService.rewritePlaylist(raw, target, AdBlockService.port,
        AdBlockService.enabled, cacheSegments);
      let body: string = filtered.text;
      let cacheable: boolean = true;
      if (filtered.kept === 0) {
        body = AdBlockService.rewritePlaylist(raw, target, 0, false, false).text;
        cacheable = false;
      } else if (filtered.removed > 0) {
        AdBlockService.blocked += filtered.removed;
        Logger.info('AD_BLOCK', '已过滤 ' + String(filtered.removed) + ' 个广告分片：' + AdBlockService.shortUrl(target));
      }
      if (cacheable) {
        const previous: CachedPlaylist | undefined = AdBlockService.playlists.get(target);
        const record: CachedPlaylist = new CachedPlaylist();
        record.key = target;
        record.master = filtered.master;
        record.live = live;
        record.segments = filtered.segments;
        record.totalMs = filtered.totalMs;
        record.text = body;
        AdBlockService.playlists.set(target, record);
        if (!filtered.master) {
          // 主列表本身也缓存文本，断网时还能把子列表地址交回播放器。
          const last: CachedPlaylist | undefined = AdBlockService.playlists.get(AdBlockService.lastPlaylistKey);
          if (last === undefined || last.master || record.segments.length >= last.segments.length) {
            AdBlockService.lastPlaylistKey = target;
          }
          // 刷新同一份播放列表时保留已有缓存进度；换集/换源才清零。
          if (previous === undefined || Math.abs(previous.totalMs - record.totalMs) > 1000) {
            AppStorage.setOrCreate<number>('hlsCacheMs', 0);
          }
          AppStorage.setOrCreate<number>('hlsCacheTotalMs', record.totalMs);
          AppStorage.setOrCreate<boolean>('hlsCacheActive', false);
        }
        Logger.info('AD_BLOCK', '播放列表已缓存：' + (filtered.master ? '主列表' :
          String(record.segments.length) + ' 个分片，总时长=' + String(Math.round(record.totalMs / 1000)) + 's'));
      }
      await AdBlockService.sendText(connection, '200 OK', 'application/vnd.apple.mpegurl; charset=utf-8',
        body, headOnly);
    } catch (error) {
      Logger.warn('AD_BLOCK', '改写播放列表失败，回退原始地址：' + String(error));
      await AdBlockService.sendRedirect(connection, target);
    }
  }

  /** 分片：优先读磁盘缓存；未命中则拉取并落盘，失败回退 CDN 直链。 */
  private static async proxySegment(connection: socket.TCPSocketConnection, target: string,
    range: string, headOnly: boolean): Promise<void> {
    try {
      const path: string = AdBlockService.cachePath(target);
      if (AdBlockService.fileExists(path)) {
        const cached: ArrayBuffer | undefined = AdBlockService.readFile(path);
        if (cached !== undefined) {
          await AdBlockService.sendCachedSegment(connection, cached, range, target, headOnly);
          return;
        }
      }
      const fetched: ProxyResponse = await AdBlockService.fetchBinary(target);
      if (fetched.code < 200 || fetched.code >= 300) {
        throw new Error('上游返回 HTTP ' + String(fetched.code));
      }
      if (fetched.code === 200 && range.length === 0 && fetched.bytes.byteLength > 0) {
        AdBlockService.saveCache(target, fetched.bytes);
      }
      const headers: string[] = [
        'Content-Type: ' + (fetched.contentType.length > 0 ? fetched.contentType : AdBlockService.mimeOf(target)),
        'Accept-Ranges: bytes'
      ];
      const status: string = fetched.code === 206 ? '206 Partial Content' : '200 OK';
      await AdBlockService.sendBytes(connection, status, headers, fetched.bytes, headOnly);
    } catch (error) {
      Logger.warn('AD_BLOCK', '代理分片失败，回退原始地址：' + String(error));
      await AdBlockService.sendRedirect(connection, target);
    }
  }

  // ---------------- 播放列表改写 ----------------

  private static rewritePlaylist(raw: string, base: string, proxyPort: number, filterAds: boolean,
    cacheSegments: boolean): PlaylistResult {
    const result: PlaylistResult = new PlaylistResult();
    const lines: string[] = raw.split('\n');
    const master: boolean = raw.indexOf('#EXT-X-STREAM-INF') >= 0;
    const live: boolean = raw.indexOf('#EXT-X-ENDLIST') < 0;
    result.master = master;
    result.live = live;
    const out: string[] = [];
    let pending: string[] = [];
    let streamTag: string = '';
    let pendingDurationMs: number = 0;
    for (const rawLine of lines) {
      const line: string = rawLine.replace(/\r$/, '');
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (AdBlockService.isAdTag(trimmed)) {
          continue;
        }
        if (trimmed.startsWith('#EXTINF')) {
          const matched: RegExpExecArray | null = /^#EXTINF:\s*([0-9.]+)/.exec(trimmed);
          const seconds: number = matched !== null ? Number(matched[1]) : 0;
          pendingDurationMs = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds * 1000)) : 0;
        }
        if (master) {
          if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
            streamTag = AdBlockService.rewriteTagUris(trimmed, base, proxyPort, cacheSegments);
            continue;
          }
          out.push(AdBlockService.rewriteTagUris(trimmed, base, proxyPort, cacheSegments));
          continue;
        }
        if (AdBlockService.isSegmentTag(trimmed)) {
          pending.push(AdBlockService.rewriteTagUris(trimmed, base, proxyPort, cacheSegments));
          continue;
        }
        out.push(AdBlockService.rewriteTagUris(trimmed, base, proxyPort, cacheSegments));
        continue;
      }
      const absolute: string = AdBlockService.resolveUrl(trimmed, base);
      if (master) {
        if (filterAds && AdBlockService.isAdUri(absolute)) {
          streamTag = '';
          result.removed++;
          continue;
        }
        if (streamTag.length > 0) {
          out.push(streamTag);
          streamTag = '';
        }
        out.push(AdBlockService.proxied(absolute, '/hls', proxyPort));
        result.kept++;
        continue;
      }
      if (filterAds && AdBlockService.isAdUri(absolute)) {
        pending = [];
        pendingDurationMs = 0;
        result.removed++;
        continue;
      }
      for (const tag of pending) {
        out.push(tag);
      }
      pending = [];
      if (cacheSegments) {
        // 点播分片走本地代理，代理会落盘缓存；暂停时还会主动预取后续分片。
        out.push(AdBlockService.proxied(absolute, '/seg', proxyPort));
        const segment: CachedSegment = new CachedSegment();
        segment.url = absolute;
        segment.durationMs = pendingDurationMs;
        result.segments.push(segment);
        result.totalMs += pendingDurationMs;
      } else {
        // 直播 / 关闭缓存：分片直接用 CDN 绝对地址，不转发媒体字节。
        out.push(absolute);
      }
      pendingDurationMs = 0;
      result.kept++;
    }
    for (const tag of pending) {
      out.push(tag);
    }
    if (streamTag.length > 0) {
      out.push(streamTag);
    }
    result.text = out.join('\n') + '\n';
    return result;
  }

  /**
   * 改写标签里的 URI="..."：
   * - 多码率子列表 / 备用音轨继续走代理，保证下一层播放列表也参与过滤与缓存；
   * - 密钥、init 分片、LL-HLS 分片在缓存模式下拉到本地代理，
   *   这样断网时已缓存分片仍然可解密/拼接；关闭缓存时保持绝对直链。
   */
  private static rewriteTagUris(tag: string, base: string, proxyPort: number, cacheMedia: boolean): string {
    if (tag.indexOf('URI="') < 0) {
      return tag;
    }
    const mediaTag: boolean = tag.startsWith('#EXT-X-MEDIA');
    // 字幕 / 闭路字幕不是播放列表，保持直链；音频、视频轨与 I-Frame 列表继续走代理。
    const subtitles: boolean = mediaTag && /TYPE="?SUBTITLES"?/i.test(tag);
    const playlistUri: boolean = proxyPort > 0 &&
      ((mediaTag && !subtitles) || tag.startsWith('#EXT-X-I-FRAME-STREAM-INF'));
    const mediaUri: boolean = cacheMedia && proxyPort > 0 &&
      (tag.startsWith('#EXT-X-KEY') || tag.startsWith('#EXT-X-MAP') ||
        tag.startsWith('#EXT-X-PART') || tag.startsWith('#EXT-X-PRELOAD-HINT'));
    if (!playlistUri && !mediaUri) {
      return tag.replace(/URI="([^"]*)"/g, (match: string, uri: string): string => {
        return 'URI="' + AdBlockService.resolveUrl(uri, base) + '"';
      });
    }
    const endpoint: string = playlistUri ? '/hls' : '/seg';
    return tag.replace(/URI="([^"]*)"/g, (match: string, uri: string): string => {
      const absolute: string = AdBlockService.resolveUrl(uri, base);
      return 'URI="' + AdBlockService.proxied(absolute, endpoint, proxyPort) + '"';
    });
  }

  private static proxied(absolute: string, endpoint: string, proxyPort: number): string {
    if (proxyPort <= 0) {
      return absolute;
    }
    if (!/^https?:\/\//i.test(absolute)) {
      return absolute;
    }
    return 'http://' + AdBlockService.HOST + ':' + String(proxyPort) + endpoint + '?u=' + encodeURIComponent(absolute);
  }

  /** 广告分片判定：路径目录 + 文件名两类标记，尽量只命中明显的广告命名。 */
  private static isAdUri(uri: string): boolean {
    const lower: string = uri.toLowerCase();
    if (/\/(ad|ads|adv|advert|adverts|advertisement|advertising|guanggao|gg|sponsor|preroll|midroll|postroll|adjump)(\/|$)/.test(lower)) {
      return true;
    }
    const path: string = lower.split('#')[0].split('?')[0];
    const name: string = path.substring(path.lastIndexOf('/') + 1);
    if (/^(ad|ads|adv|advert|guanggao|gg|sponsor|preroll|midroll|postroll)[-_.]?\d*\.(ts|m4s|mp4|aac|m4a|webm)$/.test(name)) {
      return true;
    }
    return /(^|[-_.])(ad|ads|adv|advert|guanggao|sponsor|preroll|midroll|postroll)([-_.]|$)/.test(name);
  }

  private static isSegmentTag(tag: string): boolean {
    return tag.startsWith('#EXTINF') || tag.startsWith('#EXT-X-BYTERANGE') ||
      tag.startsWith('#EXT-X-DISCONTINUITY') || tag.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
      tag.startsWith('#EXT-X-GAP') || tag.startsWith('#EXT-X-BITRATE');
  }

  private static isAdTag(tag: string): boolean {
    return tag.startsWith('#EXT-X-CUE-OUT') || tag.startsWith('#EXT-X-CUE-IN') ||
      tag.startsWith('#EXT-X-SCTE35') || tag.startsWith('#EXT-OATCLS-SCTE35') ||
      tag.startsWith('#EXT-X-ASSET') || tag.startsWith('#EXT-X-SIGNAL') || tag.startsWith('#EXT-X-AD');
  }

  private static resolveUrl(uri: string, base: string): string {
    const value: string = uri.trim();
    if (value.length === 0) {
      return base;
    }
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value)) {
      return value;
    }
    const match: RegExpExecArray | null = /^(https?):\/\/([^\/?#]+)([^?#]*)/i.exec(base);
    if (match === null) {
      return value;
    }
    const scheme: string = match[1];
    const host: string = match[2];
    const basePath: string = match[3];
    if (value.startsWith('//')) {
      return scheme + ':' + value;
    }
    if (value.startsWith('/')) {
      return scheme + '://' + host + value;
    }
    const dir: string = basePath.substring(0, basePath.lastIndexOf('/') + 1);
    return scheme + '://' + host + AdBlockService.normalizePath(dir + value);
  }

  private static normalizePath(path: string): string {
    const question: number = path.indexOf('?');
    const suffix: string = question >= 0 ? path.substring(question) : '';
    const clean: string = question >= 0 ? path.substring(0, question) : path;
    const parts: string[] = clean.split('/');
    const stack: string[] = [];
    for (const part of parts) {
      if (part.length === 0 || part === '.') {
        continue;
      }
      if (part === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(part);
    }
    return '/' + stack.join('/') + suffix;
  }

  // ---------------- 网络请求 ----------------

  private static async fetch(url: string): Promise<ProxyResponse> {
    let current: string = url;
    for (let hop = 0; hop <= AdBlockService.MAX_REDIRECT; hop++) {
      const response: ProxyResponse = await AdBlockService.request(current);
      if (response.code >= 300 && response.code < 400 && response.location.length > 0) {
        current = AdBlockService.resolveUrl(response.location, current);
        continue;
      }
      return response;
    }
    throw new Error('重定向次数过多');
  }

  private static async request(url: string): Promise<ProxyResponse> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': AdBlockService.USER_AGENT,
        'Accept': 'application/vnd.apple.mpegurl, application/x-mpegURL, */*',
        // 关闭压缩，避免播放列表被 gzip 后无法解析。
        'Accept-Encoding': 'identity',
        'Referer': AdBlockService.originOf(url)
      };
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000,
        readTimeout: 6000,
        usingCache: false,
        maxLimit: 4 * 1024 * 1024,
        header: headers
      });
      const result: ProxyResponse = new ProxyResponse();
      result.code = response.responseCode;
      const responseHeaders: Record<string, string> = response.header as Record<string, string>;
      result.contentType = String(responseHeaders['content-type'] || responseHeaders['Content-Type'] || '');
      result.location = String(responseHeaders['location'] || responseHeaders['Location'] || '');
      if (typeof response.result === 'string') {
        result.text = response.result;
      }
      return result;
    } finally {
      try {
        client.destroy();
      } catch (error) {
        Logger.warn('AD_BLOCK', '释放代理请求连接失败：' + String(error));
      }
    }
  }

  private static async fetchBinary(url: string): Promise<ProxyResponse> {
    let current: string = url;
    for (let hop = 0; hop <= AdBlockService.MAX_REDIRECT; hop++) {
      const response: ProxyResponse = await AdBlockService.requestBinary(current);
      if (response.code >= 300 && response.code < 400 && response.location.length > 0) {
        current = AdBlockService.resolveUrl(response.location, current);
        continue;
      }
      return response;
    }
    throw new Error('重定向次数过多');
  }

  private static async requestBinary(url: string): Promise<ProxyResponse> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': AdBlockService.USER_AGENT,
        'Accept': '*/*',
        'Accept-Encoding': 'identity',
        'Referer': AdBlockService.originOf(url)
      };
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 20000,
        usingCache: false,
        maxLimit: 32 * 1024 * 1024,
        header: headers
      });
      const result: ProxyResponse = new ProxyResponse();
      result.code = response.responseCode;
      const responseHeaders: Record<string, string> = response.header as Record<string, string>;
      result.contentType = String(responseHeaders['content-type'] || responseHeaders['Content-Type'] || '');
      result.contentRange = String(responseHeaders['content-range'] || responseHeaders['Content-Range'] || '');
      result.location = String(responseHeaders['location'] || responseHeaders['Location'] || '');
      if (response.result instanceof ArrayBuffer) {
        result.bytes = response.result as ArrayBuffer;
      }
      return result;
    } finally {
      try {
        client.destroy();
      } catch (error) {
        Logger.warn('AD_BLOCK', '释放分片请求连接失败：' + String(error));
      }
    }
  }

  private static originOf(url: string): string {
    const match: RegExpExecArray | null = /^(https?):\/\/([^\/?#]+)/i.exec(url);
    return match === null ? '' : match[1] + '://' + match[2] + '/';
  }

  // ---------------- HTTP 响应 ----------------

  private static async sendText(connection: socket.TCPSocketConnection, status: string, contentType: string,
    text: string, headOnly: boolean): Promise<void> {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const body: ArrayBuffer = new ArrayBuffer(bytes.length);
    new Uint8Array(body).set(bytes, 0);
    const headers: string[] = ['Content-Type: ' + contentType];
    await AdBlockService.sendBytes(connection, status, headers, body, headOnly);
  }

  private static async sendBytes(connection: socket.TCPSocketConnection, status: string, headers: string[],
    body: ArrayBuffer, headOnly: boolean): Promise<void> {
    const length: number = body.byteLength;
    let head: string = 'HTTP/1.1 ' + status + '\r\n';
    for (const line of headers) {
      head += line + '\r\n';
    }
    head += 'Content-Length: ' + String(length) + '\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n';
    const headBytes: Uint8Array = new util.TextEncoder().encodeInto(head);
    const headBuffer: ArrayBuffer = new ArrayBuffer(headBytes.length);
    new Uint8Array(headBuffer).set(headBytes, 0);
    try {
      await connection.send({ data: headBuffer });
      if (!headOnly && length > 0) {
        // 分片可能几 MB，按 512KB 顺序发送，避免一次性大缓冲和单次 send 的尺寸限制。
        const view: Uint8Array = new Uint8Array(body);
        const chunkSize: number = 512 * 1024;
        let offset: number = 0;
        while (offset < view.length) {
          const end: number = Math.min(view.length, offset + chunkSize);
          const chunk: ArrayBuffer = new ArrayBuffer(end - offset);
          new Uint8Array(chunk).set(view.subarray(offset, end), 0);
          await connection.send({ data: chunk });
          offset = end;
        }
      }
    } catch (error) {
      Logger.warn('AD_BLOCK', '回写代理响应失败：' + String(error));
    } finally {
      await AdBlockService.closeQuietly(connection);
    }
  }

  private static async sendRedirect(connection: socket.TCPSocketConnection, location: string): Promise<void> {
    const empty: ArrayBuffer = new ArrayBuffer(0);
    await AdBlockService.sendBytes(connection, '302 Found',
      ['Location: ' + location, 'Content-Type: text/plain; charset=utf-8'], empty, false);
  }

  private static async closeQuietly(connection: socket.TCPSocketConnection): Promise<void> {
    try {
      await connection.close();
    } catch (error) {
      Logger.warn('AD_BLOCK', '关闭代理连接失败：' + String(error));
    }
  }

  // ---------------- 工具 ----------------

  private static headerEnd(data: Uint8Array): number {
    for (let index = 0; index + 3 < data.length; index++) {
      if (data[index] === 13 && data[index + 1] === 10 && data[index + 2] === 13 && data[index + 3] === 10) {
        return index + 4;
      }
    }
    return -1;
  }

  private static queryValue(query: string, name: string): string {
    if (query.length === 0) {
      return '';
    }
    const prefix: string = name + '=';
    for (const pair of query.split('&')) {
      if (pair.startsWith(prefix)) {
        try {
          return decodeURIComponent(pair.substring(prefix.length).replace(/\+/g, '%20'));
        } catch (error) {
          return '';
        }
      }
    }
    return '';
  }

  // ---------------- HLS 分片磁盘缓存 ----------------

  private static ensureCacheDir(): void {
    if (AdBlockService.cacheDir.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(AdBlockService.cacheDir)) {
        fs.mkdirSync(AdBlockService.cacheDir);
      }
    } catch (error) {
      Logger.warn('AD_BLOCK', '创建 HLS 缓存目录失败：' + String(error));
    }
  }

  private static scanCache(): void {
    if (AdBlockService.cacheDir.length === 0) {
      return;
    }
    try {
      const names: string[] = fs.listFileSync(AdBlockService.cacheDir);
      let total: number = 0;
      for (const name of names) {
        try {
          total += Number(fs.statSync(AdBlockService.cacheDir + '/' + name).size);
        } catch (error) {
          Logger.warn('AD_BLOCK', '统计缓存文件失败：' + String(error));
        }
      }
      AdBlockService.cacheBytes = total;
      AdBlockService.pruneCache();
    } catch (error) {
      Logger.warn('AD_BLOCK', '扫描 HLS 缓存目录失败：' + String(error));
    }
  }

  /** 超过上限后按修改时间从旧到新删除，保留约 80% 容量。 */
  private static pruneCache(): void {
    if (AdBlockService.cacheDir.length === 0 || AdBlockService.cacheBytes <= AdBlockService.MAX_CACHE_BYTES) {
      return;
    }
    try {
      const files: CacheFileInfo[] = [];
      const names: string[] = fs.listFileSync(AdBlockService.cacheDir);
      for (const name of names) {
        try {
          const info = fs.statSync(AdBlockService.cacheDir + '/' + name);
          const entry: CacheFileInfo = new CacheFileInfo();
          entry.name = name;
          entry.size = Number(info.size);
          entry.mtime = Number(info.mtime);
          files.push(entry);
        } catch (error) {
          Logger.warn('AD_BLOCK', '读取缓存文件信息失败：' + String(error));
        }
      }
      files.sort((first: CacheFileInfo, second: CacheFileInfo): number => first.mtime - second.mtime);
      const target: number = Math.floor(AdBlockService.MAX_CACHE_BYTES * 0.8);
      for (const file of files) {
        if (AdBlockService.cacheBytes <= target) {
          break;
        }
        try {
          fs.unlinkSync(AdBlockService.cacheDir + '/' + file.name);
          AdBlockService.cacheBytes -= file.size;
        } catch (error) {
          Logger.warn('AD_BLOCK', '删除缓存文件失败：' + String(error));
        }
      }
      Logger.info('AD_BLOCK', 'HLS 缓存清理完成，当前=' + AdBlockService.byteText(AdBlockService.cacheBytes));
    } catch (error) {
      Logger.warn('AD_BLOCK', '清理 HLS 缓存失败：' + String(error));
    }
  }

  private static cacheKey(url: string): string {
    let hash: number = 2166136261;
    for (let index = 0; index < url.length; index++) {
      hash ^= url.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    const hex: string = (hash >>> 0).toString(16);
    return ('00000000' + hex).slice(-8) + '-' + url.length.toString(16);
  }

  private static cachePath(url: string): string {
    return AdBlockService.cacheDir + '/' + AdBlockService.cacheKey(url) + '.bin';
  }

  private static fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private static readFile(path: string): ArrayBuffer | undefined {
    try {
      const stat = fs.statSync(path);
      const size: number = Number(stat.size);
      if (!Number.isFinite(size) || size <= 0) {
        return undefined;
      }
      const target: Uint8Array = new Uint8Array(size);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let position: number = 0;
        while (position < size) {
          const remaining: number = size - position;
          const chunk: ArrayBuffer = new ArrayBuffer(remaining);
          const read: number = fs.readSync(file.fd, chunk, { length: remaining });
          if (read <= 0) {
            break;
          }
          target.set(new Uint8Array(chunk).subarray(0, read), position);
          position += read;
        }
        if (position <= 0) {
          return undefined;
        }
        const result: ArrayBuffer = new ArrayBuffer(position);
        new Uint8Array(result).set(target.subarray(0, position), 0);
        return result;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Logger.warn('AD_BLOCK', '读取分片缓存失败：' + String(error));
      return undefined;
    }
  }

  private static saveCache(url: string, bytes: ArrayBuffer): void {
    if (AdBlockService.cacheDir.length === 0 || bytes.byteLength === 0) {
      return;
    }
    const path: string = AdBlockService.cachePath(url);
    if (AdBlockService.fileExists(path)) {
      return;
    }
    const temp: string = path + '.tmp' + String(Date.now()) + String(Math.floor(Math.random() * 1000));
    try {
      const file = fs.openSync(temp,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      // 先写临时文件再改名，避免并发请求读到写了一半的分片。
      fs.renameSync(temp, path);
      AdBlockService.cacheBytes += bytes.byteLength;
      if (AdBlockService.cacheBytes > AdBlockService.MAX_CACHE_BYTES) {
        AdBlockService.pruneCache();
      }
    } catch (error) {
      Logger.warn('AD_BLOCK', '写入分片缓存失败：' + String(error));
      try {
        if (AdBlockService.fileExists(temp)) {
          fs.unlinkSync(temp);
        }
      } catch (caught) {
        Logger.warn('AD_BLOCK', '清理临时缓存文件失败：' + String(caught));
      }
    }
  }

  /** 已缓存分片按 Range 返回 200/206。 */
  private static async sendCachedSegment(connection: socket.TCPSocketConnection, bytes: ArrayBuffer,
    range: string, target: string, headOnly: boolean): Promise<void> {
    const total: number = bytes.byteLength;
    let start: number = 0;
    let end: number = total - 1;
    let partial: boolean = false;
    if (range.length > 0) {
      const matched: RegExpExecArray | null = /bytes=(\d*)-(\d*)/.exec(range);
      if (matched !== null) {
        start = matched[1].length > 0 ? Number(matched[1]) : 0;
        end = matched[2].length > 0 ? Number(matched[2]) : total - 1;
        if (!Number.isFinite(start) || start < 0) { start = 0; }
        if (!Number.isFinite(end) || end >= total) { end = total - 1; }
        if (start > end || start >= total) {
          await AdBlockService.sendBytes(connection, '416 Range Not Satisfiable',
            ['Content-Range: bytes */' + String(total)], new ArrayBuffer(0), headOnly);
          return;
        }
        partial = true;
      }
    }
    const slice: ArrayBuffer = bytes.slice(start, end + 1);
    const headers: string[] = [
      'Content-Type: ' + AdBlockService.mimeOf(target),
      'Accept-Ranges: bytes'
    ];
    if (partial) {
      headers.push('Content-Range: bytes ' + String(start) + '-' + String(end) + '/' + String(total));
    }
    await AdBlockService.sendBytes(connection, partial ? '206 Partial Content' : '200 OK', headers, slice, headOnly);
  }

  private static mimeOf(url: string): string {
    const clean: string = url.split('#')[0].split('?')[0].toLowerCase();
    if (clean.endsWith('.ts')) { return 'video/mp2t'; }
    if (clean.endsWith('.m4s') || clean.endsWith('.mp4') || clean.endsWith('.m4v')) { return 'video/mp4'; }
    if (clean.endsWith('.aac') || clean.endsWith('.m4a')) { return 'audio/aac'; }
    if (clean.endsWith('.key')) { return 'application/octet-stream'; }
    return 'application/octet-stream';
  }

  private static byteText(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return (Math.round(bytes / 1024 / 1024 * 10) / 10).toString() + ' MB';
    }
    if (bytes >= 1024) {
      return Math.round(bytes / 1024).toString() + ' KB';
    }
    return String(bytes) + ' B';
  }

  // ---------------- 暂停预取 ----------------

  /** 切集 / 换源时清空缓存进度显示（磁盘文件保留，后续命中仍可秒开）。 */
  static resetCacheProgress(): void {
    AdBlockService.lastPlaylistKey = '';
    AppStorage.setOrCreate<number>('hlsCacheMs', 0);
    AppStorage.setOrCreate<number>('hlsCacheTotalMs', 0);
    AppStorage.setOrCreate<boolean>('hlsCacheActive', false);
  }

  /** 暂停时调用：从当前位置向后预取分片，最多 10 分钟或缓存上限。 */
  static beginPrefetch(positionMs: number): void {
    const playlist: CachedPlaylist | undefined = AdBlockService.playlists.get(AdBlockService.lastPlaylistKey);
    if (playlist === undefined || playlist.live || playlist.segments.length === 0) {
      return;
    }
    AdBlockService.endPrefetch();
    const token: number = AdBlockService.prefetchToken;
    AdBlockService.prefetching = true;
    AppStorage.setOrCreate<boolean>('hlsCacheActive', true);
    Logger.info('AD_BLOCK', '暂停预取开始：' + AdBlockService.shortUrl(playlist.key));
    void AdBlockService.runPrefetch(playlist, positionMs, token);
  }

  /** 恢复播放 / 切集 / 离开页面时调用：停止预取，把带宽让给播放。 */
  static endPrefetch(): void {
    AdBlockService.prefetchToken++;
    if (AdBlockService.prefetching) {
      AdBlockService.prefetching = false;
      AppStorage.setOrCreate<boolean>('hlsCacheActive', false);
    }
  }

  private static async runPrefetch(playlist: CachedPlaylist, positionMs: number, token: number): Promise<void> {
    let elapsed: number = 0;
    let index: number = 0;
    for (; index < playlist.segments.length; index++) {
      if (elapsed + playlist.segments[index].durationMs > positionMs) {
        break;
      }
      elapsed += playlist.segments[index].durationMs;
    }
    const limit: number = positionMs + AdBlockService.PREFETCH_WINDOW_MS;
    let cachedMs: number = elapsed;
    for (let cursor = index; cursor < playlist.segments.length; cursor++) {
      if (token !== AdBlockService.prefetchToken ||
        AdBlockService.cacheBytes >= AdBlockService.MAX_CACHE_BYTES || cachedMs > limit) {
        break;
      }
      const segment: CachedSegment = playlist.segments[cursor];
      const path: string = AdBlockService.cachePath(segment.url);
      if (!AdBlockService.fileExists(path)) {
        try {
          const fetched: ProxyResponse = await AdBlockService.fetchBinary(segment.url);
          if (fetched.code < 200 || fetched.code >= 300 || fetched.bytes.byteLength === 0) {
            break;
          }
          AdBlockService.saveCache(segment.url, fetched.bytes);
        } catch (error) {
          Logger.warn('AD_BLOCK', '暂停预取分片失败：' + String(error));
          break;
        }
      }
      cachedMs += segment.durationMs;
      AppStorage.setOrCreate<number>('hlsCacheMs', Math.round(cachedMs));
    }
    if (token === AdBlockService.prefetchToken) {
      AdBlockService.prefetching = false;
      AppStorage.setOrCreate<boolean>('hlsCacheActive', false);
      Logger.info('AD_BLOCK', '暂停预取结束，已缓存到 ' + String(Math.round(cachedMs / 1000)) + 's');
    }
  }

  private static shortUrl(url: string): string {
    const clean: string = url.split('#')[0];
    return clean.length > 120 ? clean.substring(0, 117) + '...' : clean;
  }
}

/** 本地代理返回的原始响应。 */
class ProxyResponse {
  code: number = 0;
  contentType: string = '';
  contentRange: string = '';
  location: string = '';
  text: string = '';
  bytes: ArrayBuffer = new ArrayBuffer(0);
}

/** 播放列表改写统计。 */
class PlaylistResult {
  text: string = '';
  kept: number = 0;
  removed: number = 0;
  master: boolean = false;
  live: boolean = false;
  segments: CachedSegment[] = [];
  totalMs: number = 0;
}

/** 播放列表中的一个分片（用于暂停预取与缓存进度）。 */
class CachedSegment {
  url: string = '';
  durationMs: number = 0;
}

/** 会话内播放列表缓存：断网时仍可回放已缓存分片。 */
class CachedPlaylist {
  key: string = '';
  master: boolean = false;
  live: boolean = false;
  text: string = '';
  segments: CachedSegment[] = [];
  totalMs: number = 0;
}

class CacheFileInfo {
  name: string = '';
  size: number = 0;
  mtime: number = 0;
}

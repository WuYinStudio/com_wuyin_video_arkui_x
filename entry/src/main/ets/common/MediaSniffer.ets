import { http } from '@kit.NetworkKit';
import { ApiRequestOptions } from './CommunityApi';
import { Logger } from './Logger';

/** 嗅探结果：解析出的直链 + 是否来自页面嗅探。 */
export class SniffResult {
  url: string = '';
  sniffed: boolean = false;
}

/**
 * 媒体地址嗅探：把"网页地址 / 短链 / 分享链接"解析成 AVPlayer、Video 能直接播的直链。
 *
 * 设计成独立服务，供 PlayerPage 与聊天室（视频/音乐消息）共用同一套逻辑：
 * 1. 已经是媒体直链（.mp4/.m3u8/.mp3/.m4a…）→ 原样返回；
 * 2. 否则按 GET 拉取页面 HTML，用正则挑出第一个可信的媒体地址；
 * 3. 支持 JSON 型接口（部分站点返回 {"url":"..."}）。
 *
 * 只做"尽力而为"的通用嗅探；站点私有鉴权（Referer/UA/token）需要在调用方追加请求头。
 */
export class MediaSniffer {
  private static readonly MEDIA_PATTERN: RegExp =
    /https?:\/\/[^\s<>()']+?\.(?:mp4|m4v|m3u8|mp3|m4a|aac|flac|wav|ogg|webm)(?:\?[^\s<>()']*)?/i;

  private static readonly JSON_URL_PATTERN: RegExp = /url\s*:\s*"([^"]+)"/i;

  private static readonly DIRECT_PATTERN: RegExp = /\.(mp4|m4v|m3u8|mp3|m4a|aac|flac|wav|ogg|webm)(\?|#|$)/i;

  /** 判断是否已经是可直接播放的媒体直链。 */
  static isDirectMedia(url: string): boolean {
    const value: string = (url || '').trim();
    if (value.length === 0) { return false; }
    return MediaSniffer.DIRECT_PATTERN.test(value);
  }

  static isPage(url: string): boolean {
    const value: string = (url || '').trim();
    return /^https?:\/\//i.test(value) && !MediaSniffer.isDirectMedia(value);
  }

  /**
   * 解析播放地址：直链直接返回；页面地址尝试嗅探。
   * 嗅探失败时回退原始地址（调用方按播放失败处理），不会抛异常中断流程。
   */
  static async resolve(source: string, referer: string = ''): Promise<SniffResult> {
    const result: SniffResult = new SniffResult();
    const value: string = (source || '').trim();
    result.url = value;
    if (value.length === 0) { return result; }
    if (!MediaSniffer.isPage(value)) { return result; }
    try {
      const platform: string = MediaSniffer.platformOf(value);
      // 网易云：song?id=N → 官方 outer 直链（302 到 mp3），无需签名。
      if (platform === 'music' && value.indexOf('music.163.com') >= 0) {
        const songId: RegExpMatchArray | null = value.match(/id=(\d+)/);
        if (songId !== null && songId.length > 1) {
          result.url = 'https://music.163.com/song/media/outer/url?id=' + songId[1] + '.mp3';
          result.sniffed = true;
          Logger.info('MEDIA_SNIFF', '网易云直链：' + result.url);
          return result;
        }
      }
      if (platform === 'bilibili') {
        const direct: string = await MediaSniffer.bilibili(value);
        if (direct.length > 0) {
          result.url = direct;
          result.sniffed = true;
          return result;
        }
      }
      const html: string = await MediaSniffer.fetchText(value, referer);
      const found: string = MediaSniffer.pick(html, value);
      if (found.length > 0) {
        result.url = found;
        result.sniffed = true;
        Logger.info('MEDIA_SNIFF', '嗅探成功：' + value + ' → ' + found);
      } else {
        Logger.warn('MEDIA_SNIFF', '页面内未找到媒体直链：' + value);
      }
    } catch (error) {
      Logger.warn('MEDIA_SNIFF', '嗅探失败：' + String(error));
    }
    return result;
  }

  /** 从 HTML / JSON 文本里挑第一个媒体地址，并补全相对路径。 */
  static pick(content: string, baseUrl: string): string {
    const text: string = content || '';
    if (text.length === 0) { return ''; }
    const jsonMatch: RegExpMatchArray | null = text.match(MediaSniffer.JSON_URL_PATTERN);
    if (jsonMatch !== null && jsonMatch.length > 1) {
      const candidate: string = MediaSniffer.normalize(jsonMatch[1], baseUrl);
      if (MediaSniffer.isDirectMedia(candidate)) { return candidate; }
    }
    const match: RegExpMatchArray | null = text.match(MediaSniffer.MEDIA_PATTERN);
    if (match !== null && match.length > 0) {
      return MediaSniffer.normalize(match[0], baseUrl);
    }
    return '';
  }

  /** 相对路径补全（//cdn… / /path… / path…）。 */
  private static normalize(candidate: string, baseUrl: string): string {
    let value: string = (candidate || '').trim();
    if (value.startsWith('//')) { return 'https:' + value; }
    if (value.startsWith('/')) {
      const host: string = MediaSniffer.hostOf(baseUrl);
      return host + value;
    }
    if (!/^https?:\/\//i.test(value)) {
      const host: string = MediaSniffer.hostOf(baseUrl);
      return host + '/' + value;
    }
    return value;
  }

  private static hostOf(url: string): string {
    const match: RegExpMatchArray | null = url.match(/^https?:\/\/[^\/]+/i);
    return match !== null ? match[0] : '';
  }

  private static async fetchText(url: string, referer: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: ApiRequestOptions = new ApiRequestOptions();
      const response: http.HttpResponse = await request.request(url, options);
      const body: string = String(response.result);
      if (referer.length > 0) {
        Logger.info('MEDIA_SNIFF', '带 Referer 嗅探：' + referer);
      }
      return body;
    } finally {
      request.destroy();
    }
  }

  /** 平台识别：bilibili / douyin / kuaishou / music / other。 */
  static platformOf(url: string): string {
    const value: string = (url || '').toLowerCase();
    if (value.indexOf('bilibili.com') >= 0 || value.indexOf('b23.tv') >= 0) { return 'bilibili'; }
    if (value.indexOf('douyin.com') >= 0 || value.indexOf('iesdouyin.com') >= 0) { return 'douyin'; }
    if (value.indexOf('kuaishou.com') >= 0 || value.indexOf('gifshow.com') >= 0) { return 'kuaishou'; }
    if (value.indexOf('music.163.com') >= 0 || value.indexOf('y.qq.com') >= 0) { return 'music'; }
    return 'other';
  }

  /**
   * B 站本地解析：bvid → view 接口拿 cid → playurl 拿直链（免登录 480P）。
   * 需要带 Referer，否则 403；纯本地算，不依赖第三方服务。
   */
  static async bilibili(source: string): Promise<string> {
    const bvid: string = MediaSniffer.bvidOf(source);
    if (bvid.length === 0) { return ''; }
    try {
      const viewText: string = await MediaSniffer.fetchText('https://api.bilibili.com/x/web-interface/view?bvid=' + bvid,
        'https://www.bilibili.com');
      const viewJson: Record<string, string>[] = JSON.parse(viewText) as Record<string, string>[];
      const data: Record<string, string> | undefined = viewJson['data'] as Record<string, string> | undefined;
      if (data === undefined) { return ''; }
      const cid: string = String(data['cid'] !== undefined ? data['cid'] : '');
      if (cid.length === 0) { return ''; }
      const playText: string = await MediaSniffer.fetchText(
        'https://api.bilibili.com/x/player/playurl?bvid=' + bvid + '&cid=' + cid + '&qn=64&fnval=16',
        'https://www.bilibili.com');
      const matched: RegExpMatchArray | null = playText.match(/https?:\/\/[^"]+\.(?:m4s|mp4|m3u8)[^"]*/i);
      if (matched !== null && matched.length > 0) {
        Logger.info('MEDIA_SNIFF', 'B站解析成功：' + bvid);
        return matched[0].replace(/\\u0026/g, '&');
      }
      return '';
    } catch (error) {
      Logger.warn('MEDIA_SNIFF', 'B站解析失败：' + String(error));
      return '';
    }
  }

  private static bvidOf(url: string): string {
    const matched: RegExpMatchArray | null = url.match(/BV[0-9A-Za-z]{10}/);
    return matched !== null && matched.length > 0 ? matched[0] : '';
  }
}

import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppState } from './AppState';
import { Logger } from './Logger';

/**
 * DNS 解析策略：部分资源站域名会被运营商 DNS 污染，改用 DoH 加密解析可绕过。
 *
 * 四种模式：
 * - follow ：跟随配置（系统默认，不干预）；
 * - off    ：关闭（强制系统 DNS）；
 * - aliyun ：阿里云 DoH；
 * - tencent：腾讯 DoH。
 *
 * 只影响应用自身的网络请求（搜索源、直播源、网盘接口等），不改系统 DNS。
 */
export class DnsMode {
  static readonly FOLLOW: string = 'follow';
  static readonly OFF: string = 'off';
  static readonly ALIYUN: string = 'aliyun';
  static readonly TENCENT: string = 'tencent';
}

export class DnsService {
  private static mode: string = DnsMode.FOLLOW;
  private static loaded: boolean = false;
  private static prefs?: preferences.Preferences;

  static async init(context?: common.UIAbilityContext): Promise<void> {
    if (DnsService.loaded) { return; }
    try {
      const ctx: common.UIAbilityContext | undefined = context ?? AppState.context;
      if (!ctx) { DnsService.loaded = true; return; }
      DnsService.prefs = await preferences.getPreferences(ctx, 'wuyin-dns');
      DnsService.mode = String(await DnsService.prefs.get('mode', DnsMode.FOLLOW)).trim();
      DnsService.loaded = true;
      Logger.info('DNS', 'DNS 解析模式：' + DnsService.mode);
    } catch (error) {
      DnsService.loaded = true;
      Logger.warn('DNS', '读取 DNS 配置失败：' + String(error));
    }
  }

  static current(): string {
    return DnsService.mode;
  }

  static async setMode(mode: string): Promise<void> {
    await DnsService.init();
    const target: string = DnsService.sanitize(mode);
    const previous: string = DnsService.mode;
    DnsService.mode = target;
    try {
      if (!DnsService.prefs && AppState.context) {
        DnsService.prefs = await preferences.getPreferences(AppState.context, 'wuyin-dns');
      }
      if (DnsService.prefs) {
        await DnsService.prefs.put('mode', target);
        await DnsService.prefs.flush();
      }
      Logger.info('DNS', 'DNS 解析模式已切换为：' + target);
    } catch (error) {
      DnsService.mode = previous;
      throw new Error('保存 DNS 设置失败：' + String(error));
    }
  }

  static sanitize(mode: string): string {
    if (mode === DnsMode.OFF || mode === DnsMode.ALIYUN || mode === DnsMode.TENCENT) { return mode; }
    return DnsMode.FOLLOW;
  }

  static label(mode: string): string {
    if (mode === DnsMode.OFF) { return '关闭（系统 DNS）'; }
    if (mode === DnsMode.ALIYUN) { return '阿里云 DoH'; }
    if (mode === DnsMode.TENCENT) { return '腾讯 DoH'; }
    return '跟随配置（当前系统默认）';
  }

  /** 返回需要注入的 DoH 地址；空字符串表示不干预 DNS。 */
  static endpoint(): string {
    if (DnsService.mode === DnsMode.ALIYUN) { return 'https://dns.alidns.com:443/dns-query'; }
    if (DnsService.mode === DnsMode.TENCENT) { return 'https://doh.pub:443/dns-query'; }
    return '';
  }

  /**
   * 实测当前 DNS 配置是否生效：对一个必须联网的地址发请求，返回耗时与结果。
   * 关闭/跟随时走系统 DNS，用于对照。
   */
  static async probe(url: string): Promise<string> {
    const target: string = (url || '').trim().length > 0 ? url : 'https://www.baidu.com/';
    const request = http.createHttp();
    const started: number = Date.now();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 6000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      };
      const doh: string = DnsService.endpoint();
      if (doh.length > 0) { options.dnsOverHttps = doh; }
      const response = await request.request(target, options);
      const cost: number = Date.now() - started;
      const channel: string = doh.length > 0 ? ('DoH ' + doh) : '系统 DNS';
      return '解析成功（' + channel + '，' + String(cost) + 'ms，HTTP ' + String(response.responseCode) + '）';
    } catch (error) {
      const cost: number = Date.now() - started;
      return '解析失败（' + (DnsService.endpoint().length > 0 ? 'DoH' : '系统 DNS') + '，' + String(cost) + 'ms）：' + String(error);
    } finally {
      request.destroy();
    }
  }

  /** 把 DNS 设置合并进 http 请求选项；没开启 DoH 时原样返回。 */
  static apply(options: Record<string, Object>): Record<string, Object> {
    const doh: string = DnsService.endpoint();
    if (doh.length === 0) { return options; }
    const merged: Record<string, Object> = options;
    merged['dnsOverHttps'] = doh;
    return merged;
  }
}


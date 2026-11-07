import common from '@ohos.app.ability.common';
import { common2D, effectKit } from '@kit.ArkGraphics2D';
import { FestivalTheme } from './FestivalTheme';
import { systemShare } from './PlatformShareKit';
import promptAction from '@ohos.promptAction';
import window from '@ohos.window';
import router from '@ohos.router';
import { generateBarcode, scanCore } from './PlatformScanKit';
import pasteboard from '@ohos.pasteboard';
import fs from '@ohos.file.fs';
import { fileUri } from './PlatformFileUri';
import http from '@ohos.net.http';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import image from '@ohos.multimedia.image';
import { SearchVideoItem } from '../pages/PlayerPage';
import { Logger } from './Logger';
import { PlatformBridge } from './PlatformBridge';
import { Ui } from './Ui';

const SHARE_LINK_BASE: string = 'wuyin://player';
// 同一个 ASCII Scheme 包也用于 NFC NDEF，预留 NDEF 记录及长度字段空间。
const MAX_LINK_LENGTH: number = 60000;
const MAX_COVER_BYTES: number = 2 * 1024 * 1024;
const MAX_THUMBNAIL_BYTES: number = 32 * 1024;
// 海报用「设计稿坐标 + 输出倍率」两套尺寸：
// 所有绘制坐标仍按 900x1250 的设计稿写（改版式不用换算），导出时整体放大 1.2 倍成 1080x1500，
// 分享出去的图片分辨率更高，文字与二维码边缘也更锐利。
const POSTER_WIDTH: number = 900;
const POSTER_HEIGHT: number = 1250;
const POSTER_QR_SIZE: number = 600;
const POSTER_SCALE: number = 1.2;
const POSTER_OUTPUT_WIDTH: number = 1080;
const POSTER_OUTPUT_HEIGHT: number = 1500;
// 海报文字整体放大系数：海报会被压缩到手机宽度显示，基础字号必须放大一档。
const POSTER_TEXT_BOOST: number = 1.8;

// 仅允许影视参数进入播放器，不接受外部传入的本地路径或资源类型。
export class SharedPlayerParams {
  yhm: string = '';
  feng: string = '';
  sfeng: string = '';
  data: string = '';
  tilie: string = '';
  wzlj: string = '';
  genxi: string = '';
  zyuanuuu: string = '';
  vodId: string = '';
  sharedEpisodeIndex: number = 0;
  sharedEpisodeTitle: string = '';
  sharedPlayUrl: string = '';
  // 接续进度统一使用秒；仅在播放器调用 seek 时转换为毫秒。
  sharedPlayProgress: number = 0;
  shareChannel: string = 'share';
  fromShare: boolean = true;
}

// 请求序号只存在于本次系统唤起的内存/路由中，不写入分享链接或持久化存储。
export class SharedPlayerRouteParams extends SharedPlayerParams {
  shareRequestId: number = 0;
}

/** 分享海报版式：分享页里可切换，分享时按所选版式合成。 */
export class PosterStyle {
  static readonly CLASSIC: string = 'classic';
  static readonly MINIMAL: string = 'minimal';
  static readonly NEON: string = 'neon';
  static readonly MAGAZINE: string = 'magazine';
  static readonly COVER: string = 'cover';
  static readonly FILM: string = 'film';
  static readonly FESTIVAL: string = 'festival';
  static readonly COLLAGE: string = 'collage';
  static readonly ALL: string[] =
    ['classic', 'minimal', 'neon', 'magazine', 'cover', 'film', 'festival', 'collage'];

  /** 版式的中文名（分享页里的选择胶囊）；节日版式会带上当天节日名。 */
  static label(style: string): string {
    if (style === PosterStyle.MINIMAL) { return '极简'; }
    if (style === PosterStyle.NEON) { return '霓虹'; }
    if (style === PosterStyle.MAGAZINE) { return '杂志'; }
    if (style === PosterStyle.COVER) { return '封面卡'; }
    if (style === PosterStyle.FILM) { return '影幕'; }
    if (style === PosterStyle.COLLAGE) { return '拼贴'; }
    if (style === PosterStyle.FESTIVAL) {
      const theme: FestivalTheme = FestivalTheme.current();
      return theme.id === 'default' ? '节日' : '节日·' + theme.name;
    }
    return '经典';
  }

  /** 是否依赖影片封面（页面要先去下载封面图）。 */
  static needsCover(style: string): boolean {
    return style === PosterStyle.COVER || style === PosterStyle.FILM;
  }

  /** 兜底：未知版式一律按经典处理。 */
  static normalize(style: string): string {
    return PosterStyle.ALL.indexOf(style) >= 0 ? style : PosterStyle.CLASSIC;
  }
}

class ShareResultSnapshot {
  code?: number;
  resultCode?: number;
  status?: number | string;
  message?: string;
  targetBundleName?: string;
}

export class ShareService {
  // 保留控制器直到面板关闭，避免局部对象释放后丢失投递状态回调。
  private static activeController?: systemShare.ShareController;
  private static preparingShare: boolean = false;
  private static pendingPlayerHandoff?: SharedPlayerRouteParams;
  private static playerHandoffSequence: number = 0;
  // NFC 服务保持原接口；生成统一数据包时读取当前播放器，而非新增桌面启动缓存。
  private static playbackProgressReader?: (videoId: string, episodeIndex: number) => number;
  /** 海报底部文案：影视分享为继续播放，线路分享为导入线路。 */
  private static posterFooterValue: string = '扫码即可继续播放本剧集';

  static setPosterFooter(text: string): void {
    ShareService.posterFooterValue = (text || '').trim().length > 0
      ? text.trim() : '扫码即可继续播放本剧集';
  }

  static posterFooter(): string {
    return ShareService.posterFooterValue;
  }

  static setPlaybackProgressReader(reader: (videoId: string, episodeIndex: number) => number): void {
    try { ShareService.playbackProgressReader = reader; }
    catch (_) { Logger.error('SHARE_RESUME', '注册当前播放进度读取器失败'); }
  }

  static clearPlaybackProgressReader(reader: (videoId: string, episodeIndex: number) => number): void {
    try {
      if (ShareService.playbackProgressReader === reader) { ShareService.playbackProgressReader = undefined; }
    } catch (_) { Logger.warn('SHARE_RESUME', '清理当前播放进度读取器失败'); }
  }

  static publishPlayerHandoff(value: SharedPlayerParams): void {
    try {
      // Ability 与 Index 交接时再次校验进度，禁止无效定位值进入既有播放器。
      if (!Number.isInteger(value.sharedEpisodeIndex) || value.sharedEpisodeIndex < 0 ||
        typeof value.sharedPlayProgress !== 'number' || !Number.isFinite(value.sharedPlayProgress) ||
        value.sharedPlayProgress < 0 || value.sharedPlayProgress > Number.MAX_SAFE_INTEGER / 1000) {
        throw new Error('系统接续的分集索引或播放进度无效');
      }
      const route: SharedPlayerRouteParams = new SharedPlayerRouteParams();
      route.yhm = value.yhm;
      route.feng = value.feng;
      route.sfeng = value.sfeng;
      route.data = value.data;
      route.tilie = value.tilie;
      route.wzlj = value.wzlj;
      route.genxi = value.genxi;
      route.zyuanuuu = value.zyuanuuu;
      route.vodId = value.vodId;
      route.sharedEpisodeIndex = value.sharedEpisodeIndex;
      route.sharedEpisodeTitle = value.sharedEpisodeTitle;
      route.sharedPlayUrl = value.sharedPlayUrl;
      route.sharedPlayProgress = value.sharedPlayProgress;
      route.shareChannel = value.shareChannel;
      route.fromShare = true;
      route.shareRequestId = ++ShareService.playerHandoffSequence;
      ShareService.pendingPlayerHandoff = route;
      // Index 即使位于播放器下方也能接收这一内存事件；普通桌面启动不发布事件。
      AppStorage.setOrCreate<number>('playerHandoffVersion', route.shareRequestId);
      Logger.info('SHARE_RESUME', '发布系统接续请求，序号=' + route.shareRequestId +
      '，进度=' + route.sharedPlayProgress + '秒');
    } catch (error) {
      ShareService.pendingPlayerHandoff = undefined;
      Logger.error('SHARE_RESUME', '发布系统接续请求失败，已清空临时参数：' + String(error));
    }
  }

  static takePlayerHandoff(): SharedPlayerRouteParams | undefined {
    try {
      const route: SharedPlayerRouteParams | undefined = ShareService.pendingPlayerHandoff;
      ShareService.pendingPlayerHandoff = undefined;
      if (route) { Logger.info('SHARE_RESUME', 'Index 消费接续请求，序号=' + route.shareRequestId); }
      return route;
    } catch (_) {
      ShareService.pendingPlayerHandoff = undefined;
      Logger.error('SHARE_RESUME', '消费接续请求失败，已清空临时参数');
      return undefined;
    }
  }

  static clearPlayerHandoff(): void {
    try {
      ShareService.pendingPlayerHandoff = undefined;
      // 窗口销毁时同时清理 Index -> PlayerPage 的临时包，避免普通窗口重建误接续。
      // 先删除参数再归零事件版本，监听即使同步触发也无法重新消费已结束的请求。
      AppStorage.delete('playerSharedResumeParams');
      AppStorage.setOrCreate<number>('playerSharedResumeVersion', 0);
      AppStorage.setOrCreate<number>('playerHandoffVersion', 0);
      // 不重置请求序号，避免同一 Ability 生命周期中的新请求与旧异步回调重号。
      Logger.info('SHARE_RESUME', '系统唤起与播放器复用临时参数已清空，不保留桌面启动缓存');
    } catch (error) { Logger.warn('SHARE_RESUME', '清空系统唤起临时参数失败：' + String(error)); }
  }

  private static networkUrl(value: string): boolean {
    try { return /^https?:\/\/[^\s]+$/i.test(value) && !/^https?:\/\/[^/]*@/i.test(value); }
    catch (_) { return false; }
  }

  private static episodeEntries(value: string): string[] {
    try {
      return value.replace(/\t/g, '').trim().replace(/\s{2,}/g, ' ').split('#')
        .map((entry: string): string => entry.trim())
        .filter((entry: string): boolean => {
        const separator: number = entry.indexOf('$');
        return separator > 0 && separator < entry.length - 1 &&
          !!entry.substring(0, separator).trim() && !!entry.substring(separator + 1).trim();
      });
    } catch (_) { return []; }
  }

  static createLink(video: SearchVideoItem, episodeTitle: string, playUrl: string,
    episodeIndex: number = 0, channel: string = 'share', playbackProgress?: number): string {
    try {
      const title: string = (video.tilie || video.yhm || '').trim();
      const target: string = playUrl.trim();
      if (!video.vodId.trim() || !title || title.length > 512 || !episodeTitle.trim() ||
        video.resourceType === 'local' || !!video.localPath || !ShareService.networkUrl(target)) {
        throw new Error('当前资源不是可分享的网络影视链接，本地离线文件不能通过链接传送');
      }
      const reader: ((videoId: string, episodeIndex: number) => number) | undefined = ShareService.playbackProgressReader;
      const progress: number = playbackProgress === undefined ?
        (reader ? reader(video.vodId, episodeIndex) : 0) : playbackProgress;
      if (!Number.isFinite(progress) || progress < 0 || progress > Number.MAX_SAFE_INTEGER / 1000) {
        throw new Error('当前播放进度无效，无法生成接续参数');
      }
      const entries: string[] = ShareService.episodeEntries(video.wzlj);
      if (!Number.isInteger(episodeIndex) || episodeIndex < 0 || episodeIndex >= entries.length) {
        throw new Error('当前分集索引无效，请重新选择剧集');
      }
      const payload: SharedPlayerParams = new SharedPlayerParams();
      payload.yhm = video.yhm || title;
      payload.feng = video.feng || '';
      payload.sfeng = video.sfeng || '';
      payload.data = video.data || '';
      payload.tilie = title;
      payload.genxi = video.genxi || '';
      payload.zyuanuuu = video.zyuanuuu || '';
      payload.vodId = video.vodId;
      payload.sharedEpisodeIndex = episodeIndex;
      payload.sharedEpisodeTitle = episodeTitle.trim().replace(/[#$]/g, ' ');
      payload.sharedPlayUrl = target;
      payload.sharedPlayProgress = progress;
      payload.shareChannel = channel === 'nfc' || channel === 'airdrop' ? channel : 'share';
      entries[episodeIndex] = payload.sharedEpisodeTitle + '$' + target;
      payload.wzlj = entries.join('#');
      // JSON 只序列化一次，查询参数只编码一次；NFC 和 ShareKit 共用此原始 URI。
      const link: string = SHARE_LINK_BASE + '?video=' + encodeURIComponent(JSON.stringify(payload));
      if (link.length > MAX_LINK_LENGTH) { throw new Error('影视参数过长，无法通过分享及 NFC 传送'); }
      Logger.info(payload.shareChannel === 'nfc' ? 'NFC' : payload.shareChannel === 'airdrop' ? 'AIRDROP' : 'SHARE',
        '已生成统一 Scheme 数据包，集数=' + (episodeIndex + 1) + '，接续进度=' + progress +
      '秒，字符数=' + link.length);
      return link;
    } catch (error) {
      Logger.error('SHARE', '打包分享参数失败');
      const caught: Error = error as Error;
      throw new Error(caught.message || '打包分享参数失败');
    }
  }

  /**
   * 解析分享载体，四种都支持：
   * 1. 新版精简链接 wuyin://play?v=1&id=..&t=..&et=..&u=..（二维码用，字符最少）；
   * 2. 旧版 wuyin://player?video=<URL 编码 JSON>；
   * 3. 纯 JSON；
   * 4. 更早的 wuyinvideo://play?...。
   */
  static parseLink(uri: string): SharedPlayerParams | undefined {
    const text: string = (uri || '').trim();
    if (text.length === 0 || text.length > MAX_LINK_LENGTH) {
      Logger.error('SCHEME', '分享内容为空或超长，长度=' + String(text.length));
      return undefined;
    }
    try {
      if (text.startsWith('{')) {
        return ShareService.validatePayload(JSON.parse(text) as SharedPlayerParams);
      }
      if (/^wuyin:\/\/player\/?\?/i.test(text) || /^wuyin:\/\/play\/?\?/i.test(text)) {
        const query: string = text.substring(text.indexOf('?') + 1);
        if (/(^|&)v=1(&|$)/.test(query)) {
          const compact: SharedPlayerParams | undefined = ShareService.parseCompactQuery(query);
          if (compact !== undefined) { return compact; }
        }
        if (query.indexOf('video=') >= 0) {
          const legacy: SharedPlayerParams | undefined = ShareService.parseVideoParam(query);
          if (legacy !== undefined) { return legacy; }
        }
        return ShareService.parseCompactQuery(query);
      }
      if (/^wuyinvideo:\/\/play/i.test(text)) {
        const index: number = text.indexOf('?');
        return ShareService.parseCompactQuery(index >= 0 ? text.substring(index + 1) : '');
      }
      Logger.error('SCHEME', '不认识的分享载体，前 40 字符=' + text.substring(0, 40));
      return undefined;
    } catch (error) {
      Logger.error('SCHEME', '分享载体解析异常：' + String(error));
      return undefined;
    }
  }

  /** 旧版：?video=<encodeURIComponent(JSON)>。 */
  private static parseVideoParam(query: string): SharedPlayerParams | undefined {
    try {
      let raw: string = '';
      let found: boolean = false;
      for (const pair of query.split('&')) {
        const separator: number = pair.indexOf('=');
        if (separator < 0 || pair.substring(0, separator) !== 'video') { continue; }
        if (found) { throw new Error('影视参数重复'); }
        found = true;
        raw = decodeURIComponent(pair.substring(separator + 1).replace(/\+/g, '%20'));
      }
      if (!raw) { throw new Error('缺少影视参数'); }
      return ShareService.validatePayload(JSON.parse(raw) as SharedPlayerParams);
    } catch (error) {
      Logger.error('SCHEME', '旧版 Scheme 参数解析失败：' + String(error));
      return undefined;
    }
  }

  /** 新版：?v=1&id=&t=&et=&u=&e=&p= 逐个字段取，长度比 JSON 短很多，二维码更容易扫。 */
  private static parseCompactQuery(query: string): SharedPlayerParams | undefined {
    try {
      const fields: Record<string, string> = {};
      for (const pair of query.split('&')) {
        const separator: number = pair.indexOf('=');
        if (separator <= 0) { continue; }
        fields[pair.substring(0, separator)] = decodeURIComponent(pair.substring(separator + 1).replace(/\+/g, '%20'));
      }
      const vodId: string = fields['id'] !== undefined ? fields['id'] : '';
      const playUrl: string = fields['u'] !== undefined ? fields['u'] : '';
      if (vodId.trim().length === 0 || !ShareService.networkUrl(playUrl.trim())) {
        throw new Error('精简链接缺少影片标识或播放地址');
      }
      const payload: SharedPlayerParams = new SharedPlayerParams();
      const title: string = (fields['t'] !== undefined ? fields['t'] : '').trim();
      payload.tilie = (title.length > 0 ? title : '无音影视分享').substring(0, 120);
      payload.yhm = payload.tilie;
      payload.feng = fields['f'] !== undefined && ShareService.networkUrl(fields['f']) ? fields['f'] : '';
      payload.sfeng = '';
      payload.data = '';
      payload.genxi = '';
      payload.zyuanuuu = '';
      payload.vodId = vodId.trim();
      payload.sharedEpisodeIndex = 0;
      const episodeTitle: string = (fields['et'] !== undefined ? fields['et'] : '').trim();
      payload.sharedEpisodeTitle = (episodeTitle.length > 0 ? episodeTitle : '正片').replace(/[#$]/g, ' ').substring(0, 80);
      payload.sharedPlayUrl = playUrl.trim();
      const progress: number = Number(fields['p'] !== undefined ? fields['p'] : '0');
      payload.sharedPlayProgress = Number.isFinite(progress) && progress > 0 ? Math.floor(progress) : 0;
      payload.shareChannel = 'share';
      // 单集直接用「标题$地址」重建，播放地址里带 # 也不会把选集拆散。
      payload.wzlj = payload.sharedEpisodeTitle + '$' + payload.sharedPlayUrl;
      return ShareService.validatePayload(payload);
    } catch (error) {
      Logger.error('SCHEME', '精简链接解析失败：' + String(error));
      return undefined;
    }
  }

  /** 统一校验：字段类型、长度、播放地址白名单、集数索引。 */
  private static validatePayload(value: SharedPlayerParams): SharedPlayerParams | undefined {
    try {
      if (!value || typeof value.vodId !== 'string' || !value.vodId.trim() ||
        typeof value.tilie !== 'string' || !value.tilie.trim() || value.tilie.length > 512 ||
        typeof value.yhm !== 'string' || typeof value.feng !== 'string' ||
        typeof value.sfeng !== 'string' || typeof value.data !== 'string' ||
        typeof value.genxi !== 'string' || typeof value.zyuanuuu !== 'string' ||
        typeof value.wzlj !== 'string' || typeof value.sharedEpisodeTitle !== 'string' ||
        !value.sharedEpisodeTitle.trim() || typeof value.sharedPlayUrl !== 'string' ||
        !ShareService.networkUrl(value.sharedPlayUrl) || !Number.isInteger(value.sharedEpisodeIndex)) {
        throw new Error('影视参数类型或播放地址无效');
      }
      // 兼容旧版分享链接；新链接必须携带有限且非负的秒数，不接收字符串或负数。
      const playbackProgress: number = value.sharedPlayProgress === undefined ? 0 : value.sharedPlayProgress;
      if (typeof playbackProgress !== 'number' || !Number.isFinite(playbackProgress) ||
        playbackProgress < 0 || playbackProgress > Number.MAX_SAFE_INTEGER / 1000) {
        throw new Error('分享播放进度无效');
      }
      let entries: string[] = ShareService.episodeEntries(value.wzlj);
      if (entries.length === 0 || value.sharedEpisodeIndex < 0 || value.sharedEpisodeIndex >= entries.length) {
        // 播放地址里带 # 时，选集串会被 # 拆散导致索引越界：用单集字段重建一条，保证仍能直接播。
        entries = [value.sharedEpisodeTitle.replace(/[#$]/g, ' ') + '$' + value.sharedPlayUrl.trim()];
        value.sharedEpisodeIndex = 0;
        Logger.warn('SCHEME', '选集串被拆散，已按单集字段重建');
      }
      // 重建白名单对象，不把外部 JSON 的本地路径、资源类型或其他额外字段传给播放器。
      const result: SharedPlayerParams = new SharedPlayerParams();
      result.yhm = value.yhm;
      result.feng = value.feng;
      result.sfeng = value.sfeng;
      result.data = value.data;
      result.tilie = value.tilie;
      result.genxi = value.genxi;
      result.zyuanuuu = value.zyuanuuu;
      result.vodId = value.vodId;
      result.sharedEpisodeIndex = value.sharedEpisodeIndex;
      result.sharedEpisodeTitle = value.sharedEpisodeTitle.replace(/[#$]/g, ' ');
      result.sharedPlayUrl = value.sharedPlayUrl.trim();
      result.sharedPlayProgress = playbackProgress;
      result.shareChannel = value.shareChannel === 'nfc' || value.shareChannel === 'airdrop' ? value.shareChannel : 'share';
      entries[result.sharedEpisodeIndex] = result.sharedEpisodeTitle + '$' + result.sharedPlayUrl;
      for (const entry of entries) {
        if (!ShareService.networkUrl(entry.substring(entry.indexOf('$') + 1).trim())) {
          throw new Error('分享选集包含非网络资源');
        }
      }
      result.wzlj = entries.join('#');
      Logger.info('SCHEME', '分享参数校验通过，来源=' + result.shareChannel + '，集数=' +
      (result.sharedEpisodeIndex + 1) + '，接续进度=' + result.sharedPlayProgress + '秒');
      return result;
    } catch (error) {
      Logger.error('SCHEME', '分享参数校验失败：' + String(error));
      return undefined;
    }
  }

  private static async compressThumbnail(bytes: Uint8Array): Promise<Uint8Array | undefined> {
    let source: image.ImageSource | undefined;
    let bitmap: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    try {
      source = image.createImageSource(new Uint8Array(bytes).buffer);
      packer = image.createImagePacker();
      for (const span of [192, 96]) {
        bitmap = await source.createPixelMap({ desiredSize: { width: span, height: span } });
        const packed: ArrayBuffer = await packer.packing(bitmap, { format: 'image/jpeg', quality: 65 });
        await bitmap.release();
        bitmap = undefined;
        if (packed.byteLength > 0 && packed.byteLength <= MAX_THUMBNAIL_BYTES) {
          return new Uint8Array(packed);
        }
      }
      throw new Error('缩略图仍超过预览大小限制');
    } catch (_) {
      Logger.warn('SHARE', '封面解码或压缩失败');
      return undefined;
    } finally {
      try { if (bitmap) { await bitmap.release(); } }
      catch (_) { Logger.warn('SHARE', '释放封面位图失败'); }
      try { if (packer) { await packer.release(); } }
      catch (_) { Logger.warn('SHARE', '释放封面编码器失败'); }
      try { if (source) { await source.release(); } }
      catch (_) { Logger.warn('SHARE', '释放封面图片源失败'); }
    }
  }

  private static async coverThumbnail(context: common.UIAbilityContext, cover: string): Promise<Uint8Array | undefined> {
    let request: http.HttpRequest | undefined;
    try {
      if (ShareService.networkUrl(cover)) {
        request = http.createHttp();
        const result: http.HttpResponse = await request.request(cover, {
          method: http.RequestMethod.GET,
            expectDataType: http.HttpDataType.ARRAY_BUFFER,
            connectTimeout: 4000,
            readTimeout: 4000,
            maxLimit: MAX_COVER_BYTES
        });
        if (result.responseCode !== 200) { throw new Error('封面请求未成功'); }
        const bytes: Uint8Array = new Uint8Array(result.result as ArrayBuffer);
        if (bytes.byteLength === 0 || bytes.byteLength > MAX_COVER_BYTES) { throw new Error('封面数据大小无效'); }
        const thumbnail: Uint8Array | undefined = await ShareService.compressThumbnail(bytes);
        if (thumbnail) { return thumbnail; }
      }
    } catch (_) {
      Logger.warn('SHARE', '影视封面不可用，使用应用图标作为预览封面');
    } finally {
      try { if (request) { request.destroy(); } }
      catch (_) { Logger.warn('SHARE', '释放封面请求失败'); }
    }
    try {
      const fallback: Uint8Array = await context.resourceManager.getMediaContent($r('app.media.icon').id);
      return await ShareService.compressThumbnail(fallback);
    } catch (_) {
      Logger.warn('SHARE', '备用封面不可用，保留标题及提示文字');
      return undefined;
    }
  }

  // 系统不提供对远端设备安装状态的查询，必须在发送前提示，而不是假装已检测到远端安装。
  /**
   * 发送前确认：取消 / 分享二维码 / 继续发送。
   * 返回具体动作，调用方据此决定是否投递或打开二维码面板。
   */
  static async confirmReceiver(link: string, channel: string = 'share'): Promise<string> {
    const logTag: string = channel === 'nfc' ? 'NFC' : channel === 'airdrop' ? 'AIRDROP' : 'SHARE';
    try {
      const result: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '接收端需安装无音影视',
        message: '已安装应用的接收设备可打开 wuyin://player，自动播放本次分享的剧集。可生成二维码让对方扫码，或先复制影视参数，安装应用后再打开链接。',
        buttons: [
          { text: '取消', color: '#999999' },
          { text: '分享二维码', color: '#E5484D' },
          { text: '继续发送', color: '#E5484D' }
        ]
      });
      if (result.index === 1) {
        Logger.info(logTag, '用户选择生成分享二维码');
        return 'qr';
      }
      if (result.index !== 2) {
        Logger.info(logTag, '用户取消发送');
        return 'cancel';
      }
      Logger.info(logTag, '发送前安装提示已确认');
      return 'send';
    } catch (_) {
      Logger.error(logTag, '显示发送前提示失败，已停止发送');
      return 'cancel';
    }
  }

  /**
   * 打开「分享二维码」页面：先让用户看到海报（二维码 + logo + 文案），
   * 再决定「分享给好友 / 复制链接」，替代原来选完就静默拉起系统面板的行为。
   */
  static openQrPage(context: common.UIAbilityContext, link: string, title: string = '',
    subtitle: string = '', qrLink: string = '', cover: string = ''): void {
    const params: Record<string, string> = {
      'link': link,
      'title': title,
      'subtitle': subtitle,
      'qrLink': qrLink,
      'cover': cover
    };
    const options: router.RouterOptions = { url: 'pages/ShareQrPage', params: params };
    try {
      Logger.info('SHARE', '打开分享二维码页面，标题=' + title + '，链接长度=' + String(link.length));
      // 服务里没有组件上下文，取当前窗口的 UIContext 路由，避免全局 router 的上下文歧义。
      window.getLastWindow(context).then((active: window.Window) => {
        active.getUIContext().getRouter().pushUrl(options).catch((error: BusinessError) => {
          Logger.error('SHARE', '打开分享二维码页面失败：code=' + String(error.code) + '，message=' + String(error.message));
          promptAction.showToast({ message: '打开分享二维码页面失败', duration: 2000 });
        });
      }).catch((error: BusinessError) => {
        Logger.error('SHARE', '取当前窗口失败，改用全局路由：' + String(error));
        router.pushUrl(options).catch((caught: BusinessError) => {
          Logger.error('SHARE', '全局路由打开分享二维码页面也失败：' + String(caught));
        });
      });
    } catch (error) {
      Logger.error('SHARE', '打开分享二维码页面异常：' + String(error));
    }
  }

  /** 生成分享图：优先海报，海报不可用时退回纯二维码；两者都失败返回 undefined。 */
  static async buildPosterOrQr(context: common.UIAbilityContext, link: string, title: string = '',
    subtitle: string = '', qrLink: string = '',
    qrPixels: image.PixelMap | undefined = undefined,
    style: string = PosterStyle.CLASSIC,
    cover: image.PixelMap | undefined = undefined): Promise<image.PixelMap | undefined> {
    const poster: image.PixelMap | undefined =
      await ShareService.buildSharePoster(context, link, title, subtitle, qrLink, qrPixels, style, cover);
    if (poster !== undefined) { return poster; }
    Logger.warn('SHARE', '海报合成不可用，退回纯二维码图片');
    const fallback: image.PixelMap | undefined =
      await ShareService.buildQrImage(link, qrLink, AppStorage.get<boolean>('darkTheme') !== false);
    if (fallback === undefined && ShareService.lastPosterFailure.length === 0) {
      ShareService.lastPosterFailure = '二维码生成失败';
    }
    return fallback;
  }

  /** 最近一次海报/二维码失败原因：分享页会直接展示，便于真机定位。 */
  static lastPosterFailure: string = '';

  /**
   * 二维码载荷：优先用精简链接；没有精简链接时从完整链接压缩出本集最小参数；
   * 最后才退回原链接（完整链接通常超出二维码容量）。
   */
  static shareQrContent(qrLink: string, link: string): string {
    const compact: string = (qrLink || '').trim();
    if (compact.length > 0) { return compact; }
    const shrunk: string = ShareService.shrinkLink(link);
    return shrunk.length > 0 ? shrunk : (link || '').trim();
  }

  /** 从完整分享链接重建只带本集最少字段的精简链接（二维码容量兜底）。 */
  private static shrinkLink(link: string): string {
    try {
      const params: SharedPlayerParams | undefined = ShareService.parseLink((link || '').trim());
      if (params === undefined) { return ''; }
      const payload: SharedPlayerParams = new SharedPlayerParams();
      payload.yhm = params.yhm.substring(0, 60);
      payload.tilie = params.tilie.substring(0, 60);
      payload.feng = '';
      payload.sfeng = '';
      payload.data = '';
      payload.genxi = '';
      payload.zyuanuuu = '';
      payload.vodId = params.vodId;
      payload.sharedEpisodeIndex = 0;
      payload.sharedEpisodeTitle = params.sharedEpisodeTitle.substring(0, 60);
      payload.sharedPlayUrl = params.sharedPlayUrl;
      payload.sharedPlayProgress = params.sharedPlayProgress;
      payload.shareChannel = 'share';
      payload.wzlj = payload.sharedEpisodeTitle + '$' + payload.sharedPlayUrl;
      return SHARE_LINK_BASE + '?video=' + encodeURIComponent(JSON.stringify(payload));
    } catch (error) {
      Logger.warn('SHARE', '压缩分享链接失败：' + String(error));
      return '';
    }
  }

  /** 二维码码点/底色（#RRGGBB）：分享页里的 QRCode 组件复用同一套主题配色。 */
  static qrModuleHex(dark: boolean): string {
    return ShareService.hexFromColor(ShareService.qrModuleColor(dark));
  }

  static qrBackHex(dark: boolean): string {
    return ShareService.hexFromColor(ShareService.qrBackColor(dark));
  }

  /** common2D.Color → #RRGGBB。 */
  private static hexFromColor(color: common2D.Color): string {
    const toHex: (value: number) => string = (value: number): string => {
      const text: string = Math.max(0, Math.min(255, Math.round(value))).toString(16);
      return text.length < 2 ? '0' + text : text;
    };
    return '#' + toHex(color.red) + toHex(color.green) + toHex(color.blue);
  }

  /** 最近一次分享失败原因：分享页会直接展示，便于真机定位。 */
  static lastShareFailure: string = '';

  /**
   * 把分享图交给系统分享面板；返回是否成功唤起。
   * 关键点：ShareKit 只接受应用沙箱的文件 Uri（fileUri.getUriFromPath），
   * 手拼的 "file:///data/..." 会被判为非法 Uri，面板根本不会弹出。
   */
  static async sharePixels(context: common.UIAbilityContext, pixels: image.PixelMap,
    title: string = ''): Promise<boolean> {
    ShareService.lastShareFailure = '';
    const path: string = await ShareService.saveShareImage(context, pixels, title);
    if (path.length === 0) {
      ShareService.lastShareFailure = '分享图片保存失败，可改用「复制链接」';
      return false;
    }
    let uri: string = '';
    try {
      uri = fileUri.getUriFromPath(path);
    } catch (error) {
      Logger.warn('SHARE', '生成分享文件 Uri 失败，退回原始路径：' + String(error));
      uri = 'file://' + path;
    }
    Logger.info('SHARE', '准备分享图片，路径=' + path + '，Uri=' + uri);
    // DETAIL / DEFAULT 两种预览模式各试一次：部分机型在 DETAIL 下会直接抛错。
    const modes: systemShare.SharePreviewMode[] =
      [systemShare.SharePreviewMode.DETAIL, systemShare.SharePreviewMode.DEFAULT];
    let reason: string = '';
    for (const mode of modes) {
      try {
        const data: systemShare.SharedData = new systemShare.SharedData({
          utd: 'image/png',
          uri: uri
        });
        const controller: systemShare.ShareController = new systemShare.ShareController(data);
        await controller.show(context, {
          previewMode: mode,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
        Logger.info('SHARE', '分享图已交给系统分享面板，预览模式=' + String(mode));
        return true;
      } catch (error) {
        reason = String(error);
        Logger.warn('SHARE', '唤起系统分享失败（预览模式=' + String(mode) + '）：' + reason);
      }
    }
    ShareService.lastShareFailure = '没能唤起系统分享：' + reason;
    return false;
  }

  /** 复制分享链接（分享页兜底用）。 */
  static async copyShareLink(link: string): Promise<void> {
    await ShareService.copyLink(link, 'SHARE_PAGE');
  }

  /**
   * 分享海报并唤起系统分享面板（保留给直接调用方）。
   * 失败时按「纯二维码图 → 超链接分享 → 复制参数」逐级兜底。
   */
  static async shareQrImage(context: common.UIAbilityContext, link: string,
    title: string = '', subtitle: string = '', qrLink: string = ''): Promise<void> {
    try {
      const pixels: image.PixelMap | undefined =
        await ShareService.buildPosterOrQr(context, link, title, subtitle, qrLink);
      if (pixels !== undefined) {
        const shared: boolean = await ShareService.sharePixels(context, pixels, title);
        try { await pixels.release(); } catch (_) { Logger.warn('SHARE', '释放分享图片失败'); }
        if (shared) { return; }
      }
    } catch (error) {
      Logger.warn('SHARE', '生成分享海报失败：' + String(error));
    }
    if (await ShareService.shareHyperlink(context, link, title, subtitle)) {
      Logger.info('SHARE', '海报不可用时已改为超链接分享');
      return;
    }
    await ShareService.showCopyFallback(link, '分享海报与系统分享面板都不可用，可复制参数后发送。');
  }

  /**
   * 保存分享图片到缓存目录并返回文件路径（ShareKit 的 Uri 由调用方用 fileUri 生成）。
   * 文件名用当前影片名称（已过滤文件系统非法字符），方便用户在分享面板/文件管理器里认出来。
   */
  private static async saveShareImage(context: common.UIAbilityContext, pixels: image.PixelMap,
    title: string = ''): Promise<string> {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const buffer: ArrayBuffer = await packer.packing(pixels, { format: 'image/png', quality: 100 });
      const dir: string = context.cacheDir + '/share';
      try { fs.mkdirSync(dir); } catch (_) { /* 已存在 */ }
      const path: string = dir + '/' + ShareService.posterFileName(title);
      const file: fs.File = fs.openSync(path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      Logger.info('SHARE', '分享图片已保存：' + path);
      return path;
    } catch (error) {
      Logger.warn('SHARE', '保存分享图片失败：' + String(error));
      return '';
    } finally {
      try { await packer.release(); } catch (_) { Logger.warn('SHARE', '释放图片编码器失败'); }
    }
  }

  /** 海报文件名：影片名 + .png，过滤掉路径分隔符等非法字符，过长截断，空名回落到默认名。 */
  private static posterFileName(title: string): string {
    let name: string = (title || '').trim();
    // 去掉文件系统不允许的字符（以及换行、零宽字符），避免 openSync 失败。
    name = name.replace(/[\\/:*?"<>|\r\n\t\u0000-\u001f]/g, ' ')
      .replace(/\s+/g, ' ')
      .replace(/^[.\s]+/, '')
      .trim();
    if (name.length > 60) { name = name.substring(0, 60); }
    if (name.length === 0) { name = '无音影视分享'; }
    return name + '.png';
  }

  /** 兜底分享：普通超链接，至少让对方拿到可点开的 Scheme。 */
  private static async shareHyperlink(context: common.UIAbilityContext, link: string,
    title: string, subtitle: string): Promise<boolean> {
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
        content: link,
        title: title.length > 0 ? title : '无音影视分享',
        description: (subtitle.length > 0 ? subtitle + ' · ' : '') + '接收方需安装无音影视'
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(context, { previewMode: systemShare.SharePreviewMode.DEFAULT });
      return true;
    } catch (error) {
      Logger.warn('SHARE', '超链接分享失败：' + String(error));
      return false;
    }
  }

  /**
   * 合成分享海报：用离屏 Canvas（OffscreenCanvas）绘制主题底、居中二维码（中央 无音影视 logo）
   * 与二维码底部「打开无音影视扫一扫」，最后 getPixelMap() 导出成品图。
   *
   * 支持多种海报版式（style 见 PosterStyle），由分享页让用户选择。
   */
  static async buildSharePoster(context: common.UIAbilityContext, link: string, title: string = '',
    subtitle: string = '', qrLink: string = '',
    qrPixels: image.PixelMap | undefined = undefined,
    style: string = PosterStyle.CLASSIC,
    cover: image.PixelMap | undefined = undefined): Promise<image.PixelMap | undefined> {
    let qr: image.PixelMap | undefined = qrPixels;
    let ownsQr: boolean = false;
    try {
      const dark: boolean = AppStorage.get<boolean>('darkTheme') !== false;
      if (qr === undefined) {
        // 页面没能截到 QRCode 组件时，退回 ScanKit 生成。
        qr = await ShareService.buildQrImage(link, qrLink, dark);
        ownsQr = qr !== undefined;
      }
      if (qr === undefined) {
        ShareService.lastPosterFailure = '二维码生成失败（系统扫码组件与 QRCode 截图都不可用）';
        return undefined;
      }
      // 离屏画布按输出尺寸（1080x1500）创建，然后整体 scale 1.2，
      // 之后所有绘制坐标仍按 900x1250 设计稿写，导出即得到高分辨率海报。
      const canvas: OffscreenCanvas = new OffscreenCanvas(POSTER_OUTPUT_WIDTH, POSTER_OUTPUT_HEIGHT);
      const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', new RenderingContextSettings(true));
      ctx.clearRect(0, 0, POSTER_OUTPUT_WIDTH, POSTER_OUTPUT_HEIGHT);
      ctx.scale(POSTER_SCALE, POSTER_SCALE);
      if (style === PosterStyle.MINIMAL) {
        await ShareService.paintMinimalPoster(ctx, context, dark, title, subtitle, qr);
      } else if (style === PosterStyle.NEON) {
        await ShareService.paintNeonPoster(ctx, context, dark, title, subtitle, qr);
      } else if (style === PosterStyle.MAGAZINE) {
        await ShareService.paintMagazinePoster(ctx, context, dark, title, subtitle, qr);
      } else if (style === PosterStyle.COVER) {
        await ShareService.paintCoverPoster(ctx, context, dark, title, subtitle, qr, cover);
      } else if (style === PosterStyle.FILM) {
        await ShareService.paintFilmPoster(ctx, context, dark, title, subtitle, qr, cover);
      } else if (style === PosterStyle.FESTIVAL) {
        await ShareService.paintFestivalPoster(ctx, context, title, subtitle, qr);
      } else if (style === PosterStyle.COLLAGE) {
        await ShareService.paintCollagePoster(ctx, context, dark, title, subtitle, qr);
      } else {
        await ShareService.paintClassicPoster(ctx, context, dark, title, subtitle, qr);
      }
      // 直接导出像素图，交给分享面板或相册；toDataURL() 同样可用（返回 base64 PNG）。
      const poster: image.PixelMap = ctx.getPixelMap(0, 0, POSTER_OUTPUT_WIDTH, POSTER_OUTPUT_HEIGHT);
      ShareService.lastPosterFailure = '';
      Logger.info('SHARE', '离屏 Canvas 海报合成完成，版式=' + style + '，尺寸=' +
        String(POSTER_OUTPUT_WIDTH) + 'x' + String(POSTER_OUTPUT_HEIGHT) +
        '，主题=' + (dark ? 'dark' : 'light') + '，二维码来源=' + (ownsQr ? 'ScanKit' : '页面 QRCode 截图'));
      return poster;
    } catch (error) {
      ShareService.lastPosterFailure = '海报合成失败：' + String(error);
      Logger.warn('SHARE', '离屏 Canvas 合成分享海报失败：' + String(error));
      return undefined;
    } finally {
      // 只释放自己创建的二维码位图；页面截图的那张由页面负责释放。
      if (ownsQr && qr !== undefined) {
        try { await qr.release(); } catch (_) { Logger.warn('SHARE', '释放二维码位图失败'); }
      }
    }
  }

  /**
   * 线路分享海报：多张二维码按 2 列网格排列，支持当前主题壁纸作为背景。
   * 最多 6 张，配合 SourceShareCodec 的分片编码。
   */
  static async buildMultiQrPoster(context: common.UIAbilityContext, title: string, subtitle: string,
    qrPixels: image.PixelMap[], cover: image.PixelMap | undefined): Promise<image.PixelMap | undefined> {
    if (qrPixels.length === 0) {
      ShareService.lastPosterFailure = '没有可用的二维码';
      return undefined;
    }
    try {
      const dark: boolean = AppStorage.get<boolean>('darkTheme') !== false;
      const count: number = Math.min(16, qrPixels.length);
      const rows: number = Math.ceil(count / 2);
      const card: number = rows > 6 ? 180 : (rows > 4 ? 190 : (rows > 3 ? 210 : 250));
      const qrSize: number = card - 32;
      const gapX: number = (POSTER_WIDTH - card * 2) / 3;
      const gapY: number = rows > 3 ? 12 : 18;
      const startY: number = 160;
      const designHeight: number = Math.max(POSTER_HEIGHT, startY + rows * (card + gapY) + 110);
      const outputHeight: number = Math.round(designHeight * POSTER_SCALE);
      const canvas: OffscreenCanvas = new OffscreenCanvas(POSTER_OUTPUT_WIDTH, outputHeight);
      const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', new RenderingContextSettings(true));
      ctx.clearRect(0, 0, POSTER_OUTPUT_WIDTH, outputHeight);
      ctx.scale(POSTER_SCALE, POSTER_SCALE);
      if (cover !== undefined) {
        await ShareService.drawImageCover(ctx, cover, 0, 0, POSTER_WIDTH, designHeight);
        ctx.fillStyle = dark ? 'rgba(8,10,16,0.72)' : 'rgba(255,255,255,0.78)';
        ctx.fillRect(0, 0, POSTER_WIDTH, designHeight);
      } else {
        const gradient: CanvasGradient = ctx.createLinearGradient(0, 0, POSTER_WIDTH, designHeight);
        gradient.addColorStop(0, ShareService.cssColor(Ui.pageBg(dark)));
        gradient.addColorStop(1, ShareService.cssColor(Ui.pageBgAlt(dark)));
        ctx.fillStyle = gradient;
        ctx.fillRect(0, 0, POSTER_WIDTH, designHeight);
      }
      const ink: string = ShareService.cssColor(Ui.ink(dark));
      ShareService.paintTextAt(ctx, title, 40 * ShareService.posterFontScale(), ink,
        POSTER_WIDTH / 2, 84, 800, true, 'center');
      ShareService.paintTextAt(ctx, subtitle, 24 * ShareService.posterFontScale(),
        ShareService.cssColor(Ui.inkSoft(dark)), POSTER_WIDTH / 2, 126, 760, false, 'center');
      for (let index: number = 0; index < count; index++) {
        const column: number = index % 2;
        const row: number = Math.floor(index / 2);
        const x: number = gapX + column * (card + gapX);
        const y: number = startY + row * (card + gapY);
        ShareService.paintRoundedCard(ctx, x, y, card, card, 24, '#FFFFFF', '#E3E8F0', 1);
        ctx.drawImage(qrPixels[index], x + (card - qrSize) / 2, y + 10, qrSize, qrSize);
        ShareService.paintTextAt(ctx, String(index + 1) + '/' + String(qrPixels.length),
          18 * ShareService.posterFontScale(), ShareService.cssColor(Ui.inkSoft(dark)),
          x + card / 2, y + card - 10, card - 20, false, 'center');
      }
      ShareService.paintTextAt(ctx, ShareService.posterFooter(),
        24 * ShareService.posterFontScale(), ShareService.cssColor(Ui.inkSoft(dark)),
        POSTER_WIDTH / 2, designHeight - 76, 780, false, 'center');
      ShareService.paintTextAt(ctx, '无音影视 · 资源线路', 18 * ShareService.posterFontScale(),
        ShareService.cssColor(Ui.inkFaint(dark)), POSTER_WIDTH / 2, designHeight - 38, 700, false, 'center');
      const poster: image.PixelMap = ctx.getPixelMap(0, 0, POSTER_OUTPUT_WIDTH, outputHeight);
      ShareService.lastPosterFailure = '';
      return poster;
    } catch (error) {
      ShareService.lastPosterFailure = '多二维码海报合成失败：' + String(error);
      Logger.warn('SHARE', '多二维码海报合成失败：' + String(error));
      return undefined;
    }
  }

  /** 经典版式：主题渐变底 + 居中白卡二维码 + 中央 logo + 底部三行文案。 */
  private static async paintClassicPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    ShareService.paintPosterBackdrop(ctx, dark);
    ShareService.paintPosterHeader(ctx, dark, title, subtitle);
    ShareService.paintPosterQrCard(ctx, qr, dark);
    await ShareService.paintPosterLogo(ctx, context, dark);
    ShareService.paintPosterFooter(ctx, dark);
  }

  /** 极简版式：纯白底 + 大号白卡，只用深色文字，适合发朋友圈。 */
  private static async paintMinimalPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    const s: number = ShareService.posterFontScale();
    // 固定白底：这是「白卡极简」风格，不跟随深浅主题，打印/转发都干净。
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    ctx.fillStyle = ShareService.cssColor(Ui.accent(false), true);
    ctx.beginPath();
    ctx.roundRect(422, 92, 56, 6, 3);
    ctx.fill();
    ShareService.paintTextAt(ctx, '无音影视', 30 * s, ShareService.cssColor(Ui.accent(false)),
      POSTER_WIDTH / 2, 148, 760, false, 'center');
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 42 * s,
      ShareService.cssColor(Ui.ink(false)), POSTER_WIDTH / 2, 228, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 27 * s,
      ShareService.cssColor(Ui.inkSoft(false)), POSTER_WIDTH / 2, 296, 760, false, 'center');
    // 卡片底色与二维码底色同源，只加一圈浅描边，避免出现色块接缝。
    ShareService.paintRoundedCard(ctx, 120, 330, 660, 660, 40,
      ShareService.cssFromColor(ShareService.qrBackColor(dark)), ShareService.cssColor(Ui.divider(false)), 1);
    ctx.drawImage(qr, 170, 380, 560, 560);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 660, 54, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 42 * s, ShareService.cssColor(Ui.accent(false)),
      POSTER_WIDTH / 2, 1056, 840, true, 'center');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, ShareService.cssColor(Ui.inkSoft(false)),
POSTER_WIDTH / 2, 1116, 800, false, 'center');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, ShareService.cssColor(Ui.inkFaint(false)),
POSTER_WIDTH / 2, 1170, 800, false, 'center');
  }

  /** 霓虹版式：品牌渐变满版底 + 光斑，白卡二维码，字幕用白色，视觉冲击最强。 */
  private static async paintNeonPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    const s: number = ShareService.posterFontScale();
    const gradient: CanvasGradient = ctx.createLinearGradient(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    gradient.addColorStop(0, ShareService.cssColor(Ui.brandFrom(), true));
    gradient.addColorStop(0.55, ShareService.cssColor(Ui.brandMid(), true));
    gradient.addColorStop(1, ShareService.cssColor(Ui.brandTo(), true));
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    // 两团柔光，避免整版渐变太平。
    ctx.fillStyle = 'rgba(255,255,255,0.12)';
    ctx.beginPath();
    ctx.arc(770, 130, 220, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(110, 1130, 200, 0, Math.PI * 2);
    ctx.fill();
    ShareService.paintTextAt(ctx, '无音影视', 32 * s, 'rgba(255,255,255,0.92)',
      POSTER_WIDTH / 2, 148, 760, false, 'center');
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
'#FFFFFF', POSTER_WIDTH / 2, 232, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 27 * s,
'rgba(255,255,255,0.86)', POSTER_WIDTH / 2, 300, 780, false, 'center');
    ShareService.paintRoundedCard(ctx, 140, 330, 620, 620, 44, '#FFFFFF', '#FFFFFF', 0.45);
    ctx.drawImage(qr, 180, 370, 540, 540);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 640, 54, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 42 * s, '#FFFFFF',
POSTER_WIDTH / 2, 1040, 840, true, 'center');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, 'rgba(255,255,255,0.82)',
POSTER_WIDTH / 2, 1096, 800, false, 'center');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, 'rgba(255,255,255,0.62)',
POSTER_WIDTH / 2, 1152, 800, false, 'center');
  }

  /** 杂志版式：左侧主题色竖条 + 左对齐大标题，下面一张横幅二维码卡。 */
  private static async paintMagazinePoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    const s: number = ShareService.posterFontScale();
    ctx.fillStyle = ShareService.cssColor(Ui.pageBg(dark), true);
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    const bar: CanvasGradient = ctx.createLinearGradient(0, 0, 18, POSTER_HEIGHT);
    bar.addColorStop(0, ShareService.cssColor(Ui.brandFrom(), true));
    bar.addColorStop(1, ShareService.cssColor(Ui.brandTo(), true));
    ctx.fillStyle = bar;
    ctx.fillRect(0, 0, 18, POSTER_HEIGHT);
    ShareService.paintTextAt(ctx, '无音影视', 28 * s, ShareService.cssColor(Ui.accentStrong(dark)),
      64, 118, 700, false, 'left');
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
      ShareService.cssColor(Ui.ink(dark)), 64, 202, 840, true, 'left');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 27 * s,
      ShareService.cssColor(Ui.inkSoft(dark)), 64, 268, 760, false, 'left');
    ShareService.paintRoundedCard(ctx, 64, 320, 772, 640, 36,
      '#FFFFFF', ShareService.cssColor(Ui.accent(dark)), 0.35);
    ctx.drawImage(qr, 170, 360, 560, 560);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 640, 54, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 40 * s, ShareService.cssColor(Ui.accentStrong(dark)),
64, 1050, 840, true, 'left');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, ShareService.cssColor(Ui.inkSoft(dark)),
64, 1106, 760, false, 'left');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, ShareService.cssColor(Ui.inkFaint(dark)),
64, 1158, 760, false, 'left');
  }

  /** 封面卡版式：上半部影片封面大图，下半部标题 + 二维码，像一张影片海报。 */
  private static async paintCoverPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap, cover: image.PixelMap | undefined): Promise<void> {
    const s: number = ShareService.posterFontScale();
    const coverHeight: number = 640;
    ctx.fillStyle = ShareService.cssColor(Ui.pageBg(dark), true);
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    if (cover !== undefined) {
      // 封面按 cover 方式居中放大：宽度铺满整张海报，保持原有比例，超出的部分上下居中裁掉。
      await ShareService.drawImageCover(ctx, cover, 0, 0, POSTER_WIDTH, coverHeight);
    } else {
      // 没有封面时用主题渐变占位，版式结构不变。
      const placeholder: CanvasGradient = ctx.createLinearGradient(0, 0, POSTER_WIDTH, coverHeight);
      placeholder.addColorStop(0, ShareService.cssColor(Ui.brandFrom(), true));
      placeholder.addColorStop(1, ShareService.cssColor(Ui.brandTo(), true));
      ctx.fillStyle = placeholder;
      ctx.fillRect(0, 0, POSTER_WIDTH, coverHeight);
    }
    // 封面底部渐隐，和下方背景连成一体。
    const fade: CanvasGradient = ctx.createLinearGradient(0, coverHeight - 240, 0, coverHeight);
    fade.addColorStop(0, 'rgba(0,0,0,0)');
    fade.addColorStop(1, ShareService.cssColor(Ui.pageBg(dark), true));
    ctx.fillStyle = fade;
    ctx.fillRect(0, coverHeight - 240, POSTER_WIDTH, 240);
    ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
'#FFFFFF', POSTER_WIDTH / 2, 508, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 25 * s,
'rgba(255,255,255,0.9)', POSTER_WIDTH / 2, 570, 800, false, 'center');
    // 二维码卡：先用「正片叠底」把影片封面压成影视风底纹，再放二维码，
    // 这样卡片看起来是封面的一部分，而不是贴上去的一块白板。
    ShareService.paintRoundedCard(ctx, 210, 660, 480, 480, 36,
      ShareService.cssFromColor(ShareService.qrBackColor(dark)), ShareService.cssColor(Ui.accent(dark)), 0.3);
    if (cover !== undefined) {
      ctx.save();
      ctx.beginPath();
      ctx.roundRect(210, 660, 480, 480, 36);
      ctx.clip();
      ctx.globalCompositeOperation = 'multiply';
      ctx.globalAlpha = 0.72;
      // 取封面中部一段当底纹（cover 铺满卡片区域）。
      await ShareService.drawImageCover(ctx, cover, 210, 660, 480, 480);
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
      // 一层白色薄雾，保证底纹不会吃掉二维码的对比度。
      ctx.fillStyle = 'rgba(255,255,255,0.16)';
      ctx.fillRect(210, 660, 480, 480);
      ctx.restore();
    }
    ctx.drawImage(qr, 240, 690, 420, 420);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 900, 46, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 36 * s, ShareService.cssColor(Ui.accentStrong(dark)),
POSTER_WIDTH / 2, 1200, 840, true, 'center');
  }

  /** 影幕版式：封面高斯「半模糊」当整张背景 + 压暗层，白卡二维码居中。 */
  private static async paintFilmPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap, cover: image.PixelMap | undefined): Promise<void> {
    const s: number = ShareService.posterFontScale();
    let painted: boolean = false;
    if (cover !== undefined) {
      // 半模糊：半径减半（12 而不是 24），再叠一层原图（45% 不透明度），
      // 既保留「影幕」的柔化氛围，又能看出是哪部剧的封面。
      const blurred: image.PixelMap | undefined = await ShareService.blurredCover(cover, 12);
      try {
        await ShareService.drawImageCover(ctx, blurred !== undefined ? blurred : cover, 0, 0, POSTER_WIDTH, POSTER_HEIGHT);
        painted = true;
      } finally {
        if (blurred !== undefined) {
          try { await blurred.release(); } catch (_) { Logger.warn('SHARE', '释放模糊封面失败'); }
        }
      }
      if (blurred !== undefined) {
        ctx.save();
        ctx.globalAlpha = 0.45;
        await ShareService.drawImageCover(ctx, cover, 0, 0, POSTER_WIDTH, POSTER_HEIGHT);
        ctx.restore();
      }
    }
    if (!painted) {
      const placeholder: CanvasGradient = ctx.createLinearGradient(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
      placeholder.addColorStop(0, ShareService.cssColor(Ui.brandFrom(), true));
      placeholder.addColorStop(1, ShareService.cssColor(Ui.brandTo(), true));
      ctx.fillStyle = placeholder;
      ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    }
    // 压暗层：保证白字与二维码卡都清晰。
    const scrim: CanvasGradient = ctx.createLinearGradient(0, 0, 0, POSTER_HEIGHT);
    scrim.addColorStop(0, 'rgba(0,0,0,0.55)');
    scrim.addColorStop(0.5, 'rgba(0,0,0,0.66)');
    scrim.addColorStop(1, 'rgba(0,0,0,0.85)');
    ctx.fillStyle = scrim;
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
'#FFFFFF', POSTER_WIDTH / 2, 244, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 26 * s,
'rgba(255,255,255,0.85)', POSTER_WIDTH / 2, 300, 800, false, 'center');
    ShareService.paintRoundedCard(ctx, 150, 380, 600, 600, 44, '#FFFFFF', '#FFFFFF', 0.5);
    ctx.drawImage(qr, 180, 410, 540, 540);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 680, 54, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 40 * s, '#FFFFFF',
      POSTER_WIDTH / 2, 1060, 840, true, 'center');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, 'rgba(255,255,255,0.82)',
POSTER_WIDTH / 2, 1118, 800, false, 'center');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, 'rgba(255,255,255,0.6)',
POSTER_WIDTH / 2, 1168, 800, false, 'center');
  }

  /**
   * 节日版式：按当天节日切换配色、装饰与祝福语；没有节日时用默认红金 + 灯笼。
   * 配色与元素都来自 FestivalTheme，新增节日只要往规则表里加一行。
   */
  private static async paintFestivalPoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    const s: number = ShareService.posterFontScale();
    const theme: FestivalTheme = FestivalTheme.current();
    const accent: string = theme.accent;
    const deep: CanvasGradient = ctx.createLinearGradient(0, 0, 0, POSTER_HEIGHT);
    deep.addColorStop(0, theme.bgFrom);
    deep.addColorStop(0.55, ShareService.blendHex(theme.bgFrom, theme.bgTo, 0.55));
    deep.addColorStop(1, theme.bgTo);
    ctx.fillStyle = deep;
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    // 彩屑：固定种子，保证每次生成的花纹一致。
    let seed: number = 20260214;
    const next = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    for (let index: number = 0; index < 46; index++) {
      const x: number = next() * POSTER_WIDTH;
      const y: number = next() * POSTER_HEIGHT;
      const radius: number = 3 + next() * 5;
      ctx.globalAlpha = 0.12 + next() * 0.22;
      ctx.fillStyle = next() > 0.5 ? accent : '#FFFFFF';
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    // 当天节日的装饰元素（灯笼 / 月亮 / 雪花 / 爱心 / 星星 / 烟花 / 叶片）。
    ShareService.paintFestivalMotif(ctx, theme.motif, accent);
    if (theme.greeting.length > 0) {
      ShareService.paintTextAt(ctx, theme.greeting, 24 * s, accent,
POSTER_WIDTH / 2, 196, 840, true, 'center');
    }
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
'#FFF4E2', POSTER_WIDTH / 2, 276, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 26 * s,
'rgba(255,255,255,0.88)', POSTER_WIDTH / 2, 336, 780, false, 'center');
    ShareService.paintRoundedCard(ctx, 200, 420, 500, 500, 40, '#FFFDF7', accent, 0.55);
    ctx.drawImage(qr, 230, 450, 440, 440);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 670, 48, true);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 44 * s, accent,
POSTER_WIDTH / 2, 1004, 840, true, 'center');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, 'rgba(255,255,255,0.88)',
POSTER_WIDTH / 2, 1060, 800, false, 'center');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, 'rgba(255,255,255,0.6)',
POSTER_WIDTH / 2, 1110, 800, false, 'center');
  }

  /** 节日装饰元素：顶部左右两处，颜色统一用当天节日的强调色。 */
  private static paintFestivalMotif(ctx: OffscreenCanvasRenderingContext2D,
    motif: string, accent: string): void {
    try {
      if (motif === 'moon') {
        // 中秋：右上一轮明月 + 左下小月牙，外加几颗星。
        ctx.globalAlpha = 0.16;
        ctx.fillStyle = accent;
        ctx.beginPath();
        ctx.arc(732, 168, 108, 0, Math.PI * 2);
        ctx.fill();
        ctx.globalAlpha = 0.85;
        ctx.beginPath();
        ctx.arc(732, 168, 62, 0, Math.PI * 2);
        ctx.fill();
        ShareService.paintStar(ctx, 150, 150, 26, accent, 0.7);
        ShareService.paintStar(ctx, 214, 236, 14, accent, 0.5);
        ShareService.paintStar(ctx, 96, 250, 10, accent, 0.4);
      } else if (motif === 'snow') {
        // 圣诞/平安夜：两丛雪花 + 星点。
        ShareService.paintSnowflake(ctx, 150, 156, 56, accent);
        ShareService.paintSnowflake(ctx, 744, 186, 40, accent);
        ShareService.paintStar(ctx, 450, 120, 12, accent, 0.5);
      } else if (motif === 'heart') {
        // 情人节/七夕/妇女节：两颗爱心。
        ShareService.paintHeart(ctx, 168, 160, 52, accent, 0.75);
        ShareService.paintHeart(ctx, 738, 186, 38, accent, 0.55);
      } else if (motif === 'star') {
        ShareService.paintStar(ctx, 168, 160, 46, accent, 0.85);
        ShareService.paintStar(ctx, 742, 150, 34, accent, 0.6);
        ShareService.paintStar(ctx, 640, 250, 18, accent, 0.45);
      } else if (motif === 'firework') {
        ShareService.paintFirework(ctx, 176, 168, 78, accent, 0.85);
        ShareService.paintFirework(ctx, 736, 150, 60, accent, 0.6);
      } else if (motif === 'leaf') {
        ShareService.paintLeaf(ctx, 160, 158, 70, accent, 0.7);
        ShareService.paintLeaf(ctx, 744, 178, 54, accent, 0.5);
      } else {
        // 默认：两个灯笼圆（红金）。
        for (const cx of [150, 750]) {
          ctx.globalAlpha = 0.16;
          ctx.fillStyle = accent;
          ctx.beginPath();
          ctx.arc(cx, 150, 74, 0, Math.PI * 2);
          ctx.fill();
          ctx.globalAlpha = 0.55;
          ctx.strokeStyle = accent;
          ctx.lineWidth = 3;
          ctx.beginPath();
          ctx.arc(cx, 150, 74, 0, Math.PI * 2);
          ctx.stroke();
        }
      }
    } catch (error) {
      Logger.warn('SHARE', '绘制节日装饰失败：' + String(error));
    } finally {
      ctx.globalAlpha = 1;
    }
  }

  /** 五角星。 */
  private static paintStar(ctx: OffscreenCanvasRenderingContext2D, cx: number, cy: number,
    radius: number, color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.beginPath();
    for (let index: number = 0; index < 10; index++) {
      const angle: number = -Math.PI / 2 + index * Math.PI / 5;
      const r: number = index % 2 === 0 ? radius : radius * 0.44;
      const px: number = cx + Math.cos(angle) * r;
      const py: number = cy + Math.sin(angle) * r;
      if (index === 0) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
    }
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /** 爱心。 */
  private static paintHeart(ctx: OffscreenCanvasRenderingContext2D, cx: number, cy: number,
    radius: number, color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(cx, cy + radius * 0.78);
    ctx.bezierCurveTo(cx - radius * 1.45, cy - radius * 0.35, cx - radius * 0.52, cy - radius * 1.3,
      cx, cy - radius * 0.42);
    ctx.bezierCurveTo(cx + radius * 0.52, cy - radius * 1.3, cx + radius * 1.45, cy - radius * 0.35,
      cx, cy + radius * 0.78);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /** 雪花：六条主枝 + 分枝。 */
  private static paintSnowflake(ctx: OffscreenCanvasRenderingContext2D, cx: number, cy: number,
    radius: number, color: string): void {
    ctx.globalAlpha = 0.6;
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    for (let index: number = 0; index < 6; index++) {
      const angle: number = index * Math.PI / 3;
      const dx: number = Math.cos(angle);
      const dy: number = Math.sin(angle);
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + dx * radius, cy + dy * radius);
      ctx.stroke();
      // 两条分枝
      for (const side of [-0.62, 0.62]) {
        const bx: number = cx + dx * radius * 0.62;
        const by: number = cy + dy * radius * 0.62;
        ctx.beginPath();
        ctx.moveTo(bx, by);
        ctx.lineTo(bx + Math.cos(angle + side) * radius * 0.34, by + Math.sin(angle + side) * radius * 0.34);
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
  }

  /** 烟花：一圈放射线 + 外圈点。 */
  private static paintFirework(ctx: OffscreenCanvasRenderingContext2D, cx: number, cy: number,
    radius: number, color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    for (let index: number = 0; index < 12; index++) {
      const angle: number = index * Math.PI / 6;
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(angle) * radius * 0.28, cy + Math.sin(angle) * radius * 0.28);
      ctx.lineTo(cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius);
      ctx.stroke();
    }
    ctx.fillStyle = color;
    for (let index: number = 0; index < 12; index++) {
      const angle: number = index * Math.PI / 6 + Math.PI / 12;
      ctx.beginPath();
      ctx.arc(cx + Math.cos(angle) * radius * 1.12, cy + Math.sin(angle) * radius * 1.12, 4, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  /** 叶片（端午/重阳的艾叶、茱萸意象）。 */
  private static paintLeaf(ctx: OffscreenCanvasRenderingContext2D, cx: number, cy: number,
    radius: number, color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(-0.5);
    ctx.beginPath();
    ctx.moveTo(0, -radius);
    ctx.bezierCurveTo(radius * 0.85, -radius * 0.5, radius * 0.6, radius * 0.55, 0, radius);
    ctx.bezierCurveTo(-radius * 0.6, radius * 0.55, -radius * 0.85, -radius * 0.5, 0, -radius);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  /** 两个 #RRGGBB 颜色按比例混合。 */
  private static blendHex(from: string, to: string, ratio: number): string {
    try {
      const a: string = from.replace('#', '');
      const b: string = to.replace('#', '');
      if (a.length !== 6 || b.length !== 6) { return from; }
      const mix = (index: number): string => {
        const av: number = parseInt(a.substring(index, index + 2), 16);
        const bv: number = parseInt(b.substring(index, index + 2), 16);
        const value: number = Math.round(av + (bv - av) * ratio);
        return (value < 16 ? '0' : '') + value.toString(16);
      };
      return '#' + mix(0) + mix(2) + mix(4);
    } catch (_) {
      return from;
    }
  }

  /** 双色拼贴版式：主题色大色块 + 米色底，二维码卡压在两色之间。 */
  private static async paintCollagePoster(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean, title: string, subtitle: string,
    qr: image.PixelMap): Promise<void> {
    const s: number = ShareService.posterFontScale();
    // 米色底：与两个高饱和色块形成对比。
    ctx.fillStyle = '#F6F3EC';
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    // 上色块（主题主色）+ 右下角小方块，形成拼贴感。
    ctx.fillStyle = ShareService.cssColor(Ui.accent(dark), true);
    ctx.fillRect(0, 0, POSTER_WIDTH, 320);
    ctx.fillStyle = ShareService.cssColor(Ui.brandTo(), true);
    ctx.fillRect(0, 1150, POSTER_WIDTH, 90);
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(742, 44, 108, 108);
    ctx.fillRect(56, 196, 84, 84);
    ctx.globalAlpha = 1;
ShareService.paintTextAt(ctx, title.length > 0 ? title : '无音影视分享', 46 * s,
'#FFFFFF', POSTER_WIDTH / 2, 158, 840, true, 'center');
    ShareService.paintTextAt(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放', 26 * s,
'rgba(255,255,255,0.9)', POSTER_WIDTH / 2, 214, 780, false, 'center');
    ShareService.paintRoundedCard(ctx, 180, 380, 540, 540, 32,
      ShareService.cssFromColor(ShareService.qrBackColor(dark)), ShareService.cssColor(Ui.accent(dark)), 0.85);
    ctx.drawImage(qr, 210, 410, 480, 480);
    await ShareService.paintQrLogo(ctx, context, POSTER_WIDTH / 2, 650, 50, dark);
    ShareService.paintTextAt(ctx, '打开无音影视扫一扫', 42 * s, ShareService.cssColor(Ui.accent(false)),
POSTER_WIDTH / 2, 1000, 840, true, 'center');
    ShareService.paintTextAt(ctx, ShareService.posterFooter(), 26 * s, '#4F6178',
POSTER_WIDTH / 2, 1058, 800, false, 'center');
    ShareService.paintTextAt(ctx, '无音影视 · 分享海报', 22 * s, '#8493A6',
POSTER_WIDTH / 2, 1108, 800, false, 'center');
  }

  /**
   * 按 cover 方式把图片裁切填满目标框（保持比例、居中裁切）。
   *
   * 实现要点：不用 9 参数的 drawImage(image, sx, sy, sw, sh, dx, dy, dw, dh)——
   * 当前 ArkUI 实现里它不按目标矩形拉伸，封面只会画成原尺寸的一小块贴在左上角
   * （封面卡/影幕两个版式之前就是这样错位的）；也不用 PixelMap.crop（这个版本是原地裁切、
   * 会破坏页面缓存的封面位图）。这里用「按比例放大 + 裁剪矩形」组合：先算出能填满目标框的
   * 缩放比，把整图放大后按 offset 摆放，再 clip 到目标矩形，效果等同 CSS 的 background-size: cover。
   */
  private static async drawImageCover(ctx: OffscreenCanvasRenderingContext2D, pixels: image.PixelMap,
    x: number, y: number, width: number, height: number): Promise<void> {
    try {
      const info: image.ImageInfo = await pixels.getImageInfo();
      const sourceWidth: number = info.size.width;
      const sourceHeight: number = info.size.height;
      if (!(sourceWidth > 0) || !(sourceHeight > 0)) { return; }
      const targetRatio: number = width / height;
      const sourceRatio: number = sourceWidth / sourceHeight;
      // 目标框对应的原图裁切区域（居中）。
      let sx: number = 0;
      let sy: number = 0;
      let sw: number = sourceWidth;
      let sh: number = sourceHeight;
      if (sourceRatio > targetRatio) {
        sw = sourceHeight * targetRatio;
        sx = (sourceWidth - sw) / 2;
      } else {
        sh = sourceWidth / targetRatio;
        sy = (sourceHeight - sh) / 2;
      }
      const factor: number = Math.max(width / sw, height / sh);
      const drawX: number = x - sx * factor;
      const drawY: number = y - sy * factor;
      Logger.info('SHARE', '封面铺放：原图 ' + String(sourceWidth) + 'x' + String(sourceHeight) +
        '，目标 ' + String(Math.round(width)) + 'x' + String(Math.round(height)) +
        '，缩放 ' + factor.toFixed(3));
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y, width, height);
      ctx.clip();
      ctx.drawImage(pixels, drawX, drawY, sourceWidth * factor, sourceHeight * factor);
      ctx.restore();
    } catch (error) {
      Logger.warn('SHARE', '封面绘制失败：' + String(error));
    }
  }

  /** 高斯模糊封面（影幕版式背景）：radius 越大越糊；失败返回 undefined，调用方退回原图。 */
  private static async blurredCover(cover: image.PixelMap, radius: number = 24): Promise<image.PixelMap | undefined> {
    try {
      const filter: effectKit.Filter = effectKit.createEffect(cover);
      if (filter === undefined) { return undefined; }
      filter.blur(radius);
      return undefined;
    } catch (error) {
      Logger.warn('SHARE', '封面模糊失败：' + String(error));
      return undefined;
    }
  }

  /**
   * 把整张图片按原始比例缩放到目标框内并居中（contain，类似 background-size: contain），
   * 不裁切、不变形，四周空白由调用方自己铺垫。
   */
  private static async drawImageContain(ctx: OffscreenCanvasRenderingContext2D, pixels: image.PixelMap,
    x: number, y: number, width: number, height: number): Promise<void> {
    try {
      const info: image.ImageInfo = await pixels.getImageInfo();
      const sourceWidth: number = info.size.width;
      const sourceHeight: number = info.size.height;
      if (!(sourceWidth > 0) || !(sourceHeight > 0)) { return; }
      const factor: number = Math.min(width / sourceWidth, height / sourceHeight);
      const drawWidth: number = sourceWidth * factor;
      const drawHeight: number = sourceHeight * factor;
      const drawX: number = x + (width - drawWidth) / 2;
      const drawY: number = y + (height - drawHeight) / 2;
      ctx.drawImage(pixels, drawX, drawY, drawWidth, drawHeight);
      Logger.info('SHARE', '封面居中铺放：原图 ' + String(sourceWidth) + 'x' + String(sourceHeight) +
        '，绘制 ' + String(Math.round(drawWidth)) + 'x' + String(Math.round(drawHeight)) +
        '，缩放 ' + factor.toFixed(3));
    } catch (error) {
      Logger.warn('SHARE', '封面居中绘制失败：' + String(error));
    }
  }

  /** 下载影片封面并解码成位图（分享页在需要封面的版式里调用）。 */
  static async loadRemoteCover(url: string): Promise<image.PixelMap | undefined> {
    const target: string = (url || '').trim();
    if (target.length === 0) { return undefined; }
    // 线路分享用当前主题壁纸：支持 file:// URI / 沙箱路径，不走网络。
    if (!/^https?:\/\//i.test(target)) {
      let localSource: image.ImageSource | undefined = undefined;
      try {
        localSource = image.createImageSource(target);
        const pixels: image.PixelMap = await localSource.createPixelMap({
          desiredSize: { width: 900, height: 900 }
        });
        Logger.info('SHARE', '本地壁纸封面已解码：' + target);
        return pixels;
      } catch (error) {
        Logger.warn('SHARE', '本地壁纸封面解码失败：' + String(error));
        return undefined;
      } finally {
        if (localSource !== undefined) {
          try { await localSource.release(); } catch (_) { Logger.warn('SHARE', '释放本地封面源失败'); }
        }
      }
    }
    let request: http.HttpRequest | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(target, {
        method: http.RequestMethod.GET,
        connectTimeout: 6000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode < 200 || response.responseCode >= 300) { return undefined; }
      const data: ArrayBuffer = response.result as ArrayBuffer;
      if (data === undefined || data.byteLength < 256) { return undefined; }
      source = image.createImageSource(data);
      const pixels: image.PixelMap = await source.createPixelMap({ desiredSize: { width: 900, height: 900 } });
      Logger.info('SHARE', '封面已下载并解码，字节=' + String(data.byteLength));
      return pixels;
    } catch (error) {
      Logger.warn('SHARE', '封面下载失败：' + String(error));
      return undefined;
    } finally {
      try { request?.destroy(); } catch (_) { Logger.warn('SHARE', '释放封面请求失败'); }
      if (source !== undefined) {
        try { await source.release(); } catch (_) { Logger.warn('SHARE', '释放封面数据源失败'); }
      }
    }
  }

  /** 圆角卡片 + 可选描边/外发光圈。 */
  private static paintRoundedCard(ctx: OffscreenCanvasRenderingContext2D, x: number, y: number,
    width: number, height: number, radius: number, fillCss: string, ringCss: string, ringAlpha: number): void {
    if (ringCss.length > 0) {
      ctx.save();
      ctx.globalAlpha = Math.max(0, Math.min(1, ringAlpha));
      ctx.fillStyle = ringCss;
      ctx.beginPath();
      ctx.roundRect(x - 6, y - 6, width + 12, height + 12, radius + 6);
      ctx.fill();
      ctx.restore();
    }
    ctx.fillStyle = fillCss;
    ctx.beginPath();
    ctx.roundRect(x, y, width, height, radius);
    ctx.fill();
  }

  /** 任意版式的二维码中央 logo：白色圆底 + 圆形裁切图标，尺寸随圆底半径缩放。 */
  private static async paintQrLogo(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, cx: number, cy: number, ring: number, dark: boolean): Promise<void> {
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.arc(cx, cy, ring, 0, Math.PI * 2);
    ctx.fill();
    const side: number = Math.round(ring * 1.52);
    const half: number = side / 2;
    const logo: image.PixelMap | undefined = await ShareService.loadAppIcon(context);
    if (logo !== undefined) {
      try {
        ctx.save();
        ctx.beginPath();
        ctx.arc(cx, cy, half, 0, Math.PI * 2);
        ctx.clip();
        ctx.drawImage(logo, cx - half, cy - half, side, side);
        ctx.restore();
      } finally {
        try { await logo.release(); } catch (_) { Logger.warn('SHARE', '释放图标位图失败'); }
      }
      return;
    }
    ctx.fillStyle = ShareService.cssColor(Ui.brandFrom());
    ctx.beginPath();
    ctx.roundRect(cx - half, cy - half, side, side, Math.round(side * 0.23));
    ctx.fill();
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.moveTo(cx - half * 0.32, cy - half * 0.43);
    ctx.lineTo(cx + half * 0.48, cy);
    ctx.lineTo(cx - half * 0.32, cy + half * 0.43);
    ctx.closePath();
    ctx.fill();
    Logger.warn('SHARE', '未取到应用图标，二维码中央改用主题色播放键兜底，主题=' + (dark ? 'dark' : 'light'));
  }

  /** Ui 的 #AARRGGBB / #RRGGBB 颜色转 Canvas 可识别的 CSS 颜色。 */
  private static cssColor(value: string, forceOpaque: boolean = false): string {
    const color: common2D.Color = ShareService.toColor(value, 255);
    const alpha: number = forceOpaque ? 255 : Math.max(0, Math.min(255, color.alpha));
    if (alpha >= 255) { return 'rgb(' + String(color.red) + ',' + String(color.green) + ',' + String(color.blue) + ')'; }
    return 'rgba(' + String(color.red) + ',' + String(color.green) + ',' + String(color.blue) + ',' +
      (alpha / 255).toFixed(3) + ')';
  }

  /** 海报背景：主题页面色竖向渐变（不透明）+ 顶部主题色小横条。 */
  private static paintPosterBackdrop(ctx: OffscreenCanvasRenderingContext2D, dark: boolean): void {
    const gradient: CanvasGradient = ctx.createLinearGradient(0, 0, 0, POSTER_HEIGHT);
    gradient.addColorStop(0, ShareService.cssColor(Ui.pageBg(dark), true));
    gradient.addColorStop(1, ShareService.cssColor(Ui.pageBgAlt(dark), true));
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, POSTER_WIDTH, POSTER_HEIGHT);
    ctx.fillStyle = ShareService.cssColor(Ui.accent(dark));
    ctx.beginPath();
    ctx.roundRect(406, 52, 88, 8, 4);
    ctx.fill();
  }

  /**
   * 海报文字缩放：跟随系统字体大小（收窄到 0.9~1.05，避免和放大系数叠得太大），
   * 再统一乘 POSTER_TEXT_BOOST。海报会被压缩到手机宽度显示，基础字号必须放大才看得清。
   */
  private static posterFontScale(): number {
    try {
      const raw: number = Number(AppStorage.get<number>('fontScale') ?? 1);
      const clamped: number = (!Number.isFinite(raw) || raw <= 0) ? 1 : Math.max(0.9, Math.min(1.05, raw));
      return clamped * POSTER_TEXT_BOOST;
    } catch (_) {
      return POSTER_TEXT_BOOST;
    }
  }

  /** 海报头部：App 名 + 影视标题 + 集数副标题，超宽自动省略号。 */
  private static paintPosterHeader(ctx: OffscreenCanvasRenderingContext2D, dark: boolean,
    title: string, subtitle: string): void {
    const s: number = ShareService.posterFontScale();
    ShareService.paintPosterText(ctx, '无音影视', 36 * s, Ui.accentStrong(dark), 118, 760, false);
    ShareService.paintPosterText(ctx, title.length > 0 ? title : '无音影视分享',
      46 * s, Ui.ink(dark), 212, 840, true);
    ShareService.paintPosterText(ctx, subtitle.length > 0 ? subtitle : '扫码在手机端继续播放',
      30 * s, Ui.inkSoft(dark), 288, 780, false);
  }

  /** 海报主体：主题色圆角卡 + 居中二维码（卡片底色与二维码底色同源，码点跟随主题）。 */
  private static paintPosterQrCard(ctx: OffscreenCanvasRenderingContext2D,
    qr: image.PixelMap, dark: boolean): void {
    ctx.fillStyle = ShareService.cssColor(Ui.accent(dark), true);
    ctx.globalAlpha = dark ? 0.43 : 0.31;
    ctx.beginPath();
    ctx.roundRect(96, 316, 708, 668, 52);
    ctx.fill();
    ctx.globalAlpha = 1;
    // 卡片底色 = 二维码底色：二维码贴上去时没有色差，边缘看起来是同一张卡。
    ctx.fillStyle = ShareService.cssFromColor(ShareService.qrBackColor(dark));
    ctx.beginPath();
    ctx.roundRect(100, 320, 700, 660, 48);
    ctx.fill();
    // 二维码水平、垂直都居中于卡片，四周留 30~50px 底色边，避免贴边导致扫码失败。
    ctx.drawImage(qr, 150, 350, POSTER_QR_SIZE, POSTER_QR_SIZE);
  }

  /** 二维码中央 logo：白色圆底 + 圆形裁切的 无音影视 图标；取不到图标时用主题色播放键兜底。 */
  private static async paintPosterLogo(ctx: OffscreenCanvasRenderingContext2D,
    context: common.UIAbilityContext, dark: boolean): Promise<void> {
    const cx: number = POSTER_WIDTH / 2;
    const cy: number = 650;
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.arc(cx, cy, 58, 0, Math.PI * 2);
    ctx.fill();
    const logo: image.PixelMap | undefined = await ShareService.loadAppIcon(context);
    if (logo !== undefined) {
      try {
        // 圆形裁切后再贴图标，避免方形图标在白圆上露出四个直角。
        ctx.save();
        ctx.beginPath();
        ctx.arc(cx, cy, 44, 0, Math.PI * 2);
        ctx.clip();
        ctx.drawImage(logo, cx - 44, cy - 44, 88, 88);
        ctx.restore();
      } finally {
        try { await logo.release(); } catch (_) { Logger.warn('SHARE', '释放图标位图失败'); }
      }
      return;
    }
    ctx.fillStyle = ShareService.cssColor(Ui.brandFrom());
    ctx.beginPath();
    ctx.roundRect(cx - 44, cy - 44, 88, 88, 20);
    ctx.fill();
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.moveTo(cx - 14, cy - 19);
    ctx.lineTo(cx + 21, cy);
    ctx.lineTo(cx - 14, cy + 19);
    ctx.closePath();
    ctx.fill();
    Logger.warn('SHARE', '未取到应用图标，二维码中央改用主题色播放键兜底，主题=' + (dark ? 'dark' : 'light'));
  }

  /** 二维码底部：主文案「打开无音影视扫一扫」+ 一行说明 + 品牌落款。 */
  private static paintPosterFooter(ctx: OffscreenCanvasRenderingContext2D, dark: boolean): void {
    const s: number = ShareService.posterFontScale();
    ShareService.paintPosterText(ctx, '打开无音影视扫一扫', 46 * s, Ui.accentStrong(dark), 1058, 800, true);
    ShareService.paintPosterText(ctx, ShareService.posterFooter(), 30 * s, Ui.inkSoft(dark), 1120, 800, false);
    ShareService.paintPosterText(ctx, '无音影视 · 分享海报', 24 * s, Ui.inkFaint(dark), 1176, 800, false);
  }

  /** 居中绘制一行文字（baseline 定位），超宽用省略号截断。 */
  private static paintPosterText(ctx: OffscreenCanvasRenderingContext2D, text: string, size: number,
    color: string, baseline: number, maxWidth: number, bold: boolean): void {
    ShareService.paintTextAt(ctx, text, size, ShareService.cssColor(color),
      POSTER_WIDTH / 2, baseline, maxWidth, bold, 'center');
  }

  /** 任意对齐位置的文字绘制：colorCss 直接给 CSS 颜色（支持 rgba），便于各版式复用。 */
  private static paintTextAt(ctx: OffscreenCanvasRenderingContext2D, text: string, size: number,
    colorCss: string, x: number, baseline: number, maxWidth: number, bold: boolean,
    align: CanvasTextAlign): void {
    ctx.font = (bold ? 'bold ' : '') + String(size) + 'px sans-serif';
    const value: string = ShareService.fitCanvasText(ctx, text, maxWidth);
    if (value.length === 0) { return; }
    ctx.fillStyle = colorCss;
    ctx.textAlign = align;
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(value, x, baseline);
  }

  /** 按最大宽度把文字裁到刚好放得下，超出部分用省略号。 */
  private static fitCanvasText(ctx: OffscreenCanvasRenderingContext2D, text: string, maxWidth: number): string {
    const source: string = (text || '').trim();
    if (source.length === 0) { return ''; }
    if (ctx.measureText(source).width <= maxWidth) { return source; }
    let end: number = source.length;
    while (end > 1) {
      end -= 1;
      const candidate: string = source.substring(0, end) + '…';
      if (ctx.measureText(candidate).width <= maxWidth) { return candidate; }
    }
    return '…';
  }

  /** common2D.Color → Canvas 的 rgb() 颜色。 */
  private static cssFromColor(color: common2D.Color): string {
    return 'rgb(' + String(Math.max(0, Math.min(255, Math.round(color.red)))) + ',' +
      String(Math.max(0, Math.min(255, Math.round(color.green)))) + ',' +
      String(Math.max(0, Math.min(255, Math.round(color.blue)))) + ')';
  }

  /** 读取 App 图标（round 到 192px），供海报二维码中央使用。 */
  private static async loadAppIcon(context: common.UIAbilityContext): Promise<image.PixelMap | undefined> {
    let source: image.ImageSource | undefined = undefined;
    try {
      const bytes: Uint8Array = await context.resourceManager.getMediaContent($r('app.media.icon').id);
      if (bytes === undefined || bytes.byteLength === 0) { return undefined; }
      source = image.createImageSource(bytes.buffer);
      return await source.createPixelMap({ desiredSize: { width: 192, height: 192 } });
    } catch (error) {
      Logger.warn('SHARE', '读取应用图标失败：' + String(error));
      return undefined;
    } finally {
      if (source !== undefined) {
        try { await source.release(); } catch (_) { Logger.warn('SHARE', '释放图标数据源失败'); }
      }
    }
  }

  /** 十六进制颜色（#RRGGBB / #AARRGGBB）转 drawing 颜色；解析失败按中性灰兜底。 */
  private static toColor(value: string, alpha: number = 255): common2D.Color {
    const text: string = (typeof value === 'string' ? value : '').replace('#', '').trim();
    if (text.length === 8) {
      return {
        alpha: ShareService.hexPart(text, 0), red: ShareService.hexPart(text, 2),
        green: ShareService.hexPart(text, 4), blue: ShareService.hexPart(text, 6)
      };
    }
    if (text.length === 6) {
      return {
        alpha: alpha, red: ShareService.hexPart(text, 0),
        green: ShareService.hexPart(text, 2), blue: ShareService.hexPart(text, 4)
      };
    }
    if (text.length === 3) {
      const wide: string = text.charAt(0) + text.charAt(0) + text.charAt(1) + text.charAt(1) +
        text.charAt(2) + text.charAt(2);
      return {
        alpha: alpha, red: ShareService.hexPart(wide, 0),
        green: ShareService.hexPart(wide, 2), blue: ShareService.hexPart(wide, 4)
      };
    }
    return { alpha: alpha, red: 128, green: 128, blue: 128 };
  }

  /** 取颜色串里第 start 位起的两位十六进制分量，非法值按 0 处理。 */
  private static hexPart(text: string, start: number): number {
    const parsed: number = Number.parseInt(text.substring(start, start + 2), 16);
    if (!Number.isFinite(parsed)) { return 0; }
    return Math.max(0, Math.min(255, parsed));
  }

  /** 生成二维码位图：精简链接 → 从完整链接压缩 → 完整链接，逐个尝试。 */
  private static async buildQrImage(link: string, qrLink: string = '',
    dark: boolean = true): Promise<image.PixelMap | undefined> {
    const compact: string = (qrLink || '').trim();
    const full: string = (link || '').trim();
    const shrunk: string = ShareService.shrinkLink(full);
    const candidates: string[] = [];
    if (compact.length > 0) { candidates.push(compact); }
    if (shrunk.length > 0 && shrunk !== compact) { candidates.push(shrunk); }
    if (full.length > 0 && full !== compact && full !== shrunk) { candidates.push(full); }
    for (const value of candidates) {
      const pixels: image.PixelMap | undefined = await ShareService.tryBarcode(value, dark);
      if (pixels !== undefined) { return pixels; }
    }
    return undefined;
  }

  /**
   * 二维码码点颜色：直接取主题主色的色相/饱和度，只把亮度压到「还能扫得动」的上限，
   * 这样换主题时二维码会明显变成对应的主题色（而不是一律压成近黑）。
   */
  private static qrModuleColor(dark: boolean): common2D.Color {
    const base: common2D.Color = ShareService.toColor(Ui.accent(dark));
    const hsl: number[] = ShareService.rgbToHsl(base.red, base.green, base.blue);
    const saturation: number = Math.max(0.55, hsl[1]);
    let lightness: number = Math.min(0.52, Math.max(0.26, hsl[2]));
    let rgb: number[] = ShareService.hslToRgb(hsl[0], saturation, lightness);
    // 逐级压暗到亮度不超过 72：对比度能到 4:1 以上（扫码稳定），又保留主题色的鲜艳度。
    while (ShareService.luminanceOf(rgb[0], rgb[1], rgb[2]) > 72 && lightness > 0.12) {
      lightness -= 0.02;
      rgb = ShareService.hslToRgb(hsl[0], saturation, lightness);
    }
    return {
      alpha: 255,
      red: Math.round(rgb[0]),
      green: Math.round(rgb[1]),
      blue: Math.round(rgb[2])
    };
  }

  /** 加权亮度（0~255），用于判断二维码码点是否足够深。 */
  private static luminanceOf(red: number, green: number, blue: number): number {
    return 0.299 * red + 0.587 * green + 0.114 * blue;
  }

  /** RGB(0~255) → [h(0~360), s(0~1), l(0~1)]。 */
  private static rgbToHsl(red: number, green: number, blue: number): number[] {
    const r: number = red / 255;
    const g: number = green / 255;
    const b: number = blue / 255;
    const max: number = Math.max(r, g, b);
    const min: number = Math.min(r, g, b);
    const lightness: number = (max + min) / 2;
    const delta: number = max - min;
    if (delta === 0) { return [0, 0, lightness]; }
    const saturation: number = lightness > 0.5 ? delta / (2 - max - min) : delta / (max + min);
    let hue: number = 0;
    if (max === r) {
      hue = (g - b) / delta + (g < b ? 6 : 0);
    } else if (max === g) {
      hue = (b - r) / delta + 2;
    } else {
      hue = (r - g) / delta + 4;
    }
    return [hue * 60, saturation, lightness];
  }

  /** HSL(0~360, 0~1, 0~1) → [r, g, b](0~255)。 */
  private static hslToRgb(hue: number, saturation: number, lightness: number): number[] {
    const h: number = ((hue % 360) + 360) % 360;
    const s: number = Math.max(0, Math.min(1, saturation));
    const l: number = Math.max(0, Math.min(1, lightness));
    const c: number = (1 - Math.abs(2 * l - 1)) * s;
    const x: number = c * (1 - Math.abs((h / 60) % 2 - 1));
    const m: number = l - c / 2;
    let r: number = 0;
    let g: number = 0;
    let b: number = 0;
    if (h < 60) { r = c; g = x; }
    else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; }
    else { r = c; b = x; }
    return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
  }

  /** 二维码底色：以白为基、掺入主题色，深浅主题都保持浅底，同时看得出主题色调。 */
  private static qrBackColor(dark: boolean): common2D.Color {
    const tint: common2D.Color = ShareService.toColor(Ui.accent(dark));
    const ratio: number = dark ? 0.16 : 0.12;
    return {
      alpha: 255,
      red: Math.round(255 + (tint.red - 255) * ratio),
      green: Math.round(255 + (tint.green - 255) * ratio),
      blue: Math.round(255 + (tint.blue - 255) * ratio)
    };
  }

  /** common2D.Color → 0xRRGGBB，ScanKit 生成二维码时用这个格式。 */
  private static toRgbNumber(color: common2D.Color): number {
    return ((color.red & 0xFF) << 16) | ((color.green & 0xFF) << 8) | (color.blue & 0xFF);
  }

  /** 二维码编码：先试主题配色，失败再退回默认黑白（部分机型不接受自定义颜色）。 */
  private static async tryBarcode(content: string, dark: boolean = true): Promise<image.PixelMap | undefined> {
    const themed: image.PixelMap | undefined = await ShareService.encodeBarcode(content, dark, true);
    if (themed !== undefined) { return themed; }
    Logger.warn('SHARE', '主题配色二维码失败，退回默认黑白重试');
    return await ShareService.encodeBarcode(content, dark, false);
  }

  private static async encodeBarcode(content: string, dark: boolean,
    themed: boolean): Promise<image.PixelMap | undefined> {
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: POSTER_QR_SIZE,
        height: POSTER_QR_SIZE,
        margin: 1,
        level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
      };
      if (themed) {
        options.backgroundColor = ShareService.toRgbNumber(ShareService.qrBackColor(dark));
        options.pixelMapColor = ShareService.toRgbNumber(ShareService.qrModuleColor(dark));
      }
      return undefined;
    } catch (error) {
      Logger.warn('SHARE', '二维码编码失败（' + (themed ? '主题色' : '默认黑白') + '，' +
        String(content.length) + ' 字符）：' + String(error));
      return undefined;
    }
  }

  /** 生成分享二维码（PixelMap），失败返回 undefined。 */
  static async buildShareQr(link: string): Promise<image.PixelMap | undefined> {
    return ShareService.tryBarcode(link, AppStorage.get<boolean>('darkTheme') !== false);
  }

  /**
   * 二维码专用精简链接：完整链接带着全部选集与封面，长度常常超出二维码容量
   * （旧实现因此一路兜底到复制参数）。这里只保留本集可播放所需字段，
   * 解析端要求其余字段声明为 string，因此留空字符串。
   */
  static createQrLink(video: SearchVideoItem, episodeTitle: string, playUrl: string,
    episodeIndex: number = 0, playbackProgress?: number): string {
    try {
      const title: string = (video.tilie || video.yhm || '').trim();
      const target: string = playUrl.trim();
      if (!video.vodId.trim() || !title || !episodeTitle.trim() || !ShareService.networkUrl(target)) {
        return '';
      }
      const reader: ((videoId: string, episodeIndex: number) => number) | undefined = ShareService.playbackProgressReader;
      const progress: number = playbackProgress === undefined ?
        (reader ? reader(video.vodId, episodeIndex) : 0) : playbackProgress;
      const safeProgress: number = Number.isFinite(progress) && progress > 0 ? Math.floor(progress) : 0;
      // 极简格式：逐字段拼接，比整段 JSON 短一半以上，二维码码点更粗、更容易扫出来。
      const parts: string[] = [
        'v=1',
        'id=' + encodeURIComponent(video.vodId.trim()),
        't=' + encodeURIComponent(title.substring(0, 120)),
        'et=' + encodeURIComponent(episodeTitle.trim().replace(/[#$]/g, ' ').substring(0, 80)),
        'u=' + encodeURIComponent(target)
      ];
      // 封面只在是网络地址且不太长时带上，避免又把自己撑出二维码容量。
      if (ShareService.networkUrl(video.feng) && video.feng.length <= 320) {
        parts.push('f=' + encodeURIComponent(video.feng));
      }
      if (safeProgress > 0) { parts.push('p=' + String(safeProgress)); }
      // 仍用 module.json5 里注册的 wuyin://player，点开链接也能拉起应用。
      const link: string = SHARE_LINK_BASE + '?' + parts.join('&');
      Logger.info('SHARE', '已生成二维码精简链接，字符数=' + String(link.length));
      return link;
    } catch (error) {
      Logger.warn('SHARE', '生成二维码精简链接失败：' + String(error));
      return '';
    }
  }

  private static reportShareResult(logTag: string, serialized: string): void {
    try {
      const snapshot: ShareResultSnapshot | null = JSON.parse(serialized) as ShareResultSnapshot | null;
      const result: ShareResultSnapshot = snapshot || new ShareResultSnapshot();
      const resultCode: number | undefined = typeof result.resultCode === 'number' ? result.resultCode : result.code;
      const failed: boolean = (typeof resultCode === 'number' && resultCode !== 0) ||
        (typeof result.status === 'string' && /fail|error|reject/i.test(result.status));
      const detail: string = '系统投递状态：resultCode=' + String(resultCode) +
      '，status=' + String(result.status) + '，message=' + (result.message || '') + '，原始结果=' + serialized;
      if (failed) { Logger.error(logTag, detail + '，投递未成功，可重新分享或复制参数'); }
      else { Logger.info(logTag, detail + '；仅记录系统结果，不将面板关闭或无错误回调当作投递成功'); }
    } catch (_) {
      Logger.error(logTag, '读取系统投递结果失败，原始结果=' + serialized);
    }
  }

  static async shareEpisode(context: common.UIAbilityContext, video: SearchVideoItem,
    episodeTitle: string, playUrl: string, episodeIndex: number = 0,
    channel: string = 'share', playbackProgress?: number): Promise<void> {
    const logTag: string = channel === 'airdrop' ? 'AIRDROP' : 'SHARE';
    let link: string = '';
    let ownsPreparation: boolean = false;
    let controllerForRequest: systemShare.ShareController | undefined;
    try {
      if (ShareService.preparingShare || ShareService.activeController) {
        Logger.warn(logTag, '分享面板正在处理，请勿重复发送');
        return;
      }
      ShareService.preparingShare = true;
      ownsPreparation = true;
      link = ShareService.createLink(video, episodeTitle, playUrl, episodeIndex, channel, playbackProgress);
      const action: string = await ShareService.confirmReceiver(link, channel);
    if (action === 'qr') {
      // 跳到「分享二维码」页面：先预览海报，再由用户决定分享或复制链接。
      const qrLink: string = ShareService.createQrLink(video, episodeTitle, playUrl, episodeIndex, playbackProgress);
      ShareService.openQrPage(context, link, video.tilie || video.yhm || '无音影视分享', episodeTitle, qrLink,
        video.feng || video.sfeng || '');
      return;
    }
    if (action !== 'send') { return; }
      const thumbnail: Uint8Array | undefined = await ShareService.coverThumbnail(context, video.feng || video.sfeng || '');
      const previewDescription: string = episodeTitle + ' · 接收方需安装无音影视';
      // ShareKit 的 HYPERLINK content 直接提供 URI，不能传入 {url, description} 的 JSON 文本。
      // video 查询参数已在 createLink 中序列化和编码；此处与 NFC 一样使用原始 link。
      // 封面、标题和提示文字独立作为预览元数据，不混入传输 URI。
      const sharedData: systemShare.SharedData = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
          content: link,
          title: video.tilie || video.yhm,
          description: previewDescription,
          thumbnail: thumbnail
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
      controllerForRequest = controller;
      ShareService.activeController = controller;
      // 华为隔空投递及系统支持的手势传输均交由同一面板处理，不虚构私有手势发送 API。
      // 当前 SDK 的完成事件为单结果参数回调，不使用 (error, result) 双参数形式。
      controller.on('shareCompleted', (result: systemShare.ShareOperationResult): void => {
        try {
          ShareService.reportShareResult(logTag, JSON.stringify(result) || 'null');
        } catch (_) { Logger.error(logTag, '处理系统投递状态回调失败'); }
      });
      controller.on('dismiss', (): void => {
        try {
          if (ShareService.activeController === controller) { ShareService.activeController = undefined; }
          Logger.info(logTag, '系统分享面板已关闭，面板关闭不代表投递成功');
        } catch (_) { Logger.error(logTag, '处理分享面板关闭回调失败'); }
      });
      Logger.info(logTag, '打开 ShareKit 面板' + (channel === 'airdrop' ? '，请选择华为分享/隔空投送' : '') +
      '，数据类型=HYPERLINK，Scheme=wuyin://player，已携带当前播放进度');
      await controller.show(context, { previewMode: systemShare.SharePreviewMode.DEFAULT });
      Logger.info(logTag, '已提交系统分享请求，投递结果以系统回调为准');
    } catch (error) {
      if (ownsPreparation && ShareService.activeController === controllerForRequest) {
        ShareService.activeController = undefined;
      }
      const caught: Error = error as Error;
      const systemError: ShareResultSnapshot = error as ShareResultSnapshot;
      Logger.error(logTag, '分享或隔空投递异常，错误码=' + String(systemError.code) +
      '，message=' + (caught.message || '未知错误'));
      if (link) { await ShareService.showCopyFallback(link, '分享未完成，可复制参数后发送给对方。'); }
      else { throw new Error(caught.message || '当前影视参数无法分享，请检查播放线路'); }
    } finally {
      // 重复点击的请求没有取得准备锁，不能清除正在执行的请求所持有的锁。
      if (ownsPreparation) { ShareService.preparingShare = false; }
    }
  }

  private static async copyLink(link: string, logTag: string): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
      await pasteboard.getSystemPasteboard().setData(data);
      Logger.info(logTag, '影视 Scheme 参数已复制');
      promptAction.showToast({ message: '影视参数已复制', duration: 2000 });
    } catch (_) {
      if (await PlatformBridge.copyText(link)) {
        Logger.info(logTag, '已通过原生桥复制影视 Scheme 参数');
        promptAction.showToast({ message: '影视参数已复制', duration: 2000 });
        return;
      }
      Logger.error(logTag, '复制影视 Scheme 参数失败');
      throw new Error('复制参数失败，请重试');
    }
  }

  static async showCopyFallback(link: string, reason: string = ''): Promise<void> {
    try {
      const result: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '复制影视参数',
          message: (reason ? reason + '\n\n' : '') +
        '接收设备已安装无音影视时，可打开 wuyin://player 链接播放。未安装时无法唤起应用，请先复制参数、安装应用，再打开链接。',
          buttons: [{ text: '取消', color: '#999999' }, { text: '复制参数', color: '#E5484D' }]
      });
      if (result.index === 1) { await ShareService.copyLink(link, 'SHARE_FALLBACK'); }
    } catch (_) { Logger.error('SHARE_FALLBACK', '复制参数或显示提示失败'); }
  }
}









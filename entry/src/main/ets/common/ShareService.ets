import { common } from '@kit.AbilityKit';
import { ShareController, ShareOperationResult, SharedData, SharePreviewMode } from './compat/ShareCompat';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { SearchVideoItem } from '../pages/PlayerPage';
import { Logger } from './Logger';

const SHARE_LINK_BASE: string = 'wuyin://player';
// 同一个 ASCII Scheme 包也用于 NFC NDEF，预留 NDEF 记录及长度字段空间。
const MAX_LINK_LENGTH: number = 60000;
const MAX_COVER_BYTES: number = 2 * 1024 * 1024;
const MAX_THUMBNAIL_BYTES: number = 32 * 1024;

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

class ShareResultSnapshot {
  code?: number;
  resultCode?: number;
  status?: number | string;
  message?: string;
  targetBundleName?: string;
}

export class ShareService {
  // 保留控制器直到面板关闭，避免局部对象释放后丢失投递状态回调。
  private static activeController?: ShareController;
  private static preparingShare: boolean = false;
  private static pendingPlayerHandoff?: SharedPlayerRouteParams;
  private static playerHandoffSequence: number = 0;
  // NFC 服务保持原接口；生成统一数据包时读取当前播放器，而非新增桌面启动缓存。
  private static playbackProgressReader?: (videoId: string, episodeIndex: number) => number;

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

  static parseLink(uri: string): SharedPlayerParams | undefined {
    try {
      if (!/^wuyin:\/\/player\/?\?/i.test(uri) || uri.length > MAX_LINK_LENGTH || uri.indexOf('#') >= 0) {
        throw new Error('Scheme 地址或长度无效');
      }
      let raw: string = '';
      let found: boolean = false;
      for (const pair of uri.substring(uri.indexOf('?') + 1).split('&')) {
        const separator: number = pair.indexOf('=');
        if (separator < 0 || pair.substring(0, separator) !== 'video') { continue; }
        if (found) { throw new Error('影视参数重复'); }
        found = true;
        raw = decodeURIComponent(pair.substring(separator + 1).replace(/\+/g, '%20'));
      }
      if (!raw) { throw new Error('缺少影视参数'); }
      const value: SharedPlayerParams = JSON.parse(raw) as SharedPlayerParams;
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
      const entries: string[] = ShareService.episodeEntries(value.wzlj);
      if (value.sharedEpisodeIndex < 0 || value.sharedEpisodeIndex >= entries.length) {
        throw new Error('分享分集索引越界');
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
      Logger.info('SCHEME', 'Scheme 参数校验通过，来源=' + result.shareChannel + '，集数=' +
      (result.sharedEpisodeIndex + 1) + '，接续进度=' + result.sharedPlayProgress + '秒');
      return result;
    } catch (_) {
      Logger.error('SCHEME', 'Scheme 参数解析失败：地址、编码、字段、进度或分集索引无效');
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
  static async confirmReceiver(link: string, channel: string = 'share'): Promise<boolean> {
    const logTag: string = channel === 'nfc' ? 'NFC' : channel === 'airdrop' ? 'AIRDROP' : 'SHARE';
    try {
      const result: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '接收端需安装无音影视',
          message: '已安装应用的接收设备可打开 wuyin://player，自动播放本次分享的剧集。无法查询远端安装状态；若对方尚未安装，请先复制影视参数，安装应用后再打开链接。',
          buttons: [
          { text: '取消', color: '#999999' },
          { text: '复制参数', color: '#E5484D' },
          { text: '继续发送', color: '#E5484D' }
      ]
      });
      if (result.index === 1) { await ShareService.copyLink(link, logTag); }
      if (result.index !== 2) {
        Logger.info(logTag, result.index === 1 ? '发送前已复制参数，未启动投递' : '用户取消发送');
        return false;
      }
      Logger.info(logTag, '发送前安装提示已确认');
      return true;
    } catch (_) {
      Logger.error(logTag, '显示发送前提示失败，已停止发送');
      return false;
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
    let controllerForRequest: ShareController | undefined;
    try {
      if (ShareService.preparingShare || ShareService.activeController) {
        Logger.warn(logTag, '分享面板正在处理，请勿重复发送');
        return;
      }
      ShareService.preparingShare = true;
      ownsPreparation = true;
      link = ShareService.createLink(video, episodeTitle, playUrl, episodeIndex, channel, playbackProgress);
      if (!await ShareService.confirmReceiver(link, channel)) { return; }
      const thumbnail: Uint8Array | undefined = await ShareService.coverThumbnail(context, video.feng || video.sfeng || '');
      const previewDescription: string = episodeTitle + ' · 接收方需安装无音影视';
      // ShareKit 的 HYPERLINK content 直接提供 URI，不能传入 {url, description} 的 JSON 文本。
      // video 查询参数已在 createLink 中序列化和编码；此处与 NFC 一样使用原始 link。
      // 封面、标题和提示文字独立作为预览元数据，不混入传输 URI。
      const sharedData: SharedData = new SharedData({
        utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
          content: link,
          title: video.tilie || video.yhm,
          description: previewDescription,
          thumbnail: thumbnail
      });
      const controller: ShareController = new ShareController(sharedData);
      controllerForRequest = controller;
      ShareService.activeController = controller;
      // 华为隔空投递及系统支持的手势传输均交由同一面板处理，不虚构私有手势发送 API。
      // 当前 SDK 的完成事件为单结果参数回调，不使用 (error, result) 双参数形式。
      controller.on('shareCompleted', (result: ShareOperationResult): void => {
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
      await controller.show(context, { previewMode: SharePreviewMode.DEFAULT });
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

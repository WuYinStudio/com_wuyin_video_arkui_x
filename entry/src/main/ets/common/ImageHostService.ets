import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

/** 一次上传的结果；失败时带 HTTP 状态、「是否 404」和已经试过的每个图床的原因。 */
export class ImageHostResult {
  ok: boolean = false;
  url: string = '';
  host: string = '';
  httpStatus: number = 0;
  notFound: boolean = false;
  message: string = '';
  /** 视频封面帧（Chevereto 的 image.display_url），图片/语音为空。 */
  poster: string = '';
  /** 视频时长（秒，Chevereto 的 image.duration）。 */
  durationSec: number = 0;
}

/** 图床接口配置：地址、表单字段名、返回直链位置、API Key，都可自定义（只作用于首选图床）。 */
export class ImageHostConfig {
  uploadUrl: string = '';
  fieldName: string = '';
  responsePath: string = '';
  /** Chevereto 一类需要鉴权的图床：按键值发到 X-API-Key 请求头，留空表示匿名。 */
  apiKey: string = '';
  /**
   * 直传代理（可选）：把文件原始字节直接 POST 过去、由服务端转发到图床。
   * 用来绕开鸿蒙 multipart 在部分机型上被服务端判成空文件的问题，主要给视频/音频用。
   */
  proxyUrl: string = '';
  /** 直链图床（dbimg）地址：媒体文件优先走它，75MB、支持音频。 */
  directUrl: string = '';
  /** 直链图床的 API Key（Bearer）。 */
  directKey: string = '';
}

/** 一个上传目标：地址、字段名、返回格式、额外表单字段、允许的扩展名与体积上限。 */
class UploadTarget {
  label: string = '';
  url: string = '';
  fieldName: string = '';
  /** 空字符串表示接口直接返回纯文本直链（配合 format=txt）。 */
  responsePath: string = '';
  allowed: string[] = [];
  maxBytes: number = 0;
  /** 非空时按 X-API-Key 头发送（Chevereto 的 API v1 就是这样鉴权）。 */
  apiKey: string = '';
  /** 非空时优先走直传代理（原始字节 POST）。 */
  proxyUrl: string = '';
}

/**
 * 媒体上传服务：只走奶昔图床（Chevereto v4）。
 *
 * 奶昔 https://naixiai.cn/api/1/upload：jpg/png/gif/webp/mp4/webm/mov/mp3/wav/flac/m4a/ogg，≤50MB；
 * 地址、表单字段名、返回直链位置、API Key 都可以在设置页改。
 *
 * 调用方只管拿直链，异常全部在 try-catch 里收口，不向外抛，避免影响聊天等既有业务。
 */
export class ImageHostService {
  static readonly DEFAULT_UPLOAD_URL: string = 'https://naixiai.cn/api/1/upload';
  static readonly DEFAULT_FIELD_NAME: string = 'source';
  static readonly DEFAULT_RESPONSE_PATH: string = 'image.url';
  /** 内置的奶昔 API Key（Chevereto v4，走 X-API-Key）。设置页里默认是隐藏状态。 */
  static readonly DEFAULT_API_KEY: string =
    'chv_OmR_28831c6c4cf1bcd1a5d179ca45830bebb12fe33438f89dae5de77e6c70fac4c3_1641bfc8529bb9592d8ab26262e9e8d486ff9c2ade21ba5df2519c5ffb2fe928';
  /** 奶昔单文件上限。 */
  static readonly NAISHI_MAX_BYTES: number = 50 * 1024 * 1024;
  /** 直链图床 dbimg：地址、字段名、返回路径、Key（Bearer）、单文件上限。 */
  static readonly DEFAULT_DIRECT_URL: string = 'https://dbimg.app/api/upload';
  static readonly DEFAULT_DIRECT_FIELD: string = 'file';
  static readonly DEFAULT_DIRECT_PATH: string = 'mediaUrl';
  static readonly DIRECT_MAX_BYTES: number = 75 * 1024 * 1024;
  /** 内置的 dbimg API Key（免费账号 3 把，默认用第一把）。 */
  static readonly DEFAULT_DIRECT_KEY: string = 'dbimg_rr7iu4P4EQooRBB6JhDC-B4tXCGjZvGp4v8G4xb0rFU';
  /**
   * 直链图床（dbimg）只接管**音频**：语音消息走它。
   * 图片、视频保持原来的奶昔链路，不受影响。
   */
  private static readonly DIRECT_TYPES: string[] = [
    '.wav', '.mp3', '.ogg', '.flac', '.aac', '.m4a'
  ];
  /** base64 送法的体积上限：与图床单文件上限一致（50MB），视频也走这条。 */
  private static readonly BASE64_MAX_BYTES: number = ImageHostService.NAISHI_MAX_BYTES;
  /** 送法被跳过（不适用于当前文件）的标记，uploadWith 看到它就换下一种。 */
  private static readonly SKIP_TOKEN: string = '__skip__';
  /** 扩展名保持原样：dbimg 支持 m4a/mp3/wav，改后缀反而会让服务端校验失败。 */
  private static normalizeExtension(extension: string): string {
    return extension;
  }

  /** 奶昔支持的媒体扩展名（注意：不支持 m4a，音频统一按 mp4 传）。 */
  private static readonly NAISHI_TYPES: string[] = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp',
    '.mp4', '.webm', '.mov',
    '.mp3', '.wav', '.flac', '.ogg'
  ];
  /** 可执行/安装包类一律不发：图床不接受，也不该往公共图床塞。 */
  private static readonly BLOCKED_TYPES: string[] = [
    '.exe', '.apk', '.apks', '.aab', '.bat', '.cmd', '.com', '.msi', '.msc', '.scr',
    '.vbs', '.js', '.jar', '.dll', '.so', '.dylib', '.deb', '.rpm', '.dmg', '.pkg',
    '.app', '.appx', '.ipa', '.sh', '.ps1', '.py'
  ];
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_URL: string = 'imageHostUploadUrl';
  private static readonly KEY_FIELD: string = 'imageHostFieldName';
  private static readonly KEY_PATH: string = 'imageHostResponsePath';
  private static readonly KEY_API_KEY: string = 'imageHostApiKey';
  private static readonly KEY_PROXY: string = 'imageHostProxyUrl';
  private static readonly KEY_DIRECT_URL: string = 'imageHostDirectUrl';
  private static readonly KEY_DIRECT_KEY: string = 'imageHostDirectKey';
  /** 上次成功的送法（path / base64 / data），下次优先用它，省掉重复失败。 */
  private static readonly KEY_MODE: string = 'imageHostUploadMode';
  private static lastGoodMode: string = '';
  private static store?: preferences.Preferences;
  private static context?: common.UIAbilityContext;
  private static config: ImageHostConfig = ImageHostService.defaults();

  private static defaults(): ImageHostConfig {
    const config: ImageHostConfig = new ImageHostConfig();
    config.uploadUrl = ImageHostService.DEFAULT_UPLOAD_URL;
    config.fieldName = ImageHostService.DEFAULT_FIELD_NAME;
    config.responsePath = ImageHostService.DEFAULT_RESPONSE_PATH;
    config.apiKey = ImageHostService.DEFAULT_API_KEY;
    config.directUrl = ImageHostService.DEFAULT_DIRECT_URL;
    config.directKey = ImageHostService.DEFAULT_DIRECT_KEY;
    return config;
  }

  static async init(context: common.UIAbilityContext): Promise<void> {
    ImageHostService.context = context;
    try {
      ImageHostService.store = await preferences.getPreferences(context, ImageHostService.STORE);
      const url: string = String(await ImageHostService.store.get(ImageHostService.KEY_URL, ImageHostService.DEFAULT_UPLOAD_URL));
      const field: string = String(await ImageHostService.store.get(ImageHostService.KEY_FIELD, ImageHostService.DEFAULT_FIELD_NAME));
      const path: string = String(await ImageHostService.store.get(ImageHostService.KEY_PATH, ImageHostService.DEFAULT_RESPONSE_PATH));
      const apiKey: string = String(await ImageHostService.store.get(ImageHostService.KEY_API_KEY, ImageHostService.DEFAULT_API_KEY));
      const config: ImageHostConfig = ImageHostService.defaults();
      config.uploadUrl = ImageHostService.isValidUrl(url) ? url.trim() : ImageHostService.DEFAULT_UPLOAD_URL;
      config.fieldName = ImageHostService.isValidField(field) ? field.trim() : ImageHostService.DEFAULT_FIELD_NAME;
      config.responsePath = ImageHostService.isValidPath(path) ? path.trim() : ImageHostService.DEFAULT_RESPONSE_PATH;
      config.apiKey = apiKey.trim();
      config.proxyUrl = String(await ImageHostService.store.get(ImageHostService.KEY_PROXY, '')).trim();
      // 直链图床：本地存了空串（历史上被覆盖过）时回落到内置默认值，避免语音退回奶昔。
      const savedDirectUrl: string =
        String(await ImageHostService.store.get(ImageHostService.KEY_DIRECT_URL, ImageHostService.DEFAULT_DIRECT_URL)).trim();
      const savedDirectKey: string =
        String(await ImageHostService.store.get(ImageHostService.KEY_DIRECT_KEY, ImageHostService.DEFAULT_DIRECT_KEY)).trim();
      config.directUrl = savedDirectUrl.length > 0 ? savedDirectUrl : ImageHostService.DEFAULT_DIRECT_URL;
      config.directKey = savedDirectKey.length > 0 ? savedDirectKey : ImageHostService.DEFAULT_DIRECT_KEY;
      ImageHostService.config = config;
      ImageHostService.lastGoodMode =
        String(await ImageHostService.store.get(ImageHostService.KEY_MODE, ''));
      Logger.info('IMAGE_HOST', '图床配置已恢复：' + config.uploadUrl + '；直链图床=' + config.directUrl +
        (config.directKey.length > 0 ? '（已带 Key）' : '（无 Key）'));
    } catch (error) {
      Logger.error('IMAGE_HOST', '读取图床配置失败：' + String(error));
      ImageHostService.config = ImageHostService.defaults();
    }
  }

  /** 返回副本，避免设置页改到一半就影响正在进行的上传。 */
  static current(): ImageHostConfig {
    const config: ImageHostConfig = ImageHostService.defaults();
    config.uploadUrl = ImageHostService.config.uploadUrl;
    config.fieldName = ImageHostService.config.fieldName;
    config.responsePath = ImageHostService.config.responsePath;
    config.apiKey = ImageHostService.config.apiKey;
    config.proxyUrl = ImageHostService.config.proxyUrl;
    config.directUrl = ImageHostService.config.directUrl;
    config.directKey = ImageHostService.config.directKey;
    return config;
  }

  static isValidUrl(value: string): boolean {
    const normalized: string = value.trim();
    if (normalized.length === 0) { return false; }
    return /^https?:\/\/[^\s]+$/i.test(normalized);
  }

  static isValidField(value: string): boolean {
    return /^[A-Za-z0-9_.\-]+$/.test(value.trim());
  }

  static isValidPath(value: string): boolean {
    // 允许留空：有些接口（如 Chevereto 的 format=txt）直接返回纯文本直链。
    const trimmed: string = value.trim();
    if (trimmed.length === 0) { return true; }
    return /^[A-Za-z0-9_.\-\[\]]+$/.test(trimmed);
  }

  static async save(uploadUrl: string, fieldName: string, responsePath: string, apiKey: string,
    proxyUrl: string = '', directUrl: string = '', directKey: string = ''): Promise<void> {
    if (!ImageHostService.isValidUrl(uploadUrl)) {
      throw new Error('接口地址必须是 http 或 https 链接');
    }
    if (!ImageHostService.isValidField(fieldName)) {
      throw new Error('表单字段名只能包含字母、数字、下划线、点或短横线');
    }
    if (!ImageHostService.isValidPath(responsePath)) {
      throw new Error('返回路径格式无效，例如 data.url；留空表示接口直接返回纯文本直链');
    }
    if (proxyUrl.trim().length > 0 && !ImageHostService.isValidUrl(proxyUrl)) {
      throw new Error('直传代理地址必须是 http 或 https 链接');
    }
    const config: ImageHostConfig = ImageHostService.defaults();
    config.uploadUrl = uploadUrl.trim();
    config.fieldName = fieldName.trim();
    config.responsePath = responsePath.trim().replace(/^\$\.?/, '');
    config.apiKey = apiKey.trim();
    config.proxyUrl = proxyUrl.trim();
    // 直链图床（dbimg）单独维护：不传值时保留原有配置，避免保存「图床设置」时被清空。
    const keepDirectUrl: string = directUrl.trim().length > 0 ? directUrl.trim() : ImageHostService.config.directUrl;
    const keepDirectKey: string = directKey.trim().length > 0 ? directKey.trim() : ImageHostService.config.directKey;
    config.directUrl = keepDirectUrl.length > 0 ? keepDirectUrl : ImageHostService.DEFAULT_DIRECT_URL;
    config.directKey = keepDirectKey.length > 0 ? keepDirectKey : ImageHostService.DEFAULT_DIRECT_KEY;
    ImageHostService.config = config;
    await ImageHostService.persist();
    Logger.info('IMAGE_HOST', '图床配置已保存：' + config.uploadUrl +
      (config.apiKey.length > 0 ? '（带 API Key）' : '') +
      (config.proxyUrl.length > 0 ? '（带直传代理）' : '') +
      '，直链图床=' + config.directUrl);
  }

  static async restoreDefaults(): Promise<void> {
    ImageHostService.config = ImageHostService.defaults();
    await ImageHostService.persist();
    Logger.info('IMAGE_HOST', '图床配置已恢复默认');
  }

  private static async persist(): Promise<void> {
    if (ImageHostService.store === undefined) {
      if (ImageHostService.context === undefined) {
        throw new Error('图床配置存储未初始化');
      }
      ImageHostService.store = await preferences.getPreferences(ImageHostService.context, ImageHostService.STORE);
    }
    await ImageHostService.store.put(ImageHostService.KEY_URL, ImageHostService.config.uploadUrl);
    await ImageHostService.store.put(ImageHostService.KEY_FIELD, ImageHostService.config.fieldName);
    await ImageHostService.store.put(ImageHostService.KEY_PATH, ImageHostService.config.responsePath);
    await ImageHostService.store.put(ImageHostService.KEY_API_KEY, ImageHostService.config.apiKey);
    await ImageHostService.store.put(ImageHostService.KEY_PROXY, ImageHostService.config.proxyUrl);
    await ImageHostService.store.put(ImageHostService.KEY_DIRECT_URL, ImageHostService.config.directUrl);
    await ImageHostService.store.put(ImageHostService.KEY_DIRECT_KEY, ImageHostService.config.directKey);
    await ImageHostService.store.flush();
  }

  /**
   * 用已保存的配置上传：
   * - 音频（wav/mp3/m4a…）→ dbimg；失败再退回奶昔；
   * - 其它文件（pdf/zip/docx…）→ 走默认图床（「图床设置」里配的那家）；
   * - 图片、视频 → 完全保持原来的奶昔链路。
   */
  static async upload(uri: string): Promise<ImageHostResult> {
    Logger.info('IMAGE_HOST', '上传入口：直链图床=' + ImageHostService.config.directUrl +
      (ImageHostService.config.directKey.length > 0 ? '（有 Key）' : '（无 Key，跳过）'));
    const direct: ImageHostResult = await ImageHostService.uploadToDirect(uri);
    if (direct.ok && direct.url.length > 0) { return direct; }
    if (direct.message.length > 0) {
      Logger.warn('IMAGE_HOST', '直链图床未成功：' + direct.message + '，改用默认图床');
    }
    // 普通文件（pdf/zip…）也先按需求交给 dbimg；它只收媒体，被拒后再走默认图床。
    const fileDirect: ImageHostResult = await ImageHostService.uploadToDirect(uri, true);
    if (fileDirect.ok && fileDirect.url.length > 0) { return fileDirect; }
    if (fileDirect.message.length > 0) {
      Logger.warn('IMAGE_HOST', 'dbimg 未接收该文件：' + fileDirect.message + '，改用默认图床');
    }

    const first: ImageHostResult = await ImageHostService.uploadWith(ImageHostService.config, uri);
    if (first.ok) { return first; }
    // 两种送法都失败时，把 dbimg 的原因一起带出来，方便定位是哪一家出的问题。
    if (direct.message.length > 0) {
      first.message = 'dbimg：' + direct.message + '；' + (first.message || '默认图床未返回原因');
    }
    return first;
  }

  /** 聊天「文件」按钮专用：走 dbimg，只接受音频/视频/图片，其它类型直接给出提示。 */
  static async uploadFileAsMedia(uri: string): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    const extension: string = ImageHostService.detectExtension(
      ImageHostService.headBytes(uri, 16), ImageHostService.extensionOf(uri));
    const allowed: boolean = ImageHostService.DIRECT_TYPES.indexOf(extension) >= 0 ||
      ImageHostService.isImageType(extension) || ImageHostService.isVideoType(extension);
    if (!allowed) {
      result.message = 'dbimg 只支持音频、视频、图片文件（当前 ' + (extension || '未知类型') + '）';
      Logger.warn('IMAGE_HOST', '文件类型不被 dbimg 接受：' + extension);
      return result;
    }
    return await ImageHostService.uploadToDirectMedia(uri, extension);
  }

  /** 用 dbimg 传一个媒体文件（图片/视频/音频都算）。 */
  private static async uploadToDirectMedia(uri: string, extension: string): Promise<ImageHostResult> {
    const config: ImageHostConfig = ImageHostService.config;
    if (config.directUrl.length === 0 || config.directKey.length === 0) {
      const result: ImageHostResult = new ImageHostResult();
      result.message = '未配置直链图床';
      return result;
    }
    return await ImageHostService.sendDirectPayload(config, uri, extension);
  }

  /**
   * 直链图床（dbimg）：POST /api/upload，字段 file，头 Authorization: Bearer <key>。
   * 返回 mediaUrl 是 CDN 绝对地址；没有时用 directUrl 拼成绝对地址。
   * 非媒体文件（pdf/zip 等）dbimg 会 400，这里直接跳过让奶昔处理。
   */
  static async uploadToDirect(uri: string, anyFile: boolean = false): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    const config: ImageHostConfig = ImageHostService.config;
    if (config.directUrl.length === 0 || config.directKey.length === 0) {
      Logger.warn('IMAGE_HOST', '直链图床未配置（地址或 Key 为空），该文件会退回默认图床');
      result.message = '';
      return result;
    }
    const extension: string = ImageHostService.normalizeExtension(ImageHostService.detectExtension(
      ImageHostService.headBytes(uri, 16), ImageHostService.extensionOf(uri)));
    if (!anyFile) {
      // 第一轮：只接管音频；图片、视频、普通文件继续走默认图床。
      if (ImageHostService.DIRECT_TYPES.indexOf(extension) < 0) {
        result.message = '';
        return result;
      }
    } else if (ImageHostService.DIRECT_TYPES.indexOf(extension) >= 0 ||
      ImageHostService.isImageType(extension) || ImageHostService.isVideoType(extension) ||
      ImageHostService.BLOCKED_TYPES.indexOf(extension) >= 0) {
      // 第二轮只补「普通文件」：音频已试过，图片/视频保持原链路，可执行文件仍拒收。
      result.message = '';
      return result;
    }
    return await ImageHostService.sendDirectPayload(config, uri, extension);
  }

  /** dbimg 的实际发送：单个 file 段 + Bearer 头，返回 mediaUrl / directUrl。 */
  private static async sendDirectPayload(config: ImageHostConfig, uri: string,
    extension: string): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    const declaredSize: number = ImageHostService.sizeOf(uri);
    if (declaredSize > ImageHostService.DIRECT_MAX_BYTES) {
      result.message = '文件超过 ' + ImageHostService.megaText(ImageHostService.DIRECT_MAX_BYTES);
      return result;
    }
    let request: http.HttpRequest | undefined = undefined;
    try {
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      const part: http.MultiFormData = {
        name: ImageHostService.DEFAULT_DIRECT_FIELD,
        contentType: ImageHostService.contentTypeOf(fileName),
        remoteFileName: fileName
      };
      const bytes: ArrayBuffer = declaredSize > 0 ?
        ImageHostService.readExact(uri, declaredSize) :
        ImageHostService.readBytes(uri, ImageHostService.DIRECT_MAX_BYTES);
      if (bytes.byteLength === 0) {
        result.message = '读取文件失败：内容为空';
        return result;
      }
      part.data = bytes;
      Logger.info('IMAGE_HOST', '直链上传：类型=' + extension + '，字节=' + String(bytes.byteLength));
      const header: Record<string, string> = {};
      header['Authorization'] = 'Bearer ' + config.directKey;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        multiFormDataList: [part],
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 180000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(config.directUrl, options);
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        result.httpStatus = response.responseCode;
        result.message = 'HTTP ' + String(response.responseCode) + '（' +
          ImageHostService.failureDetail(text) + '，发送 ' + String(bytes.byteLength) + ' 字节）';
        Logger.warn('IMAGE_HOST', '系统 multipart 失败：' + result.message + '，改用手拼 multipart 重试');
        // 系统 multiFormDataList 在部分机型上组包异常（服务端 500），改用手拼 body 再试一次。
        const manual: ImageHostResult =
          await ImageHostService.sendDirectManual(config, uri, extension, bytes);
        if (!manual.ok) {
          manual.message = result.message + '；手拼：' + manual.message;
        }
        return manual;
      }
      let picked: string = ImageHostService.pickUrl(text, 'mediaUrl');
      if (picked.length === 0) { picked = ImageHostService.pickUrl(text, 'directUrl'); }
      // dbimg 的 directUrl 是相对路径（/image/xxx.png），按接口域名补全。
      if (picked.length > 0 && !/^https?:\/\//i.test(picked)) {
        const origin: string = ImageHostService.originOf(config.directUrl);
        picked = origin + (picked.startsWith('/') ? picked : '/' + picked);
      }
      if (picked.length === 0) {
        result.message = '返回里没有直链（' + ImageHostService.failureDetail(text) + '）';
        return result;
      }
      result.ok = true;
      result.url = picked;
      result.host = 'dbimg';
      Logger.info('IMAGE_HOST', '直链上传成功 → ' + picked);
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) { request.destroy(); }
    }
  }

  /** 手拼 multipart 发 dbimg：显式 boundary + 段头 + 原始字节，绕开系统组包。 */
  private static async sendDirectManual(config: ImageHostConfig, uri: string, extension: string,
    known: ArrayBuffer): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    try {
      const bytes: ArrayBuffer = known.byteLength > 0 ? known :
        ImageHostService.readBytes(uri, ImageHostService.DIRECT_MAX_BYTES);
      if (bytes.byteLength === 0) {
        result.message = '读取文件失败：内容为空';
        return result;
      }
      const boundary: string = '----WuyinDbimg' + String(Date.now());
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      const headText: string = '--' + boundary + '\r\n' +
        'Content-Disposition: form-data; name="' + ImageHostService.DEFAULT_DIRECT_FIELD +
        '"; filename="' + fileName + '"\r\n' +
        'Content-Type: ' + ImageHostService.contentTypeOf(fileName) + '\r\n\r\n';
      const tailText: string = '\r\n--' + boundary + '--\r\n';
      const head: Uint8Array = new util.TextEncoder().encodeInto(headText);
      const tail: Uint8Array = new util.TextEncoder().encodeInto(tailText);
      const body: Uint8Array = new Uint8Array(head.length + bytes.byteLength + tail.length);
      body.set(head, 0);
      body.set(new Uint8Array(bytes), head.length);
      body.set(tail, head.length + bytes.byteLength);
      const header: Record<string, string> = {};
      header['Authorization'] = 'Bearer ' + config.directKey;
      header['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body.buffer,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 180000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(config.directUrl, options);
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        result.httpStatus = response.responseCode;
        result.message = 'HTTP ' + String(response.responseCode) + '（' +
          ImageHostService.failureDetail(text) + '）';
        return result;
      }
      let picked: string = ImageHostService.pickUrl(text, 'mediaUrl');
      if (picked.length === 0) { picked = ImageHostService.pickUrl(text, 'directUrl'); }
      if (picked.length > 0 && !/^https?:\/\//i.test(picked)) {
        picked = ImageHostService.originOf(config.directUrl) + (picked.startsWith('/') ? picked : '/' + picked);
      }
      if (picked.length === 0) {
        result.message = '返回里没有直链（' + ImageHostService.failureDetail(text) + '）';
        return result;
      }
      result.ok = true;
      result.url = picked;
      result.host = 'dbimg';
      Logger.info('IMAGE_HOST', '手拼 multipart 上传成功 → ' + picked);
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) { request.destroy(); }
    }
  }

  /** 取 URL 的协议+域名，用于补全相对直链。 */
  private static originOf(url: string): string {
    const matched: RegExpMatchArray | null = url.trim().match(/^(https?:\/\/[^\/]+)/i);
    return matched !== null && matched.length > 1 ? matched[1] : '';
  }

  /**
   * 用一份临时配置上传（设置页「测试接口」用）。
   * overrideExtension 非空时强制用这个扩展名发（语音的「mp3 改 mp4」重试走这里）。
   */
  static async uploadWith(config: ImageHostConfig, uri: string,
    overrideExtension: string = ''): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    try {
      // 相册/选择器给的 URI 常常没有扩展名：先读文件头判断真实类型。
      const declaredSize: number = ImageHostService.sizeOf(uri);
      const headBytes: ArrayBuffer = ImageHostService.headBytes(uri, 16);
      const extension: string = overrideExtension.length > 0 ? overrideExtension :
        ImageHostService.normalizeExtension(
          ImageHostService.detectExtension(headBytes, ImageHostService.extensionOf(uri)));
      if (ImageHostService.BLOCKED_TYPES.indexOf(extension) >= 0) {
        result.message = extension + ' 属于可执行/安装包，图床不接受';
        Logger.error('IMAGE_HOST', '拒绝上传可执行文件：' + extension);
        return result;
      }
      if (declaredSize === 0) {
        result.message = '文件内容为空';
        return result;
      }
      if (declaredSize > ImageHostService.NAISHI_MAX_BYTES) {
        result.message = '文件超过 ' + ImageHostService.megaText(ImageHostService.NAISHI_MAX_BYTES) + '，图床不接受';
        return result;
      }
      const target: UploadTarget | undefined = ImageHostService.buildTarget(config, extension, declaredSize);
      if (target === undefined) {
        result.message = '文件类型或体积不符合图床限制（' + extension +
          (declaredSize > 0 ? '，' + ImageHostService.megaText(declaredSize) : '') + '）';
        return result;
      }
      // 配了直传代理就优先走它（原始字节 POST，完全不依赖客户端 multipart）。
      if (target.proxyUrl.length > 0) {
        const proxied: ImageHostResult = await ImageHostService.sendViaProxy(target, uri, extension, declaredSize);
        if (proxied.ok && proxied.url.length > 0) {
          proxied.host = target.label;
          Logger.info('IMAGE_HOST', '上传成功（直传代理），图床=' + target.label);
          return proxied;
        }
        Logger.warn('IMAGE_HOST', '直传代理失败，回退常规送法：' + proxied.message);
      }
      // 依次尝试不同的送法：上次成功的优先，其次 path（curl -F 等价）、base64（表单参数）、data（内存段）。
      // 服务端说「空上传源」才换下一种；base64 对超大文件会直接跳过（见 SKIP_TOKEN）。
      // 视频 / 语音：照 22:21 那版原样执行 —— 先走 filePath，被判空文件时换内存段重试，两种都失败才报错。
      if (!ImageHostService.isImageType(extension)) {
        Logger.info('IMAGE_HOST', '开始上传（视频/语音）：类型=' + extension + '，大小=' +
          (declaredSize > 0 ? ImageHostService.megaText(declaredSize) : '未知'));
        const first: ImageHostResult =
          await ImageHostService.sendTo(target, uri, extension, declaredSize, true);
        if (first.ok && first.url.length > 0) {
          first.host = target.label;
          Logger.info('IMAGE_HOST', '[filePath] 成功 → ' + first.url);
          return first;
        }
        Logger.warn('IMAGE_HOST', '[filePath] 失败：' + (first.message || '无'));
        // 服务端说「空上传源」时换第二种送法（内存 data 段）再试一次，两种都失败才报错。
        if (ImageHostService.isEmptySource(first.message)) {
          Logger.warn('IMAGE_HOST', 'filePath 方式被判空文件，改用内存段重试');
          const retry: ImageHostResult =
            await ImageHostService.sendTo(target, uri, extension, declaredSize, false);
          if (retry.ok && retry.url.length > 0) {
            retry.host = target.label;
            Logger.info('IMAGE_HOST', '内存段方式上传成功');
            return retry;
          }
          result.httpStatus = retry.httpStatus;
          result.notFound = retry.notFound;
          result.message = target.label + '：' + (retry.message || '未知原因');
          Logger.warn('IMAGE_HOST', '内存段方式也失败：' + retry.message);
          // 最后兜底：base64 表单（服务端实测接受视频，且完全不经过 multipart/缓存文件）。
          if (ImageHostService.isVideoType(extension)) {
            const base64Attempt: ImageHostResult =
              await ImageHostService.sendBase64(target, uri, extension, declaredSize);
            // 记录实际送出的字节数，用来区分「我们这边空」还是「服务端收不到」。
            Logger.info('IMAGE_HOST', 'base64 兜底结果：' +
              (base64Attempt.ok ? '成功 → ' + base64Attempt.url : '失败：' + base64Attempt.message));
            if (base64Attempt.ok && base64Attempt.url.length > 0) {
              base64Attempt.host = target.label;
              return base64Attempt;
            }
            result.httpStatus = base64Attempt.httpStatus;
            result.notFound = base64Attempt.notFound;
            result.message = base64Attempt.message;
            return result;
          }
          return result;
        }
        result.httpStatus = first.httpStatus;
        result.notFound = first.notFound;
        result.message = target.label + '：' + (first.message || '未知原因');
        return result;
      }
      let attempt: ImageHostResult = new ImageHostResult();
      const modes: string[] = ImageHostService.modeOrder(extension, declaredSize);
      // 每种送法的结果都写进运行日志，出问题时看日志就能定位，不用再猜。
      Logger.info('IMAGE_HOST', '开始上传：类型=' + extension + '，大小=' +
        (declaredSize > 0 ? ImageHostService.megaText(declaredSize) : '未知') +
        '，送法顺序=' + modes.join('>'));
      for (const mode of modes) {
        if (mode === 'base64') {
          attempt = await ImageHostService.sendBase64(target, uri, extension, declaredSize);
        } else if (mode === 'doc') {
          // 严格照 Chevereto 文档的 curl：-F "source=@file"，只发文件段 + X-API-Key。
          attempt = await ImageHostService.sendDoc(target, uri, extension, declaredSize);
        } else if (mode === 'manual') {
          // 自己拼 multipart body + 显式 boundary（最早那版）。
          attempt = await ImageHostService.sendManual(target, uri, extension, declaredSize);
        } else {
          attempt = await ImageHostService.sendTo(target, uri, extension, declaredSize, mode === 'path');
        }
        if (attempt.ok && attempt.url.length > 0) {
          attempt.host = target.label;
          Logger.info('IMAGE_HOST', '[TRY ' + mode + '] 成功 → ' + attempt.url);
          await ImageHostService.rememberMode(mode);
          return attempt;
        }
        Logger.error('IMAGE_HOST', '[TRY ' + mode + '] 失败：http=' + String(attempt.httpStatus) +
          '，原因=' + (attempt.message || '无'));
        if (attempt.message === ImageHostService.SKIP_TOKEN) {
          Logger.info('IMAGE_HOST', '送法=' + mode + ' 不适用于当前文件，跳过');
          continue;
        }
        if (!ImageHostService.isEmptySource(attempt.message) &&
          !ImageHostService.isUnreadableSource(attempt.message)) {
          break;
        }
        Logger.warn('IMAGE_HOST', '送法=' + mode + ' 不被接受，换下一种');
      }
      if (attempt.message === ImageHostService.SKIP_TOKEN) {
        result.message = '文件太大，没有可用的上传方式';
        return result;
      }
      result.httpStatus = attempt.httpStatus;
      result.notFound = attempt.notFound;
      result.message = target.label + '：' + (attempt.message || '未知原因');
      Logger.warn('IMAGE_HOST', '上传失败，图床=' + target.label + '，原因=' + attempt.message);
      return result;
    } catch (error) {
      // 任何异常都在这里收口：调用方只需要看 ok/url，不处理异常。
      result.message = ImageHostService.errorText(error);
      result.notFound = result.message.indexOf('404') >= 0;
      Logger.error('IMAGE_HOST', '上传流程异常：' + result.message);
      return result;
    }
  }

  /**
   * 构建唯一的奶昔上传目标；类型或体积不符时返回 undefined。
   * size 传 -1 表示读不到文件大小，此时只按类型判断。
   */
  private static buildTarget(config: ImageHostConfig, extension: string, size: number): UploadTarget | undefined {
    if (!ImageHostService.isValidUrl(config.uploadUrl)) { return undefined; }
    if (ImageHostService.NAISHI_TYPES.indexOf(extension) < 0) { return undefined; }
    if (size > 0 && size > ImageHostService.NAISHI_MAX_BYTES) { return undefined; }
    const target: UploadTarget = new UploadTarget();
    target.label = '奶昔图床';
    target.url = config.uploadUrl;
    target.fieldName = config.fieldName;
    target.responsePath = config.responsePath;
    target.allowed = ImageHostService.NAISHI_TYPES;
    target.maxBytes = ImageHostService.NAISHI_MAX_BYTES;
    target.apiKey = config.apiKey;
    target.proxyUrl = config.proxyUrl;
    return target;
  }

  /** 按单个目标组 multipart 并发请求；异常在内部转成失败结果。 */
  private static async sendTo(target: UploadTarget, uri: string, extension: string,
    declaredSize: number, useFilePath: boolean = true): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    let stagedPath: string = '';
    try {
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      // Chevereto 文档里 format 是「表单参数」而不是查询参数：写进 URL 会被判成空文件，
      // 所以这里把地址里的 ?format=xxx 摘出来，改成 multipart 字段发送。
      const split: string[] = ImageHostService.splitFormat(target.url);
      const requestUrl: string = split[0];
      const formFormat: string = split[1];
      const contentType: string = ImageHostService.contentTypeOf(fileName);

      // 用系统的 multipart 组装（multiFormDataList），由 http 模块自己写 boundary 和各段头。
      // 优先用 filePath：让系统按 curl -F 的方式从磁盘流式读文件，少一次内存搬运，
      // 也避开「ArrayBuffer 段被服务端当空文件」的问题；拷不进缓存时才退回 data。
      const parts: http.MultiFormData[] = [];
      if (formFormat.length > 0) {
        parts.push({ name: 'format', contentType: 'text/plain', data: formFormat });
      }
      if (target.apiKey.length > 0) {
        // 文档：API V1 除 X-API-Key 头外，也支持用 key 作为请求参数鉴权。
        // 两个都带上，中间层吃掉自定义头时仍然能通过鉴权。
        parts.push({ name: 'key', contentType: 'text/plain', data: target.apiKey });
      }
      const staged: string = useFilePath ? ImageHostService.stageFile(uri, extension) : '';
      stagedPath = staged;
      if (staged.length > 0) {
        Logger.info('IMAGE_HOST', '文件已缓存：' + staged + '，' + String(fileIo.statSync(staged).size) + ' 字节');
      } else {
        Logger.info('IMAGE_HOST', '未使用缓存文件，改用内存段');
      }
      if (staged.length > 0) {
        parts.push({
          name: target.fieldName,
          contentType: contentType,
          remoteFileName: fileName,
          filePath: staged
        });
      } else {
        let bytes: ArrayBuffer = declaredSize > 0 ?
          ImageHostService.readExact(uri, declaredSize) :
          ImageHostService.readBytes(uri, target.maxBytes);
        if (bytes.byteLength === 0 && declaredSize > 0) {
          bytes = ImageHostService.readBytes(uri, target.maxBytes);
        }
        if (bytes.byteLength === 0) {
          result.message = '读取文件失败：内容为空';
          return result;
        }
        Logger.info('IMAGE_HOST', '内存段字节数=' + String(bytes.byteLength));
        parts.push({
          name: target.fieldName,
          contentType: contentType,
          remoteFileName: fileName,
          data: bytes
        });
      }

      const header: Record<string, string> = {};
      // 不要自己写 Content-Type：系统生成 multipart 时会带 boundary，
      // 手写 `multipart/form-data`（无 boundary）服务端解析不出文件段，实测报 Can't get target upload source info。
      if (target.apiKey.length > 0) {
        // Chevereto 的 API v1 用 X-API-Key 鉴权（也支持 ?key= 查询参数，这里走 header）。
        header['X-API-Key'] = target.apiKey;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        multiFormDataList: parts,
        expectDataType: http.HttpDataType.STRING,
        // 走系统默认协议：22:21 那版视频就是这么传通的，强推 HTTP/1.1 反而把 multipart 弄坏了。
        connectTimeout: 15000,
        readTimeout: 120000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(requestUrl, options);
      result.httpStatus = response.responseCode;
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode === 404) {
        result.notFound = true;
        result.message = '接口 404';
        return result;
      }
      if (response.responseCode === 429) {
        result.message = '限流（HTTP 429）';
        return result;
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = 'HTTP ' + String(response.responseCode) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      // 文档约定：JSON 返回里 status_code / status_txt 才是业务结果，HTTP 200 也可能带错误。
      const bodyStatus: number = ImageHostService.bodyStatusCode(text);
      if (bodyStatus > 0 && bodyStatus !== 200) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = '接口状态 ' + String(bodyStatus) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const picked: string = ImageHostService.extractUrl(text, target.responsePath, extension);
      if (picked.length > 0) {
        result.ok = true;
        result.url = picked;
        ImageHostService.fillExtras(result, text);
        return result;
      }
      const fallback: string = ImageHostService.firstMediaUrl(text);
      if (fallback.length > 0) {
        result.ok = true;
        result.url = fallback;
        return result;
      }
      const emptyDetail: string = ImageHostService.failureDetail(text);
      result.message = '返回里没有直链' + (emptyDetail.length > 0 ? '（' + emptyDetail + '）' : '');
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      result.notFound = result.message.indexOf('404') >= 0;
      return result;
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
      ImageHostService.dropStaged(stagedPath);
    }
  }

  /**
   * 把待上传文件拷一份到缓存目录，交给系统的 multipart 按 filePath 读取。
   *
   * 注意：不能再依赖 copyFileSync(fd → path)——在真机上它可能"成功"但目标文件是 0 字节，
   * 服务端就会回 `Can't get target upload source info`（读不到源文件信息）。
   * 这里改成显式读字节 + 写文件，并核对落盘大小；对不上就返回空串，让调用方退回内存段。
   */
  private static stageFile(uri: string, extension: string): string {
    const context: common.UIAbilityContext | undefined = ImageHostService.context;
    if (context === undefined) { return ''; }
    const targetPath: string = context.cacheDir + '/upload_' + String(Date.now()) +
      String(Math.floor(Math.random() * 1000)) + extension;
    let source: fileIo.File | undefined = undefined;
    let out: fileIo.File | undefined = undefined;
    try {
      const bytes: ArrayBuffer = ImageHostService.readBytes(uri, ImageHostService.NAISHI_MAX_BYTES);
      if (bytes.byteLength === 0) { return ''; }
      out = fileIo.openSync(targetPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(out.fd, bytes);
      fileIo.closeSync(out);
      out = undefined;
      const written: number = fileIo.statSync(targetPath).size;
      if (written !== bytes.byteLength) {
        Logger.warn('IMAGE_HOST', '缓存文件大小不一致：写入 ' + String(written) + '，期望 ' + String(bytes.byteLength));
        ImageHostService.dropStaged(targetPath);
        return '';
      }
      return targetPath;
    } catch (error) {
      Logger.warn('IMAGE_HOST', '缓存待上传文件失败，改用内存上传：' + String(error));
      ImageHostService.dropStaged(targetPath);
      return '';
    } finally {
      if (source !== undefined) {
        try { fileIo.closeSync(source); } catch (_) { /* 忽略 */ }
      }
      if (out !== undefined) {
        try { fileIo.closeSync(out); } catch (_) { /* 忽略 */ }
      }
    }
  }

  /** 依次要尝试的送法：上次成功的排最前；base64 对图片和视频都可用（实测视频 base64 能通）。 */
  private static modeOrder(extension: string, size: number): string[] {
    const base64Usable: boolean = ImageHostService.supportsBase64(extension) &&
      (size <= 0 || size <= ImageHostService.NAISHI_MAX_BYTES);
    // 图片：保持现状（path → base64 → manual → data）。
    // 视频：base64 优先（实测可用，50MB 以内）；语音：音频 base64 会被拒，走 multipart。
    let all: string[] = [];
    if (ImageHostService.isImageType(extension)) {
      all = ['path', 'base64', 'manual', 'data'];
    } else if (ImageHostService.isVideoType(extension)) {
      all = ['base64', 'path', 'data', 'manual'];
    } else {
      all = ['path', 'data', 'doc', 'manual'];
    }
    const usable: string[] = all.filter((mode: string) => mode !== 'base64' || base64Usable);
    const first: string = ImageHostService.lastGoodMode;
    if (first.length === 0 || usable.indexOf(first) < 0) { return usable; }
    return [first].concat(usable.filter((mode: string) => mode !== first));
  }

  /** base64 送法支持的类型：图片 + 视频（音频实测会被服务端拒，走 multipart）。 */
  private static supportsBase64(extension: string): boolean {
    return ImageHostService.isImageType(extension) || ImageHostService.isVideoType(extension);
  }

  private static isImageType(extension: string): boolean {
    const images: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
    return images.indexOf(extension) >= 0;
  }

  private static isVideoType(extension: string): boolean {
    const videos: string[] = ['.mp4', '.m4v', '.mov', '.webm'];
    return videos.indexOf(extension) >= 0;
  }

  private static async rememberMode(mode: string): Promise<void> {
    if (ImageHostService.lastGoodMode === mode) { return; }
    ImageHostService.lastGoodMode = mode;
    try {
      if (ImageHostService.store !== undefined) {
        await ImageHostService.store.put(ImageHostService.KEY_MODE, mode);
        await ImageHostService.store.flush();
      }
    } catch (error) {
      Logger.warn('IMAGE_HOST', '记录上传送法失败：' + String(error));
    }
  }

  /**
   * base64 送法：把文件编码成 base64 塞进 source 表单参数（application/x-www-form-urlencoded）。
   * Chevereto 文档写明 source 支持 base64；实测这样绕开了鸿蒙 multipart 的坑。
   */
  private static async sendBase64(target: UploadTarget, uri: string, extension: string,
    declaredSize: number): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    try {
      const bytes: ArrayBuffer = declaredSize > 0 ?
        ImageHostService.readExact(uri, declaredSize) :
        ImageHostService.readBytes(uri, target.maxBytes);
      if (bytes.byteLength === 0) {
        result.message = '读取文件失败：内容为空';
        return result;
      }
      // 大文件不走 base64：编码后体积膨胀，服务端也会解不开（Can't get target upload source info）。
      if (bytes.byteLength > ImageHostService.BASE64_MAX_BYTES) {
        result.message = ImageHostService.SKIP_TOKEN;
        return result;
      }
      const encoded: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
      const split: string[] = ImageHostService.splitFormat(target.url);
      let body: string = 'source=' + encodeURIComponent(encoded);
      if (target.apiKey.length > 0) {
        body += '&key=' + encodeURIComponent(target.apiKey);
      }
      if (split[1].length > 0) {
        body += '&format=' + encodeURIComponent(split[1]);
      }
      const header: Record<string, string> = {};
      header['Content-Type'] = 'application/x-www-form-urlencoded';
      if (target.apiKey.length > 0) {
        header['X-API-Key'] = target.apiKey;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        connectTimeout: 15000,
        readTimeout: 120000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(split[0], options);
      result.httpStatus = response.responseCode;
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = 'HTTP ' + String(response.responseCode) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const picked: string = ImageHostService.extractUrl(text, target.responsePath, extension);
      if (picked.length > 0) {
        result.ok = true;
        result.url = picked;
        ImageHostService.fillExtras(result, text);
        return result;
      }
      const fallback: string = ImageHostService.firstMediaUrl(text);
      if (fallback.length > 0) {
        result.ok = true;
        result.url = fallback;
        return result;
      }
      const detail: string = ImageHostService.failureDetail(text);
      result.message = '返回里没有直链' + (detail.length > 0 ? '（' + detail + '）' : '');
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  private static dropStaged(path: string): void {
    if (path.length === 0) { return; }
    try { fileIo.unlinkSync(path); } catch (_) { /* 忽略 */ }
  }

  /** 服务端把文件判成空（Chevereto 的 "Empty upload source"）。 */
  private static isEmptySource(message: string): boolean {
    const text: string = (message || '').toLowerCase();
    return text.indexOf('empty upload source') >= 0 || text.indexOf('empty source') >= 0;
  }

  /** 服务端收到了 source 但解不开（base64 送法遇到音视频时会这样）。 */
  private static isUnreadableSource(message: string): boolean {
    const text: string = (message || '').toLowerCase();
    return text.indexOf("can't get target upload source") >= 0 ||
      text.indexOf('cannot get target upload source') >= 0;
  }

  /**
   * 直传代理：把文件原始字节 POST 给代理，由服务端转发到图床并回传直链。
   * 请求形态最简单（octet-stream + X-File-Name 头），不经过 multipart，视频/音频也能过。
   */
  private static async sendViaProxy(target: UploadTarget, uri: string, extension: string,
    declaredSize: number): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    try {
      const bytes: ArrayBuffer = declaredSize > 0 ?
        ImageHostService.readExact(uri, declaredSize) :
        ImageHostService.readBytes(uri, target.maxBytes);
      if (bytes.byteLength === 0) {
        result.message = '读取文件失败：内容为空';
        return result;
      }
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      const header: Record<string, string> = {};
      header['Content-Type'] = 'application/octet-stream';
      header['X-File-Name'] = fileName;
      if (target.apiKey.length > 0) {
        header['X-API-Key'] = target.apiKey;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: bytes,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        connectTimeout: 15000,
        readTimeout: 120000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(target.proxyUrl, options);
      result.httpStatus = response.responseCode;
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = 'HTTP ' + String(response.responseCode) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const picked: string = ImageHostService.pickUrl(text, 'url');
      if (picked.length > 0) {
        result.ok = true;
        result.url = picked;
        ImageHostService.fillExtras(result, text);
        return result;
      }
      const plain: string = ImageHostService.plainUrl(text);
      if (plain.length > 0) {
        result.ok = true;
        result.url = plain;
        return result;
      }
      const fallback: string = ImageHostService.firstMediaUrl(text);
      if (fallback.length > 0) {
        result.ok = true;
        result.url = fallback;
        return result;
      }
      const detail: string = ImageHostService.failureDetail(text);
      result.message = '代理返回里没有直链' + (detail.length > 0 ? '（' + detail + '）' : '');
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  /**
   * 手拼 multipart：自己写 boundary、各段头和 body，再用 extraData 发出去。
   * 这是最早那版实现，视频用它上传成功过，所以保留成一种送法。
   */
  private static async sendManual(target: UploadTarget, uri: string, extension: string,
    declaredSize: number): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    try {
      const bytes: ArrayBuffer = declaredSize > 0 ?
        ImageHostService.readExact(uri, declaredSize) :
        ImageHostService.readBytes(uri, target.maxBytes);
      if (bytes.byteLength === 0) {
        result.message = '读取文件失败：内容为空';
        return result;
      }
      const boundary: string = '----WuyinUpload' + String(Date.now()) + String(Math.floor(Math.random() * 100000));
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      const split: string[] = ImageHostService.splitFormat(target.url);
      let headText: string = '';
      if (split[1].length > 0) {
        headText += '--' + boundary + '\r\nContent-Disposition: form-data; name="format"\r\n\r\n' + split[1] + '\r\n';
      }
      if (target.apiKey.length > 0) {
        headText += '--' + boundary + '\r\nContent-Disposition: form-data; name="key"\r\n\r\n' + target.apiKey + '\r\n';
      }
      headText += '--' + boundary + '\r\n' +
        'Content-Disposition: form-data; name="' + target.fieldName + '"; filename="' + fileName + '"\r\n' +
        'Content-Type: ' + ImageHostService.contentTypeOf(fileName) + '\r\n\r\n';
      const tailText: string = '\r\n--' + boundary + '--\r\n';
      const head: Uint8Array = new util.TextEncoder().encodeInto(headText);
      const tail: Uint8Array = new util.TextEncoder().encodeInto(tailText);
      const body: Uint8Array = new Uint8Array(head.length + bytes.byteLength + tail.length);
      body.set(head, 0);
      body.set(new Uint8Array(bytes), head.length);
      body.set(tail, head.length + bytes.byteLength);

      const header: Record<string, string> = {};
      header['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
      if (target.apiKey.length > 0) {
        header['X-API-Key'] = target.apiKey;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body.buffer,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        connectTimeout: 15000,
        readTimeout: 120000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(split[0], options);
      result.httpStatus = response.responseCode;
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = 'HTTP ' + String(response.responseCode) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const picked: string = ImageHostService.extractUrl(text, target.responsePath, extension);
      if (picked.length > 0) {
        result.ok = true;
        result.url = picked;
        ImageHostService.fillExtras(result, text);
        return result;
      }
      const fallback: string = ImageHostService.firstMediaUrl(text);
      if (fallback.length > 0) {
        result.ok = true;
        result.url = fallback;
        return result;
      }
      const detail: string = ImageHostService.failureDetail(text);
      result.message = '返回里没有直链' + (detail.length > 0 ? '（' + detail + '）' : '');
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  /**
   * 严格按 Chevereto 文档的调用形态发一次：
   *   POST /api/1/upload
   *   X-API-Key: <key>
   *   -F "source=@file"
   * 也就是 multipart 里只放一个文件段，不带 format/key 等附加字段，避免 PHP 侧解析差异。
   * 视频 / 语音走这条。
   */
  private static async sendDoc(target: UploadTarget, uri: string, extension: string,
    declaredSize: number): Promise<ImageHostResult> {
    const result: ImageHostResult = new ImageHostResult();
    let request: http.HttpRequest | undefined = undefined;
    let stagedPath: string = '';
    try {
      const fileName: string = 'wuyin_' + String(Date.now()) + extension;
      const contentType: string = ImageHostService.contentTypeOf(fileName);
      const part: http.MultiFormData = {
        name: target.fieldName,
        contentType: contentType,
        remoteFileName: fileName
      };
      const staged: string = ImageHostService.stageFile(uri, extension);
      stagedPath = staged;
      if (staged.length > 0) {
        part.filePath = staged;
      } else {
        const bytes: ArrayBuffer = declaredSize > 0 ?
          ImageHostService.readExact(uri, declaredSize) :
          ImageHostService.readBytes(uri, target.maxBytes);
        if (bytes.byteLength === 0) {
          result.message = '读取文件失败：内容为空';
          return result;
        }
        part.data = bytes;
      }
      const header: Record<string, string> = {};
      if (target.apiKey.length > 0) {
        header['X-API-Key'] = target.apiKey;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        multiFormDataList: [part],
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 180000
      };
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(target.url, options);
      result.httpStatus = response.responseCode;
      const text: string = typeof response.result === 'string' ? String(response.result) : '';
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = 'HTTP ' + String(response.responseCode) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const bodyStatus: number = ImageHostService.bodyStatusCode(text);
      if (bodyStatus > 0 && bodyStatus !== 200) {
        const detail: string = ImageHostService.failureDetail(text);
        result.message = '接口状态 ' + String(bodyStatus) + (detail.length > 0 ? '（' + detail + '）' : '');
        return result;
      }
      const picked: string = ImageHostService.pickUrl(text, target.responsePath);
      if (picked.length > 0) {
        result.ok = true;
        result.url = picked;
        ImageHostService.fillExtras(result, text);
        return result;
      }
      const fallback: string = ImageHostService.firstMediaUrl(text);
      if (fallback.length > 0) {
        result.ok = true;
        result.url = fallback;
        return result;
      }
      const detail: string = ImageHostService.failureDetail(text);
      result.message = '返回里没有直链' + (detail.length > 0 ? '（' + detail + '）' : '');
      return result;
    } catch (error) {
      result.message = ImageHostService.errorText(error);
      return result;
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
      ImageHostService.dropStaged(stagedPath);
    }
  }

  /** 文件大小；读不到（媒体 URI 不支持 stat）返回 -1。 */
  private static sizeOf(uri: string): number {
    try {
      const stat: fileIo.Stat = fileIo.statSync(uri);
      const size: number = stat.size;
      return Number.isFinite(size) && size > 0 ? size : 0;
    } catch (_) {
      return -1;
    }
  }

  /** 只读文件头若干字节，用于识别真实类型。 */
  private static headBytes(uri: string, length: number): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fileIo.readSync(file.fd, buffer, { offset: 0, length: length });
    } catch (_) {
      // 读不到文件头就只按扩展名判断
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_) { /* 忽略关闭错误 */ }
      }
    }
    return buffer;
  }

  /** 把文件内容读进已有缓冲区的指定区间，避免为大文件再复制一份。 */
  private static readInto(uri: string, buffer: ArrayBuffer, start: number, length: number): void {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      let read: number = 0;
      while (read < length) {
        const received: number = fileIo.readSync(file.fd, buffer, {
          offset: start + read,
          length: length - read
        });
        if (received <= 0) { break; }
        read += received;
      }
    } finally {
      try { fileIo.closeSync(file); } catch (_) { /* 关闭失败不影响结果 */ }
    }
  }

  /** 文件大小已知时按精确大小读一份，交给系统的 multipart 组装。 */
  private static readExact(uri: string, size: number): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    ImageHostService.readInto(uri, buffer, 0, size);
    return buffer;
  }

  private static readBytes(uri: string, maxBytes: number): ArrayBuffer {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      let buffer: ArrayBuffer = new ArrayBuffer(256 * 1024);
      let total: number = 0;
      while (total < buffer.byteLength) {
        const received: number = fileIo.readSync(file.fd, buffer, {
          offset: total,
          length: buffer.byteLength - total
        });
        if (received <= 0) { break; }
        total += received;
        if (total > maxBytes) {
          throw new Error('文件超过 ' + ImageHostService.megaText(maxBytes) + '，图床不接受');
        }
        if (total === buffer.byteLength) {
          const grown: ArrayBuffer = new ArrayBuffer(buffer.byteLength * 2);
          new Uint8Array(grown).set(new Uint8Array(buffer), 0);
          buffer = grown;
        }
      }
      return buffer.slice(0, total);
    } finally {
      try { fileIo.closeSync(file); } catch (_) { /* 关闭失败不影响结果 */ }
    }
  }

  private static megaText(bytes: number): string {
    const mega: number = Math.round(bytes / (1024 * 1024) * 10) / 10;
    return String(mega) + 'MB';
  }

  private static extensionOf(uri: string): string {
    const clean: string = uri.split('?')[0];
    const dot: number = clean.lastIndexOf('.');
    if (dot < 0) { return ''; }
    const extension: string = clean.substring(dot).toLowerCase();
    return extension.length <= 6 ? extension : '';
  }

  /** 按文件头判断真实类型；认不出时返回 URI 后缀（可能为空）。 */
  private static detectExtension(bytes: ArrayBuffer, fallback: string): string {
    try {
      const length: number = Math.min(bytes.byteLength, 16);
      const head: Uint8Array = new Uint8Array(bytes, 0, length);
      const tag = (start: number, count: number): string => {
        if (head.length < start + count) { return ''; }
        let text: string = '';
        for (let index: number = 0; index < count; index++) {
          text += String.fromCharCode(head[start + index]);
        }
        return text;
      };
      // mp4 / mov / m4a：偏移 4 处的 ftyp 盒，品牌在 8 处
      if (tag(4, 4) === 'ftyp') {
        const brand: string = tag(8, 4);
        if (brand === 'qt  ') { return '.mov'; }
        // M4A / mp42 / mp41 / isom 本质上都是 MP4 容器，统一按 .mp4 传，
        // 和录音时用的 CFT_MPEG_4 + AAC 保持一致。
        return '.mp4';
      }
      if (head.length >= 3 && head[0] === 0xFF && head[1] === 0xD8 && head[2] === 0xFF) { return '.jpg'; }
      if (head.length >= 4 && head[0] === 0x89 && tag(1, 3) === 'PNG') { return '.png'; }
      if (tag(0, 4) === 'GIF8') { return '.gif'; }
      if (tag(0, 4) === 'RIFF') {
        if (tag(8, 4) === 'WEBP') { return '.webp'; }
        if (tag(8, 4) === 'WAVE') { return '.wav'; }
      }
      if (head.length >= 4 && head[0] === 0x1A && head[1] === 0x45 && head[2] === 0xDF && head[3] === 0xA3) {
        return '.webm';
      }
      if (tag(0, 3) === 'ID3') { return '.mp3'; }
      if (head.length >= 2 && head[0] === 0xFF && (head[1] & 0xE0) === 0xE0) { return '.mp3'; }
      if (tag(0, 4) === 'OggS') { return '.ogg'; }
      if (tag(0, 4) === 'fLaC') { return '.flac'; }
      if (tag(0, 4) === '%PDF') { return '.pdf'; }
      if (head.length >= 2 && head[0] === 0x50 && head[1] === 0x4B) { return '.zip'; }
    } catch (_) {
      // 探测失败就只看扩展名
    }
    return fallback.length > 0 ? fallback : '.jpg';
  }

  private static contentTypeOf(fileName: string): string {
    const name: string = fileName.toLowerCase();
    if (name.endsWith('.png')) { return 'image/png'; }
    if (name.endsWith('.gif')) { return 'image/gif'; }
    if (name.endsWith('.webp')) { return 'image/webp'; }
    if (name.endsWith('.bmp')) { return 'image/bmp'; }
    if (name.endsWith('.heic') || name.endsWith('.heif')) { return 'image/heic'; }
    if (name.endsWith('.mp4')) { return 'video/mp4'; }
    if (name.endsWith('.webm')) { return 'video/webm'; }
    if (name.endsWith('.mov')) { return 'video/quicktime'; }
    if (name.endsWith('.mp3')) { return 'audio/mpeg'; }
    if (name.endsWith('.wav')) { return 'audio/wav'; }
    if (name.endsWith('.flac')) { return 'audio/flac'; }
    if (name.endsWith('.m4a')) { return 'audio/mp4'; }
    if (name.endsWith('.ogg')) { return 'audio/ogg'; }
    if (name.endsWith('.txt')) { return 'text/plain'; }
    if (name.endsWith('.pdf')) { return 'application/pdf'; }
    if (name.endsWith('.zip')) { return 'application/zip'; }
    return 'application/octet-stream';
  }

  private static shortText(body: string): string {
    const text: string = body.replace(/\s+/g, ' ').trim();
    return text.length > 120 ? text.substring(0, 120) + '…' : text;
  }

  /** 把接口错误返回压成一句人话：优先取 JSON 里的 message，取不到才截断原文。 */
  private static failureDetail(body: string): string {
    const text: string = body.trim();
    if (text.length === 0) { return ''; }
    try {
      const record: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const direct: string[] = ['message', 'msg', 'error_desc'];
      for (const key of direct) {
        const value: Object | undefined = record[key];
        if (typeof value === 'string') {
          const text2: string = String(value).trim();
          if (text2.length > 0 && text2.length <= 60) { return text2; }
        }
      }
      // 常见嵌套：{"error":{"message":"No action provided"}}，比 status_txt 更能说明原因
      const nested: Object | undefined = record['error'];
      if (nested !== undefined && nested !== null && typeof nested === 'object') {
        const inner: Record<string, Object> = nested as Record<string, Object>;
        const innerMessage: Object | undefined = inner['message'];
        if (typeof innerMessage === 'string') {
          const text2: string = String(innerMessage).trim();
          if (text2.length > 0 && text2.length <= 60) { return text2; }
        }
      }
      const status: Object | undefined = record['status_txt'];
      if (typeof status === 'string') {
        const text2: string = String(status).trim();
        if (text2.length > 0 && text2.length <= 60) { return text2; }
      }
    } catch (_) {
      // 非 JSON：走截断
    }
    return ImageHostService.shortText(text);
  }

  /** 异常转人话：BusinessError 这类对象 String() 会变成 "[object Object]"，要显式取 code/message。 */
  private static errorText(error: Object | undefined): string {
    if (error === undefined || error === null) { return '未知错误'; }
    if (typeof error === 'string') { return String(error); }
    try {
      const record: Record<string, Object> = error as Record<string, Object>;
      const message: Object | undefined = record['message'];
      const code: Object | undefined = record['code'];
      if (typeof message === 'string' && String(message).length > 0) {
        const text: string = String(message);
        return (typeof code === 'number' || typeof code === 'string') ?
          text + '（' + String(code) + '）' : text;
      }
      if (typeof code === 'number' || typeof code === 'string') {
        return '连接失败（错误码 ' + String(code) + '）';
      }
    } catch (_) {
      // 继续走兜底
    }
    const text: string = String(error);
    return text === '[object Object]' ? '连接失败' : text;
  }

  /** 纯文本直链接口：整段返回就是一个 URL（配合 format=txt）。 */
  private static plainUrl(body: string): string {
    const text: string = body.trim();
    return /^https?:\/\/\S+$/i.test(text) ? text : '';
  }

  /** 取出地址里的 format 参数并返回 [去掉该参数的地址, format 值]。 */
  private static splitFormat(url: string): string[] {
    const index: number = url.indexOf('?');
    if (index < 0) { return [url, '']; }
    const base: string = url.substring(0, index);
    const parts: string[] = url.substring(index + 1).split('&').filter((item: string) => item.length > 0);
    const kept: string[] = [];
    let format: string = '';
    for (const part of parts) {
      if (part.indexOf('format=') === 0) {
        format = part.substring('format='.length).trim();
      } else {
        kept.push(part);
      }
    }
    const clean: string = kept.length > 0 ? base + '?' + kept.join('&') : base;
    return [clean, format];
  }

  /** 读 JSON 里的 status_code；不是 JSON 或没有该字段返回 -1。 */
  private static bodyStatusCode(body: string): number {
    const text: string = body.trim();
    if (text.length === 0 || text.indexOf('{') !== 0) { return -1; }
    try {
      const record: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const value: Object | undefined = record['status_code'];
      if (typeof value === 'number') { return Number(value); }
      if (typeof value === 'string') {
        const parsed: number = Number(value);
        return Number.isFinite(parsed) ? parsed : -1;
      }
    } catch (_) {
      return -1;
    }
    return -1;
  }

  /**
   * 从响应里取直链。
   * 视频 / 语音固定按 Chevereto 文档读 `image.url`（视频响应里的 mp4 直链），
   * 不管设置页里填的返回路径是什么；图片沿用配置里的返回路径。
   */
  private static extractUrl(text: string, responsePath: string, extension: string): string {
    if (text.length === 0) { return ''; }
    if (!ImageHostService.isImageType(extension)) {
      const docUrl: string = ImageHostService.pickUrl(text, 'image.url');
      if (docUrl.length > 0) { return docUrl; }
    }
    if (responsePath.length === 0) { return ImageHostService.plainUrl(text); }
    return ImageHostService.pickUrl(text, responsePath);
  }

  /**
   * 成功后再从响应里补两个视频字段：
   * `image.display_url`（封面帧 jpeg）和 `image.duration`（秒）。
   * 图片/语音没有这两个字段，取不到就保持空/0。
   */
  private static fillExtras(result: ImageHostResult, text: string): void {
    if (text.length === 0) { return; }
    try {
      const root: Object = JSON.parse(text) as Object;
      let poster: string = ImageHostService.urlAt(root, 'image.display_url');
      if (poster.length === 0) { poster = ImageHostService.urlAt(root, 'image.frame.url'); }
      if (poster.length === 0) { poster = ImageHostService.urlAt(root, 'image.thumb.url'); }
      result.poster = poster;
      const durationNode: Object | undefined = ImageHostService.walk(root, 'image.duration');
      const seconds: number = Number(durationNode);
      result.durationSec = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
    } catch (_) {
      // 响应不是 JSON（纯文本模式）就什么都不补。
    }
  }

  private static pickUrl(body: string, path: string): string {
    if (body.length === 0) { return ''; }
    try {
      const root: Object = JSON.parse(body) as Object;
      const primary: string = ImageHostService.urlAt(root, path);
      if (primary.length > 0) { return primary; }
      // 返回结构兜底：Chevereto（image.url）、Lsky/其它常见位置都试一遍。
      const alternates: string[] = ['image.url', 'image.image.url', 'image.display_url', 'data.url', 'data.links.url', 'url', 'url_full'];
      for (const alternate of alternates) {
        if (alternate === path) { continue; }
        const found: string = ImageHostService.urlAt(root, alternate);
        if (found.length > 0) { return found; }
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  private static urlAt(root: Object, path: string): string {
    if (path.length === 0) { return ''; }
    const value: Object | undefined = ImageHostService.walk(root, path);
    if (value === undefined || value === null) { return ''; }
    if (typeof value === 'string') {
      const text: string = String(value).trim();
      return /^https?:\/\//i.test(text) ? text : '';
    }
    return '';
  }

  private static walk(node: Object, path: string): Object | undefined {
    const segments: string[] = path.split('.').filter((item: string) => item.length > 0);
    let cursor: Object | undefined = node;
    for (const segment of segments) {
      if (cursor === undefined || cursor === null) { return undefined; }
      const record: Record<string, Object> = cursor as Record<string, Object>;
      cursor = record[segment];
    }
    return cursor;
  }

  /** 兜底：从返回里找第一个媒体直链。 */
  private static firstMediaUrl(body: string): string {
    const matched: RegExpMatchArray | null = body.match(
      /https?:\/\/[^\s"'<>\\]+?\.(?:jpg|jpeg|png|webp|gif|bmp|heic|heif|mp4|webm|mov|mp3|wav|flac|m4a|ogg|txt|pdf|zip)/i);
    return matched === null ? '' : matched[0];
  }
}

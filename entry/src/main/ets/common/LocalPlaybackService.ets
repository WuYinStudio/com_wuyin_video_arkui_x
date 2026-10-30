import { common } from '@kit.AbilityKit';
import { fileIo, storageStatistics } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { PlatformApi } from './compat/PlatformApi';

class OfflinePart {
  localPath: string = '';
  keyPath: string = '';
  ivHex: string = '';
  sequence: number = 0;
}

class OfflinePlan {
  parts: OfflinePart[] = [];
  fragmentedMp4: boolean = false;
  estimatedBytes: number = 0;
}

// 只读取应用私有文件。离线 HLS 转成本地媒体文件后交给 AVPlayer.fdSrc，
// 不把 file:// 清单交给 URL/网络分支，也不启动解析、鉴权或网络请求。
export class LocalPlaybackService {
  private static fileFailure(localPath: string, caught: BusinessError, fallback: string): Error {
    const details: string = caught.message || '';
    const error401: boolean = caught.code === 401 || /\b401\b/.test(details);
    Logger.error('PLAYER_LOCAL', '资源类型=local，路径=' + localPath +
    (typeof caught.code === 'number' ? '，错误码=' + caught.code : '') +
    (error401 ? '，401异常，本地文件未发起远程鉴权' : '，本地文件校验或准备异常'));
    const notice: string = error401 ? '本地视频文件无法读取（错误码401），请检查文件完整性、访问权限或重新下载' :
      (/^(本地|离线|当前离线)/.test(details) ? details : fallback);
    // 保留文件 API 的原始错误码，播放器及下载入口仍能识别并记录 401。
    const failure: BusinessError = new Error(notice) as BusinessError;
    if (typeof caught.code === 'number') { failure.code = caught.code; }
    else if (error401) { failure.code = 401; }
    return failure;
  }

  static checkedPath(source: string, context: common.UIAbilityContext): string {
    let candidate: string = source.trim();
    try {
      if (/^file:\/\//i.test(candidate)) { candidate = decodeURIComponent(candidate.substring(7)); }
      if (!candidate.startsWith('/') || /[\u0000?#]/.test(candidate)) {
        throw new Error('本地视频路径无效，请重新下载');
      }
      const segments: string[] = [];
      for (const segment of candidate.split('/')) {
        if (!segment || segment === '.') { continue; }
        if (segment === '..') { segments.pop(); } else { segments.push(segment); }
      }
      const normalized: string = '/' + segments.join('/');
      const privateRoot: string = context.filesDir.replace(/\/+$/, '') + '/';
      if (!context.filesDir.startsWith('/') || privateRoot === '/') {
        throw new Error('本地视频目录不可用，请退出播放页后重试');
      }
      if (!normalized.startsWith(privateRoot)) { throw new Error('本地视频不在应用私有目录，无法读取'); }
      return normalized;
    } catch (error) {
      // 无效 URI 编码或目录异常同样转为本地提示，绝不回退至网络地址。
      throw LocalPlaybackService.fileFailure(candidate, error as BusinessError, '本地视频路径无效，请重新下载');
    }
  }

  static checkedSize(localPath: string): number {
    try {
      if (!fileIo.accessSync(localPath)) { throw new Error('本地视频或分片已丢失，请重新下载'); }
      const info: fileIo.Stat = fileIo.statSync(localPath);
      if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
        throw new Error('本地视频或分片为空或大小无效，请重新下载');
      }
      return info.size;
    } catch (error) {
      throw LocalPlaybackService.fileFailure(localPath, error as BusinessError,
        '本地视频或分片无法读取，请检查文件权限或重新下载');
    }
  }

  private static openReadablePath(localPath: string): fileIo.File {
    let opened: fileIo.File | undefined;
    try {
      LocalPlaybackService.checkedSize(localPath);
      opened = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
      // access/stat 成功并不保证可读；以明确偏移读取验证权限及文件内容。
      // 调用方使用 fdSrc 的 offset=0 或显式偏移读取，不依赖句柄当前位置。
      const probe = new ArrayBuffer(1);
      const count: number = fileIo.readSync(opened.fd, probe, { offset: 0, length: 1 });
      if (count !== 1) { throw new Error('本地视频或分片无法读取，请重新下载'); }
      return opened;
    } catch (error) {
      if (opened) {
        try { fileIo.closeSync(opened); }
        catch (closeError) {
          Logger.warn('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，关闭校验句柄失败：' + String(closeError));
        }
      }
      throw LocalPlaybackService.fileFailure(localPath, error as BusinessError,
        '本地视频或分片无法读取，请检查文件权限或重新下载');
    }
  }

  // 下载入口与播放器共用此入口。返回的句柄由调用方在播放器释放后关闭。
  // 仅接收应用私有目录的本地路径，不解析远程地址，也不请求鉴权。
  static openFile(source: string, context: common.UIAbilityContext): fileIo.File {
    const localPath: string = LocalPlaybackService.checkedPath(source, context);
    Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，校验本地文件可读性，跳过远程鉴权');
    const opened: fileIo.File = LocalPlaybackService.openReadablePath(localPath);
    Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，本地文件校验通过，使用文件描述符');
    return opened;
  }

  // 合并缓存不在 filesDir，使用单独的严格入口，不放宽下载文件的目录校验。
  // 只接受本服务在当前应用 cacheDir 根目录生成的媒体文件，路由不能传入任意缓存。
  static openPreparedFile(source: string, context: common.UIAbilityContext): fileIo.File {
    const localPath: string = source.trim();
    try {
      const cacheRoot: string = context.cacheDir.replace(/\/+$/, '') + '/';
      if (!context.cacheDir.startsWith('/') || cacheRoot === '/' || !localPath.startsWith(cacheRoot)) {
        throw new Error('本地播放缓存目录无效，请退出播放页后重试');
      }
      const fileName: string = localPath.substring(cacheRoot.length);
      if (!/^wuyin_offline_playback_[a-z0-9_]+\.(?:ts|mp4)$/.test(fileName)) {
        throw new Error('本地播放缓存路径无效，请重新打开视频');
      }
      Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，校验离线合并缓存可读性，不发起远程鉴权');
      const opened: fileIo.File = LocalPlaybackService.openReadablePath(localPath);
      Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + localPath + '，离线缓存校验通过，使用文件描述符');
      return opened;
    } catch (error) {
      throw LocalPlaybackService.fileFailure(localPath, error as BusinessError,
        '本地播放缓存无法读取，请检查存储空间或重新打开视频');
    }
  }

  private static assetPath(address: string, manifestPath: string, context: common.UIAbilityContext): string {
    const target: string = address.trim();
    if (!target || target.startsWith('//') || (/^[a-z][a-z0-9+.-]*:/i.test(target) && !/^file:\/\//i.test(target))) {
    throw new Error('离线清单包含远程或无效资源，请重新下载');
  }
  const directory: string = manifestPath.substring(0, manifestPath.lastIndexOf('/') + 1);
  const localPath: string = LocalPlaybackService.checkedPath(target.startsWith('/') || /^file:\/\//i.test(target) ? target : directory + target, context);
  LocalPlaybackService.checkedSize(localPath);
  return localPath;
}

private static parse(manifestPath: string, context: common.UIAbilityContext): OfflinePlan {
  if (LocalPlaybackService.checkedSize(manifestPath) > 2 * 1024 * 1024) {
    throw new Error('离线播放清单过大，请重新下载');
  }
  const text: string = fileIo.readTextSync(manifestPath).replace(/^\uFEFF/, '').trim();
  if (!text.startsWith('#EXTM3U') || !text.includes('#EXT-X-ENDLIST')) {
    throw new Error('离线播放清单不完整，请重新下载');
  }
  if (/#EXT-X-STREAM-INF:|#EXT-X-BYTERANGE:|#EXT-X-GAP(?:\r?\n|$)/.test(text)) {
    throw new Error('离线清单不是完整分片清单，请更换线路重新下载');
  }
  const plan = new OfflinePlan();
  let keyPath: string = '';
  let ivHex: string = '';
  let sequence: number = 0;
  let mediaCount: number = 0;
  let lastMap: string = '';
  for (const entry of text.split(/\r?\n/)) {
    const line: string = entry.trim();
    if (!line) { continue; }
    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      sequence = Number(line.substring(line.indexOf(':') + 1));
      if (!Number.isSafeInteger(sequence) || sequence < 0) { throw new Error('离线清单分片序号无效，请重新下载'); }
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      const method = /(?:^|,)METHOD=([^,\s]+)/.exec(line.substring(line.indexOf(':') + 1));
      if (!method) { throw new Error('离线清单加密信息缺失，请重新下载'); }
      if (method[1] === 'NONE') { keyPath = ''; ivHex = ''; continue; }
      if (method[1] !== 'AES-128') { throw new Error('当前离线视频使用不支持的受保护加密方式，请更换线路'); }
      const format = /(?:^|,)KEYFORMAT="([^"]+)"/.exec(line.substring(line.indexOf(':') + 1));
      if (format && format[1] !== 'identity') { throw new Error('当前离线视频密钥依赖远程服务，请更换线路'); }
      const uri = /URI="([^"]+)"/.exec(line);
      if (!uri) { throw new Error('离线视频密钥文件缺失，请重新下载'); }
      keyPath = LocalPlaybackService.assetPath(uri[1], manifestPath, context);
      if (LocalPlaybackService.checkedSize(keyPath) !== 16) { throw new Error('离线视频密钥文件不完整，请重新下载'); }
      const iv = /(?:^|,)IV=([^,\s]+)/.exec(line.substring(line.indexOf(':') + 1));
      ivHex = iv ? iv[1] : '';
      if (ivHex && !/^0x[0-9a-f]{1,32}$/i.test(ivHex)) { throw new Error('离线清单加密参数无效，请重新下载'); }
      continue;
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      if (/BYTERANGE=/.test(line)) { throw new Error('离线初始化片段不完整，请更换线路重新下载'); }
      const uri = /URI="([^"]+)"/.exec(line);
      if (!uri) { throw new Error('离线初始化片段缺失，请重新下载'); }
      if (keyPath && !ivHex) { throw new Error('离线初始化片段缺少加密参数，请重新下载'); }
      const part = new OfflinePart();
      part.localPath = LocalPlaybackService.assetPath(uri[1], manifestPath, context);
      part.keyPath = keyPath; part.ivHex = ivHex; part.sequence = sequence;
      const signature: string = part.localPath + ':' + keyPath + ':' + ivHex;
      if (signature !== lastMap) { plan.parts.push(part); lastMap = signature; }
      plan.fragmentedMp4 = true;
      continue;
    }
    if (line.startsWith('#')) {
      // 未识别的 URI 标签也不能夹带网络资源；只验证本地引用，不发起任何请求。
      const pattern: RegExp = /URI="([^"]+)"/g;
      let uri: RegExpExecArray | null = pattern.exec(line);
      while (uri) { LocalPlaybackService.assetPath(uri[1], manifestPath, context); uri = pattern.exec(line); }
      continue;
    }
    const part = new OfflinePart();
    part.localPath = LocalPlaybackService.assetPath(line, manifestPath, context);
    part.keyPath = keyPath; part.ivHex = ivHex; part.sequence = sequence;
    plan.parts.push(part); mediaCount++; sequence++;
    if (plan.parts.length > 10000 || !Number.isSafeInteger(sequence)) { throw new Error('离线清单分片数量或序号超出限制'); }
  }
  if (mediaCount === 0) { throw new Error('离线播放清单没有本地视频分片，请重新下载'); }
  for (const part of plan.parts) {
    plan.estimatedBytes += LocalPlaybackService.checkedSize(part.localPath);
    if (!Number.isSafeInteger(plan.estimatedBytes)) { throw new Error('离线视频总大小无效，请重新下载'); }
  }
  return plan;
}

private static checkCancelled(cancelled: () => boolean): void {
  if (cancelled()) { throw new Error('本地视频准备已取消'); }
}

private static ivBytes(part: OfflinePart): Uint8Array {
  const result = new Uint8Array(16);
  if (part.ivHex) {
    const hex: string = part.ivHex.substring(2).padStart(32, '0');
    for (let index: number = 0; index < 16; index++) { result[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16); }
  } else {
    let sequence: number = part.sequence;
    for (let index: number = 15; index >= 0; index--) { result[index] = sequence % 256; sequence = Math.floor(sequence / 256); }
  }
  return result;
}

private static readBytes(localPath: string, maxBytes: number): Uint8Array {
  const size: number = LocalPlaybackService.checkedSize(localPath);
  if (size > maxBytes) { throw new Error('离线加密分片过大，请更换线路重新下载'); }
  const opened: fileIo.File = LocalPlaybackService.openReadablePath(localPath);
  try {
    const buffer = new ArrayBuffer(size);
    let offset: number = 0;
    while (offset < size) {
      const remaining = new ArrayBuffer(size - offset);
      const count: number = fileIo.readSync(opened.fd, remaining, { offset: offset, length: size - offset });
      if (count <= 0) { throw new Error('本地视频分片读取不完整，请重新下载'); }
      new Uint8Array(buffer).set(new Uint8Array(remaining, 0, count), offset); offset += count;
    }
    return new Uint8Array(buffer);
  } finally { fileIo.closeSync(opened); }
}

private static writeBytes(output: fileIo.File, data: Uint8Array, startOffset: number): number {
  let consumed: number = 0;
  while (consumed < data.byteLength) {
    const chunk: Uint8Array = data.slice(consumed);
    const count: number = fileIo.writeSync(output.fd, chunk.buffer, { offset: startOffset + consumed, length: chunk.byteLength });
    if (count <= 0) { throw new Error('本地播放缓存写入失败，请检查存储空间'); }
    consumed += count;
  }
  return consumed;
}

private static async copyPart(part: OfflinePart, output: fileIo.File, startOffset: number, cancelled: () => boolean): Promise<number> {
  LocalPlaybackService.checkCancelled(cancelled);
  // 文件校验先于 open，避免 stat/access 抛错后留下未关闭的输入句柄。
  const expected: number = LocalPlaybackService.checkedSize(part.localPath);
  const input: fileIo.File = LocalPlaybackService.openReadablePath(part.localPath);
  let consumed: number = 0;
  try {
    while (consumed < expected) {
      LocalPlaybackService.checkCancelled(cancelled);
      const span: number = Math.min(512 * 1024, expected - consumed);
      const buffer = new ArrayBuffer(span);
      const count: number = fileIo.readSync(input.fd, buffer, { offset: consumed, length: span });
      if (count <= 0) { throw new Error('本地视频分片读取不完整，请重新下载'); }
      LocalPlaybackService.writeBytes(output, new Uint8Array(buffer, 0, count), startOffset + consumed);
      consumed += count;
      // 让页面退出、切集及错误提示有机会执行，准备过程可以及时取消。
      await new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, 0); });
    }
  } finally { fileIo.closeSync(input); }
  return consumed;
}

static async prepareHls(source: string, context: common.UIAbilityContext, cancelled: () => boolean): Promise<string> {
  let manifestPath: string = source.trim();
  let outputPath: string = '';
  let output: fileIo.File | undefined;
  try {
    LocalPlaybackService.checkCancelled(cancelled);
    manifestPath = LocalPlaybackService.checkedPath(source, context);
    Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + manifestPath + '，校验离线清单，跳过远程鉴权');
    const plan: OfflinePlan = LocalPlaybackService.parse(manifestPath, context);
    LocalPlaybackService.checkCancelled(cancelled);
    const free: number = await PlatformApi.freeSpaceBytes();
    if (free >= 0 && free < plan.estimatedBytes + 16 * 1024 * 1024) {
      throw new Error('本地视频播放缓存空间不足，请清理空间后重试');
    }
    outputPath = context.cacheDir + '/wuyin_offline_playback_' + Date.now().toString(36) + '_' + Math.floor(Math.random() * 1000000).toString(36) + (plan.fragmentedMp4 ? '.mp4' : '.ts');
    output = fileIo.openSync(outputPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const keys: Map<string, cryptoFramework.SymKey> = new Map();
    let written: number = 0;
    Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + manifestPath + '，开始准备离线分片，数量=' + plan.parts.length + '，不使用网络或远程鉴权');
    for (const part of plan.parts) {
      LocalPlaybackService.checkCancelled(cancelled);
      if (part.keyPath) {
        let key: cryptoFramework.SymKey | undefined = keys.get(part.keyPath);
        if (!key) {
          const keyBytes: Uint8Array = LocalPlaybackService.readBytes(part.keyPath, 16);
          const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
          key = await generator.convertKey({ data: keyBytes }); keys.set(part.keyPath, key);
        }
        LocalPlaybackService.checkCancelled(cancelled);
        const encrypted: Uint8Array = LocalPlaybackService.readBytes(part.localPath, 64 * 1024 * 1024);
        const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
        const iv: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: LocalPlaybackService.ivBytes(part) } };
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, iv);
        const decrypted: cryptoFramework.DataBlob = await cipher.doFinal({ data: encrypted });
        LocalPlaybackService.checkCancelled(cancelled);
        written += LocalPlaybackService.writeBytes(output, decrypted.data, written);
      } else { written += await LocalPlaybackService.copyPart(part, output, written, cancelled); }
    }
    fileIo.closeSync(output); output = undefined;
    LocalPlaybackService.checkCancelled(cancelled);
    LocalPlaybackService.checkedSize(outputPath);
    Logger.info('PLAYER_LOCAL', '资源类型=local，路径=' + manifestPath + '，离线文件准备完成，大小=' + written + '，使用本地文件描述符播放');
    return outputPath;
  } catch (error) {
    if (output) { try { fileIo.closeSync(output); } catch (closeError) { Logger.warn('PLAYER_LOCAL', '关闭离线缓存句柄失败：' + String(closeError)); } }
    LocalPlaybackService.cleanup(outputPath);
    throw LocalPlaybackService.fileFailure(manifestPath, error as BusinessError,
      '本地视频或分片无法读取，请检查文件完整性或重新下载');
  }
}

static cleanup(preparedPath: string): void {
  if (!/\/wuyin_offline_playback_[a-z0-9_]+\.(?:ts|mp4)$/.test(preparedPath)) { return; }
  try { if (fileIo.accessSync(preparedPath)) { fileIo.unlinkSync(preparedPath); } }
  catch (error) { Logger.warn('PLAYER_LOCAL', '清理本地播放临时文件失败，路径=' + preparedPath + '：' + String(error)); }
}
}

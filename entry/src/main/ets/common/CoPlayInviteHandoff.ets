import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';

export interface CoPlayCachedInvite {
  yhm: string;
  feng: string;
  sfeng: string;
  data: string;
  tilie: string;
  wzlj: string;
  genxi: string;
  zyuanuuu: string;
  vodId: string;
  sessionId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  sharedEpisodeIndex: number;
  sharedPlayProgress: number;
  shareChannel: string;
  fromShare: boolean;
  syncMode: string;
  serverUrl: string;
}

// 仅用于本次外部邀请的应用私有临时交接；不参与历史续播或桌面启动恢复。
export class CoPlayInviteHandoff {
  private static readonly LIFETIME_MS: number = 15 * 60 * 1000;
  private static readonly WRITE_CHUNK_UNITS: number = 16384;
  private static logSequence: number = 0;
  private static cacheSequence: number = 0;

  // 每片不超过 512 个 UTF-16 单元，避免系统单条日志长度限制掩盖完整载荷。
  static logText(stage: string, label: string, text: string): void {
    const trace: string = String(Date.now()) + '-' + String(++CoPlayInviteHandoff.logSequence);
    const parts: string[] = [];
    let offset: number = 0;
    while (offset < text.length) {
      let end: number = Math.min(text.length, offset + 512);
      if (end < text.length) {
        const last: number = text.charCodeAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) { end--; }
      }
      parts.push(text.substring(offset, end));
      offset = end;
    }
    if (parts.length === 0) { parts.push(''); }
    Logger.info('CO_PLAYBACK', '【CoPlay][' + stage + '] ' + label + '，追踪=' + trace +
    '，字符总长=' + text.length + '，分片总数=' + parts.length);
    for (let index: number = 0; index < parts.length; index++) {
      Logger.info('CO_PLAYBACK', '【CoPlay][' + stage + '] 追踪=' + trace + '，分片=' +
      (index + 1) + '/' + parts.length + '，内容=' + parts[index]);
    }
  }

  private static path(context: common.UIAbilityContext, key: string): string {
    // 缓存键只由接收端生成，禁止将分享输入直接作为文件路径。
    if (!/^coplay_[0-9]{13,16}_[a-z0-9]{1,16}$/.test(key)) {
      throw new Error('协播临时载荷键无效');
    }
    return context.cacheDir + '/' + key + '.json';
  }

  private static purgeExpired(context: common.UIAbilityContext): void {
    try {
      const names: string[] = fileIo.listFileSync(context.cacheDir);
      for (let index: number = 0; index < names.length; index++) {
        const match: RegExpExecArray | null = /^coplay_([0-9]{13,16})_[a-z0-9]{1,16}\.json$/.exec(names[index]);
        if (!match || Date.now() - Number(match[1]) <= CoPlayInviteHandoff.LIFETIME_MS) { continue; }
        try { fileIo.unlinkSync(context.cacheDir + '/' + names[index]); }
        catch (error) { Logger.warn('CO_PLAYBACK', '清理过期协播载荷失败：' + String(error)); }
      }
    } catch (error) { Logger.warn('CO_PLAYBACK', '检查过期协播载荷失败：' + String(error)); }
  }

  // 此处只解析应用自行写入的本地缓存，不对 share_data 二次解包，也不改写 videoJson/选集。
  private static decodeCache(content: string): CoPlayCachedInvite {
    const invite: CoPlayCachedInvite = JSON.parse(content) as CoPlayCachedInvite;
    if (!invite || typeof invite !== 'object' || Array.isArray(invite) ||
      typeof invite.sessionId !== 'string' || !invite.sessionId.trim() ||
      invite.sessionId === 'null' || invite.sessionId === 'undefined' ||
      typeof invite.vodId !== 'string' || !invite.vodId.trim() ||
      typeof invite.videoJson !== 'string' || !invite.videoJson.trim() ||
      typeof invite.wzlj !== 'string' ||
      typeof invite.currentMs !== 'number' || !Number.isFinite(invite.currentMs) ||
      invite.currentMs < 0 || invite.currentMs > Number.MAX_SAFE_INTEGER ||
      typeof invite.episodeIndex !== 'number' || !Number.isSafeInteger(invite.episodeIndex) || invite.episodeIndex < 0 ||
      typeof invite.timestamp !== 'number' || !Number.isFinite(invite.timestamp) ||
      invite.timestamp < 0 || invite.timestamp > Number.MAX_SAFE_INTEGER) {
      throw new Error('协播临时载荷损坏');
    }
    // trim 仅用于判断空白，不将其结果赋回 sessionId，保证边界间仍可逐字符对照。
    return invite;
  }

  private static utf8Length(text: string): number {
    let bytes: number = 0;
    for (let index: number = 0; index < text.length; index++) {
      const unit: number = text.charCodeAt(index);
      if (unit <= 0x7F) { bytes++; }
      else if (unit <= 0x7FF) { bytes += 2; }
      else if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length &&
        text.charCodeAt(index + 1) >= 0xDC00 && text.charCodeAt(index + 1) <= 0xDFFF) {
        bytes += 4;
        index++;
      } else { bytes += 3; }
    }
    return bytes;
  }

  private static writeComplete(fd: number, content: string): number {
    let offset: number = 0;
    let byteOffset: number = 0;
    // 超长选集分块写入；文件 offset 使用 UTF-8 字节数，不能使用字符串字符数。
    while (offset < content.length) {
      let end: number = Math.min(content.length, offset + CoPlayInviteHandoff.WRITE_CHUNK_UNITS);
      if (end < content.length) {
        const last: number = content.charCodeAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) { end--; }
      }
      const part: string = content.substring(offset, end);
      const expected: number = CoPlayInviteHandoff.utf8Length(part);
      const written: number = fileIo.writeSync(fd, part, { offset: byteOffset, encoding: 'utf-8' });
      if (written !== expected) {
        Logger.error('CO_PLAYBACK', '【CoPlay][CachePut] 检测到载荷短写，字节偏移=' + byteOffset +
        '，预期字节数=' + expected + '，实际字节数=' + written);
        throw new Error('协播临时载荷写入不完整');
      }
      byteOffset += written;
      offset = end;
    }
    return byteOffset;
  }

  static put(context: common.UIAbilityContext, content: string): string {
    CoPlayInviteHandoff.purgeExpired(context);
    // 同一毫秒收到多份邀请时仍各自使用独立短键，不覆盖正在交接给页面的载荷。
    const suffix: string = (Math.random().toString(36).slice(2, 12) || '0') +
    (++CoPlayInviteHandoff.cacheSequence).toString(36).slice(-6);
    const key: string = 'coplay_' + Date.now() + '_' + suffix;
    const path: string = CoPlayInviteHandoff.path(context, key);
    let opened: fileIo.File | undefined;
    try {
      if (!content) { throw new Error('协播临时载荷为空'); }
      const before: CoPlayCachedInvite = CoPlayInviteHandoff.decodeCache(content);
      opened = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const bytes: number = CoPlayInviteHandoff.writeComplete(opened.fd, content);
      fileIo.closeSync(opened);
      opened = undefined;
      // 跳转前校验完整回读，短写或编码异常不能静默进入页面。
      const restored: string = fileIo.readTextSync(path, { encoding: 'utf-8' });
      if (restored !== content) { throw new Error('协播临时载荷写入不完整'); }
      const after: CoPlayCachedInvite = CoPlayInviteHandoff.decodeCache(restored);
      if (after.sessionId !== before.sessionId || after.videoJson !== before.videoJson) {
        throw new Error('协播临时载荷字段回读不一致');
      }
      Logger.info('CO_PLAYBACK', '【CoPlay][CachePut] 完整载荷已分块写入并校验回读，缓存键=' + key +
      '，字符总长=' + content.length + '，UTF-8字节数=' + bytes +
      '，sessionId原串一致=' + (after.sessionId === before.sessionId) +
      '，videoJson原串一致=' + (after.videoJson === before.videoJson));
      CoPlayInviteHandoff.logText('CachePut', '落盘回读的sessionId原串', after.sessionId);
      return key;
    } catch (error) {
      if (opened) {
        try { fileIo.closeSync(opened); }
        catch (caught) { Logger.warn('CO_PLAYBACK', '关闭协播临时文件失败：' + String(caught)); }
      }
      CoPlayInviteHandoff.remove(context, key);
      Logger.error('CO_PLAYBACK', '【CoPlay][CachePut] 保存协播载荷失败：' + String(error));
      throw new Error('协播临时载荷保存失败');
    }
  }

  static read(context: common.UIAbilityContext, key: string): CoPlayCachedInvite {
    try {
      const path: string = CoPlayInviteHandoff.path(context, key);
      const createdAt: number = Number(key.split('_')[1]);
      if (Date.now() - createdAt > CoPlayInviteHandoff.LIFETIME_MS) {
        CoPlayInviteHandoff.remove(context, key);
        throw new Error('协播邀请已过期，请重新分享');
      }
      const content: string = fileIo.readTextSync(path, { encoding: 'utf-8' });
      const invite: CoPlayCachedInvite = CoPlayInviteHandoff.decodeCache(content);
      Logger.info('CO_PLAYBACK', '【CoPlay][CacheRead] 已恢复完整载荷，缓存键=' + key +
      '，字符总长=' + content.length + '，videoJson字符数=' + invite.videoJson.length +
      '，sessionId字符数=' + invite.sessionId.length);
      CoPlayInviteHandoff.logText('CacheRead', '缓存中的sessionId原串（仅供与路由对照，不补写路由）', invite.sessionId);
      return invite;
    } catch (error) {
      Logger.error('CO_PLAYBACK', '【CoPlay][CacheRead] 恢复协播载荷失败：' + String(error));
      throw new Error(error instanceof Error ? error.message : '协播临时载荷读取失败');
    }
  }

  static remove(context: common.UIAbilityContext, key: string): void {
    try {
      const path: string = CoPlayInviteHandoff.path(context, key);
      if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
    } catch (error) { Logger.warn('CO_PLAYBACK', '清理协播临时载荷失败：' + String(error)); }
  }
}

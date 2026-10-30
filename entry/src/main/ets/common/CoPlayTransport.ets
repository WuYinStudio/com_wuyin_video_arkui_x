import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

export interface CoPlayInvitation {
  version: number;
  sessionId: string;
  vodId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  syncMode?: string;
  serverUrl?: string;
}

// API26 Beta2 的 Want 和页面路由只承载短字符串，不承载超长选集。
export interface CoPlayWantParameters {
  coPlayEntry: string;
  coPlayPayloadKey: string;
  sessionId: string;
  vodId: string;
  currentMs: string;
  timestamp: string;
  episodeIndex: string;
  syncMode: string;
  serverUrl: string;
}

export class CoPlayTransport {
  private static readonly PREFIX: string = 'coplay-invite-';
  private static readonly MAX_AGE_MS: number = 30 * 60 * 1000;

  static validSessionId(value: Object | undefined | null): boolean {
    return typeof value === 'string' && value.trim().length > 0 && value !== 'null' && value !== 'undefined';
  }

  // 单条系统日志可能被截断；分片保留完整原文，每片均带阶段、序号和总长度。
  static logText(stage: string, label: string, value: string): void {
    const chunkSize: number = 480;
    const count: number = Math.max(1, Math.ceil(value.length / chunkSize));
    const trace: string = String(Date.now());
    for (let index: number = 0; index < count; index++) {
      Logger.info('CO_PLAYBACK', '【CoPlay][' + stage + '] ' + label + '，追踪=' + trace +
      '，长度=' + value.length + '，分片=' + (index + 1) + '/' + count + '：' +
      value.substring(index * chunkSize, (index + 1) * chunkSize));
    }
  }

  static logParameters(stage: string, params: Record<string, Object> | undefined | null): void {
    if (!params) {
      Logger.warn('CO_PLAYBACK', '【CoPlay][' + stage + '] 参数对象缺失');
      return;
    }
    CoPlayTransport.logText(stage, '全部键值', JSON.stringify(params));
    Object.keys(params).forEach((key: string): void => {
      const value: Object | undefined | null = params[key];
      CoPlayTransport.logText(stage, key + '，类型=' + typeof value,
        value === undefined ? 'undefined' : value === null ? 'null' :
        typeof value === 'string' ? value : JSON.stringify(value));
    });
    Logger.info('CO_PLAYBACK', '【CoPlay][' + stage + '] sessionId是否存在=' +
    CoPlayTransport.validSessionId(params['sessionId']));
  }

  // 仅用于收发日志比对，不作为认证或加密摘要。
  private static fingerprint(bytes: Uint8Array): string {
    let value: number = 2166136261;
    for (let index: number = 0; index < bytes.length; index++) {
      value = Math.imul(value ^ bytes[index], 16777619) >>> 0;
    }
    return value.toString(16);
  }

  static logLanMetrics(stage: string, invitation: CoPlayInvitation, raw: string): void {
    const videoBytes: Uint8Array = new util.TextEncoder().encodeInto(invitation.videoJson);
    const rawBytes: Uint8Array = new util.TextEncoder().encodeInto(raw);
    Logger.info('CO_PLAYBACK', '【CoPlay][' + stage + '] sessionId=' + invitation.sessionId +
    '，videoJson字符串长度=' + invitation.videoJson.length + '，videoJson UTF-8字节数=' + videoBytes.length +
    '，videoJson校验摘要=' + CoPlayTransport.fingerprint(videoBytes) + '，payload字符串长度=' + raw.length +
    '，payload UTF-8字节数=' + rawBytes.length + '，payload校验摘要=' + CoPlayTransport.fingerprint(rawBytes));
  }

  // 两端共用严格校验；不裁剪 sessionId，也不接受对象形式的 videoJson。
  // 本方法不输出 LAN-Receive，发送端校验不能冒充接收端收到消息。
  static validateLanInvitation(invitation: CoPlayInvitation): void {
    if (!invitation || typeof invitation !== 'object' || Array.isArray(invitation) || invitation.version !== 1 ||
      !CoPlayTransport.validSessionId(invitation.sessionId)) {
      throw new Error('局域网协播 version 或 sessionId 无效');
    }
    if (invitation.syncMode !== 'lan' || typeof invitation.vodId !== 'string' || !invitation.vodId.trim() ||
      !Number.isSafeInteger(invitation.currentMs) || invitation.currentMs < 0 ||
      !Number.isSafeInteger(invitation.timestamp) || invitation.timestamp <= 0 ||
      !Number.isSafeInteger(invitation.episodeIndex) || invitation.episodeIndex < 0 ||
      typeof invitation.videoJson !== 'string' || !invitation.videoJson) {
      throw new Error('局域网协播字段类型或取值无效');
    }
    try {
      const video: Object = JSON.parse(invitation.videoJson) as Object;
      if (!video || typeof video !== 'object' || Array.isArray(video)) {
        throw new Error('videoJson 必须序列化自视频对象');
      }
    } catch (error) {
      const failure: Error = error as Error;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN][Validate] videoJson 解析失败：' +
      failure.message + '，堆栈=' + failure.stack);
      throw new Error('局域网协播 videoJson 不是有效视频 JSON 字符串');
    }
    Logger.info('CO_PLAYBACK', '【CoPlay][LAN][Validate] 参数校验通过，videoJson字符串长度=' +
    invitation.videoJson.length + '，sessionId长度=' + invitation.sessionId.length);
  }

  static serializeLanInvitation(invitation: CoPlayInvitation): string {
    try {
      CoPlayTransport.validateLanInvitation(invitation);
      const payload: string = JSON.stringify(invitation);
      CoPlayTransport.logText('LAN-Send', '完整payload', payload);
      CoPlayTransport.logLanMetrics('LAN-Send', invitation, payload);
      return payload;
    } catch (error) {
      const failure: Error = error as Error;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Send] 序列化或参数校验失败：' +
      failure.message + '，堆栈=' + failure.stack);
      throw failure;
    }
  }

  static parseLanInvitation(payload: string): CoPlayInvitation {
    try {
      CoPlayTransport.logText('LAN-Receive', '完整payload', payload);
      const invitation: CoPlayInvitation = JSON.parse(payload) as CoPlayInvitation;
      CoPlayTransport.validateLanInvitation(invitation);
      CoPlayTransport.logLanMetrics('LAN-Receive', invitation, payload);
      return invitation;
    } catch (error) {
      const failure: Error = error as Error;
      Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Receive] 参数校验失败：' +
      failure.message + '，堆栈=' + failure.stack);
      throw failure;
    }
  }

  static makeParameters(context: common.UIAbilityContext, invitation: CoPlayInvitation): CoPlayWantParameters {
    if (!CoPlayTransport.validSessionId(invitation.sessionId)) { throw new Error('协播缺少有效 sessionId'); }
    if (typeof invitation.videoJson !== 'string' || !invitation.videoJson) { throw new Error('协播缺少字符串 videoJson'); }
    const key: string = String(Date.now()) + '-' + util.generateRandomUUID(true);
    const path: string = context.cacheDir + '/' + CoPlayTransport.PREFIX + key + '.json';
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, invitation.videoJson);
    } finally { fileIo.closeSync(file); }
    // 回读确认完整，失败时绝不继续跳转或回退到超长 Want 传参。
    if (fileIo.readTextSync(path) !== invitation.videoJson) {
      try { fileIo.unlinkSync(path); } catch (_) {}
      throw new Error('协播视频资料缓存不完整');
    }
    Logger.info('CO_PLAYBACK', '【CoPlay][Cache] 已保存完整 videoJson，长度=' + invitation.videoJson.length + '，缓存键=' + key);
    const params: CoPlayWantParameters = {
      coPlayEntry: '1', coPlayPayloadKey: key,
        sessionId: invitation.sessionId, vodId: String(invitation.vodId),
        currentMs: String(invitation.currentMs), timestamp: String(invitation.timestamp),
        episodeIndex: String(invitation.episodeIndex), syncMode: String(invitation.syncMode || 'lan'),
        serverUrl: String(invitation.serverUrl || '')
    };
    CoPlayTransport.cleanup(context);
    return params;
  }

  static readVideo(context: common.UIAbilityContext, key: string): string {
    if (!/^\d{13}-[A-Za-z0-9-]{32,36}$/.test(key)) { throw new Error('协播缓存键无效'); }
    const created: number = Number(key.substring(0, 13));
    if (created > Date.now() + 60000 || Date.now() - created > CoPlayTransport.MAX_AGE_MS) {
      throw new Error('协播邀请缓存已过期，请重新分享');
    }
    const value: string = fileIo.readTextSync(context.cacheDir + '/' + CoPlayTransport.PREFIX + key + '.json');
    if (!value) { throw new Error('协播视频资料缓存为空'); }
    Logger.info('CO_PLAYBACK', '【CoPlay][Cache] 页面恢复完整 videoJson，长度=' + value.length + '，缓存键=' + key);
    return value;
  }

  private static cleanup(context: common.UIAbilityContext): void {
    try {
      const names: string[] = fileIo.listFileSync(context.cacheDir);
      names.forEach((name: string): void => {
        const match: RegExpExecArray | null = /^coplay-invite-(\d{13})-[A-Za-z0-9-]{32,36}\.json$/.exec(name);
        if (match && Date.now() - Number(match[1]) > CoPlayTransport.MAX_AGE_MS) {
          try { fileIo.unlinkSync(context.cacheDir + '/' + name); }
          catch (_) { Logger.warn('CO_PLAYBACK', '【CoPlay][Cache] 清理过期邀请缓存失败'); }
        }
      });
    } catch (_) { Logger.warn('CO_PLAYBACK', '【CoPlay][Cache] 枚举过期邀请缓存失败'); }
  }
}

import { Logger } from './Logger';

export interface CollaborativeVideoInfo {
  yhm: string;
  feng: string;
  sfeng: string;
  data: string;
  tilie: string;
  wzlj: string;
  genxi: string;
  zyuanuuu: string;
  vodId: string;
}

export interface CollaborativeInvitePayload {
  version: number;
  vodId: string;
  sessionId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  syncMode?: string;
  serverUrl?: string;
}

export interface ValidatedCollaborativeInvite {
  payload: CollaborativeInvitePayload;
  video: CollaborativeVideoInfo;
}

function optionalText(value: string, limit: number): string {
  return typeof value === 'string' ? value.slice(0, limit) : '';
}

// 外部邀请只允许影视展示和网络选集字段，不能注入离线路径或播放器内部状态。
export function validateCollaborativeInvite(payload: CollaborativeInvitePayload): ValidatedCollaborativeInvite {
  try {
    if (!payload || payload.version !== 1 ||
      typeof payload.vodId !== 'string' || !payload.vodId.trim() ||
      typeof payload.sessionId !== 'string' || !payload.sessionId.trim() ||
      typeof payload.videoJson !== 'string' || !payload.videoJson.trim() ||
      (payload.syncMode !== undefined && typeof payload.syncMode !== 'string') ||
      typeof payload.currentMs !== 'number' || !Number.isFinite(payload.currentMs) || payload.currentMs < 0 || payload.currentMs > Number.MAX_SAFE_INTEGER ||
      typeof payload.timestamp !== 'number' || !Number.isFinite(payload.timestamp) || payload.timestamp < 0 || payload.timestamp > Number.MAX_SAFE_INTEGER ||
      typeof payload.episodeIndex !== 'number' || !Number.isSafeInteger(payload.episodeIndex) || payload.episodeIndex < 0) {
      throw new Error('协播数据解析失败');
    }
    const syncMode: string = payload.syncMode && payload.syncMode.trim() ? payload.syncMode.trim() : 'lan';
    if (syncMode !== 'lan' && syncMode !== 'server') { throw new Error('协播同步模式无效'); }
    const serverUrl: string = typeof payload.serverUrl === 'string' ? payload.serverUrl.trim() : '';
    if (syncMode === 'server' && !/^wss?:\/\//i.test(serverUrl)) { throw new Error('服务器协播邀请缺少有效信令地址'); }
    let video: CollaborativeVideoInfo;
    try {
      const parsed: CollaborativeVideoInfo = JSON.parse(payload.videoJson) as CollaborativeVideoInfo;
      if (!parsed || typeof parsed.yhm !== 'string' || !parsed.yhm.trim() ||
        typeof parsed.wzlj !== 'string' || !parsed.wzlj.trim()) {
        throw new Error('缺少影片名称或选集字段');
      }
      const cleanWzlj: string = parsed.wzlj.replaceAll('\t', '');
      let playable: number = 0;
      const entries: string[] = cleanWzlj.split('#');
      for (let index: number = 0; index < entries.length; index++) {
        const entry: string = entries[index].trim();
        const separator: number = entry.indexOf('$');
        if (separator <= 0 || separator >= entry.length - 1) { continue; }
        const title: string = entry.substring(0, separator).trim();
        const address: string = entry.substring(separator + 1).trim();
        if (!title || !address) { continue; }
        if (!/^https?:\/\/[^\s/]+/i.test(address)) { throw new Error('选集播放地址无效'); }
        playable++;
      }
      if (playable === 0 || payload.episodeIndex >= playable) { throw new Error('选集为空或集号超出范围'); }
      video = {
        yhm: optionalText(parsed.yhm, 256), feng: optionalText(parsed.feng, 4096),
          sfeng: optionalText(parsed.sfeng, 4096), data: optionalText(parsed.data, 4096),
          tilie: optionalText(parsed.tilie, 256) || optionalText(parsed.yhm, 256),
          wzlj: cleanWzlj, genxi: optionalText(parsed.genxi, 4096),
          zyuanuuu: optionalText(parsed.zyuanuuu, 4096), vodId: payload.vodId.trim()
      };
      Logger.info('MEDIA_SESSION', '协播剧集校验通过，选集数=' + playable + '，目标集号=' + payload.episodeIndex);
    } catch (error) {
      Logger.error('MEDIA_SESSION', '解析或清洗协播 videoJson 失败：' + String(error));
      throw new Error('协播剧集信息损坏');
    }
    const normalized: CollaborativeInvitePayload = {
      version: 1, vodId: payload.vodId.trim(), sessionId: payload.sessionId.trim(),
        currentMs: Math.floor(payload.currentMs), timestamp: payload.timestamp,
        episodeIndex: payload.episodeIndex, videoJson: JSON.stringify(video), syncMode: syncMode, serverUrl: serverUrl
    };
    Logger.info('MEDIA_SESSION', '协播载荷校验通过，sessionId=' + normalized.sessionId + '，currentMs=' + normalized.currentMs);
    return { payload: normalized, video: video };
  } catch (error) {
    Logger.error('MEDIA_SESSION', '校验协播载荷失败：' + String(error));
    const problem: Error = error as Error;
    throw new Error(problem && problem.message ? problem.message : '协播数据解析失败');
  }
}

export function parseCollaborativeInvite(raw: string): ValidatedCollaborativeInvite {
  let payload: CollaborativeInvitePayload;
  try {
    payload = JSON.parse(raw) as CollaborativeInvitePayload;
  } catch (error) {
    Logger.error('MEDIA_SESSION', '解析协播外层 JSON 失败：' + String(error));
    throw new Error('协播数据解析失败');
  }
  return validateCollaborativeInvite(payload);
}

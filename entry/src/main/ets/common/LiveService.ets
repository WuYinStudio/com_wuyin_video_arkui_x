import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

export class LiveChannel {
  name: string = '';
  logo: string = '';
  group: string = '';
  sources: string[] = [];
}

/**
 * 电视直播源解析。
 * rawfile/tv_channels.m3u 来自用户提供的「国内电视直播源.txt」，
 * 同一个频道可能有多条备用线路，全部保留供播放页切换。
 */
export class LiveService {
  private static channelsCache: LiveChannel[] = [];
  private static groupsCache: string[] = [];
  private static loaded: boolean = false;

  static async load(context: common.UIAbilityContext): Promise<void> {
    if (LiveService.loaded && LiveService.channelsCache.length > 0) {
      return;
    }
    try {
      const data: Uint8Array = await context.resourceManager.getRawFileContent('tv_channels.m3u');
      const text: string = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(data).replace(/^\uFEFF/, '');
      const parsed: LiveChannel[] = LiveService.parse(text);
      LiveService.channelsCache = parsed;
      LiveService.groupsCache = LiveService.collectGroups(parsed);
      LiveService.loaded = true;
      Logger.info('LIVE_TV', '直播源加载完成，频道=' + String(parsed.length) + '，分组=' + String(LiveService.groupsCache.length));
    } catch (error) {
      Logger.error('LIVE_TV', '加载直播源失败：' + String(error));
      throw new Error('直播源加载失败：' + String(error));
    }
  }

  static channels(): LiveChannel[] {
    return LiveService.channelsCache;
  }

  static groups(): string[] {
    return LiveService.groupsCache;
  }

  static channel(name: string): LiveChannel | undefined {
    for (const item of LiveService.channelsCache) {
      if (item.name === name) {
        return item;
      }
    }
    return undefined;
  }

  private static parse(text: string): LiveChannel[] {
    const result: LiveChannel[] = [];
    const lines: string[] = text.split(/\r?\n/);
    let pendingName: string = '';
    let pendingLogo: string = '';
    let pendingGroup: string = '';
    for (const raw of lines) {
      const line: string = raw.trim();
      if (!line) {
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        const logoMatch: RegExpMatchArray | null = line.match(/tvg-logo="([^"]*)"/i);
        const groupMatch: RegExpMatchArray | null = line.match(/group-title="([^"]*)"/i);
        pendingLogo = logoMatch !== null ? logoMatch[1].trim() : '';
        pendingGroup = groupMatch !== null ? groupMatch[1].trim() : '其他';
        const comma: number = line.lastIndexOf(',');
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      if (!line.startsWith('http://') && !line.startsWith('https://')) {
        continue;
      }
      if (!pendingName) {
        continue;
      }
      let channel: LiveChannel | undefined = undefined;
      for (const item of result) {
        if (item.name === pendingName) {
          channel = item;
          break;
        }
      }
      if (channel === undefined) {
        channel = new LiveChannel();
        channel.name = pendingName;
        channel.logo = pendingLogo;
        channel.group = pendingGroup || '其他';
        result.push(channel);
      }
      if (!channel.sources.includes(line)) {
        channel.sources.push(line);
      }
    }
    return result;
  }

  private static collectGroups(channels: LiveChannel[]): string[] {
    const groups: string[] = [];
    for (const item of channels) {
      if (item.group && groups.indexOf(item.group) < 0) {
        groups.push(item.group);
      }
    }
    return groups;
  }
}

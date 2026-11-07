import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { AppState } from './AppState';
import { Logger } from './Logger';

export class LiveChannel {
  name: string = '';
  logo: string = '';
  group: string = '';
  sources: string[] = [];
}

/**
 * 电视直播源解析（**只读用户自己导入的源**）。
 *
 * 合规说明：应用不再内置任何直播频道列表——频道 m3u 必须由用户通过
 * 「导入 m3u 文件」或「从链接导入」自行提供，应用只负责解析与播放。
 * 这样与「自定义搜索规则」保持同一套定位：应用是播放工具，不提供内容。
 */
export class LiveService {
  private static channelsCache: LiveChannel[] = [];
  private static groupsCache: string[] = [];
  private static loaded: boolean = false;
  /** 用户导入的源标签：文件名或链接，用于页面展示"当前直播源"。 */
  private static sourceLabel: string = '';
  private static prefs?: preferences.Preferences;

  static async load(context: common.UIAbilityContext): Promise<void> {
    if (LiveService.loaded) { return; }
    try {
      LiveService.prefs = await preferences.getPreferences(context, 'wuyin-live');
      LiveService.sourceLabel = String(await LiveService.prefs.get('sourceLabel', '')).trim();
      const text: string = String(await LiveService.prefs.get('sourceText', ''));
      if (text.trim().length > 0) {
        const parsed: LiveChannel[] = LiveService.parse(text);
        LiveService.channelsCache = parsed;
        LiveService.groupsCache = LiveService.collectGroups(parsed);
        Logger.info('LIVE_TV', '已加载用户导入的直播源，频道=' + String(parsed.length));
      } else {
        LiveService.channelsCache = [];
        LiveService.groupsCache = [];
      }
      LiveService.loaded = true;
    } catch (error) {
      Logger.error('LIVE_TV', '读取直播源失败：' + String(error));
      LiveService.channelsCache = [];
      LiveService.groupsCache = [];
      LiveService.loaded = true;
    }
  }

  /** 当前是否已经导入过直播源。 */
  static hasSource(): boolean {
    return LiveService.channelsCache.length > 0;
  }

  /** 当前直播源标签（文件名或链接），没导入时为空。 */
  static currentSourceLabel(): string {
    return LiveService.sourceLabel;
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

  /** 从用户选择的 m3u/m3u8/txt 文件导入。 */
  static async importFile(context: common.UIAbilityContext): Promise<number> {
    await LiveService.load(context);
    const paths: string[] = await new picker.DocumentViewPicker(context).select(new picker.DocumentSelectOptions());
    if (paths.length === 0) { return 0; }
    const filename: string = decodeURIComponent(paths[0].split('/').pop() || '').split('?')[0];
    const file: fs.File = fs.openSync(paths[0], fs.OpenMode.READ_ONLY);
    let text: string = '';
    try {
      const size: number = Number(fs.statSync(file.fd).size);
      if (size <= 0) { throw new Error('文件为空'); }
      if (size > 8 * 1024 * 1024) { throw new Error('文件超过 8MB，请换小一点的源文件'); }
      const data: ArrayBuffer = new ArrayBuffer(size);
      let read: number = 0;
      while (read < size) {
        const chunk: number = fs.readSync(file.fd, data, { offset: read, length: size - read });
        if (chunk <= 0) { throw new Error('文件读取不完整'); }
        read += chunk;
      }
      text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(data));
    } finally {
      fs.closeSync(file);
    }
    return LiveService.apply(text, filename);
  }

  /** 从用户填写的 m3u 链接导入（网络地址）。 */
  static async importUrl(context: common.UIAbilityContext, url: string): Promise<number> {
    await LiveService.load(context);
    const target: string = (url || '').trim();
    if (!/^https?:\/\//i.test(target)) { throw new Error('请输入 http 或 https 开头的直播源链接'); }
    const request = http.createHttp();
    try {
      const response = await request.request(target, {
        method: http.RequestMethod.GET, connectTimeout: 8000, readTimeout: 12000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('直播源下载失败，HTTP ' + response.responseCode);
      }
      return LiveService.apply(String(response.result || ''), target);
    } finally {
      request.destroy();
    }
  }

  /** 清除已导入的直播源（回到"未导入"状态）。 */
  static async clear(context: common.UIAbilityContext): Promise<void> {
    await LiveService.load(context);
    LiveService.channelsCache = [];
    LiveService.groupsCache = [];
    LiveService.sourceLabel = '';
    if (LiveService.prefs) {
      await LiveService.prefs.put('sourceText', '');
      await LiveService.prefs.put('sourceLabel', '');
      await LiveService.prefs.flush();
    }
    Logger.info('LIVE_TV', '已清除用户导入的直播源');
  }

  /** 解析并持久化：解析不出来直接报错，不覆盖已有的可用源。 */
  private static async apply(text: string, label: string): Promise<number> {
    const parsed: LiveChannel[] = LiveService.parse(text);
    if (parsed.length === 0) {
      throw new Error('没有解析到频道，请确认是标准的 m3u / m3u8 直播源');
    }
    LiveService.channelsCache = parsed;
    LiveService.groupsCache = LiveService.collectGroups(parsed);
    LiveService.sourceLabel = label;
    if (!LiveService.prefs && AppState.context) {
      LiveService.prefs = await preferences.getPreferences(AppState.context, 'wuyin-live');
    }
    if (LiveService.prefs) {
      await LiveService.prefs.put('sourceText', text);
      await LiveService.prefs.put('sourceLabel', label);
      await LiveService.prefs.flush();
    }
    Logger.info('LIVE_TV', '导入直播源成功，来源=' + label + '，频道=' + String(parsed.length));
    return parsed.length;
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


import { Logger } from './Logger';

export interface WzljEpisode {
  title: string;
  url: string;
}

// 只清理制表符和片段两端空白，不改写地址中的 $、查询参数或编码。
export function parseWzlj(wzljStr: string): Array<WzljEpisode> {
  try {
    if (typeof wzljStr !== 'string') {
      Logger.warn('CO_PLAYBACK', '选集解析已跳过：入参不是字符串');
      return [];
    }
    const cleaned: string = wzljStr.replaceAll('\t', '');
    const fragments: string[] = cleaned.split('#');
    const result: WzljEpisode[] = [];
    for (let index: number = 0; index < fragments.length; index++) {
      const fragment: string = fragments[index].trim();
      if (!fragment) { continue; }
      const separator: number = fragment.indexOf('$');
      if (separator <= 0 || separator >= fragment.length - 1) { continue; }
      const title: string = fragment.substring(0, separator).trim();
      const url: string = fragment.substring(separator + 1).trim();
      if (!title || !url) { continue; }
      result.push({ title: title, url: url });
    }
    Logger.info('CO_PLAYBACK', '选集解析完成，片段数=' + fragments.length + '，有效集数=' + result.length);
    return result;
  } catch (error) {
    Logger.error('CO_PLAYBACK', '选集解析异常：' + String(error));
    return [];
  }
}

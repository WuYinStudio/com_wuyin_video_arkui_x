import { Logger } from './Logger';

/**
 * QQ 风控/TG 机器人常用的富文本 XML 卡片（ark 卡片）解析。
 *
 * 结构：
 * <msg serviceID="1|2" templateID="1" action="web" brief="…" url="wuyinvideo://audio?…">
 *   <item layout="1|2">
 *     <title>…</title>
 *     <summary>…</summary>
 *     <pic>封面</pic> / <audio cover="封面"/>
 *     <hr/>
 *     <desc>…（可含 <br/>）</desc>
 *   </item>
 *   <source name="无音影视" icon="…"/>
 * </msg>
 *
 * 解析结果统一映射到聊天室的卡片模型（XmlCard），并保留 scheme 参数。
 */
export class ArkCard {
  serviceId: string = '1';
  layout: number = 1;
  action: string = 'web';
  brief: string = '';
  scheme: string = '';
  title: string = '';
  summary: string = '';
  desc: string = '';
  cover: string = '';
  source: string = '';
  icon: string = '';
}

/** 是否是 QQ 风格 XML 卡片。 */
export function isArkCard(content: string): boolean {
  const text: string = (content || '').trim();
  return text.startsWith('<msg') || text.indexOf('<?xml') === 0 && text.indexOf('<msg') > 0;
}

/** 解析 ark 卡片；失败返回 undefined。 */
export function parseArkCard(content: string): ArkCard | undefined {
  const text: string = (content || '').trim();
  if (text.length === 0) { return undefined; }
  try {
    const card: ArkCard = new ArkCard();
    card.serviceId = attr(text, 'serviceID', '1');
    card.action = attr(text, 'action', 'web');
    card.brief = attr(text, 'brief', '');
    card.scheme = attr(text, 'url', '');
    const layoutText: string = block(text, '<item ', 'layout="', '"');
    const layout: number = Number(layoutText);
    card.layout = Number.isFinite(layout) && layout > 0 ? layout : 1;
    card.title = tag(text, 'title');
    if (card.title.length === 0) {
      // 兼容"标题直接写在 <item> 里"的写法（无 <title> 标签）
      card.title = firstTextInItem(text);
    }
    card.summary = tag(text, 'summary');
    card.desc = clean(tag(text, 'desc'));
    card.cover = tag(text, 'pic') || attrText(text, '<audio', 'cover');
    const sourceBlock: string = block(text, '<source', 'name="', '"');
    card.source = sourceBlock.length > 0 ? sourceBlock : '无音影视';
    card.icon = attrText(text, '<source', 'icon');
    if (card.title.length === 0 && card.summary.length === 0 && card.desc.length === 0) {
      return undefined;
    }
    return card;
  } catch (error) {
    Logger.warn('ARK_CARD', '解析 XML 卡片失败：' + String(error));
    return undefined;
  }
}

/** 从 scheme 里取参数：wuyinvideo://play?vodId=1&episodeIndex=2 */
export function schemeValue(scheme: string, key: string): string {
  const value: string = (scheme || '').trim();
  const queryIndex: number = value.indexOf('?');
  if (queryIndex < 0) { return ''; }
  const query: string = value.substring(queryIndex + 1);
  const pairs: string[] = query.split('&');
  for (const pair of pairs) {
    const eq: number = pair.indexOf('=');
    if (eq <= 0) { continue; }
    const name: string = pair.substring(0, eq);
    if (name === key) {
      return decodeURIComponent(pair.substring(eq + 1));
    }
  }
  return '';
}

/** scheme 的 host：play / audio / notice / download / post。 */
export function schemeHost(scheme: string): string {
  const value: string = (scheme || '').trim();
  const index: number = value.indexOf('://');
  if (index < 0) { return ''; }
  const rest: string = value.substring(index + 3);
  const end: number = rest.search(/[\/?]/);
  return (end >= 0 ? rest.substring(0, end) : rest).toLowerCase();
}

function firstTextInItem(text: string): string {
  const start: number = text.indexOf('<item');
  if (start < 0) { return ''; }
  const open: number = text.indexOf('>', start);
  const close: number = text.indexOf('</item>', open);
  if (open < 0 || close < 0) { return ''; }
  const inner: string = text.substring(open + 1, close);
  const lines: string[] = inner.split(/<br\s*\/?>/i);
  for (const rawLine of lines) {
    const line: string = rawLine.replace(/<[^>]+>/g, '').trim();
    if (line.length > 0) { return line; }
  }
  return '';
}

function attr(text: string, name: string, fallback: string): string {
  const matched: RegExpMatchArray | null = text.match(new RegExp(name + '\\s*=\\s*"([^"]*)"', 'i'));
  return matched !== null && matched.length > 1 ? decode(matched[1]) : fallback;
}

function attrText(text: string, tagName: string, name: string): string {
  const start: number = text.indexOf(tagName);
  if (start < 0) { return ''; }
  const end: number = text.indexOf('>', start);
  if (end < 0) { return ''; }
  const seg: string = text.substring(start, end);
  const matched: RegExpMatchArray | null = seg.match(new RegExp(name + '\\s*=\\s*"([^"]*)"', 'i'));
  return matched !== null && matched.length > 1 ? decode(matched[1]) : '';
}

function block(text: string, tagName: string, name: string, quote: string): string {
  const start: number = text.indexOf(tagName);
  if (start < 0) { return ''; }
  const end: number = text.indexOf('>', start);
  if (end < 0) { return ''; }
  const seg: string = text.substring(start, end);
  const matched: RegExpMatchArray | null = seg.match(new RegExp(name + '([^' + quote + ']*)' + quote, 'i'));
  return matched !== null && matched.length > 1 ? matched[1] : '';
}

function tag(text: string, name: string): string {
  const start: number = text.indexOf('<' + name + '>');
  if (start < 0) { return ''; }
  const end: number = text.indexOf('</' + name + '>', start);
  if (end < 0) { return ''; }
  return clean(decode(text.substring(start + name.length + 2, end)));
}

function clean(value: string): string {
  return (value || '').replace(/<br\s*\/?>/gi, '\n').trim();
}

function decode(value: string): string {
  return (value || '')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

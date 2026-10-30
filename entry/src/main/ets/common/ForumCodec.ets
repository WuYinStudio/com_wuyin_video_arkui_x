/**
 * 论坛帖子 / 回复的正文协议。
 *
 * 后端 bbs.php 只接受纯文本 content，因此帖子里的富内容（图片、视频、音乐、附件、付费段落）
 * 统一序列化成一段 JSON，前面加 `#WYF#` 前缀；**发送给服务端的仍然是纯文字**。
 * 不带任何媒体的普通帖子直接存原文，保证与历史数据、其它客户端互相兼容。
 *
 * 历史格式（【img1】url【img1】/【video】url【video】/【paid:10】…【/paid】）在解析时一并兼容。
 */
export class ForumMedia {
  /** image | video | audio | file */
  kind: string = 'image';
  url: string = '';
  /** 视频/音乐/附件的显示名 */
  title: string = '';
  /** 视频封面 */
  poster: string = '';
}

export class ForumContent {
  text: string = '';
  media: ForumMedia[] = [];
  price: number = 0;
  paid: string = '';
}

/** 序列化用的载荷（ArkTS 不允许无类型对象字面量，这里显式声明）。 */
class ForumPayload {
  v: number = 1;
  text: string = '';
  media: ForumMedia[] = [];
  price: number = 0;
  paid: string = '';
}

export class ForumCodec {
  static readonly PREFIX: string = '#WYF#';
  static readonly VERSION: number = 1;
  static readonly MAX_IMAGES: number = 9;

  // ---------------- 编码 ----------------

  /** 富内容 → 纯文字 JSON；无媒体无付费时退化为普通文本。 */
  static encode(content: ForumContent): string {
    const text: string = content.text.trim();
    const hasMedia: boolean = content.media.length > 0;
    const hasPaid: boolean = content.price > 0 && content.paid.trim().length > 0;
    if (!hasMedia && !hasPaid) {
      return text;
    }
    const payload: ForumPayload = new ForumPayload();
    payload.v = ForumCodec.VERSION;
    payload.text = text;
    payload.media = content.media;
    payload.price = hasPaid ? Math.trunc(content.price) : 0;
    payload.paid = hasPaid ? content.paid.trim() : '';
    return ForumCodec.PREFIX + JSON.stringify(payload);
  }

  // ---------------- 解码 ----------------

  static isJson(raw: string): boolean {
    return raw !== undefined && raw !== null && String(raw).startsWith(ForumCodec.PREFIX);
  }

  static decode(raw: string): ForumContent {
    const value: string = raw === undefined || raw === null ? '' : String(raw);
    if (!value.startsWith(ForumCodec.PREFIX)) {
      return ForumCodec.decodeLegacy(value);
    }
    try {
      const parsed: ForumPayload = JSON.parse(value.substring(ForumCodec.PREFIX.length)) as ForumPayload;
      const content: ForumContent = new ForumContent();
      content.text = typeof parsed.text === 'string' ? parsed.text : '';
      content.price = Number(parsed.price) > 0 ? Math.trunc(Number(parsed.price)) : 0;
      content.paid = typeof parsed.paid === 'string' ? parsed.paid : '';
      const list: ForumMedia[] = parsed.media;
      if (Array.isArray(list)) {
        content.media = ForumCodec.parseMedia(list);
      }
      return content;
    } catch (error) {
      return ForumCodec.decodeLegacy(value);
    }
  }

  /** 把任意来源的媒体数组规范化（过滤空 URL、纠正 kind），聊天室与论坛共用。 */
  static parseMedia(source: ForumMedia[]): ForumMedia[] {
    const result: ForumMedia[] = [];
    if (!Array.isArray(source)) {
      return result;
    }
    for (const item of source) {
      const media: ForumMedia | undefined = ForumCodec.mediaOfItem(item);
      if (media !== undefined) {
        result.push(media);
      }
    }
    return result;
  }

  private static mediaOfItem(item: ForumMedia): ForumMedia | undefined {
    if (item === undefined || item === null) {
      return undefined;
    }
    const url: string = typeof item.url === 'string' ? item.url.trim() : '';
    if (url.length === 0) {
      return undefined;
    }
    const media: ForumMedia = new ForumMedia();
    const kind: string = typeof item.kind === 'string' ? item.kind : 'image';
    media.kind = ForumCodec.normalizeKind(kind);
    media.url = url;
    media.title = typeof item.title === 'string' ? item.title : '';
    media.poster = typeof item.poster === 'string' ? item.poster : '';
    return media;
  }

  private static normalizeKind(kind: string): string {
    if (kind === 'video' || kind === 'audio' || kind === 'file' || kind === 'image') {
      return kind;
    }
    return 'image';
  }

  /** 兼容旧标记格式（发布端早期版本写入的纯文本帖子）。 */
  static decodeLegacy(raw: string): ForumContent {
    const content: ForumContent = new ForumContent();
    if (!raw) {
      return content;
    }
    const paid: RegExpMatchArray | null = raw.match(/【paid[:：](\d+)】([\s\S]*?)【\/paid】/);
    if (paid !== null) {
      content.price = Number(paid[1]) > 0 ? Math.trunc(Number(paid[1])) : 0;
      content.paid = paid[2].trim();
    }
    let text: string = raw.replace(/【paid[:：]\d+】[\s\S]*?【\/paid】/g, '');
    const imageMarker: RegExp = /【img\d*】\s*(https?:\/\/[^【\s]+)\s*【img\d*】/gi;
    let match: RegExpExecArray | null = imageMarker.exec(text);
    while (match !== null && content.media.length < ForumCodec.MAX_IMAGES) {
      const media: ForumMedia = new ForumMedia();
      media.kind = 'image';
      media.url = match[1];
      content.media.push(media);
      match = imageMarker.exec(text);
    }
    text = text.replace(imageMarker, ' ');
    const videoMarker: RegExp = /【video】\s*(https?:\/\/[^【\s]+)\s*【video】/gi;
    match = videoMarker.exec(text);
    while (match !== null) {
      const media: ForumMedia = new ForumMedia();
      media.kind = 'video';
      media.url = match[1];
      content.media.push(media);
      match = videoMarker.exec(text);
    }
    text = text.replace(videoMarker, ' ');
    content.text = text.trim();
    return content;
  }

  // ---------------- 便捷读取 ----------------

  static images(raw: string): string[] {
    const result: string[] = [];
    for (const media of ForumCodec.decode(raw).media) {
      if (media.kind === 'image' && result.indexOf(media.url) < 0 && result.length < ForumCodec.MAX_IMAGES) {
        result.push(media.url);
      }
    }
    return result;
  }

  static videos(raw: string): ForumMedia[] {
    return ForumCodec.byKind(raw, 'video');
  }

  static audios(raw: string): ForumMedia[] {
    return ForumCodec.byKind(raw, 'audio');
  }

  static files(raw: string): ForumMedia[] {
    return ForumCodec.byKind(raw, 'file');
  }

  private static byKind(raw: string, kind: string): ForumMedia[] {
    const result: ForumMedia[] = [];
    for (const media of ForumCodec.decode(raw).media) {
      if (media.kind === kind) {
        result.push(media);
      }
    }
    return result;
  }

  /** 列表页预览：优先正文，没有正文时用媒体类型占位。 */
  static preview(raw: string): string {
    const content: ForumContent = ForumCodec.decode(raw);
    const text: string = contentTypeText(content.text);
    if (text.length > 0) {
      return text;
    }
    return ForumCodec.mediaSummary(content.media);
  }

  /** 媒体徽标：['图片 3', '视频', '音乐', '附件 2']。 */
  static badges(raw: string): string[] {
    const content: ForumContent = ForumCodec.decode(raw);
    const images: number = ForumCodec.count(content.media, 'image');
    const videos: number = ForumCodec.count(content.media, 'video');
    const audios: number = ForumCodec.count(content.media, 'audio');
    const files: number = ForumCodec.count(content.media, 'file');
    const result: string[] = [];
    if (images > 0) { result.push('图片 ' + String(images)); }
    if (videos > 0) { result.push('视频 ' + String(videos)); }
    if (audios > 0) { result.push('音乐 ' + String(audios)); }
    if (files > 0) { result.push('附件 ' + String(files)); }
    return result;
  }

  static count(media: ForumMedia[], kind: string): number {
    let total: number = 0;
    for (const item of media) {
      if (item.kind === kind) { total++; }
    }
    return total;
  }

  static mediaSummary(media: ForumMedia[]): string {
    const images: number = ForumCodec.count(media, 'image');
    const videos: number = ForumCodec.count(media, 'video');
    const audios: number = ForumCodec.count(media, 'audio');
    const files: number = ForumCodec.count(media, 'file');
    if (images > 0) { return '[图片] ' + String(images) + ' 张'; }
    if (videos > 0) { return '[视频] 帖子包含视频'; }
    if (audios > 0) { return '[音乐] 帖子包含音频'; }
    if (files > 0) { return '[附件] ' + String(files) + ' 个文件'; }
    return '';
  }
}

/** 去掉 HTML 标签后的纯文本（与 CommunityApi.plainText 保持一致的轻量版）。 */
function contentTypeText(raw: string): string {
  if (!raw) {
    return '';
  }
  let text: string = raw;
  text = text.replace(/<br\s*\/?>/gi, '\n');
  text = text.replace(/<[^>]+>/g, '');
  text = text.replace(/&nbsp;/g, ' ');
  text = text.replace(/&amp;/g, '&');
  text = text.replace(/&lt;/g, '<');
  text = text.replace(/&gt;/g, '>');
  return text.trim();
}

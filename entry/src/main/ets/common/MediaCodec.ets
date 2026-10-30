import { ForumCodec, ForumMedia } from './ForumCodec';

/**
 * 聊天室 / 私聊的消息编码（富媒体版）。
 *
 * lts.php 只接收纯文本 message，所以富内容统一编码成 `#WY#` + JSON：
 * - `kind = rich`：一段文字 + 任意条媒体（图片 / 视频 / 音乐 / 附件），与论坛的媒体模型一致；
 * - 仍保留 image / video / file / voice / redpacket / card / quote / system / friend_* 等历史类型，
 *   老消息照旧可以解析与渲染；
 * - 纯文本不加前缀，服务端网页端仍然能正常显示。
 */
export class ChatCard {
  kind: string = 'text';
  text: string = '';
  url: string = '';
  title: string = '';
  amount: number = 0;
  count: number = 0;
  blessing: string = '';
  target: string = '';
  quoteUser: string = '';
  quoteText: string = '';
  fromName: string = '';
  time: string = '';
  /** 富媒体列表（kind = rich 时使用；与论坛共用 ForumMedia）。 */
  media: ForumMedia[] = [];

  hasMedia(): boolean {
    return this.media.length > 0;
  }
}

export class MediaCodec {
  static readonly PREFIX: string = '#WY#';

  static encode(card: ChatCard): string {
    if (card.kind === 'text') {
      return card.text;
    }
    if (card.kind === 'rich' && card.media.length === 0) {
      // 没有媒体的"富消息"退化成普通文本，避免多包一层 JSON。
      return card.text;
    }
    return MediaCodec.PREFIX + JSON.stringify(card);
  }

  static decode(content: string): ChatCard {
    const card: ChatCard = new ChatCard();
    card.text = content;
    const value: string = content !== undefined ? content.trim() : '';
    if (!value.startsWith(MediaCodec.PREFIX)) {
      return card;
    }
    try {
      const raw = JSON.parse(value.substring(MediaCodec.PREFIX.length)) as ChatCard;
      card.kind = typeof raw.kind === 'string' && raw.kind.length > 0 ? raw.kind : 'text';
      card.text = typeof raw.text === 'string' ? raw.text : '';
      card.url = typeof raw.url === 'string' ? raw.url : '';
      card.title = typeof raw.title === 'string' ? raw.title : '';
      card.amount = Number.isFinite(Number(raw.amount)) ? Number(raw.amount) : 0;
      card.count = Number.isFinite(Number(raw.count)) ? Number(raw.count) : 0;
      card.blessing = typeof raw.blessing === 'string' ? raw.blessing : '';
      card.target = typeof raw.target === 'string' ? raw.target : '';
      card.quoteUser = typeof raw.quoteUser === 'string' ? raw.quoteUser : '';
      card.quoteText = typeof raw.quoteText === 'string' ? raw.quoteText : '';
      card.fromName = typeof raw.fromName === 'string' ? raw.fromName : '';
      card.time = typeof raw.time === 'string' ? raw.time : '';
      card.media = ForumCodec.parseMedia(raw.media);
      return card;
    } catch (error) {
      return card;
    }
  }

  /** 列表 / 弹窗里的一行预览。 */
  static preview(card: ChatCard): string {
    switch (card.kind) {
      case 'rich':
        return card.text.length > 0 ? card.text : MediaCodec.mediaSummary(card.media);
      case 'image': return '[图片]';
      case 'video': return '[视频]';
      case 'file': return '[文件] ' + (card.title || card.url);
      case 'voice': return '[语音]';
      case 'redpacket': return '[红包] ' + (card.blessing || '恭喜发财');
      case 'card': return '[名片] ' + card.title;
      case 'quote':
        if (card.media.length > 0 && card.text.length === 0) {
          return '回复 ' + card.quoteUser + '：' + MediaCodec.mediaSummary(card.media);
        }
        return '回复 ' + card.quoteUser + '：' + card.quoteText + (card.text.length > 0 ? ' ' + card.text : '');
      case 'system': return card.text;
      case 'friend_request': return '[好友申请] ' + (card.fromName || card.target);
      case 'friend_accept': return '[好友申请已通过]';
      case 'friend_reject': return '[好友申请被拒绝]';
      default: return card.text;
    }
  }

  /** 媒体摘要：给没有文字的富消息一个可读的替代文本。 */
  static mediaSummary(media: ForumMedia[]): string {
    let images: number = 0;
    let videos: number = 0;
    let audios: number = 0;
    let files: number = 0;
    for (const item of media) {
      if (item.kind === 'image') { images++; }
      else if (item.kind === 'video') { videos++; }
      else if (item.kind === 'audio') { audios++; }
      else { files++; }
    }
    const parts: string[] = [];
    if (images > 0) { parts.push('图片×' + String(images)); }
    if (videos > 0) { parts.push('视频×' + String(videos)); }
    if (audios > 0) { parts.push('音乐×' + String(audios)); }
    if (files > 0) { parts.push('附件×' + String(files)); }
    return parts.length > 0 ? '[' + parts.join(' · ') + ']' : '[富媒体消息]';
  }

  static images(card: ChatCard): string[] {
    const result: string[] = [];
    for (const item of card.media) {
      if (item.kind === 'image') { result.push(item.url); }
    }
    if (result.length === 0 && card.kind === 'image' && card.url.length > 0) {
      result.push(card.url);
    }
    return result;
  }

  static mediaOf(card: ChatCard, kind: string): ForumMedia[] {
    const result: ForumMedia[] = [];
    for (const item of card.media) {
      if (item.kind === kind) { result.push(item); }
    }
    if (result.length === 0 && card.url.length > 0) {
      // 兼容旧版单媒体卡片：kind=video/file/voice 时 url 字段即媒体地址。
      if ((card.kind === 'video' && kind === 'video') || (card.kind === 'file' && kind === 'file') ||
        (card.kind === 'voice' && kind === 'audio')) {
        const legacy: ForumMedia = new ForumMedia();
        legacy.kind = kind;
        legacy.url = card.url;
        legacy.title = card.title;
        result.push(legacy);
      }
    }
    return result;
  }
}

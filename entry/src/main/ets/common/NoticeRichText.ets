import common from '@ohos.app.ability.common';
import media from '@ohos.multimedia.media';
import { ArkCard, parseArkCard } from './ArkCard';
import { ChatCardMessage, parseXmlCard, XmlCard } from '../components/ChatCardMessage';
import { PlatformLinks } from './PlatformLinks';
import { Ui } from './Ui';

/** 公告富文本中的一段行内文字。 */
class NoticeSpan {
  text: string = '';
  bold: boolean = false;
  accent: boolean = false;
  href: string = '';

  constructor(text: string, bold: boolean, accent: boolean, href: string = '') {
    this.text = text;
    this.bold = bold;
    this.accent = accent;
    this.href = href;
  }
}

/** 公告富文本中的一个块级元素。 */
class NoticeBlock {
  kind: string = 'p';
  spans: NoticeSpan[] = [];
  image: string = '';
  cardKind: string = 'link';
  cardTitle: string = '';
  cardDesc: string = '';
  cardSource: string = '';
  cardUrl: string = '';
  cardThumb: string = '';
  cardDuration: number = 0;

  constructor(kind: string) {
    this.kind = kind;
  }
}

/**
 * 纯 ArkTS 富文本渲染：
 * 不依赖 RichText / WebView，解析公告接口返回的常用 HTML 片段，
 * 段落、标题、列表、加粗、链接、图片、分割线都用 ArkUI 原生组件绘制。
 */
@Component
export struct NoticeRichText {
  @Prop @Watch('onHtmlChanged') html: string = '';
  @Prop dark: boolean = true;
  @Prop fontScale: number = 1;
  @State private blocks: NoticeBlock[] = [];
  @State private playingUrl: string = '';
  @State private audioPositionMs: number = 0;
  @State private audioDurationMs: number = 0;
  private audioPlayer?: media.AVPlayer;

  aboutToAppear(): void {
    this.parse();
  }

  aboutToDisappear(): void {
    void this.stopVoice();
  }

  private onHtmlChanged(): void {
    this.parse();
  }

  private decode(text: string): string {
    return text
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;/gi, "'")
      .replace(/&#x27;/gi, "'");
  }

  private parseSpans(raw: string): NoticeSpan[] {
    const spans: NoticeSpan[] = [];
    let bold: boolean = false;
    let accent: boolean = false;
    let href: string = '';
    const tokens: string[] = raw.split(/(<[^>]+>)/);
    for (const token of tokens) {
      if (token.length === 0) { continue; }
      if (token.startsWith('<')) {
        const tag: string = token.toLowerCase();
        if (tag.startsWith('</strong') || tag.startsWith('</b>')) { bold = false; }
        else if (tag.startsWith('<strong') || tag.startsWith('<b>')) { bold = true; }
        else if (tag.startsWith('</a')) { accent = false; href = ''; }
        else if (tag.startsWith('<a')) {
          accent = true;
          const matched: RegExpMatchArray | null = token.match(/href\s*=\s*["']([^"']+)["']/i);
          href = matched !== null && matched.length > 1 ? this.decode(matched[1]) : '';
        }
        continue;
      }
      const text: string = this.decode(token);
      if (text.length > 0) {
        spans.push(new NoticeSpan(text, bold, accent, href));
      }
    }
    return spans;
  }

  private async openLink(link: string): Promise<void> {
    const value: string = (link || '').trim();
    if (value.length === 0) { return; }
    const uri: string = /^[a-z][a-z0-9+.-]*:/i.test(value)
      ? value
      : 'https://www.baidu.com/s?wd=' + encodeURIComponent(value);
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: uri
      });
    } catch (_) {
      // 未安装 QQ 时，mqqapi 群链接回退到 QQ 群官网。
      if (/^(mqqapi|mqq|qq):\/\//i.test(uri)) {
        try {
          const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
          await context.startAbility({ action: 'ohos.want.action.viewData', uri: 'https://qun.qq.com/' });
          return;
        } catch (_) { }
      }
    }
  }

  private cardBlock(raw: string): NoticeBlock | undefined {
    if (raw.startsWith('<msg')) {
      const ark: ArkCard | undefined = parseArkCard(raw);
      if (ark === undefined) { return undefined; }
      const block: NoticeBlock = new NoticeBlock('card');
      block.cardKind = ark.audioUrl.length > 0 ? 'audio' : 'link';
      block.cardTitle = ark.title;
      block.cardDesc = ark.desc.replace(/<[^>]+>/g, '').trim();
      block.cardSource = ark.source;
      block.cardUrl = ark.audioUrl.length > 0 ? ark.audioUrl : ark.scheme;
      block.cardThumb = ark.cover;
      block.cardDuration = ark.audioDuration > 0 ? ark.audioDuration * 1000 : 0;
      return block;
    }
    const card: XmlCard | undefined = parseXmlCard(raw);
    if (card === undefined) { return undefined; }
    const block: NoticeBlock = new NoticeBlock('card');
    block.cardKind = card.kind;
    block.cardTitle = card.title;
    block.cardDesc = card.desc;
    block.cardSource = card.source;
    block.cardUrl = card.url;
    block.cardThumb = card.poster.length > 0 ? card.poster : card.thumb;
    return block;
  }

  private async stopVoice(): Promise<void> {
    const player: media.AVPlayer | undefined = this.audioPlayer;
    this.audioPlayer = undefined;
    this.playingUrl = '';
    this.audioPositionMs = 0;
    this.audioDurationMs = 0;
    if (player !== undefined) {
      try { await player.release(); } catch (_) { }
    }
  }

  private async toggleVoice(url: string): Promise<void> {
    const value: string = (url || '').trim();
    if (value.length === 0) { return; }
    if (this.playingUrl === value) {
      await this.stopVoice();
      return;
    }
    await this.stopVoice();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.audioPlayer = player;
      this.playingUrl = value;
      player.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          player.prepare().catch(() => { });
        } else if (state === 'prepared') {
          this.audioDurationMs = player.duration;
          player.play().catch(() => { });
        } else if (state === 'completed') {
          if (this.playingUrl === value) {
            this.playingUrl = '';
            this.audioPositionMs = 0;
          }
        }
      });
      player.on('timeUpdate', (time: number) => {
        if (this.playingUrl === value) { this.audioPositionMs = time; }
      });
      player.on('durationUpdate', (duration: number) => {
        if (this.playingUrl === value) { this.audioDurationMs = duration; }
      });
      player.url = value;
    } catch (_) {
      this.playingUrl = '';
      this.audioPlayer = undefined;
    }
  }

  private seekVoice(percent: number): void {
    if (this.audioDurationMs <= 0 || this.audioPlayer === undefined) { return; }
    const ratio: number = Math.max(0, Math.min(100, percent)) / 100;
    const target: number = Math.round(this.audioDurationMs * ratio);
    this.audioPositionMs = target;
    this.audioPlayer.seek(target, 2 as media.SeekMode);
  }

  private parse(): void {
    const result: NoticeBlock[] = [];
    let source: string = this.html;
    // 脚本、样式不参与渲染，避免公告内容执行任何代码。
    source = source.replace(/<script[\s\S]*?<\/script>/gi, '');
    source = source.replace(/<style[\s\S]*?<\/style>/gi, '');
    // 图片单独成块，并用占位符保留正文顺序。
    const imagePattern: RegExp = /<img[^>]*src=["']([^"']+)["'][^>]*>/gi;
    const imageUrls: string[] = [];
    source = source.replace(imagePattern, (match: string, src: string): string => {
      imageUrls.push(src);
      return '\n[[IMG:' + String(imageUrls.length - 1) + ']]\n';
    });
    // 聊天室同款 XML 卡片：语音、视频、链接等。
    const xmlBlocks: NoticeBlock[] = [];
    const xmlPattern: RegExp = /<msg[\s\S]*?<\/msg>|<card[\s\S]*?<\/card>|<card[^>]*\/>/gi;
    let xmlMatch: RegExpExecArray | null = xmlPattern.exec(source);
    while (xmlMatch !== null) {
      const card: NoticeBlock | undefined = this.cardBlock(xmlMatch[0].trim());
      if (card !== undefined) { xmlBlocks.push(card); }
      xmlMatch = xmlPattern.exec(source);
    }
    source = source.replace(xmlPattern, '\n');
    // 列表项保留项目符号。
    source = source.replace(/<li[^>]*>/gi, '\n• ');
    source = source.replace(/<\/li>/gi, '\n');
    source = source.replace(/<hr[^>]*>/gi, '\n[[HR]]\n');
    source = source.replace(/<br\s*\/?>/gi, '\n');
    source = source.replace(/<\/?(p|div|h[1-6]|ul|ol|blockquote|section|article|tr)[^>]*>/gi, '\n');
    const lines: string[] = source.split('\n');
    for (const line of lines) {
      const text: string = line.trim();
      if (text.length === 0) { continue; }
      if (text === '[[HR]]') {
        result.push(new NoticeBlock('hr'));
        continue;
      }
      if (text.startsWith('[[IMG:')) {
        const end: number = text.indexOf(']]');
        const index: number = Number(text.substring(6, end));
        if (Number.isInteger(index) && index >= 0 && index < imageUrls.length) {
          const imageBlock: NoticeBlock = new NoticeBlock('image');
          imageBlock.image = imageUrls[index];
          result.push(imageBlock);
        }
        continue;
      }
      const block: NoticeBlock = new NoticeBlock('p');
      block.spans = this.parseSpans(text);
      if (block.spans.length > 0) { result.push(block); }
    }
    for (const card of xmlBlocks) {
      result.push(card);
    }
    if (result.length === 0) {
      const empty: NoticeBlock = new NoticeBlock('p');
      empty.spans = [new NoticeSpan('暂无公告', false, false)];
      result.push(empty);
    }
    this.blocks = result;
  }

  private linkOf(block: NoticeBlock): string {
    for (const span of block.spans) {
      if (span.href.length > 0) { return span.href; }
    }
    return '';
  }

  @Builder
  private blockView(block: NoticeBlock) {
    if (block.kind === 'image') {
      Image(block.image)
        .width('100%')
        .borderRadius('12vp')
        .objectFit(ImageFit.Contain)
    } else if (block.kind === 'hr') {
      Divider()
        .strokeWidth(1)
        .color(Ui.divider(this.dark))
        .margin({ top: '6vp', bottom: '6vp' })
    } else if (block.kind === 'card') {
      ChatCardMessage({
        kind: block.cardKind,
        title: block.cardTitle,
        desc: block.cardDesc,
        source: block.cardSource,
        url: block.cardUrl,
        button: '打开',
        thumb: block.cardThumb,
        poster: block.cardThumb,
        platformKey: PlatformLinks.detect(block.cardUrl),
        playing: block.cardKind === 'audio' && this.playingUrl === block.cardUrl,
        positionMs: block.cardKind === 'audio' && this.playingUrl === block.cardUrl ? this.audioPositionMs : 0,
        durationMs: block.cardDuration > 0 ? block.cardDuration :
          (block.cardKind === 'audio' && this.playingUrl === block.cardUrl ? this.audioDurationMs : 0),
        onTap: (): void => {
          if (block.cardKind === 'audio') {
            void this.toggleVoice(block.cardUrl);
          } else if (block.cardUrl.length > 0) {
            void this.openLink(block.cardUrl);
          }
        },
        onSeekPercent: (percent: number): void => { this.seekVoice(percent); }
      })
    } else {
      Text() {
        ForEach(block.spans, (span: NoticeSpan) => {
          Span(span.text)
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(span.accent || span.href.length > 0 ? Ui.accent(this.dark) : Ui.ink(this.dark))
        }, (span: NoticeSpan, index: number) => 'notice-span-' + index + '-' + span.text)
      }
        .width('100%')
        .lineHeight(Ui.fs('21vp', this.fontScale))
        .fontColor(Ui.ink(this.dark))
        .onClick(() => {
          const link: string = this.linkOf(block);
          if (link.length > 0) { void this.openLink(link); }
        })
    }
  }

  build() {
    Column({ space: '8vp' }) {
      ForEach(this.blocks, (block: NoticeBlock, index: number) => {
        this.blockView(block)
      }, (block: NoticeBlock, index: number) => 'notice-block-' + index + '-' + block.kind)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }
}

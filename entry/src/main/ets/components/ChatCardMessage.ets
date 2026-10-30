import { Ui } from '../common/Ui';

/**
 * XML 卡片消息（QQ 风格）通用模型。
 *
 * 统一标签：`<card type="..." title="" desc="" source="" url="" button="" icon="" ... />`
 * type 取值（不写默认 link）：
 * - link      链接卡片：title/desc/source/url/button
 * - image     图片：url（原图）/thumb（缩略图）/title
 * - video     视频：url/poster/title
 * - audio     音乐：url/title/artist
 * - file      文件：url/name/size
 * - redpacket 红包：title/amount/count/blessing
 * - contact   名片：user/name/desc
 * - location  位置：name/address/lat/lng
 * - text      纯文本气泡：title（正文）
 * 也支持 <title>…</title> 这类子标签写法。
 */
export class XmlCard {
  kind: string = 'link';
  title: string = '';
  desc: string = '';
  source: string = '';
  url: string = '';
  button: string = '查看';
  icon: string = '';
  thumb: string = '';
  poster: string = '';
  artist: string = '';
  name: string = '';
  size: string = '';
  amount: string = '';
  count: string = '';
  blessing: string = '';
  user: string = '';
  address: string = '';
  lat: string = '';
  lng: string = '';
}

const KNOWN_FIELDS: string[] = [
  'type', 'title', 'desc', 'source', 'url', 'button', 'icon', 'thumb', 'poster', 'artist',
  'name', 'size', 'amount', 'count', 'blessing', 'user', 'address', 'lat', 'lng'
];

export function parseXmlCard(content: string): XmlCard | undefined {
  const text: string = (content || '').trim();
  if (!text.startsWith('<card')) { return undefined; }
  const card: XmlCard = new XmlCard();
  const kind: string = readAttr(text, 'type');
  if (kind.length > 0) { card.kind = kind.toLowerCase(); }
  card.title = readAttr(text, 'title') || readTag(text, 'title');
  card.desc = readAttr(text, 'desc') || readTag(text, 'desc');
  card.source = readAttr(text, 'source') || readTag(text, 'source');
  card.url = readAttr(text, 'url') || readTag(text, 'url');
  card.icon = readAttr(text, 'icon');
  card.thumb = readAttr(text, 'thumb');
  card.poster = readAttr(text, 'poster');
  card.artist = readAttr(text, 'artist') || readTag(text, 'artist');
  card.name = readAttr(text, 'name') || readTag(text, 'name');
  card.size = readAttr(text, 'size');
  card.amount = readAttr(text, 'amount');
  card.count = readAttr(text, 'count');
  card.blessing = readAttr(text, 'blessing') || readTag(text, 'blessing');
  card.user = readAttr(text, 'user');
  card.address = readAttr(text, 'address') || readTag(text, 'address');
  card.lat = readAttr(text, 'lat');
  card.lng = readAttr(text, 'lng');
  const button: string = readAttr(text, 'button');
  if (button.length > 0) { card.button = button; }
  if (card.title.length === 0 && card.desc.length === 0 && card.name.length === 0 &&
    card.url.length === 0 && card.address.length === 0) {
    return undefined;
  }
  return card;
}

/** 组装卡片（发送端用）：只写有值的属性。 */
export function buildXmlCard(card: XmlCard): string {
  let xml: string = '<card type="' + escapeAttr(card.kind) + '"';
  for (const field of KNOWN_FIELDS) {
    if (field === 'type') { continue; }
    const value: string = fieldValue(card, field);
    if (value.length > 0) { xml += ' ' + field + '="' + escapeAttr(value) + '"'; }
  }
  return xml + '/>';
}

function fieldValue(card: XmlCard, field: string): string {
  if (field === 'title') { return card.title; }
  if (field === 'desc') { return card.desc; }
  if (field === 'source') { return card.source; }
  if (field === 'url') { return card.url; }
  if (field === 'button') { return card.button; }
  if (field === 'icon') { return card.icon; }
  if (field === 'thumb') { return card.thumb; }
  if (field === 'poster') { return card.poster; }
  if (field === 'artist') { return card.artist; }
  if (field === 'name') { return card.name; }
  if (field === 'size') { return card.size; }
  if (field === 'amount') { return card.amount; }
  if (field === 'count') { return card.count; }
  if (field === 'blessing') { return card.blessing; }
  if (field === 'user') { return card.user; }
  if (field === 'address') { return card.address; }
  if (field === 'lat') { return card.lat; }
  if (field === 'lng') { return card.lng; }
  return '';
}

function decodeEntities(value: string): string {
  return (value || '')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function readAttr(text: string, name: string): string {
  const pattern: RegExp = new RegExp(name + '\\s*=\\s*"([^"]*)"', 'i');
  const matched: RegExpMatchArray | null = text.match(pattern);
  return matched !== null && matched.length > 1 ? decodeEntities(matched[1].trim()) : '';
}

function readTag(text: string, name: string): string {
  const pattern: RegExp = new RegExp('<' + name + '>([\\s\\S]*?)</' + name + '>', 'i');
  const matched: RegExpMatchArray | null = text.match(pattern);
  return matched !== null && matched.length > 1 ? decodeEntities(matched[1].trim()) : '';
}

function escapeAttr(value: string): string {
  return (value || '').replace(/"/g, '&quot;');
}

/**
 * 卡片渲染：按 kind 分支，统一玻璃卡外壳，内部按类型给不同内容。
 */
@Component
export struct ChatCardMessage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @Prop kind: string = 'link';
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop source: string = '';
  @Prop url: string = '';
  @Prop button: string = '查看';
  @Prop thumb: string = '';
  @Prop poster: string = '';
  @Prop name: string = '';
  @Prop fileSize: string = '';
  @Prop amount: string = '';
  @Prop count: string = '';
  @Prop blessing: string = '';
  @Prop address: string = '';
  /** 音频卡：是否正在播放（由页面传入）。 */
  @Prop playing: boolean = false;
  @Prop positionMs: number = 0;
  @Prop durationMs: number = 0;
  onTap: () => void = (): void => {};
  /** 拖动进度条：回传 0~100 的百分比。 */
  onSeekPercent: (percent: number) => void = (percent: number): void => {};

  private accentText(): string {
    return Ui.fs(this.kind === 'redpacket' ? '15vp' : '13.5vp', this.fontScale);
  }

  private headLine(): string {
    if (this.kind === 'file') { return this.name.length > 0 ? this.name : '文件'; }
    if (this.kind === 'audio') { return this.title.length > 0 ? this.title : '音乐'; }
    if (this.kind === 'video') { return this.title.length > 0 ? this.title : '视频'; }
    if (this.kind === 'image') { return this.title.length > 0 ? this.title : '图片'; }
    if (this.kind === 'location') { return this.name.length > 0 ? this.name : '位置'; }
    if (this.kind === 'contact') { return this.title.length > 0 ? this.title : '名片'; }
    if (this.kind === 'redpacket') { return this.title.length > 0 ? this.title : '红包'; }
    return this.title.length > 0 ? this.title : '卡片消息';
  }

  private subLine(): string {
    if (this.kind === 'file') { return (this.fileSize.length > 0 ? this.fileSize + ' · ' : '') + '点击下载'; }
    if (this.kind === 'audio') { return this.desc.length > 0 ? this.desc : '点击播放'; }
    if (this.kind === 'video') { return this.desc.length > 0 ? this.desc : '点击播放'; }
    if (this.kind === 'location') { return this.address; }
    if (this.kind === 'contact') { return this.desc.length > 0 ? this.desc : '个人名片'; }
    if (this.kind === 'redpacket') {
      const money: string = this.amount.length > 0 ? '￥' + this.amount : '红包';
      const num: string = this.count.length > 0 ? ' · ' + this.count + ' 个' : '';
      return money + num + (this.blessing.length > 0 ? ' · ' + this.blessing : '');
    }
    return this.desc;
  }

  private clockOf(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const min: number = Math.floor(total / 60);
    const sec: number = total % 60;
    return (min < 10 ? '0' : '') + String(min) + ':' + (sec < 10 ? '0' : '') + String(sec);
  }

  private progressPercent(): number {
    if (this.durationMs <= 0) { return 0; }
    const ratio: number = this.positionMs / this.durationMs;
    return Math.max(0, Math.min(100, Math.round(ratio * 100)));
  }

  private coverUrl(): string {
    return this.poster.length > 0 ? this.poster : this.thumb;
  }

  build() {
    Column({ space: '8vp' }) {
      // 视频卡：上方 16:9 封面 + 播放图标 + 时长角标，点封面直接播放。
      if (this.kind === 'video' && this.coverUrl().length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.coverUrl())
            .width('210vp')
            .height('118vp')
            .borderRadius('10vp')
            .objectFit(ImageFit.Cover)
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(Ui.fs('34vp', this.fontScale))
            .fontColor(['#FFFFFF'])
          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize(Ui.fs('9vp', this.fontScale))
              .fontColor('#FFFFFF')
              .padding({ left: '5vp', right: '5vp' })
              .borderRadius('4vp')
              .backgroundColor('#99000000')
              .align(Alignment.BottomEnd)
              .margin({ right: '6vp', bottom: '6vp' })
          }
        }
          .width('210vp')
          .height('118vp')
          .onClick(() => { this.onTap(); })
      }
      Row({ space: '10vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('40vp')
            .height('40vp')
            .borderRadius('12vp')
            .linearGradient({
              angle: 140,
              colors: this.kind === 'redpacket'
                ? [[Ui.gold(this.darkTheme), 0], ['#FF8A3D', 1]]
                : [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
            })
          if (this.kind === 'audio') {
            SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(Ui.fs('18vp', this.fontScale))
              .fontColor(['#FFFFFF'])
          } else {
            Text(this.source.length > 0 ? this.source.substring(0, 1) : (this.kind === 'redpacket' ? '红' : '卡'))
              .fontSize(Ui.fs('16vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
        }
          .width('40vp')
          .height('40vp')
        Column({ space: '3vp' }) {
          Text(this.headLine())
            .fontSize(this.accentText())
            .fontWeight(FontWeight.Bold)
            .fontColor(this.kind === 'redpacket' ? Ui.gold(this.darkTheme) : Ui.ink(this.darkTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.kind === 'audio') {
            // 可拖动进度条：拖动/点击都会回传百分比，由页面执行 seek。
            Slider({
              value: this.positionMs,
              min: 0,
              max: this.durationMs > 0 ? this.durationMs : 1,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .selectedColor(Ui.accent(this.darkTheme))
              .trackColor(Ui.glassRing(this.darkTheme))
              .blockColor(Ui.accentStrong(this.darkTheme))
              .trackThickness('3vp')
              .showSteps(false)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.onSeekPercent(this.durationMs > 0 ? Math.round(value * 100 / this.durationMs) : 0);
              })
            Text(this.clockOf(this.positionMs) + ' / ' + (this.durationMs > 0 ? this.clockOf(this.durationMs) : '--:--'))
              .fontSize(Ui.fs('9.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .width('100%')
          }
          if (this.subLine().length > 0) {
            Text(this.subLine())
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.inkSoft(this.darkTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      Row({ space: '6vp' }) {
        Text(this.source.length > 0 ? this.source : '无音影视')
          .fontSize(Ui.fs('9.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(1)
        if (this.kind === 'audio') {
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(Ui.fs('16vp', this.fontScale))
            .fontColor([Ui.accentStrong(this.darkTheme)])
        } else {
          Text(this.kind === 'redpacket' ? '领取' : this.button)
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.accentStrong(this.darkTheme))
          .height('22vp')
          .padding({ left: '10vp', right: '10vp' })
          .borderRadius('11vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
    }
      .width('230vp')
      .padding('10vp')
      .borderRadius('14vp')
      .backgroundColor(this.darkTheme ? Ui.glassTintSoft(this.darkTheme) : '#FFFFFFFF')
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
      .onClick(() => { this.onTap(); })
  }
}

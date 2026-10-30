import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ChatAlertInfo, ChatAlertService } from '../common/ChatAlertService';
import { Logger } from '../common/Logger';
import { Ui, UiMotion } from '../common/Ui';

/** 从顶部提醒进入聊天页时的路由参数，与 ChatRoomPage 读取的字段保持一致。 */
class ChatNoticeParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class ChatNoticeRoute {
  url: string = 'pages/ChatRoomPage';
  params: ChatNoticeParams;

  constructor(room: string, peer: string, title: string) {
    this.params = new ChatNoticeParams();
    this.params.room = room;
    this.params.peer = peer;
    this.params.title = title;
  }
}

/** 芯片按钮参数：单对象传参，避免 @Builder 多参数按值传递带来的刷新差异。 */
class NoticeChip {
  label: string = '';
  action: () => void = (): void => {};
  accent: boolean = false;
}

/**
 * 聊天室实时消息提醒 · 顶部弹窗。
 *
 * 交互参考 QQ / 微信的横幅通知：
 * - 从顶部滑入，展示会话名、发送者与消息预览，7 秒无操作自动收起；
 * - 点卡片主体直接进入对应聊天室（群聊 / 私聊自动区分）；
 * - 点「回复」展开内联输入框，可直接把文字消息发回该房间；
 * - 多条新消息排队展示，右上角显示待看条数。
 *
 * 布局：根节点是"整屏透明锚点容器"，用构造参数 alignContent 决定卡片落点
 * （顶部=屏幕正上方 / 居中 / Dock 栏上方），卡片区域正常吃掉点击，
 * 空白区域以 HitTestMode.Transparent 透传给页面，不拦截页面其它触摸。
 * 组件本身不轮询，状态全部来自 ChatAlertService（AppStorage 发布）。
 */
@Component
export struct ChatNoticeBanner {
  @StorageLink('chatAlertVisible') @Watch('onVisibleChanged') private visible: boolean = false;
  @StorageLink('chatAlertInfo') @Watch('onInfoChanged') private info: ChatAlertInfo = new ChatAlertInfo();
  @StorageLink('chatAlertPending') private pending: number = 0;
  @StorageLink('chatDndEnabled') private dnd: boolean = false;
  @StorageLink('chatBannerEnabled') private bannerEnabled: boolean = true;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  // Dock 栏 + 手势条的占位高度（HomePage 发布），用于把"底部"锚点放到导航栏上方。
  @StorageLink('navClearance') private navClearance: number = 102;
  // 弹窗位置：top（默认，贴紧屏幕正上方）/ center / bottom，offset 为垂直微调（vp）。
  @StorageLink('chatAlertPosition') private alertPosition: string = 'top';
  @StorageLink('chatAlertOffset') private alertOffset: number = 0;
  @StorageLink('fontScale') private fontScale: number = 1;
  @State private expanded: boolean = false;
  @State private replyText: string = '';
  @State private sending: boolean = false;
  @State private notice: string = '';
  private autoTimer: number = -1;
  /** 上一次渲染的提醒序号：同序号代表"同一房间的内容实时刷新"，不重置输入状态。 */
  private lastVersion: number = -1;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  /** 是否真正展示：免打扰或关闭顶部弹窗时一律隐藏。 */
  private active(): boolean {
    return this.visible && !this.dnd && this.bannerEnabled;
  }

  private onVisibleChanged(): void {
    if (!this.active()) {
      this.clearTimer();
      this.expanded = false;
      this.replyText = '';
      this.notice = '';
      return;
    }
    this.armTimer();
  }

  private onInfoChanged(): void {
    const same: boolean = this.info.version === this.lastVersion;
    this.lastVersion = this.info.version;
    if (same) {
      // 同一房间来了新消息：内容就地刷新，只重新计时；保留回复草稿与展开状态。
      this.armTimer();
      return;
    }
    this.clearTimer();
    this.expanded = false;
    this.replyText = '';
    this.notice = '';
    this.sending = false;
    if (!this.active()) {
      return;
    }
    this.armTimer();
  }

  /** 布防 7 秒自动收起；展开回复输入框时不倒计时。 */
  private armTimer(): void {
    this.clearTimer();
    if (!this.active() || this.expanded) {
      return;
    }
    this.autoTimer = setTimeout(() => {
      this.autoTimer = -1;
      if (!this.expanded) {
        ChatAlertService.dismiss();
      }
    }, 7000);
  }

  private clearTimer(): void {
    if (this.autoTimer >= 0) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private safeBottom(): number {
    return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16;
  }

  /** 归一化后的锚点：非法值一律回到顶部（默认位置）。 */
  private place(): string {
    return this.alertPosition === 'center' || this.alertPosition === 'bottom' ? this.alertPosition : 'top';
  }

  /** 卡片在页面 Stack 内的对齐方式，与位置设置一致。 */
  private anchor(): Alignment {
    const place: string = this.place();
    if (place === 'bottom') { return Alignment.Bottom; }
    if (place === 'center') { return Alignment.Center; }
    return Alignment.Top;
  }

  /** 垂直微调距离：0~200vp，非法值按 0 处理。 */
  private shift(): number {
    return Number.isFinite(this.alertOffset) ? Math.max(0, Math.min(200, this.alertOffset)) : 0;
  }

  /** 顶栏/底栏避让高度（Dock 栏 + 手势条的占位，由 HomePage 发布），用于"Dock 栏上方"锚点。 */
  private dockClearance(): number {
    const value: number = Number.isFinite(this.navClearance) ? this.navClearance : 102;
    return Math.max(70, Math.min(280, value));
  }

  /** 顶部锚点：贴紧屏幕正上方（状态栏下 2vp 起步 + 微调）。 */
  private topMargin(): string {
    if (this.place() !== 'top') { return '0vp'; }
    return (this.safeTop() + 2 + this.shift()) + 'vp';
  }

  /** 底部锚点：紧贴 Dock 栏上边缘（不压住导航栏），微调只在该区域上方移动。 */
  private bottomMargin(): string {
    if (this.place() !== 'bottom') { return '0vp'; }
    return (this.dockClearance() + this.shift()) + 'vp';
  }

  /** 入场/退场动画：顶部从上滑入、Dock 栏上方从下滑入、居中淡入。 */
  private enterTransition(): TransitionEffect {
    const place: string = this.place();
    if (place === 'bottom') {
      return TransitionEffect.translate({ y: 120 })
        .combine(TransitionEffect.OPACITY)
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn });
    }
    if (place === 'center') {
      return TransitionEffect.OPACITY.animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn });
    }
    return TransitionEffect.translate({ y: -120 })
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn });
  }

  private glassBlur(): number {
    return Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur);
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '聊';
  }

  private title(): string {
    return this.info.title || this.info.room || '新消息';
  }

  private previewLine(): string {
    const sender: string = this.info.sender || this.title();
    const text: string = this.info.preview || '收到一条新消息';
    return sender + '：' + text;
  }

  private openChat(): void {
    const room: string = this.info.room;
    if (!room) {
      return;
    }
    try {
      ChatAlertService.markCurrentRead();
      AppStorage.setOrCreate<string>('activeChatRoom', room);
      this.clearTimer();
      // 先收起弹窗再跳转：弹窗状态由 AppStorage 发布，多个页面挂载的同一组件会一起隐藏。
      ChatAlertService.dismiss();
      router.pushUrl(new ChatNoticeRoute(room, this.info.peer, this.title())).catch((error: Error) => {
        Logger.error('CHAT_ALERT', '打开提醒对应的聊天室失败：' + String(error));
      });
      Logger.info('CHAT_ALERT', '从顶部提醒进入聊天室：' + room);
    } catch (error) {
      Logger.error('CHAT_ALERT', '打开聊天室路由异常：' + String(error));
    }
  }

  private toggleReply(): void {
    this.expanded = !this.expanded;
    this.notice = '';
    // 展开时停表，避免用户输入到一半弹窗消失；收起后重新布防。
    if (this.expanded) {
      this.clearTimer();
    } else {
      this.armTimer();
    }
  }

  private async sendReply(): Promise<void> {
    if (this.sending) {
      return;
    }
    const text: string = this.replyText.trim();
    if (text.length === 0) {
      this.notice = '请输入回复内容';
      return;
    }
    this.sending = true;
    this.notice = '';
    try {
      await ChatAlertService.reply(text);
      this.replyText = '';
      this.sending = false;
      this.notice = '已回复';
      setTimeout(() => {
        this.notice = '';
        ChatAlertService.dismiss();
      }, 600);
    } catch (error) {
      this.sending = false;
      this.notice = '回复失败：' + String(error);
      Logger.warn('CHAT_ALERT', '顶部提醒回复失败：' + String(error));
    }
  }

  private chipOf(label: string, accent: boolean, action: () => void): NoticeChip {
    const chip: NoticeChip = new NoticeChip();
    chip.label = label;
    chip.accent = accent;
    chip.action = action;
    return chip;
  }

  @Builder
  private chip(model: NoticeChip) {
    Row() {
      Text(model.label)
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontWeight(model.accent ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(model.accent ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
        .maxLines(1)
    }
      .height('28vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('14vp')
      .backgroundColor(model.accent ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: model.accent ? Ui.glassRingAccent(this.darkTheme) : Ui.glassRingSoft(this.darkTheme) })
      .accessibilityText(model.label)
      .onClick(() => { model.action(); })
  }

  build() {
    Stack({ alignContent: this.anchor() }) {
      if (this.active()) {
        Column({ space: '0vp' }) {
          Row({ space: '10vp' }) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width('36vp')
                .height('36vp')
                .borderRadius('18vp')
                .linearGradient({
                  angle: 135,
                  colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
                })
              Text(this.initial(this.info.sender || this.title()))
                .fontSize(Ui.fs('14vp', this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
              .width('36vp')
              .height('36vp')
            Column({ space: '2vp' }) {
              Row({ space: '6vp' }) {
                Text(this.title())
                  .fontSize(Ui.fs('13.5vp', this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Ui.ink(this.darkTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.info.unread > 1) {
                  // 同一房间连续多条消息时，实时显示累计条数。
                  Text(String(this.info.unread) + ' 条')
                    .fontSize(Ui.fs('9.5vp', this.fontScale))
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Ui.accentStrong(this.darkTheme))
                    .height('18vp')
                    .padding({ left: '6vp', right: '6vp' })
                    .borderRadius('9vp')
                    .backgroundColor(Ui.accentSoft(this.darkTheme))
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                }
                if (this.pending > 0) {
                  Text('+' + String(this.pending))
                    .fontSize(Ui.fs('9.5vp', this.fontScale))
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Ui.accentStrong(this.darkTheme))
                    .height('18vp')
                    .padding({ left: '6vp', right: '6vp' })
                    .borderRadius('9vp')
                    .backgroundColor(Ui.accentSoft(this.darkTheme))
                    .textAlign(TextAlign.Center)
                }
              }
                .width('100%')
              Text(this.previewLine())
                .fontSize(Ui.fs('12vp', this.fontScale))
                .lineHeight(Ui.fs('17vp', this.fontScale))
                .fontColor(Ui.inkSoft(this.darkTheme))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            Column({ space: '4vp' }) {
              Text(this.info.time)
                .fontSize(Ui.fs('9.5vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .maxLines(1)
              Text('×')
                .fontSize(Ui.fs('15vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .width('22vp')
                .height('22vp')
                .textAlign(TextAlign.Center)
                .accessibilityText('关闭消息提醒')
                .onClick(() => {
                  this.clearTimer();
                  ChatAlertService.dismiss();
                })
            }
              .alignItems(HorizontalAlign.End)
          }
            .width('100%')
            .padding({ left: '12vp', right: '10vp', top: '10vp', bottom: '8vp' })
            .alignItems(VerticalAlign.Center)
            .onClick(() => { this.openChat(); })
          Row({ space: '8vp' }) {
            if (!this.info.demo) {
              this.chip(this.chipOf(this.expanded ? '收起' : '回复', true, () => { this.toggleReply(); }))
              this.chip(this.chipOf('进入聊天室', false, () => { this.openChat(); }))
            } else {
              this.chip(this.chipOf('示例提醒 · 仅预览样式', false, () => {}))
            }
            if (this.pending > 0) {
              this.chip(this.chipOf('全部忽略', false, () => {
                this.clearTimer();
                ChatAlertService.dismissAll();
              }))
            }
            Blank()
            if (this.notice.length > 0) {
              Text(this.notice)
                .fontSize(Ui.fs('10.5vp', this.fontScale))
                .fontColor(this.notice.startsWith('已回复') ? Ui.success(this.darkTheme) : Ui.danger(this.darkTheme))
                .maxLines(1)
            }
          }
            .width('100%')
            .padding({ left: '12vp', right: '12vp', bottom: '10vp' })
            .alignItems(VerticalAlign.Center)
          if (this.expanded) {
            Row({ space: '8vp' }) {
              TextInput({ text: this.replyText, placeholder: '回复 ' + (this.info.sender || this.title()) })
                .layoutWeight(1)
                .height('38vp')
                .fontSize(Ui.fs('12.5vp', this.fontScale))
                .fontColor(Ui.ink(this.darkTheme))
                .placeholderColor(Ui.inkFaint(this.darkTheme))
                .caretColor(Ui.accent(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .borderRadius('19vp')
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
                .padding({ left: '12vp', right: '12vp' })
                .focusOnTouch(true)
                .onChange((value: string) => { this.replyText = value; })
                .onSubmit(() => { void this.sendReply(); })
              Row() {
                Text(this.sending ? '发送中…' : '发送')
                  .fontSize(Ui.fs('12.5vp', this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
              }
                .height('38vp')
                .padding({ left: '14vp', right: '14vp' })
                .borderRadius('19vp')
                .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
                .accessibilityText('发送回复')
                .onClick(() => { void this.sendReply(); })
            }
              .width('100%')
              .padding({ left: '12vp', right: '12vp', bottom: '10vp' })
              .alignItems(VerticalAlign.Center)
          }
        }
          .width('100%')
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlur())
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .shadow({ radius: 22, color: Ui.shadow(this.darkTheme), offsetY: 10 })
          .clip(true)
          .margin({ left: '10vp', right: '10vp', top: this.topMargin(), bottom: this.bottomMargin() })
          .transition(this.enterTransition())
      }
    }
      // 整屏锚点容器：用 Stack 的 alignContent 定位（构造函数参数，任何宿主都生效），
      // 不再依赖 .align()——在首页外壳（底栏对齐 Bottom）里 .align() 会被宿主覆盖。
      .width('100%')
      .height('100%')
      // 收起时透传触摸（不挡页面）；展开回复输入框时改为独占，避免打字/点按钮穿透到页面。
      .hitTestBehavior(this.expanded ? HitTestMode.Default : HitTestMode.Transparent)
      .zIndex(60)
  }
}

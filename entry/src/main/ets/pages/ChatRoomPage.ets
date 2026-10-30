import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AccountApi, ChatEntry } from '../common/AccountApi';
import { buildXmlCard, ChatCardMessage, parseXmlCard, XmlCard } from '../components/ChatCardMessage';
import { PortraitLoader } from '../common/PortraitLoader';
import { MediaSniffer, SniffResult } from '../common/MediaSniffer';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ChatAlertService } from '../common/ChatAlertService';
import { ChatMessage, CommunityApi, CommunitySession } from '../common/CommunityApi';
import { ChatService } from '../common/ChatService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { inputMethod } from '../common/compat/InputMethodCompat';
import { ChatCard, MediaCodec } from '../common/MediaCodec';
import { ForumMedia } from '../common/ForumCodec';
import { SocialStore } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { SymbolIcons } from '../common/SymbolIcons';
import { UserTitles } from '../common/UserTitles';
import { AuroraBackdrop, EmptyState, GhostButton, GlassChip, PrimaryButton } from '../common/UiWidgets';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { ArkCard, isArkCard, parseArkCard, schemeHost, schemeValue } from '../common/ArkCard';
import { ChatArchive } from '../common/ChatArchive';

class ChatRoomParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class UserRouteParams {
  account: string = '';

  constructor(account: string) {
    this.account = account;
  }
}

class UserRouteOptions {
  url: string = 'pages/UserProfilePage';
  params: UserRouteParams;

  constructor(account: string) {
    this.params = new UserRouteParams(account);
  }
}

/**
 * 聊天室 / 私聊页。
 *
 * 文本、表情、图片、视频、文件、语音、红包、引用、名片、系统提示都通过
 * MediaCodec 编码在 lts.php 的文本 message 中；发送采用乐观插入，失败可重发。
 */
@Entry
@Component
struct ChatRoomPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private messages: ChatMessage[] = [];
  @State private draft: string = '';
  @State private loading: boolean = false;
  @State private sending: boolean = false;
  @State private errorText: string = '';
  @State private loggedIn: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private room: string = '';
  // 私聊对象（friendchat/echochat 双人聊天）。
  @State private peer: string = '';
  private pendingPeer: string = '';
  @State private title: string = '';
    @State private privateMode: boolean = false;
  @State private onlineCount: number = 0;
  @State private viewportWidth: number = 360;
  @State private historyPage: number = 1;
  @State private loadingHistory: boolean = false;
  @State private showEmoji: boolean = false;
  @State private emojiTab: number = 0;
  @State private showPlus: boolean = false;
  @State private showMembers: boolean = false;
  @State private showMenu: boolean = false;
  @State private showInfo: boolean = false;
  @State private showUrlDialog: boolean = false;
  @State private showRedPacket: boolean = false;
  // 富媒体输入：图片 / 视频 / 音乐 / 附件，先攒在 draftMedia 里，随文字一起发成一条 rich 消息。
  @State private mediaKind: string = 'image';
  @State private urlValue: string = '';
  @State private mediaTitle: string = '';
  @State private mediaPoster: string = '';
  @State private draftMedia: ForumMedia[] = [];
  // 点了哪条音乐消息：点击后就地展开一个音频播放器（QQ 式：点卡片即播）。
  @State private playingAudio: string = '';
  // 正在播放的消息 id（同一 URL 发多次也能区分）。
  @State private playingMessageId: number = 0;
  // 音频播放进度（毫秒），由 AVPlayer.timeUpdate 驱动。
  @State private audioPosMs: number = 0;
  @State private audioDurMs: number = 0;
  // 拖动进度条期间暂停 timeUpdate 覆盖，避免进度被拉回。
  @State private audioSeeking: boolean = false;
  // 他人头像：账号 → PixelMap（http 拉取后缓存，避免 Image 直连失败）。
  @State private portraits: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  // 视频消息：已嗅探出的直链与对应原始地址。
  @State private resolvedVideo: string = '';
  @State private resolvedVideoKey: string = '';
  // XML 视频卡片：点开后就地播放的地址。
  @State private cardVideoUrl: string = '';
  // 上次处理过的剪贴板链接，避免重复发送。
  private lastClipUrl: string = '';
  @State private redAmount: string = '';
  @State private redCount: string = '';
  @State private redBlessing: string = '';
  @State private actionMessage: ChatMessage = new ChatMessage();
  @State private actionVisible: boolean = false;
  @State private replyTo: ChatMessage = new ChatMessage();
  @State private replyVisible: boolean = false;
  @State private muted: boolean = false;
  @State private claimed: string[] = [];
  @State private toastText: string = '';
  @State private members: string[] = [];
  private lastId: number = 0;
  // 音乐消息：点一次播放、再点暂停；不渲染进度条。
  private audioPlayer?: media.AVPlayer;
  // 本地音频文件句柄：播放结束/停止时必须关闭，避免句柄泄漏。
  private audioFd: number = -1;
  private lastSentText: string = '';
  private lastSentAt: number = 0;
  private timerId: number = -1;
  private onlineTimer: number = -1;
  private alive: boolean = false;
  private readonly listScroller: Scroller = new Scroller();
  private readonly emojisHot: string[] = ['😀', '😂', '😍', '🤔', '😭', '😡', '👍', '🎉', '❤️', '🔥', '🌹', '👏'];
  private readonly emojisSelect: string[] = ['😎', '🤗', '😴', '😅', '🙏', '💪', '🍉', '🍺', '🎬', '🎮', '⭐', '💎'];

  aboutToAppear(): void {
    try {
      const incoming: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
      if (incoming !== undefined && incoming['target'] !== undefined && String(incoming['target']).length > 0) {
        this.peer = String(incoming['target']);
        Logger.info('CHAT_ROOM', '私聊对象=' + this.peer);
      }
    } catch (error) {
      Logger.warn('CHAT_ROOM', '读取私聊对象失败：' + String(error));
    }
    setTimeout(() => { this.ensurePortraitAll(); }, 900);
    setInterval(() => { this.ensurePortraitAll(); }, 15000);
    this.alive = true;
    // 聊天记录本地归档：懒初始化，保证 save() 真正落盘（设置页的导入导出复用同一份存储）。
    ChatArchive.init(this.getUIContext().getHostContext() as common.UIAbilityContext)
      .catch((error: Error) => { Logger.warn('CHAT_ROOM', '初始化聊天归档失败：' + String(error)); });
    try {
      const params = router.getParams() as ChatRoomParams | undefined;
      if (params && typeof params.room === 'string') {
        this.room = params.room.trim();
      }
      if (params && typeof params.peer === 'string') {
        this.peer = params.peer.trim();
      }
      if (params && typeof params.title === 'string') {
        this.title = params.title.trim();
      }
      Logger.info('CHAT_ROOM', '进入聊天页：房间=' + this.room + '，私聊对象=' + this.peer);
    } catch (error) {
      Logger.warn('CHAT_ROOM', '读取聊天页参数失败：' + String(error));
    }
    void this.prepare();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.closeAudioFd();
    void this.stopAudio();
    this.stopTimers();
    this.releaseActiveRoom();
  }

  onPageHide(): void {
    this.stopTimers();
    this.stopPolling();
    this.releaseActiveRoom();
  }

  onPageShow(): void {
    if (this.alive && this.loggedIn) {
      this.startPolling();
      this.startOnlineTimer();
      this.claimActiveRoom();
      // 从嗅探页返回：有结果直接播放，没有就走普通流程。
      const sniffed: string = AppStorage.get<string>('sniffedVideoUrl') || '';
      if (sniffed.length > 0) {
        AppStorage.delete('sniffedVideoUrl');
        this.cardVideoUrl = sniffed;
        Logger.info('CHAT_ROOM', '使用嗅探结果播放：' + sniffed);
      }
      void this.checkClipboard();
    }
  }

  /** 回到聊天页：读剪贴板，识别抖音/快手/B站/媒体直链 → 填输入框 + 发卡片 + 直接打开视频。 */
  private async checkClipboard(): Promise<void> {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await board.getData();
      const text: string = data.getPrimaryText();
      const url: string = this.findShareUrl(text);
      if (url.length === 0 || url === this.lastClipUrl) { return; }
      this.lastClipUrl = url;
      // 填入输入框，方便用户再补充文字
      this.draft = url;
      const platform: string = MediaSniffer.platformOf(url);
      const card: XmlCard = new XmlCard();
      card.kind = 'video';
      card.url = url;
      card.title = platform === 'bilibili' ? 'B站视频' : (platform === 'douyin' ? '抖音视频' :
        (platform === 'kuaishou' ? '快手视频' : '视频链接'));
      card.desc = '来自剪贴板 · 点击播放';
      card.source = platform === 'bilibili' ? '哔哩哔哩' : (platform === 'douyin' ? '抖音' :
        (platform === 'kuaishou' ? '快手' : '无音影视'));
      // sendText() 读的是输入框内容：先把卡片 XML 写进 draft 再发送。
      this.draft = buildXmlCard(card);
      await this.sendText();
      void this.playCardVideo(url);
      this.showToast('已识别' + card.source + '链接，已发送卡片');
    } catch (error) {
      Logger.warn('CHAT_ROOM', '剪贴板识别失败：' + String(error));
    }
  }

  /** 从任意文本里提取第一个可识别的分享链接。 */
  private findShareUrl(text: string): string {
    const matched: RegExpMatchArray | null = (text || '').match(/https?:\/\/[^\s'"）)】]+/i);
    if (matched === null || matched.length === 0) { return ''; }
    const url: string = matched[0];
    const platform: string = MediaSniffer.platformOf(url);
    if (platform !== 'other') { return url; }
    return MediaSniffer.isDirectMedia(url) ? url : '';
  }

  /** 登记"当前正在查看的房间"：提醒服务据此跳过该房间的弹窗与提示音。 */
  private claimActiveRoom(): void {
    try {
      if (this.room.length === 0) { return; }
      AppStorage.setOrCreate<string>('activeChatRoom', this.room);
    } catch (error) {
      Logger.warn('CHAT_ROOM', '登记当前聊天室失败：' + String(error));
    }
  }

  private releaseActiveRoom(): void {
    try {
      const active: string = AppStorage.get<string>('activeChatRoom') || '';
      if (active.length > 0 && active === this.room) {
        AppStorage.setOrCreate<string>('activeChatRoom', '');
      }
    } catch (error) {
      Logger.warn('CHAT_ROOM', '释放当前聊天室失败：' + String(error));
    }
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      if (!this.loggedIn) {
        this.errorText = '登录后才能进入聊天室';
        return;
      }
      this.privateMode = this.peer.length > 0;
      if (this.privateMode) {
        this.room = ChatService.privateRoom(this.session.user, this.peer);
        if (this.title.length === 0) {
          this.title = this.peer;
        }
        if (SocialStore.isBlocked(this.peer)) {
          this.errorText = '已拉黑该用户，不再接收消息';
          return;
        }
      } else if (this.room.length === 0) {
        this.room = ChatService.OFFICIAL_ROOM;
      }
      if (this.title.length === 0) {
        this.title = this.room;
      }
      this.claimActiveRoom();
      await this.loadMessages(true);
      await this.loadOnline();
      this.startPolling();
      this.startOnlineTimer();
    } catch (error) {
      this.errorText = String(error);
      Logger.error('CHAT_ROOM', '初始化聊天页失败：' + String(error));
    }
  }

  private async loadMessages(reset: boolean): Promise<void> {
    if (this.peer.length > 0) {
      await this.loadPrivateChat(reset);
      return;
    }
    if (!this.loggedIn || this.loading) {
      return;
    }
    this.loading = true;
    try {
      const result = await CommunityApi.chatMessages(this.session, this.room, 1, 50, reset ? 0 : this.lastId);
      if (reset) {
        this.historyPage = 1;
      }
      let merged: ChatMessage[] = reset ? [] : this.messages.slice();
      let added: number = 0;
      for (const item of result.messages) {
        if (!merged.some((message: ChatMessage) => message.id === item.id && item.id > 0)) {
          merged.push(item);
          added++;
        }
      }
      merged = merged.filter((item: ChatMessage) => item.user === this.session.user ||
        !SocialStore.isBlocked(item.user));
      this.messages = merged;
      this.normalizeMessages();
      this.refreshMembers();
      this.errorText = this.messages.length === 0 ? '还没有消息，来打个招呼吧' : '';
      // 收到新消息（包括轮询拉到别人发的消息）后自动落到底部。
      // 加载更早历史走 loadHistory，不触发这里，避免阅读位置被拉走。
      if (!reset && added > 0) {
        // 房间内直接响铃（免打扰 / 关闭提示音时 playNoticeSound 内部会忽略），
        // 弹窗由 ChatAlertService 跳过当前房间，不会重复打扰。
        const incoming: ChatMessage[] = result.messages.filter((item: ChatMessage) =>
          item.user !== this.session.user && !SocialStore.isBlocked(item.user));
        if (incoming.length > 0) {
          ChatAlertService.playNoticeSound();
        }
      }
      if (reset || added > 0) {
        setTimeout(() => {
          this.listScroller.scrollEdge(Edge.Bottom);
        }, 60);
      }
    } catch (error) {
      this.errorText = String(error);
      Logger.warn('CHAT_ROOM', '加载聊天消息失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  /** 私聊：拉 echochat 记录并转成消息列表。 */
  private async loadPrivateChat(reset: boolean): Promise<void> {
    if (!this.loggedIn || this.loading) { return; }
    this.loading = true;
    try {
      const text: string = await AccountApi.friendChatList(this.session.user, this.peer);
      const entries: ChatEntry[] = AccountApi.parseChatLog(text);
      const list: ChatMessage[] = [];
      for (let index: number = 0; index < entries.length; index++) {
        const entry: ChatEntry = entries[index];
        const message: ChatMessage = new ChatMessage();
        message.id = index + 1;
        message.user = entry.user;
        message.name = entry.user;
        message.content = entry.content;
        message.time = entry.time;
        list.push(message);
      }
      this.messages = list;
      void ChatArchive.save('room', this.room, list);
      this.lastId = list.length;
      void ChatArchive.save('peer', this.peer, list);
      Logger.info('CHAT_ROOM', '私聊记录加载完成，条数=' + String(list.length));
    } catch (error) {
      Logger.warn('CHAT_ROOM', '加载私聊记录失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  /** 私聊：发一条消息（friendchat.php）。 */
  private async sendPrivateChat(): Promise<void> {
    const text: string = this.draft.trim();
    if (text.length === 0 || this.sending) { return; }
    this.sending = true;
    try {
      const message: string = await AccountApi.sendFriendChat(this.session.user, this.session.pass, this.peer, text);
      Logger.info('CHAT_ROOM', '私聊发送返回：' + message);
      this.draft = '';
      await this.loadPrivateChat(true);
    } catch (error) {
      this.showToast('发送失败：' + String(error));
    } finally {
      this.sending = false;
    }
  }

  private async loadHistory(): Promise<void> {
    if (this.loadingHistory || this.loading) {
      return;
    }
    this.loadingHistory = true;
    try {
      const next: number = this.historyPage + 1;
      const result = await CommunityApi.chatMessages(this.session, this.room, next, 50, 0);
      const older: ChatMessage[] = result.messages.filter((item: ChatMessage) =>
        !this.messages.some((message: ChatMessage) => message.id === item.id));
      if (older.length > 0) {
        this.messages = older.concat(this.messages);
        this.normalizeMessages();
        this.historyPage = next;
      }
      this.showToast(older.length > 0 ? '已加载更早消息' : '没有更早的消息了');
    } catch (error) {
      this.showToast('加载历史失败：' + String(error));
    } finally {
      this.loadingHistory = false;
    }
  }

  private normalizeMessages(): void {
    const server: ChatMessage[] = [];
    const pending: ChatMessage[] = [];
    for (const item of this.messages) {
      if (item.pending || item.id <= 0) {
        if (!pending.some((message: ChatMessage) => message.localKey.length > 0 &&
          message.localKey === item.localKey)) {
          pending.push(item);
        }
      } else if (!server.some((message: ChatMessage) => message.id === item.id)) {
        server.push(item);
      }
    }
    server.sort((first: ChatMessage, second: ChatMessage) => first.id - second.id);
    this.messages = server.concat(pending);
    let lastServerId: number = 0;
    for (const item of server) {
      if (item.id > lastServerId) {
        lastServerId = item.id;
      }
    }
    this.lastId = lastServerId;
    if (lastServerId > 0) {
      SocialStore.markRead(this.room, lastServerId);
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.timerId = setInterval(() => {
      if (this.alive && this.loggedIn && !this.loading && !this.sending) {
        void this.loadMessages(false);
      }
    }, 3000);
  }

  private stopPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private startOnlineTimer(): void {
    if (this.onlineTimer >= 0) {
      clearInterval(this.onlineTimer);
    }
    this.onlineTimer = setInterval(() => {
      if (this.alive) {
        void this.loadOnline();
      }
    }, 30000);
  }

  private stopTimers(): void {
    this.stopPolling();
    if (this.onlineTimer >= 0) {
      clearInterval(this.onlineTimer);
      this.onlineTimer = -1;
    }
  }

  private async loadOnline(): Promise<void> {
    try {
      this.onlineCount = await ChatService.onlineCount();
    } catch (error) {
      Logger.warn('CHAT_ROOM', '读取在线人数失败：' + String(error));
    }
  }

  private refreshMembers(): void {
    const members: string[] = [];
    for (const item of this.messages) {
      if (item.name && members.indexOf(item.name) < 0) {
        members.push(item.name);
      }
    }
    this.members = members;
  }

  private async sendCard(card: ChatCard, replace?: ChatMessage): Promise<void> {
    if (!this.loggedIn || this.sending) {
      return;
    }
    this.sending = true;
    const baselineId: number = this.lastId;
    const content: string = MediaCodec.encode(card);
    let temp: ChatMessage;
    if (replace !== undefined) {
      temp = replace;
      temp.failed = false;
      temp.pending = true;
      temp.content = content;
    } else {
      temp = new ChatMessage();
      temp.localKey = 'local-' + String(Date.now());
      temp.user = this.session.user;
      temp.name = this.session.user;
      temp.grade = '';
      temp.time = this.nowTime();
      temp.content = content;
      temp.pending = true;
      this.messages = this.messages.concat([temp]);
      this.listScroller.scrollEdge(Edge.Bottom);
    }
    this.errorText = '';
    try {
      const remoteId: number = await CommunityApi.sendChat(this.session, this.room, content);
      const confirmed: ChatMessage = new ChatMessage();
      confirmed.id = remoteId;
      confirmed.user = temp.user;
      confirmed.name = temp.name;
      confirmed.grade = temp.grade;
      confirmed.vipTime = temp.vipTime;
      confirmed.time = temp.time;
      confirmed.content = temp.content;
      confirmed.replyTo = temp.replyTo;
      confirmed.pending = false;
      confirmed.failed = false;
      confirmed.localKey = '';
      // 先按 localKey 和真实 id 双条件清理：
      // 轮询可能已经把同一条服务端消息插进列表，只替换 localKey 会留下两条。
      if (remoteId > 0) {
        this.messages = this.messages.filter((item: ChatMessage) =>
          item.localKey !== temp.localKey && item.id !== remoteId).concat([confirmed]);
        this.normalizeMessages();
      } else {
        // 服务端成功但没有返回 message_id 时，不能把 id=0 的乐观消息留在列表里，
        // 否则轮询拉到真实消息后会再显示一条。
        this.messages = this.messages.filter((item: ChatMessage) => item.localKey !== temp.localKey);
        await this.loadMessages(true);
      }
      Logger.info('CHAT_ROOM', '消息发送成功，ID=' + String(remoteId));
      this.startPolling();
    } catch (error) {
      const recovered: ChatMessage | undefined = await this.recoverSentMessage(content, baselineId);
      if (recovered !== undefined) {
        // 请求超时/解析失败但服务端已落库：以服务端消息为准，移除本地临时消息。
        this.messages = this.messages.filter((item: ChatMessage) => item.localKey !== temp.localKey);
        this.messages.push(recovered);
        this.normalizeMessages();
        this.errorText = '';
        this.showToast('消息已发送');
        Logger.warn('CHAT_ROOM', '发送返回失败，但服务端已存在该消息，已回收并去重');
        return;
      }
      this.messages = this.messages.map((item: ChatMessage) => {
        if (item.localKey === temp.localKey) {
          item.pending = false;
          item.failed = true;
        }
        return item;
      });
      this.errorText = String(error);
      if (String(error).indexOf('禁言') >= 0) {
        this.muted = true;
      }
      Logger.error('CHAT_ROOM', '消息发送失败：' + String(error));
    } finally {
      this.sending = false;
    }
  }

  private async recoverSentMessage(content: string, baselineId: number): Promise<ChatMessage | undefined> {
    try {
      const result = await CommunityApi.chatMessages(this.session, this.room, 1, 20, 0);
      for (let index = result.messages.length - 1; index >= 0; index--) {
        const item: ChatMessage = result.messages[index];
        if (item.id > baselineId && item.user === this.session.user && item.content === content) {
          return item;
        }
      }
    } catch (error) {
      Logger.warn('CHAT_ROOM', '发送失败后的服务端回查失败：' + String(error));
    }
    return undefined;
  }

  private async sendText(): Promise<void> {
    if (this.peer.length > 0) {
      await this.sendPrivateChat();
      return;
    }
    const text: string = this.draft.trim();
    const hasMedia: boolean = this.draftMedia.length > 0;
    if ((!text && !hasMedia) || this.sending) {
      return;
    }
    // 阻止输入框 onSubmit 与发送按钮 onClick 在同一帧内触发两次发送。
    const now: number = Date.now();
    if (text.length > 0 && text === this.lastSentText && now - this.lastSentAt < 1200) {
      Logger.warn('CHAT_ROOM', '忽略重复发送请求：' + text);
      return;
    }
    this.lastSentText = text;
    this.lastSentAt = now;
    this.draft = '';
    this.showEmoji = false;
    this.showPlus = false;
    const card: ChatCard = new ChatCard();
    // 引用的优先级最高；其次带媒体就是 rich（富文本），只发文字仍是 text。
    card.kind = this.replyVisible ? 'quote' : (hasMedia ? 'rich' : 'text');
    card.text = text;
    if (hasMedia) {
      card.media = this.draftMedia.slice();
      this.draftMedia = [];
    }
    if (this.replyVisible) {
      card.quoteUser = this.replyTo.name || this.replyTo.user;
      card.quoteText = MediaCodec.preview(MediaCodec.decode(this.replyTo.content));
      this.replyVisible = false;
    }
    await this.sendCard(card);
  }

  private resend(message: ChatMessage): void {
    const card: ChatCard = MediaCodec.decode(message.content);
    void this.sendCard(card, message);
  }

  private nowTime(): string {
    const date: Date = new Date();
    const hour: string = date.getHours() < 10 ? '0' + String(date.getHours()) : String(date.getHours());
    const minute: string = date.getMinutes() < 10 ? '0' + String(date.getMinutes()) : String(date.getMinutes());
    return hour + ':' + minute;
  }

  private minutesOf(time: string): number {
    const parts: string[] = time.split(':');
    if (parts.length !== 2) {
      return -1;
    }
    const hour: number = Number(parts[0]);
    const minute: number = Number(parts[1]);
    return Number.isFinite(hour) && Number.isFinite(minute) ? hour * 60 + minute : -1;
  }

  private showTime(index: number, message: ChatMessage): boolean {
    if (index === 0) {
      return true;
    }
    const previous: ChatMessage = this.messages[index - 1];
    const currentValue: number = this.minutesOf(message.time);
    const previousValue: number = this.minutesOf(previous.time);
    if (currentValue < 0 || previousValue < 0) {
      return message.time !== previous.time;
    }
    return currentValue - previousValue >= 5 || currentValue < previousValue;
  }

  private confirmRevoke(message: ChatMessage): void {
    if (!message.mine(this.session.user)) {
      return;
    }
    AlertDialog.show({
      title: '撤回消息',
      message: '确定撤回这条消息吗？',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '撤回', action: (): void => { void this.revoke(message); } }
    });
  }

  private async revoke(message: ChatMessage): Promise<void> {
    try {
      await CommunityApi.revokeChat(this.session, this.room, message.id);
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== message.id);
      this.actionVisible = false;
      Logger.info('CHAT_ROOM', '撤回成功：' + String(message.id));
    } catch (error) {
      this.showToast('撤回失败：' + String(error));
      Logger.error('CHAT_ROOM', '撤回失败：' + String(error));
    }
  }

  private copyMessage(message: ChatMessage): void {
    const card: ChatCard = MediaCodec.decode(message.content);
    const text: string = MediaCodec.preview(card);
    try {
      pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)).then(() => {
        this.showToast('已复制消息');
      }).catch((error: Error) => {
        Logger.error('CHAT_ROOM', '复制消息失败：' + String(error));
        this.showToast('复制失败');
      });
    } catch (error) {
      this.showToast('复制失败');
    }
    this.actionVisible = false;
  }

  /** 音乐消息：点击直连播放，再点停止；失败只提示一句。 */
  private async toggleAudio(url: string, messageId: number = 0): Promise<void> {
    try {
      const same: boolean = this.playingAudio === url;
      await this.stopAudio();
      if (same) { return; }
      const player: media.AVPlayer = await media.createAVPlayer();
      this.audioPlayer = player;
      this.playingAudio = url;
      this.playingMessageId = messageId;
      player.on('stateChange', (state: string) => {
        try {
          if (state === 'initialized') { player.prepare().catch(() => {}); }
          else if (state === 'prepared') { player.play().catch(() => {}); }
          else if (state === 'completed') { void this.stopAudio(); }
        } catch (_) { Logger.warn('CHAT_ROOM', '音乐播放状态异常'); }
      });
      player.on('timeUpdate', (time: number) => { if (!this.audioSeeking) { this.audioPosMs = time; } });
      player.on('durationUpdate', (duration: number) => { this.audioDurMs = duration; });
      player.on('error', (error: BusinessError) => {
        Logger.error('CHAT_ROOM', '音乐播放失败：code=' + String(error.code) + '，msg=' + String(error.message) + '，url=' + url);
        if (error.code === 5400106) {
          Logger.warn('CHAT_ROOM', '容器不支持，改为下载后播放：' + url);
          void this.playAudioFromCache(url);
          return;
        }
        const reason: string = error.code === 5400106
          ? '该链接返回的不是音频（多为网易云版权/VIP 限制），可换直链 mp3 或本地文件'
          : ('音乐播放失败（' + String(error.code) + '）：' + String(error.message));
        this.showToast(reason);
        void this.stopAudio();
      });
      // 与播放器同源：网页/短链先嗅探成直链再播。
      const resolved: SniffResult = await MediaSniffer.resolve(url);
      player.url = resolved.url;
    } catch (error) {
      this.showToast('音乐播放失败：' + String(error));
      await this.stopAudio();
    }
  }

  private async stopAudio(): Promise<void> {
    const player: media.AVPlayer | undefined = this.audioPlayer;
    this.audioPlayer = undefined;
    this.playingAudio = '';
    this.playingMessageId = 0;
    this.audioPosMs = 0;
    this.audioDurMs = 0;
    if (player !== undefined) {
      try { await player.release(); } catch (_) { Logger.warn('CHAT_ROOM', '释放音乐播放器失败'); }
    }
    this.closeAudioFd();
  }

  /** 关闭本地音频文件句柄（幂等）。 */
  private closeAudioFd(): void {
    const fd: number = this.audioFd;
    this.audioFd = -1;
    if (fd >= 0) {
      try { fileIo.closeSync(fd); } catch (error) { Logger.warn('CHAT_ROOM', '关闭音频句柄失败：' + String(error)); }
    }
  }

  /** 是否纯媒体消息（没有文字）：这类消息不套文字气泡背景。 */
  private mediaOnly(message: ChatMessage): boolean {
    const card: ChatCard = MediaCodec.decode(message.content);
    if (card.kind === 'image' || card.kind === 'video' || card.kind === 'file' || card.kind === 'voice') {
      return true;
    }
    if (card.kind === 'rich' || card.kind === 'quote') {
      return card.text.trim().length === 0 && card.hasMedia();
    }
    return false;
  }

  /** 点头衔：打开全部头衔/等级排行，并带上当前等级高亮。 */
  /** 右上角排行榜入口。 */
  private openRankPage(): void {
    router.pushUrl({ url: 'pages/RankPage' }).catch((error: Error) => {
      Logger.warn('CHAT_ROOM', '打开排行榜失败：' + String(error));
    });
  }

  private openTitleRank(grade: string, account: string): void {
    try {
      const level: number = UserTitles.levelOf(grade, account);
      const params: Record<string, string> = { 'level': String(level) };
      router.pushUrl({ url: 'pages/TitleRankPage', params: params }).catch((error: Error) => {
        Logger.error('CHAT_ROOM', '打开头衔排行失败：' + String(error));
      });
    } catch (error) {
      Logger.error('CHAT_ROOM', '头衔排行路由异常：' + String(error));
    }
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2000);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('CHAT_ROOM', '同步沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 880);
  }

  private bubbleMaxWidth(): number {
    return this.tablet() ? 540 : Math.max(190, this.viewportWidth * 0.7);
  }

  private glassBlurRadius(): number {
    return Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur);
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeBottom(): number {
    return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  /** 按需加载消息里的账号头像（已缓存的直接用）。 */
  /** 消息列表变化后统一拉取一次头像。 */
  private ensurePortraitAll(): void {
    for (let index: number = 0; index < this.messages.length; index++) {
      this.ensurePortrait(this.messages[index].user);
    }
  }

  private ensurePortrait(user: string): void {
    const name: string = (user || '').trim();
    if (name.length === 0 || this.portraits.has(name)) { return; }
    PortraitLoader.load(name, (pixel: image.PixelMap | undefined) => {
      if (pixel === undefined || this.portraits.has(name)) { return; }
      const next: Map<string, image.PixelMap> = new Map<string, image.PixelMap>(this.portraits);
      next.set(name, pixel);
      this.portraits = next;
    });
  }

  /** 是否 XML 卡片消息。 */
  private isXmlCard(content: string): boolean {
    return parseXmlCard(content) !== undefined;
  }

  /** 解析 XML 卡片（不是卡片时返回空卡片）。 */
  private xmlCardOf(content: string): XmlCard {
    const parsed: XmlCard | undefined = parseXmlCard(content);
    return parsed === undefined ? new XmlCard() : parsed;
  }

  /** 卡片点击分流：音频→音乐播放器，视频→内嵌播放，其它→提示。 */

  /** 卡片点击分流：音频→音乐播放器，视频→内嵌播放，其它→提示。 */


    /** 卡片点击分流：音频→音乐播放器，视频→内嵌播放，其它→提示。 */
  /** 播放前探测：拿 Content-Type 判断是不是音频，避免 5400106 这种黑盒报错。 */
  private async probeAudio(url: string): Promise<string> {
    try {
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(url, {
          method: http.RequestMethod.GET,
          header: { 'Range': 'bytes=0-1024' } as Record<string, string>,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: 10000
        });
        const type: string = String(response.header['content-type'] || response.header['Content-Type'] || '');
        Logger.info('CHAT_ROOM', '音频探测：type=' + type + '，code=' + String(response.responseCode));
        if (type.length > 0 && type.indexOf('audio') < 0 && type.indexOf('octet-stream') < 0) {
          return '该地址返回 ' + type + '（不是音频，可能是防盗链或网页）';
        }
        return '';
      } finally {
        request.destroy();
      }
    } catch (error) {
      Logger.warn('CHAT_ROOM', '音频探测失败：' + String(error));
      return '';
    }
  }

  /** 下载到缓存再用本地文件播放：绕过防盗链 / 怪异容器导致的 5400106。 */
  private async playAudioFromCache(url: string): Promise<void> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const path: string = context.cacheDir + '/chat_audio_' + String(Date.now()) + '.mp3';
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 30000
      });
      const bytes: ArrayBuffer = response.result as ArrayBuffer;
      if (bytes === undefined || bytes.byteLength < 1024) {
        this.showToast('下载到的音频为空（可能受版权限制）');
        return;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, bytes);
      fileIo.closeSync(file);
      Logger.info('CHAT_ROOM', '音频已缓存：' + path + '，字节=' + String(bytes.byteLength));
      await this.playLocalAudio(path);
    } catch (error) {
      Logger.error('CHAT_ROOM', '下载音频失败：' + String(error));
      this.showToast('下载音频失败：' + String(error));
    } finally {
      request.destroy();
    }
  }

  /** 用本地文件（fd）播放音频。 */
  private async playLocalAudio(path: string): Promise<void> {
    await this.stopAudio();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.audioPlayer = player;
      this.playingAudio = path;
      player.on('stateChange', (state: string) => {
        try {
          if (state === 'initialized') { player.prepare().catch(() => {}); }
          else if (state === 'prepared') { player.play().catch(() => {}); }
          else if (state === 'completed') { void this.stopAudio(); }
        } catch (_) { Logger.warn('CHAT_ROOM', '本地音频状态异常'); }
      });
      player.on('error', () => { void this.stopAudio(); });
      player.on('timeUpdate', (time: number) => { if (!this.audioSeeking) { this.audioPosMs = time; } });
      player.on('durationUpdate', (duration: number) => { this.audioDurMs = duration; });
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      this.audioFd = file.fd;
      const size: number = fileIo.statSync(path).size;
      player.fdSrc = { fd: file.fd, offset: 0, length: size };
    } catch (error) {
      Logger.error('CHAT_ROOM', '本地音频播放失败：' + String(error));
      this.showToast('本地音频播放失败：' + String(error));
    }
  }

  /** 音频进度跳转（按钮/进度条点击）。 */
  /** 这条消息是否正在播放（URL + 消息 id 双重判断）。 */
  private isPlaying(messageId: number, url: string): boolean {
    return this.playingAudio === url && (this.playingMessageId === 0 || this.playingMessageId === messageId);
  }

  private async seekAudioTo(ms: number): Promise<void> {
    const player: media.AVPlayer | undefined = this.audioPlayer;
    if (player === undefined) { return; }
    const target: number = Math.max(0, Math.min(this.audioDurMs > 0 ? this.audioDurMs : ms, ms));
    try {
      this.audioSeeking = true;
      this.audioPosMs = target;
      await player.seek(target);
    } catch (error) {
      Logger.warn('CHAT_ROOM', '音频跳转失败：' + String(error));
    } finally {
      this.audioSeeking = false;
    }
  }

  /** 拖动进度：按总时长百分比跳转。 */
  private seekAudioPercent(percent: number): void {
    if (this.audioDurMs <= 0) { return; }
    void this.seekAudioTo(Math.round(this.audioDurMs * percent / 100));
  }

  private async onCardTap(card: XmlCard, messageId: number = 0): Promise<void> {
    Logger.info('CHAT_ROOM', '卡片解析 url=' + card.url + '，kind=' + card.kind);
    if (card.kind === 'audio') {
      const problem: string = await this.probeAudio(card.url);
      if (problem.length > 0) {
        this.showToast(problem);
        return;
      }
      await this.toggleAudio(card.url, messageId);
      return;
    }
    if (card.kind === 'video') {
      await this.playCardVideo(card.url);
      return;
    }
    this.openXmlCard(card);
  }

  private async playCardVideo(url: string): Promise<void> {
    const target: string = (url || '').trim();
    if (target.length === 0) {
      this.showToast('该卡片没有视频地址');
      return;
    }
    if (this.cardVideoUrl === target) {
      this.cardVideoUrl = '';
      return;
    }
    // 抖音/快手：打开内嵌嗅探页跑页面脚本抓直链。
    const platform: string = MediaSniffer.platformOf(target);
    if (platform === 'douyin' || platform === 'kuaishou') {
      try {
        const params: Record<string, string> = { 'url': target };
        await router.pushUrl({ url: 'pages/PlatformSnifferPage', params: params });
        return;
      } catch (error) {
        Logger.warn('CHAT_ROOM', '打开嗅探页失败：' + String(error));
      }
    }
    try {
      const resolved: SniffResult = await MediaSniffer.resolve(target);
      this.cardVideoUrl = resolved.url.length > 0 ? resolved.url : target;
    } catch (error) {
      Logger.warn('CHAT_ROOM', '卡片视频解析失败：' + String(error));
      this.cardVideoUrl = target;
    }
  }

  private openXmlCard(card: XmlCard): void {
    if (card.url.length > 0) {
      this.showToast('卡片链接：' + card.url);
      return;
    }
    this.showToast(card.title.length > 0 ? card.title : '卡片消息');
  }

  /** ark 卡片 → 聊天室卡片类型。 */
  private arkKind(content: string): string {
    const card: ArkCard | undefined = parseArkCard(content);
    if (card === undefined) { return 'link'; }
    const host: string = schemeHost(card.scheme);
    if (host === 'audio') { return 'audio'; }
    if (host === 'play') { return 'video'; }
    if (host === 'download') { return 'file'; }
    if (host === 'post' || host === 'notice') { return 'link'; }
    return card.serviceId === '2' ? 'audio' : 'link';
  }

  private arkField(content: string, field: string): string {
    const card: ArkCard | undefined = parseArkCard(content);
    if (card === undefined) { return ''; }
    if (field === 'title') { return card.title; }
    if (field === 'desc') { return this.cleanCardDesc(card.desc); }
    if (field === 'source') { return card.source; }
    if (field === 'scheme') { return card.scheme; }
    if (field === 'cover') { return card.cover; }
    return '';
  }

  /** 点 ark 卡片：按 scheme host 分流。 */
  private openArkCard(content: string): void {
    const card: ArkCard | undefined = parseArkCard(content);
    if (card === undefined) { return; }
    const scheme: string = card.scheme;
    const host: string = schemeHost(scheme);
    Logger.info('CHAT_ROOM', 'ark 卡片点击：host=' + host + '，scheme=' + scheme);
    if (host === 'audio') {
      const audioId: string = schemeValue(scheme, 'audioId');
      const title: string = schemeValue(scheme, 'title');
      this.showToast('音频：' + (title.length > 0 ? title : audioId));
      return;
    }
    if (host === 'play' || host === 'joinSession') {
      const vodId: string = schemeValue(scheme, 'vodId');
      const episode: string = schemeValue(scheme, 'episodeIndex');
      const wzlj: string = schemeValue(scheme, 'wzlj');
      const title: string = schemeValue(scheme, 'title');
      const cover: string = schemeValue(scheme, 'cover');
      if (vodId.length === 0) {
        this.showToast('卡片缺少影片信息');
        return;
      }
      if (host === 'joinSession') {
        this.showToast('协播请从邀请消息进入');
      }
      const params: Record<string, string> = {
        'vodId': vodId, 'episodeIndex': episode, 'wzlj': wzlj,
        'tilie': title, 'yhm': title, 'feng': cover
      };
      void router.pushUrl({ url: 'pages/PlayerPage', params: params }).catch((error: Error) => {
        Logger.warn('CHAT_ROOM', '打开播放器失败：' + String(error));
      });
      return;
    }
    if (host === 'post') {
      const postId: string = schemeValue(scheme, 'postId');
      const params: Record<string, string> = { 'postId': postId };
      void router.pushUrl({ url: 'pages/ForumDetailPage', params: params }).catch((error: Error) => {
        Logger.warn('CHAT_ROOM', '打开帖子失败：' + String(error));
      });
      return;
    }
    if (host === 'live') {
      this.showToast('直播：' + schemeValue(scheme, 'liveId'));
      return;
    }
    this.showToast(card.title.length > 0 ? card.title : '卡片');
  }

  /** 收起输入法（点 ＋ 展开更多功能时用）。 */
  private hideKeyboard(): void {
    try {
      inputMethod.getController().stopInputSession().catch((error: Error) => {
        Logger.warn('CHAT_ROOM', '收起输入法失败：' + String(error));
      });
      this.getUIContext().getFocusController().clearFocus();
    } catch (error) {
      Logger.warn('CHAT_ROOM', '收起输入法异常：' + String(error));
    }
  }

  /** 粗略在线判断：最近 5 分钟内有发言视为在线。 */
  private isOnline(name: string): boolean {
    try {
      const account: string = name.trim();
      for (let index: number = this.messages.length - 1; index >= 0; index--) {
        const message: ChatMessage = this.messages[index];
        if (message.user !== account && message.name !== account) { continue; }
        const minutes: number = this.minutesOf(message.time);
        return minutes >= 0 && minutes <= 5;
      }
    } catch (error) {
      Logger.warn('CHAT_ROOM', '判断在线状态失败：' + String(error));
    }
    return false;
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  private openProfile(account: string): void {
    if (!account) {
      return;
    }
    try {
      router.pushUrl(new UserRouteOptions(account)).catch((error: Error) => {
        Logger.error('CHAT_ROOM', '打开资料页失败：' + String(error));
      });
    } catch (error) {
      Logger.error('CHAT_ROOM', '资料页路由异常：' + String(error));
    }
  }

  private async toggleBan(): Promise<void> {
    try {
      await CommunityApi.banChat(this.session, this.room, true);
      this.showToast('已开启全体禁言');
      this.showMenu = false;
      Logger.info('CHAT_ROOM', '开启全体禁言');
    } catch (error) {
      this.showToast('操作失败：' + String(error));
    }
  }

  private async unmuteAll(): Promise<void> {
    try {
      await CommunityApi.banChat(this.session, this.room, false);
      this.showToast('已解除全体禁言');
      this.showMenu = false;
      this.muted = false;
    } catch (error) {
      this.showToast('操作失败：' + String(error));
    }
  }

  private clearLocal(): void {
    this.messages = [];
    this.showMenu = false;
    this.showToast('已清空本地聊天记录');
  }

  /** 打开富媒体添加框；图片/视频/附件/音频 共用一套输入（音频沿用旧的 voice 入口）。 */
  private openUrl(kind: string): void {
    this.mediaKind = kind === 'voice' ? 'audio' : kind;
    this.urlValue = '';
    this.mediaTitle = '';
    this.mediaPoster = '';
    this.showUrlDialog = true;
    this.showPlus = false;
  }

  /** 把一条媒体加入待发送列表（不立即发送，随文字一起组成一条 rich 消息）。 */
  private addDraftMedia(): void {
    const value: string = this.urlValue.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      this.showToast('请输入 http/https 链接');
      return;
    }
    if (this.draftMedia.length >= 12) {
      this.showToast('单条消息最多 12 个媒体');
      return;
    }
    const media: ForumMedia = new ForumMedia();
    media.kind = this.mediaKind;
    media.url = value;
    media.title = this.mediaTitle.trim();
    media.poster = this.mediaPoster.trim();
    this.draftMedia = this.draftMedia.concat([media]);
    this.showUrlDialog = false;
    this.urlValue = '';
    this.mediaTitle = '';
    this.mediaPoster = '';
  }

  private removeDraftMedia(index: number): void {
    this.draftMedia = this.draftMedia.filter((_item: ForumMedia, position: number) => position !== index);
  }

  private mediaLabel(kind: string): string {
    if (kind === 'video') { return '视频'; }
    if (kind === 'audio') { return '音乐'; }
    if (kind === 'file') { return '附件'; }
    return '图片';
  }

  private mediaGlyph(kind: string): string {
    if (kind === 'video') { return '▶'; }
    if (kind === 'audio') { return '♪'; }
    if (kind === 'file') { return '📎'; }
    return '🖼';
  }

  private async sendRedPacket(): Promise<void> {
    const amount: number = Number(this.redAmount);
    const count: number = Number(this.redCount);
    if (!Number.isFinite(amount) || amount <= 0 || !Number.isFinite(count) || count <= 0) {
      this.showToast('请输入正确的金额和个数');
      return;
    }
    try {
      const message: string = await CommunityApi.spendCoins(this.session, amount);
      if (message.indexOf('不足') >= 0 || message.indexOf('失败') >= 0) {
        this.showToast(message || '金币不足');
        return;
      }
      const card: ChatCard = new ChatCard();
      card.kind = 'redpacket';
      card.amount = amount;
      card.count = Math.trunc(count);
      card.blessing = this.redBlessing.trim() || '恭喜发财，大吉大利';
      this.showRedPacket = false;
      this.redAmount = '';
      this.redCount = '';
      this.redBlessing = '';
      await this.sendCard(card);
    } catch (error) {
      this.showToast('红包发送失败：' + String(error));
    }
  }

  private claimRedPacket(message: ChatMessage): void {
    const key: string = String(message.id);
    if (this.claimed.includes(key)) {
      this.showToast('红包已领取');
      return;
    }
    this.claimed = this.claimed.concat([key]);
    this.showToast('红包领取成功（本地演示）');
  }

  private insertEmoji(emoji: string): void {
    this.draft = this.draft + emoji;
  }

  private insertMention(name: string): void {
    this.draft = this.draft + '@' + name + ' ';
    this.showMembers = false;
  }

  private formatAction(message: ChatMessage): string {
    return MediaCodec.preview(MediaCodec.decode(message.content));
  }

  private actionPreview(): string {
    return this.actionVisible ? this.formatAction(this.actionMessage) : '';
  }

  private roomIntro(): string {
    const room = SocialStore.room(this.room);
    return room !== undefined ? room.intro : '无音影视聊天室';
  }

  @Builder
  private header() {
    Row({ space: '8vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Column({ space: '1vp' }) {
        Text(this.title)
          .fontSize(Ui.fs(this.tablet() ? '20vp' : '17vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => { this.showInfo = true; })
        Text('在线 ' + String(this.onlineCount) + ' 人' + (this.privateMode ? ' · 私聊' : ''))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      // 排行榜入口（群聊与私聊都可看）
      SymbolGlyph(SymbolIcons.trophy())
        .fontSize(Ui.fs('18vp', this.fontScale))
        .fontColor([Ui.ink(this.darkTheme)])
        .width('36vp')
        .height('36vp')
        .borderRadius('18vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .onClick(() => { this.openRankPage(); })
      if (!this.privateMode) {
        Text('⋮')
          .fontSize(Ui.fs('24vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .width('36vp')
          .height('36vp')
          .textAlign(TextAlign.Center)
          .borderRadius('18vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .onClick(() => { this.showMenu = !this.showMenu; })
      } else {
        Text('⋯')
          .fontSize(Ui.fs('22vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .width('36vp')
          .height('36vp')
          .textAlign(TextAlign.Center)
          .borderRadius('18vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .onClick(() => { this.showMenu = !this.showMenu; })
      }
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '12vp',
        right: this.tablet() ? '24vp' : '12vp',
        top: (this.safeTop() + 6) + 'vp',
        bottom: '4vp'
      })
  }

  @Builder
  private messageBubble(message: ChatMessage, index: number) {
    Column({ space: '4vp' }) {
      if (this.showTime(index, message)) {
        Text(message.time)
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: '4vp', bottom: '2vp' })
      }
      Row({ space: '7vp' }) {
        if (!message.mine(this.session.user)) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Column()
              .width('32vp')
              .height('32vp')
              .borderRadius('16vp')
              .backgroundColor(Ui.accentSoft(this.darkTheme))
            Text(this.initial(message.name))
              .fontSize(Ui.fs('13vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.accentStrong(this.darkTheme))
            // 在线状态小绿点（最近 5 分钟有发言）
            if (this.isOnline(message.user.length > 0 ? message.user : message.name)) {
              Column()
                .width('8vp')
                .height('8vp')
                .borderRadius('4vp')
                .backgroundColor(Ui.success(this.darkTheme))
                .border({ width: 1, color: Ui.pageBg(this.darkTheme) })
            }
            // 账号真实头像：http 取字节 → PixelMap 显示，取不到就保持首字。
            if (this.portraits.get(message.user) !== undefined) {
              Image(this.portraits.get(message.user))
                .width('32vp')
                .height('32vp')
                .borderRadius('16vp')
                .objectFit(ImageFit.Cover)
                .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
            }
          }
            .width('32vp')
            .height('32vp')
            .onClick(() => { this.openProfile(message.user); })
        }
        Column({ space: '3vp' }) {
          Row({ space: '5vp' }) {
            Text(message.name || message.user)
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(Ui.inkSoft(this.darkTheme))
              .maxLines(1)
            // 等级头衔（无音影视主题），由 grade 解析；无等级时按账号稳定兜底。
            // 等级头衔：13 级起用双色渐变胶囊，低等级保持单色。
            if (UserTitles.levelOf(message.grade, message.user) >= 13) {
              Text(UserTitles.badgeOf(message.grade, message.user))
                .fontSize(Ui.fs('9vp', this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(UserTitles.gradientOf(message.grade, message.user)[2])
                .maxLines(1)
                .height('16vp')
                .padding({ left: '6vp', right: '6vp' })
                .borderRadius('8vp')
                .linearGradient({
                  angle: 90,
                  colors: [
                    [UserTitles.gradientOf(message.grade, message.user)[0], 0],
                    [UserTitles.gradientOf(message.grade, message.user)[1], 1]
                  ]
                })
                .onClick(() => { this.openTitleRank(message.grade, message.user); })
            } else {
              Text(UserTitles.badgeOf(message.grade, message.user))
                .fontSize(Ui.fs('9vp', this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(UserTitles.colorOf(message.grade, message.user, this.darkTheme))
                .maxLines(1)
                .height('16vp')
                .padding({ left: '5vp', right: '5vp' })
                .borderRadius('8vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .onClick(() => { this.openTitleRank(message.grade, message.user); })
            }
            if (message.vipTime.length > 0 && message.vipTime !== '已过期') {
              Text('VIP')
                .fontSize(Ui.fs('8.5vp', this.fontScale))
                .fontColor(Ui.gold(this.darkTheme))
                .padding({ left: '4vp', right: '4vp' })
                .borderRadius('6vp')
                .backgroundColor(Ui.goldSoft(this.darkTheme))
            }
          }
            .width('100%')
            .justifyContent(message.mine(this.session.user) ? FlexAlign.End : FlexAlign.Start)
          this.bubbleContent(message)
          if (message.pending) {
            Text('发送中…')
              .fontSize(Ui.fs('9vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
          if (message.failed) {
            Row({ space: '4vp' }) {
              Text('!')
                .fontSize(Ui.fs('10vp', this.fontScale))
                .fontColor(Ui.danger(this.darkTheme))
              Text('发送失败，点击重发')
                .fontSize(Ui.fs('9.5vp', this.fontScale))
                .fontColor(Ui.danger(this.darkTheme))
            }
              .onClick(() => { this.resend(message); })
          }
          if (this.privateMode && message.mine(this.session.user) && index === this.messages.length - 1) {
            Text('已读')
              .fontSize(Ui.fs('9vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
        }
          .alignItems(message.mine(this.session.user) ? HorizontalAlign.End : HorizontalAlign.Start)
          .constraintSize({ maxWidth: this.bubbleMaxWidth() })
      }
        .width('100%')
        .justifyContent(message.mine(this.session.user) ? FlexAlign.End : FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
        .gesture(LongPressGesture({ repeat: false }).onAction(() => {
          this.actionMessage = message;
          this.actionVisible = true;
        }))
    }
      .width('100%')
  }

  /** 富媒体块：图片九宫格 + 视频/音乐/附件行，rich 与 quote 气泡共用。 */
  @Builder
  private mediaBlock(message: ChatMessage) {
    if (MediaCodec.images(MediaCodec.decode(message.content)).length > 0) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
        ForEach(MediaCodec.images(MediaCodec.decode(message.content)).slice(0, 9),
          (url: string, index: number) => {
            // 图片按自身尺寸展示（不裁切成方块），限制最大宽高，整体水平居中。
            Image(url)
              .width('140vp')
              .height('140vp')
              .objectFit(ImageFit.Cover)
              .borderRadius('10vp')
              .margin('2vp')
              .onClick(() => { this.showToast('图片：' + url); })
          }, (url: string, index: number) => 'chat-img-' + String(message.id) + '-' + String(index))
      }
        .width('100%')
    }
    ForEach(MediaCodec.mediaOf(MediaCodec.decode(message.content), 'video'),
      (media: ForumMedia, index: number) => {
        this.videoBubble(media)
      }, (media: ForumMedia, index: number) => 'chat-video-' + String(message.id) + '-' + String(index))
    ForEach(MediaCodec.mediaOf(MediaCodec.decode(message.content), 'audio'),
      (media: ForumMedia, index: number) => {
        this.audioCard(media)
      }, (media: ForumMedia, index: number) => 'chat-audio-' + String(message.id) + '-' + String(index))
    ForEach(MediaCodec.mediaOf(MediaCodec.decode(message.content), 'file'),
      (media: ForumMedia, index: number) => {
        this.fileCard(media)
      }, (media: ForumMedia, index: number) => 'chat-file-' + String(message.id) + '-' + String(index))
  }

  /** 视频消息：直接在气泡里内嵌可播放控件。 */
  @Builder
  private videoBubble(media: ForumMedia) {
    Column({ space: '6vp' }) {
      if (this.resolvedVideoKey === media.url && this.resolvedVideo.length > 0) {
        // 已嗅探出直链：直接渲染原生视频控件，点击即播。
        Video({ src: this.resolvedVideo })
          .width('200vp')
          .height('112vp')
          .borderRadius('12vp')
          .objectFit(ImageFit.Cover)
          .controls(true)
          .autoPlay(true)
      } else {
        // 未解析：先显示封面 + 播放按钮，点一下走嗅探再换成播放器。
        Stack({ alignContent: Alignment.Center }) {
          if (media.poster.length > 0) {
            Image(media.poster)
              .width('200vp')
              .height('112vp')
              .borderRadius('12vp')
              .objectFit(ImageFit.Cover)
          } else {
            Column()
              .width('200vp')
              .height('112vp')
              .borderRadius('12vp')
              .backgroundColor('#000000')
          }
          SymbolGlyph(SymbolIcons.play())
            .fontSize(Ui.fs('34vp', this.fontScale))
            .fontColor(['#FFFFFF'])
        }
          .width('200vp')
          .height('112vp')
          .onClick(() => { void this.openVideo(media); })
      }
      Row({ space: '6vp' }) {
        SymbolGlyph(SymbolIcons.play())
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor([Ui.accentStrong(this.darkTheme)])
        Text(media.title.length > 0 ? media.title : '视频消息')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
      }
        .width('200vp')
        .alignItems(VerticalAlign.Center)
    }
  }

  /** 视频消息：先用公共嗅探解析直链，再交给 Video 播放。 */
  private async openVideo(item: ForumMedia): Promise<void> {
    try {
      const resolved: SniffResult = await MediaSniffer.resolve(item.url);
      this.resolvedVideoKey = item.url;
      this.resolvedVideo = resolved.url.length > 0 ? resolved.url : item.url;
    } catch (error) {
      this.showToast('视频打开失败：' + String(error));
    }
  }

  @Builder
  private audioCard(media: ForumMedia) {
    Row({ space: '10vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('42vp')
          .height('42vp')
          .borderRadius('21vp')
          .linearGradient({ angle: 140, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
          .shadow({ radius: 12, color: Ui.accentGlow(this.darkTheme), offsetY: 4 })
        SymbolGlyph(SymbolIcons.play())
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontColor(['#FFFFFF'])
      }
        .width('42vp')
        .height('42vp')
      Column({ space: '5vp' }) {
        Text(media.title.length > 0 ? media.title : '音乐')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .width('100%')
        Row() {
          Row()
            .width('38%')
            .height('3vp')
            .borderRadius('1.5vp')
            .backgroundColor(Ui.accent(this.darkTheme))
        }
          .width('100%')
          .height('3vp')
          .borderRadius('1.5vp')
          .backgroundColor(Ui.glassRing(this.darkTheme))
        Text(media.url)
          .fontSize(Ui.fs('9vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      SymbolGlyph(this.playingAudio === media.url ? SymbolIcons.pause() : SymbolIcons.play())
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontColor([Ui.accentStrong(this.darkTheme)])
    }
      .width('200vp')
      .padding('10vp')
      .borderRadius('14vp')
      .linearGradient({
        angle: 120,
        colors: [[Ui.glassTintStrong(this.darkTheme), 0], [Ui.accentSoft(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
      .onClick(() => { void this.toggleAudio(media.url); })
  }

  /** 文件消息：类型徽标 + 文件名 + 打开按钮。 */
  @Builder
  private fileCard(media: ForumMedia) {
    Row({ space: '10vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('38vp')
          .height('38vp')
          .borderRadius('10vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
        SymbolGlyph(SymbolIcons.file())
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontColor([Ui.accentStrong(this.darkTheme)])
      }
        .width('38vp')
        .height('38vp')
      Column({ space: '3vp' }) {
        Text(media.title.length > 0 ? media.title : '文件')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .width('100%')
        Text(media.url)
          .fontSize(Ui.fs('9vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Text('打开')
        .fontSize(Ui.fs('10vp', this.fontScale))
        .fontColor(Ui.accentStrong(this.darkTheme))
        .height('24vp')
        .padding({ left: '10vp', right: '10vp' })
        .borderRadius('12vp')
        .backgroundColor(Ui.accentSoft(this.darkTheme))
        .textAlign(TextAlign.Center)
    }
      .width('200vp')
      .padding('10vp')
      .borderRadius('12vp')
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
      .onClick(() => { this.showToast('文件：' + media.url); })
  }

  /** 文件扩展名徽标（取 URL 最后一段的扩展名，最多 4 位）。 */
  private fileExt(media: ForumMedia): string {
    const title: string = media.title.length > 0 ? media.title : media.url;
    const dot: number = title.lastIndexOf('.');
    if (dot < 0 || dot >= title.length - 1) {
      return 'FILE';
    }
    return title.substring(dot + 1).toUpperCase().substring(0, 4);
  }

  @Builder
  private bubbleContent(message: ChatMessage) {
    // XML 卡片消息（QQ 风格）：内容以 <card 开头时走卡片渲染。
    if (isArkCard(message.content)) {
      ChatCardMessage({
        kind: this.arkKind(message.content),
        title: this.arkField(message.content, 'title'),
        desc: this.arkField(message.content, 'desc'),
        source: this.arkField(message.content, 'source'),
        url: this.arkField(message.content, 'scheme'),
        button: '打开',
        thumb: this.arkField(message.content, 'cover'),
        poster: this.arkField(message.content, 'cover'),
        fileSize: '',
        amount: '',
        count: '',
        blessing: '',
        address: '',
        playing: false,
        positionMs: 0,
        durationMs: 0,
        onTap: (): void => { this.openArkCard(message.content); },
        onSeekPercent: (_percent: number): void => {}
      })
    } else if (this.isXmlCard(message.content)) {
      ChatCardMessage({
        kind: this.xmlCardOf(message.content).kind,
        title: this.xmlCardOf(message.content).title,
        desc: this.xmlCardOf(message.content).desc,
        source: this.xmlCardOf(message.content).source,
        url: this.xmlCardOf(message.content).url,
        button: this.xmlCardOf(message.content).button,
        thumb: this.xmlCardOf(message.content).thumb,
        poster: this.xmlCardOf(message.content).poster,
        name: this.xmlCardOf(message.content).name,
        fileSize: this.xmlCardOf(message.content).size,
        amount: this.xmlCardOf(message.content).amount,
        count: this.xmlCardOf(message.content).count,
        blessing: this.xmlCardOf(message.content).blessing,
        address: this.xmlCardOf(message.content).address,
        // 只有"当前正在播的那条"才带播放态与进度，其它音频卡片保持静止。
        playing: this.isPlaying(message.id, this.xmlCardOf(message.content).url),
        positionMs: this.isPlaying(message.id, this.xmlCardOf(message.content).url) ? this.audioPosMs : 0,
        durationMs: this.isPlaying(message.id, this.xmlCardOf(message.content).url) ? this.audioDurMs : 0,
        onTap: (): void => { void this.onCardTap(this.xmlCardOf(message.content), message.id); },
        onSeekPercent: (percent: number): void => { this.seekAudioPercent(percent); }
      })
      if (this.cardVideoUrl.length > 0 && this.cardVideoUrl === this.xmlCardOf(message.content).url) {
        Video({ src: this.cardVideoUrl })
          .width('230vp')
          .height('130vp')
          .borderRadius('12vp')
          .objectFit(ImageFit.Cover)
          .controls(true)
          .autoPlay(true)
          .margin({ top: '6vp' })
      }
    } else {

    Column({ space: '6vp' }) {
      if (MediaCodec.decode(message.content).kind === 'rich') {
        // 富文本：一段文字 + 任意条媒体，媒体块与文字同气泡。
        if (MediaCodec.decode(message.content).text.length > 0) {
          Text(MediaCodec.decode(message.content).text)
            .fontSize(this.tablet() ? '15vp' : '14vp')
            .lineHeight(this.tablet() ? '22vp' : '20vp')
            .fontColor(message.mine(this.session.user) ? '#FFFFFF' : Ui.ink(this.darkTheme))
            .width('100%')
        }
        this.mediaBlock(message)
      } else if (MediaCodec.decode(message.content).kind === 'image') {
        Image(MediaCodec.decode(message.content).url)
          .width('200vp')
          .height('150vp')
          .objectFit(ImageFit.Cover)
          .borderRadius('12vp')
      } else if (MediaCodec.decode(message.content).kind === 'redpacket') {
        Column({ space: '4vp' }) {
          Text((MediaCodec.decode(message.content).blessing || '恭喜发财'))
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFE4B5')
            .maxLines(2)
          Text('¥' + String(MediaCodec.decode(message.content).amount) + ' · ' +
            String(MediaCodec.decode(message.content).count) + '个')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor('#FFD18A')
          Text(this.claimed.includes(String(message.id)) ? '已领取' : '点击领取')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor('#FFFFFF')
            .onClick(() => { this.claimRedPacket(message); })
        }
          .padding('10vp')
          .borderRadius('10vp')
          .backgroundColor('#B33A1F1F')
          .border({ width: 1, color: '#66FFB36B' })
      } else if (MediaCodec.decode(message.content).kind === 'video' ||
        MediaCodec.decode(message.content).kind === 'file' ||
        MediaCodec.decode(message.content).kind === 'voice' ||
        MediaCodec.decode(message.content).kind === 'card') {
        Column({ space: '3vp' }) {
          // 旧版单媒体消息：图标换鸿蒙原生符号，文字去掉 emoji。
          SymbolGlyph(MediaCodec.decode(message.content).kind === 'card' ? SymbolIcons.mine(false) :
            SymbolIcons.file())
            .fontSize(Ui.fs('16vp', this.fontScale))
            .fontColor([Ui.accentStrong(this.darkTheme)])
          Text(MediaCodec.decode(message.content).kind === 'video' ? '视频' :
            (MediaCodec.decode(message.content).kind === 'file' ? '文件' :
              (MediaCodec.decode(message.content).kind === 'voice' ? '语音' : '名片')))
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
          Text(MediaCodec.decode(message.content).title || MediaCodec.decode(message.content).url)
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
            .maxLines(2)
        }
          .padding('10vp')
          .borderRadius('10vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .onClick(() => { this.showToast('资源：' + MediaCodec.decode(message.content).url); })
      } else if (MediaCodec.decode(message.content).kind === 'quote') {
        Column({ space: '4vp' }) {
          Text('回复 ' + MediaCodec.decode(message.content).quoteUser + '：' +
            MediaCodec.decode(message.content).quoteText)
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(2)
          Text(MediaCodec.decode(message.content).text)
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor(message.mine(this.session.user) ? '#FFFFFF' : Ui.ink(this.darkTheme))
          // 引用消息里也可以带富媒体。
          if (MediaCodec.decode(message.content).hasMedia()) {
            this.mediaBlock(message)
          }
        }
          .padding('10vp')
          .borderRadius('10vp')
          .backgroundColor(message.mine(this.session.user) ? Ui.accent(this.darkTheme) : Ui.card(this.darkTheme))
      } else {
        Text(MediaCodec.decode(message.content).text)
          .fontSize(Ui.fs(this.tablet() ? '15vp' : '14vp', this.fontScale))
          .lineHeight(this.tablet() ? '22vp' : '20vp')
          .fontColor(message.mine(this.session.user) ? '#FFFFFF' : Ui.ink(this.darkTheme))
      }
    }
      // 纯媒体消息（图片/视频/音乐/文件）不套文字气泡底色，直接显示媒体卡。
      .padding(this.mediaOnly(message) ? '0vp' : '8vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(this.mediaOnly(message) ? Color.Transparent :
        (message.mine(this.session.user) ? Ui.accent(this.darkTheme) : Ui.glassTintStrong(this.darkTheme)))
      .border({
        width: this.mediaOnly(message) ? 0 : 1,
        color: message.mine(this.session.user) ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
    }
  }

  @Builder
  private messageList() {
    Column() {
      if (this.messages.length === 0) {
        Column({ space: '10vp' }) {
          if (this.loading) {
            LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.darkTheme))
          } else {
            EmptyState({ title: '暂无消息', hint: this.errorText, icon: SymbolIcons.doc() })
          }
        }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.listScroller }) {
          ListItem() {
            Row() {
              GhostButton({
                label: this.loadingHistory ? '加载中…' : '加载更早消息',
                compact: true,
                onTap: (): void => { void this.loadHistory(); }
              })
            }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: '4vp', bottom: '2vp' })
          }
          ForEach(this.messages, (message: ChatMessage, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  this.messageBubble(message, index)
                }
                  .width('100%')
                  .constraintSize({ maxWidth: this.contentMaxWidth() })
              }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ left: '12vp', right: '12vp', top: '2vp', bottom: '2vp' })
            }
          }, (message: ChatMessage, index: number) => 'chat-' + String(message.id) + '-' + message.localKey + '-' + String(index))
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
      }
      if (this.errorText.length > 0 && this.messages.length > 0) {
        Text(this.errorText)
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.gold(this.darkTheme))
          .width('100%')
          .padding({ left: '12vp', right: '12vp', bottom: '2vp' })
          .maxLines(2)
      }
    }
      .width('100%')
      .layoutWeight(1)
  }

  @Builder
  private inputBar() {
    Column({ space: '0vp' }) {
      // 待发送的富媒体：随下一条消息一起发出，可逐条删除。
      if (this.draftMedia.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.draftMedia, (item: ForumMedia, index: number) => {
            Row({ space: '5vp' }) {
              if (item.kind === 'video' || item.kind === 'audio') {
                SymbolGlyph(SymbolIcons.play())
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor([Ui.accentStrong(this.darkTheme)])
              } else if (item.kind === 'image') {
                SymbolGlyph(SymbolIcons.image())
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor([Ui.accentStrong(this.darkTheme)])
              } else {
                SymbolGlyph(SymbolIcons.file())
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor([Ui.accentStrong(this.darkTheme)])
              }
              Text(this.mediaLabel(item.kind) + (item.title.length > 0 ? '：' + item.title : ''))
                .fontSize(Ui.fs('10.5vp', this.fontScale))
                .fontColor(Ui.inkSoft(this.darkTheme))
                .maxLines(1)
                .constraintSize({ maxWidth: '140vp' })
              Text('×')
                .fontSize(Ui.fs('12vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .width('14vp')
                .textAlign(TextAlign.Center)
                .onClick(() => { this.removeDraftMedia(index); })
            }
              .height('26vp')
              .padding({ left: '9vp', right: '5vp' })
              .borderRadius('13vp')
              .backgroundColor(Ui.accentSoft(this.darkTheme))
              .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
              .margin('2vp')
          }, (item: ForumMedia, index: number) => 'draft-media-' + String(index) + '-' + item.kind)
        }
          .width('100%')
          .padding({ top: '6vp' })
      }
      if (this.replyVisible) {
        Row({ space: '8vp' }) {
          Text('回复 ' + (this.replyTo.name || this.replyTo.user) + '：' + this.formatAction(this.replyTo))
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          Text('×')
            .fontSize(Ui.fs('16vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .onClick(() => { this.replyVisible = false; })
        }
          .width('100%')
          .padding('6vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      }
      Row({ space: '7vp' }) {
        Text('☺')
          .fontSize(Ui.fs('22vp', this.fontScale))
          .fontColor(this.showEmoji ? Ui.accent(this.darkTheme) : Ui.inkSoft(this.darkTheme))
          .width('34vp')
          .height('38vp')
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.showEmoji = !this.showEmoji;
            this.showPlus = false;
          })
        TextInput({ text: this.draft, placeholder: this.muted ? '你已被禁言' : '说点什么吧...' })
          .layoutWeight(1)
          .height('42vp')
          .fontSize(Ui.fs('14vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .placeholderColor(Ui.inkFaint(this.darkTheme))
          .caretColor(Ui.accent(this.darkTheme))
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .borderRadius('21vp')
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .padding({ left: '14vp', right: '14vp' })
          .enabled(!this.muted)
          .onChange((value: string) => {
            this.draft = value;
            if (value.endsWith('@')) {
              this.showMembers = true;
            }
          })
          .onSubmit(() => { void this.sendText(); })
        Text('＋')
          .fontSize(Ui.fs('22vp', this.fontScale))
          .fontColor(this.showPlus ? Ui.accent(this.darkTheme) : Ui.inkSoft(this.darkTheme))
          .width('32vp')
          .height('38vp')
          .textAlign(TextAlign.Center)
          .onClick(() => {
            // 点 ＋ 展开更多功能时先收起输入法，避免键盘挡住面板。
            if (!this.showPlus) {
              this.hideKeyboard();
            }
            this.showPlus = !this.showPlus;
            this.showEmoji = false;
          })
        PrimaryButton({ label: this.sending ? '…' : '发送', compact: true, onTap: (): void => { void this.sendText(); } })
      }
        .width('100%')
        .padding({ top: '8vp', bottom: '8vp' })
      if (this.showEmoji) {
        Column({ space: '6vp' }) {
          Row({ space: '6vp' }) {
            GlassChip({ label: '热门', selected: this.emojiTab === 0, compact: true, onTap: (): void => { this.emojiTab = 0; } })
            GlassChip({ label: '精选', selected: this.emojiTab === 1, compact: true, onTap: (): void => { this.emojiTab = 1; } })
          }
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.emojiTab === 0 ? this.emojisHot : this.emojisSelect, (emoji: string) => {
              Text(emoji)
                .fontSize(Ui.fs('24vp', this.fontScale))
                .width('38vp')
                .height('38vp')
                .textAlign(TextAlign.Center)
                .onClick(() => { this.insertEmoji(emoji); })
            }, (emoji: string) => 'emoji-' + emoji)
          }
            .width('100%')
            .height('140vp')
        }
          .width('100%')
          .padding({ top: '6vp', bottom: '8vp' })
      }
      if (this.showPlus) {
        Column({ space: '8vp' }) {
          Row({ space: '8vp' }) {
            this.plusItem('图片', SymbolIcons.image(), 'image');
            this.plusItem('视频', SymbolIcons.play(), 'video');
            this.plusItem('文件', SymbolIcons.file(), 'file');
            this.plusItem('音频', SymbolIcons.play(), 'voice');
          }
            .width('100%')
          Row({ space: '8vp' }) {
            this.plusItem('红包', SymbolIcons.wallet(), 'redpacket');
            this.plusItem('名片', SymbolIcons.mine(false), 'card');
            this.plusItem('位置', SymbolIcons.cast(), 'location');
            this.plusItem('@成员', SymbolIcons.doc(), 'mention');
          }
            .width('100%')
        }
          .width('100%')
          .padding({ top: '6vp', bottom: '8vp' })
      }
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '12vp',
        right: this.tablet() ? '24vp' : '12vp',
        bottom: (this.safeBottom() + 4) + 'vp'
      })
      .backgroundColor(Ui.glassTint(this.darkTheme))
      .backdropBlur(this.glassBlurRadius())
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
  }

  @Builder
  private plusItem(label: string, icon: Resource, kind: string) {
    Column({ space: '3vp' }) {
      SymbolGlyph(icon)
        .fontSize(Ui.fs('22vp', this.fontScale))
        .fontColor([Ui.accentStrong(this.darkTheme)])
      Text(label)
        .fontSize(Ui.fs('10.5vp', this.fontScale))
        .fontColor(Ui.accentStrong(this.darkTheme))
    }
      .layoutWeight(1)
      .height('58vp')
      .justifyContent(FlexAlign.Center)
      .borderRadius('12vp')
      .backgroundColor(Ui.accentSoft(this.darkTheme))
      .onClick(() => {
        if (kind === 'redpacket') {
          this.showRedPacket = true;
          this.showPlus = false;
        } else if (kind === 'mention') {
          this.showMembers = true;
          this.showPlus = false;
        } else if (kind === 'location') {
          this.showToast('位置分享将在后续版本开放');
        } else {
          this.openUrl(kind);
        }
      })
  }

  @Builder
  private menuOverlay() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.showMenu = false; })
      Column({ space: '2vp' }) {
        this.menuItem('修改头像', () => { this.showToast('房间头像修改将在后续版本开放'); this.showMenu = false; })
        if (!this.privateMode) {
          this.menuItem('全体禁言', () => { void this.toggleBan(); });
          this.menuItem('解除禁言', () => { void this.unmuteAll(); });
          this.menuItem('设置管理', () => { this.showToast('管理员设置已提交给服务端'); this.showMenu = false; });
        }
        this.menuItem('清空聊天', () => { this.clearLocal(); });
        this.menuItem('退出房间', () => { this.showMenu = false; router.back(); });
      }
        .width('180vp')
        .padding('6vp')
        .margin({ top: '58vp', right: '12vp' })
        .borderRadius(Ui.R_MD)
        .backgroundColor(Ui.glassTintStrong(this.darkTheme))
        .backdropBlur(this.glassBlurRadius())
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
        .shadow({ radius: 18, color: Ui.shadow(this.darkTheme), offsetY: 8 })
    }
      .width('100%')
      .height('100%')
      .zIndex(20)
  }

  @Builder
  private menuItem(label: string, action: () => void) {
    Text(label)
      .fontSize(Ui.fs('13vp', this.fontScale))
      .fontColor(Ui.ink(this.darkTheme))
      .width('100%')
      .height('38vp')
      .padding({ left: '10vp' })
      .borderRadius('10vp')
      .onClick(action)
  }

  @Builder
  private infoOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Ui.scrim(this.darkTheme))
        .onClick(() => { this.showInfo = false; })
      Column({ space: '10vp' }) {
        Text(this.title)
          .fontSize(Ui.fs('21vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text(this.privateMode ? '私聊会话' : '房间介绍')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
        Text(this.privateMode ? '与 ' + this.peer + ' 的私聊消息' : this.roomIntro())
          .fontSize(Ui.fs('13vp', this.fontScale))
          .lineHeight('20vp')
          .fontColor(Ui.inkSoft(this.darkTheme))
          .width('100%')
        Text('在线 ' + String(this.onlineCount) + ' 人 · 消息 ' + String(this.messages.length) + ' 条')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
        Row({ space: '8vp' }) {
          if (this.privateMode) {
            GhostButton({ label: '查看资料', compact: true, onTap: (): void => {
              this.showInfo = false;
              this.openProfile(this.peer);
            } })
          }
          GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.showInfo = false; } })
        }
          .width('100%')
          .justifyContent(FlexAlign.End)
      }
        .width(this.tablet() ? '420vp' : '86%')
        .padding('20vp')
        .borderRadius(Ui.R_LG)
        .backgroundColor(Ui.glassTintStrong(this.darkTheme))
        .backdropBlur(this.glassBlurRadius())
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
    }
      .width('100%')
      .height('100%')
      .zIndex(15)
  }

  @Builder
  private actionOverlay() {
    if (this.actionVisible) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.actionVisible = false; })
        Column({ space: '2vp' }) {
          Text(this.actionPreview())
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
            .maxLines(2)
            .width('100%')
            .padding({ left: '10vp', right: '10vp', bottom: '4vp' })
          this.menuItem('复制', () => { this.copyMessage(this.actionMessage); });
          this.menuItem('回复', () => {
            this.replyTo = this.actionMessage;
            this.replyVisible = true;
            this.actionVisible = false;
          });
          this.menuItem('转发', () => {
            this.showToast('转发内容：' + this.actionPreview());
            this.actionVisible = false;
          });
          if (this.actionMessage.mine(this.session.user)) {
            this.menuItem('撤回', () => { this.confirmRevoke(this.actionMessage); });
          }
          this.menuItem('翻译', () => {
            this.showToast('翻译服务暂未接入');
            this.actionVisible = false;
          });
          if (!this.privateMode) {
            this.menuItem('禁言该用户', () => {
              const target: string = this.actionMessage.user;
              this.actionVisible = false;
              void this.muteTarget(target);
            });
          }
          this.menuItem('删除', () => {
            const target: string = this.actionMessage.user;
            const targetId: number = this.actionMessage.id;
            this.messages = this.messages.filter((item: ChatMessage) =>
              !(item.user === target && item.id === targetId));
            this.actionVisible = false;
          });
        }
          .width('100%')
          .padding({ left: '12vp', right: '12vp', top: '10vp', bottom: (this.safeBottom() + 10) + 'vp' })
          .borderRadius({ topLeft: '22vp', topRight: '22vp' })
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlurRadius())
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%')
        .height('100%')
        .zIndex(18)
    }
  }

  private async muteTarget(user: string): Promise<void> {
    if (!user) {
      return;
    }
    try {
      await CommunityApi.muteChat(this.session, this.room, user, true);
      this.showToast('已禁言 ' + user);
    } catch (error) {
      this.showToast('操作失败：' + String(error));
    }
  }

  @Builder
  private mediaKindChip(label: string, kind: string) {
    Row() {
      Text(label)
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontWeight(this.mediaKind === kind ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.mediaKind === kind ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
        .maxLines(1)
    }
      .height('28vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('14vp')
      .backgroundColor(this.mediaKind === kind ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.mediaKind === kind ? Ui.glassRingAccent(this.darkTheme) : Ui.glassRingSoft(this.darkTheme)
      })
      .accessibilityText('媒体类型：' + label)
      .onClick(() => { this.mediaKind = kind; })
  }

  @Builder
  private urlDialog() {
    if (this.showUrlDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showUrlDialog = false; });
        Column({ space: '10vp' }) {
          Text('添加' + this.mediaLabel(this.mediaKind))
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
          Row({ space: '6vp' }) {
            this.mediaKindChip('图片', 'image')
            this.mediaKindChip('视频', 'video')
            this.mediaKindChip('音乐', 'audio')
            this.mediaKindChip('附件', 'file')
          }
            .width('100%')
          TextInput({ text: this.urlValue, placeholder: '粘贴 http/https 资源链接' })
            .width('100%')
            .height('44vp')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .placeholderColor(Ui.inkFaint(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .borderRadius('22vp')
            .padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.urlValue = value; })
          if (this.mediaKind !== 'image') {
            TextInput({ text: this.mediaTitle,
              placeholder: this.mediaKind === 'file' ? '文件名（可选）' : '显示标题（可选）' })
              .width('100%')
              .height('40vp')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .placeholderColor(Ui.inkFaint(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .borderRadius('20vp')
              .padding({ left: '14vp', right: '14vp' })
              .onChange((value: string) => { this.mediaTitle = value; })
          }
          if (this.mediaKind === 'video') {
            TextInput({ text: this.mediaPoster, placeholder: '封面图链接（可选）' })
              .width('100%')
              .height('40vp')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .placeholderColor(Ui.inkFaint(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .borderRadius('20vp')
              .padding({ left: '14vp', right: '14vp' })
              .onChange((value: string) => { this.mediaPoster = value; })
          }
          Text('添加后会出现在输入框上方，可继续输入文字，点「发送」一起发出去。')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
          Row({ space: '8vp' }) {
            GhostButton({ label: '取消', compact: true, onTap: (): void => { this.showUrlDialog = false; } })
            PrimaryButton({ label: '添加', compact: true, onTap: (): void => { this.addDraftMedia(); } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
        }
          .width(this.tablet() ? '440vp' : '86%')
          .padding('20vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlurRadius())
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%')
        .height('100%')
        .zIndex(16)
    }
  }

  @Builder
  private redPacketDialog() {
    if (this.showRedPacket) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showRedPacket = false; });
        Column({ space: '8vp' }) {
          Text('发红包')
            .fontSize(Ui.fs('19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.gold(this.darkTheme))
          TextInput({ text: this.redAmount, placeholder: '金额（金币）' })
            .width('100%').height('42vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('21vp').padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.redAmount = value; })
          TextInput({ text: this.redCount, placeholder: '个数' })
            .width('100%').height('42vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('21vp').padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.redCount = value; })
          TextInput({ text: this.redBlessing, placeholder: '祝福语' })
            .width('100%').height('42vp').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('21vp').padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.redBlessing = value; })
          Row({ space: '8vp' }) {
            GhostButton({ label: '取消', compact: true, onTap: (): void => { this.showRedPacket = false; } })
            PrimaryButton({ label: '塞钱进红包', compact: true, onTap: (): void => { void this.sendRedPacket(); } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
        }
          .width(this.tablet() ? '440vp' : '86%')
          .padding('20vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlurRadius())
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%')
        .height('100%')
        .zIndex(17)
    }
  }

  @Builder
  private membersOverlay() {
    if (this.showMembers) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showMembers = false; });
        Column({ space: '6vp' }) {
          Text('选择要 @ 的成员')
            .fontSize(Ui.fs('15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          List() {
            ForEach(this.members, (name: string) => {
              ListItem() {
                Row({ space: '8vp' }) {
                  Text(name)
                    .fontSize(Ui.fs('14vp', this.fontScale))
                    .fontColor(Ui.ink(this.darkTheme))
                    .maxLines(1)
                    .layoutWeight(1)
                  // 右侧在线/离线状态
                  Row({ space: '4vp' }) {
                    Column()
                      .width('6vp')
                      .height('6vp')
                      .borderRadius('3vp')
                      .backgroundColor(this.isOnline(name) ? Ui.success(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                    Text(this.isOnline(name) ? '在线' : '离线')
                      .fontSize(Ui.fs('10vp', this.fontScale))
                      .fontColor(this.isOnline(name) ? Ui.success(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                  }
                }
                  .width('100%')
                  .height('40vp')
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => { this.insertMention(name); })
              }
            }, (name: string) => 'member-' + name)
          }
            .width('100%')
            .height('180vp')
        }
          .padding('14vp')
          .borderRadius({ topLeft: '20vp', topRight: '20vp' })
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlurRadius())
      }
        .width('100%')
        .height('100%')
        .zIndex(19)
    }
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        this.header()
        if (!this.loggedIn) {
          Column({ space: '12vp' }) {
            EmptyState({ title: '登录后进入聊天室', hint: '登录凭证缺失', icon: SymbolIcons.doc() })
            PrimaryButton({ label: '去登录', onTap: (): void => {
              router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
                Logger.error('CHAT_ROOM', '打开登录页失败：' + String(error));
              });
            } })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          this.messageList()
          this.inputBar()
        }
      }
        .width('100%')
        .height('100%')
      if (this.toastText.length > 0) {
        Text(this.toastText)
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .padding({ left: '16vp', right: '16vp', top: '9vp', bottom: '9vp' })
          .borderRadius('20vp')
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .align(Alignment.Bottom)
          .margin({ bottom: (this.safeBottom() + 100) + 'vp' })
      }
      if (this.showMenu) {
        this.menuOverlay()
      }
      if (this.showInfo) {
        this.infoOverlay()
      }
      if (this.actionVisible) {
        this.actionOverlay()
      }
      this.urlDialog()
      this.redPacketDialog()
      this.membersOverlay()
      // 其它会话的新消息提醒：本房间已被提醒服务跳过，这里只兜底展示排队中的提醒。
      ChatNoticeBanner()
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
        } catch (error) {
          Logger.warn('CHAT_ROOM', '更新聊天页宽度失败：' + String(error));
        }
      })
  }

  /** 卡片描述里去掉图片/链接行，避免把 URL 显示成正文。 */
  private cleanCardDesc(desc: string): string {
    const lines: string[] = (desc || '').split('\n');
    const kept: string[] = [];
    for (const line of lines) {
      const text: string = line.trim();
      if (text.length === 0) { continue; }
      if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) { continue; }
      kept.push(text);
    }
    return kept.join('\n');
  }
}

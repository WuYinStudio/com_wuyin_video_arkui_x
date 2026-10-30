import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { AccountApi, ChatEntry, FollowEntry } from './AccountApi';
import { AppState } from './AppState';
import { ChatMessage, CommunityApi, CommunitySession } from './CommunityApi';
import { ChatService } from './ChatService';
import { MediaCodec } from './MediaCodec';
import { Logger } from './Logger';
import { ChatNotificationPayload, NotificationService } from './NotificationService';
import { FriendItem, RoomItem, SocialStore } from './SocialStore';

/**
 * 一条待展示的聊天提醒。
 *
 * 只保存展示所需的快照：房间名（推送/回复都靠它定位 lts.php 房间；私聊通道下是
 * 双人私聊房间名）、私聊对象账号（非空表示这条提醒来自私聊通道）、发送者昵称与消息预览。
 */
export class ChatAlertInfo {
  version: number = 0;
  room: string = '';
  peer: string = '';
  title: string = '';
  sender: string = '';
  preview: string = '';
  time: string = '';
  unread: number = 1;
  /** 设置页「预览顶部弹窗」生成的示例提醒：只用于看样式，不回发消息。 */
  demo: boolean = false;
}

/** 轮询目标：一个聊天室或一个私聊房间。 */
class ChatAlertTarget {
  room: string = '';
  peer: string = '';

  constructor(room: string, peer: string) {
    this.room = room;
    this.peer = peer;
  }
}

/**
 * 聊天室 / 私聊的实时提醒服务。
 *
 * 设计要点：
 * 1. 前台常驻轮询（默认 4s，按 message.id 增量），每轮每房间只取最新 5 条，首轮只建立基线，
 *    不把历史消息当成新消息提醒；
 * 2. 新消息 → 弹窗（ChatNoticeBanner）+ 提示音；免打扰或关闭对应开关时静默；
 * 3. 同一房间连续来消息时就地更新弹窗（文案 + 条数 + 重新计时），不排队重复弹窗；
 * 4. 正在查看的房间（AppStorage 'activeChatRoom'）不弹窗、不响铃，交给聊天页自身处理；
 * 5. 弹窗内可直接回文字，回复成功后把该房间的已读基线推进到最新消息；
 * 6. 自身消息、黑名单用户、好友申请控制卡不计入提醒；
 * 7. 好友私聊走独立通道：3s 独立轮询 + friendSeen（账号 → 条数）独立游标，
 *    复用同一套弹窗/提示音/通知栏，但绝不读写房间通道的 seen。
 */
export class ChatAlertService {
  /** 轮询间隔（毫秒）。消息量大的房间依靠 message.id 增量，不会被重复提醒。 */
  static readonly INTERVAL: number = 4000;
  /** 每轮每个房间最多取多少条（只为算增量与预览，取太多没有意义）。 */
  static readonly PAGE_SIZE: number = 5;
  /** 单轮最多轮询的会话数量，避免房间过多时请求堆积。 */
  static readonly MAX_TARGETS: number = 8;
  /** 私聊通道的轮询间隔（毫秒）：比房间通道更短，好友私聊更即时。 */
  static readonly PRIVATE_INTERVAL: number = 3000;
  /** 私聊单轮最多检查多少个关注对象，避免好友过多时请求堆积。 */
  static readonly PRIVATE_MAX: number = 8;
  /** 提示音资源（entry/src/main/resources/rawfile/chat_notice.wav）。 */
  static readonly SOUND_FILE: string = 'chat_notice.wav';
  /** 通知栏提醒的附属文案。 */
  static readonly NOTIFY_SUMMARY: string = '无音影视 · 聊天提醒';

  private static timer: number = -1;
  private static polling: boolean = false;
  private static session: CommunitySession = new CommunitySession();
  private static sessionReady: boolean = false;
  /** 房间通道已读游标：房间名 → 已读到的 message.id。 */
  private static seen: Map<string, number> = new Map<string, number>();
  /**
   * 私聊通道已读游标：好友账号 → 已读到的记录条数。
   *
   * 私聊记录接口（echochat.php）没有稳定的 message.id，只能按"条数"推进；
   * 这份游标与房间通道的 seen 完全分开，互不覆盖、互不推进。
   */
  private static friendSeen: Map<string, number> = new Map<string, number>();
  /** 私聊通道自己的定时器与节流标记，避免和房间轮询抢同一个开关。 */
  private static privateTimer: number = -1;
  private static privatePolling: boolean = false;
  private static queue: ChatAlertInfo[] = [];
  private static current?: ChatAlertInfo;
  private static versionSeed: number = 0;
  private static soundBusy: boolean = false;
  /** 应用是否在前台：决定用应用内弹窗还是系统通知栏提醒。 */
  private static foreground: boolean = true;
  /** 后台期间累计的未读条数（通知栏只保留一条通知，用它显示"共 N 条"）。 */
  private static backgroundCount: number = 0;

  static init(): void {
    try {
      ChatAlertService.seen.clear();
      ChatAlertService.friendSeen.clear();
      ChatAlertService.queue = [];
      ChatAlertService.current = undefined;
      ChatAlertService.sessionReady = false;
      // 启动时清掉上一次进程可能残留的弹窗状态（AppStorage 只在 UI 线程可用，失败不影响主流程）。
      AppStorage.setOrCreate<boolean>('chatAlertVisible', false);
      AppStorage.setOrCreate<number>('chatAlertPending', 0);
      Logger.info('CHAT_ALERT', '聊天提醒服务已初始化');
    } catch (error) {
      Logger.warn('CHAT_ALERT', '初始化聊天提醒服务失败：' + String(error));
    }
  }

  /** 前台启动轮询；重复调用安全。 */
  static start(): void {
    ChatAlertService.startPrivate();
    if (ChatAlertService.timer >= 0) {
      return;
    }
    ChatAlertService.timer = setInterval(() => {
      void ChatAlertService.poll();
    }, ChatAlertService.INTERVAL);
    void ChatAlertService.poll();
    Logger.info('CHAT_ALERT', '聊天提醒轮询已启动，间隔=' + String(ChatAlertService.INTERVAL) + 'ms');
  }

  /** 应用退到后台时停止轮询，避免无意义的后台网络请求。 */
  static stop(): void {
    ChatAlertService.stopPrivate();
    if (ChatAlertService.timer >= 0) {
      clearInterval(ChatAlertService.timer);
      ChatAlertService.timer = -1;
      Logger.info('CHAT_ALERT', '聊天提醒轮询已停止');
    }
  }

  /** 切回前台：应用内弹窗 + 提示音；清掉通知栏遗留并释放后台持续任务。 */
  static enterForeground(): void {
    ChatAlertService.foreground = true;
    ChatAlertService.backgroundCount = 0;
    void NotificationService.cancelAll();
    ChatAlertService.start();
  }

  /** 切到后台：开关打开时继续轮询并改为系统通知栏提醒，否则停止轮询。 */
  static enterBackground(): void {
    ChatAlertService.foreground = false;
    ChatAlertService.backgroundCount = 0;
    if (ChatAlertService.backgroundAllowed()) {
      ChatAlertService.start();
    } else {
      ChatAlertService.stop();
      void NotificationService.cancelAll();
    }
  }

  /** 设置页切换「后台通知栏提醒」后调用：应用已在后台时立即生效。 */
  static refreshBackgroundMode(): void {
    if (ChatAlertService.foreground) {
      return;
    }
    if (ChatAlertService.backgroundAllowed()) {
      ChatAlertService.start();
      return;
    }
    ChatAlertService.stop();
    ChatAlertService.backgroundCount = 0;
    void NotificationService.cancelAll();
  }

  /** Ability 销毁：停表、释放后台任务、清通知。 */
  static shutdown(): void {
    ChatAlertService.stop();
    void NotificationService.cancelAll();
  }

  /** 后台通知栏提醒是否生效：免打扰关闭、且「后台通知栏提醒」开关打开。 */
  private static backgroundAllowed(): boolean {
    if (AppStorage.get<boolean>('chatDndEnabled') === true) {
      return false;
    }
    return AppStorage.get<boolean>('chatBackgroundNotify') !== false;
  }


  static running(): boolean {
    return ChatAlertService.timer >= 0;
  }

  // ---------------- 提醒开关 ----------------

  private static soundAllowed(): boolean {
    if (AppStorage.get<boolean>('chatDndEnabled') === true) { return false; }
    return AppStorage.get<boolean>('chatSoundEnabled') !== false;
  }

  private static bannerAllowed(): boolean {
    if (AppStorage.get<boolean>('chatDndEnabled') === true) { return false; }
    return AppStorage.get<boolean>('chatBannerEnabled') !== false;
  }

  /** 设置页「试听」：按当前开关播放一次提示音。 */
  static previewSound(): boolean {
    if (!ChatAlertService.soundAllowed()) {
      return false;
    }
    ChatAlertService.playNoticeSound();
    return true;
  }

  /** 设置页「预览弹窗」：用一条本地示例消息展示顶部提醒。 */
  static previewBanner(): void {
    const info: ChatAlertInfo = new ChatAlertInfo();
    info.room = SocialStore.OFFICIAL_ROOM;
    info.peer = '';
    info.title = SocialStore.OFFICIAL_ROOM;
    info.sender = '无音小助手';
    info.preview = '这是一条示例提醒，可直接在这里回复文字消息';
    info.time = ChatAlertService.nowTime();
    info.unread = 1;
    info.demo = true;
    ChatAlertService.enqueue(info);
  }

  // ---------------- 轮询 ----------------

  private static async ensureSession(): Promise<boolean> {
    if (ChatAlertService.sessionReady && ChatAlertService.session.valid()) {
      return true;
    }
    try {
      ChatAlertService.session = await CommunityApi.readSession();
      ChatAlertService.sessionReady = ChatAlertService.session.valid();
    } catch (error) {
      ChatAlertService.sessionReady = false;
      Logger.warn('CHAT_ALERT', '读取聊天登录状态失败：' + String(error));
    }
    return ChatAlertService.sessionReady;
  }

  /** 登录会话变化（登录/退出）后重新读取凭证。 */
  static refreshSession(): void {
    ChatAlertService.sessionReady = false;
    ChatAlertService.seen.clear();
    // 账号换了，按账号记录的私聊条数游标也必须清空，否则会拿旧账号的条数比新账号的记录。
    ChatAlertService.friendSeen.clear();
  }

  private static targets(): ChatAlertTarget[] {
    const result: ChatAlertTarget[] = [];
    try {
      const rooms: RoomItem[] = SocialStore.roomsList();
      for (const room of rooms) {
        if (result.length >= ChatAlertService.MAX_TARGETS) { break; }
        if (!room.name) { continue; }
        result.push(new ChatAlertTarget(room.name, ''));
      }
      // 好友私聊不再走这里：lts.php 的私聊房间只是旧数据，真正的私聊记录在
      // echochat.php，由 pollPrivateChats() 用独立游标单独轮询，避免同一条消息弹两次。
    } catch (error) {
      Logger.warn('CHAT_ALERT', '整理聊天提醒目标失败：' + String(error));
    }
    return result;
  }

  private static async poll(): Promise<void> {
    if (ChatAlertService.polling) {
      return;
    }
    ChatAlertService.polling = true;
    try {
      if (!await ChatAlertService.ensureSession()) {
        return;
      }
      const targets: ChatAlertTarget[] = ChatAlertService.targets();
      const activeRoom: string = AppStorage.get<string>('activeChatRoom') || '';
      for (const target of targets) {
        await ChatAlertService.inspect(target, activeRoom);
      }
    } catch (error) {
      Logger.warn('CHAT_ALERT', '聊天提醒轮询失败：' + String(error));
    } finally {
      ChatAlertService.polling = false;
    }
  }

  private static async inspect(target: ChatAlertTarget, activeRoom: string): Promise<void> {
    try {
      const result = await CommunityApi.chatMessages(ChatAlertService.session, target.room, 1,
        ChatAlertService.PAGE_SIZE, 0);
      const messages: ChatMessage[] = result.messages;
      if (messages.length === 0) {
        return;
      }
      let newest: ChatMessage = messages[0];
      for (const item of messages) {
        if (item.id > newest.id) { newest = item; }
      }
      const baseline: number | undefined = ChatAlertService.seen.get(target.room);
      if (baseline === undefined) {
        // 首轮只建立基线：历史消息不提醒。
        ChatAlertService.seen.set(target.room, newest.id);
        return;
      }
      if (newest.id <= baseline) {
        return;
      }
      ChatAlertService.seen.set(target.room, newest.id);
      // 每条消息只解析一次编码（JSON.parse），避免一轮轮询重复解析数百次。
      const fresh: ChatMessage[] = [];
      for (const item of messages) {
        if (item.id <= baseline) { continue; }
        if (item.user === ChatAlertService.session.user) { continue; }
        if (SocialStore.isBlocked(item.user)) { continue; }
        const kind: string = MediaCodec.decode(item.content).kind;
        if (kind === 'friend_request' || kind === 'friend_accept' || kind === 'friend_reject') { continue; }
        fresh.push(item);
      }
      if (fresh.length === 0) {
        return;
      }
      const last: ChatMessage = fresh[fresh.length - 1];
      const preview: string = MediaCodec.preview(MediaCodec.decode(last.content));
      ChatAlertService.touchSummary(target, last, preview, fresh.length);
      if (activeRoom.length > 0 && activeRoom === target.room) {
        // 正在该房间内：不弹窗、不响铃，页面自己会滚动到底部。
        return;
      }
      const info: ChatAlertInfo = new ChatAlertInfo();
      info.room = target.room;
      info.peer = target.peer;
      info.title = target.peer.length > 0 ? ChatAlertService.friendTitle(target.peer) : target.room;
      info.sender = last.name || last.user;
      info.preview = preview;
      info.time = last.time || ChatAlertService.nowTime();
      info.unread = fresh.length;
      ChatAlertService.enqueue(info);
    } catch (error) {
      Logger.warn('CHAT_ALERT', '检查房间新消息失败：' + target.room + '，' + String(error));
    }
  }

  // ---------------- 私聊通道（与房间通道分开） ----------------

  /** 启动私聊轮询：独立定时器 + 独立游标，房间通道停/起都不影响它自己的开关。 */
  private static startPrivate(): void {
    if (ChatAlertService.privateTimer >= 0) {
      return;
    }
    ChatAlertService.privateTimer = setInterval(() => {
      void ChatAlertService.pollPrivateChats();
    }, ChatAlertService.PRIVATE_INTERVAL);
    void ChatAlertService.pollPrivateChats();
    Logger.info('CHAT_ALERT', '私聊提醒轮询已启动，间隔=' + String(ChatAlertService.PRIVATE_INTERVAL) + 'ms');
  }

  private static stopPrivate(): void {
    if (ChatAlertService.privateTimer >= 0) {
      clearInterval(ChatAlertService.privateTimer);
      ChatAlertService.privateTimer = -1;
      Logger.info('CHAT_ALERT', '私聊提醒轮询已停止');
    }
  }

  /**
   * 好友私聊轮询（每 3s）：关注列表 → 每个人的私聊记录 → 条数增量。
   *
   * 与房间通道共用提醒队列 / 弹窗 / 提示音 / 通知栏，但自己维护 friendSeen（账号 → 条数），
   * 不写 seen，所以一条私聊不会被房间通道再弹一次，两边的已读也不会互相推进。
   */
  private static async pollPrivateChats(): Promise<void> {
    if (ChatAlertService.privatePolling) {
      return;
    }
    ChatAlertService.privatePolling = true;
    try {
      if (!await ChatAlertService.ensureSession()) {
        return;
      }
      const me: string = ChatAlertService.session.user.trim();
      if (me.length === 0) {
        return;
      }
      const following: FollowEntry[] = AccountApi.parseFollowList(
        await AccountApi.following(me, ChatAlertService.session.pass));
      const activeRoom: string = AppStorage.get<string>('activeChatRoom') || '';
      let visited: number = 0;
      for (const entry of following) {
        if (visited >= ChatAlertService.PRIVATE_MAX) { break; }
        const account: string = entry.user.trim();
        if (account.length === 0) { continue; }
        visited++;
        await ChatAlertService.inspectPrivate(account, entry.name, me, activeRoom);
      }
    } catch (error) {
      Logger.warn('CHAT_ALERT', '私聊提醒轮询失败：' + String(error));
    } finally {
      ChatAlertService.privatePolling = false;
    }
  }

  /** 检查一个好友的私聊：只有"对方最后一条 + 条数增加"才提醒。 */
  private static async inspectPrivate(account: string, displayName: string, me: string,
    activeRoom: string): Promise<void> {
    try {
      const text: string = await AccountApi.friendChatList(me, account);
      const log: ChatEntry[] = AccountApi.parseChatLog(text);
      if (log.length === 0) {
        return;
      }
      const total: number = log.length;
      const known: number | undefined = ChatAlertService.friendSeen.get(account);
      if (known === undefined) {
        // 首次见到这个好友：只建立基线，历史记录不提醒。
        ChatAlertService.friendSeen.set(account, total);
        return;
      }
      if (total < known) {
        // 记录被清理/截断：游标回落到实际条数，避免以后永远认为"没有新消息"。
        ChatAlertService.friendSeen.set(account, total);
        return;
      }
      if (total === known) {
        return;
      }
      const last: ChatEntry = log[total - 1];
      // 自己发的（例如在别处已回）只推进游标，不提醒。
      if (last.user === me || last.user.length === 0) {
        ChatAlertService.friendSeen.set(account, total);
        return;
      }
      if (SocialStore.isBlocked(last.user)) {
        ChatAlertService.friendSeen.set(account, total);
        return;
      }
      const added: number = total - known;
      ChatAlertService.friendSeen.set(account, total);
      const preview: string = MediaCodec.preview(MediaCodec.decode(last.content));
      const room: string = ChatService.privateRoom(me, account);
      if (activeRoom.length > 0 && activeRoom === room) {
        // 正在这个私聊页里：只推进游标，不弹窗、不响铃、也不累计好友未读角标。
        return;
      }
      // 复用房间通道的摘要同步与弹窗队列：target.peer 非空时 touchSummary 走好友分支。
      const bridge: ChatMessage = new ChatMessage();
      bridge.id = total;
      bridge.user = last.user;
      bridge.name = displayName.length > 0 ? displayName : last.user;
      bridge.content = last.content;
      bridge.time = last.time;
      const target: ChatAlertTarget = new ChatAlertTarget(room, account);
      ChatAlertService.touchSummary(target, bridge, preview, added);
      const info: ChatAlertInfo = new ChatAlertInfo();
      info.room = room;
      info.peer = account;
      info.title = ChatAlertService.friendTitle(account);
      info.sender = displayName.length > 0 ? displayName : last.user;
      info.preview = preview;
      info.time = last.time || ChatAlertService.nowTime();
      info.unread = added;
      ChatAlertService.enqueue(info);
      Logger.info('CHAT_ALERT', '私聊新消息：' + account + '，新增 ' + String(added) + ' 条');
    } catch (error) {
      Logger.warn('CHAT_ALERT', '检查好友私聊失败：' + account + '，' + String(error));
    }
  }

  private static friendTitle(account: string): string {
    const friend: FriendItem | undefined = SocialStore.friend(account);
    if (friend && friend.name) { return friend.name; }
    return account;
  }

  /** 同步未读摘要，让聊天室列表 / 消息中心返回时就已经是新的未读数。 */
  private static touchSummary(target: ChatAlertTarget, last: ChatMessage, preview: string, unread: number): void {
    try {
      if (target.peer.length === 0) {
        const room: RoomItem | undefined = SocialStore.room(target.room);
        const total: number = room !== undefined ? room.unread + unread : unread;
        SocialStore.touchRoom(target.room, preview, last.time, total);
        return;
      }
      const friend: FriendItem | undefined = SocialStore.friend(target.peer);
      if (!friend) { return; }
      const updated: FriendItem = new FriendItem();
      updated.account = friend.account;
      updated.name = friend.name;
      updated.avatar = friend.avatar;
      updated.grade = friend.grade;
      updated.signature = friend.signature;
      updated.lastMessage = preview;
      updated.lastTime = last.time;
      updated.unread = friend.unread + unread;
      SocialStore.upsertFriend(updated);
    } catch (error) {
      Logger.warn('CHAT_ALERT', '更新未读摘要失败：' + String(error));
    }
  }

  // ---------------- 弹窗队列 ----------------

  private static enqueue(info: ChatAlertInfo): void {
    // 应用在后台：不发应用内弹窗、也不放提示音，改发系统通知栏提醒（免打扰同样压制）。
    if (!ChatAlertService.foreground) {
      ChatAlertService.publishBackground(info);
      return;
    }
    if (!ChatAlertService.bannerAllowed()) {
      // 免打扰 / 关闭顶部弹窗时仍需响铃（免打扰已在 soundAllowed 中排除）。
      ChatAlertService.playNoticeSound();
      return;
    }
    // 同一个房间连续来消息：就地刷新正在展示的弹窗（文案 + 条数，并重新计时），
    // 不再排队重复弹一条；排队中的同一房间也只更新内容。
    const showing: ChatAlertInfo | undefined = ChatAlertService.current;
    if (showing !== undefined && !showing.demo && showing.room === info.room) {
      ChatAlertService.mergeInto(showing, info, true);
      return;
    }
    for (const queued of ChatAlertService.queue) {
      if (!queued.demo && queued.room === info.room) {
        ChatAlertService.mergeInto(queued, info, false);
        ChatAlertService.publishPending();
        return;
      }
    }
    ChatAlertService.versionSeed++;
    info.version = ChatAlertService.versionSeed;
    ChatAlertService.queue.push(info);
    if (ChatAlertService.current === undefined) {
      ChatAlertService.advance();
    } else {
      ChatAlertService.publishPending();
    }
    ChatAlertService.playNoticeSound();
  }

  /** 后台提醒：只维护一条通知栏通知，累计条数就地更新，点击直达对应聊天室。 */
  private static publishBackground(info: ChatAlertInfo): void {
    ChatAlertService.backgroundCount = Math.max(1,
      ChatAlertService.backgroundCount + Math.max(1, info.unread));
    if (!ChatAlertService.backgroundAllowed()) {
      return;
    }
    const context: common.UIAbilityContext | undefined = AppState.context;
    if (!context) {
      return;
    }
    const payload: ChatNotificationPayload = new ChatNotificationPayload();
    payload.title = info.title + '（' + String(ChatAlertService.backgroundCount) + ' 条新消息）';
    payload.text = (info.sender || info.title) + '：' + info.preview;
    payload.summary = ChatAlertService.NOTIFY_SUMMARY;
    payload.room = info.room;
    payload.peer = info.peer;
    void NotificationService.publish(context, payload);
    Logger.info('CHAT_ALERT', '后台提醒转入通知栏：' + payload.title);
  }

  private static advance(): void {
    const next: ChatAlertInfo | undefined = ChatAlertService.queue.shift();
    if (next === undefined) {
      ChatAlertService.current = undefined;
      ChatAlertService.publishPending();
      AppStorage.setOrCreate<boolean>('chatAlertVisible', false);
      return;
    }
    ChatAlertService.current = next;
    // 先置为可见再发布内容：弹窗组件同时监听两者，先可见才能正确布防自动收起定时器。
    AppStorage.setOrCreate<boolean>('chatAlertVisible', true);
    AppStorage.setOrCreate<ChatAlertInfo>('chatAlertInfo', next);
    ChatAlertService.publishPending();
    Logger.info('CHAT_ALERT', '展示聊天提醒：' + next.title + '，' + next.sender + '：' + next.preview);
  }

  /**
   * 把同一房间的新消息合并进已有提醒。
   * showNow=true 表示这条提醒正在展示：重新发布一份副本以刷新文案与条数，
   * version 保持不变，弹窗组件据此只"重新计时"，不会清掉用户正在输入的回复草稿。
   */
  private static mergeInto(target: ChatAlertInfo, incoming: ChatAlertInfo, showNow: boolean): void {
    target.peer = incoming.peer;
    target.title = incoming.title;
    target.sender = incoming.sender;
    target.preview = incoming.preview;
    target.time = incoming.time;
    target.unread = Math.max(1, target.unread + Math.max(1, incoming.unread));
    if (showNow) {
      const next: ChatAlertInfo = ChatAlertService.clone(target);
      ChatAlertService.current = next;
      AppStorage.setOrCreate<ChatAlertInfo>('chatAlertInfo', next);
      Logger.info('CHAT_ALERT', '提醒内容实时刷新：' + next.title + '，累计 ' + String(next.unread) + ' 条');
    }
    ChatAlertService.playNoticeSound();
  }

  private static clone(source: ChatAlertInfo): ChatAlertInfo {
    const copy: ChatAlertInfo = new ChatAlertInfo();
    copy.version = source.version;
    copy.room = source.room;
    copy.peer = source.peer;
    copy.title = source.title;
    copy.sender = source.sender;
    copy.preview = source.preview;
    copy.time = source.time;
    copy.unread = source.unread;
    copy.demo = source.demo;
    return copy;
  }

  private static publishPending(): void {
    AppStorage.setOrCreate<number>('chatAlertPending', ChatAlertService.queue.length);
  }

  static currentInfo(): ChatAlertInfo | undefined {
    return ChatAlertService.current;
  }

  /** 关闭当前提醒，稍后展示下一条（不打断收起动画）。 */
  static dismiss(): void {
    AppStorage.setOrCreate<boolean>('chatAlertVisible', false);
    ChatAlertService.current = undefined;
    ChatAlertService.publishPending();
    if (ChatAlertService.queue.length > 0) {
      setTimeout(() => {
        if (ChatAlertService.current === undefined && ChatAlertService.queue.length > 0) {
          ChatAlertService.advance();
        }
      }, 320);
    }
  }

  /** 忽略全部待展示提醒。 */
  static dismissAll(): void {
    ChatAlertService.queue = [];
    ChatAlertService.dismiss();
  }

  /** 把当前提醒标记为已读（打开聊天页时调用），避免重复提醒同一批消息。 */
  static markCurrentRead(): void {
    const info: ChatAlertInfo | undefined = ChatAlertService.current;
    if (info === undefined) { return; }
    try {
      // 私聊通道：游标是"条数"，只标记私聊这一侧的已读，不碰房间的 message.id 游标。
      if (info.peer.length > 0) {
        const knownCount: number = ChatAlertService.friendSeen.get(info.peer) || 0;
        if (knownCount > 0) {
          SocialStore.markRead(info.room, knownCount);
        }
        return;
      }
      const known: number = ChatAlertService.seen.get(info.room) || 0;
      SocialStore.markRead(info.room, known);
    } catch (error) {
      Logger.warn('CHAT_ALERT', '标记提醒已读失败：' + String(error));
    }
  }

  /** 弹窗内快捷回复：直接在当前提醒的房间发送一条文本消息。 */
  static async reply(text: string): Promise<void> {
    const info: ChatAlertInfo | undefined = ChatAlertService.current;
    if (info === undefined) {
      throw new Error('没有待回复的消息');
    }
    if (info.demo) {
      throw new Error('示例提醒仅用于预览，不能回复');
    }
    const content: string = text.trim();
    if (content.length === 0) {
      throw new Error('回复内容不能为空');
    }
    if (!ChatAlertService.session.valid()) {
      await ChatAlertService.ensureSession();
    }
    if (!ChatAlertService.session.valid()) {
      throw new Error('登录状态已失效，请重新登录');
    }
    // 私聊通道：回复走 friendchat.php，并把它算进私聊条数游标（自己发的不再提醒）。
    if (info.peer.length > 0) {
      const result: string = await AccountApi.sendFriendChat(ChatAlertService.session.user,
        ChatAlertService.session.pass, info.peer, content);
      const sent: number = ChatAlertService.friendSeen.get(info.peer) || 0;
      ChatAlertService.friendSeen.set(info.peer, sent + 1);
      Logger.info('CHAT_ALERT', '顶部提醒私聊回复成功：' + info.peer + '，' + result);
      return;
    }
    const messageId: number = await CommunityApi.sendChat(ChatAlertService.session, info.room, content);
    if (messageId > 0) {
      const known: number = ChatAlertService.seen.get(info.room) || 0;
      ChatAlertService.seen.set(info.room, Math.max(known, messageId));
    }
    Logger.info('CHAT_ALERT', '顶部提醒快捷回复成功，房间=' + info.room);
  }

  // ---------------- 提示音 ----------------

  /** 播放一次聊天提示音（受提示音开关与免打扰约束）。 */
  static playNoticeSound(): void {
    if (!ChatAlertService.soundAllowed()) {
      return;
    }
    void ChatAlertService.playSoundFile();
  }

  private static async playSoundFile(): Promise<void> {
    if (ChatAlertService.soundBusy) {
      return;
    }
    const context: common.UIAbilityContext | undefined = AppState.context;
    if (!context) {
      return;
    }
    ChatAlertService.soundBusy = true;
    try {
      // 每次播放重新取 rawfile 句柄，并在释放时关闭，避免常驻轮询下 fd 累积。
      const raw = await context.resourceManager.getRawFd(ChatAlertService.SOUND_FILE);
      const player: media.AVPlayer = await media.createAVPlayer();
      let released: boolean = false;
      const release = (): void => {
        if (released) { return; }
        released = true;
        ChatAlertService.soundBusy = false;
        try {
          player.release().catch((error: BusinessError) => {
            Logger.warn('CHAT_ALERT', '释放提示音播放器失败：' + String(error.message || error));
          });
        } catch (error) {
          Logger.warn('CHAT_ALERT', '释放提示音播放器异常：' + String(error));
        }
        try {
          context.resourceManager.closeRawFd(ChatAlertService.SOUND_FILE).catch((error: BusinessError) => {
            Logger.warn('CHAT_ALERT', '关闭提示音资源句柄失败：' + String(error.message || error));
          });
        } catch (error) {
          Logger.warn('CHAT_ALERT', '关闭提示音资源句柄异常：' + String(error));
        }
      };
      player.on('stateChange', (state: string) => {
        try {
          if (state === 'initialized') {
            player.prepare().catch((error: Error) => {
              Logger.warn('CHAT_ALERT', '准备提示音失败：' + String(error));
              release();
            });
          } else if (state === 'prepared') {
            player.play().catch((error: Error) => {
              Logger.warn('CHAT_ALERT', '播放提示音失败：' + String(error));
              release();
            });
          } else if (state === 'completed' || state === 'stopped' || state === 'error') {
            release();
          }
        } catch (error) {
          Logger.warn('CHAT_ALERT', '处理提示音状态失败：' + String(error));
          release();
        }
      });
      player.on('error', (error: BusinessError) => {
        Logger.warn('CHAT_ALERT', '提示音播放异常：' + String(error.message || '未知错误'));
        release();
      });
      player.fdSrc = { fd: raw.fd, offset: raw.offset, length: raw.length };
      // 兜底释放：即使没有收到 completed 回调也不会留下悬挂的播放器。
      setTimeout(release, 5000);
      Logger.info('CHAT_ALERT', '播放聊天提示音');
    } catch (error) {
      ChatAlertService.soundBusy = false;
      Logger.warn('CHAT_ALERT', '创建提示音播放器失败：' + String(error));
    }
  }

  private static nowTime(): string {
    const date: Date = new Date();
    const hour: string = date.getHours() < 10 ? '0' + String(date.getHours()) : String(date.getHours());
    const minute: string = date.getMinutes() < 10 ? '0' + String(date.getMinutes()) : String(date.getMinutes());
    return hour + ':' + minute;
  }
}

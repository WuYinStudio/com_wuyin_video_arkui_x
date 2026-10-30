import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AccountApi, ChatEntry, FollowEntry, LtsRoom } from '../common/AccountApi';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession } from '../common/CommunityApi';
import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { SymbolIcons } from '../common/SymbolIcons';
import { FriendItem, RoomItem, SocialStore } from '../common/SocialStore';
import { UserTitles } from '../common/UserTitles';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';

class ChatRouteParams {
  room: string = '';
  target: string = '';
}

class ChatRouteOptions {
  url: string = 'pages/ChatRoomPage';
  params: ChatRouteParams;

  constructor(room: string, target: string) {
    this.params = new ChatRouteParams();
    this.params.room = room;
    this.params.target = target;
  }
}

/**
 * 消息中心：好友 / 群聊（群聊即聊天室）。
 * 布局：手机单列、平板双栏（好友 | 群聊）；深浅色统一走 Ui.*。
 */
@Component
export struct MessageCenterPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private friends: FriendItem[] = [];
  @State private rooms: RoomItem[] = [];
  @State private session: CommunitySession = new CommunitySession();
  @State private loggedIn: boolean = false;
  @State private viewportWidth: number = 360;
  @State private tab: number = 0;
  @State private refreshing: boolean = false;
  @State private loading: boolean = false;
  private readonly navScroller: Scroller = new Scroller();
  // 实时刷新定时器（好友 + 群聊未读/最新消息）。
  private refreshTimer: number = -1;
  // 每个好友已有的私聊条数（用于算未读增量）。
  private peerCounts: Map<string, number> = new Map<string, number>();

  aboutToAppear(): void {
    void this.load();
    this.startRefreshTimer();
  }

  aboutToDisappear(): void {
    this.stopRefreshTimer();
  }

  /** 5 秒轮询一次，好友/群聊的未读与新消息实时刷新。 */
  private startRefreshTimer(): void {
    this.stopRefreshTimer();
    this.refreshTimer = setInterval(() => { void this.load(); }, 3000);
  }

  private stopRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  /** 增量同步好友：只改新增/删除/内容变化的条目，未变化的保留原对象（避免整列表闪烁）。 */
  private syncFriends(next: FriendItem[]): void {
    const current: FriendItem[] = this.friends;
    let changed: boolean = false;
    const kept: FriendItem[] = [];
    for (const item of next) {
      const old: FriendItem | undefined = current.find((row: FriendItem) => row.account === item.account);
      if (old === undefined) {
        kept.push(item);
        changed = true;
        continue;
      }
      if (old.unread !== item.unread) { old.unread = item.unread; changed = true; }
      if (old.lastMessage !== item.lastMessage) { old.lastMessage = item.lastMessage; changed = true; }
      if (old.lastTime !== item.lastTime) { old.lastTime = item.lastTime; changed = true; }
      if (old.name !== item.name) { old.name = item.name; changed = true; }
      if (old.grade !== item.grade) { old.grade = item.grade; changed = true; }
      kept.push(old);
    }
    if (kept.length !== current.length) { changed = true; }
    if (changed) { this.friends = kept; }
  }

  /** 增量同步群聊：按房间名对比，只更新变化的项。 */
  private syncRooms(next: RoomItem[]): void {
    const current: RoomItem[] = this.rooms;
    let changed: boolean = false;
    const kept: RoomItem[] = [];
    for (const item of next) {
      const old: RoomItem | undefined = current.find((row: RoomItem) => row.name === item.name);
      if (old === undefined) {
        kept.push(item);
        changed = true;
        continue;
      }
      if (old.unread !== item.unread) { old.unread = item.unread; changed = true; }
      if (old.lastMessage !== item.lastMessage) { old.lastMessage = item.lastMessage; changed = true; }
      if (old.lastTime !== item.lastTime) { old.lastTime = item.lastTime; changed = true; }
      if (old.avatar !== item.avatar) { old.avatar = item.avatar; changed = true; }
      kept.push(old);
    }
    if (kept.length !== current.length) { changed = true; }
    if (changed) { this.rooms = kept; }
  }

  private async load(): Promise<void> {
    if (this.loading) { this.refreshing = false; return; }
    this.loading = true;
    try {
      this.syncFriends(SocialStore.friendsList());
      this.syncRooms(SocialStore.roomsList());
      await this.mergeServerRooms();
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      if (this.loggedIn) {
        await this.mergeMutual();
        await this.refreshPrivateUnread();
      }
    } catch (error) {
      Logger.warn('MESSAGE_CENTER', '加载消息页失败：' + String(error));
    } finally {
      // 关键：无论成功失败都要复位，否则下拉刷新会一直转/反复触发。
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 拉服务端聊天室列表（lts_list.php），与本地房间合并。 */
  private async mergeServerRooms(): Promise<void> {
    try {
      const rooms: LtsRoom[] = await AccountApi.roomList();
      if (rooms.length === 0) { return; }
      const merged: RoomItem[] = this.rooms.slice();
      for (const room of rooms) {
        if (merged.some((item: RoomItem) => item.name === room.title)) { continue; }
        const item: RoomItem = new RoomItem();
        item.name = room.title;
        item.avatar = room.avatar;
        item.lastMessage = room.latest;
        item.unread = room.count;
        merged.push(item);
      }
      this.syncRooms(merged);
      Logger.info('MESSAGE_CENTER', '服务端聊天室已合并，总数=' + String(this.rooms.length));
    } catch (error) {
      Logger.warn('MESSAGE_CENTER', '拉取聊天室列表失败：' + String(error));
    }
  }

  /** 私聊未读：拉每个好友的最后一条私聊，与上次记录对比得出新增条数。 */
  private async refreshPrivateUnread(): Promise<void> {
    try {
      const peers: FriendItem[] = this.friends.slice(0, 12);
      for (const friend of peers) {
        if (friend.account.length === 0) { continue; }
        const text: string = await AccountApi.friendChatList(this.session.user, friend.account);
        const entries: ChatEntry[] = AccountApi.parseChatLog(text);
        if (entries.length === 0) { continue; }
        const last: ChatEntry = entries[entries.length - 1];
        const known: number = this.peerCounts.get(friend.account) === undefined
          ? 0 : Number(this.peerCounts.get(friend.account));
        if (known > 0 && entries.length > known && last.user !== this.session.user) {
          friend.unread = entries.length - known;
        }
        if (last.user !== this.session.user) {
          friend.lastMessage = last.content;
          friend.lastTime = last.time;
        }
        this.peerCounts.set(friend.account, entries.length);
      }
      this.syncFriends(this.friends);
    } catch (error) {
      Logger.warn('MESSAGE_CENTER', '私聊未读刷新失败：' + String(error));
    }
  }

  private async mergeMutual(): Promise<void> {
    try {
      // 好友 = 我关注的人 ∪ 关注我的人（去重）。
      const followingList: FollowEntry[] = AccountApi.parseFollowList(
        await AccountApi.following(this.session.user, this.session.pass));
      const followerList: FollowEntry[] = AccountApi.parseFollowList(
        await AccountApi.followers(this.session.user, this.session.pass));
      const list: FollowEntry[] = followingList.slice();
      for (const entry of followerList) {
        if (!list.some((item: FollowEntry) => item.user === entry.user)) { list.push(entry); }
      }
      if (list.length === 0) { return; }
      const merged: FriendItem[] = this.friends.slice();
      for (const entry of list) {
        if (merged.some((item: FriendItem) => item.account === entry.user)) { continue; }
        const friend: FriendItem = new FriendItem();
        friend.account = entry.user;
        friend.name = entry.name.length > 0 ? entry.name : entry.user;
        friend.avatar = entry.avatar;
        friend.lastTime = entry.time;
        merged.push(friend);
      }
      this.syncFriends(merged);
    } catch (error) {
      Logger.warn('MESSAGE_CENTER', '互关好友合并失败：' + String(error));
    }
  }

  private columns(): number {
    if (this.viewportWidth >= 1000) { return 3; }
    if (this.viewportWidth >= 600) { return 2; }
    return 1;
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private gutter(): number {
    return this.tablet() ? 24 : 16;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private friendUnread(): number {
    let total: number = 0;
    for (const item of this.friends) { total += Math.max(0, item.unread); }
    return total;
  }

  private roomUnread(): number {
    let total: number = 0;
    for (const item of this.rooms) { total += Math.max(0, item.unread); }
    return total;
  }

  /** 群聊列表：官方群固定第一位，其余保持原顺序。 */
  private roomList(): RoomItem[] {
    const list: RoomItem[] = this.rooms.slice();
    list.sort((first: RoomItem, second: RoomItem) => {
      if (first.official === second.official) { return 0; }
      return first.official ? -1 : 1;
    });
    return list;
  }

  private initial(name: string): string {
    const value: string = (name || '').trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  private openPrivate(friend: FriendItem): void {
    try {
      void router.pushUrl(new ChatRouteOptions('', friend.account));
    } catch (error) {
      Logger.error('MESSAGE_CENTER', '打开私聊失败：' + String(error));
    }
  }

  private openRoom(room: RoomItem): void {
    try {
      void router.pushUrl(new ChatRouteOptions(room.name, ''));
    } catch (error) {
      Logger.error('MESSAGE_CENTER', '打开群聊失败：' + String(error));
    }
  }

  /** 打开群头像上传页（lts_portrait.php），等价 iApp 的 hw(url)。 */
  private async openRoomPortrait(roomName: string): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const url: string = AccountApi.chatRoomPortraitUrl(roomName);
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: url });
      Logger.info('MESSAGE_CENTER', '已打开群头像上传页：' + url);
    } catch (error) {
      Logger.warn('MESSAGE_CENTER', '打开群头像上传页失败：' + String(error));
    }
  }

  private openAllRooms(): void {
    void router.pushUrl({ url: 'pages/ChatRoomsPage' }).catch((error: Error) => {
      Logger.warn('MESSAGE_CENTER', '打开聊天室列表失败：' + String(error));
    });
  }

  private switchTab(index: number): void {
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.tab = index;
    });
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      Column({ space: '3vp' }) {
        Text('消息')
          .fontSize(Ui.fs(this.tablet() ? '26vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .width('100%')
        Text('好友 · 群聊')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

    }
      .width('100%')
      .padding({
        left: this.gutter() + 'vp',
        right: this.gutter() + 'vp',
        top: (this.safeTop() + 6) + 'vp'
      })
  }

  @Builder
  private segment(label: string, index: number, badge: number) {
    Row({ space: '5vp' }) {
      Text(label)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.tab === index ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
        .maxLines(1)
      if (badge > 0) {
        Text(badge > 99 ? '99+' : String(badge))
          .fontSize(Ui.fs('9.5vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .height('16vp')
          .constraintSize({ minWidth: '16vp' })
          .padding({ left: '4vp', right: '4vp' })
          .borderRadius('8vp')
          .backgroundColor(this.tab === index ? Ui.accent(this.darkTheme) : Ui.danger(this.darkTheme))
          .textAlign(TextAlign.Center)
      }
    }
      .height('34vp')
      .padding({ left: '14vp', right: '14vp' })
      .borderRadius('17vp')
      .backgroundColor(this.tab === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.tab === index ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
      .onClick(() => { this.switchTab(index); })
  }

  @Builder
  private segments() {
    Row({ space: '8vp' }) {
      this.segment('好友', 0, this.friendUnread())
      this.segment('群聊', 1, this.roomUnread())

    }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.gutter() + 'vp',
        right: this.gutter() + 'vp',
        top: '4vp',
        bottom: '8vp'
      })
  }

  @Builder
  private avatar(name: string, accent: boolean, size: number, url: string = '') {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(size + 'vp')
        .height(size + 'vp')
        .borderRadius((size / 2) + 'vp')
        .linearGradient({
          angle: 140,
          colors: accent
            ? [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
            : [[Ui.glassSheenTop(this.darkTheme), 0], [Ui.accentSoft(this.darkTheme), 1]]
        })
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      Text(accent ? '官' : this.initial(name))
        .fontSize(Ui.fs((size * 0.4) + 'vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(accent ? '#FFFFFF' : Ui.accentStrong(this.darkTheme))
      // 有头像地址就显示真实头像（账号头像 / 聊天室头像），失败保持文字。
      if (!accent && url.length > 0) {
        Image(url)
          .width(size + 'vp')
          .height(size + 'vp')
          .borderRadius((size / 2) + 'vp')
          .objectFit(ImageFit.Cover)
          .onError(() => { Logger.warn('MESSAGE_CENTER', '头像加载失败：' + url); })
      }
    }
      .width(size + 'vp')
      .height(size + 'vp')
  }

  @Builder
  private cardBody(name: string, badge: string, time: string, preview: string, unread: number, accent: boolean,
    avatarUrl: string = '') {
    Row({ space: '10vp' }) {
      this.avatar(name, accent, this.tablet() ? 52 : 46, avatarUrl)
      Column({ space: '5vp' }) {
        Row({ space: '5vp' }) {
          Text(name)
            .fontSize(Ui.fs(this.tablet() ? '16vp' : '14.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          if (badge.length > 0) {
            Text(badge)
              .fontSize(Ui.fs('9vp', this.fontScale))
              .fontColor(accent ? Ui.gold(this.darkTheme) : UserTitles.colorOf('', name, this.darkTheme))
              .height('16vp')
              .padding({ left: '5vp', right: '5vp' })
              .borderRadius('8vp')
              .backgroundColor(accent ? Ui.goldSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
              .maxLines(1)
          }
          Text(time)
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Row({ space: '6vp' }) {
          Text(preview)
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .padding({ left: '8vp', right: '8vp', top: '6vp', bottom: '6vp' })
            .borderRadius('8vp')
            .backgroundColor(this.darkTheme ? Ui.glassTintSoft(this.darkTheme) : '#FFF7F8FA')
            .border({ width: { left: 3 }, color: this.darkTheme ? Ui.cardBorder(this.darkTheme) : '#FFC8C8C8' })
          if (unread > 0) {
            Text(unread > 99 ? '99+' : String(unread))
              .fontSize(Ui.fs('9.5vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .height('18vp')
              .constraintSize({ minWidth: '18vp' })
              .padding({ left: '5vp', right: '5vp' })
              .borderRadius('9vp')
              .backgroundColor(Ui.danger(this.darkTheme))
              .textAlign(TextAlign.Center)
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .padding('10vp')
      .borderRadius('14vp')
      .backgroundColor(this.darkTheme ? Ui.card(this.darkTheme) : '#FFFFFF')
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private friendCard(friend: FriendItem) {
    Column() {
      this.cardBody(friend.name || friend.account, UserTitles.badgeOf(friend.grade, friend.account),
        friend.lastTime, friend.lastMessage || friend.signature || '还没有聊天记录', friend.unread, false,
        AccountApi.portraitUrl(friend.account))
    }
      .width('100%')
      .onClick(() => { this.openPrivate(friend); })
  }

  @Builder
  private roomCard(room: RoomItem) {
    Column() {
      this.cardBody(room.name, room.official ? '官方' : '', room.lastTime,
        room.lastMessage || room.intro || '暂无消息', room.unread, room.official,
        this.roomAvatarUrl(room))
    }
      .width('100%')
      .onClick(() => { this.openRoom(room); })
      .gesture(LongPressGesture({ repeat: false }).onAction(() => {
        this.openRoomPortrait(room.name);
      }))
  }

  @Builder
  private emptyBlock(title: string, hint: string) {
    Column({ space: '8vp' }) {
      SymbolGlyph(this.tab === 0 ? SymbolIcons.mine(false) : SymbolIcons.doc())
        .fontSize(Ui.fs('30vp', this.fontScale))
        .fontColor([Ui.inkFaint(this.darkTheme)])
      Text(title)
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
      Text(hint)
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .textAlign(TextAlign.Center)
    }
      .width('100%')
      .padding({ top: '40vp', bottom: '40vp' })
      .justifyContent(FlexAlign.Center)
  }

  @Builder
  private friendColumn() {
    Column({ space: '8vp' }) {
      if (this.friends.length === 0) {
        this.emptyBlock('还没有好友', this.loggedIn ? '互相关注后会自动出现在这里' : '登录后可同步互关好友')
      } else {
        ForEach(this.friends, (friend: FriendItem) => {
          this.friendCard(friend)
        }, (friend: FriendItem) => 'friend-' + friend.account)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private roomColumn() {
    Column({ space: '8vp' }) {
      if (this.roomList().length === 0) {
        this.emptyBlock('暂无群聊', '在聊天室里加入或创建群聊')
      } else {
        ForEach(this.roomList(), (room: RoomItem) => {
          this.roomCard(room)
        }, (room: RoomItem) => 'room-' + room.name)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private content() {
    if (this.columns() >= 2) {
      Row({ space: '12vp' }) {
        Column() {
          this.friendColumn()
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Column() {
          this.roomColumn()
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .alignItems(VerticalAlign.Top)
    } else if (this.tab === 0) {
      this.friendColumn()
    } else {
      this.roomColumn()
    }
  }

  /** 聊天室头像：相对路径拼服务端域名；官方群用应用图标。 */
  private roomAvatarUrl(room: RoomItem): string {
    if (room.official) { return ''; }
    const path: string = (room.avatar || '').trim();
    if (path.indexOf('http') === 0) { return path; }
    if (path.length > 0 && path.indexOf('.') > 0) {
      const domain: string = AppConfig.getInstance().backendDomain;
      return path.indexOf('/') === 0 ? domain + path : domain + '/' + path;
    }
    // 列表只给了房间名：用 lts_portrait.php 按名称取头像。
    return AccountApi.chatRoomPortraitUrl(room.name);
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        this.header()
        this.segments()
        Refresh({ refreshing: this.refreshing }) {
          Scroll(this.navScroller) {
            Column() {
              this.content()
            }
            .width('100%')
            .constraintSize({ maxWidth: '1180vp' })
              .padding({
                left: this.gutter() + 'vp',
                right: this.gutter() + 'vp',
                bottom: '24vp'
              })
          }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .onScrollStart(() => { NavigationScroll.begin('message', 'content', this.navScroller); })
            .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
              NavigationScroll.report('message', 'content', this.navScroller, scrollState);
            })
            .onScrollStop(() => { NavigationScroll.end('message', 'content', this.navScroller); })
        }
          .onRefreshing(() => { this.refreshing = true; void this.load(); })
          .layoutWeight(1)
      }
        .width('100%')
        .height('100%')
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const width: number = Number(newValue.width);
          if (Number.isFinite(width) && width > 0) { this.viewportWidth = width; }
        } catch (error) {
          Logger.warn('MESSAGE_CENTER', '更新宽度失败：' + String(error));
        }
      })


  }
}

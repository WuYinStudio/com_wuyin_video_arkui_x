import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, ForumPost } from '../common/CommunityApi';
import { ChatService } from '../common/ChatService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { FriendItem, RoomItem, SocialStore, SystemItem } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, GlassSearchBar, PrimaryButton, SectionHeader } from '../common/UiWidgets';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { SymbolIcons } from '../common/SymbolIcons';
import { replaceRoute } from '../common/compat/RouterCompat';

interface MessageRouteParams {
  room?: string;
}

class ChatParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class ChatRoute {
  url: string = 'pages/ChatRoomPage';
  params: ChatParams;

  constructor(room: string, title: string) {
    this.params = new ChatParams();
    this.params.room = room;
    this.params.title = title;
  }
}

class DetailParams {
  postId: string = '';

  constructor(postId: string) {
    this.postId = postId;
  }
}

class DetailRoute {
  url: string = 'pages/ForumDetailPage';
  params: DetailParams;

  constructor(postId: string) {
    this.params = new DetailParams(postId);
  }
}

class MessageEntry {
  key: string = '';
  title: string = '';
  subtitle: string = '';
  glyph: string = '';
  unread: number = 0;

  constructor(key: string, title: string, subtitle: string, glyph: string, unread: number) {
    this.key = key;
    this.title = title;
    this.subtitle = subtitle;
    this.glyph = glyph;
    this.unread = unread;
  }
}

/**
 * 消息中心 · 7.12
 * 顶栏搜索/榜单、在线卡、聊天室/系统消息/官方群聊/好友消息入口与未读红点。
 */
@Entry
@Component
struct MessagePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @StorageLink('socialVersion') @Watch('reloadLocal') private socialVersion: number = 0;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private loggedIn: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private onlineCount: number = 0;
  @State private systems: SystemItem[] = [];
  @State private friendUnread: number = 0;
  @State private roomUnread: number = 0;
  @State private officialUnread: number = 0;
  @State private systemUnread: number = 0;
  @State private viewportWidth: number = 360;
  @State private showSearch: boolean = false;
  @State private searchText: string = '';
  @State private showRank: boolean = false;
  @State private rankLoading: boolean = false;
  @State private ranks: ForumPost[] = [];
  @State private detailVisible: boolean = false;
  @State private detailTitle: string = '';
  @State private detailContent: string = '';
  @State private detailTime: string = '';
  @State private toastText: string = '';
  private onlineTimer: number = -1;
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    try {
      const params = router.getParams() as MessageRouteParams | undefined;
      if (params && typeof params.room === 'string' && params.room.trim().length > 0) {
        replaceRoute(new ChatRoute(params.room.trim(), params.room.trim())).catch((error: Error) => {
          Logger.error('MESSAGE_HUB', '打开反馈聊天室失败：' + String(error));
        });
        return;
      }
    } catch (error) {
      Logger.warn('MESSAGE_HUB', '读取消息页参数失败：' + String(error));
    }
    void this.prepare();
  }

  onPageShow(): void {
    if (this.alive && this.loggedIn) {
      this.reloadLocal();
      void this.refreshUnread();
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.onlineTimer >= 0) {
      clearInterval(this.onlineTimer);
      this.onlineTimer = -1;
    }
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      this.reloadLocal();
      if (this.loggedIn) {
        await this.refreshRemoteSystems();
        await this.refreshUnread();
      }
      await this.loadOnline();
      this.startOnlineTimer();
    } catch (error) {
      Logger.error('MESSAGE_HUB', '初始化消息中心失败：' + String(error));
    }
  }

  private reloadLocal(): void {
    this.systems = SocialStore.systemsList();
    this.friendUnread = SocialStore.totalFriendUnread();
    this.roomUnread = SocialStore.totalRoomUnread();
    this.systemUnread = SocialStore.systemUnread();
    const official: RoomItem | undefined = SocialStore.room(SocialStore.OFFICIAL_ROOM);
    this.officialUnread = official !== undefined ? official.unread : 0;
  }

  private async refreshRemoteSystems(): Promise<void> {
    try {
      const notice: string = await CommunityApi.remoteNotice();
      if (notice.length > 0) {
        const item: SystemItem = new SystemItem();
        item.id = 'remote-notice';
        item.title = '系统公告';
        item.content = notice;
        item.time = this.nowText();
        SocialStore.upsertSystem(item);
      }
      const update = await CommunityApi.remoteUpdate();
      if (update.content.length > 0) {
        const item: SystemItem = new SystemItem();
        item.id = 'remote-update';
        item.title = '版本更新 · ' + update.version;
        item.content = update.content;
        item.time = this.nowText();
        SocialStore.upsertSystem(item);
      }
      this.reloadLocal();
    } catch (error) {
      Logger.warn('MESSAGE_HUB', '刷新系统消息失败：' + String(error));
    }
  }

  private async refreshUnread(): Promise<void> {
    try {
      const rooms: RoomItem[] = SocialStore.roomsList();
      for (const room of rooms) {
        await ChatService.refreshRoomSummary(this.session, room);
      }
      const friends: FriendItem[] = SocialStore.friendsList();
      for (const friend of friends) {
        await ChatService.refreshFriendSummary(this.session, friend);
      }
      this.reloadLocal();
    } catch (error) {
      Logger.warn('MESSAGE_HUB', '刷新未读数失败：' + String(error));
    }
  }

  private async loadOnline(): Promise<void> {
    try {
      this.onlineCount = await ChatService.onlineCount();
    } catch (error) {
      Logger.warn('MESSAGE_HUB', '在线人数读取失败：' + String(error));
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

  private nowText(): string {
    const date: Date = new Date();
    const month: string = date.getMonth() + 1 < 10 ? '0' + String(date.getMonth() + 1) : String(date.getMonth() + 1);
    const day: string = date.getDate() < 10 ? '0' + String(date.getDate()) : String(date.getDate());
    const hour: string = date.getHours() < 10 ? '0' + String(date.getHours()) : String(date.getHours());
    const minute: string = date.getMinutes() < 10 ? '0' + String(date.getMinutes()) : String(date.getMinutes());
    return month + '-' + day + ' ' + hour + ':' + minute;
  }

  private entries(): MessageEntry[] {
    const list: MessageEntry[] = [];
    list.push(new MessageEntry('chatrooms', '聊天室', '官方群聊与自建房间', '💬', this.roomUnread));
    list.push(new MessageEntry('system', '系统消息', '公告与版本通知', '🔔', this.systemUnread));
    list.push(new MessageEntry('official', '官方群聊', '在线 ' + String(this.onlineCount) + ' 人', '🏠', this.officialUnread));
    list.push(new MessageEntry('friends', '好友消息', '私聊与好友申请', '👥', this.friendUnread));
    return list;
  }

  private openEntry(key: string): void {
    try {
      if (key === 'chatrooms') {
        router.pushUrl({ url: 'pages/ChatRoomsPage' }).catch((error: Error) => {
          Logger.error('MESSAGE_HUB', '打开聊天室列表失败：' + String(error));
        });
      } else if (key === 'system') {
        if (this.systems.length > 0) {
          this.openSystem(this.systems[0]);
        } else {
          this.showToast('暂无系统消息');
        }
      } else if (key === 'official') {
        router.pushUrl(new ChatRoute(SocialStore.OFFICIAL_ROOM, '官方群聊')).catch((error: Error) => {
          Logger.error('MESSAGE_HUB', '打开官方群聊失败：' + String(error));
        });
      } else if (key === 'friends') {
        router.pushUrl({ url: 'pages/FriendsPage' }).catch((error: Error) => {
          Logger.error('MESSAGE_HUB', '打开好友页失败：' + String(error));
        });
      }
    } catch (error) {
      Logger.error('MESSAGE_HUB', '消息入口跳转失败：' + String(error));
    }
  }

  private openSystem(item: SystemItem): void {
    this.detailTitle = item.title;
    this.detailContent = item.content;
    this.detailTime = item.time;
    this.detailVisible = true;
    SocialStore.markSystemRead(item.id);
    this.reloadLocal();
  }

  private async openRank(): Promise<void> {
    this.showRank = true;
    if (this.ranks.length > 0 || this.rankLoading) {
      return;
    }
    this.rankLoading = true;
    try {
      const result = await CommunityApi.forumPosts('', 1, '');
      const sorted: ForumPost[] = result.posts.slice();
      sorted.sort((a: ForumPost, b: ForumPost) => (b.views + b.likes * 3) - (a.views + a.likes * 3));
      this.ranks = sorted.slice(0, 10);
      Logger.info('MESSAGE_HUB', '社区榜单加载完成：' + String(this.ranks.length));
    } catch (error) {
      Logger.warn('MESSAGE_HUB', '榜单加载失败：' + String(error));
      this.showToast('榜单加载失败');
    } finally {
      this.rankLoading = false;
    }
  }

  private openRankPost(post: ForumPost): void {
    this.showRank = false;
    router.pushUrl(new DetailRoute(post.id)).catch((error: Error) => {
      Logger.error('MESSAGE_HUB', '打开榜单帖子失败：' + String(error));
    });
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('MESSAGE_HUB', '同步沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 860);
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

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  private filteredSystems(): SystemItem[] {
    const keyword: string = this.searchText.trim();
    if (!keyword) {
      return this.systems;
    }
    return this.systems.filter((item: SystemItem) =>
      item.title.indexOf(keyword) >= 0 || item.content.indexOf(keyword) >= 0);
  }

  @Builder
  private header() {
    Row({ space: '8vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Text('消息')
        .fontSize(Ui.fs(this.tablet() ? '29vp' : '25vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .layoutWeight(1)
      GhostButton({ label: '搜索', compact: true, onTap: (): void => { this.showSearch = true; } })
      GhostButton({ label: '榜单', compact: true, onTap: (): void => { void this.openRank(); } })
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '16vp',
        right: this.tablet() ? '24vp' : '16vp',
        top: (this.safeTop() + 8) + 'vp',
        bottom: '8vp'
      })
  }

  @Builder
  private onlineCard() {
    Row({ space: '12vp' }) {
      Column({ space: '4vp' }) {
        Text('当前在线 ' + String(this.onlineCount) + ' 人')
          .fontSize(Ui.fs(this.tablet() ? '18vp' : '16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('和好友一起聊天、追剧、逛论坛')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Row({ space: '2vp' }) {
        ForEach(this.avatarSeeds(), (seed: string, index: number) => {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('30vp').height('30vp').borderRadius('15vp')
              .backgroundColor(Ui.accentSoft(this.darkTheme))
              .border({ width: 2, color: this.pageBackground() })
            Text(this.initial(seed))
              .fontSize(Ui.fs('11vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.accentStrong(this.darkTheme))
          }
            .width('30vp').height('30vp')
        }, (seed: string, index: number) => 'online-' + seed + '-' + String(index))
      }
      Row() {
        Text('立即查看')
          .fontSize(Ui.fs('11.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
      }
        .height('30vp').padding({ left: '12vp', right: '12vp' }).borderRadius('15vp')
        .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
        .onClick(() => { this.openEntry('chatrooms'); })
    }
      .width('100%')
      .padding('16vp')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.accentSoft(this.darkTheme), 0], [Ui.glassTintStrong(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
  }

  private avatarSeeds(): string[] {
    const result: string[] = [];
    const friends: FriendItem[] = SocialStore.friendsList();
    for (const friend of friends) {
      if (result.length >= 3) {
        break;
      }
      result.push(friend.name || friend.account);
    }
    while (result.length < 3) {
      result.push(result.length === 0 ? '聊' : (result.length === 1 ? '友' : '官'));
    }
    return result;
  }

  @Builder
  private entryGrid() {
    Grid() {
      ForEach(this.entries(), (item: MessageEntry) => {
        GridItem() {
          Column({ space: '8vp' }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Column()
                .width('44vp').height('44vp').borderRadius('14vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
              Text(item.glyph)
                .fontSize(Ui.fs('20vp', this.fontScale))
                .width('44vp').height('44vp').textAlign(TextAlign.Center)
              if (item.unread > 0) {
                Text(item.unread > 99 ? '99+' : String(item.unread))
                  .fontSize(Ui.fs('8.5vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                  .height('16vp').constraintSize({ minWidth: '16vp' })
                  .padding({ left: '3vp', right: '3vp' }).borderRadius('8vp')
                  .backgroundColor(Ui.danger(this.darkTheme)).textAlign(TextAlign.Center)
              }
            }
              .width('44vp').height('44vp')
            Text(item.title)
              .fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
            Text(item.subtitle)
              .fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).maxLines(1)
          }
            .width('100%').height('100%')
            .justifyContent(FlexAlign.Center)
            .padding('8vp')
            .borderRadius(Ui.R_MD)
            .backgroundColor(Ui.card(this.darkTheme))
            .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
            .onClick(() => { this.openEntry(item.key); })
        }
      }, (item: MessageEntry) => 'entry-' + item.key)
    }
      .width('100%')
      .height('190vp')
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap('8vp')
      .rowsGap('8vp')
  }

  @Builder
  private systemList() {
    Column({ space: '8vp' }) {
      SectionHeader({ title: '系统消息', subtitle: this.systemUnread > 0 ? String(this.systemUnread) + ' 条未读' : '全部已读',
        viewportWidth: this.viewportWidth })
      if (this.systems.length === 0) {
        EmptyState({ title: this.loggedIn ? '暂无消息' : '登录后可查看', hint: '系统公告与版本通知会显示在这里', icon: SymbolIcons.bell() })
      } else {
        ForEach(this.filteredSystems(), (item: SystemItem) => {
          Row({ space: '10vp' }) {
            Column({ space: '3vp' }) {
              Row({ space: '6vp' }) {
                Text(item.title)
                  .fontSize(Ui.fs('13.5vp', this.fontScale)).fontWeight(item.read ? FontWeight.Normal : FontWeight.Bold)
                  .fontColor(Ui.ink(this.darkTheme)).maxLines(1).layoutWeight(1)
                if (!item.read) {
                  Column().width('7vp').height('7vp').borderRadius('3.5vp')
                    .backgroundColor(Ui.danger(this.darkTheme))
                }
              }
                .width('100%')
              Text(item.content)
                .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(item.time)
                .fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
            }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            Text('›').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          }
            .width('100%')
            .padding('12vp')
            .borderRadius(Ui.R_MD)
            .backgroundColor(Ui.card(this.darkTheme))
            .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
            .onClick(() => { this.openSystem(item); })
        }, (item: SystemItem) => 'system-' + item.id)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private searchOverlay() {
    if (this.showSearch) {
      Stack({ alignContent: Alignment.Top }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showSearch = false; });
        Column({ space: '10vp' }) {
          Row({ space: '8vp' }) {
            Text('搜索消息与通知')
              .fontSize(Ui.fs('17vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.darkTheme)).layoutWeight(1)
            GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.showSearch = false; } })
          }
            .width('100%')
          GlassSearchBar({
            query: this.searchText,
            placeholder: '搜索聊天室、系统消息、好友',
            showButton: false,
            compact: true,
            onQueryChange: (text: string): void => { this.searchText = text; },
            onSubmit: (): void => {}
          })
          ForEach(this.filteredSystems(), (item: SystemItem) => {
            Text('🔔 ' + item.title)
              .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
              .width('100%').padding('10vp').borderRadius('10vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .onClick(() => {
                this.showSearch = false;
                this.openSystem(item);
              })
          }, (item: SystemItem) => 'search-' + item.id)
          ForEach(this.entries(), (item: MessageEntry) => {
            if (this.searchText.length === 0 || item.title.indexOf(this.searchText) >= 0) {
              Text(item.glyph + ' ' + item.title)
                .fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
                .width('100%').padding('10vp').borderRadius('10vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .onClick(() => {
                  this.showSearch = false;
                  this.openEntry(item.key);
                })
            }
          }, (item: MessageEntry) => 'search-entry-' + item.key)
        }
          .width(this.tablet() ? '560vp' : '92%')
          .padding('18vp')
          .margin({ top: '80vp' })
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%').height('100%').zIndex(12)
    }
  }

  @Builder
  private rankOverlay() {
    if (this.showRank) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showRank = false; });
        Column({ space: '10vp' }) {
          Row({ space: '8vp' }) {
            Text('社区榜单')
              .fontSize(Ui.fs('19vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.darkTheme)).layoutWeight(1)
            GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.showRank = false; } })
          }
            .width('100%')
          if (this.rankLoading) {
            LoadingProgress().width('28vp').height('28vp').color(Ui.accent(this.darkTheme))
          } else if (this.ranks.length === 0) {
            EmptyState({ title: '暂无榜单', hint: '论坛还需要更多帖子', icon: SymbolIcons.trophy() })
          } else {
            List({ space: '6vp' }) {
              ForEach(this.ranks, (post: ForumPost, index: number) => {
                ListItem() {
                  Row({ space: '8vp' }) {
                    Text(String(index + 1))
                      .fontSize(Ui.fs('13vp', this.fontScale)).fontWeight(FontWeight.Bold)
                      .fontColor(index < 3 ? Ui.gold(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                      .width('22vp')
                    Column({ space: '2vp' }) {
                      Text(post.title).fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).maxLines(1)
                      Text('浏览 ' + String(post.views) + ' · 赞 ' + String(post.likes))
                        .fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
                    }
                      .layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }
                    .width('100%').padding('9vp').borderRadius('10vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .onClick(() => { this.openRankPost(post); })
                }
              }, (post: ForumPost) => 'rank-' + post.id)
            }
              .width('100%').height('340vp')
          }
        }
          .width(this.tablet() ? '560vp' : '90%')
          .padding('18vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%').height('100%').zIndex(13)
    }
  }

  @Builder
  private detailOverlay() {
    if (this.detailVisible) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.detailVisible = false; });
        Column({ space: '10vp' }) {
          Text(this.detailTitle)
            .fontSize(Ui.fs('19vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.darkTheme)).width('100%')
          Text(this.detailTime)
            .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%')
          Scroll() {
            Text(this.detailContent)
              .fontSize(Ui.fs('14vp', this.fontScale)).lineHeight('23vp').fontColor(Ui.inkSoft(this.darkTheme)).width('100%')
          }
            .width('100%').constraintSize({ maxHeight: 360 }).scrollBar(BarState.Auto)
          Row() {
            GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.detailVisible = false; } })
          }
            .width('100%').justifyContent(FlexAlign.End)
        }
          .width(this.tablet() ? '540vp' : '88%')
          .padding('20vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%').height('100%').zIndex(14)
    }
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.46 : 0.56 })
      Column() {
        this.header()
        Scroll() {
          Column({ space: '12vp' }) {
            if (!this.loggedIn) {
              EmptyState({ title: '登录后可查看', hint: '登录后查看聊天室、系统消息与好友消息', icon: SymbolIcons.doc() })
              PrimaryButton({ label: '去登录', onTap: (): void => {
                router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
                  Logger.error('MESSAGE_HUB', '打开登录页失败：' + String(error));
                });
              } })
            } else {
              this.onlineCard()
              this.entryGrid()
              this.systemList()
            }
          }
            .width('100%')
            .constraintSize({ maxWidth: this.contentMaxWidth() })
            .padding({
              left: this.tablet() ? '24vp' : '16vp',
              right: this.tablet() ? '24vp' : '16vp',
              bottom: (this.safeBottom() + 24) + 'vp'
            })
        }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
      }
        .width('100%').height('100%')
      if (this.toastText.length > 0) {
        Text(this.toastText)
          .fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
          .padding({ left: '16vp', right: '16vp', top: '9vp', bottom: '9vp' })
          .borderRadius('20vp').backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .align(Alignment.Bottom).margin({ bottom: (this.safeBottom() + 30) + 'vp' })
      }
      this.searchOverlay()
      this.rankOverlay()
      this.detailOverlay()
      // 实时消息提醒：消息中心顶部弹窗，可直接回复新消息。
      ChatNoticeBanner()
    }
      .width('100%').height('100%')
      .backgroundColor(this.pageBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
        } catch (error) {
          Logger.warn('MESSAGE_HUB', '更新消息页宽度失败：' + String(error));
        }
      })
  }
}

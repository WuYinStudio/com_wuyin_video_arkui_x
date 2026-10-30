import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ChatMessage, CommunityApi, CommunitySession, CommunityUser } from '../common/CommunityApi';
import { ChatService } from '../common/ChatService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { ChatCard, MediaCodec } from '../common/MediaCodec';
import { FriendItem, FriendRequestItem, SocialStore } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, GlassChip, PrimaryButton } from '../common/UiWidgets';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { SymbolIcons } from '../common/SymbolIcons';

class FriendChatParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class FriendChatRoute {
  url: string = 'pages/ChatRoomPage';
  params: FriendChatParams;

  constructor(peer: string, title: string) {
    this.params = new FriendChatParams();
    this.params.peer = peer;
    this.params.title = title;
  }
}

class ProfileParams {
  account: string = '';

  constructor(account: string) {
    this.account = account;
  }
}

class ProfileRoute {
  url: string = 'pages/UserProfilePage';
  params: ProfileParams;

  constructor(account: string) {
    this.params = new ProfileParams(account);
  }
}

/**
 * 好友列表 / 好友申请 / 黑名单 · 7.11
 */
@Entry
@Component
struct FriendsPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('socialVersion') @Watch('reload') private socialVersion: number = 0;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private friends: FriendItem[] = [];
  @State private requests: FriendRequestItem[] = [];
  @State private blocks: string[] = [];
  @State private activeTab: number = 0;
  @State private session: CommunitySession = new CommunitySession();
  @State private loggedIn: boolean = false;
  @State private myName: string = '';
  @State private loading: boolean = false;
  @State private showAdd: boolean = false;
  @State private accountInput: string = '';
  @State private foundUser: CommunityUser = new CommunityUser();
  @State private foundVisible: boolean = false;
  @State private searching: boolean = false;
  @State private sending: boolean = false;
  @State private toastText: string = '';
  @State private viewportWidth: number = 360;
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    void this.prepare();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  onPageShow(): void {
    if (this.alive && this.loggedIn) {
      void this.refresh();
    }
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      this.reload();
      if (this.loggedIn) {
        const profile: CommunityUser = await CommunityApi.fetchProfile(this.session);
        this.myName = profile.name || this.session.user;
        await this.refresh();
      }
    } catch (error) {
      Logger.error('FRIENDS_PAGE', '初始化好友页失败：' + String(error));
    }
  }

  private reload(): void {
    this.friends = SocialStore.friendsList();
    this.requests = SocialStore.requestsList();
    this.blocks = SocialStore.blocksList();
  }

  private async refresh(): Promise<void> {
    if (this.loading || !this.loggedIn) {
      return;
    }
    this.loading = true;
    try {
      await this.pollEvents();
      const snapshot: FriendItem[] = SocialStore.friendsList();
      for (const friend of snapshot) {
        await ChatService.refreshFriendSummary(this.session, friend);
      }
      this.reload();
      Logger.info('FRIENDS_PAGE', '好友列表刷新完成，好友=' + String(this.friends.length));
    } catch (error) {
      Logger.warn('FRIENDS_PAGE', '刷新好友失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private async pollEvents(): Promise<void> {
    try {
      const events: ChatMessage[] = await ChatService.requestEvents(this.session);
      for (const message of events) {
        if (message.user === this.session.user) {
          continue;
        }
        const card: ChatCard = MediaCodec.decode(message.content);
        if (card.kind === 'friend_request') {
          const item: FriendRequestItem = new FriendRequestItem();
          item.from = message.user;
          item.name = message.name || card.fromName || message.user;
          item.time = message.time;
          item.kind = 'request';
          if (!SocialStore.friend(message.user)) {
            SocialStore.addRequest(item);
          }
        } else if (card.kind === 'friend_accept') {
          const existing: FriendItem | undefined = SocialStore.friend(message.user);
          if (!existing) {
            const friend: FriendItem = new FriendItem();
            friend.account = message.user;
            friend.name = message.name || message.user;
            friend.avatar = CommunityApi.avatarUrl(message.user);
            SocialStore.upsertFriend(friend);
          }
          SocialStore.removeRequest(message.user, 'request');
          this.showToast(message.name + ' 已通过你的好友申请');
        } else if (card.kind === 'friend_reject') {
          SocialStore.removeRequest(message.user, 'request');
          this.showToast(message.name + ' 拒绝了你的好友申请');
        }
      }
    } catch (error) {
      Logger.warn('FRIENDS_PAGE', '轮询好友申请失败：' + String(error));
    }
  }

  private async searchUser(): Promise<void> {
    const account: string = this.accountInput.trim();
    if (!account) {
      this.showToast('请输入对方账号');
      return;
    }
    if (account === this.session.user) {
      this.showToast('不能添加自己为好友');
      return;
    }
    this.searching = true;
    try {
      const user: CommunityUser | undefined = await CommunityApi.queryUser(account);
      if (user === undefined) {
        this.foundVisible = false;
        this.showToast('未找到该账号');
      } else {
        this.foundUser = user;
        this.foundVisible = true;
      }
      Logger.info('FRIENDS_PAGE', '账号精确查询完成：' + account);
    } catch (error) {
      this.showToast('查询失败：' + String(error));
      Logger.error('FRIENDS_PAGE', '查询用户失败：' + String(error));
    } finally {
      this.searching = false;
    }
  }

  private async sendRequest(): Promise<void> {
    if (!this.foundVisible || this.sending) {
      return;
    }
    const target: string = this.foundUser.userId;
    this.sending = true;
    try {
      await ChatService.sendFriendRequest(this.session, target, this.myName || this.session.user);
      this.showToast('好友申请已发送');
      this.showAdd = false;
      this.accountInput = '';
      this.foundVisible = false;
      Logger.info('FRIENDS_PAGE', '好友申请发送：' + target);
    } catch (error) {
      this.showToast('发送失败：' + String(error));
      Logger.error('FRIENDS_PAGE', '发送好友申请失败：' + String(error));
    } finally {
      this.sending = false;
    }
  }

  private accept(request: FriendRequestItem): void {
    const friend: FriendItem = new FriendItem();
    friend.account = request.from;
    friend.name = request.name || request.from;
    friend.avatar = CommunityApi.avatarUrl(request.from);
    SocialStore.upsertFriend(friend);
    SocialStore.removeRequest(request.from, 'request');
    void ChatService.sendFriendResponse(this.session, request.from, true, this.myName || this.session.user)
      .catch((error: Error) => {
        Logger.error('FRIENDS_PAGE', '发送通过响应失败：' + String(error));
      });
    this.reload();
    this.showToast('已添加 ' + friend.name + ' 为好友');
  }

  private reject(request: FriendRequestItem): void {
    SocialStore.removeRequest(request.from, 'request');
    void ChatService.sendFriendResponse(this.session, request.from, false, this.myName || this.session.user)
      .catch((error: Error) => {
        Logger.error('FRIENDS_PAGE', '发送拒绝响应失败：' + String(error));
      });
    this.reload();
    this.showToast('已拒绝好友申请');
  }

  private openChat(friend: FriendItem): void {
    try {
      router.pushUrl(new FriendChatRoute(friend.account, friend.name)).catch((error: Error) => {
        Logger.error('FRIENDS_PAGE', '打开私聊失败：' + String(error));
      });
    } catch (error) {
      Logger.error('FRIENDS_PAGE', '私聊路由异常：' + String(error));
    }
  }

  private openProfile(account: string): void {
    try {
      router.pushUrl(new ProfileRoute(account)).catch((error: Error) => {
        Logger.error('FRIENDS_PAGE', '打开资料页失败：' + String(error));
      });
    } catch (error) {
      Logger.error('FRIENDS_PAGE', '资料页路由异常：' + String(error));
    }
  }

  private blockFriend(friend: FriendItem): void {
    AlertDialog.show({
      title: '拉黑好友',
      message: '拉黑后将不再接收 ' + friend.name + ' 的消息',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '拉黑',
        action: (): void => {
          SocialStore.block(friend.account);
          SocialStore.removeFriend(friend.account);
          this.reload();
          this.showToast('已加入黑名单');
        }
      }
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
      Logger.error('FRIENDS_PAGE', '同步沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 820);
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeBottom(): number {
    return 16;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Column({ space: '2vp' }) {
        Text('好友')
          .fontSize(Ui.fs(this.tablet() ? '26vp' : '23vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('私聊、好友申请与黑名单')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '添加好友', compact: true, onTap: (): void => { this.showAdd = true; } })
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
  private tabs() {
    Row({ space: '8vp' }) {
      GlassChip({ label: '好友 ' + String(this.friends.length), selected: this.activeTab === 0, compact: true,
        onTap: (): void => { this.activeTab = 0; } })
      GlassChip({ label: '申请 ' + String(this.requests.length), selected: this.activeTab === 1, compact: true,
        onTap: (): void => { this.activeTab = 1; } })
      GlassChip({ label: '黑名单 ' + String(this.blocks.length), selected: this.activeTab === 2, compact: true,
        onTap: (): void => { this.activeTab = 2; } })
    }
      .width('100%')
      .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp' })
  }

  @Builder
  private friendRow(friend: FriendItem) {
    Row({ space: '12vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('46vp').height('46vp').borderRadius('23vp')
          .backgroundColor(Ui.accentSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
        Text(this.initial(friend.name))
          .fontSize(Ui.fs('17vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.accentStrong(this.darkTheme))
      }
        .width('46vp').height('46vp')
      Column({ space: '3vp' }) {
        Row({ space: '6vp' }) {
          Text(friend.name || friend.account)
            .fontSize(Ui.fs(this.tablet() ? '15.5vp' : '14vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          Text(friend.lastTime)
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .width('100%')
        Row({ space: '6vp' }) {
          Text(friend.lastMessage || '暂无消息')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (friend.unread > 0) {
            Text(friend.unread > 99 ? '99+' : String(friend.unread))
              .fontSize(Ui.fs('9vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .height('18vp').constraintSize({ minWidth: '18vp' })
              .padding({ left: '4vp', right: '4vp' }).borderRadius('9vp')
              .backgroundColor(Ui.danger(this.darkTheme)).textAlign(TextAlign.Center)
          }
        }
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .padding('12vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
      .onClick(() => { this.openChat(friend); })
      .gesture(LongPressGesture({ repeat: false }).onAction(() => {
        AlertDialog.show({
          title: friend.name,
          message: '选择操作',
          autoCancel: true,
          primaryButton: { value: '查看资料', action: (): void => { this.openProfile(friend.account); } },
          secondaryButton: { value: '拉黑', action: (): void => { this.blockFriend(friend); } }
        });
      }))
  }

  @Builder
  private requestRow(request: FriendRequestItem) {
    Row({ space: '10vp' }) {
      Column({ space: '3vp' }) {
        Text(request.name || request.from)
          .fontSize(Ui.fs('14.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.ink(this.darkTheme))
        Text('账号 ' + request.from + ' · ' + request.time)
          .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '拒绝', compact: true, onTap: (): void => { this.reject(request); } })
      PrimaryButton({ label: '通过', compact: true, onTap: (): void => { this.accept(request); } })
    }
      .width('100%')
      .padding('12vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private blockRow(account: string) {
    Row({ space: '10vp' }) {
      Text(account)
        .fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).layoutWeight(1)
      GhostButton({ label: '移出黑名单', compact: true, onTap: (): void => {
        SocialStore.unblock(account);
        this.reload();
        this.showToast('已移出黑名单');
      } })
    }
      .width('100%')
      .padding('12vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private addOverlay() {
    if (this.showAdd) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showAdd = false; });
        Column({ space: '10vp' }) {
          Text('添加好友')
            .fontSize(Ui.fs('20vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.darkTheme))
          Text('输入对方账号，精确匹配后发送申请')
            .fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          Row({ space: '8vp' }) {
            TextInput({ text: this.accountInput, placeholder: '对方账号' })
              .layoutWeight(1).height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
              .placeholderColor(Ui.inkFaint(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp')
              .padding({ left: '14vp', right: '14vp' })
              .onChange((value: string) => { this.accountInput = value; })
            PrimaryButton({ label: this.searching ? '查询中' : '查询', compact: true, onTap: (): void => { void this.searchUser(); } })
          }
            .width('100%')
          if (this.foundVisible) {
            Row({ space: '10vp' }) {
              Column({ space: '2vp' }) {
                Text(this.foundUser.name || this.foundUser.userId)
                  .fontSize(Ui.fs('15vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.ink(this.darkTheme))
                Text('ID ' + this.foundUser.userId + ' · ' + this.foundUser.grade)
                  .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
              }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              PrimaryButton({ label: this.sending ? '发送中' : '加好友', compact: true, onTap: (): void => { void this.sendRequest(); } })
            }
              .width('100%')
              .padding('10vp')
              .borderRadius('12vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          }
          Row() {
            GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.showAdd = false; } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
        }
          .width(this.tablet() ? '460vp' : '88%')
          .padding('20vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%')
        .height('100%')
        .zIndex(10)
    }
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.48 : 0.58 })
      Column() {
        this.header()
        this.tabs()
        if (!this.loggedIn) {
          Column({ space: '12vp' }) {
            EmptyState({ title: '登录后可查看好友', hint: '登录凭证缺失', icon: SymbolIcons.mine(false) })
            PrimaryButton({ label: '去登录', onTap: (): void => {
              router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
                Logger.error('FRIENDS_PAGE', '打开登录页失败：' + String(error));
              });
            } })
          }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: '8vp' }) {
              if (this.activeTab === 0) {
                if (this.friends.length === 0) {
                  EmptyState({ title: '暂无好友', hint: '点击右上角添加好友', icon: SymbolIcons.mine(false) })
                } else {
                  ForEach(this.friends, (friend: FriendItem) => {
                    this.friendRow(friend)
                  }, (friend: FriendItem) => 'friend-' + friend.account)
                }
              } else if (this.activeTab === 1) {
                if (this.requests.length === 0) {
                  EmptyState({ title: '暂无好友申请', hint: '新的申请会显示在这里', icon: SymbolIcons.mail() })
                } else {
                  ForEach(this.requests, (request: FriendRequestItem) => {
                    this.requestRow(request)
                  }, (request: FriendRequestItem) => 'request-' + request.from + '-' + request.kind)
                }
              } else {
                if (this.blocks.length === 0) {
                  EmptyState({ title: '黑名单为空', hint: '被拉黑的用户不会再来消息', icon: SymbolIcons.close() })
                } else {
                  ForEach(this.blocks, (account: string) => {
                    this.blockRow(account)
                  }, (account: string) => 'block-' + account)
                }
              }
              GhostButton({ label: this.loading ? '刷新中…' : '刷新', compact: true,
                onTap: (): void => { void this.refresh(); } })
            }
              .width('100%')
              .constraintSize({ maxWidth: this.contentMaxWidth() })
              .padding({
                left: this.tablet() ? '24vp' : '16vp',
                right: this.tablet() ? '24vp' : '16vp',
                top: '8vp',
                bottom: (this.safeBottom() + 24) + 'vp'
              })
          }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
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
      this.addOverlay()
      // 实时消息提醒：好友页顶部弹窗，可直接回复私聊消息。
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
          Logger.warn('FRIENDS_PAGE', '更新好友页宽度失败：' + String(error));
        }
      })
  }
}

import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, CommunityUser } from '../common/CommunityApi';
import { ChatService } from '../common/ChatService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { AccountApi, FollowEntry } from '../common/AccountApi';
import { SocialStore } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, PrimaryButton } from '../common/UiWidgets';
import { SymbolIcons } from '../common/SymbolIcons';

interface ProfileRouteParams {
  account?: string;
}

class ProfileChatParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class ProfileChatRoute {
  url: string = 'pages/ChatRoomPage';
  params: ProfileChatParams;

  constructor(peer: string, title: string) {
    this.params = new ProfileChatParams();
    this.params.peer = peer;
    this.params.title = title;
  }
}

/**
 * 用户资料页 · 7.11
 * 头像、昵称、ID、签名、等级、称号、VIP；发消息、加好友、举报、拉黑。
 */
@Entry
@Component
struct UserProfilePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private account: string = '';
  @State private profile: CommunityUser = new CommunityUser();
  @State private found: boolean = false;
  @State private loading: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private loggedIn: boolean = false;
  @State private isFriend: boolean = false;
  @State private blocked: boolean = false;
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';

  aboutToAppear(): void {
    void this.loadFollowStatus();
    try {
      const params = router.getParams() as ProfileRouteParams | undefined;
      if (params && typeof params.account === 'string') {
        this.account = params.account.trim();
      }
    } catch (error) {
      Logger.warn('USER_PROFILE', '读取资料参数失败：' + String(error));
    }
    void this.prepare();
  }

  onPageShow(): void {
    if (this.found) {
      this.refreshRelation();
    }
  }

  private async prepare(): Promise<void> {
    if (!this.account) {
      return;
    }
    this.loading = true;
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      const user: CommunityUser | undefined = await CommunityApi.queryUser(this.account);
      if (user === undefined) {
        this.found = false;
        this.showToast('未找到该用户');
        return;
      }
      this.profile = user;
      this.found = true;
      this.refreshRelation();
      Logger.info('USER_PROFILE', '资料加载成功：' + this.account);
    } catch (error) {
      this.showToast('资料加载失败：' + String(error));
      Logger.error('USER_PROFILE', '资料加载失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private refreshRelation(): void {
    this.isFriend = SocialStore.friend(this.account) !== undefined;
    this.blocked = SocialStore.isBlocked(this.account);
  }

  private async sendFriendRequest(): Promise<void> {
    if (!this.loggedIn) {
      this.showToast('请先登录');
      return;
    }
    if (this.isFriend) {
      this.showToast('已经是好友了');
      return;
    }
    if (this.account === this.session.user) {
      this.showToast('不能添加自己');
      return;
    }
    try {
      await ChatService.sendFriendRequest(this.session, this.account, this.session.user);
      this.showToast('好友申请已发送');
      Logger.info('USER_PROFILE', '好友申请发送：' + this.account);
    } catch (error) {
      this.showToast('发送失败：' + String(error));
    }
  }

  private openChat(): void {
    if (!this.loggedIn) {
      this.showToast('请先登录');
      return;
    }
    if (this.blocked) {
      this.showToast('已拉黑该用户，请先移出黑名单');
      return;
    }
    try {
      router.pushUrl(new ProfileChatRoute(this.account, this.profile.name || this.account)).catch((error: Error) => {
        Logger.error('USER_PROFILE', '打开私聊失败：' + String(error));
      });
    } catch (error) {
      Logger.error('USER_PROFILE', '私聊路由异常：' + String(error));
    }
  }

  private report(): void {
    AlertDialog.show({
      title: '举报用户',
      message: '确定举报 ' + (this.profile.name || this.account) + ' 吗？管理员会尽快处理。',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '提交举报',
        action: (): void => {
          Logger.warn('USER_PROFILE', '用户举报已提交：' + this.account);
          this.showToast('举报已提交，感谢你的反馈');
        }
      }
    });
  }

  private toggleBlock(): void {
    if (this.blocked) {
      SocialStore.unblock(this.account);
      this.blocked = false;
      this.showToast('已移出黑名单');
      return;
    }
    SocialStore.block(this.account);
    SocialStore.removeFriend(this.account);
    this.blocked = true;
    this.isFriend = false;
    this.showToast('已加入黑名单');
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('USER_PROFILE', '同步沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 700);
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  @State private followed: boolean = false;
  @State private followedMe: boolean = false;

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Text('用户资料')
        .fontSize(Ui.fs(this.tablet() ? '20vp' : '18vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .layoutWeight(1)
      Text('⋯')
        .fontSize(Ui.fs('22vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .width('36vp').height('36vp').textAlign(TextAlign.Center)
        .borderRadius('18vp').backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .onClick(() => { this.report(); })
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '16vp',
        right: this.tablet() ? '24vp' : '16vp',
        top: (this.safeTop() + 6) + 'vp',
        bottom: '8vp'
      })
  }

  @Builder
  private avatarBlock() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('88vp').height('88vp').borderRadius('44vp')
        .linearGradient({ angle: 135, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
        .shadow({ radius: 18, color: Ui.accentGlow(this.darkTheme), offsetY: 7 })
      Text(this.initial(this.profile.name))
        .fontSize(Ui.fs('34vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      // 账号真实头像（echoportrait.php），加载失败保持首字。
      if (this.portraitUrl().length > 0) {
        Image(this.portraitUrl())
          .width('88vp').height('88vp').borderRadius('44vp')
          .objectFit(ImageFit.Cover)
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .onError(() => { Logger.warn('USER_PROFILE', '头像加载失败：' + this.account); })
      }
    }
      .width('88vp').height('88vp')
  }

  @Builder
  private profileCard() {
    Column({ space: '12vp' }) {
      Row({ space: '14vp' }) {
        this.avatarBlock()
        Column({ space: '5vp' }) {
          Row({ space: '6vp' }) {
            Text(this.profile.name || this.account)
              .fontSize(Ui.fs(this.tablet() ? '23vp' : '21vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
              .layoutWeight(1)
            if (this.profile.vipTime.length > 0 && this.profile.vipTime !== '已过期') {
              Text('VIP')
                .fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme))
                .padding({ left: '6vp', right: '6vp' }).borderRadius('7vp')
                .backgroundColor(Ui.goldSoft(this.darkTheme))
            }
          }
            .width('100%')
          Text('ID：' + this.account)
            .fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          Text(this.profile.signature || '这个人很懒，还没有签名')
            .fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.inkSoft(this.darkTheme))
            .maxLines(2)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
      Row({ space: '8vp' }) {
        this.statCell('等级', this.profile.grade || ('Lv.' + String(this.profile.exp)))
        this.statCell('称号', this.profile.chenhao || '未佩戴')
        this.statCell('获赞', String(this.profile.praise))
      }
        .width('100%')
      if (this.profile.registerTime.length > 0) {
        Text('注册时间 ' + this.profile.registerTime)
          .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme)).width('100%')
      }
    }
      .width('100%')
      .padding(this.tablet() ? '20vp' : '18vp')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
  }

  @Builder
  private statCell(label: string, value: string) {
    Column({ space: '2vp' }) {
      Text(value)
        .fontSize(Ui.fs('14vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.ink(this.darkTheme))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
    }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding('6vp')
      .borderRadius('10vp')
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
  }

  @Builder
  private actionRow() {
    Row({ space: '8vp' }) {
      if (this.account !== this.session.user) {
        PrimaryButton({ label: '发消息', compact: true, onTap: (): void => { this.openChat(); } })
        // 互关 / 回关 / 已关注 / 关注，均走 follow.php。
        GhostButton({ label: this.followLabel(), compact: true,
          onTap: (): void => { void this.toggleFollow(); } })
        GhostButton({ label: this.blocked ? '移出黑名单' : '拉黑', compact: true, onTap: (): void => { this.toggleBlock(); } })
      }
      GhostButton({ label: '举报', compact: true, onTap: (): void => { this.report(); } })
    }
      .width('100%')
      .padding({ top: '4vp' })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        this.header()
        if (!this.found) {
          Column({ space: '12vp' }) {
            if (this.loading) {
              LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.darkTheme))
            } else {
              EmptyState({ title: '用户不存在', hint: '账号可能已注销或输入有误', icon: SymbolIcons.mine(false) })
              GhostButton({ label: '返回', onTap: (): void => { router.back(); } })
            }
          }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: '12vp' }) {
              this.profileCard()
              this.actionRow()
            }
              .width('100%')
              .constraintSize({ maxWidth: this.contentMaxWidth() })
              .padding({
                left: this.tablet() ? '24vp' : '16vp',
                right: this.tablet() ? '24vp' : '16vp',
                top: '14vp',
                bottom: '28vp'
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
          .align(Alignment.Bottom).margin({ bottom: '30vp' })
      }
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
          Logger.warn('USER_PROFILE', '更新资料页宽度失败：' + String(error));
        }
      })
  }
  /** 该账号头像地址（echoportrait.php）。 */
  private portraitUrl(): string {
    return AccountApi.portraitUrl(this.account);
  }

  /** 按钮文案：互关 / 回关 / 已关注 / 关注。 */
  private followLabel(): string {
    if (this.followed && this.followedMe) { return '互关'; }
    if (this.followed) { return '已关注'; }
    if (this.followedMe) { return '回关'; }
    return '关注';
  }

  /** 拉关注/粉丝列表，判断双向关注关系。 */
  private async loadFollowStatus(): Promise<void> {
    try {
      if (!this.session.valid() || this.account.length === 0) { return; }
      if (this.account === this.session.user) { return; }
      const followingText: string = await AccountApi.following(this.session.user, this.session.pass);
      const followingList: FollowEntry[] = await AccountApi.parseFollowList(followingText);
      this.followed = followingList.some((item: FollowEntry) => item.user === this.account);
      const followerText: string = await AccountApi.followers(this.session.user, this.session.pass);
      const followerList: FollowEntry[] = await AccountApi.parseFollowList(followerText);
      this.followedMe = followerList.some((item: FollowEntry) => item.user === this.account);
    } catch (error) {
      Logger.warn('USER_PROFILE', '读取关注关系失败：' + String(error));
    }
  }

  /** 加好友 / 关注 / 取关。 */
  private async toggleFollow(): Promise<void> {
    try {
      if (!this.session.valid()) {
        this.toastNotice('请先登录');
        return;
      }
      const message: string = this.followed
        ? await AccountApi.unfollow(this.session.user, this.session.pass, this.account)
        : await AccountApi.follow(this.session.user, this.session.pass, this.account);
      await this.loadFollowStatus();
      this.toastNotice(message.length > 0 ? message : '操作成功');
    } catch (error) {
      this.toastNotice('操作失败：' + String(error));
    }
  }

  private toastNotice(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message }); }
    catch (error) { Logger.warn('USER_PROFILE', String(error)); }
  }
}

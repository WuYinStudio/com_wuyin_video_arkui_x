import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AccountApi, FollowEntry } from '../common/AccountApi';
import { AccountStore, RankRow, VipPlan, WalletFlow } from '../common/AccountStore';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, CommunityUser } from '../common/CommunityApi';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { SocialStore, FriendItem } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, PrimaryButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

/**
 * 账号中心（签到 / 钱包 / VIP / 资料 / 三榜）。
 *
 * 真实接口（api.y11.top 文档）：
 * - 金币余额 echomoney.php、会员状态 uservipif.php、用户资料 echouserdata.php
 * - 改昵称 username.php、改签名 autographset.php、改密码 userpass.php、绑 QQ userqqset.php
 * - 每日签到 sign.php（MyPage 已有的 CommunityApi.signIn）
 *
 * 沙箱部分（界面已标注）：金币套餐充值、卡密兑换、VIP 四档下单、三榜样本。
 * 这些接口文档里要么需要支付渠道、要么需要后台数据，先把流程跑通，后续替换成真实接口即可。
 */
@Entry
@Component
struct AccountCenterPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private session: CommunitySession = new CommunitySession();
  @State private profile: CommunityUser = new CommunityUser();
  @State private loggedIn: boolean = false;
  @State private coins: number = 0;
  @State private coinsText: string = '0';
  @State private vipExpire: string = '';
  // 服务端真实粉丝数（follow.php action=followers）
  @State private fansCount: number = 0;
  @State private signDay: number = 1;
  @State private signedToday: boolean = false;
  @State private streak: number = 0;
  @State private flows: WalletFlow[] = [];
  @State private plans: VipPlan[] = [];
  @State private rankKind: string = 'money';
  @State private ranks: RankRow[] = [];
  @State private nickname: string = '';
  @State private signature: string = '';
  @State private newPass: string = '';
  @State private qq: string = '';
  @State private busy: boolean = false;
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';
  @State private kami: string = '';

  aboutToAppear(): void {
    void this.prepare();
  }

  private async prepare(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await AccountStore.init(context);
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      this.refreshLocal();
      if (!this.loggedIn) {
        return;
      }
      await this.loadRemote();
    } catch (error) {
      Logger.error('ACCOUNT_CENTER', '初始化账号中心失败：' + String(error));
      this.showToast('加载失败：' + String(error));
    }
  }

  private refreshLocal(): void {
    this.plans = AccountStore.plans();
    this.coins = AccountStore.coins;
    this.coinsText = String(AccountStore.coins);
    this.flows = AccountStore.flows.slice(0, 20);
    this.streak = AccountStore.streak();
    this.signDay = AccountStore.signDay();
    this.signedToday = AccountStore.signedToday();
    this.vipExpire = AccountStore.vipExpire;
    const names: string[] = [];
    const grades: string[] = [];
    const friendList: FriendItem[] = SocialStore.friendsList();
    for (const friend of friendList) {
      names.push(friend.name || friend.account);
      grades.push(friend.grade);
    }
    this.ranks = AccountStore.ranksWithFriends(this.rankKind, this.session.user,
      this.profile.praise, this.fansCount > 0 ? this.fansCount : this.profile.fans, names, grades);
  }

  /** 读服务端资料：exp / 帖子数 / 金币 / 会员；接口失败不影响沙箱部分。 */
  private async loadRemote(): Promise<void> {
    try {
      this.profile = await CommunityApi.fetchProfile(this.session);
      this.nickname = this.profile.name;
      this.signature = this.profile.signature;
      this.qq = this.profile.qq;
      Logger.info('ACCOUNT_CENTER', '资料已加载：exp=' + String(this.profile.exp) + '，帖子=' + String(this.profile.postCount));
    } catch (error) {
      Logger.warn('ACCOUNT_CENTER', '读取用户资料失败：' + String(error));
    }
    try {
      const money: number = await AccountApi.money(this.session.user, this.session.pass);
      if (money > this.coins) {
        this.coins = money;
        this.coinsText = String(money);
      }
      Logger.info('ACCOUNT_CENTER', '服务端金币=' + String(money));
    } catch (error) {
      Logger.warn('ACCOUNT_CENTER', '读取金币失败：' + String(error));
    }
    try {
      const json: string = await AccountApi.followers(this.session.user, this.session.pass);
      const list: FollowEntry[] = await AccountApi.parseFollowList(json);
      if (list.length > 0) {
        this.fansCount = list.length;
        this.ranks = AccountStore.ranksWithFriends(this.rankKind, this.session.user,
          this.profile.praise, this.fansCount, [], []);
        Logger.info('ACCOUNT_CENTER', '真实粉丝数=' + String(this.fansCount));
      }
    } catch (error) {
      Logger.warn('ACCOUNT_CENTER', '读取粉丝列表失败：' + String(error));
    }
    try {
      const expire: string = await AccountApi.vipExpire(this.session.user, this.session.pass);
      if (expire.length > 0) {
        this.vipExpire = expire;
      }
    } catch (error) {
      Logger.warn('ACCOUNT_CENTER', '读取会员状态失败：' + String(error));
    }
  }

  private async doSign(): Promise<void> {
    if (this.busy) { return; }
    if (this.signedToday) {
      this.showToast('今天已经签到过了');
      return;
    }
    this.busy = true;
    try {
      // 服务端签到（sign.php）：成功/已签到都以返回文案为准，失败不阻断本地日历。
      let remote: string = '';
      try {
        remote = await CommunityApi.signIn(this.session);
      } catch (error) {
        Logger.warn('ACCOUNT_CENTER', '服务端签到失败，仅记录本地：' + String(error));
      }
      const reward: number = await AccountStore.sign();
      this.refreshLocal();
      this.showToast('签到成功 · 第 ' + String(this.signDay) + ' 天 +' + String(reward) + ' 金币' +
        (remote.length > 0 ? '（' + remote + '）' : ''));
    } catch (error) {
      this.showToast('签到失败：' + String(error));
    } finally {
      this.busy = false;
    }
  }

  private async recharge(coins: number, price: number): Promise<void> {
    try {
      AccountStore.coins += coins;
      AccountStore.addFlow('金币套餐充值（沙箱）', coins, '￥' + String(price));
      await AccountStore.save();
      this.refreshLocal();
      this.showToast('沙箱充值成功：+' + String(coins) + ' 金币');
    } catch (error) {
      this.showToast('充值失败：' + String(error));
    }
  }

  private async redeemKami(): Promise<void> {
    try {
      const coins: number = await AccountStore.redeem(this.kami);
      this.kami = '';
      this.refreshLocal();
      this.showToast('兑换成功：+' + String(coins) + ' 金币');
    } catch (error) {
      this.showToast(String(error));
    }
  }

  private async buy(plan: VipPlan): Promise<void> {
    try {
      const expire: string = await AccountStore.buyVip(plan);
      this.refreshLocal();
      this.vipExpire = expire;
      this.showToast('已开通 ' + plan.name + '，到期 ' + expire + '（沙箱）');
    } catch (error) {
      this.showToast(String(error));
    }
  }

  private async saveNickname(): Promise<void> {
    if (this.nickname.trim().length === 0) {
      this.showToast('昵称不能为空');
      return;
    }
    await this.runRemote('修改昵称', (): Promise<string> =>
      AccountApi.setNickname(this.session.user, this.session.pass, this.nickname.trim()));
  }

  private async saveSignature(): Promise<void> {
    await this.runRemote('修改签名', (): Promise<string> =>
      AccountApi.setSignature(this.session.user, this.session.pass, this.signature.trim()));
  }

  private async savePassword(): Promise<void> {
    if (this.newPass.trim().length < 6) {
      this.showToast('新密码至少 6 位');
      return;
    }
    await this.runRemote('修改密码', (): Promise<string> => {
      const result: Promise<string> = AccountApi.setPassword(this.session.user, this.session.pass, this.newPass.trim());
      return result;
    });
    this.newPass = '';
  }

  private async saveQQ(): Promise<void> {
    await this.runRemote('绑定 QQ', (): Promise<string> =>
      AccountApi.setQQ(this.session.user, this.session.pass, this.qq.trim()));
  }

  private async runRemote(label: string, action: () => Promise<string>): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const message: string = await action();
      this.showToast(message.length > 0 ? label + '：' + message : label + '成功');
    } catch (error) {
      this.showToast(label + '失败：' + String(error));
    } finally {
      this.busy = false;
    }
  }

  private switchRank(kind: string): void {
    this.rankKind = kind;
    const names: string[] = [];
    const grades: string[] = [];
    const friendList: FriendItem[] = SocialStore.friendsList();
    for (const friend of friendList) {
      names.push(friend.name || friend.account);
      grades.push(friend.grade);
    }
    this.ranks = AccountStore.ranksWithFriends(kind, this.session.user,
      this.profile.praise, this.fansCount > 0 ? this.fansCount : this.profile.fans, names, grades);
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2400);
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private gutter(): number {
    return this.tablet() ? 24 : 16;
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    void replaceRoute({ url: 'pages/Index' });
  }

  onBackPress(): boolean {
    if (Number(router.getLength()) > 1) { return false; }
    void replaceRoute({ url: 'pages/Index' });
    return true;
  }

  @Builder
  private card(title: string, subtitle: string) {
    Column({ space: '2vp' }) {
      Text(title)
        .fontSize(Ui.fs(this.tablet() ? '18vp' : '16vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
    }
      .width('100%')
      .padding({ bottom: '8vp' })
  }

  @Builder
  private signSection() {
    Column() {
      this.card('每日签到', '连续签到 7 天可拿第 7 天大奖 · 每次 +5~100 金币')
      Row({ space: '6vp' }) {
        ForEach([1, 2, 3, 4, 5, 6, 7], (day: number) => {
          Column({ space: '2vp' }) {
            Text(String(day))
              .fontSize(Ui.fs('10vp', this.fontScale))
              .fontColor(day === 7 ? Ui.gold(this.darkTheme) : Ui.inkFaint(this.darkTheme))
            Text(day === 7 ? '大奖' : String(AccountStore.signReward(day)))
              .fontSize(Ui.fs(day === 7 ? '11vp' : '10vp', this.fontScale))
              .fontWeight(day === 7 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(day === 7 ? Ui.gold(this.darkTheme) : Ui.inkSoft(this.darkTheme))
          }
            .layoutWeight(1)
            .height('46vp')
            .justifyContent(FlexAlign.Center)
            .borderRadius('10vp')
            .backgroundColor(day <= this.streak % 7 ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .border({ width: 1, color: day <= this.streak % 7 ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme) })
        }, (day: number) => 'sign-day-' + String(day))
      }
        .width('100%')
      Row({ space: '8vp' }) {
        Text(this.signedToday ? '今日已签到 · 连续 ' + String(this.streak) + ' 天' :
          '今日可签 · 第 ' + String(this.signDay) + ' 天 +' + String(AccountStore.signReward(this.signDay)) + ' 金币')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(this.signedToday ? Ui.inkFaint(this.darkTheme) : Ui.accentStrong(this.darkTheme))
          .layoutWeight(1)
          .maxLines(2)
        PrimaryButton({ label: this.signedToday ? '已签到' : '签到', compact: true,
          onTap: (): void => { void this.doSign(); } })
      }
        .width('100%')
        .padding({ top: '10vp' })
        .alignItems(VerticalAlign.Center)
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  @Builder
  private walletSection() {
    Column() {
      this.card('钱包 · 金币', '余额 ' + this.coinsText + ' 金币；套餐与卡密为沙箱流程，流水本地记账')
      Row({ space: '6vp' }) {
        ForEach(AccountStore.COIN_PACKS, (pack: number, index: number) => {
          Column({ space: '2vp' }) {
            Text(String(pack))
              .fontSize(Ui.fs('13vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text('￥' + String(AccountStore.COIN_PRICES[index]))
              .fontSize(Ui.fs('10vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .height('50vp')
            .justifyContent(FlexAlign.Center)
            .borderRadius('10vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
            .onClick(() => { void this.recharge(pack, AccountStore.COIN_PRICES[index]); })
        }, (pack: number, index: number) => 'coin-pack-' + String(pack))
      }
        .width('100%')
      Row({ space: '8vp' }) {
        TextInput({ text: this.kami, placeholder: '卡密 WY-XXXX-XXXX' })
          .layoutWeight(1)
          .height('42vp')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .placeholderColor(Ui.inkFaint(this.darkTheme))
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .borderRadius('21vp')
          .padding({ left: '14vp', right: '14vp' })
          .onChange((value: string) => { this.kami = value; })
        GhostButton({ label: '兑换', compact: true, onTap: (): void => { void this.redeemKami(); } })
      }
        .width('100%')
        .padding({ top: '10vp' })
      ForEach(this.flows, (flow: WalletFlow, index: number) => {
        Row({ space: '8vp' }) {
          Column({ space: '2vp' }) {
            Text(flow.title)
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
            Text(flow.time + (flow.note.length > 0 ? ' · ' + flow.note : ''))
              .fontSize(Ui.fs('10vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .maxLines(1)
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          Text((flow.amount > 0 ? '+' : '') + String(flow.amount))
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(flow.amount > 0 ? Ui.success(this.darkTheme) : Ui.danger(this.darkTheme))
        }
          .width('100%')
          .padding({ top: '8vp', bottom: '8vp' })
          .border({ width: { top: index === 0 ? 0 : 1 }, color: Ui.divider(this.darkTheme) })
      }, (flow: WalletFlow, index: number) => 'flow-' + String(index) + flow.time)
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  @Builder
  private vipSection() {
    Column() {
      this.card('VIP 会员', (this.vipExpire.length > 0 ? '当前到期：' + this.vipExpire : '当前未开通') +
        ' · 下单为演示沙箱（扣本地金币，1 元 = 10 金币）')
      Row({ space: '6vp' }) {
        ForEach(this.plans, (plan: VipPlan) => {
          Column({ space: '3vp' }) {
            Text(plan.name)
              .fontSize(Ui.fs('12vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.gold(this.darkTheme))
              .maxLines(1)
            Text('￥' + String(plan.price))
              .fontSize(Ui.fs('15vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text(String(plan.days >= 36500 ? '永久' : String(plan.days) + ' 天'))
              .fontSize(Ui.fs('9.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .maxLines(1)
          }
            .layoutWeight(1)
            .height('76vp')
            .justifyContent(FlexAlign.Center)
            .borderRadius('12vp')
            .backgroundColor(Ui.goldSoft(this.darkTheme))
            .border({ width: 1, color: Ui.divider(this.darkTheme) })
            .onClick(() => { void this.buy(plan); })
        }, (plan: VipPlan) => 'vip-' + plan.id)
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  @Builder
  private profileSection() {
    Column() {
      this.card('资料编辑', '改昵称 / 签名 / 密码 / QQ，走 api.y11.top 用户系统接口')
      this.field('昵称', this.nickname, '昵称', (value: string): void => { this.nickname = value; },
        (): void => { void this.saveNickname(); })
      this.field('签名', this.signature, '个性签名', (value: string): void => { this.signature = value; },
        (): void => { void this.saveSignature(); })
      this.field('QQ', this.qq, 'QQ 号', (value: string): void => { this.qq = value; },
        (): void => { void this.saveQQ(); })
      this.field('新密码', this.newPass, '至少 6 位', (value: string): void => { this.newPass = value; },
        (): void => { void this.savePassword(); })
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  @Builder
  private field(label: string, value: string, hint: string, changed: (value: string) => void, save: () => void) {
    Row({ space: '8vp' }) {
      Text(label)
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('38vp')
      TextInput({ text: value, placeholder: hint })
        .layoutWeight(1)
        .height('40vp')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .placeholderColor(Ui.inkFaint(this.darkTheme))
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .borderRadius('20vp')
        .padding({ left: '14vp', right: '14vp' })
        .onChange((text: string) => changed(text))
      GhostButton({ label: '保存', compact: true, onTap: save })
    }
      .width('100%')
      .padding({ top: '8vp' })
      .alignItems(VerticalAlign.Center)
  }

  @Builder
  private rankSection() {
    Column() {
      this.card('三榜排名', '金币 / 获赞 / 粉丝 · 我的数据实时，好友按等级估算')
      Row({ space: '6vp' }) {
        GhostButton({ label: '金币榜', compact: true, onTap: (): void => { this.switchRank('money'); } })
        GhostButton({ label: '获赞榜', compact: true, onTap: (): void => { this.switchRank('praise'); } })
        GhostButton({ label: '粉丝榜', compact: true, onTap: (): void => { this.switchRank('fans'); } })
      }
        .width('100%')
      ForEach(this.ranks, (row: RankRow, index: number) => {
        Row({ space: '8vp' }) {
          Text(String(index + 1))
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(index < 3 ? Ui.gold(this.darkTheme) : Ui.inkFaint(this.darkTheme))
            .width('22vp')
          Text(row.name)
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          Text(String(row.value) + ' ' + row.extra)
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme))
        }
          .width('100%')
          .padding({ top: '7vp', bottom: '7vp' })
          .border({ width: { top: index === 0 ? 0 : 1 }, color: Ui.divider(this.darkTheme) })
      }, (row: RankRow, index: number) => 'rank-' + row.name + String(index))
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        Row({ space: '10vp' }) {
          GhostButton({ label: '返回', compact: true, onTap: (): void => { this.goBack(); } })
          Column({ space: '2vp' }) {
            Text('账号中心')
              .fontSize(Ui.fs('22vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text(this.loggedIn ? this.session.user : '未登录')
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .padding({ left: this.gutter() + 'vp', right: this.gutter() + 'vp', top: (this.safeTop() + 6) + 'vp' })
        Scroll() {
          Column({ space: '12vp' }) {
            if (!this.loggedIn) {
              Text('登录后才能签到、充值、开通会员与改资料')
                .fontSize(Ui.fs('13vp', this.fontScale))
                .fontColor(Ui.inkSoft(this.darkTheme))
                .width('100%')
            } else {
              this.signSection()
              this.walletSection()
              this.vipSection()
              this.profileSection()
              this.rankSection()
            }
          }
            .width('100%')
            .constraintSize({ maxWidth: this.tablet() ? '860vp' : '100%' })
            .padding({ left: this.gutter() + 'vp', right: this.gutter() + 'vp', top: '10vp', bottom: '28vp' })
        }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
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
          .margin({ bottom: '48vp' })
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const width: number = Number(newValue.width);
          if (Number.isFinite(width) && width > 0) { this.viewportWidth = width; }
        } catch (error) {
          Logger.warn('ACCOUNT_CENTER', '更新宽度失败：' + String(error));
        }
      })
  }
}

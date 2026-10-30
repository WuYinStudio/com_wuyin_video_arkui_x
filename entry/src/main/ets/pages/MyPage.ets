import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { preferences, uniformTypeDescriptor } from '@kit.ArkData';
import { ShareController, ShareOperationResult, SharedData, SharedRecord, SharePreviewMode } from '../common/compat/ShareCompat';
import { AppConfig } from '../common/AppConfig';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, CommunityUser, RemoteUpdate } from '../common/CommunityApi';
import { ImmersiveService } from '../common/ImmersiveService';
import { AccountApi } from '../common/AccountApi';
import { UserTitles } from '../common/UserTitles';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, GlassIconButton, PrimaryButton, SectionHeader } from '../common/UiWidgets';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { replaceRoute } from '../common/compat/RouterCompat';
import { PlatformApi } from '../common/compat/PlatformApi';

export interface UserInfo {
  userId: string;
  nickName: string;
  goldCoin: number;
  level: number;
  vipStatus: string;
  vipExpireTime: string;
  avatarUrl: string;
  grade: string;
  signature: string;
  postCount: number;
  fans: number;
  follows: number;
  seal: string;
  registerTime: string;
}

export interface GlobalStatInfo {
  totalUsers: number;
  launchCount: number;
  onlineCount: number;
}

interface ErrorPayload {
  message?: string;
}

class UserInfoValue implements UserInfo {
  userId: string = '';
  nickName: string = '';
  goldCoin: number = 0;
  level: number = 0;
  vipStatus: string = '';
  vipExpireTime: string = '';
  avatarUrl: string = '';
  grade: string = '';
  signature: string = '';
  postCount: number = 0;
  fans: number = 0;
  follows: number = 0;
  seal: string = '';
  registerTime: string = '';
}

class GlobalStatValue implements GlobalStatInfo {
  totalUsers: number = 0;
  launchCount: number = 0;
  onlineCount: number = 0;
}

class UserCredentials {
  user: string = '';
  password: string = '';
  nickname: string = '';
  avatar: string = '';
}

class RouteOptions {
  url: string;

  constructor(url: string) {
    this.url = url;
  }
}

class MessageRouteParams {
  room: string = '';

  constructor(room: string) {
    this.room = room;
  }
}

class MessageRouteOptions {
  url: string = 'pages/MessagePage';
  params: MessageRouteParams;

  constructor(room: string) {
    this.params = new MessageRouteParams(room);
  }
}

class EdgePadding {
  top: string;
  bottom: string;
  left: string;
  right: string;

  constructor(top: string, bottom: string, left: string, right: string) {
    this.top = top;
    this.bottom = bottom;
    this.left = left;
    this.right = right;
  }
}

class FeatureItem {
  key: string;
  title: string;
  subtitle: string;
  symbol: Resource;

  constructor(key: string, title: string, subtitle: string, symbol: Resource) {
    this.key = key;
    this.title = title;
    this.subtitle = subtitle;
    this.symbol = symbol;
  }
}

class HistoryItem {
  title: string;
  progress: string;
  coverUrl: string;

  constructor(title: string, progress: string, coverUrl: string) {
    this.title = title;
    this.progress = progress;
    this.coverUrl = coverUrl;
  }
}

@Component
export struct MyPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('onImmersiveChanged') private darkTheme: boolean = true;
  @StorageLink('immersiveStatusBarInset') private statusBarInset: number = 24;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;

  @State private userInfo: UserInfo = new UserInfoValue();
  @State private globalStat: GlobalStatInfo = new GlobalStatValue();
  @State private globalStatAvailable: boolean = false;
  @State private dynamicCount: number = 0;
  @State private newsCount: number = 0;
  @State private accountName: string = '';
  // 关注 / 粉丝数量（follow.php 粉丝与关注列表长度）
  @State private followCount: number = 0;
  // 统计条专用状态（独立 @State，确保一定触发重绘）
  // 用 @StorageLink 双向绑定全局值：任何实例赋值，所有页面实例立即重绘。
  @StorageLink('myStatPosts') private statPosts: number = 0;
  @StorageLink('myStatCoins') private statCoins: number = 0;
  @StorageLink('myStatGrade') private statGrade: string = '';
  @StorageLink('myStatFollows') private statFollows: number = 0;
  @StorageLink('myStatFans') private statFans: number = 0;
  // 昵称修改弹窗
  @State private showNickDialog: boolean = false;
  @State private nickDraft: string = '';
  @State private fansCount: number = 0;
  @State private loggedIn: boolean = false;
  @State private loadingUser: boolean = false;
  @State private viewportWidth: number = 360;
  @State private pageOpacity: number = 0;
  @State private historyItems: HistoryItem[] = [];
  @State private loginPanelVisible: boolean = false;
  @State private loginPanelOffset: number = 360;

  private readonly pageScroller: Scroller = new Scroller();
  private readonly historyScroller: Scroller = new Scroller();
  private pageAlive: boolean = false;
  private redirectingLogin: boolean = false;
  private refreshingLoginState: boolean = false;
  private loginPanelAnimationToken: number = 0;
  private readonly storagePermission: Permissions = 'ohos.permission.READ_MEDIA' as Permissions;

  private readonly firstRow: FeatureItem[] = [
    new FeatureItem('message', '消息中心', '聊天室与通知', $r('sys.symbol.speaker_wave_3_fill')),
    new FeatureItem('forum', '交流论坛', '发帖与讨论', $r('sys.symbol.list_number')),
    new FeatureItem('wallet', '我的钱包', '金币明细', $r('sys.symbol.folder')),
    new FeatureItem('vipRenew', '会员续费', '专享权益', $r('sys.symbol.square_grid_2x2'))
];

  private readonly secondRow: FeatureItem[] = [
    new FeatureItem('favorite', '我的收藏', '收藏影片', $r('sys.symbol.square_grid_2x2')),
    new FeatureItem('download', '我的下载', '离线资源', $r('sys.symbol.arrow_down_circle')),
    new FeatureItem('manage', '资源管理', '本地资源', $r('sys.symbol.folder')),
    new FeatureItem('live', '电视直播', '央视与卫视', $r('sys.symbol.speaker_wave_3_fill'))
];

  private readonly thirdRow: FeatureItem[] = [
    new FeatureItem('theme', '主题商城', '27 套主题与壁纸', $r('sys.symbol.square_grid_2x2')),
    new FeatureItem('share', '分享软件', '邀请好友', $r('sys.symbol.house')),
    new FeatureItem('permission', '检测权限', '安全诊断', $r('sys.symbol.gearshape')),
    new FeatureItem('update', '更新日志', '版本记录', $r('sys.symbol.folder')),
    new FeatureItem('about', '关于我们', '应用信息', $r('sys.symbol.person'))
];

  private restoreStats(): void {
    try {
      this.statPosts = AppStorage.get<number>('myStatPosts') || 0;
      this.statCoins = AppStorage.get<number>('myStatCoins') || 0;
      this.statGrade = AppStorage.get<string>('myStatGrade') || '';
      this.statFollows = AppStorage.get<number>('myStatFollows') || 0;
      this.statFans = AppStorage.get<number>('myStatFans') || 0;
    } catch (error) {
      Logger.warn('MyPage', '恢复统计失败');
    }
  }

  aboutToAppear(): void {
    try {
      this.statPosts = AppStorage.get<number>('myStatPosts') || 0;
      this.statCoins = AppStorage.get<number>('myStatCoins') || 0;
      this.statGrade = AppStorage.get<string>('myStatGrade') || '';
      this.statFollows = AppStorage.get<number>('myStatFollows') || 0;
      this.statFans = AppStorage.get<number>('myStatFans') || 0;
    } catch (error) { Logger.warn('MyPage', '恢复统计失败'); }

    this.pageAlive = true;
    this.syncImmersive();
    this.pageOpacity = 0;
    animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
      this.pageOpacity = 1;
    });
    this.refreshOnShow();
    this.refreshGlobalStatistics();
    Logger.info('MyPage', '我的页面已加载');
  }

  onPageShow(): void {
    this.restoreStats();
    this.onShow();
  }

  onShow(): void {
    this.refreshOnShow();
  }

  aboutToDisappear(): void {
    this.pageAlive = false;
  }

  private refreshOnShow(): void {
    void this.refreshLoginState().catch((error: Object): void => {
      const failure: Error = new Error('刷新登录状态失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
    });
  }

  private refreshGlobalStatistics(): void {
    void this.loadGlobalStatistics().catch((error: Object): void => {
      const failure: Error = new Error('刷新全网统计失败：' + this.errorMessage(error));
      Logger.error('MyPageNetwork', failure.message);
    });
  }

  private onImmersiveChanged(): void {
    this.syncImmersive();
  }

  private syncImmersive(): void {
    void ImmersiveService.apply(true);
  }

  private errorMessage(error: Object): string {
    if (error instanceof Error) {
      return error.message || '未知错误';
    }
    const errorPayload: ErrorPayload = error as ErrorPayload;
    if (typeof errorPayload.message === 'string' && errorPayload.message.trim()) {
      return errorPayload.message.trim();
    }
    try {
      const details: string = JSON.stringify(error);
      return details && details !== '{}' ? details : '未知错误';
    } catch (_error) {
      return '未知错误';
    }
  }

  private profileGradientColors(): Array<[ResourceColor, number]> {
    try {
      // 登录态使用"墨玻璃/乳白玻璃"高光层，未登录态叠一层品牌淡底指引登录。
      if (this.loggedIn) {
        return [[Ui.glassSheenTop(this.darkTheme), 0.0], [Ui.glassTintStrong(this.darkTheme), 0.55],
          [Ui.cardBottom(this.darkTheme), 1.0]];
      }
      return [[Ui.accentSoft(this.darkTheme), 0.0], [Ui.glassTint(this.darkTheme), 0.55],
        [Ui.cardBottom(this.darkTheme), 1.0]];
    } catch (error) {
      Logger.error('MyPageUI', '读取个人卡片渐变色失败：' + this.errorMessage(error));
      return [[this.cardColor(), 0.0], [this.cardColor(), 1.0]];
    }
  }

  private profileCardBorderColor(): ResourceColor {
    return Ui.glassRing(this.darkTheme);
  }

  private loginPanelBackground(): ResourceColor {
    return Ui.glassTintStrong(this.darkTheme);
  }

  private loginPanelBorderColor(): ResourceColor {
    return Ui.glassRing(this.darkTheme);
  }

  private loginPanelMaskColor(): ResourceColor {
    return Ui.scrim(this.darkTheme);
  }

  private loginPanelBlur(): number {
    const configuredBlur: number = this.glassBlurRadius();
    return Math.max(18, configuredBlur);
  }

  private showLoginPanel(): void {
    try {
      if (this.loggedIn) {
        return;
      }
      this.loginPanelAnimationToken += 1;
      const token: number = this.loginPanelAnimationToken;
      this.loginPanelVisible = true;
      AppStorage.setOrCreate<boolean>('navigationBarHidden', true);
      this.loginPanelOffset = 360;
      animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
        try {
          if (this.loginPanelAnimationToken === token) {
            this.loginPanelOffset = 0;
          }
        } catch (error) {
          Logger.error('MyPageLoginPanel', '登录面板弹出动画失败：' + this.errorMessage(error));
        }
      });
      Logger.info('MyPageLoginPanel', '打开底部登录面板');
    } catch (error) {
      Logger.error('MyPageLoginPanel', '打开底部登录面板失败：' + this.errorMessage(error));
    }
  }

  private closeLoginPanel(): void {
    try {
      if (!this.loginPanelVisible) {
        return;
      }
      this.loginPanelAnimationToken += 1;
      const token: number = this.loginPanelAnimationToken;
      animateTo({ duration: 260, curve: Curve.EaseIn }, () => {
        try {
          if (this.loginPanelAnimationToken === token) {
            this.loginPanelOffset = 360;
          }
        } catch (error) {
          Logger.error('MyPageLoginPanel', '登录面板收起动画失败：' + this.errorMessage(error));
        }
      });
      setTimeout((): void => {
        try {
          if (this.loginPanelAnimationToken === token) {
            this.loginPanelVisible = false;
      AppStorage.setOrCreate<boolean>('navigationBarHidden', false);
            Logger.info('MyPageLoginPanel', '关闭底部登录面板');
          }
        } catch (error) {
          Logger.error('MyPageLoginPanel', '隐藏登录面板失败：' + this.errorMessage(error));
        }
      }, 280);
    } catch (error) {
      Logger.error('MyPageLoginPanel', '关闭底部登录面板失败：' + this.errorMessage(error));
    }
  }

  private async openLoginFromPanel(): Promise<void> {
    try {
      this.closeLoginPanel();
      await this.redirectToLogin();
    } catch (error) {
      Logger.error('MyPageLoginPanel', '从登录面板打开登录页失败：' + this.errorMessage(error));
    }
  }

  private async openPreferences(): Promise<preferences.Preferences> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return await preferences.getPreferences(context, 'wuyin');
    } catch (error) {
      const failure: Error = new Error('读取用户偏好设置失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
      throw failure;
    }
  }

  private async readCredentials(): Promise<UserCredentials> {
    const store: preferences.Preferences = await this.openPreferences();
    try {
      const credentials: UserCredentials = new UserCredentials();
      credentials.user = String(await store.get('$user', ''));
      credentials.password = String(await store.get('$pass', ''));
      credentials.nickname = String(await store.get('$qqname', ''));
      credentials.avatar = String(await store.get('$QQimg', ''));
      return credentials;
    } catch (error) {
      const failure: Error = new Error('读取用户登录凭证失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
      throw failure;
    }
  }

  private async clearCredentials(): Promise<void> {
    try {
      const store: preferences.Preferences = await this.openPreferences();
      await store.put('$user', '');
      await store.put('$pass', '');
      await store.put('$qqname', '');
      await store.put('$QQimg', '');
      await store.flush();
      Logger.info('MyPageStorage', '已清空用户登录凭证');
    } catch (error) {
      const failure: Error = new Error('清空用户登录凭证失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
      throw failure;
    }
  }

  private resetUserState(): void {
    this.userInfo = new UserInfoValue();
    this.dynamicCount = 0;
    this.newsCount = 0;
    this.accountName = '';
    this.loggedIn = false;
    this.loadingUser = false;
  }

  private copyUserInfo(source: UserInfo): UserInfoValue {
    const result: UserInfoValue = new UserInfoValue();
    result.userId = source.userId;
    result.nickName = source.nickName;
    result.goldCoin = source.goldCoin;
    result.level = source.level;
    result.vipStatus = source.vipStatus;
    result.vipExpireTime = source.vipExpireTime;
    result.avatarUrl = source.avatarUrl;
    result.grade = source.grade;
    result.signature = source.signature;
    result.postCount = source.postCount;
    result.fans = source.fans;
    result.follows = source.follows;
    result.seal = source.seal;
    result.registerTime = source.registerTime;
    return result;
  }

  private applyCachedProfile(credentials: UserCredentials): void {
    const cached: UserInfoValue = this.copyUserInfo(this.userInfo);
    if (!cached.userId.trim()) {
      cached.userId = credentials.user.trim();
    }
    if (credentials.nickname.trim()) {
      cached.nickName = credentials.nickname.trim();
    }
    if (credentials.avatar.trim()) {
      cached.avatarUrl = credentials.avatar.trim();
    }
    this.userInfo = cached;
  }

  private async refreshLoginState(): Promise<void> {
    if (this.refreshingLoginState) {
      return;
    }
    this.refreshingLoginState = true;
    try {
      const credentials: UserCredentials = await this.readCredentials();
      const user: string = credentials.user.trim();
      const password: string = credentials.password.trim();
      if (!user || !password) {
        this.resetUserState();
        Logger.info('MyPageStorage', '当前没有有效登录凭证');
        return;
      }
      this.accountName = user;
      this.loggedIn = true;
      this.applyCachedProfile(credentials);
      await this.loadUserInfo(credentials);
    } catch (error) {
      const failure: Error = new Error('刷新登录状态失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
      throw failure;
    } finally {
      this.refreshingLoginState = false;
    }
  }

  private async redirectToLogin(): Promise<void> {
    if (this.redirectingLogin) {
      return;
    }
    this.redirectingLogin = true;
    const loginRouteUri: string = 'pages/LoginPage';
    try {
      await replaceRoute(new RouteOptions(loginRouteUri));
      Logger.info('MyPageRoute', '已跳转登录页，URI=' + loginRouteUri);
    } catch (error) {
      this.redirectingLogin = false;
      const detail: string = this.errorMessage(error);
      const failure: Error = new Error('跳转登录页失败：' + detail);
      Logger.error('MyPageRoute', '登录页路由跳转失败，URI=' + loginRouteUri + '，错误=' + detail);
      throw failure;
    }
  }

  private async invalidateSession(): Promise<void> {
    this.resetUserState();
    try {
      await this.clearCredentials();
    } catch (error) {
      const failure: Error = new Error('登录状态失效且凭证清除失败：' + this.errorMessage(error));
      Logger.error('MyPageStorage', failure.message);
      if (this.pageAlive) {
        await this.redirectToLogin();
      }
      throw failure;
    }
    if (this.pageAlive) {
      await this.redirectToLogin();
    }
  }

  private async loadUserInfo(credentials: UserCredentials): Promise<void> {
    this.loadingUser = true;
    try {
      const session: CommunitySession = new CommunitySession();
      session.user = credentials.user;
      session.pass = credentials.password;
      session.loggedIn = true;
      // 文档接口：echouserdata.php?type=json，一次返回昵称、金币、会员、称号、帖子数等资料。
      const profile: CommunityUser = await CommunityApi.fetchProfile(session);
      const merged: UserInfoValue = new UserInfoValue();
      merged.userId = profile.userId.trim() || credentials.user;
      merged.nickName = profile.name.trim() || credentials.nickname.trim() || this.userInfo.nickName;
      merged.goldCoin = profile.money;
      merged.level = profile.exp;
      merged.grade = profile.grade;
      merged.signature = profile.signature;
      merged.postCount = profile.postCount;
      merged.fans = profile.fans;
      merged.follows = profile.follows;
      merged.seal = profile.seal;
      merged.registerTime = profile.registerTime;
      merged.avatarUrl = profile.avatarUrl.trim() || credentials.avatar.trim();
      merged.vipExpireTime = profile.vipTime.trim() || '暂无到期时间';
      merged.vipStatus = profile.vipTime.length > 0 && profile.vipTime !== '已过期' ? '会员' : '普通用户';
      this.userInfo = merged;
      this.dynamicCount = profile.postCount;
      this.followCount = profile.follows;
      this.fansCount = profile.fans;
      this.userInfo.goldCoin = profile.money;
      this.loggedIn = true;
      this.statPosts = profile.postCount;
      this.statCoins = profile.money;
      this.statGrade = profile.grade;
      this.statFollows = profile.follows;
      this.statFans = profile.follows;
      this.statFans = profile.fans;
      // 写入全局缓存：即使页面被重建/多实例，也能恢复到最新值
      AppStorage.setOrCreate<number>('myStatPosts', profile.postCount);
      AppStorage.setOrCreate<number>('myStatCoins', profile.money);
      AppStorage.setOrCreate<string>('myStatGrade', profile.grade);
      AppStorage.setOrCreate<number>('myStatFollows', profile.follows);
      AppStorage.setOrCreate<number>('myStatFans', profile.fans);
      Logger.info('MyPageNetwork', '摘要赋值：动态=' + String(this.dynamicCount) +
        '，金币=' + String(this.userInfo.goldCoin) + '，等级=' + this.userInfo.grade +
        '，关注=' + String(this.followCount) + '，粉丝=' + String(this.fansCount));
      await this.loadNewsCount(session);
      this.followCount = profile.follows;
      this.fansCount = profile.fans;
      Logger.info('MyPageNetwork', '用户资料加载成功，用户=' + merged.userId + '，论坛帖子=' + String(profile.postCount) +
        '，关注=' + String(profile.follows) + '，粉丝=' + String(profile.fans));
    } catch (error) {
      const failure: Error = new Error('加载用户信息失败：' + this.errorMessage(error));
      Logger.error('MyPageNetwork', failure.message);
      throw failure;
    } finally {
      this.loadingUser = false;
    }
  }

  private async loadNewsCount(session: CommunitySession): Promise<void> {
    try {
      this.newsCount = await CommunityApi.newsCount(session);
      Logger.info('MyPageNetwork', '系统消息数量=' + String(this.newsCount));
    } catch (error) {
      Logger.warn('MyPageNetwork', '读取系统消息数量失败：' + String(error));
    }
  }

  private async loadGlobalStatistics(): Promise<void> {
    try {
      // 文档接口只提供在线人数；不再请求工程里不存在的 /statistics/global 占位接口。
      const online: number = await CommunityApi.onlineCount();
      const result: GlobalStatValue = new GlobalStatValue();
      result.totalUsers = 0;
      result.launchCount = 0;
      result.onlineCount = online;
      this.globalStat = result;
      this.globalStatAvailable = true;
      Logger.info('MyPageNetwork', '在线人数统计加载成功：' + String(online));
    } catch (error) {
      this.globalStat = new GlobalStatValue();
      this.globalStatAvailable = false;
      const failure: Error = new Error('加载在线统计失败：' + this.errorMessage(error));
      Logger.error('MyPageNetwork', failure.message);
      throw failure;
    }
  }

  private showAlert(title: string, message: string): void {
    try {
      AlertDialog.show({
        title: title,
          message: message || '暂无信息',
          autoCancel: true,
          primaryButton: {
          value: '知道了',
            action: (): void => {
            Logger.debug('MyPageDialog', '关闭提示弹窗：' + title);
          }
        }
      });
    } catch (error) {
      const failure: Error = new Error('显示提示弹窗失败：' + this.errorMessage(error));
      Logger.error('MyPageDialog', failure.message);
      throw failure;
    }
  }

  private showExtensionDialog(): void {
    try {
      AlertDialog.show({
        title: '应用扩展',
          message: '这里将提供更多扩展软件与辅助工具。' + String.fromCharCode(10) + String.fromCharCode(10) +
        '扩展软件服务正在规划中，后续会根据用户需求逐步上线。',
          autoCancel: true,
          primaryButton: {
          value: '知道了',
            action: (): void => {
            Logger.info('MyPageBusiness', '关闭应用扩展弹窗');
          }
        }
      });
    } catch (error) {
      const failure: Error = new Error('显示应用扩展弹窗失败：' + this.errorMessage(error));
      Logger.error('MyPageBusiness', failure.message);
      throw failure;
    }
  }

  private confirmLogout(): void {
    try {
      AlertDialog.show({
        title: '退出登录',
          message: '退出后将清除当前设备保存的登录凭证，确定要退出吗？',
          autoCancel: true,
          primaryButton: {
          value: '取消',
            action: (): void => {
            Logger.info('MyPageBusiness', '取消退出登录');
          }
        },
          secondaryButton: {
          value: '退出登录',
            action: (): void => {
            void this.logout().catch((error: Object): void => {
              const failure: Error = new Error('退出登录失败：' + this.errorMessage(error));
              Logger.error('MyPageBusiness', failure.message);
            });
          }
        }
      });
    } catch (error) {
      const failure: Error = new Error('显示退出登录确认弹窗失败：' + this.errorMessage(error));
      Logger.error('MyPageBusiness', failure.message);
      throw failure;
    }
  }

  private async logout(): Promise<void> {
    try {
      await this.clearCredentials();
      this.resetUserState();
      await this.redirectToLogin();
    } catch (error) {
      const failure: Error = new Error('退出登录失败：' + this.errorMessage(error));
      Logger.error('MyPageBusiness', failure.message);
      this.showAlert('退出登录失败', '登录凭证未能完整清除，请稍后重试');
      throw failure;
    }
  }

  private async signInClick(): Promise<void> {
    if (!this.loggedIn) {
      this.showAlert('签到', '请先登录后再进行签到');
      return;
    }
    try {
      const credentials: UserCredentials = await this.readCredentials();
      const session: CommunitySession = new CommunitySession();
      session.user = credentials.user;
      session.pass = credentials.password;
      session.loggedIn = true;
      // 文档接口 sign.php 返回纯文本：签到成功 / 今天已签到 / 密码错误 等。
      const message: string = await CommunityApi.signIn(session);
      const alreadySigned: boolean = message.indexOf('已签到') >= 0 || message.indexOf('已经签到') >= 0;
      if (alreadySigned) {
        this.showAlert('签到结果', '今天已经签到过了，明天再来吧');
        return;
      }
      const failed: boolean = message.indexOf('密码错误') >= 0 || message.indexOf('失败') >= 0 ||
        message.indexOf('封禁') >= 0 || message.indexOf('不存在') >= 0;
      if (failed) {
        this.showAlert('签到结果', message || '签到失败，请稍后重试');
        Logger.warn('MyPageBusiness', '签到未成功：' + message);
        return;
      }
      this.showAlert('签到成功', message || '签到成功，奖励已到账');
      Logger.info('MyPageBusiness', '签到成功');
      // 签到会改变金币，立即重新拉取用户资料，避免本地数字与服务端不一致。
      await this.loadUserInfo(credentials);
    } catch (error) {
      const failure: Error = new Error('签到失败：' + this.errorMessage(error));
      Logger.error('MyPageBusiness', failure.message);
      this.showAlert('签到失败', '网络异常，请稍后重试');
      throw failure;
    }
  }

  private async checkPermissionClick(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const status: abilityAccessCtrl.GrantStatus = await manager.checkAccessToken(
        context.applicationInfo.accessTokenId, this.storagePermission);
      const permissionState: string = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ? '已授予' : '未授予';
      const online: number = await CommunityApi.onlineCount();
      const remoteState: string = '云逸服务连接正常（当前在线 ' + String(online) + ' 人）';
      this.showAlert('权限检测', '应用存储权限：' + permissionState + String.fromCharCode(10) + remoteState);
      Logger.info('MyPagePermission', '权限与远程资源诊断完成');
    } catch (error) {
      const failure: Error = new Error('权限检测失败：' + this.errorMessage(error));
      Logger.error('MyPagePermission', failure.message);
      this.showAlert('权限检测', '权限或远程资源检测失败，请稍后重试');
      throw failure;
    }
  }

  private validHttpUrl(value: string): boolean {
    return value.startsWith('https://') || value.startsWith('http://');
  }

  private async shareAppClick(): Promise<void> {
    try {
      // 文档接口：echouser.php?file=new 返回“软件版本 / 更新内容 / 更新链接”。
      const update: RemoteUpdate = await CommunityApi.remoteUpdate();
      const downloadUrl: string = this.validHttpUrl(update.link) ? update.link : AppConfig.DEFAULT_BACKEND_DOMAIN;
      if (!this.validHttpUrl(downloadUrl)) {
        this.showAlert('分享软件', '暂未获取到有效下载链接，请稍后重试');
        return;
      }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const shareRecord: SharedRecord = {
        utd: 'general.hyperlink',
        content: downloadUrl,
        title: '无音影视 ' + update.version,
        description: update.content || '分享无音影视，打开链接获取最新版本'
      };
      const sharedData: SharedData = new SharedData(shareRecord);
      const controller: ShareController = new ShareController(sharedData);
      controller.on('shareCompleted', (result: ShareOperationResult): void => {
        Logger.info('MyPageShare', '系统分享完成：' + JSON.stringify(result));
      });
      controller.on('dismiss', (): void => {
        Logger.info('MyPageShare', '系统分享面板已关闭');
      });
      await controller.show(context);
      Logger.info('MyPageShare', '已调用系统分享能力，版本=' + update.version);
    } catch (error) {
      const failure: Error = new Error('分享软件失败：' + this.errorMessage(error));
      Logger.error('MyPageShare', failure.message);
      this.showAlert('分享软件', '网络异常或系统分享不可用，请稍后重试');
      throw failure;
    }
  }

  private async navigate(path: string): Promise<void> {
    try {
      await router.pushUrl(new RouteOptions(path));
      Logger.info('MyPageRoute', '页面跳转成功：' + path);
    } catch (error) {
      const detail: string = this.errorMessage(error);
      const failure: Error = new Error('页面跳转失败：' + detail);
      Logger.error('MyPageRoute', '页面跳转失败，路径=' + path + '，错误=' + detail);
      this.showAlert('页面打开失败', '当前页面暂时无法打开，请稍后重试');
      throw failure;
    }
  }

  private openManagement(tab: number): void {
    AppStorage.setOrCreate<number>('manageInitialTab', Math.max(0, Math.trunc(tab)));
    AppState.go('manage');
    Logger.info('MyPageRoute', '打开文件管理，Tab=' + String(tab));
  }

  private openHistory(): void {
    this.openManagement(0);
  }

  private openFeedback(): void {
    router.pushUrl(new MessageRouteOptions('反馈')).catch((error: Error) => {
      Logger.error('MyPageRoute', '打开意见反馈失败：' + String(error));
      this.showAlert('意见反馈', '消息中心暂时无法打开，请稍后重试');
    });
  }

  private async onFeatureClick(item: FeatureItem): Promise<void> {
    switch (item.key) {
      case 'theme':
        await this.navigate('pages/ThemeStorePage');
        break;
      case 'live':
        await this.navigate('pages/LiveTvPage');
        break;
      case 'message':
        await this.navigate('pages/MessagePage');
        break;
      case 'forum':
        await this.navigate('pages/ForumPage');
        break;
      case 'ranking':
        this.showAlert('榜单排行', '榜单数据正在准备中，请稍后再试');
        break;
      case 'wallet':
        this.showAlert('我的钱包', this.loggedIn ? '当前金币：' + String(this.userInfo.goldCoin) + '，可在签到与论坛互动中获得' :
          '请先登录后查看金币');
        break;
      case 'vipRenew':
        this.showAlert('会员状态', this.loggedIn ? this.displayVipStatus() + ' · ' + this.displayVipExpire() :
          '请先登录后查看会员状态');
        break;
      case 'notice':
        await this.navigate('pages/MessagePage');
        break;
      case 'favorite':
        this.openManagement(1);
        break;
      case 'download':
        this.openManagement(2);
        break;
      case 'manage':
        this.openManagement(0);
        break;
      case 'extension':
        this.showExtensionDialog();
        break;
      case 'share':
        await this.shareAppClick();
        break;
      case 'permission':
        await this.checkPermissionClick();
        break;
      case 'update':
        await this.showUpdateInfo();
        break;
      case 'about':
        this.showAlert('关于我们', '无音影视致力于提供简洁、稳定的观影体验');
        break;
      default:
        Logger.warn('MyPageBusiness', '未识别的功能入口：' + item.key);
        break;
    }
  }

  private async showUpdateInfo(): Promise<void> {
    try {
      const update: RemoteUpdate = await CommunityApi.remoteUpdate();
      this.showAlert('版本信息', '当前版本 ' + update.version + String.fromCharCode(10) + update.content);
      Logger.info('MyPageBusiness', '读取远程版本信息成功：' + update.version);
    } catch (error) {
      Logger.warn('MyPageBusiness', '读取远程版本信息失败：' + String(error));
      this.showAlert('版本信息', '暂时无法获取版本信息，请稍后重试');
    }
  }

  private updateViewportWidth(value: number | string): void {
    const measuredWidth: number = Number(value);
    if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
      this.viewportWidth = measuredWidth;
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  /** 玻璃材质半径：全局沉浸强度变化时所有卡片同步变糊或变清。 */
  private glassBlurRadius(): number {
    const materialOn: boolean = this.immersiveConfig.immersiveEnable;
    const configured: number = this.glassRadius();
    return Ui.glassBlur(materialOn, configured);
  }

  /** 内容最大宽度：宽屏居中限宽，手机占满可用宽度（左右留白由 pagePadding 提供）。 */
  private contentMaxWidth(): number {
    const availableWidth: number = Number.isFinite(this.viewportWidth) && this.viewportWidth > 0 ? this.viewportWidth : 360;
    const gutter: number = Ui.gutter(availableWidth);
    const limit: number = Math.min(availableWidth, 1180);
    return Math.min(availableWidth, limit + gutter * 2);
  }

  private avatarSize(): number {
    return this.tablet() ? 76 : 66;
  }

  private iconBlockSize(): number {
    return this.tablet() ? 46 : 40;
  }

  /** 右上设置入口：沿用底部导航既有的"设置"页路由。 */
  private openSettings(): void {
    AppState.go('settings');
  }

  private safeTop(): number {
    const status: number = Number.isFinite(this.statusBarInset) ? Math.max(0, this.statusBarInset) : 24;
    const cutout: number = Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
    return Math.max(status, cutout);
  }

  private safeBottom(): number {
    return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16;
  }

  private pagePadding(): EdgePadding {
    // 底部不再预留底栏 / 手势条 / 模糊带的避让高度：内容铺到屏幕最底部，
    // 悬浮玻璃底栏只叠加显示（向下滚动时它会自动隐藏），避免底部出现大片空白。
    const horizontal: string = Ui.gutter(this.viewportWidth) + 'vp';
    return new EdgePadding(this.safeTop() + 'vp', '0vp', horizontal, horizontal);
  }

  private pageBackgroundColor(): ResourceColor {
    // 页面底色使用主题资源：深色 #FF212121，浅色 #FFFFFFFF。
    return Ui.pageBg(this.darkTheme);
  }

  private textColor(): ResourceColor {
    return Ui.ink(this.darkTheme);
  }

  private secondaryTextColor(): ResourceColor {
    return Ui.inkSoft(this.darkTheme);
  }

  private accentColor(): ResourceColor {
    return Ui.accent(this.darkTheme);
  }

  private cardColor(): ResourceColor {
    return Ui.card(this.darkTheme);
  }

  private symbolColor(color: ResourceColor): ResourceColor[] {
    return [color];
  }

  private glassRadius(): number {
    if (!this.immersiveConfig.immersiveEnable) {
      return 0;
    }
    const configuredBlur: number = Number(this.immersiveConfig.immersiveBlur);
    return Number.isFinite(configuredBlur) ? Math.max(0, Math.min(100, configuredBlur)) : 0;
  }

  private displayVipStatus(): string {
    if (!this.loggedIn) {
      return '请先登录查看会员状态';
    }
    return this.userInfo.vipStatus.trim() || '普通用户';
  }

  private displayVipExpire(): string {
    if (!this.loggedIn) {
      return '登录后查看到期时间';
    }
    return this.formatDateCn(this.userInfo.vipExpireTime.trim() || '暂无到期时间');
  }

  // ---------------- 视觉层：液态玻璃 ----------------
  // 以下 Builder 只负责"长什么样"：玻璃底、描边、投影、圆角、间距、字号。
  // 所有状态读取、点击回调、弹窗与路由都沿用原有实现，未新增业务分支。

  /** 圆形头像：品牌渐变外环 + 玻璃内盘，有头像用图片，没有则用人物符号。 */
  @Builder
  private avatarBlock() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width((this.avatarSize() + 6) + 'vp')
        .height((this.avatarSize() + 6) + 'vp')
        .borderRadius(((this.avatarSize() + 6) / 2) + 'vp')
        .linearGradient({
          angle: 145,
          colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
        })
        .shadow({ radius: 16, color: Ui.accentGlow(this.darkTheme), offsetY: 6 })
      if (this.userInfo.avatarUrl.trim()) {
        Image(this.userInfo.avatarUrl)
          .width(this.avatarSize() + 'vp')
          .height(this.avatarSize() + 'vp')
          .objectFit(ImageFit.Cover)
          .borderRadius((this.avatarSize() / 2) + 'vp')
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(Ui.fs((this.avatarSize() * 0.46) + 'vp', this.fontScale))
            .fontColor(this.symbolColor(this.accentColor()))
        }
          .width(this.avatarSize() + 'vp')
          .height(this.avatarSize() + 'vp')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .borderRadius((this.avatarSize() / 2) + 'vp')
          .backgroundColor(this.pageBackgroundColor())
      }
    }
      .width((this.avatarSize() + 6) + 'vp')
      .height((this.avatarSize() + 6) + 'vp')
      .onClick(() => { void this.pickAvatar(); })
  }

  /** 把相册 URI 拷进应用缓存目录，返回真实文件路径（上传用）。 */
  private copyUriToCache(context: common.UIAbilityContext, uri: string): string {
    const target: string = context.cacheDir + '/avatar_' + String(Date.now()) + '.jpg';
    const source: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.copyFileSync(source.fd, target);
    } finally {
      fileIo.closeSync(source);
    }
    Logger.info('MY_PAGE', '头像已缓存：' + target);
    return target;
  }

  @Builder
  private nickDialog() {
    Column({ space: '12vp' }) {
      Text('修改昵称')
        .fontSize(Ui.fs('16vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      TextInput({ text: this.nickDraft, placeholder: '输入新昵称' })
        .width('100%')
        .height('44vp')
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .borderRadius('12vp')
        .onChange((value: string) => { this.nickDraft = value; })
      Row({ space: '10vp' }) {
        GhostButton({ label: '取消', compact: true, onTap: (): void => { this.showNickDialog = false; } })
        Blank()
        PrimaryButton({ label: '保存', compact: true, onTap: (): void => { void this.saveNickname(); } })
      }
        .width('100%')
    }
      .width('86%')
      .constraintSize({ maxWidth: '420vp' })
      .padding('18vp')
      .borderRadius('18vp')
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
  }

  private toastNotice(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message }); }
    catch (error) { Logger.warn('MY_PAGE', String(error)); }
  }

  /** 点头像：系统相册选图 → 上传到 /uploadportrait.php → 刷新头像。 */
  /**
   * 点头像：官方示例（云逸全功能对接）用的是 hw(userportrait.php?...)，即浏览器打开上传页，
   * 这里同样用系统浏览器打开，上传完回到「我的」刷新即可。
   */
  /** 点头像：系统相册选图 → 拷进沙箱 → 上传到 portraitupload.php?admin&user&pass。 */
  /** 点头像：系统相册选图 → 拷进沙箱 → 手工 multipart 上传到 portraitupload.php。 */
  private async pickAvatar(): Promise<void> {
    try {
      if (this.accountName.length === 0) {
        this.toastNotice('请先登录后再修改头像');
        return;
      }
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      PlatformApi.setMaxSelectNumber(options as Object, 1);
      
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) { return; }
      const uri: string = result.photoUris[0];
      this.toastNotice('正在上传头像…');
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const localPath: string = this.copyUriToCache(context, uri);
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      const pass: string = String(await store.get('$pass', ''));
      const fileName: string = localPath.substring(localPath.lastIndexOf('/') + 1);
      const message: string = await AccountApi.uploadPortrait(context, this.accountName, pass, fileName);
      this.userInfo.avatarUrl = AccountApi.portraitUrl(this.accountName) + '&t=' + String(Date.now());
      const ok: boolean = message.indexOf('上传成功') >= 0 || message.indexOf('"code":200') >= 0;
      this.toastNotice(ok ? '头像已更新' : '上传结果：' + message.substring(0, 40));
    } catch (error) {
      Logger.error('MY_PAGE', '更换头像失败：' + String(error));
      this.toastNotice('更换头像失败：' + String(error));
    }
  }

  /** 会员标签：金色玻璃胶囊，文案取自原有的 displayVipStatus()。 */
  @Builder
  private memberTag() {
    Row({ space: 4 }) {
      Text('★')
        .fontSize(Ui.fs('9vp', this.fontScale))
        .fontColor(Ui.gold(this.darkTheme))
      Text(this.displayVipStatus())
        .fontSize(Ui.fs(this.tablet() ? '12vp' : '11vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.gold(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .height('22vp')
      .padding({ left: '9vp', right: '9vp' })
      .borderRadius('11vp')
      .backgroundColor(Ui.goldSoft(this.darkTheme))
      .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
      .alignSelf(ItemAlign.Start)
  }

  /** 数据摘要单元：数值 + 说明，全部取自原有状态（动态数 / 金币 / 等级）。 */
  @Builder
  private summaryCell(value: string, label: string, onTap: () => void = (): void => {}) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(Ui.fs(this.tablet() ? '22vp' : '19vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(Ui.fs(this.tablet() ? '12vp' : '11vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .maxLines(1)
    }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => { onTap(); })
  }

  /** 数据摘要：一条玻璃底的三段统计，与用户卡同属"个人数据"分组。 */
  @Builder
  private summaryRow() {
    Row() {
      this.summaryCell(String(this.statPosts), '帖子', (): void => { this.openForumPage(); });
      Column()
        .width('1vp')
        .height('26vp')
        .backgroundColor(Ui.divider(this.darkTheme))
      this.summaryCell(String(this.statCoins), '金币', (): void => { this.openAccountCenter(); });
      Column()
        .width('1vp')
        .height('26vp')
        .backgroundColor(Ui.divider(this.darkTheme))
      this.summaryCell(this.statGradeLabel(), '等级', (): void => { this.openTitleRank(); });
      Column()
        .width('1vp')
        .height('26vp')
        .backgroundColor(Ui.divider(this.darkTheme))
      this.summaryCell(String(this.statFollows), '关注', (): void => { this.openFollowList(); });
      Column()
        .width('1vp')
        .height('26vp')
        .backgroundColor(Ui.divider(this.darkTheme))
      this.summaryCell(String(this.statFans), '粉丝', (): void => { this.openFollowList(); });
    }
      .width('100%')
      .padding({ top: '12vp', bottom: '12vp' })
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private profileHeader() {
    Column({ space: this.tablet() ? 16 : 12 }) {
      Row({ space: this.tablet() ? 16 : 12 }) {
        this.avatarBlock()
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            Text(this.loggedIn ? (this.userInfo.nickName.trim() || '无音用户') : '登录无音影视')
              .fontSize(Ui.fs(this.tablet() ? '24vp' : '20vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.loadingUser) {
              LoadingProgress()
                .width('18vp')
                .height('18vp')
                .color(this.accentColor())
            }
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          if (this.loggedIn) {
            Text('账号：' + (this.accountName || this.userInfo.userId))
              .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
              .fontColor(Ui.inkSoft(this.darkTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (this.userInfo.signature.trim().length > 0) {
              Text(this.userInfo.signature.trim())
                .fontSize(Ui.fs(this.tablet() ? '12.5vp' : '11.5vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            this.memberTag()
          } else {
            Text('登录后同步收藏、下载与观影记录')
              .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
              .fontColor(Ui.inkSoft(this.darkTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        GlassIconButton({
          iconSize: this.tablet() ? 42 : 38,
          symbol: $r('sys.symbol.gearshape'),
          accessibilityLabel: '设置',
          onTap: (): void => { this.openSettings(); }
        })
      }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      if (this.loggedIn) {
        this.summaryRow()
        Row({ space: 10 }) {
          Text('账号安全与登录管理')
            .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Row() {
            Text('签到')
              .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
          }
            .height('34vp')
            .padding({ left: '16vp', right: '16vp' })
            .borderRadius('17vp')
            .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
            .shadow({ radius: 12, color: Ui.accentGlow(this.darkTheme), offsetY: 4 })
            .accessibilityText('签到')
            .onClick(() => { void this.signInClick(); })
          Row() {
            Text('退出登录')
              .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
              .fontColor(Ui.danger(this.darkTheme))
              .maxLines(1)
          }
            .height('34vp')
            .padding({ left: '14vp', right: '14vp' })
            .borderRadius('17vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
            .accessibilityText('退出登录')
            .onClick(() => { this.confirmLogout(); })
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: 6 }) {
          Text('立即登录')
            .fontSize(Ui.fs(this.tablet() ? '14vp' : '13vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
          Text('›')
            .fontSize(Ui.fs('15vp', this.fontScale))
            .fontColor('#FFFFFF')
        }
          .height('36vp')
          .padding({ left: '16vp', right: '14vp' })
          .borderRadius('18vp')
          .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
          .shadow({ radius: 14, color: Ui.accentGlow(this.darkTheme), offsetY: 5 })
          .alignSelf(ItemAlign.Start)
          .accessibilityText('立即登录')
      }
    }
      .width('100%')
      .padding(this.tablet() ? '22vp' : '18vp')
      .linearGradient({ angle: 135, colors: this.profileGradientColors() })
      .border({ width: 1, color: this.profileCardBorderColor() })
      .borderRadius(Ui.R_XL)
      .shadow({ radius: 22, color: Ui.shadowSoft(this.darkTheme), offsetY: 10 })
      .backdropBlur(this.glassBlurRadius())
      .clip(true)
      .onClick(() => {
        if (!this.loggedIn) {
          this.showLoginPanel();
        }
      });
  }

  @Builder
  private loginPanel() {
    Column() {
      Column()
        .width('44vp')
        .height('4vp')
        .backgroundColor(Ui.glassRing(this.darkTheme))
        .borderRadius('2vp')
        .margin({ bottom: '20vp' });
      Row({ space: 14 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(Ui.fs('28vp', this.fontScale))
            .fontColor(this.symbolColor(this.accentColor()));
        }
          .width('56vp')
          .height('56vp')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Ui.accentSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
          .borderRadius('28vp');
        Column({ space: 6 }) {
          Text('登录无音影视')
            .fontSize(Ui.fs('21vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme));
          Text('登录后解锁完整的个人中心体验')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.darkTheme));
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: '2vp' });
      }
        .width('100%');
      Text('同步收藏、下载和观影记录，换设备也能继续使用')
        .fontSize(Ui.fs(this.tablet() ? '14vp' : '13vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
        .margin({ top: '18vp', bottom: '18vp' });
      Row() {
        Text('立即登录')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
      }
        .width('100%')
        .height('48vp')
        .justifyContent(FlexAlign.Center)
        .borderRadius('24vp')
        .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
        .shadow({ radius: 16, color: Ui.accentGlow(this.darkTheme), offsetY: 6 })
        .accessibilityText('立即登录')
        .onClick(() => {
          void this.openLoginFromPanel();
        });
      Row() {
        Text('暂不登录')
          .fontSize(Ui.fs('14vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .height('44vp')
        .justifyContent(FlexAlign.Center)
        .borderRadius('22vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
        .margin({ top: '8vp' })
        .accessibilityText('暂不登录')
        .onClick(() => {
          this.closeLoginPanel();
        });
    }
      .width('100%')
      .constraintSize({ maxWidth: 640 })
      .padding({ left: '22vp', right: '22vp', top: '16vp', bottom: (this.safeBottom() + 22) + 'vp' })
      .backgroundColor(this.loginPanelBackground())
      .border({ width: 1, color: this.loginPanelBorderColor() })
      .borderRadius('28vp')
      .backdropBlur(this.loginPanelBlur())
      .clip(true)
      .translate({ y: this.loginPanelOffset + 'vp' });
  }

  @Builder
  private membershipCard() {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Text(this.displayVipStatus())
          .fontSize(Ui.fs(this.tablet() ? '19vp' : '17vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.displayVipExpire())
          .fontSize(Ui.fs(this.tablet() ? '13vp' : '12vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      Row({ space: 5 }) {
        Text('会员特权')
          .fontSize(Ui.fs(this.tablet() ? '13vp' : '12vp', this.fontScale))
          .fontColor(Ui.accent(this.darkTheme))
          .maxLines(1);
        Text('›')
          .fontSize(Ui.fs('15vp', this.fontScale))
          .fontColor(Ui.accent(this.darkTheme));
      }
        .height('30vp')
        .padding({ left: '12vp', right: '11vp' })
        .borderRadius('15vp')
        .backgroundColor(Ui.accentSoft(this.darkTheme))
        .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
        .accessibilityText('会员特权')
        .onClick(() => {
          this.showAlert('会员特权', '会员特权内容即将开放');
        });
    }
      .width('100%')
      .padding(this.tablet() ? '20vp' : '16vp')
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .borderRadius(Ui.R_LG)
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .backdropBlur(this.glassBlurRadius())
      .clip(true)
  }

  /** 功能宫格单元：玻璃 icon 块 + 标题 + 副标题，图标与回调来自 FeatureItem。 */
  @Builder
  private featureCell(item: FeatureItem) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(this.iconBlockSize() + 'vp')
          .height(this.iconBlockSize() + 'vp')
          .borderRadius('14vp')
          .linearGradient({
            angle: 145,
            colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.glassTintStrong(this.darkTheme), 1]]
          })
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .shadow({ radius: 8, color: Ui.shadowSoft(this.darkTheme), offsetY: 3 })
        SymbolGlyph(item.symbol)
          .fontSize(Ui.fs((this.iconBlockSize() * 0.46) + 'vp', this.fontScale))
          .fontColor(this.symbolColor(this.accentColor()))
        if (item.key === 'message' && this.newsCount > 0) {
          Text(this.newsCount > 99 ? '99+' : String(this.newsCount))
            .fontSize(Ui.fs('9vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .height('18vp')
            .constraintSize({ minWidth: '18vp' })
            .padding({ left: '4vp', right: '4vp' })
            .borderRadius('9vp')
            .backgroundColor(Ui.danger(this.darkTheme))
            .textAlign(TextAlign.Center)
            .align(Alignment.TopEnd)
        }
      }
        .width(this.iconBlockSize() + 'vp')
        .height(this.iconBlockSize() + 'vp')
      Text(item.title)
        .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.subtitle)
        .fontSize(Ui.fs(this.tablet() ? '11vp' : '10vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .width('100%')
      .height('100%')
      .padding({ top: '9vp', bottom: '9vp', left: '4vp', right: '4vp' })
      .justifyContent(FlexAlign.Center)
      .borderRadius(Ui.R_MD)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 10, color: Ui.shadowSoft(this.darkTheme), offsetY: 5 })
      .accessibilityText(item.title + '，' + item.subtitle)
      .onClick(() => {
        void this.onFeatureClick(item);
      })
  }

  @Builder
  private featureGrid(items: FeatureItem[]) {
    Grid() {
      ForEach(items, (item: FeatureItem) => {
        GridItem() {
          this.featureCell(item);
        }
      }, (item: FeatureItem) => item.key);
    }
      .width('100%')
      .height(this.tablet() ? '128vp' : '116vp')
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(this.tablet() ? 12 : 9)
      .rowsGap(this.tablet() ? 12 : 9)
  }

  /** 分组列表行：玻璃卡内 52vp 行高，左 icon + 标题 + 副标题 + 右箭头。 */
  @Builder
  private groupRow(item: FeatureItem) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('34vp')
          .height('34vp')
          .borderRadius('12vp')
          .linearGradient({
            angle: 145,
            colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.glassTintStrong(this.darkTheme), 1]]
          })
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
        SymbolGlyph(item.symbol)
          .fontSize(Ui.fs('17vp', this.fontScale))
          .fontColor(this.symbolColor(this.accentColor()))
      }
        .width('34vp')
        .height('34vp')
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(Ui.fs(this.tablet() ? '15vp' : '13.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.subtitle)
          .fontSize(Ui.fs(this.tablet() ? '11.5vp' : '10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(Ui.fs('20vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
    }
      .width('100%')
      .height('52vp')
      .padding({ left: '14vp', right: '14vp' })
      .alignItems(VerticalAlign.Center)
      .accessibilityText(item.title + '，' + item.subtitle)
      .onClick(() => {
        void this.onFeatureClick(item);
      })
  }

  @Builder
  private groupCard(items: FeatureItem[]) {
    Column() {
      ForEach(items, (item: FeatureItem, index: number) => {
        Column() {
          this.groupRow(item)
          if (index < items.length - 1) {
            Row() {
              Row()
                .width('100%')
                .height('1vp')
                .backgroundColor(Ui.divider(this.darkTheme))
            }
              .width('100%')
              .padding({ left: '60vp', right: '14vp' })
          }
        }
          .width('100%')
      }, (item: FeatureItem, index: number) => 'group-' + item.key + '-' + index)
    }
      .width('100%')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .clip(true)
  }

  @Builder
  private toolsSection() {
    Column({ space: 10 }) {
      SectionHeader({ title: '常用功能', viewportWidth: this.viewportWidth })
      this.featureGrid(this.firstRow);
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private contentSection() {
    Column({ space: 10 }) {
      SectionHeader({ title: '我的内容', viewportWidth: this.viewportWidth })
      this.groupCard(this.secondRow);
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private moreSection() {
    Column({ space: 10 }) {
      SectionHeader({ title: '更多服务', viewportWidth: this.viewportWidth })
      this.groupCard(this.thirdRow);
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private feedbackCard() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('38vp')
          .height('38vp')
          .borderRadius('13vp')
          .backgroundColor(Ui.accentSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontColor(this.symbolColor(this.accentColor()))
      }
        .width('38vp')
        .height('38vp')
      Column({ space: 4 }) {
        Text('意见反馈')
          .fontSize(Ui.fs(this.tablet() ? '15vp' : '13.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
        Text('帮助我们持续改进无音影视')
          .fontSize(Ui.fs(this.tablet() ? '11.5vp' : '10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Text('去反馈')
        .fontSize(Ui.fs(this.tablet() ? '13vp' : '12vp', this.fontScale))
        .fontColor(Ui.accent(this.darkTheme))
        .maxLines(1)
      Text('›')
        .fontSize(Ui.fs('20vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '16vp')
      .alignItems(VerticalAlign.Center)
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .accessibilityText('意见反馈')
      .onClick(() => {
        void this.openFeedback();
      });
  }

  @Builder
  private statisticsFooter() {
    Column({ space: 6 }) {
      Text('服务状态')
        .fontSize(Ui.fs(this.tablet() ? '15vp' : '14vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
      if (this.globalStatAvailable) {
        Text('云逸服务当前在线 ' + String(this.globalStat.onlineCount) + ' 人' +
          (this.loggedIn ? ' · 我的帖子 ' + String(this.userInfo.postCount) : ''))
          .fontSize(Ui.fs(this.tablet() ? '12.5vp' : '11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
          .textAlign(TextAlign.Center);
      } else {
        Text('暂无统计数据')
          .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme));
        Text('网络请求失败，稍后再试')
          .fontSize(Ui.fs(this.tablet() ? '12vp' : '11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme));
      }
    }
      .width('100%')
      .padding(this.tablet() ? '20vp' : '18vp')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(Ui.R_LG)
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  build() {
    Stack() {
      // 底层：主题资源底色（深 #FF212121 / 浅 #FFFFFFFF）+ 低强度极光柔光
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackgroundColor())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.42 : 0.55 })
      Scroll(this.pageScroller) {
        Row() {
          Column({ space: this.tablet() ? 18 : 14 }) {
            this.profileHeader();
            this.membershipCard();
            this.toolsSection();
            this.contentSection();
            this.moreSection();
            this.feedbackCard();
            this.statisticsFooter();
          }
            .width('100%')
            .constraintSize({ maxWidth: this.contentMaxWidth() })
            .padding(this.pagePadding())
            .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .justifyContent(FlexAlign.Center)
      }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .onScrollStart(() => { NavigationScroll.begin('mine', 'content', this.pageScroller); })
        .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
          NavigationScroll.report('mine', 'content', this.pageScroller, scrollState);
        })
        .onScrollStop(() => { NavigationScroll.end('mine', 'content', this.pageScroller); })
        .opacity(this.pageOpacity)
        .onAreaChange((_oldValue, newValue) => {
        let measuredWidth: number = 0;
        const widthValue: Length = newValue.width;
        if (typeof widthValue === 'number') {
          measuredWidth = widthValue;
        } else if (typeof widthValue === 'string') {
          const widthText: string = widthValue as string;
          measuredWidth = Number(widthText);
        }
        if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
          this.updateViewportWidth(measuredWidth);
        }
      });
      if (this.showNickDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.loginPanelMaskColor())
            .onClick(() => { this.showNickDialog = false; })
          this.nickDialog()
        }
          .width('100%')
          .height('100%')
          .zIndex(11)
      }
      if (this.loginPanelVisible) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.loginPanelMaskColor())
            .onClick(() => {
            this.closeLoginPanel();
          });
          this.loginPanel();
        }
          .width('100%')
          .height('100%')
          .zIndex(10);
      }
    }
      .width('100%')
      .height('100%');
  }

  /** 把日期格式化成 年月日。 */
  private formatDateCn(text: string): string {
    const value: string = (text || '').trim();
    if (value.length === 0 || value.indexOf('暂无') >= 0) { return value; }
    const matched: RegExpMatchArray | null = value.match(/(\d{4})-(\d{1,2})-(\d{1,2})(.*)/);
    if (matched === null || matched.length < 4) { return value; }
    const rest: string = matched.length > 4 ? matched[4].trim() : '';
    return matched[1] + '年' + matched[2] + '月' + matched[3] + '日' + (rest.length > 0 ? ' ' + rest : '');
  }

  /** 金币 → 账号中心。 */
  private openAccountCenter(): void {
    if (!this.loggedIn) { this.toastNotice('请先登录后查看金币'); return; }
    router.pushUrl({ url: 'pages/AccountCenterPage' }).catch((error: Error) => {
      Logger.error('MY_PAGE', '打开账号中心失败：' + String(error));
    });
  }

  /** 等级 → 全部头衔排行。 */
  private openTitleRank(): void {
    const level: number = UserTitles.levelOf(this.userInfo.grade, this.userInfo.userId);
    const params: Record<string, string> = { 'level': String(level) };
    router.pushUrl({ url: 'pages/TitleRankPage', params: params }).catch((error: Error) => {
      Logger.error('MY_PAGE', '打开头衔排行失败：' + String(error));
    });
  }

  /** 帖子 → 交流论坛。 */
  private openForumPage(): void {
    router.pushUrl({ url: 'pages/ForumPage' }).catch((error: Error) => {
      Logger.error('MY_PAGE', '打开论坛失败：' + String(error));
    });
  }

  /** 打开关注 / 粉丝列表。 */
  /** 等级文案（统计条专用）：纯数字 grade → Lv.N。 */
  private statGradeLabel(): string {
    const grade: string = this.statGrade.trim();
    if (grade.length === 0) { return 'Lv.0'; }
    const matched: RegExpMatchArray | null = grade.match(/^\d+$/);
    return matched !== null ? 'Lv.' + grade : grade;
  }

  private openFollowList(): void {
    router.pushUrl({ url: 'pages/FollowListPage' }).catch((error: Error) => {
      Logger.error('MY_PAGE', '打开关注列表失败：' + String(error));
    });
  }

  /** 保存昵称：username.php。 */
  private async saveNickname(): Promise<void> {
    const name: string = this.nickDraft.trim();
    if (name.length === 0) {
      this.toastNotice('昵称不能为空');
      return;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      const pass: string = String(await store.get('$pass', ''));
      const message: string = await AccountApi.setNickname(this.accountName, pass, name);
      this.userInfo.nickName = name;
      this.showNickDialog = false;
      this.toastNotice(message.length > 0 ? message : '昵称已修改');
    } catch (error) {
      this.toastNotice('修改失败：' + String(error));
    }
  }

  /** 等级文案：grade 是纯数字时显示 Lv.N，否则原样显示。 */
  private levelLabel(): string {
    const grade: string = this.userInfo.grade.trim();
    if (grade.length === 0) { return 'Lv.0'; }
    const matched: RegExpMatchArray | null = grade.match(/^\d+$/);
    return matched !== null ? 'Lv.' + grade : grade;
  }
}

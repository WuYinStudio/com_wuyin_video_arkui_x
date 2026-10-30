import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { TencentSDK, TencentAuthorizationResult, TencentProvider } from '../common/TencentSdkService';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

interface TencentProfileResponse {
  nickname?: string;
  figureurl_qq_2?: string;
  figureurl_2?: string;
  figureurl?: string;
  ret?: number;
  msg?: string;
}

interface LoginTencentProfile {
  nickname: string;
  avatar: string;
}

interface HuaweiAuthResponseData {
  authorizationCode?: string;
}

interface HuaweiAuthResponseBridge {
  authorizationCode?: string;
  data?: HuaweiAuthResponseData;
}

interface HuaweiBackendUserInfo {
  user: string;
  pass: string;
  nickname: string;
  avatar: string;
}

interface LoginStatusResponse {
  status?: string | number;
  code?: string | number;
  result?: string | number;
}

@Entry
@Component
struct LoginPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @State private account: string = '';
  @State private password: string = '';
  @State private isLoading: boolean = false;
  @State private pageOpacity: number = 0;
  @State private pageOffset: number = 28;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private focusedField: string = '';
  @State private viewportWidth: number = 360;
  @State private primaryPressed: boolean = false;

  aboutToAppear(): void {
    // 注册成功后带回的账号，直接预填，省得用户再输一次。
    try {
      const pending: string = AppStorage.get<string>('pendingLoginUser') || '';
      if (pending.length > 0) {
        this.account = pending;
        AppStorage.delete('pendingLoginUser');
      }
    } catch (_) { Logger.warn('LOGIN', '读取待登录账号失败'); }

    this.startEnterAnimation();
    void this.applyImmersiveConfig();
    void this.preparePage();
  }

  private startEnterAnimation(): void {
    this.pageOpacity = 0;
    this.pageOffset = 28;
    animateTo({
      duration: 460,
        curve: Curve.EaseOut
    }, () => {
      this.pageOpacity = 1;
      this.pageOffset = 0;
    });
  }

  private async applyImmersiveConfig(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const currentWindow: window.Window = await window.getLastWindow(context);
      await currentWindow.setWindowLayoutFullScreen(true);
      await currentWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          isStatusBarLightIcon: false,
          isNavigationBarLightIcon: false,
          enableStatusBarAnimation: true,
          enableNavigationBarAnimation: true
      });
      Logger.debug('LOGIN', 'immersiveConfig已应用');
    } catch (error) {
      Logger.warn('LOGIN', 'immersiveConfig应用失败：' + this.errorMessage(error));
    }
  }

  private async preparePage(): Promise<void> {
    try {
      const config: AppConfig = AppConfig.getInstance();
      if (!config.isInitialized()) {
        Logger.error('LOGIN', 'AppConfig实例尚未初始化');
        this.showAlert('后端配置异常', '后端配置尚未初始化，请稍后重试');
        return;
      }
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      this.account = String(await store.get('$user', ''));
      this.password = String(await store.get('$pass', ''));
      Logger.debug('LOGIN', '已读取本地登录凭证');
    } catch (error) {
      Logger.error('LOGIN', '读取本地登录凭证失败：' + this.errorMessage(error));
      this.showAlert('读取失败', this.errorMessage(error));
    }
  }

  private validateAccountAndPassword(): boolean {
    const currentAccount: string = this.account.trim();
    const currentPassword: string = this.password;
    if (!currentAccount || !currentPassword) {
      this.showAlert('登录提示', '账号和密码不能为空');
      return false;
    }
    if (currentAccount.length < 6 || currentPassword.length < 6) {
      this.showAlert('登录提示', '账号和密码长度必须不少于6位');
      return false;
    }
    return true;
  }

  private async loginByPassword(): Promise<void> {
    if (this.isLoading || !this.validateAccountAndPassword()) {
      return;
    }
    const config: AppConfig = AppConfig.getInstance();
    if (!config.isInitialized()) {
      this.showAlert('后端配置异常', '后端配置尚未初始化，请稍后重试');
      return;
    }
    this.isLoading = true;
    try {
      const user: string = this.account.trim();
      const pass: string = this.password;
      const loginUrl: string = this.buildBackendUrl('userlogin.php', user, pass);
      Logger.info('LOGIN', '发起账号密码登录请求：' + this.safeLogUrl(loginUrl));
      const loginText: string = await this.requestText(loginUrl);
      Logger.info('LOGIN', '账号密码登录返回：' + loginText);
      if (!this.isSuccessResponse(loginText)) {
        this.showAlert('登录失败', loginText || '账号或密码错误');
        return;
      }
      const nickname: string = await this.requestUserNickname(config, user, pass);
      const avatar: string = await this.requestUserPortrait(config, user, pass);
      await this.saveCredentials(user, pass, nickname, avatar);
      await this.replaceToMyPage();
    } catch (error) {
      Logger.error('LOGIN', '账号密码登录异常：' + this.errorMessage(error));
      this.showAlert('登录异常', this.errorMessage(error));
    } finally {
      this.isLoading = false;
    }
  }

  private async requestUserNickname(config: AppConfig, user: string, pass: string): Promise<string> {
    const url: string = this.buildBackendUrlWithCredentials(config, 'echouserdata.php', user, pass);
    Logger.debug('LOGIN', '请求用户昵称：' + this.safeLogUrl(url));
    const text: string = await this.requestText(url);
    Logger.debug('LOGIN', '用户昵称返回：' + text);
    return text.trim();
  }

  private async requestUserPortrait(config: AppConfig, user: string, pass: string): Promise<string> {
    const url: string = this.buildBackendUrlWithCredentials(config, 'echoportrait.php', user, pass);
    Logger.debug('LOGIN', '请求用户头像：' + this.safeLogUrl(url));
    const text: string = await this.requestText(url);
    Logger.debug('LOGIN', '用户头像返回：' + text);
    return text.trim();
  }

  private async requestText(url: string): Promise<string> {
    let request: http.HttpRequest | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
          connectTimeout: 30000,
          readTimeout: 30000
      });
      const text: string = String(response.result);
      Logger.debug('LOGIN_HTTP', 'HTTP返回码：' + String(response.responseCode));
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(text || ('HTTP请求失败，状态码：' + String(response.responseCode)));
      }
      return text;
    } catch (error) {
      Logger.error('LOGIN_HTTP', 'HTTP请求异常：' + this.errorMessage(error));
      throw new Error(this.errorMessage(error));
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  private buildBackendUrl(path: string, user: string, pass: string): string {
    const config: AppConfig = AppConfig.getInstance();
    return this.buildBackendUrlWithCredentials(config, path, user, pass);
  }

  private buildBackendUrlWithCredentials(config: AppConfig, path: string, user: string, pass: string): string {
    const domain: string = config.backendDomain.replace(/\/+$/, '');
    const admin: string = encodeURIComponent(config.backendAccount);
    const encodedUser: string = encodeURIComponent(user);
    const encodedPass: string = encodeURIComponent(pass);
    return domain + '/' + path + '?admin=' + admin + '&user=' + encodedUser + '&pass=' + encodedPass;
  }

  private buildTencentLoginUrl(config: AppConfig, user: string, pass: string): string {
    return this.buildBackendUrlWithCredentials(config, 'userlogin.php', user, pass);
  }

  private buildTencentRegisterUrl(config: AppConfig, user: string, pass: string): string {
    return this.buildBackendUrlWithCredentials(config, 'userregister.php', user, pass);
  }

  private async loginByTencent(provider: TencentProvider): Promise<void> {
    if (this.isLoading) {
      return;
    }
    const config: AppConfig = AppConfig.getInstance();
    if (!config.isInitialized()) {
      this.showAlert('后端配置异常', '后端配置尚未初始化，请稍后重试');
      return;
    }
    this.isLoading = true;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      Logger.info('LOGIN', '开始' + provider + ' SDK授权');
      const authorization: TencentAuthorizationResult = await TencentSDK.authorize(context, provider);
      if (!authorization.openid || !authorization.accessToken) {
        throw new Error(provider + '授权未返回openid或access_token');
      }
      Logger.info('LOGIN', provider + '授权成功，openid已获取');
      const profile: LoginTencentProfile = await this.requestTencentProfile(config, provider, authorization);
      const internalUser: string = this.createInternalUser(provider, authorization.openid);
      const internalPass: string = this.createInternalPassword(authorization.openid);
      const loginUrl: string = this.buildTencentLoginUrl(config, internalUser, internalPass);
      const loginText: string = await this.requestText(loginUrl);
      Logger.info('LOGIN', provider + '内部登录返回：' + loginText);
      if (!this.isSuccessResponse(loginText)) {
        const registerUrl: string = this.buildTencentRegisterUrl(config, internalUser, internalPass);
        const registerText: string = await this.requestText(registerUrl);
        Logger.info('LOGIN', provider + '自动注册返回：' + registerText);
        if (!this.isSuccessResponse(registerText)) {
          throw new Error(registerText || loginText || (provider + '登录注册失败'));
        }
      }
      await this.saveCredentials(internalUser, internalPass, profile.nickname, profile.avatar);
      await this.replaceToMyPage();
    } catch (error) {
      Logger.error('LOGIN', provider + '登录异常：' + this.errorMessage(error));
      this.showAlert(provider + '登录失败', this.errorMessage(error));
    } finally {
      this.isLoading = false;
    }
  }

  private async requestTencentProfile(config: AppConfig, provider: TencentProvider,
    authorization: TencentAuthorizationResult): Promise<LoginTencentProfile> {
    const profile: LoginTencentProfile = {
      nickname: authorization.nickname,
        avatar: authorization.avatar
    };
    try {
      const domain: string = provider === TencentProvider.QQ ? 'https://graph.qq.com' : 'https://graph.qq.com';
      const url: string = domain + '/user/get_user_info?access_token=' + encodeURIComponent(authorization.accessToken) +
      '&oauth_consumer_key=' + encodeURIComponent(config.backendAccount) + '&openid=' + encodeURIComponent(authorization.openid);
      Logger.debug('LOGIN', provider + '请求腾讯公开用户接口');
      const text: string = await this.requestText(url);
      const response: TencentProfileResponse = JSON.parse(text) as TencentProfileResponse;
      if (response.nickname) {
        profile.nickname = response.nickname;
      }
      if (response.figureurl_qq_2) {
        profile.avatar = response.figureurl_qq_2;
      } else if (response.figureurl_2) {
        profile.avatar = response.figureurl_2;
      } else if (response.figureurl) {
        profile.avatar = response.figureurl;
      }
      Logger.debug('LOGIN', provider + '腾讯用户信息解析完成');
    } catch (error) {
      Logger.warn('LOGIN', provider + '公开用户接口失败，使用SDK资料：' + this.errorMessage(error));
    }
    return profile;
  }

  private createInternalUser(provider: TencentProvider, openid: string): string {
    const prefix: string = provider === TencentProvider.QQ ? 'qq' : 'tim';
    return prefix + '_' + this.hashOpenId(openid);
  }

  private createInternalPassword(openid: string): string {
    return 'wuyin_' + this.hashOpenId(openid) + '_login';
  }

  private hashOpenId(openid: string): string {
    let hash: number = 7;
    for (let index: number = 0; index < openid.length; index++) {
      hash = (hash * 31 + openid.charCodeAt(index)) >>> 0;
    }
    return hash.toString(36);
  }

  private loginByHuawei(): void {
    const message: string = '当前工程使用的 AccountKit 未提供可用的华为账号认证接口，请使用账号密码登录';
    Logger.warn('LOGIN', message);
    this.showAlert('华为登录暂不可用', message);
  }

  private extractHuaweiAuthorizationCode(response: HuaweiAuthResponseBridge): string {
    if (response.authorizationCode) {
      return response.authorizationCode;
    }
    if (response.data && response.data.authorizationCode) {
      return response.data.authorizationCode;
    }
    return '';
  }

  private buildHuaweiBackendUrl(config: AppConfig, authorizationCode: string): string {
    const domain: string = config.backendDomain.replace(/\/+$/, '');
    return domain + '/huaweiLogin.php?admin=' + encodeURIComponent(config.backendAccount) +
    '&authorizationCode=' + encodeURIComponent(authorizationCode);
  }

  private parseHuaweiBackendResponse(text: string): HuaweiBackendUserInfo {
    try {
      const parsed: HuaweiBackendUserInfo = JSON.parse(text) as HuaweiBackendUserInfo;
      if (!parsed.user || !parsed.pass) {
        throw new Error(text || '华为后端未返回完整用户信息');
      }
      return parsed;
    } catch (error) {
      Logger.error('LOGIN', '华为后端用户信息解析失败：' + this.errorMessage(error));
      throw new Error(this.errorMessage(error));
    }
  }

  private async saveCredentials(user: string, pass: string, nickname: string, avatar: string): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      await store.put('$user', user);
      await store.put('$pass', pass);
      await store.put('$qqname', nickname);
      await store.put('$QQimg', avatar);
      await store.flush();
      Logger.info('LOGIN', '登录凭证及用户资料已保存');
    } catch (error) {
      Logger.error('LOGIN', '保存登录凭证失败：' + this.errorMessage(error));
      throw new Error(this.errorMessage(error));
    }
  }

  /**
   * 登录成功后的返回：优先 pop 回上一级（保留来路页面与它的状态），
   * 只有在登录页是唯一页面时才用 Index 替换，绝不 clear 整个路由栈。
   */
  private async replaceToMyPage(): Promise<void> {
    try {
      if (Number(router.getLength()) > 1) {
        router.back();
        return;
      }
      await replaceRoute({ url: 'pages/Index' });
    } catch (error) {
      Logger.error('LOGIN', '登录成功后的返回失败：' + this.errorMessage(error));
      throw new Error('登录成功，但页面跳转失败：' + this.errorMessage(error));
    }
  }

  /** 返回上一级；没有上一级就回首页，避免直接退出应用。 */
  private goBack(): void {
    try {
      if (Number(router.getLength()) > 1) {
        router.back();
        return;
      }
      void replaceRoute({ url: 'pages/Index' });
    } catch (error) {
      Logger.error('LOGIN', '返回上一级失败：' + this.errorMessage(error));
    }
  }

  // 系统返回：有上一级交给系统 pop；只有本页时改为回首页，不退出应用。
  onBackPress(): boolean {
    try {
      if (Number(router.getLength()) > 1) { return false; }
      void replaceRoute({ url: 'pages/Index' });
      return true;
    } catch (error) {
      return false;
    }
  }

  private openRegisterPage(): void {
    try {
      // 已经在注册页就不再重复压栈（返回键会一级级回到登录）。
      const state = router.getState();
      if (state !== undefined && state.path === 'pages/RegisterPage') {
        return;
      }
      void router.pushUrl({ url: 'pages/RegisterPage' });
    } catch (error) {
      Logger.error('LOGIN', '跳转RegisterPage失败：' + this.errorMessage(error));
      this.showAlert('页面跳转失败', this.errorMessage(error));
    }
  }

  private isSuccessResponse(text: string): boolean {
    const normalized: string = text.trim().toLowerCase();
    if (normalized === '1' || normalized === 'ok' || normalized === 'true') {
      return true;
    }
    if (normalized.includes('success') || normalized.includes('成功') || normalized.includes('登录成功') ||
      normalized.includes('注册成功')) {
      return true;
    }
    if (normalized.startsWith('{')) {
      try {
        const parsed: LoginStatusResponse = JSON.parse(normalized) as LoginStatusResponse;
        const status: string = String(parsed.status || parsed.code || parsed.result || '');
        return status === '1' || status === '200' || status.toLowerCase() === 'success' || status === '成功';
      } catch (error) {
        Logger.warn('LOGIN', '接口JSON状态解析失败：' + this.errorMessage(error));
      }
    }
    return false;
  }

  private safeLogUrl(url: string): string {
    return url.replace(/([&?](?:pass|authorizationCode|access_token)=)[^&]*/gi, '$1***');
  }

  private errorMessage(error: Error): string {
    if (error instanceof Error) {
      return error.message || '未知错误';
    }
    return String(error) || '未知错误';
  }

  private showAlert(title: string, message: string): void {
    AlertDialog.show({
      title: title,
        message: message || '未知错误',
        autoCancel: true,
        primaryButton: {
        value: '确定',
          action: () => {
        }
      }
    });
  }

  private openAgreementPage(): void {
    try {
      const state = router.getState();
      if (state !== undefined && state.path === 'pages/UserAgreementPage') {
        return;
      }
      void router.pushUrl({ url: 'pages/UserAgreementPage' });
    } catch (error) {
      Logger.error('LOGIN', '跳转用户协议失败：' + this.errorMessage(error));
      this.showAlert('页面跳转失败', this.errorMessage(error));
    }
  }

  private updateViewport(area: Area): void {
    const measured: number = Number(area.width);
    if (measured > 0 && Math.abs(measured - this.viewportWidth) > 0.5) {
      this.viewportWidth = measured;
    }
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private tablet(): boolean {
    return Ui.isTablet(this.viewportWidth);
  }

  private gutter(): number {
    return this.tablet() ? 32 : 24;
  }

  private logoSize(): number {
    return this.tablet() ? 78 : 64;
  }

  private logoRadius(): number {
    return this.tablet() ? 24 : 20;
  }

  @Builder
  private brandHeader() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Text('无')
            .fontSize(Ui.fs(this.tablet() ? '32vp' : '28vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .letterSpacing(1)
        }
          .width(this.logoSize())
          .height(this.logoSize())
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(this.logoRadius())
          .linearGradient({
            angle: 145,
            colors: [
              [Ui.brandFrom(), 0],
              [Ui.brandMid(), 0.55],
              [Ui.brandTo(), 1]
            ]
          })
          .border({ width: 1, color: Ui.glassRing(this.dark) })
          .shadow({ radius: 24, color: Ui.accentGlow(this.dark), offsetY: 10 })
        Column()
          .width(this.logoSize() * 0.52)
          .height(this.logoSize() * 0.18)
          .borderRadius(this.logoSize() * 0.09)
          .backgroundColor(Ui.glassSheenTop(this.dark))
          .opacity(0.6)
          .blur(3)
          .translate({ x: -this.logoSize() * 0.1, y: -this.logoSize() * 0.24 })
          .hitTestBehavior(HitTestMode.None)
      }
        .width(this.logoSize())
        .height(this.logoSize())
      Column({ space: 7 }) {
        Text('无音影视')
          .fontSize(Ui.fs(this.tablet() ? '31vp' : '27vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.dark))
          .letterSpacing(0.5)
          .maxLines(1)
        Text('登录后同步您的观影记录')
          .fontSize(Ui.fs(this.tablet() ? '14vp' : '13vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.dark))
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
        .alignItems(HorizontalAlign.Center)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private loginForm() {
    Column({ space: 14 }) {
      Column({ space: 7 }) {
        Text('欢迎回来')
          .fontSize(Ui.fs(this.tablet() ? '24vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.dark))
          .width('100%')
        Text('使用账号登录您的无音影视账户')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.dark))
          .width('100%')
      }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 2 })

      TextInput({ placeholder: '请输入账号', text: this.account })
        .height(50)
        .width('100%')
        .fontSize(15)
        .fontColor(Ui.ink(this.dark))
        .placeholderColor(Ui.inkFaint(this.dark))
        .caretColor(Ui.accent(this.dark))
        .backgroundColor(Ui.glassTintSoft(this.dark))
        .borderRadius(25)
        .border({
          width: 1,
          color: this.focusedField === 'account' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
        })
        .shadow({
          radius: this.focusedField === 'account' ? 16 : 0,
          color: this.focusedField === 'account' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
          offsetY: 4
        })
        .padding({ top: 0, right: 18, bottom: 0, left: 18 })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        .onFocus(() => {
          this.focusedField = 'account';
        })
        .onBlur(() => {
          this.focusedField = '';
        })
        .onChange((value: string) => {
          this.account = value;
        })

      TextInput({ placeholder: '请输入密码', text: this.password })
        .height(50)
        .width('100%')
        .fontSize(15)
        .fontColor(Ui.ink(this.dark))
        .placeholderColor(Ui.inkFaint(this.dark))
        .caretColor(Ui.accent(this.dark))
        .backgroundColor(Ui.glassTintSoft(this.dark))
        .borderRadius(25)
        .border({
          width: 1,
          color: this.focusedField === 'password' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
        })
        .shadow({
          radius: this.focusedField === 'password' ? 16 : 0,
          color: this.focusedField === 'password' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
          offsetY: 4
        })
        .padding({ top: 0, right: 18, bottom: 0, left: 18 })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        .type(InputType.Password)
        .onFocus(() => {
          this.focusedField = 'password';
        })
        .onBlur(() => {
          this.focusedField = '';
        })
        .onChange((value: string) => {
          this.password = value;
        })

      Row() {
        if (this.isLoading) {
          LoadingProgress()
            .width('16vp')
            .height('16vp')
            .color('#FFFFFF')
            .margin({ right: 8 })
        }
        Text('登录')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
      }
        .width('100%')
        .height(50)
        .justifyContent(FlexAlign.Center)
        .borderRadius(25)
        .linearGradient({
          angle: 110,
          colors: [
            [Ui.brandFrom(), 0],
            [Ui.brandMid(), 0.55],
            [Ui.brandTo(), 1]
          ]
        })
        .shadow({ radius: 16, color: Ui.accentGlow(this.dark), offsetY: 6 })
        .enabled(!this.isLoading)
        .opacity(this.isLoading ? 0.72 : 1)
        .scale({ x: this.primaryPressed ? 0.97 : 1, y: this.primaryPressed ? 0.97 : 1 })
        .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
        .margin({ top: 4 })
        .onTouch((event: TouchEvent) => {
          this.primaryPressed = event.type === TouchType.Down;
        })
        .onClick(() => {
          void this.loginByPassword();
        })

      Row({ space: 10 }) {
        Column()
          .height(1)
          .layoutWeight(1)
          .backgroundColor(Ui.divider(this.dark))
          .opacity(0.8)
        Text('其他方式登录')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
          .maxLines(1)
        Column()
          .height(1)
          .layoutWeight(1)
          .backgroundColor(Ui.divider(this.dark))
          .opacity(0.8)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 2 })

      Row({ space: 10 }) {
        Column() {
          GhostButton({
            label: 'QQ登录',
            compact: true,
            onTap: (): void => {
              void this.loginByTencent(TencentProvider.QQ);
            }
          })
        }
          .layoutWeight(1)
        Column() {
          GhostButton({
            label: 'TIM登录',
            compact: true,
            onTap: (): void => {
              void this.loginByTencent(TencentProvider.TIM);
            }
          })
        }
          .layoutWeight(1)
        Column() {
          GhostButton({
            label: '华为账号',
            compact: true,
            onTap: (): void => {
              void this.loginByHuawei();
            }
          })
        }
          .layoutWeight(1)
      }
        .width('100%')
        .enabled(!this.isLoading)
        .opacity(this.isLoading ? 0.6 : 1)
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private loginFooter() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('还没有账号？')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.dark))
          .maxLines(1)
        GhostButton({
          label: '立即注册',
          compact: true,
          onTap: (): void => {
            this.openRegisterPage();
          }
        })
      }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      Text() {
        Span('登录即表示您已阅读并同意')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
        Span('《用户协议》')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.accent(this.dark))
          .onClick(() => {
            this.openAgreementPage();
          })
      }
        .textAlign(TextAlign.Center)
        .width('100%')
    }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: this.tablet() ? 28 : 22, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [Ui.pageBg(this.dark), 0],
            [Ui.pageBgAlt(this.dark), 1]
          ]
        })
      AuroraBackdrop({ intensity: this.dark ? 1 : 0.9 })
      // 左上角返回：返回上一级；没有上一级回首页，不会直接退出应用。
      Row() {
        GhostButton({ label: '返回', compact: true, onTap: (): void => { this.goBack(); } })
      }
        .width('100%')
        .padding({ left: this.gutter(), top: (this.safeTop() + 6) + 'vp' })
        .justifyContent(FlexAlign.Start)
      Scroll() {
        Column() {
          this.brandHeader()
          Column() {
            this.loginForm()
          }
            .width('100%')
            .constraintSize({ maxWidth: '520vp' })
            .margin({ top: this.tablet() ? 30 : 26 })
            .padding({ top: 24, right: 20, bottom: 24, left: 20 })
            .borderRadius(28)
            .linearGradient({
              angle: 135,
              colors: [
                [Ui.card(this.dark), 0],
                [Ui.cardBottom(this.dark), 1]
              ]
            })
            .border({ width: 1, color: Ui.cardBorder(this.dark) })
            .shadow({ radius: 20, color: Ui.shadowSoft(this.dark), offsetY: 8 })
            .clip(true)
          this.loginFooter()
        }
          .width('100%')
          .padding({
            top: this.safeTop() + (this.tablet() ? 56 : 34),
            bottom: 40,
            left: this.gutter(),
            right: this.gutter()
          })
          .opacity(this.pageOpacity)
          .translate({ x: 0, y: this.pageOffset })
      }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.dark))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldArea: Area, area: Area) => {
        this.updateViewport(area);
      })
  }
}

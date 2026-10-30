import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

enum MailSendStatus {
  SUCCESS = 'SUCCESS',
    DISABLED = 'DISABLED',
    FAILED = 'FAILED'
}

@Entry
@Component
struct RegisterPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @State private account: string = '';
  @State private password: string = '';
  @State private nickname: string = '';
  @State private qq: string = '';
  @State private email: string = '';
  @State private verificationCode: string = '';
  @State private inviteCode: string = '';
  @State private emailRegistrationEnabled: boolean = true;
  @State private isSendingCode: boolean = false;
  // 验证码 60 秒倒计时：发送成功后按钮禁用并显示剩余秒数。
  @State private codeCountdown: number = 0;
  private codeTimer: number = -1;
  @State private isRegistering: boolean = false;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private focusedField: string = '';
  @State private viewportWidth: number = 360;
  @State private primaryPressed: boolean = false;

  aboutToAppear(): void {
    void this.applyImmersiveConfig();
    void this.preparePage();
  }

  private async preparePage(): Promise<void> {
    try {
      const config: AppConfig = AppConfig.getInstance();
      if (!config.isInitialized()) {
        Logger.error('REGISTER', 'AppConfig实例尚未初始化');
        this.showAlert('后端配置异常', '后端配置尚未初始化，请稍后重试');
        return;
      }
      Logger.debug('REGISTER', '注册页面已完成后端配置校验');
    } catch (error) {
      Logger.error('REGISTER', '注册页面初始化异常：' + this.errorMessage(error));
      this.showAlert('后端配置异常', this.errorMessage(error));
    }
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
      Logger.debug('REGISTER', 'immersiveConfig已应用');
    } catch (error) {
      Logger.warn('REGISTER', 'immersiveConfig应用失败：' + this.errorMessage(error));
    }
  }

  private getInitializedConfig(): AppConfig | undefined {
    const config: AppConfig = AppConfig.getInstance();
    if (!config.isInitialized()) {
      Logger.error('REGISTER', '请求前检测到AppConfig实例尚未初始化');
      this.showAlert('后端配置异常', '后端配置尚未初始化，请稍后重试');
      return undefined;
    }
    return config;
  }

  private validateVerificationRequest(): boolean {
    const currentAccount: string = this.account.trim();
    const currentEmail: string = this.email.trim();
    if (!currentAccount || !currentEmail) {
      this.showAlert('获取验证码', '账号和邮箱不能为空');
      return false;
    }
    if (currentAccount.length < 6 || this.password.length < 6) {
      this.showAlert('获取验证码', '账号和密码长度必须不少于6位');
      return false;
    }
    return true;
  }

  private validateRegisterRequest(): boolean {
    const currentAccount: string = this.account.trim();
    if (!currentAccount || !this.password) {
      this.showAlert('注册提示', '账号和密码不能为空');
      return false;
    }
    if (currentAccount.length < 6 || this.password.length < 6) {
      this.showAlert('注册提示', '账号和密码长度必须不少于6位');
      return false;
    }
    return true;
  }

  /** 启动 60 秒倒计时；重复点击只会在倒计时结束后才允许重发。 */
  private startCodeCountdown(): void {
    this.stopCodeCountdown();
    this.codeCountdown = 60;
    this.codeTimer = setInterval(() => {
      this.codeCountdown = this.codeCountdown - 1;
      if (this.codeCountdown <= 0) {
        this.stopCodeCountdown();
      }
    }, 1000);
  }

  private stopCodeCountdown(): void {
    if (this.codeTimer >= 0) {
      clearInterval(this.codeTimer);
      this.codeTimer = -1;
    }
    this.codeCountdown = 0;
  }

  aboutToDisappear(): void {
    this.stopCodeCountdown();
  }

  private codeButtonLabel(): string {
    if (this.isSendingCode) { return '发送中…'; }
    if (this.codeCountdown > 0) { return String(this.codeCountdown) + 's 后重发'; }
    return '获取验证码';
  }

  private async sendVerificationCode(): Promise<void> {
    if (this.isSendingCode || this.isRegistering || this.codeCountdown > 0) {
      return;
    }
    if (!this.validateVerificationRequest()) {
      return;
    }
    const config: AppConfig | undefined = this.getInitializedConfig();
    if (config === undefined) {
      return;
    }

    this.isSendingCode = true;
    try {
      const currentAccount: string = this.account.trim();
      const currentEmail: string = this.email.trim();
      const requestUrl: string = this.buildMailUrl(config, currentAccount, currentEmail);
      Logger.info('REGISTER', '发起验证码请求：' + this.safeLogUrl(requestUrl));
      const responseText: string = await this.requestText(requestUrl);
      Logger.info('REGISTER', '验证码接口返回：' + responseText);

      const status: MailSendStatus = this.parseMailSendStatus(responseText);
      if (status === MailSendStatus.SUCCESS) {
        this.startCodeCountdown();
        this.showAlert('发送成功', responseText.trim() || '验证码已发送，请注意查收邮箱');
      } else if (status === MailSendStatus.DISABLED) {
        this.emailRegistrationEnabled = false;
        this.email = '';
        this.verificationCode = '';
        this.showAlert('后台未开启邮箱注册', '后台未开启邮箱注册，邮箱输入和验证码功能已隐藏');
      } else {
        this.showAlert('发送失败', responseText.trim() || '验证码发送失败');
      }
    } catch (error) {
      Logger.error('REGISTER', '获取验证码异常：' + this.errorMessage(error));
      this.showAlert('发送失败', this.errorMessage(error));
    } finally {
      this.isSendingCode = false;
    }
  }

  private async registerAccount(): Promise<void> {
    if (this.isRegistering || this.isSendingCode) {
      return;
    }
    if (!this.validateRegisterRequest()) {
      return;
    }
    const config: AppConfig | undefined = this.getInitializedConfig();
    if (config === undefined) {
      return;
    }

    this.isRegistering = true;
    try {
      const currentAccount: string = this.account.trim();
      const requestUrl: string = this.buildRegisterUrl(config, currentAccount, this.password);
      Logger.info('REGISTER', '发起注册请求：' + this.safeLogUrl(requestUrl));
      const responseText: string = await this.requestText(requestUrl);
      Logger.info('REGISTER', '注册接口返回：' + responseText);

      if (!this.isSuccessResponse(responseText)) {
        this.showAlert('注册失败', responseText.trim() || '注册失败');
        return;
      }

      await this.saveCredentials(currentAccount, this.password);
      await this.replaceToMyPage();
    } catch (error) {
      Logger.error('REGISTER', '注册请求异常：' + this.errorMessage(error));
      this.showAlert('注册失败', this.errorMessage(error));
    } finally {
      this.isRegistering = false;
    }
  }

  private buildMailUrl(config: AppConfig, user: string, mail: string): string {
    const domain: string = config.backendDomain.replace(/\/+$/, '');
    return domain + '/send_mail.php?admin=' + encodeURIComponent(config.backendAccount) +
    '&user=' + encodeURIComponent(user) + '&mail=' + encodeURIComponent(mail);
  }

  private buildRegisterUrl(config: AppConfig, user: string, pass: string): string {
    const domain: string = config.backendDomain.replace(/\/+$/, '');
    let requestUrl: string = domain + '/userregister.php?admin=' + encodeURIComponent(config.backendAccount) +
    '&user=' + encodeURIComponent(user) + '&pass=' + encodeURIComponent(pass);
    requestUrl = this.appendOptionalParameter(requestUrl, 'name', this.nickname);
    requestUrl = this.appendOptionalParameter(requestUrl, 'qq', this.qq);
    requestUrl = this.appendOptionalParameter(requestUrl, 'mail', this.email);
    requestUrl = this.appendOptionalParameter(requestUrl, 'codes', this.verificationCode);
    requestUrl = this.appendOptionalParameter(requestUrl, 'code', this.inviteCode);
    return requestUrl;
  }

  private appendOptionalParameter(requestUrl: string, key: string, value: string): string {
    const normalized: string = value.trim();
    if (!normalized) {
      return requestUrl;
    }
    return requestUrl + '&' + key + '=' + encodeURIComponent(normalized);
  }

  private async requestText(requestUrl: string): Promise<string> {
    let request: http.HttpRequest | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(requestUrl, {
        method: http.RequestMethod.GET,
          connectTimeout: 30000,
          readTimeout: 30000
      });
      const responseText: string = String(response.result);
      Logger.debug('REGISTER_HTTP', 'HTTP返回码：' + String(response.responseCode));
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(responseText || ('HTTP请求失败，状态码：' + String(response.responseCode)));
      }
      return responseText;
    } catch (error) {
      Logger.error('REGISTER_HTTP', 'HTTP请求异常：' + this.errorMessage(error));
      throw new Error(this.errorMessage(error));
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  private parseMailSendStatus(responseText: string): MailSendStatus {
    const normalized: string = responseText.trim().toLowerCase();
    const mentionsMail: boolean = normalized.includes('邮箱') || normalized.includes('邮件') || normalized.includes('mail');
    const disabledByMessage: boolean = mentionsMail &&
      (normalized.includes('未开启') || normalized.includes('未开放') || normalized.includes('关闭') ||
      normalized.includes('禁用') || normalized.includes('disabled') || normalized.includes('off'));
    if (normalized === '2' || normalized === '-2' || disabledByMessage) {
      return MailSendStatus.DISABLED;
    }
    if (normalized === '1' || normalized === 'ok' || normalized === 'true' ||
      normalized.includes('发送成功') || normalized.includes('验证码已发送') || normalized.includes('success') ||
      normalized.includes('sent')) {
      return MailSendStatus.SUCCESS;
    }
    return MailSendStatus.FAILED;
  }

  private isSuccessResponse(responseText: string): boolean {
    const normalized: string = responseText.trim().toLowerCase();
    if (normalized === '1' || normalized === 'ok' || normalized === 'true' || normalized === '200') {
      return true;
    }
    return normalized.includes('注册成功') || normalized.includes('success') || normalized === '成功';
  }

  private async saveCredentials(user: string, pass: string): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      await store.put('$user', user);
      await store.put('$pass', pass);
      await store.flush();
      Logger.info('REGISTER', '注册凭证已保存至preferences(wuyin)');
    } catch (error) {
      Logger.error('REGISTER', '保存注册凭证失败：' + this.errorMessage(error));
      throw new Error(this.errorMessage(error));
    }
  }

  /**
   * 注册成功后返回：MyPage 是内嵌组件、不是路由页，原来的 replaceUrl('pages/MyPage') 会跳转失败；
   * 这里改为"回到上一级（通常是登录页）"，只把账号带回去，不动其它页面。
   */
  private async replaceToMyPage(): Promise<void> {
    try {
      AppStorage.setOrCreate<string>('pendingLoginUser', this.account.trim());
      if (Number(router.getLength()) > 1) {
        router.back();
        Logger.info('REGISTER', '注册成功，已返回上一级并带回账号');
        return;
      }
      await replaceRoute({ url: 'pages/Index' });
      Logger.info('REGISTER', '注册成功并已回到首页');
    } catch (error) {
      Logger.error('REGISTER', '注册成功后的返回失败：' + this.errorMessage(error));
      throw new Error('注册成功，但页面跳转失败：' + this.errorMessage(error));
    }
  }

  /** 返回上一级；没有上一级回首页，避免直接退出应用。 */
  private goBack(): void {
    try {
      if (Number(router.getLength()) > 1) {
        router.back();
        return;
      }
      void replaceRoute({ url: 'pages/Index' });
    } catch (error) {
      Logger.error('REGISTER', '返回上一级失败：' + this.errorMessage(error));
    }
  }

  onBackPress(): boolean {
    try {
      if (Number(router.getLength()) > 1) { return false; }
      void replaceRoute({ url: 'pages/Index' });
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 已有账号：有上一级就回退，没有才替换成登录页，避免栈里堆叠多个登录页。 */
  private async openLoginPage(): Promise<void> {
    try {
      if (Number(router.getLength()) > 1) {
        router.back();
        return;
      }
      await router.pushUrl({ url: 'pages/LoginPage' });
    } catch (error) {
      Logger.error('REGISTER', '跳转LoginPage失败：' + this.errorMessage(error));
      this.showAlert('页面跳转失败', this.errorMessage(error));
    }
  }

  private async openAgreementPage(): Promise<void> {
    try {
      const state = router.getState();
      if (state !== undefined && state.path === 'pages/UserAgreementPage') {
        return;
      }
      await router.pushUrl({ url: 'pages/UserAgreementPage' });
    } catch (error) {
      Logger.error('REGISTER', '跳转用户协议失败：' + this.errorMessage(error));
      this.showAlert('页面跳转失败', this.errorMessage(error));
    }
  }

  private safeLogUrl(requestUrl: string): string {
    return requestUrl.replace(/([&?]pass=)[^&]*/gi, '$1***');
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
        Text('创建账户，开始记录您的观影旅程')
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
  private registerForm() {
    Column({ space: 13 }) {
      Column({ space: 7 }) {
        Text('注册新账号')
          .fontSize(Ui.fs(this.tablet() ? '24vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.dark))
          .width('100%')
        Text('填写信息后即可使用无音影视')
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

      TextInput({ placeholder: '请输入密码（不少于6位）', text: this.password })
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

      TextInput({ placeholder: '请输入昵称（选填）', text: this.nickname })
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
          color: this.focusedField === 'nickname' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
        })
        .shadow({
          radius: this.focusedField === 'nickname' ? 16 : 0,
          color: this.focusedField === 'nickname' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
          offsetY: 4
        })
        .padding({ top: 0, right: 18, bottom: 0, left: 18 })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        .onFocus(() => {
          this.focusedField = 'nickname';
        })
        .onBlur(() => {
          this.focusedField = '';
        })
        .onChange((value: string) => {
          this.nickname = value;
        })

      TextInput({ placeholder: '请输入QQ（选填）', text: this.qq })
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
          color: this.focusedField === 'qq' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
        })
        .shadow({
          radius: this.focusedField === 'qq' ? 16 : 0,
          color: this.focusedField === 'qq' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
          offsetY: 4
        })
        .padding({ top: 0, right: 18, bottom: 0, left: 18 })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        .onFocus(() => {
          this.focusedField = 'qq';
        })
        .onBlur(() => {
          this.focusedField = '';
        })
        .onChange((value: string) => {
          this.qq = value;
        })

      if (this.emailRegistrationEnabled) {
        Column({ space: 10 }) {
          TextInput({ placeholder: '请输入邮箱', text: this.email })
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
              color: this.focusedField === 'email' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
            })
            .shadow({
              radius: this.focusedField === 'email' ? 16 : 0,
              color: this.focusedField === 'email' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
              offsetY: 4
            })
            .padding({ top: 0, right: 18, bottom: 0, left: 18 })
            .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
            .onFocus(() => {
              this.focusedField = 'email';
            })
            .onBlur(() => {
              this.focusedField = '';
            })
            .onChange((value: string) => {
              this.email = value;
            })

          Row({ space: 10 }) {
            TextInput({ placeholder: '请输入验证码', text: this.verificationCode })
              .height(50)
              .layoutWeight(1)
              .fontSize(15)
              .fontColor(Ui.ink(this.dark))
              .placeholderColor(Ui.inkFaint(this.dark))
              .caretColor(Ui.accent(this.dark))
              .backgroundColor(Ui.glassTintSoft(this.dark))
              .borderRadius(25)
              .border({
                width: 1,
                color: this.focusedField === 'code' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
              })
              .shadow({
                radius: this.focusedField === 'code' ? 16 : 0,
                color: this.focusedField === 'code' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
                offsetY: 4
              })
              .padding({ top: 0, right: 18, bottom: 0, left: 18 })
              .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
              .onFocus(() => {
                this.focusedField = 'code';
              })
              .onBlur(() => {
                this.focusedField = '';
              })
              .onChange((value: string) => {
                this.verificationCode = value;
              })

            Column() {
              GhostButton({
                label: this.codeButtonLabel(),
                onTap: (): void => {
                  void this.sendVerificationCode();
                }
              })
            }
              .enabled(!this.isSendingCode && !this.isRegistering && this.codeCountdown === 0)
              .opacity(this.isSendingCode || this.isRegistering || this.codeCountdown > 0 ? 0.55 : 1)
          }
            .width('100%')
        }
          .width('100%')
      }

      TextInput({ placeholder: '请输入邀请码（选填）', text: this.inviteCode })
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
          color: this.focusedField === 'invite' ? Ui.accentRing(this.dark) : Ui.glassRingSoft(this.dark)
        })
        .shadow({
          radius: this.focusedField === 'invite' ? 16 : 0,
          color: this.focusedField === 'invite' ? Ui.accentGlow(this.dark) : Ui.glassSheenClear(),
          offsetY: 4
        })
        .padding({ top: 0, right: 18, bottom: 0, left: 18 })
        .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
        .onFocus(() => {
          this.focusedField = 'invite';
        })
        .onBlur(() => {
          this.focusedField = '';
        })
        .onChange((value: string) => {
          this.inviteCode = value;
        })

      Row() {
        if (this.isRegistering) {
          LoadingProgress()
            .width('16vp')
            .height('16vp')
            .color('#FFFFFF')
            .margin({ right: 8 })
        }
        Text(this.isRegistering ? '注册中…' : '注册')
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
        .enabled(!this.isRegistering && !this.isSendingCode)
        .opacity(this.isRegistering || this.isSendingCode ? 0.72 : 1)
        .scale({ x: this.primaryPressed ? 0.97 : 1, y: this.primaryPressed ? 0.97 : 1 })
        .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
        .margin({ top: 4 })
        .onTouch((event: TouchEvent) => {
          this.primaryPressed = event.type === TouchType.Down;
        })
        .onClick(() => {
          void this.registerAccount();
        })
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private registerFooter() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('已有账号？')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.dark))
          .maxLines(1)
        GhostButton({
          label: '去登录',
          compact: true,
          onTap: (): void => {
            void this.openLoginPage();
          }
        })
      }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      Text() {
        Span('注册即表示您已阅读并同意')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
        Span('《用户协议》')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.accent(this.dark))
          .onClick(() => {
            void this.openAgreementPage();
          })
      }
        .textAlign(TextAlign.Center)
        .width('100%')
    }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: this.tablet() ? 26 : 22, bottom: 8 })
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
            this.registerForm()
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
          this.registerFooter()
        }
          .width('100%')
          .padding({
            top: this.safeTop() + (this.tablet() ? 56 : 34),
            bottom: 40,
            left: this.gutter(),
            right: this.gutter()
          })
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

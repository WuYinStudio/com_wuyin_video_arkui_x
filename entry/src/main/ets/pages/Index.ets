/*
AIGC:
Label: '1'
ContentProducer: 'HapCode'
ProduceID: '10f41559-e350-40e8-bb7d-586706c2db8a'
ReservedCode1: ''
ContentPropagator: 'HapCode'
PropagateID: '10f41559-e350-40e8-bb7d-586706c2db8a'
ReservedCode2: ''
*/
// 内容由 AI 生成，请仔细甄别（AI）
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { AgreementService } from '../common/AgreementService';
import { AppState } from '../common/AppState';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { PlatformBridge } from '../common/PlatformBridge';
import { ShareService, SharedPlayerRouteParams } from '../common/ShareService';
import { Ui } from '../common/Ui';
import { AuroraBackdrop } from '../common/UiWidgets';
import { HomePage } from './HomePage';
import { UserAgreementPage } from './UserAgreementPage';

// 连按两次返回键退出应用的判定窗口（毫秒）。
const DOUBLE_BACK_EXIT_MS: number = 2000;
// 所有带底部导航栏的标签页（与 NavTabs.ALL 对齐）：在这些页面上按返回才走「先显示底栏 / 再连按退出」。
const TAB_PAGE_KEYS: string[] = ['home', 'message', 'forum', 'live', 'category', 'manage', 'settings', 'mine'];

// 先完成协议状态恢复，再挂载首页，避免已同意用户启动时短暂看到协议页面。
@Entry
@Component
struct Index {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('agreementAccepted') @Watch('onAgreementChanged') private agreementAccepted: boolean = false;
  @StorageLink('playerHandoffVersion') @Watch('onPlayerHandoffChanged') private playerHandoffVersion: number = 0;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('page') @Watch('onPageChanged') private pageKey: string = 'home';
  @State private agreementReady: boolean = false;
  private handoffRouting: boolean = false;
  private handoffQueued: boolean = false;
  /** 上一次按返回键的时间：用于「连按两次返回才退出应用」判定。 */
  private lastBackAt: number = 0;
  /** 内部页面栈（底栏标签页只保留一层）：返回键据此「返回上一级页面」。 */
  private pageHistory: string[] = ['home'];
  /** 返回导航自身触发的切页不写入页面栈，避免来回弹。 */
  private backNavigating: boolean = false;

  aboutToAppear(): void {
    try {
      void this.prepareAgreement();
    } catch (error) {
      Logger.error('UserAgreement', '准备协议状态失败：' + String(error));
      this.agreementAccepted = false;
      this.agreementReady = true;
    }
  }

  /** 云端 iOS 自测：先测网络与原生桥，再逐页 push / 切换底栏。 */
  private async runIosSmokeTest(): Promise<void> {
    await this.smokeSleep(5000);
    AppStorage.setOrCreate('agreementAccepted', true);
    this.smokeLog('SMOKE', '==== start ====');
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const agreement: string = fs.accessSync(context.filesDir + '/agreement_accepted.txt') ? 'yes' : 'no';
      this.smokeLog('SMOKE_STORAGE', 'filesDir=' + context.filesDir + ' agreement=' + agreement);
    } catch (error) {
      this.smokeLog('SMOKE_STORAGE', 'error=' + String(error));
    }
    this.smokeLog('SMOKE_BRIDGE', 'battery=' + String(await PlatformBridge.batteryPercent()));
    const homeUrl: string = 'http://www.baofeng.com/po/v10/config/channelhome?nav_id=203&pg=1&cp=fr4k0se&cl=newweb_baofeng';
    try {
      const raw: string = await PlatformBridge.httpRequest(homeUrl, 'GET', '{}', '');
      this.smokeLog('SMOKE_HTTP', 'bridge=' + raw.substring(0, 160).replace(/\n/g, ' | '));
    } catch (error) {
      this.smokeLog('SMOKE_HTTP', 'bridge error=' + String(error));
    }
    try {
      const request: http.HttpRequest = http.createHttp();
      const response: http.HttpResponse = await request.request(homeUrl, {
        method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      });
      this.smokeLog('SMOKE_HTTP_DIRECT', 'code=' + response.responseCode +
        ' body=' + String(response.result).substring(0, 120).replace(/\n/g, ' | '));
      request.destroy();
    } catch (error) {
      this.smokeLog('SMOKE_HTTP_DIRECT', 'error=' + String(error));
    }
    const routes: string[] = [
      'pages/PlayerPage', 'pages/MessagePage', 'pages/ForumPage', 'pages/LoginPage',
      'pages/ThemeStorePage', 'pages/WallpaperPage', 'pages/UpdateLogPage',
      'pages/ScanPage', 'pages/ShareQrPage', 'pages/CastControlPage'
    ];
    for (const route of routes) {
      this.smokeLog('SMOKE_ROUTE', 'push ' + route);
      try {
        await router.pushUrl({ url: route });
        this.smokeLog('SMOKE_ROUTE', 'ok ' + route);
      } catch (error) {
        this.smokeLog('SMOKE_ROUTE', 'fail ' + route + ' ' + String(error));
      }
      await this.smokeSleep(1200);
      try {
        if (Number(router.getLength()) > 1) { router.back(); }
      } catch (error) {
        this.smokeLog('SMOKE_ROUTE', 'back fail ' + String(error));
      }
      await this.smokeSleep(600);
    }
    const tabs: string[] = ['settings', 'mine', 'category', 'message', 'forum'];
    for (const tab of tabs) {
      this.smokeLog('SMOKE_TAB', 'switch ' + tab);
      AppStorage.setOrCreate('page', tab);
      await this.smokeSleep(1800);
      this.smokeLog('SMOKE_TAB', 'ok ' + tab);
    }
    this.smokeLog('SMOKE_TAB', 'switch home');
    AppStorage.setOrCreate('page', 'home');
    await this.smokeSleep(8000);
    this.smokeLog('SMOKE', '==== done ====');
  }

  private smokeLog(tag: string, message: string): void {
    try { console.info('[SMOKE][' + tag + '] ' + message); } catch (_) {}
    try { Logger.info(tag, message); } catch (_) {}
  }

  private async smokeSleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
  }

  private async prepareAgreement(): Promise<void> {
    try {
      await AgreementService.restore(getContext(this) as common.UIAbilityContext);
    } catch (error) {
      Logger.error('UserAgreement', '启动时读取协议状态失败：' + String(error));
      this.agreementAccepted = false;
    } finally {
      this.agreementReady = true;
      this.onPlayerHandoffChanged();
      this.maybeRunIosSmokeTest();
    }
  }

  /** 云端模拟器通过 WUYIN_SMOKE=1 写入标记文件；正式包没有该文件时不会执行。 */
  private maybeRunIosSmokeTest(): void {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      if (!fs.accessSync(context.filesDir + '/smoke_mode.txt')) { return; }
      Logger.info('SMOKE', '检测到 smoke_mode.txt，启动 iOS 冒烟测试');
      void this.runIosSmokeTest();
    } catch (_) {
      // 非 iOS / 无文件系统时静默跳过。
    }
  }

  private onAgreementChanged(): void {
    try { this.onPlayerHandoffChanged(); }
    catch (_) { Logger.error('SHARE_RESUME', '协议确认后检查接续请求失败'); }
  }

  onPageShow(): void {
    try { this.onPlayerHandoffChanged(); }
    catch (_) { Logger.error('SHARE_RESUME', '启动页显示时检查接续请求失败'); }
  }

  private onPlayerHandoffChanged(): void {
    try {
      if (!this.agreementReady || !this.agreementAccepted) { return; }
      if (this.handoffRouting) {
        this.handoffQueued = true;
        return;
      }
      void this.routeSharedPlayer();
    } catch (_) { Logger.error('SHARE_RESUME', '检查系统分享接续请求失败'); }
  }

  private clearPlayerResume(requestId: number = 0): void {
    try {
      const pending: SharedPlayerRouteParams | undefined = AppStorage.get<SharedPlayerRouteParams>('playerSharedResumeParams');
      // 失败的旧请求不能删除路由期间到达的新系统请求。
      if (requestId !== 0 && pending?.shareRequestId !== requestId) { return; }
      AppStorage.delete('playerSharedResumeParams');
      AppStorage.setOrCreate<number>('playerSharedResumeVersion', 0);
    } catch (_) { Logger.warn('SHARE_RESUME', '清理播放器临时接续参数失败'); }
  }

  private async routeSharedPlayer(): Promise<void> {
    let request: SharedPlayerRouteParams | undefined;
    try {
      if (this.handoffRouting || !this.agreementReady || !this.agreementAccepted) { return; }
      this.handoffRouting = true;
      // 只消费 Ability 发布的本次系统 Want，不读取剪贴板或持久化启动参数。
      request = ShareService.takePlayerHandoff();
      if (!request) { return; }
      const playerStates: router.RouterState[] = router.getStateByUrl('pages/PlayerPage');
      if (playerStates.length > 0) {
        const playerState: router.RouterState = playerStates[playerStates.length - 1];
        const currentState: router.RouterState = router.getState();
        // 当前播放器由版本监听消费；下层播放器返回显示时消费同一份内存参数。
        AppStorage.setOrCreate<SharedPlayerRouteParams>('playerSharedResumeParams', request);
        AppStorage.setOrCreate<number>('playerSharedResumeVersion', request.shareRequestId);
        if (currentState.index !== playerState.index) {
          // 不把已存在页面的路由参数再次替换为分享包，防止页面返回时重复接续。
          router.back({ url: 'pages/PlayerPage' });
        }
        Logger.info('SHARE_RESUME', 'Index 复用已存在的 PlayerPage，序号=' + request.shareRequestId +
        '，集数=' + (request.sharedEpisodeIndex + 1) + '，接续进度=' + request.sharedPlayProgress + '秒');
      } else {
        // 上次已退出的播放器不能留下可供新页面误消费的临时包。
        this.clearPlayerResume();
        await router.pushUrl({ url: 'pages/PlayerPage', params: request });
        Logger.info('SHARE_RESUME', 'Index 新建 PlayerPage，序号=' + request.shareRequestId +
        '，集数=' + (request.sharedEpisodeIndex + 1) + '，接续进度=' + request.sharedPlayProgress + '秒');
      }
    } catch (error) {
      if (request) { this.clearPlayerResume(request.shareRequestId); }
      Logger.error('SHARE_RESUME', '分享接续路由失败：' + String(error));
    } finally {
      this.handoffRouting = false;
      // 异步跳转期间收到的新 Want 不被旧请求清除，继续消费最新的系统请求。
      if (this.handoffQueued) {
        this.handoffQueued = false;
        this.onPlayerHandoffChanged();
      }
    }
  }

  private needsAgreement(): boolean {
    try {
      return !this.agreementAccepted;
    } catch (error) {
      Logger.error('UserAgreement', '检查协议展示状态失败：' + String(error));
      return true;
    }
  }

  /**
   * 记录内部页面栈：
   * - 底栏标签页之间是平级切换，栈只保留当前标签（返回时回首页）；
   * - 搜索、个人主页等子页面按层压栈，返回键逐级回退。
   */
  private onPageChanged(): void {
    try {
      const current: string = this.pageKey;
      if (this.backNavigating) {
        // 这次切页是返回键触发的，不再入栈（否则会来回弹）。
        this.backNavigating = false;
        return;
      }
      if (TAB_PAGE_KEYS.indexOf(current) >= 0) {
        this.pageHistory = [current];
        return;
      }
      if (this.pageHistory.length === 0) { this.pageHistory = ['home']; }
      if (this.pageHistory[this.pageHistory.length - 1] !== current) {
        this.pageHistory.push(current);
        if (this.pageHistory.length > 10) { this.pageHistory.shift(); }
      }
    } catch (error) {
      Logger.warn('NAV_BACK', '记录页面栈失败：' + String(error));
    }
  }

  /** 返回上一级内部页面；没有上一级返回 false，交给后续规则处理。 */
  private backToPreviousPage(): boolean {
    try {
      const stack: string[] = this.pageHistory;
      if (stack.length > 0 && stack[stack.length - 1] === this.pageKey) { stack.pop(); }
      while (stack.length > 0) {
        const target: string = stack[stack.length - 1];
        if (target === this.pageKey) { stack.pop(); continue; }
        this.backNavigating = true;
        AppState.go(target);
        setTimeout(() => { this.backNavigating = false; }, 200);
        Logger.info('NAV_BACK', '返回上一级页面：' + this.pageKey + ' → ' + target);
        return true;
      }
      return false;
    } catch (error) {
      Logger.warn('NAV_BACK', '返回上一级页面失败：' + String(error));
      return false;
    }
  }

  /** 非首页时按返回：先回到首页（再按一次才进入退出判定）。 */
  private consumeBackForHome(): boolean {
    try {
      if (this.pageKey === 'home') { return false; }
      const from: string = this.pageKey;
      this.backNavigating = true;
      AppState.go('home');
      setTimeout(() => { this.backNavigating = false; }, 200);
      Logger.info('NAV_BACK', '非首页按返回，回到首页：' + from);
      return true;
    } catch (error) {
      this.backNavigating = false;
      Logger.warn('NAV_BACK', '回到首页失败：' + String(error));
      return false;
    }
  }

  onBackPress(): boolean {
    try {
      if (!this.agreementReady || this.needsAgreement()) {
        return true;
      }
      // 1) 底栏被滚动藏起来时，第一次返回只负责把底栏显示回来。
      if (this.consumeBackForNavigationBar()) {
        return true;
      }
      // 2) 有上一级内部页面：逐级返回，不退出应用。
      if (this.backToPreviousPage()) {
        return true;
      }
      // 3) 不在首页：先回首页。
      if (this.consumeBackForHome()) {
        return true;
      }
      // 4) 已在首页：连按两次返回才退出应用，第一次只弹提示。
      return this.consumeBackForExit();
    } catch (error) {
      Logger.error('UserAgreement', '拦截协议页面返回失败：' + String(error));
      return true;
    }
  }

  /**
   * 首页返回：第一次只提示「再按一次退出」，2 秒内再按一次才真正退出应用。
   */
  private consumeBackForExit(): boolean {
    try {
      const page: string = this.pageKey;
      if (page !== 'home') {
        return false;
      }
      const now: number = Date.now();
      if (this.lastBackAt > 0 && now - this.lastBackAt <= DOUBLE_BACK_EXIT_MS) {
        this.lastBackAt = 0;
        Logger.info('NAV_BACK', '2 秒内再次按返回，退出应用');
        try {
          const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
          void context.terminateSelf();
        } catch (error) {
          Logger.warn('NAV_BACK', '主动退出应用失败，交给系统默认返回：' + String(error));
          return false;
        }
        return true;
      }
      this.lastBackAt = now;
      this.showExitHint();
      Logger.info('NAV_BACK', '第一次按返回：提示再按一次退出');
      return true;
    } catch (error) {
      Logger.warn('NAV_BACK', '处理退出返回键失败：' + String(error));
      return false;
    }
  }

  /** 第一次返回时的吐司提示。 */
  private showExitHint(): void {
    try {
      promptAction.showToast({ message: '再按一次返回退出无音影视', duration: 1600 });
    } catch (error) {
      Logger.warn('NAV_BACK', '显示退出提示失败：' + String(error));
    }
  }

  /**
   * 底栏被滚动藏起来时，第一次返回只负责把底栏显示回来，不退出、也不回退页面；
   * 底栏本来就是显示状态时不拦截，交给系统按默认行为处理（退出应用）。
   */
  private consumeBackForNavigationBar(): boolean {
    try {
      const page: string = this.pageKey;
      if (TAB_PAGE_KEYS.indexOf(page) < 0) {
        // 不在带底栏的标签页上，保持原有返回行为。
        return false;
      }
      const hidden: boolean = AppStorage.get<boolean>('navigationBarHidden') ?? false;
      if (!hidden) {
        return false;
      }
      NavigationScroll.reset(page, '返回键显示底部导航栏');
      Logger.info('NAV_BACK', '底栏隐藏状态下按返回：本次只恢复底栏，页面=' + page);
      return true;
    } catch (error) {
      Logger.warn('NAV_BACK', '返回键恢复底栏失败：' + String(error));
      return false;
    }
  }

  // ArkUI 的 build 只能包含声明式组件语法；可能抛错的存储读取放在受保护的方法中。
  build() {
    Column() {
      if (!this.agreementReady) {
        // 协议状态恢复期间显示与启动窗口同色的品牌闪屏，避免出现一块突兀的纯色。
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 180,
              colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
            })
          AuroraBackdrop({ intensity: 0.9 })
          Column({ space: 14 }) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width('64vp').height('64vp').borderRadius('20vp')
                .linearGradient({
                  angle: 135,
                  colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
                })
                .shadow({ radius: 24, color: Ui.accentGlow(this.darkTheme), offsetY: 10 })
              Text('无').fontSize(Ui.fs('30vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            }
              .width('64vp').height('64vp')
            Text('无音影视')
              .fontSize(Ui.fs('17vp', this.fontScale)).fontWeight(FontWeight.Medium)
              .fontColor(Ui.inkSoft(this.darkTheme))
          }
        }
          .width('100%')
          .height('100%')
      } else if (this.needsAgreement()) {
        UserAgreementPage()
      } else {
        HomePage()
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
  }
}
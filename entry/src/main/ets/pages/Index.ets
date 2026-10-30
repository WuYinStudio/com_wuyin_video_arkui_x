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
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AgreementService } from '../common/AgreementService';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { ShareService, SharedPlayerRouteParams } from '../common/ShareService';
import { Ui } from '../common/Ui';
import { AuroraBackdrop } from '../common/UiWidgets';
import { HomePage } from './HomePage';
import { UserAgreementPage } from './UserAgreementPage';

// 先完成协议状态恢复，再挂载首页，避免已同意用户启动时短暂看到协议页面。
@Entry
@Component
struct Index {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('agreementAccepted') @Watch('onAgreementChanged') private agreementAccepted: boolean = false;
  @StorageLink('playerHandoffVersion') @Watch('onPlayerHandoffChanged') private playerHandoffVersion: number = 0;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private agreementReady: boolean = false;
  private handoffRouting: boolean = false;
  private handoffQueued: boolean = false;

  aboutToAppear(): void {
    try {
      void this.prepareAgreement();
    } catch (error) {
      Logger.error('UserAgreement', '准备协议状态失败：' + String(error));
      this.agreementAccepted = false;
      this.agreementReady = true;
    }
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

  onBackPress(): boolean {
    try {
      if (!this.agreementReady || this.needsAgreement()) {
        return true;
      }
      return this.consumeBackForNavigationBar();
    } catch (error) {
      Logger.error('UserAgreement', '拦截协议页面返回失败：' + String(error));
      return true;
    }
  }

  /**
   * 底栏被滚动藏起来时，第一次返回只负责把底栏显示回来，不退出、也不回退页面；
   * 底栏本来就是显示状态时不拦截，交给系统按默认行为处理（退出应用）。
   */
  private consumeBackForNavigationBar(): boolean {
    try {
      const page: string = AppStorage.get<string>('page') ?? 'home';
      const tabPages: string[] = ['home', 'category', 'manage', 'settings', 'mine'];
      if (tabPages.indexOf(page) < 0) {
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
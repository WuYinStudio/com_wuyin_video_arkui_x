import { router } from '@kit.ArkUI';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { GhostButton } from '../common/UiWidgets';

class SniffParams {
  url: string = '';
}

/**
 * 平台链接嗅探页。
 *
 * iOS 版 ArkUI-X 没有实现 @kit.ArkWeb，无法注入页面脚本抓直链。
 * 这里保留路由和参数，提示用户改用“手动播放/搜索”。
 */
@Entry
@Component
struct PlatformSnifferPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private target: string = '';
  private topSafeInset: number = 24;

  aboutToAppear(): void {
    try {
      const params: SniffParams | undefined = router.getParams() as SniffParams | undefined;
      if (params !== undefined && params.url !== undefined) { this.target = params.url; }
      Logger.info('SNIFF_PAGE', '打开分享页解析：' + this.target);
    } catch (error) {
      Logger.warn('SNIFF_PAGE', '读取参数失败：' + String(error));
    }
  }

  private finish(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
    } else {
      void router.pushUrl({ url: 'pages/Index' });
    }
  }

  build() {
    Column({ space: '16vp' }) {
      Row({ space: '10vp' }) {
        GhostButton({ label: '返回', compact: true, onTap: (): void => { this.finish(); } })
        Text('解析分享页')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
      }
        .width('100%')
      Text('iOS 版暂不支持网页脚本嗅探。')
        .fontSize(Ui.fs('15vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
      Text(this.target)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.accent(this.darkTheme))
        .width('100%')
        .textAlign(TextAlign.Start)
      Text('请复制分享链接，回到首页用搜索/手动播放打开；或使用支持嗅探的 Android / HarmonyOS 版本。')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
    }
      .width('100%')
      .height('100%')
      .padding({ left: '16vp', right: '16vp', top: (this.topSafeInset + 6) + 'vp', bottom: '16vp' })
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

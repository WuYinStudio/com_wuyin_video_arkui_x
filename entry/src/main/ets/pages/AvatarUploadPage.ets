import { router } from '@kit.ArkUI';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { GhostButton } from '../common/UiWidgets';

class AvatarRouteParams {
  url: string = '';
}

/**
 * 头像上传页。
 *
 * iOS 版 ArkUI-X 没有实现 @kit.ArkWeb，不能内嵌官方上传页面；
 * 这里保留路由和参数，提示用户改用系统浏览器打开上传地址。
 */
@Entry
@Component
struct AvatarUploadPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private url: string = 'https://api.y11.top/userportrait.php';
  private topSafeInset: number = 24;

  aboutToAppear(): void {
    try {
      const params: AvatarRouteParams | undefined = router.getParams() as AvatarRouteParams | undefined;
      if (params !== undefined && params.url !== undefined && params.url.length > 0) {
        this.url = params.url;
      }
      Logger.info('AVATAR_UPLOAD', '打开头像上传页：' + this.url);
    } catch (error) {
      Logger.warn('AVATAR_UPLOAD', '读取上传页参数失败：' + String(error));
    }
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    void router.pushUrl({ url: 'pages/Index' });
  }

  build() {
    Column({ space: '16vp' }) {
      Row({ space: '10vp' }) {
        GhostButton({ label: '完成', compact: true, onTap: (): void => { this.goBack(); } })
        Text('上传头像')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
      }
        .width('100%')
      Text('iOS 版暂不支持内嵌网页上传。')
        .fontSize(Ui.fs('15vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
      Text(this.url)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.accent(this.darkTheme))
        .width('100%')
        .textAlign(TextAlign.Start)
      Text('请复制上面的地址，用 Safari 打开后完成上传；或直接在“我的”页选择本地图片上传。')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
    }
      .width('100%')
      .height('100%')
      .padding({ left: '16vp', right: '16vp', top: (this.safeTop() + 6) + 'vp', bottom: '16vp' })
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

class AvatarRouteParams {
  url: string = '';
}

/**
 * 头像上传页（内嵌 WebView）。
 *
 * 官方接口 userportrait.php / portraitupload.php 返回的是一个自带 JS 上传逻辑的 HTML 页面
 * （选图 → FormData POST 到 portraitupload.php?admin&user&pass → alert('上传成功')），
 * 用原生 http 组装 multipart 会被服务端当成普通访问而回退到该页面，
 * 因此这里直接用它自己的页面上传，等价于 iApp 示例里的 hw(url)。
 */
@Entry
@Component
struct AvatarUploadPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private url: string = 'https://api.y11.top/userportrait.php';
  @State private loading: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
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
    void replaceRoute({ url: 'pages/Index' });
  }

  build() {
    Column() {
      Row({ space: '10vp' }) {
        GhostButton({ label: '完成', compact: true, onTap: (): void => { this.goBack(); } })
        Text('上传头像')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
        if (this.loading) {
          LoadingProgress().width('18vp').height('18vp').color(Ui.accent(this.darkTheme))
        }
      }
        .width('100%')
        .padding({ left: '14vp', right: '14vp', top: (this.safeTop() + 6) + 'vp', bottom: '6vp' })
        .backgroundColor(Ui.pageBg(this.darkTheme))
      Web({ src: this.url, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .mixedMode(MixedMode.All)
        .onPageEnd(() => { this.loading = false; })
        .onErrorReceive(() => { this.loading = false; })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

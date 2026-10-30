import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

class SniffParams {
  url: string = '';
}

/**
 * 平台链接嗅探页（抖音 / 快手等需要跑页面脚本的平台）。
 *
 * 思路：隐藏式 WebView 打开分享页，注入本地 JS 抓真实视频地址：
 * 1. 覆写 XMLHttpRequest/fetch，记录含 playurl / m3u8 / mp4 的请求；
 * 2. 扫描 <video>.src 与页面内联 JSON（如 renderData / __INITIAL_STATE__）；
 * 3. 抓到后写入 AppStorage('sniffedVideoUrl') 并自动返回。
 *
 * 抓不到时 8 秒后自动返回，由调用方回退到普通嗅探。
 */
@Entry
@Component
struct PlatformSnifferPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private target: string = '';
  @State private hint: string = '正在解析分享页…';
  @State private ready: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private timer: number = -1;
  private topSafeInset: number = 24;

  aboutToAppear(): void {
    try {
      const params: SniffParams | undefined = router.getParams() as SniffParams | undefined;
      if (params !== undefined && params.url !== undefined) { this.target = params.url; }
      Logger.info('SNIFF_PAGE', '开始嗅探：' + this.target);
      this.timer = setTimeout(() => { this.finish(''); }, 8000);
    } catch (error) {
      Logger.warn('SNIFF_PAGE', '读取参数失败：' + String(error));
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private inject(): void {
    const script: string = "(function(){"
      + "var out=[];var push=function(u){if(!u)return;if(/m3u8|mp4|playurl|mp3/.test(u)&&out.indexOf(u)<0)out.push(u);};"
      + "var o=XMLHttpRequest.prototype.open;"
      + "XMLHttpRequest.prototype.open=function(m,u){try{push(String(u));}catch(e){}return o.apply(this,arguments);};"
      + "try{var f=window.fetch;if(f){window.fetch=function(a){try{push(String(a&&a.url?a.url:a));}catch(e){}return f.apply(this,arguments);};}}catch(e){}"
      + "try{document.querySelectorAll('video,source').forEach(function(v){push(v.src);push(v.currentSrc);});}catch(e){}"
      + "try{var t=document.documentElement.innerHTML;var m=t.match(/https?:[^\"'\\\\s]+?\\.(mp4|m3u8)[^\"'\\\\s]*/g);if(m){m.forEach(push);}}catch(e){}"
      + "window.__wySniff=out;})();";
    this.controller.runJavaScript(script).then(() => {
      Logger.info('SNIFF_PAGE', '拦截脚本已注入');
    }).catch((error: Error) => {
      Logger.warn('SNIFF_PAGE', '注入失败：' + String(error));
    });
  }

  private collect(): void {
    this.controller.runJavaScript('JSON.stringify(window.__wySniff||[])').then((value: string) => {
      const text: string = String(value || '').replace(/^"|"$/g, '').replace(/\\"/g, '"');
      const matched: RegExpMatchArray | null = text.match(/https?:[^"'\s\\]+/);
      if (matched !== null && matched.length > 0) {
        this.finish(matched[0]);
        return;
      }
      this.hint = '暂未抓到直链，可点「重试」或返回手动播放';
    }).catch((error: Error) => {
      Logger.warn('SNIFF_PAGE', '读取结果失败：' + String(error));
    });
  }

  private finish(url: string): void {
    if (url.length > 0) {
      AppStorage.setOrCreate<string>('sniffedVideoUrl', url);
      Logger.info('SNIFF_PAGE', '抓到直链：' + url);
    } else {
      Logger.warn('SNIFF_PAGE', '未抓到直链，返回调用方');
    }
    if (Number(router.getLength()) > 1) {
      router.back();
    } else {
      void replaceRoute({ url: 'pages/Index' });
    }
  }

  build() {
    Column() {
      Row({ space: '10vp' }) {
        GhostButton({ label: '返回', compact: true, onTap: (): void => { this.finish(''); } })
        Text('解析分享页')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
        GhostButton({ label: '重试', compact: true, onTap: (): void => { this.inject(); } })
      }
        .width('100%')
        .padding({ left: '14vp', right: '14vp', top: (this.topSafeInset + 6) + 'vp', bottom: '6vp' })
      Text(this.hint)
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ left: '16vp', bottom: '6vp' })
      Web({ src: this.target, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .mixedMode(MixedMode.All)
        .onPageEnd(() => {
          this.ready = true;
          this.inject();
          setTimeout(() => { this.collect(); }, 1500);
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

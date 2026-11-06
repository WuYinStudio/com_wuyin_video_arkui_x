import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { router, window } from '@kit.ArkUI';
import { AppState } from '../common/AppState';
import { Logger } from '../common/Logger';
import { PosterStyle, ShareService } from '../common/ShareService';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, GlassChip, PrimaryButton } from '../common/UiWidgets';

// 左右滑动切换版式的判定阈值（vp）。
const SWIPE_SWITCH_THRESHOLD: number = 48;

/** 分享二维码页入参：由 ShareService.openQrPage 传入。 */
class ShareQrParams {
  link: string = '';
  title: string = '';
  subtitle: string = '';
  qrLink: string = '';
  /** 影片封面直链：封面卡 / 影幕版式使用。 */
  cover: string = '';
  /** 线路资源 JSON 分享：标题/副标题/页脚与封面使用专用文案。 */
  sourceMode: boolean = false;
}

/**
 * 分享二维码页：预览海报（二维码居中 + 中央 logo + 底部「打开无音影视扫一扫」），
 * 再由用户点「分享给好友」唤起系统分享面板，或「复制链接」兜底。
 */
@Entry
@Component
export struct ShareQrPage {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('themeVersion') @Watch('onThemeVersionChanged') private themeVersion: number = 0;
  @StorageLink('fontScale') @Watch('onFontScaleChanged') private fontScale: number = 1;
  @StorageLink('immersiveTopInset') private topInset: number = 24;
  @State private poster: image.PixelMap | undefined = undefined;
  @State private busy: boolean = true;
  @State private message: string = '';
  @State private sharing: boolean = false;
  /** 二维码载荷：精简链接优先，页面里的隐藏 QRCode 组件用它渲染。 */
  @State private qrContent: string = '';
  /** 海报版式：经典 / 极简 / 霓虹 / 杂志 / 封面卡 / 影幕，切换后立即重合成。 */
  @State private posterStyle: string = PosterStyle.CLASSIC;
  private params: ShareQrParams = new ShareQrParams();
  /** 线路分享的多张二维码载荷。 */
  @State private sourceParts: string[] = [];
  private sourceQrMounted: number = 0;
  /** 影片封面位图：封面类版式使用，只下载一次。 */
  private coverPixels: image.PixelMap | undefined = undefined;
  private coverRequested: boolean = false;
  /** 左右滑动换版式：按下位置与是否处于滑动中。 */
  private touchStartX: number = 0;
  private touchActive: boolean = false;
  /** 换版式时的淡出/缩放进场动画参数。 */
  @State private posterOpacity: number = 1;
  @State private posterScale: number = 1;
  private qrCodeMounted: boolean = false;
  private generateStarted: boolean = false;
  private generating: boolean = false;
  private pageGone: boolean = false;
  /** 进入本页前的窗口方向：退出时原样恢复（播放器全屏时是横屏）。 */
  private restoreOrientation: window.Orientation | undefined = undefined;
  private appWindow: window.Window | undefined = undefined;

  aboutToAppear(): void {
    try {
      const incoming: ShareQrParams | undefined = router.getParams() as ShareQrParams | undefined;
      if (incoming !== undefined && typeof incoming.link === 'string') {
        this.params = incoming;
      }
      if (this.params.sourceMode) {
        // 完整线路 JSON 从 AppStorage 取，避免路由参数长度限制把二维码内容截短。
        const stored: string = AppStorage.get<string>('sourceShareJson') || '';
        if (stored.length > 0) {
          this.params.link = stored;
          this.params.qrLink = stored;
        }
        this.sourceParts = AppStorage.get<string[]>('sourceShareParts') || [];
      }
      this.qrContent = ShareService.shareQrContent(this.params.qrLink, this.params.link);
      // 记住上次选的版式，下次进页面还是同一套风格。
      this.posterStyle = PosterStyle.normalize(AppStorage.get<string>('sharePosterStyle') ?? PosterStyle.CLASSIC);
      if (this.params.sourceMode) {
        // 线路分享：海报用当前主题壁纸做封面，页脚改为导入线路文案。
        ShareService.setPosterFooter('扫码即可导入本地资源线路');
        this.posterStyle = PosterStyle.COVER;
      } else {
        ShareService.setPosterFooter('扫码即可继续播放本剧集');
      }
      Logger.info('SHARE_PAGE', '进入分享二维码页，标题=' + this.params.title +
        '，链接长度=' + String(this.params.link.length) + '，二维码载荷长度=' + String(this.qrContent.length) +
        '，版式=' + this.posterStyle);
    } catch (error) {
      Logger.warn('SHARE_PAGE', '读取分享二维码参数失败：' + String(error));
    }
    // 兜底：QRCode 组件万一没触发 onAppear，也要在 800ms 后走一遍生成（会退回 ScanKit 出码）。
    setTimeout(() => {
      if (!this.pageGone && !this.generateStarted) {
        Logger.warn('SHARE_PAGE', 'QRCode 组件未就绪，直接生成海报');
        void this.generate();
      }
    }, 800);
    // 播放器全屏进来时窗口是横屏：本页固定竖屏展示，退出时恢复原方向。
    void this.forcePortrait();
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    // 页面退场动画还在用这张位图，延迟释放，避免动画期间底图被回收出现黑闪。
    this.releaseLater(this.poster);
    this.poster = undefined;
    const cover: image.PixelMap | undefined = this.coverPixels;
    this.coverPixels = undefined;
    if (cover !== undefined) {
      cover.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放封面位图失败'); });
    }
    void this.restoreWindowOrientation();
  }

  /** 进入本页：记住原方向并切到竖屏。 */
  private async forcePortrait(): Promise<void> {
    try {
      const target: window.Window = await window.getLastWindow(this.context());
      if (this.pageGone) { return; }
      this.appWindow = target;
      this.restoreOrientation = window.Orientation.PORTRAIT;
      await target.setPreferredOrientation(window.Orientation.PORTRAIT);
      Logger.info('SHARE_PAGE', '分享二维码页已切到竖屏，原方向=' + String(this.restoreOrientation));
    } catch (error) {
      Logger.warn('SHARE_PAGE', '切换竖屏失败：' + String(error));
    }
  }

  /** 离开本页：把窗口方向恢复成进来前的样子（播放器全屏时是横屏）。 */
  private async restoreWindowOrientation(): Promise<void> {
    const target: window.Window | undefined = this.appWindow;
    const state: window.Orientation | undefined = this.restoreOrientation;
    this.appWindow = undefined;
    this.restoreOrientation = undefined;
    if (target === undefined || state === undefined) { return; }
    try {
      await target.setPreferredOrientation(state);
      Logger.info('SHARE_PAGE', '已恢复原窗口方向=' + String(state));
    } catch (error) {
      Logger.warn('SHARE_PAGE', '恢复窗口方向失败：' + String(error));
    }
  }

  /** 延迟释放海报位图（换图或退场时调用）。 */
  private releaseLater(pixels: image.PixelMap | undefined): void {
    if (pixels === undefined) { return; }
    setTimeout(() => {
      pixels.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放海报位图失败'); });
    }, 600);
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 主题（主色/深浅）变化：二维码与海报配色都跟着变，需要重新合成。 */
  private onThemeVersionChanged(): void {
    if (this.pageGone) { return; }
    Logger.info('SHARE_PAGE', '主题变化，重新合成海报，themeVersion=' + String(this.themeVersion));
    void this.generate();
  }

  /** 系统字体大小变化：海报里的文字尺寸跟着变，需要重新合成一张。 */
  private onFontScaleChanged(): void {
    if (this.pageGone) { return; }
    Logger.info('SHARE_PAGE', '系统字体大小变化，重新合成海报，fontScale=' + String(this.fontScale));
    void this.generate();
  }

  /** QRCode 组件挂载后触发一次生成（等转屏与首帧都稳定后再截图）。 */
  private scheduleGenerate(): void {
    if (this.generateStarted) { return; }
    this.generateStarted = true;
    setTimeout(() => {
      if (!this.pageGone) { void this.generate(); }
    }, 260);
  }

  /** 把页面上隐藏的 QRCode 截成位图；失败或被遮住没渲染时返回 undefined，由 ShareService 退回 ScanKit。 */
  private async captureQrCode(): Promise<image.PixelMap | undefined> {
    let pixels: image.PixelMap | undefined = undefined;
    try {
      if (!this.qrCodeMounted || this.qrContent.length === 0) { return undefined; }
      const snapshot = this.getUIContext().getComponentSnapshot();
      pixels = await snapshot.get('share-qr-code');
      if (await ShareQrPage.isBlankPixelMap(pixels)) {
        // 截图是纯色（组件被背景遮住没有真正渲染）：这份图贴进海报会是一块空白色块。
        Logger.warn('SHARE_PAGE', 'QRCode 截图为空，改由扫码组件生成二维码');
        pixels.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放空二维码位图失败'); });
        return undefined;
      }
      Logger.info('SHARE_PAGE', 'QRCode 组件已截图');
      return pixels;
    } catch (error) {
      Logger.warn('SHARE_PAGE', 'QRCode 截图失败，改用扫码组件生成：' + String(error));
      return undefined;
    }
  }

  /** 截图线路分享的全部分片二维码。 */
  private async captureSourceQrCodes(): Promise<image.PixelMap[]> {
    const result: image.PixelMap[] = [];
    const snapshot = this.getUIContext().getComponentSnapshot();
    for (let index: number = 0; index < this.sourceParts.length; index++) {
      const pixels: image.PixelMap = await snapshot.get('share-src-qr-' + String(index));
      result.push(pixels);
    }
    if (result.length === 0) { throw new Error('二维码尚未渲染完成'); }
    return result;
  }

  /** 抽样判断位图是否几乎纯色（用于识别「截到空白」的二维码）。 */
  private static async isBlankPixelMap(pixels: image.PixelMap): Promise<boolean> {
    try {
      const info: image.ImageInfo = await pixels.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (!(width > 0) || !(height > 0)) { return true; }
      const buffer: ArrayBuffer = new ArrayBuffer(width * height * 4);
      await pixels.readPixelsToBuffer(buffer);
      const view: Uint8Array = new Uint8Array(buffer);
      let base: number = -1;
      for (let index: number = 0; index + 3 < view.length; index += 4 * 53) {
        const sum: number = view[index] + view[index + 1] + view[index + 2] + view[index + 3];
        if (base < 0) { base = sum; continue; }
        if (Math.abs(sum - base) > 60) { return false; }
      }
      return true;
    } catch (_) {
      // 读取失败就按「有内容」处理，避免把可用截图误判成空白。
      return false;
    }
  }

  /** 切换海报版式：记到 AppStorage，旧图淡出后立即重新合成，新图进场有动效。 */
  private selectStyle(style: string): void {
    const next: string = PosterStyle.normalize(style);
    AppStorage.setOrCreate('sharePosterStyle', next);
    if (next === this.posterStyle) { return; }
    this.posterStyle = next;
    this.animatePosterOut();
    Logger.info('SHARE_PAGE', '切换海报版式：' + next);
    void this.generate();
  }

  /** 按方向切换版式：delta = 1 下一个、-1 上一个（循环）。 */
  private switchStyleBy(delta: number): void {
    const all: string[] = PosterStyle.ALL;
    const index: number = all.indexOf(this.posterStyle);
    const base: number = index < 0 ? 0 : index;
    const nextIndex: number = ((base + delta) % all.length + all.length) % all.length;
    this.selectStyle(all[nextIndex]);
  }

  /** 旧海报淡出并轻微缩小，给新海报留出进场空间。 */
  private animatePosterOut(): void {
    try {
      this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseIn }, () => {
        this.posterOpacity = 0.15;
        this.posterScale = 0.97;
      });
    } catch (error) {
      Logger.warn('SHARE_PAGE', '海报淡出动画失败：' + String(error));
    }
  }

  /** 新海报淡入并回弹到原始大小。 */
  private animatePosterIn(): void {
    try {
      this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
        this.posterOpacity = 1;
        this.posterScale = 1;
      });
    } catch (error) {
      Logger.warn('SHARE_PAGE', '海报进场动画失败：' + String(error));
    }
  }

  /** 海报区域左右滑动：左滑切到下一个版式，右滑切回上一个。 */
  private onPosterTouch(event: TouchEvent): void {
    try {
      if (event.type === TouchType.Down) {
        this.touchStartX = event.touches.length > 0 ? event.touches[0].x : 0;
        this.touchActive = true;
        return;
      }
      if (event.type !== TouchType.Up && event.type !== TouchType.Cancel) { return; }
      if (!this.touchActive) { return; }
      this.touchActive = false;
      const endX: number = event.changedTouches.length > 0 ? event.changedTouches[0].x : this.touchStartX;
      const distance: number = endX - this.touchStartX;
      if (distance <= -SWIPE_SWITCH_THRESHOLD) {
        this.switchStyleBy(1);
      } else if (distance >= SWIPE_SWITCH_THRESHOLD) {
        this.switchStyleBy(-1);
      }
    } catch (error) {
      Logger.warn('SHARE_PAGE', '滑动切换版式失败：' + String(error));
    }
  }

  /** 下载影片封面（只尝试一次）；没有封面地址或失败时返回 undefined，版式会退回主题占位。 */
  private async ensureCover(): Promise<image.PixelMap | undefined> {
    if (this.coverPixels !== undefined) { return this.coverPixels; }
    if (this.coverRequested || this.params.cover.length === 0) { return undefined; }
    this.coverRequested = true;
    this.coverPixels = await ShareService.loadRemoteCover(this.params.cover);
    if (this.coverPixels === undefined) {
      Logger.warn('SHARE_PAGE', '封面不可用，封面类版式将用主题渐变占位');
    }
    return this.coverPixels;
  }

  /** 生成海报位图：QRCode 截图 → Canvas 拼海报；失败退纯二维码，再失败提示复制链接。 */
  private async generate(): Promise<void> {
    if (this.generating) { return; }
    this.generating = true;
    this.busy = true;
    this.message = '';
    const previous: image.PixelMap | undefined = this.poster;
    let qrPixels: image.PixelMap | undefined = undefined;
    let multiPixels: image.PixelMap[] = [];
    try {
      if (this.params.sourceMode && this.sourceParts.length > 0) {
        multiPixels = await this.captureSourceQrCodes();
        const cover: image.PixelMap | undefined = await this.ensureCover();
        this.poster = await ShareService.buildMultiQrPoster(this.context(), this.params.title,
          this.params.subtitle, multiPixels, cover);
      } else {
        qrPixels = await this.captureQrCode();
        const cover: image.PixelMap | undefined =
          PosterStyle.needsCover(this.posterStyle) ? await this.ensureCover() : undefined;
        this.poster = await ShareService.buildPosterOrQr(this.context(), this.params.link,
          this.params.title, this.params.subtitle, this.params.qrLink, qrPixels, this.posterStyle, cover);
      }
      this.releaseLater(previous);
      if (this.poster === undefined) {
        const reason: string = ShareService.lastPosterFailure;
        this.message = reason.length > 0 ? reason : '海报生成失败，可改用「复制链接」把参数发给对方';
      }
    } catch (error) {
      this.message = '海报生成失败：' + String(error);
      Logger.warn('SHARE_PAGE', '生成分享海报失败：' + String(error));
    } finally {
      if (qrPixels !== undefined) {
        qrPixels.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放二维码位图失败'); });
      }
      for (const pixels of multiPixels) {
        pixels.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放分片二维码位图失败'); });
      }
      this.busy = false;
      this.generating = false;
      // 新海报就位后再做进场动画，避免淡入到的是旧图。
      if (this.poster !== undefined) { this.animatePosterIn(); }
    }
  }

  private async share(): Promise<void> {
    const pixels: image.PixelMap | undefined = this.poster;
    if (pixels === undefined || this.sharing) { return; }
    this.sharing = true;
    try {
      const shared: boolean = await ShareService.sharePixels(this.context(), pixels, this.params.title);
      if (!shared) {
        const reason: string = ShareService.lastShareFailure;
        this.message = reason.length > 0 ? reason : '没能唤起系统分享，可改用「复制链接」';
      }
    } catch (error) {
      this.message = '分享失败：' + String(error);
      Logger.warn('SHARE_PAGE', '分享海报失败：' + String(error));
    } finally {
      this.sharing = false;
    }
  }

  private async copyLink(): Promise<void> {
    try {
      if (this.params.link.length === 0) { return; }
      await ShareService.copyShareLink(this.params.link);
    } catch (error) {
      this.message = '复制链接失败，请重试';
      Logger.warn('SHARE_PAGE', '复制分享链接失败：' + String(error));
    }
  }

  /** 逐个导出分片二维码图片，文件名：1_1.png、2_2.png…… */
  private async exportSourceParts(): Promise<void> {
    if (this.busy || this.sourceParts.length === 0) { return; }
    this.busy = true;
    let pixels: image.PixelMap[] = [];
    try {
      pixels = await this.captureSourceQrCodes();
      const names: string[] = [];
      for (let index: number = 0; index < pixels.length; index++) {
        names.push(String(index + 1) + '_' + String(index + 1) + '.png');
      }
      const targets: string[] = await new picker.DocumentViewPicker(this.context()).save({
        newFileNames: names,
        fileSuffixChoices: ['.png']
      });
      if (targets.length === 0) { return; }
      const packer: image.ImagePacker = image.createImagePacker();
      try {
        const limit: number = Math.min(targets.length, pixels.length);
        for (let index: number = 0; index < limit; index++) {
          const buffer: ArrayBuffer = await packer.packing(pixels[index],
            { format: 'image/png', quality: 100 });
          const file = fileIo.openSync(targets[index],
            fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
          try { fileIo.writeSync(file.fd, buffer); } finally { fileIo.closeSync(file); }
        }
      } finally {
        await packer.release();
      }
      this.message = '已导出 ' + String(pixels.length) + ' 张分片二维码';
      Logger.info('SHARE_PAGE', '分片二维码已导出，数量=' + String(pixels.length));
    } catch (error) {
      this.message = '导出分片二维码失败：' + String(error);
      Logger.warn('SHARE_PAGE', '导出分片二维码失败：' + String(error));
    } finally {
      for (const item of pixels) {
        item.release().catch((): void => { Logger.warn('SHARE_PAGE', '释放分片图片失败'); });
      }
      this.busy = false;
    }
  }

  private goBack(): void {    try {
      if (Number(router.getLength()) > 1) { void router.back(); return; }
      AppState.go('home');
      void router.pushUrl({ url: 'pages/Index' });
    } catch (error) {
      Logger.warn('SHARE_PAGE', '返回失败：' + String(error));
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 离屏二维码：放在最底层、被后面的不透明背景完全盖住，用户看不到但会正常渲染，
      // 生成海报时用 componentSnapshot 截图拼进去（不依赖 ScanKit 的生成接口）。
      if (this.params.sourceMode && this.sourceParts.length > 0) {
        Row({ space: 0 }) {
          ForEach(this.sourceParts, (part: string, index: number) => {
            Stack({ alignContent: Alignment.Center }) {
              QRCode(part)
                .width('100%')
                .height('100%')
                .color(ShareService.qrModuleHex(this.dark))
                .backgroundColor(ShareService.qrBackHex(this.dark));
              Text(String(index + 1))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(Ui.accentStrong(this.dark))
                .width('48vp')
                .height('48vp')
                .lineHeight('48vp')
                .textAlign(TextAlign.Center)
                .borderRadius('24vp')
                .backgroundColor('#FFFFFF')
                .shadow({ radius: 6, color: 'rgba(0,0,0,0.18)', offsetY: 2 })
                .hitTestBehavior(HitTestMode.None);
            }
              .width('300vp')
              .height('300vp')
              .id('share-src-qr-' + String(index))
              .hitTestBehavior(HitTestMode.None)
              .onAppear(() => {
                this.sourceQrMounted++;
                if (this.sourceQrMounted >= this.sourceParts.length) { this.scheduleGenerate(); }
              });
          }, (part: string, index: number) => 'src-qr-' + String(index));
        }
          .width((this.sourceParts.length * 300) + 'vp')
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None);
      } else {
        QRCode(this.qrContent)
          .width('200vp')
          .height('200vp')
          .color(ShareService.qrModuleHex(this.dark))
          .backgroundColor(ShareService.qrBackHex(this.dark))
          .id('share-qr-code')
          .hitTestBehavior(HitTestMode.None)
          .position({ x: 0, y: 0 })
          .onAppear(() => {
            this.qrCodeMounted = true;
            this.scheduleGenerate();
          });
      }

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.dark), 0], [Ui.pageBgAlt(this.dark), 1]]
        })
      AuroraBackdrop({ intensity: this.dark ? 1 : 0.9 })

      Column() {
        // 顶部：返回 + 标题
        Row({ space: 10 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left_circle'))
              .fontSize(Ui.fs('22vp', this.fontScale))
              .fontColor([Ui.ink(this.dark)]);
          }
            .width('40vp').height('40vp').padding(0)
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .accessibilityText('返回')
            .onClick(() => { this.goBack(); });
          Column({ space: '1vp' }) {
            Text('分享二维码')
              .fontSize(Ui.fs('20vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.dark));
            Text('让对方用手机扫一扫，直达本集播放')
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.dark))
              .maxLines(1);
          }
            .alignItems(HorizontalAlign.Start)
          Blank()
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)

        // 海报版式选择：经典 / 极简 / 霓虹 / 杂志，点一下立即重合成预览。
        Scroll() {
          Row({ space: '8vp' }) {
            ForEach(PosterStyle.ALL, (style: string) => {
              GlassChip({
                label: PosterStyle.label(style),
                selected: this.posterStyle === style,
                compact: true,
                onTap: (): void => { this.selectStyle(style); }
              })
            }, (style: string) => 'poster-style-' + style)
          }
            .padding({ top: '10vp', bottom: '2vp' })
        }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

        // 海报预览：直接展示合成好的位图，所见即分享出去的那张图。
        Scroll() {
          Column({ space: 10 }) {
            // 版式切换的浮动提示：左右滑动即可换一种海报。
            Text('左右滑动海报可切换版式 · 当前「' + PosterStyle.label(this.posterStyle) + '」')
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.dark))
              .width('100%')
              .textAlign(TextAlign.Center)
              .maxLines(1)
            if (this.poster !== undefined) {
              Image(this.poster)
                .width('100%')
                .objectFit(ImageFit.Contain)
                .borderRadius('20vp')
                .border({ width: 1, color: Ui.cardBorderSoft(this.dark) })
                .shadow({ radius: 20, color: Ui.shadowSoft(this.dark), offsetY: 10 })
                .interpolation(ImageInterpolation.High)
                .opacity(this.posterOpacity)
                .scale({ x: this.posterScale, y: this.posterScale })
                .onTouch((event: TouchEvent) => { this.onPosterTouch(event); })
                .accessibilityText('分享二维码海报，左右滑动可切换版式')
            } else if (this.busy) {
              Column({ space: 10 }) {
                LoadingProgress().width('34vp').height('34vp').color(Ui.accent(this.dark));
                Text('正在生成分享二维码…')
                  .fontSize(Ui.fs('13vp', this.fontScale))
                  .fontColor(Ui.inkSoft(this.dark));
              }
                .width('100%')
                .height('320vp')
                .justifyContent(FlexAlign.Center)
            } else {
              // 海报位图没合成出来时，直接用 QRCode 组件把二维码摆在页面上：
              // 至少当场可以扫码，不必依赖导出图片。
              Column({ space: 12 }) {
                Column({ space: 10 }) {
                  QRCode(this.qrContent)
                    .width('220vp')
                    .height('220vp')
                    .color(ShareService.qrModuleHex(this.dark))
                    .backgroundColor(ShareService.qrBackHex(this.dark))
                  Text('打开无音影视扫一扫')
                    .fontSize(Ui.fs('14vp', this.fontScale))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Ui.accentStrong(this.dark));
                }
                  .padding('18vp')
                  .borderRadius('20vp')
                  .backgroundColor(ShareService.qrBackHex(this.dark))
                Text(this.message.length > 0 ? this.message : '海报生成失败')
                  .fontSize(Ui.fs('12.5vp', this.fontScale))
                  .fontColor(Ui.gold(this.dark))
                  .textAlign(TextAlign.Center)
                  .maxLines(3);
                GhostButton({ label: '重新生成海报', compact: true, onTap: (): void => { void this.generate(); } });
              }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: '6vp' })
            }

            if (this.message.length > 0 && this.poster !== undefined) {
              Text(this.message)
                .fontSize(Ui.fs('12vp', this.fontScale))
                .fontColor(Ui.gold(this.dark))
                .width('100%')
                .textAlign(TextAlign.Center);
            }
            if (this.params.sourceMode && this.sourceParts.length > 0) {
              Row() {
                GhostButton({
                  label: '导出分片二维码',
                  compact: true,
                  onTap: (): void => { void this.exportSourceParts(); }
                });
              }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: '8vp' });
            }
          }
            .width('100%')
            .padding({ top: '14vp', bottom: '18vp' })
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

        // 底部操作：分享 / 复制链接
        Row({ space: '12vp' }) {
          Button(this.sharing ? '正在分享…' : '分享给好友')
            .height('46vp')
            .fontSize(Ui.fs('15vp', this.fontScale))
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .backgroundColor(this.poster !== undefined ? Ui.accent(this.dark) : Ui.inkFaint(this.dark))
            .borderRadius('23vp')
            .enabled(this.poster !== undefined && !this.sharing)
            .accessibilityText('分享给好友')
            .onClick(() => { void this.share(); });
          Button('复制链接')
            .height('46vp')
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor(Ui.ink(this.dark))
            .padding({ left: '18vp', right: '18vp' })
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .borderRadius('23vp')
            .enabled(this.params.link.length > 0)
            .accessibilityText('复制分享链接')
            .onClick(() => { void this.copyLink(); });
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ bottom: '10vp' })
      }
        .width('100%')
        .height('100%')
        .padding({ left: '16vp', right: '16vp', top: (this.topInset + 8) + 'vp' })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.dark))
  }
}

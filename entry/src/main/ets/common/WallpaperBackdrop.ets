import router from '@ohos.router';
import { Logger } from './Logger';
import { WallpaperKind, WallpaperService } from './WallpaperService';

/**
 * 跨页面的动态背景播放位置。
 *
 * 每个页面都会有一份背景图层（ArkUI 没有"窗口级背景层"），切页时新图层从上次位置续播，
 * 观感上像同一张背景一直在播，而不是每次切页都从 0 秒重新开始。
 */
class WallpaperRuntime {
  static position: number = 0;
}

/**
 * 全局背景图层（本地导入的图片 / GIF / 视频）。
 *
 * - 视频：ArkUI 原生 Video 组件，静音 + 循环 + 无控制条，currentProgressRate 控制 0.5/1/1.5x；
 * - GIF：Image 组件按系统动图能力循环播放；
 * - 图片：Image 组件铺满。
 *
 * 只读取已经导入到沙箱的静态导出资源，不做任何外部引擎实时渲染。
 * 该组件铺在页面底色之上、内容之下，并且 hitTestBehavior(None)，不拦截任何手势。
 */
@Component
export struct WallpaperBackdrop {
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('wallpaperMediaVersion') @Watch('onSourceChanged') private version: number = 0;
  @StorageLink('wallpaperMediaKind') private kind: string = '';
  @StorageLink('wallpaperMediaUri') private uri: string = '';
  @StorageLink('wallpaperOpacity') private backdropOpacity: number = 0.85;
  @StorageLink('wallpaperRate') @Watch('onRateChanged') private rate: number = 1;
  @StorageLink('wallpaperMotion') @Watch('onMotionChanged') private motion: boolean = true;
  /** 宿主页面/标签页是否在前台（首页在自己不是当前 Tab 时传 false）。 */
  @Prop hostVisible: boolean = true;
  /** 当前最上层路由页：被别的页面盖住时销毁 Video，避免返回时 Surface 失效变黑。 */
  @StorageLink('wallpaperTopRoute') private topRoute: string = '';
  @StorageLink('wallpaperTopRoutePath') private topRoutePath: string = '';
  @StorageLink('wallpaperTopIndex') private topIndex: number = -1;
  /** Video 的构造参数（src / 速率）变化时用 key 强制重建，确保新速率一定生效。 */
  @State private videoKeys: number[] = [0];
  private controller: VideoController = new VideoController();
  private prepared: boolean = false;
  private resumed: boolean = false;
  private ownRoute: string = '';
  private ownPath: string = '';
  private ownIndex: number = -1;

  aboutToAppear(): void {
    try {
      // 本组件所在页面（Tab 页统一算宿主 Index）：与最上层路由比较后决定是否渲染视频。
      const state = router.getState();
      this.ownRoute = state.name;
      this.ownPath = state.path;
      const index: number = Number(state.index);
      this.ownIndex = Number.isFinite(index) ? index : -1;
    } catch (error) {
      Logger.warn('WALLPAPER_BACKDROP', '读取当前页面路由失败：' + String(error));
    }
  }

  /**
   * 是否处于最上层可见页面。
   *
   * 优先用路由栈序号（与路由命名无关，最稳）；名字/路径仅作兜底。
   * 任一信息取不到、或两侧名字一致时都按"可见"处理：宁可多渲染一份，
   * 也不能因为路由信息缺失把背景整片藏掉。只有确认是"更下层的页面"才隐藏。
   */
  private routeVisible(): boolean {
    const topKnown: boolean = this.topIndex >= 0 ||
      this.topRoute.length > 0 || this.topRoutePath.length > 0;
    const ownKnown: boolean = this.ownIndex >= 0 ||
      this.ownRoute.length > 0 || this.ownPath.length > 0;
    if (!topKnown || !ownKnown) {
      return true;
    }
    if (this.ownIndex >= 0 && this.topIndex >= 0 && this.ownIndex === this.topIndex) {
      return true;
    }
    // 上层页面信息为空：无法判断，保持可见（首屏 / 路由事件尚未到达的情况）。
    if (this.topRoute.length === 0 && this.topRoutePath.length === 0) {
      return true;
    }
    const nameConflict: boolean = this.ownRoute.length > 0 && this.topRoute.length > 0 &&
      !WallpaperService.sameRoute(this.ownRoute, this.topRoute);
    const pathConflict: boolean = this.ownPath.length > 0 && this.topRoutePath.length > 0 &&
      !WallpaperService.sameRoute(this.ownPath, this.topRoutePath);
    // 只有拿到"名字对不上"的明确证据才隐藏；任一侧缺失都保留渲染。
    return !(nameConflict || pathConflict);
  }

  private mediaVisible(): boolean {
    return this.hostVisible && this.routeVisible();
  }

  private resolvedOpacity(): number {
    const value: number = Number(this.backdropOpacity);
    if (!Number.isFinite(value)) {
      return 0.85;
    }
    return Math.max(WallpaperService.OPACITY_MIN, Math.min(1, value));
  }

  private rateValue(): number {
    return WallpaperService.normalizeRate(this.rate);
  }

  /** 压暗一点点，保证视频背景上的玻璃卡片与文字仍然清晰。 */
  private scrimColor(): string {
    return this.dark ? '#33000000' : '#1F0B1220';
  }

  private rebuild(): void {
    this.prepared = false;
    this.resumed = false;
    this.videoKeys = [this.videoKeys[0] + 1];
  }

  private onSourceChanged(): void {
    this.rebuild();
  }

  private onRateChanged(): void {
    // 播放速率是 Video 的构造参数，重建一次最稳妥；位置由 WallpaperRuntime 续上。
    this.rebuild();
  }

  private onMotionChanged(): void {
    try {
      if (!this.prepared) {
        return;
      }
      if (this.motion) {
        this.controller.start();
      } else {
        this.controller.pause();
      }
    } catch (error) {
      Logger.warn('WALLPAPER_BACKDROP', '切换背景动效失败：' + String(error));
    }
  }

  private onReady(): void {
    this.prepared = true;
    if (!this.motion) {
      try {
        this.controller.pause();
      } catch (error) {
        Logger.warn('WALLPAPER_BACKDROP', '暂停背景视频失败：' + String(error));
      }
    }
    if (!this.resumed && WallpaperRuntime.position > 0.3) {
      this.resumed = true;
      try {
        this.controller.setCurrentTime(WallpaperRuntime.position, SeekMode.Accurate);
      } catch (error) {
        Logger.warn('WALLPAPER_BACKDROP', '续接背景播放位置失败：' + String(error));
      }
    }
  }

  private remember(time: number): void {
    if (Number.isFinite(time) && time >= 0) {
      WallpaperRuntime.position = time;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.mediaVisible() && this.kind === WallpaperKind.VIDEO && this.uri.length > 0) {
        ForEach(this.videoKeys, (_key: number) => {
          Video({
            src: this.uri,
            controller: this.controller,
            currentProgressRate: this.rateValue()
          })
            .muted(true)
            .autoPlay(this.motion)
            .controls(false)
            .loop(true)
            .objectFit(ImageFit.Cover)
            .width('100%')
            .height('100%')
            .opacity(this.resolvedOpacity())
            .onPrepared((_info: PreparedInfo): void => { this.onReady(); })
            .onUpdate((info: PlaybackInfo): void => { this.remember(info.time); })
            .onError((): void => {
              Logger.warn('WALLPAPER_BACKDROP', '动态背景解码失败：' + this.uri);
            })
            .hitTestBehavior(HitTestMode.None)
        }, (key: number) => 'wallpaper-video-' + String(key))
      } else if (this.mediaVisible() && this.uri.length > 0) {
        Image(this.uri)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .width('100%')
          .height('100%')
          .opacity(this.resolvedOpacity())
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.mediaVisible() && this.uri.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.scrimColor())
          .hitTestBehavior(HitTestMode.None)
      }
    }
      .width('100%')
      .height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
  }
}

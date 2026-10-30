import { Scene } from '@kit.ArkGraphics3D';
import { Logger } from '../common/Logger';
import {
  VRSpatialRuntime, VRRuntimeOptions, VRRuntimeResult, VRScreenMode, VRScreenTransform,
    VRPlaybackState, VRPlaybackRequest, VRPlaybackAction, VRInput, VRRay, VRVector,
    VRPose, VRQuaternion, VRPanelState, vrDefaultTransform, vrClamp, vrHitFlat
} from '../common/VRSpatialRuntime';

export interface VRPlayerPresentation {
  native: boolean;
  transform: VRScreenTransform;
}
interface VRModeOption { mode: VRScreenMode; title: string; }

/**
* 独立空间控制组件。视频播放、协播、选集和记录始终由 PlayerPage 负责。
* 普通设备仅对原 XComponent 做平直大屏透视预览，不截屏、不创建第二个播放器。
* 真实 XR 只能由通过目标 SDK 核验的 VRNativeAdapter 提供；未接入时不开放弧幕/球幕。
* Component3D 只呈现适配器返回的 ArkGraphics 3D 场景，不伪造 XR 会话。
*/
@Component
export struct VRPlayer {
  @Prop @Watch('onActivationChanged') active: boolean = false;
  @Prop @Watch('onActivationChanged') sourceReady: boolean = false;
  @Prop playback: VRPlaybackState = {
    playing: false, currentMs: 0, durationMs: 0, speedIndex: 1,
      episodeIndex: 0, episodeCount: 0, volume: 1, locked: false
  };
  @Prop @Watch('onAspectChanged') aspect: number = 16 / 9;
  @Prop viewportHeight: number = 300;
  runtime: VRSpatialRuntime = new VRSpatialRuntime();
  options: () => VRRuntimeOptions | undefined = (): VRRuntimeOptions | undefined => undefined;
  onAction: (request: VRPlaybackRequest) => Promise<void> = async (_request: VRPlaybackRequest): Promise<void> => {};
  onPresentation: (presentation: VRPlayerPresentation) => void = (_presentation: VRPlayerPresentation): void => {};
  onNotice: (message: string) => void = (_message: string): void => {};

  @State private scene?: Scene;
  @State private nativeMode: boolean = false;
  @State private status: string = '平直大屏预览 · 普通立体声';
  @State private mode: VRScreenMode = VRScreenMode.FLAT;
  @State private screen: VRScreenTransform = vrDefaultTransform();
  @State private menuVisible: boolean = true;
  @State private focused: boolean = false;
  @State private starting: boolean = false;
  @State private brightness: number = 1;
  private readonly modes: VRModeOption[] = [
    { mode: VRScreenMode.FLAT, title: '平直巨幕' },
    { mode: VRScreenMode.HALF, title: '180°弧形幕' },
    { mode: VRScreenMode.SPHERE, title: '360°全景' }
];
  private disposed: boolean = false;
  private revision: number = 0;
  private timer: number = -1;
  private updating: boolean = false;
  private modePending: boolean = false;
  private selectedBefore: boolean = false;
  private menuBefore: boolean = false;
  private requestBefore: boolean = false;
  private dwellStart: number = 0;
  private dwellOpened: boolean = false;
  private panStart: VRScreenTransform = vrDefaultTransform();
  private pinchStart: number = 1;
  private lastNotice: string = '';

  aboutToAppear(): void {
    this.disposed = false;
    void this.synchronize();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    ++this.revision;
    this.clearTimer();
    this.scene = undefined;
    void this.runtime.exit().catch((error: Error): void => {
      Logger.error('VR_PLAYER', '组件离开时释放空间资源失败：' + String(error));
    });
  }

  private onActivationChanged(): void { void this.synchronize(); }

  private onAspectChanged(): void {
    try {
      if (this.active && this.sourceReady && this.nativeMode && !this.disposed) {
        void this.changeMode(this.mode);
      }
    } catch (error) { Logger.warn('VR_PLAYER', '同步视频比例到空间幕面失败：' + String(error)); }
  }

  private copyTransform(value: VRScreenTransform): VRScreenTransform {
    const position: VRVector = { x: value.position.x, y: value.position.y, z: value.position.z };
    const result: VRScreenTransform = { position: position, yaw: value.yaw, pitch: value.pitch, scale: value.scale };
    return result;
  }

  private present(): void {
    try {
      const presentation: VRPlayerPresentation = { native: this.nativeMode, transform: this.copyTransform(this.screen) };
      this.onPresentation(presentation);
    } catch (error) { Logger.error('VR_PLAYER', '通知原视频预览布局失败：' + String(error)); }
  }

  private notice(message: string): void {
    try { this.onNotice(message); }
    catch (error) { Logger.warn('VR_PLAYER', '显示空间模式提示失败：' + String(error)); }
  }

  private async synchronize(): Promise<void> {
    const revision: number = ++this.revision;
    this.clearTimer();
    this.scene = undefined;
    this.nativeMode = false;
    this.modePending = false;
    this.focused = false;
    this.dwellStart = 0;
    this.dwellOpened = false;
    this.selectedBefore = false;
    this.menuBefore = false;
    this.requestBefore = false;
    this.starting = this.active && this.sourceReady;
    try {
      if (!this.active || !this.sourceReady || this.disposed) {
        await this.runtime.exit();
        if (revision !== this.revision || this.disposed) { return; }
        if (!this.active) {
          this.screen = vrDefaultTransform(); this.mode = VRScreenMode.FLAT;
          this.menuVisible = true; this.lastNotice = ''; this.brightness = 1;
        }
        this.status = this.active ? '正在准备原播放源…' : '平直大屏预览 · 普通立体声';
        this.present();
        return;
      }
      const options: VRRuntimeOptions | undefined = this.options();
      if (!options) { this.status = '原播放器尚未就绪'; this.present(); return; }
      const result: VRRuntimeResult = await this.runtime.enter(options, this.screen);
      if (revision !== this.revision || this.disposed || !this.active || !this.sourceReady) { return; }
      this.nativeMode = result.native;
      this.scene = result.scene;
      this.status = result.message;
      if (!result.native) { this.mode = VRScreenMode.FLAT; }
      else if (this.mode !== VRScreenMode.FLAT) {
        if (!await this.runtime.setMode(this.mode, this.aspect)) { this.mode = VRScreenMode.FLAT; }
        if (revision !== this.revision || this.disposed) { return; }
      }
      this.present();
      if (result.message !== this.lastNotice) { this.lastNotice = result.message; this.notice(result.message); }
      if (result.native) {
        // 视频刷新由同一个 AVPlayer 驱动；轮询仅负责控制、姿态和空间音源位置。
        this.timer = setInterval((): void => { void this.tick(revision); }, 50);
      }
    } catch (error) {
      Logger.error('VR_PLAYER', '同步空间组件生命周期失败：' + String(error));
      if (revision === this.revision && !this.disposed) {
        this.status = '空间资源异常，请退出大屏模式';
        this.notice(this.status); this.present();
      }
    } finally { if (revision === this.revision) { this.starting = false; } }
  }

  private clearTimer(): void {
    try { if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; } }
    catch (error) { Logger.warn('VR_PLAYER', '停止空间输入轮询失败：' + String(error)); }
  }

  private async tick(revision: number): Promise<void> {
    if (revision !== this.revision || this.updating || this.disposed || !this.active || !this.sourceReady) { return; }
    this.updating = true;
    try {
      // 必须把菜单显隐、注视焦点及亮度交给真实空间面板，而不只改变 ArkUI 浮层。
      const panel: VRPanelState = { visible: this.menuVisible, focused: this.focused, brightness: this.brightness };
      await this.runtime.update(this.playback, this.copyTransform(this.screen), panel);
      if (revision !== this.revision || this.disposed) { return; }
      const input: VRInput | undefined = await this.runtime.input();
      if (revision !== this.revision || this.disposed || !input) { return; }
      this.consumeInput(input);
    } catch (error) { Logger.error('VR_PLAYER', '空间状态与交互更新失败：' + String(error)); }
    finally { this.updating = false; }
  }

  private gazeRay(input: VRInput): VRRay | undefined {
    try {
      const pose: VRPose = input.eye.tracked ? input.eye : input.head;
      if (!pose.tracked) { return undefined; }
      const q: VRQuaternion = pose.rotation;
      const norm: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
      if (!Number.isFinite(norm) || norm < 0.00001) { return undefined; }
      const x: number = q.x / norm; const y: number = q.y / norm;
      const z: number = q.z / norm; const w: number = q.w / norm;
      const direction: VRVector = { x: -2 * (x * z + w * y), y: 2 * (w * x - y * z), z: 2 * (x * x + y * y) - 1 };
      const ray: VRRay = { origin: pose.position, direction: direction };
      return ray;
    } catch (error) { Logger.warn('VR_PLAYER', '计算头眼注视射线失败：' + String(error)); return undefined; }
  }

  private consumeInput(input: VRInput): void {
    try {
      const ray: VRRay | undefined = input.ray || this.gazeRay(input);
      // 弧面/球面精确拾取由已核验的设备适配器负责，不能冒用平面命中结果。
      this.focused = input.screenHit !== undefined ? input.screenHit :
        (this.mode === VRScreenMode.FLAT && ray !== undefined && vrHitFlat(ray, this.screen, this.aspect));
      if (this.focused) {
        if (this.dwellStart === 0) { this.dwellStart = Date.now(); }
        if (!this.dwellOpened && Date.now() - this.dwellStart >= 900) {
          this.menuVisible = true; this.dwellOpened = true;
        }
      } else { this.dwellStart = 0; this.dwellOpened = false; }
      const selectEdge: boolean = input.select && !this.selectedBefore;
      if (input.menu && !this.menuBefore) { this.menuVisible = !this.menuVisible; }
      if (selectEdge && this.focused) { this.menuVisible = true; }
      this.selectedBefore = input.select; this.menuBefore = input.menu;
      // 适配器应仅在点击事件那一帧提供 request。兼容按住选中时重复采样，避免连续切集。
      // 面板命中不同于幕面命中，不能要求 focused 才分发空间面板点击。
      if (input.request && (!this.requestBefore || selectEdge)) {
        const request: VRPlaybackRequest = { action: input.request.action, value: input.request.value };
        void this.send(request.action, request.value);
      }
      this.requestBefore = input.request !== undefined;
      if (input.dragging && this.focused) {
        const next: VRScreenTransform = this.copyTransform(this.screen);
        next.position.x = vrClamp(next.position.x + input.translation.x, -5, 5);
        next.position.y = vrClamp(next.position.y + input.translation.y, -3, 3);
        next.position.z = vrClamp(next.position.z + input.translation.z, -12, -1);
        next.scale = vrClamp(next.scale + input.scaleDelta, 0.3, 2.5);
        this.screen = next; this.present();
      }
    } catch (error) { Logger.error('VR_PLAYER', '处理注视、射线或手柄拖拽失败：' + String(error)); }
  }

  private async send(action: VRPlaybackAction, value: number = 0): Promise<void> {
    const revision: number = this.revision;
    try {
      if (this.disposed || !this.active) { return; }
      if (action !== VRPlaybackAction.EXIT && this.playback.locked) {
        this.notice('协同同播中，仅主控设备可控制播放'); return;
      }
      if (!Number.isFinite(value)) { throw new Error('空间控制参数不是有限数值'); }
      switch (action) {
        case VRPlaybackAction.TOGGLE:
          case VRPlaybackAction.PREVIOUS:
          case VRPlaybackAction.NEXT:
          case VRPlaybackAction.SEEK:
          case VRPlaybackAction.SPEED:
          case VRPlaybackAction.VOLUME:
          case VRPlaybackAction.BRIGHTNESS:
          case VRPlaybackAction.EXIT:
          break;
        default:
          throw new Error('未知空间控制操作');
      }
      const request: VRPlaybackRequest = { action: action, value: value };
      await this.onAction(request);
      if (revision === this.revision && !this.disposed && action === VRPlaybackAction.BRIGHTNESS) {
        this.brightness = vrClamp(value, 0.05, 1);
      }
    } catch (error) { Logger.error('VR_PLAYER', '空间迷你控制操作失败：' + String(error)); this.notice('操作失败，请重试'); }
  }

  private async changeMode(mode: VRScreenMode): Promise<void> {
    const revision: number = this.revision;
    try {
      if (this.modePending || !this.active || this.disposed) { return; }
      if (!this.nativeMode) {
        if (mode !== VRScreenMode.FLAT) { this.notice('当前仅支持原视频平直大屏预览；弧幕和全景需要真实 XR 视频纹理适配'); }
        return;
      }
      this.modePending = true;
      if (await this.runtime.setMode(mode, this.aspect) && revision === this.revision && !this.disposed) { this.mode = mode; }
    } catch (error) { Logger.error('VR_PLAYER', '切换空间幕型失败：' + String(error)); this.notice('幕型切换失败'); }
    finally { if (revision === this.revision) { this.modePending = false; } }
  }

  private changeScale(value: number): void {
    try { const next: VRScreenTransform = this.copyTransform(this.screen); next.scale = vrClamp(value, 0.3, 2.5); this.screen = next; this.present(); }
    catch (error) { Logger.error('VR_PLAYER', '缩放大屏失败：' + String(error)); }
  }

  private moveScreen(axis: number, value: number): void {
    try {
      const next: VRScreenTransform = this.copyTransform(this.screen);
      if (axis === 0) { next.position.x = vrClamp(value, -5, 5); }
      else if (axis === 1) { next.position.y = vrClamp(value, -3, 3); }
      else { next.position.z = vrClamp(value, -12, -1); }
      this.screen = next; this.present();
    } catch (error) { Logger.error('VR_PLAYER', '平移大屏失败：' + String(error)); }
  }

  private resetView(): void {
    try { this.screen = vrDefaultTransform(); this.present(); }
    catch (error) { Logger.error('VR_PLAYER', '重置大屏位置失败：' + String(error)); }
  }

  private panBegin(): void {
    try { this.panStart = this.copyTransform(this.screen); }
    catch (error) { Logger.warn('VR_PLAYER', '开始预览拖动失败：' + String(error)); }
  }

  private panMove(event: GestureEvent): void {
    try {
      if (this.nativeMode || !this.active) { return; }
      const next: VRScreenTransform = this.copyTransform(this.panStart);
      next.yaw = vrClamp(this.panStart.yaw + event.offsetX / 6, -65, 65);
      next.pitch = vrClamp(this.panStart.pitch - event.offsetY / 6, -45, 45);
      this.screen = next; this.present();
    } catch (error) { Logger.error('VR_PLAYER', '触屏或鼠标拖动预览失败：' + String(error)); }
  }

  private pinchBegin(): void {
    try { this.pinchStart = this.screen.scale; }
    catch (error) { Logger.warn('VR_PLAYER', '开始双指缩放失败：' + String(error)); }
  }

  private pinchMove(event: GestureEvent): void {
    try { if (!this.nativeMode && this.active) { this.changeScale(this.pinchStart * event.scale); } }
    catch (error) { Logger.error('VR_PLAYER', '双指缩放预览失败：' + String(error)); }
  }

  private toggleMenu(): void {
    try { this.menuVisible = !this.menuVisible; }
    catch (error) { Logger.warn('VR_PLAYER', '呼出大屏控制失败：' + String(error)); }
  }

  private time(value: number): string {
    const seconds: number = Math.floor(Math.max(0, value) / 1000);
    return Math.floor(seconds / 60) + ':' + (seconds % 60).toString().padStart(2, '0');
  }

  @Builder private miniPanel() {
    Scroll() {
      Column({ space: 8 }) {
        Text(this.playback.locked ? '协播接收端 · 播放控制已锁定' : '迷你控制 · 沿用原播放器与协播').fontSize(12).fontColor('#BCD4EE').width('100%');
        Row({ space: 8 }) {
          Button('上一集').layoutWeight(1).height(36).enabled(!this.playback.locked && this.playback.episodeIndex > 0)
            .onClick((): void => { void this.send(VRPlaybackAction.PREVIOUS); });
          Button(this.playback.playing ? '暂停' : '播放').layoutWeight(1).height(36).enabled(!this.playback.locked)
            .onClick((): void => { void this.send(VRPlaybackAction.TOGGLE); });
          Button('下一集').layoutWeight(1).height(36).enabled(!this.playback.locked && this.playback.episodeIndex < this.playback.episodeCount - 1)
            .onClick((): void => { void this.send(VRPlaybackAction.NEXT); });
        }.width('100%');
        Text(this.time(this.playback.currentMs) + ' / ' + this.time(this.playback.durationMs) + ' · 第' + (this.playback.episodeIndex + 1) + '集').fontSize(12).fontColor('#E8F2FF');
        Slider({ value: this.playback.currentMs, min: 0, max: Math.max(1, this.playback.durationMs), step: 1000 })
          .enabled(!this.playback.locked && this.playback.durationMs > 0)
          .onChange((value: number, change: SliderChangeMode): void => { if (change === SliderChangeMode.End) { void this.send(VRPlaybackAction.SEEK, value); } });
        Button('倍速 ' + ['0.75×', '1.0×', '1.25×', '1.75×', '2.0×'][this.playback.speedIndex]).height(36).width('100%').enabled(!this.playback.locked)
          .onClick((): void => { void this.send(VRPlaybackAction.SPEED, (this.playback.speedIndex + 1) % 5); });
        Text('音量').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: this.playback.volume, min: 0, max: 1, step: 0.05 }).enabled(!this.playback.locked)
          .onChange((value: number): void => { void this.send(VRPlaybackAction.VOLUME, value); });
        Text('画面亮度（视频遮罩，不修改系统亮度）').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: this.brightness, min: 0.05, max: 1, step: 0.05 }).enabled(!this.playback.locked)
          .onChange((value: number): void => { void this.send(VRPlaybackAction.BRIGHTNESS, value); });
        Row({ space: 4 }) {
          ForEach(this.modes, (option: VRModeOption) => {
            Button(option.title).layoutWeight(1).height(36).fontSize(11)
              .backgroundColor(this.mode === option.mode ? '#286395' : '#26374F')
              .accessibilityText(option.title + (!this.nativeMode && option.mode !== VRScreenMode.FLAT ? '，当前设备未接入' : ''))
              .onClick((): void => { void this.changeMode(option.mode); });
          }, (option: VRModeOption): string => option.mode);
        }.width('100%');
        Text('平直幕透视预览 · 鼠标/单指拖动 · 双指缩放').fontSize(12).fontColor('#BCD4EE').width('100%');
        Text('缩放').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: this.screen.scale, min: 0.3, max: 2.5, step: 0.05 }).onChange((value: number): void => { this.changeScale(value); });
        Text('水平位置').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: this.screen.position.x, min: -5, max: 5, step: 0.1 }).onChange((value: number): void => { this.moveScreen(0, value); });
        Text('垂直位置').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: this.screen.position.y, min: -3, max: 3, step: 0.1 }).onChange((value: number): void => { this.moveScreen(1, value); });
        Text('观看距离').fontSize(12).fontColor('#BCD4EE').width('100%');
        Slider({ value: -this.screen.position.z, min: 1, max: 12, step: 0.1 }).onChange((value: number): void => { this.moveScreen(2, -value); });
        Button('重置视角与屏幕位置').width('100%').height(36).onClick((): void => { this.resetView(); });
        Text('当前没有真实 XR 会话、视频纹理或空间音频；弧幕和球幕不可用。普通影片不会自动转换成全景内容。').fontSize(12).fontColor('#FFD6A4').width('100%');
      }.width('100%').padding(12);
    }.width('92%').constraintSize({ maxWidth: 420, maxHeight: Math.max(100, this.viewportHeight - 100) })
      .backgroundColor('#EE142338').borderRadius(16).scrollBar(BarState.Auto)
      .onTouch((event: TouchEvent): void => {
      try { event.stopPropagation(); }
      catch (error) { Logger.warn('VR_PLAYER', '拦截预览面板触摸失败：' + String(error)); }
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.nativeMode && this.scene) {
        Component3D({ scene: this.scene, modelType: ModelType.SURFACE }).width('100%').height('100%').hitTestBehavior(HitTestMode.None);
      }
      Column().width('100%').height('100%').backgroundColor('#00000000')
        .gesture(GestureGroup(GestureMode.Parallel,
        PanGesture().onActionStart((): void => { this.panBegin(); }).onActionUpdate((event: GestureEvent): void => { this.panMove(event); }),
        PinchGesture().onActionStart((): void => { this.pinchBegin(); }).onActionUpdate((event: GestureEvent): void => { this.pinchMove(event); }),
        TapGesture().onAction((): void => { this.toggleMenu(); })
      ));
      // 原生空间焦点和面板由适配器绘制；下方 ArkUI 仅作设备屏幕的状态/退出入口。
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(this.starting ? '正在进入空间模式…' : this.status).fontSize(12).fontColor('#ECF5FF').layoutWeight(1).maxLines(2);
          Button(this.menuVisible ? '收起' : '控制').height(36).fontSize(12).onClick((): void => { this.toggleMenu(); });
          Button('退出VR').height(36).fontSize(12).onClick((): void => { void this.send(VRPlaybackAction.EXIT); });
        }.width('100%').padding(8).backgroundColor('#D9142338').borderRadius(12)
          .onTouch((event: TouchEvent): void => {
          try { event.stopPropagation(); }
          catch (error) { Logger.warn('VR_PLAYER', '拦截空间状态栏触摸失败：' + String(error)); }
        });
        if (this.menuVisible && !this.nativeMode) { this.miniPanel(); }
        Blank().hitTestBehavior(HitTestMode.None);
      }.width('100%').height('100%').padding(8).hitTestBehavior(HitTestMode.Transparent);
    }.width('100%').height('100%').visibility(this.active ? Visibility.Visible : Visibility.None);
  }
}

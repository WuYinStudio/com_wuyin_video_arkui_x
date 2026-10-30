import { common } from '@kit.AbilityKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { AppBrightnessUtil } from '../common/AppBrightnessUtil';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';

// 只由视频画面的 Stack 挂载，控制栏、选集和弹窗不属于此手势区域。
@Component
export struct PlayerGestureLayer {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop currentMs: number = 0;
  @Prop durationMs: number = 0;
  @Prop volumeValue: number = 1;
  @Prop @Watch('onReceiverLockChanged') receiverLocked: boolean = false;
  @Prop @Watch('onReceiverLockChanged') isSlaveMode: boolean = false;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  onReveal: () => void = (): void => {};
  onToggleControls: () => void = (): void => {};
  onToggle: () => Promise<void> = async (): Promise<void> => {};
  onSeek: (targetMs: number) => Promise<void> = async (_targetMs: number): Promise<void> => {};
  onVolume: (level: number) => void = (_level: number): void => {};
  onBrightnessMask: (level: number) => void = (_level: number): void => {};
  @State private hintVisible: boolean = false;
  @State private hintText: string = '';
  @State private hintKind: string = 'seek';
  private playerBrightness: AppBrightnessUtil = new AppBrightnessUtil();
  private lightLevel: number = 0.5;
  private brightnessTouched: boolean = false;
  // 从机首次挂载不初始化本地亮度；断开解锁后再恢复原有亮度手势准备。
  private brightnessPrepared: boolean = false;
  private brightnessPreparing: boolean = false;
  private soundLevel: number = 1;
  private measuredSpan: number = 1;
  private axis: string = '';
  private tracking: boolean = false;
  private leftSide: boolean = true;
  private startMs: number = 0;
  private targetMs: number = 0;
  private lastVertical: number = 0;
  private hintTimer: number = -1;
  private lightRevision: number = 0;
  private living: boolean = false;
  private lockNoticeAt: number = 0;

  aboutToAppear(): void {
    try {
      this.living = true;
      this.brightnessTouched = false;
      this.brightnessPrepared = false;
      if (this.isSlaveMode || this.receiverLocked) { this.onReceiverLockChanged(); return; }
      void this.prepareBrightness();
    } catch (error) { Logger.error('PLAYER_GESTURE', '初始化手势层失败：' + String(error)); }
  }
  aboutToDisappear(): void {
    try {
      this.living = false;
      this.brightnessPrepared = false;
      ++this.lightRevision;
      this.tracking = false;
      this.axis = '';
      this.hintVisible = false;
      this.clearHintTimer();
      this.onBrightnessMask(0);
    } catch (error) {
      Logger.warn('PLAYER_GESTURE', '释放手势提示失败：' + String(error));
    } finally {
      void this.restoreBrightness();
    }
  }
  private async restoreBrightness(): Promise<void> {
    try { await this.playerBrightness.restore(); }
    catch (error) { Logger.warn('PLAYER_GESTURE', '恢复窗口亮度失败：' + String(error)); }
  }
  private async prepareBrightness(): Promise<void> {
    if (!this.living || this.isSlaveMode || this.receiverLocked || this.brightnessPrepared || this.brightnessPreparing) { return; }
    this.brightnessPreparing = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const level: number = await this.playerBrightness.attach(context);
      if (!this.living) { await this.restoreBrightness(); return; }
      this.brightnessPrepared = true;
      // 异步读取只记录亮度基线；读取期间入会后不得继续提交本地亮度操作。
      if (!this.brightnessTouched && Number.isFinite(level)) { this.lightLevel = Math.max(0.05, Math.min(1, level)); }
      else if (this.brightnessTouched && !this.isSlaveMode && !this.receiverLocked) { await this.applyLight(this.lightLevel); }
    } catch (error) { Logger.error('PLAYER_GESTURE', '准备窗口亮度失败：' + String(error)); }
    finally { this.brightnessPreparing = false; }
  }
  private onReceiverLockChanged(): void {
    try {
      if (!this.isSlaveMode && !this.receiverLocked) {
        if (this.living && !this.brightnessPrepared && !this.brightnessPreparing) { void this.prepareBrightness(); }
        Logger.debug('PLAYER_GESTURE', '接收端已解锁，恢复原有播放及亮度、音量、进度手势');
        return;
      }
      ++this.lightRevision;
      this.tracking = false;
      this.axis = '';
      this.lastVertical = 0;
      this.startMs = 0;
      this.targetMs = 0;
      this.hintVisible = false;
      this.hintText = '';
      this.clearHintTimer();
      Logger.debug('PLAYER_GESTURE', '接收端已锁定，取消尚未提交的滑动');
    } catch (error) { Logger.warn('PLAYER_GESTURE', '更新接收端手势锁定失败：' + String(error)); }
  }
  private clearHintTimer(): void {
    if (this.hintTimer !== -1) { clearTimeout(this.hintTimer); this.hintTimer = -1; }
  }
  private locked(): boolean {
    if (!this.isSlaveMode && !this.receiverLocked) { return false; }
    try {
      if (Date.now() - this.lockNoticeAt > 1500) {
        this.lockNoticeAt = Date.now();
        this.getUIContext().getPromptAction().showToast({ message: '协同同播中，仅主控设备可控制播放' });
      }
    } catch (error) { Logger.warn('PLAYER_GESTURE', '提示接收端锁定失败：' + String(error)); }
    return true;
  }
  private reveal(): void {
    try { if (this.living) { this.onReveal(); } }
    catch (error) { Logger.error('PLAYER_GESTURE', '单击显示控制栏失败：' + String(error)); }
  }
  private async doubleTap(): Promise<void> {
    try {
      // 兼容父页既有 receiverLocked 接口；等待入会和已入会均在回调之前拦截。
      if (!this.living || this.isSlaveMode || this.receiverLocked) { return; }
      this.onReveal();
      if (!this.locked()) { await this.onToggle(); }
    } catch (error) { Logger.error('PLAYER_GESTURE', '双击播放控制失败：' + String(error)); }
  }
  private start(event: GestureEvent): void {
    try {
      this.tracking = false;
      if (!this.living || this.isSlaveMode || this.receiverLocked) { return; }
      this.clearHintTimer();
      this.hintVisible = false;
      this.axis = '';
      this.lastVertical = 0;
      if (this.locked() || !Number.isFinite(this.currentMs) || !Number.isFinite(this.durationMs)) { return; }
      if (event.fingerList.length === 0 || !Number.isFinite(event.fingerList[0].localX)) { return; }
      this.startMs = Math.max(0, this.currentMs);
      this.targetMs = this.startMs;
      this.soundLevel = Number.isFinite(this.volumeValue) ? Math.max(0, Math.min(1, this.volumeValue)) : 1;
      this.leftSide = event.fingerList[0].localX < this.measuredSpan / 2;
      this.tracking = true;
      Logger.debug('PLAYER_GESTURE', '开始视频区域滑动');
    } catch (error) { Logger.error('PLAYER_GESTURE', '开始滑动失败：' + String(error)); }
  }
  private async applyLight(level: number): Promise<void> {
    const revision: number = ++this.lightRevision;
    try {
      if (!this.living || this.isSlaveMode || this.receiverLocked || !Number.isFinite(level)) { return; }
      const shade: number = await this.playerBrightness.setValue(level);
      if (this.living && !this.isSlaveMode && !this.receiverLocked && revision === this.lightRevision) { this.onBrightnessMask(shade); }
    } catch (error) { Logger.error('PLAYER_GESTURE', '应用亮度失败：' + String(error)); }
  }
  private update(event: GestureEvent): void {
    try {
      if (this.isSlaveMode || this.receiverLocked || !this.living || !this.tracking || !Number.isFinite(event.offsetX) || !Number.isFinite(event.offsetY)) { return; }
      if (!this.axis) {
        if (Math.max(Math.abs(event.offsetX), Math.abs(event.offsetY)) < 8) { return; }
        this.axis = Math.abs(event.offsetX) >= Math.abs(event.offsetY) ? 'seek' : this.leftSide ? 'light' : 'sound';
      }
      this.hintKind = this.axis;
      if (this.axis === 'seek') {
        // GestureEvent 偏移使用 vp：100vp 对应 10000ms。
        this.targetMs = Math.max(0, Math.min(Math.max(0, this.durationMs - 1), this.startMs + event.offsetX * 100));
        const deltaSec: number = Math.round((this.targetMs - this.startMs) / 1000);
        this.hintText = (deltaSec >= 0 ? '快进 ' : '快退 ') + Math.abs(deltaSec) + ' 秒 · ' + this.clock(this.targetMs);
      } else {
        // 增量积分：80vp 对应 10%，到达边界即停止，反向滑动无需抵消越界距离。
        const delta: number = (this.lastVertical - event.offsetY) / 800;
        this.lastVertical = event.offsetY;
        if (this.axis === 'light') {
          const next: number = Math.max(0.05, Math.min(1, this.lightLevel + delta));
          if (next !== this.lightLevel) { this.brightnessTouched = true; this.lightLevel = next; void this.applyLight(next); }
          this.hintText = '亮度 ' + Math.round(this.lightLevel * 100) + '%';
        } else {
          const next: number = Math.max(0, Math.min(1, this.soundLevel + delta));
          if (next !== this.soundLevel) { this.soundLevel = next; this.onVolume(next); }
          this.hintText = '音量 ' + Math.round(this.soundLevel * 100) + '%';
        }
      }
      this.hintVisible = true;
    } catch (error) { Logger.error('PLAYER_GESTURE', '处理视频滑动失败：' + String(error)); }
  }
  private async end(cancelled: boolean = false): Promise<void> {
    try {
      if (this.isSlaveMode || this.receiverLocked) {
        this.tracking = false;
        this.axis = '';
        this.hintVisible = false;
        this.clearHintTimer();
        return;
      }
      if (!this.living || !this.tracking) { return; }
      this.tracking = false;
      const finishedAxis: string = this.axis;
      const finalMs: number = Math.floor(this.targetMs);
      this.axis = '';
      if (!cancelled && !this.isSlaveMode && !this.receiverLocked && finishedAxis === 'seek' && this.durationMs > 0 && Number.isFinite(finalMs)) {
        await this.onSeek(finalMs);
      }
      if (!this.living || this.isSlaveMode || this.receiverLocked) { return; }
      Logger.debug('PLAYER_GESTURE', cancelled ? '视频滑动已取消' : '视频滑动结束：' + finishedAxis);
      this.clearHintTimer();
      this.hintTimer = setTimeout((): void => {
        try { this.hintTimer = -1; if (this.living) { this.hintVisible = false; } }
        catch (error) { Logger.warn('PLAYER_GESTURE', '隐藏手势提示失败：' + String(error)); }
      }, 650);
    } catch (error) { Logger.error('PLAYER_GESTURE', '结束滑动失败：' + String(error)); }
  }
  private clock(value: number): string {
    const seconds: number = Math.floor(Math.max(0, value) / 1000);
    return Math.floor(seconds / 60) + ':' + (seconds % 60).toString().padStart(2, '0');
  }
  private hintSymbol(): Resource {
    return this.hintKind === 'light' ? $r('sys.symbol.sun_max_fill') :
      this.hintKind === 'sound' ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.arrow_left_arrow_right');
  }
  private panelTint(): string {
    const alpha: number = this.immersion.immersiveEnable ? Math.max(0.65, Math.min(1, this.immersion.immersiveOpacity)) : 1;
    return this.darkTheme ? `rgba(26,39,57,${alpha})` : `rgba(240,247,255,${alpha})`;
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        SymbolGlyph(this.hintSymbol()).fontSize(Ui.fs('28vp', this.fontScale)).fontColor([this.darkTheme ? '#F0F6FF' : '#182A40']);
        Text(this.hintText).fontSize(Ui.fs('15vp', this.fontScale)).fontColor(this.darkTheme ? '#F0F6FF' : '#182A40');
      }.padding('18vp').backgroundColor(this.panelTint()).backdropBlur(this.immersion.immersiveEnable ? this.immersion.immersiveBlur : 0)
        .borderRadius('16vp').hitTestBehavior(HitTestMode.None).visibility(this.hintVisible ? Visibility.Visible : Visibility.None);
    }.width('100%').height('100%').backgroundColor('#00000000')
      .accessibilityText(this.isSlaveMode || this.receiverLocked ? '同播接收端，播放由主控控制' : '视频手势区域')
      .onAreaChange((_old: Area, area: Area): void => {
      try {
        const measured: number = Number(area.width);
        if (Number.isFinite(measured) && measured > 0) { this.measuredSpan = measured; }
      } catch (error) { Logger.warn('PLAYER_GESTURE', '测量视频区域失败：' + String(error)); }
    })
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
      .gesture(
      GestureGroup(GestureMode.Exclusive,
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 8 })
      .onActionStart((event: GestureEvent): void => { this.start(event); })
      .onActionUpdate((event: GestureEvent): void => { this.update(event); })
      .onActionEnd((): void => { void this.end(); })
      .onActionCancel((): void => { void this.end(true); }),
      TapGesture({ count: 2 }).onAction((): void => { void this.doubleTap(); }),
      // 单击切换控制栏；独占手势组优先识别双击，避免双击暂停被单击逻辑抢先触发。
      TapGesture({ count: 1 }).onAction((): void => {
        try { if (this.living) { this.onToggleControls(); } }
        catch (error) { Logger.error('PLAYER_GESTURE', '单击切换控制栏失败：' + String(error)); }
      })
    )
    );
  }
}

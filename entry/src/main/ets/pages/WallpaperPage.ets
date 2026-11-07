import { common } from '@kit.AbilityKit';
import router from '@ohos.router';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { Logger } from '../common/Logger';
import { SymbolIcons } from '../common/SymbolIcons';
import { ThemeService, WallpaperPreset } from '../common/ThemeService';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, PrimaryButton } from '../common/UiWidgets';
import { WallpaperKind, WallpaperMedia, WallpaperService } from '../common/WallpaperService';

/**
 * 壁纸 · 自定义背景。
 *
 * 三块内容：
 * 1. 本地导入：图片 / GIF / 视频（含 Wallpaper Engine 导出的 mp4、gif），文件复制进沙箱后离线可用；
 * 2. 播放参数：背景透明度、播放速率（0.5 / 1 / 1.5x）、动态背景帧率、动态播放开关；
 * 3. 内置渐变壁纸：沿用原来的 12 套渐变，作为没有本地资源时的备选。
 *
 * 应用本地背景后，页面自身通过 AuroraBackdrop 里的全局背景图层即时预览，
 * 其它页面（播放器除外）同步生效。
 */
@Entry
@Component
struct WallpaperPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('wallpaperId') private wallpaperId: string = '';
  @StorageLink('wallpaperMediaId') private mediaId: string = '';
  @StorageLink('wallpaperMediaKind') private mediaKind: string = '';
  @StorageLink('wallpaperMediaName') private mediaName: string = '';
  @StorageLink('wallpaperOpacity') private backdropOpacity: number = 0.85;
  @StorageLink('wallpaperRate') private rate: number = 1;
  @StorageLink('wallpaperFrameHz') private frameHz: number = 0;
  @StorageLink('wallpaperMotion') private motion: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';
  @State private imported: WallpaperMedia[] = [];
  @State private importing: boolean = false;

  aboutToAppear(): void {
    this.refreshImported();
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private refreshImported(): void {
    this.imported = WallpaperService.list().slice();
  }

  private currentSummary(): string {
    if (this.mediaId.length > 0 && this.mediaName.length > 0) {
      return WallpaperKind.label(this.mediaKind) + '「' + this.mediaName + '」';
    }
    if (this.wallpaperId.length > 0) {
      for (const item of ThemeService.wallpapers()) {
        if (item.id === this.wallpaperId) {
          return '内置壁纸「' + item.name + '」';
        }
      }
    }
    return '跟随当前主题背景';
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  /** 应用内置渐变壁纸（与本地背景互斥，由 ThemeService 统一处理）。 */
  private applyPreset(item: WallpaperPreset): void {
    try {
      ThemeService.applyWallpaper(item.id);
      // StorageLink 立即同步，避免部分设备上要等下一次页面刷新才看到新渐变。
      this.wallpaperId = item.id;
      this.showToast('已应用壁纸「' + item.name + '」');
    } catch (error) {
      Logger.error('WALLPAPER_PAGE', '应用壁纸失败：' + String(error));
      this.showToast('应用壁纸失败');
    }
  }

  /** 应用某个已导入的本地背景。 */
  private applyMedia(item: WallpaperMedia): void {
    try {
      if (ThemeService.applyImportedWallpaper(item.id)) {
        this.showToast('已应用' + WallpaperKind.label(item.kind) + '背景「' + item.name + '」');
      } else {
        this.showToast('背景文件已失效，请重新导入');
        this.refreshImported();
      }
    } catch (error) {
      Logger.error('WALLPAPER_PAGE', '应用本地背景失败：' + String(error));
      this.showToast('应用本地背景失败');
    }
  }

  /** 系统文件选择器导入图片 / GIF / 视频，成功后自动应用第一个文件。 */
  private async importMedia(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const created: WallpaperMedia[] = await WallpaperService.importFromPicker(context);
      this.refreshImported();
      if (created.length === 0) {
        this.showToast('未选择文件，或文件格式不支持');
        return;
      }
      const first: WallpaperMedia = created[0];
      ThemeService.applyImportedWallpaper(first.id);
      this.showToast('已导入并应用「' + first.name + '」');
    } catch (error) {
      Logger.error('WALLPAPER_PAGE', '导入背景失败：' + String(error));
      this.showToast('导入失败，请重新选择文件');
    } finally {
      this.importing = false;
    }
  }

  private removeMedia(item: WallpaperMedia): void {
    try {
      const wasActive: boolean = item.id === this.mediaId;
      WallpaperService.remove(item.id);
      this.refreshImported();
      if (wasActive) {
        // 删掉的正是当前背景：触发一次主题背景重绘，页面底色立即回到当前主题。
        ThemeService.applyWallpaper('');
      }
      this.showToast('已删除「' + item.name + '」');
    } catch (error) {
      Logger.error('WALLPAPER_PAGE', '删除本地背景失败：' + String(error));
      this.showToast('删除失败');
    }
  }

  private clearAll(): void {
    ThemeService.clearBackground();
    this.showToast('已恢复主题默认背景');
  }

  /**
   * 卡片宽高比（宽 / 高）：0.68~0.80 四档，按壁纸 id 稳定取档，
   * 保证同一张壁纸每次进入都是同一个高度，整体呈竖版缩略图比例。
   */
  private cardAspect(item: WallpaperPreset): number {
    const key: string = (item.id || '') + (item.name || '');
    let hash: number = 0;
    for (let index: number = 0; index < key.length; index++) {
      hash = (hash * 31 + key.charCodeAt(index)) % 1000;
    }
    const steps: number[] = [0.68, 0.72, 0.76, 0.80];
    return steps[hash % steps.length];
  }

  private panelBackground(): ResourceColor {
    return Ui.card(this.darkTheme);
  }

  // ---------------- 视觉层 ----------------

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Column({ space: '2vp' }) {
        Text('壁纸 · 自定义背景')
          .fontSize(Ui.fs(this.tablet() ? '25vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
        Text('本地视频 / 动图 / 图片可作为全应用动态背景')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { this.clearAll(); } })
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '16vp',
        right: this.tablet() ? '24vp' : '16vp',
        top: (this.safeTop() + 8) + 'vp',
        bottom: '8vp'
      })
  }

  /** 当前背景摘要 + 导入入口。 */
  @Builder
  private importPanel() {
    Column({ space: '10vp' }) {
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('当前背景')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
          Text(this.currentSummary())
            .fontSize(Ui.fs(this.tablet() ? '16vp' : '14.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        if (this.mediaId.length > 0) {
          Text(this.motion ? '动态' : '已暂停')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(this.motion ? Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme))
            .padding({ left: '9vp', right: '9vp', top: '4vp', bottom: '4vp' })
            .borderRadius('9vp')
            .backgroundColor(this.motion ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
        }
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      Row({ space: '8vp' }) {
        PrimaryButton({ label: this.importing ? '导入中…' : '导入本地背景', compact: true,
          onTap: (): void => { void this.importMedia(); } })
        if (this.imported.length > 0) {
          GhostButton({ label: '清空本地', compact: true, onTap: (): void => {
            const hadActive: boolean = this.mediaId.length > 0;
            WallpaperService.removeAll();
            this.refreshImported();
            if (hadActive) {
              ThemeService.applyWallpaper('');
            }
            this.showToast('已清空本地背景');
          } })
        }
        if (this.importing) {
          LoadingProgress().width('20vp').height('20vp').color(Ui.accent(this.darkTheme))
        }
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Text('支持 Wallpaper Engine 导出的 mp4 / gif，以及 jpg / png / webp / bmp / mkv / ts。' +
        '文件会复制到应用私有目录，不依赖 WE 客户端或任何外部渲染引擎。')
        .fontSize(Ui.fs('10.5vp', this.fontScale))
        .lineHeight(this.tablet() ? '17vp' : '15.5vp')
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
      if (this.imported.length === 0) {
        Text('还没有导入本地背景，点「导入本地背景」从文件管理里选一个。')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
          .padding({ top: '6vp' })
      } else {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.imported, (item: WallpaperMedia) => {
            this.mediaCard(item)
          }, (item: WallpaperMedia) => 'media-' + item.id)
        }
          .width('100%')
      }
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(this.panelBackground())
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
  }

  @Builder
  private mediaCard(item: WallpaperMedia) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (WallpaperKind.isVideo(item.kind)) {
        // 视频缩略图不额外起解码器：用渐变底 + 播放符号表示，避免列表里挂很多 Video。
        Column({ space: '6vp' }) {
          SymbolGlyph(SymbolIcons.play())
            .fontSize(Ui.fs('22vp', this.fontScale))
            .fontColor(['#FFFFFF'])
          Text(WallpaperKind.label(item.kind))
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor('#E6FFFFFF')
        }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 135,
            colors: [[Ui.brandMid(), 0], [Ui.brandTo(), 1]]
          })
      } else {
        Image(item.uri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
      }
      Column({ space: '1vp' }) {
        Text(item.name)
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(WallpaperService.formatBytes(item.bytes) + ' · ' + WallpaperKind.label(item.kind))
          .fontSize(Ui.fs('9.5vp', this.fontScale))
          .fontColor('#CCFFFFFF')
          .maxLines(1)
      }
        .width('100%')
        .padding({ left: '9vp', right: '9vp', top: '6vp', bottom: '7vp' })
        .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#B3000000', 1]] })
      Row({ space: '4vp' }) {
        if (item.id === this.mediaId) {
          Text('使用中')
            .fontSize(Ui.fs('9.5vp', this.fontScale))
            .fontColor('#FFFFFF')
            .padding({ left: '7vp', right: '7vp', top: '2vp', bottom: '2vp' })
            .borderRadius('7vp')
            .backgroundColor(Ui.accent(this.darkTheme))
        }
        Text('✕')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor('#FFFFFF')
          .width('20vp')
          .height('20vp')
          .textAlign(TextAlign.Center)
          .borderRadius('10vp')
          .backgroundColor('#66000000')
          .onClick(() => { this.removeMedia(item); })
      }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: '7vp', right: '7vp', top: '7vp' })
        .align(Alignment.TopEnd)
    }
      .width('48.5%')
      .aspectRatio(0.82)
      .borderRadius(Ui.R_MD)
      .clip(true)
      .margin({ bottom: '9vp' })
      .border({
        width: item.id === this.mediaId ? 2 : 0,
        color: item.id === this.mediaId ? Ui.accent(this.darkTheme) : Color.Transparent
      })
      .onClick(() => { this.applyMedia(item); })
  }

  /** 播放参数：透明度 / 速率 / 帧率 / 动效开关。 */
  @Builder
  private tuningPanel() {
    Column({ space: '10vp' }) {
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('播放参数')
            .fontSize(Ui.fs(this.tablet() ? '17vp' : '15.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('透明度与速率即时生效；帧率通过系统刷新率申请控制动态背景的功耗。')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.motion })
          .selectedColor(Ui.accent(this.darkTheme))
          .onChange((isOn: boolean) => {
            WallpaperService.setMotion(isOn);
          })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      // 背景透明度
      Column({ space: '4vp' }) {
        Row() {
          Text('背景透明度')
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(Math.round(this.backdropOpacity * 100).toString() + '%')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('100%')
        Slider({
          value: Math.round(this.backdropOpacity * 100),
          min: Math.round(WallpaperService.OPACITY_MIN * 100),
          max: 100,
          step: 5,
          style: SliderStyle.OutSet
        })
          .blockColor(Ui.accentStrong(this.darkTheme))
          .trackColor(Ui.glassTintSoft(this.darkTheme))
          .selectedColor(Ui.accent(this.darkTheme))
          .onChange((value: number) => { WallpaperService.setOpacity(value / 100); })
      }
        .width('100%')
      this.rowDivider()
      // 播放速率：0.5 / 1 / 1.5x 滑块
      Column({ space: '4vp' }) {
        Row() {
          Text('播放速率')
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(WallpaperService.rateLabel(this.rate))
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('100%')
        Slider({
          value: WallpaperService.normalizeRate(this.rate),
          min: 0.5,
          max: 1.5,
          step: 0.5,
          style: SliderStyle.OutSet
        })
          .blockColor(Ui.accentStrong(this.darkTheme))
          .trackColor(Ui.glassTintSoft(this.darkTheme))
          .selectedColor(Ui.accent(this.darkTheme))
          .showSteps(true)
          .onChange((value: number) => { WallpaperService.setRate(value); })
        Row() {
          Text('0.5x').fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          Text('1x').fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          Text('1.5x').fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
        }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
      }
        .width('100%')
      this.rowDivider()
      // 动态背景帧率
      Column({ space: '6vp' }) {
        Row() {
          Text('动态背景帧率')
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(WallpaperService.frameLabel(this.frameHz))
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
        }
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(WallpaperService.FRAME_OPTIONS, (hz: number) => {
            Text(hz <= 0 ? '跟随系统' : String(hz) + 'Hz')
              .fontSize(Ui.fs('12vp', this.fontScale))
              .fontColor(this.frameHz === hz ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
              .height('32vp')
              .padding({ left: '13vp', right: '13vp' })
              .borderRadius('16vp')
              .backgroundColor(this.frameHz === hz ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
              .border({
                width: 1,
                color: this.frameHz === hz ? Ui.accentRing(this.darkTheme) : Color.Transparent
              })
              .margin({ right: '7vp', bottom: '6vp' })
              .onClick(() => { WallpaperService.setFrameHz(hz); })
          }, (hz: number) => 'frame-' + String(hz))
        }
          .width('100%')
        Text('只有视频 / GIF 背景且开启动效时才申请该帧率；静态图片背景与暂停状态不受影响，播放器页始终使用播放器帧率。')
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .lineHeight(this.tablet() ? '17vp' : '15.5vp')
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '14vp')
      .borderRadius(Ui.R_LG)
      .backgroundColor(this.panelBackground())
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
  }

  @Builder
  private rowDivider() {
    Divider()
      .strokeWidth(1)
      .color(Ui.divider(this.darkTheme))
      .width('100%')
  }

  @Builder
  private presetSection() {
    Column({ space: '9vp' }) {
      Row() {
        Column({ space: '2vp' }) {
          Text('内置渐变壁纸')
            .fontSize(Ui.fs(this.tablet() ? '17vp' : '15.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('不导入文件时也可以只用渐变背景，随深浅主题各自取色')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Text(this.wallpaperId.length > 0 ? '使用中' : '未使用')
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(ThemeService.wallpapers(), (item: WallpaperPreset) => {
          this.wallpaperCard(item)
        }, (item: WallpaperPreset) => 'wallpaper-' + item.id)
      }
        .width('100%')
    }
      .width('100%')
  }

  @Builder
  private wallpaperCard(item: WallpaperPreset) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [[this.darkTheme ? item.darkTop : item.lightTop, 0],
            [this.darkTheme ? item.darkBottom : item.lightBottom, 1]]
        })
      Column({ space: '2vp' }) {
        Text(item.name)
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(item.id === this.wallpaperId ? '当前使用' : '点击应用')
          .fontSize(Ui.fs('9.5vp', this.fontScale))
          .fontColor(item.id === this.wallpaperId ? '#FFFFFF' : '#E6FFFFFF')
      }
        .width('100%')
        .padding('10vp')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#99000000', 1]]
        })
      if (item.id === this.wallpaperId) {
        Text('✓')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('20vp').height('20vp')
          .textAlign(TextAlign.Center)
          .borderRadius('10vp')
          .backgroundColor('#66000000')
          .margin('8vp')
          .align(Alignment.TopEnd)
      }
    }
      .width('48.5%')
      .aspectRatio(this.cardAspect(item))
      .borderRadius(Ui.R_MD)
      .clip(true)
      .margin({ bottom: '9vp' })
      .border({
        width: item.id === this.wallpaperId ? 2 : 0,
        color: item.id === this.wallpaperId ? Ui.accent(this.darkTheme) : Color.Transparent
      })
      .onClick(() => { this.applyPreset(item); })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      // 背景图层（本地视频 / 动图 / 图片或主题渐变）就在 AuroraBackdrop 里，应用后本页即预览。
      AuroraBackdrop({ intensity: this.darkTheme ? 0.4 : 0.5 })
      Column() {
        this.header()
        Scroll() {
          Column({ space: '14vp' }) {
            this.importPanel()
            this.tuningPanel()
            this.presetSection()
            Text('应用本地背景会清空内置壁纸选择；选择内置壁纸也会收起本地背景，二者同一时间只生效一个。' +
              '播放器页保持自己的画面与背景，不叠加应用背景。')
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .lineHeight(this.tablet() ? '17vp' : '15.5vp')
              .fontColor(Ui.inkFaint(this.darkTheme))
              .width('100%')
              .padding({ bottom: '12vp' })
          }
            .width('100%')
            .constraintSize({ maxWidth: this.tablet() ? 900 : 2000 })
            .padding({
              left: this.tablet() ? '24vp' : '16vp',
              right: this.tablet() ? '24vp' : '16vp',
              top: '6vp',
              bottom: '24vp'
            })
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
      }
        .width('100%').height('100%')
      if (this.toastText.length > 0) {
        Text(this.toastText)
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .padding({ left: '16vp', right: '16vp', top: '9vp', bottom: '9vp' })
          .borderRadius('20vp')
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .align(Alignment.Bottom)
          .margin({ bottom: '30vp' })
      }
    }
      .width('100%').height('100%')
      .backgroundColor(this.pageBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
        } catch (error) {
          Logger.warn('WALLPAPER_PAGE', '更新壁纸页宽度失败：' + String(error));
        }
      })
  }
}

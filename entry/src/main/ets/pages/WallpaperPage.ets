import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ThemeService, WallpaperPreset } from '../common/ThemeService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';

/**
 * 壁纸瀑布流 · 自定义背景。
 * 使用本地渐变壁纸（不依赖图片 CDN），选中后作为所有页面的 pageBg/pageBgAlt。
 */
@Entry
@Component
struct WallpaperPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('wallpaperId') private wallpaperId: string = '';
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private apply(item: WallpaperPreset): void {
    try {
      ThemeService.applyWallpaper(item.id);
      this.showToast('已应用壁纸「' + item.name + '」');
    } catch (error) {
      Logger.error('WALLPAPER_PAGE', '应用壁纸失败：' + String(error));
      this.showToast('应用壁纸失败');
    }
  }

  private clear(): void {
    ThemeService.applyWallpaper('');
    this.showToast('已恢复默认背景');
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2000);
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Column({ space: '2vp' }) {
        Text('壁纸瀑布流')
          .fontSize(Ui.fs(this.tablet() ? '25vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('选择一张作为全应用自定义背景')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { this.clear(); } })
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '16vp',
        right: this.tablet() ? '24vp' : '16vp',
        top: (this.safeTop() + 8) + 'vp',
        bottom: '8vp'
      })
  }

  @Builder
  private wallpaperCard(item: WallpaperPreset, index: number) {
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
          .fontSize(Ui.fs('15vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(item.id === this.wallpaperId ? '当前使用' : '点击应用')
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(item.id === this.wallpaperId ? '#FFFFFF' : '#E6FFFFFF')
      }
        .width('100%')
        .padding('12vp')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#99000000', 1]]
        })
      if (item.id === this.wallpaperId) {
        Text('✓')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('24vp').height('24vp')
          .textAlign(TextAlign.Center)
          .borderRadius('12vp')
          .backgroundColor('#66000000')
          .margin('10vp')
      }
    }
      .width('100%')
      .height(index % 3 === 0 ? '230vp' : (index % 3 === 1 ? '170vp' : '200vp'))
      .borderRadius(Ui.R_LG)
      .clip(true)
      .border({
        width: item.id === this.wallpaperId ? 2 : 0,
        color: item.id === this.wallpaperId ? Ui.accent(this.darkTheme) : Color.Transparent
      })
      .onClick(() => { this.apply(item); })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.4 : 0.5 })
      Column() {
        this.header()
        WaterFlow() {
          ForEach(ThemeService.wallpapers(), (item: WallpaperPreset, index: number) => {
            FlowItem() {
              this.wallpaperCard(item, index)
            }
              .width(this.tablet() ? '48%' : '48.5%')
          }, (item: WallpaperPreset) => 'wallpaper-' + item.id)
        }
          .columnsTemplate('1fr 1fr')
          .columnsGap('10vp')
          .rowsGap('10vp')
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({
            left: this.tablet() ? '24vp' : '16vp',
            right: this.tablet() ? '24vp' : '16vp',
            top: '8vp',
            bottom: '24vp'
          })
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

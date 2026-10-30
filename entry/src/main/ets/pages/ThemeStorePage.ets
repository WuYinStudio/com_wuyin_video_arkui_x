import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ThemePreset, ThemeService, WallpaperPreset } from '../common/ThemeService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, GlassChip } from '../common/UiWidgets';

/**
 * 主题商城 · 27 套主题 + 跟随系统/浅色/深色 + 自定义背景入口。
 */
@Entry
@Component
struct ThemeStorePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('themeMode') private themeMode: string = 'system';
  @StorageLink('themeId') private themeId: string = ThemeService.DEFAULT_THEME;
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

  private themeName(): string {
    for (const item of ThemeService.themes()) {
      if (item.id === this.themeId) {
        return item.name;
      }
    }
    return '极光蓝';
  }

  private wallpaperName(): string {
    const wall: WallpaperPreset | undefined = ThemeService.wallpaper();
    return wall !== undefined ? wall.name : '未设置';
  }

  private applyTheme(item: ThemePreset): void {
    try {
      if (ThemeService.applyTheme(item.id)) {
        this.showToast('已应用「' + item.name + '」');
      }
    } catch (error) {
      Logger.error('THEME_PAGE', '应用主题失败：' + String(error));
      this.showToast('应用主题失败');
    }
  }

  private async setMode(mode: string): Promise<void> {
    try {
      await AppState.setThemeMode(mode);
      this.showToast(mode === 'system' ? '已跟随系统' : (mode === 'dark' ? '已切换深色' : '已切换浅色'));
    } catch (error) {
      Logger.error('THEME_PAGE', '切换主题模式失败：' + String(error));
    }
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
        Text('主题商城')
          .fontSize(Ui.fs(this.tablet() ? '25vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('27 套主题 · 当前 ' + this.themeName())
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
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
  private modeSelector() {
    Column({ space: '8vp' }) {
      Text('深浅模式')
        .fontSize(Ui.fs('15vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      Row({ space: '8vp' }) {
        GlassChip({ label: '跟随系统', selected: this.themeMode === 'system', compact: true,
          onTap: (): void => { void this.setMode('system'); } })
        GlassChip({ label: '浅色', selected: this.themeMode === 'light', compact: true,
          onTap: (): void => { void this.setMode('light'); } })
        GlassChip({ label: '深色', selected: this.themeMode === 'dark', compact: true,
          onTap: (): void => { void this.setMode('dark'); } })
      }
        .width('100%')
    }
      .width('100%')
      .padding('14vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private themeCard(item: ThemePreset) {
    Column({ space: '6vp' }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Row()
          .width('100%')
          .height('48vp')
          .borderRadius('14vp')
          .linearGradient({
            angle: 135,
            colors: [[item.brandFrom, 0], [item.brandMid, 0.55], [item.brandTo, 1]]
          })
        if (item.id === this.themeId) {
          Text('✓')
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width('20vp').height('20vp')
            .textAlign(TextAlign.Center)
            .borderRadius('10vp')
            .backgroundColor('#66000000')
            .margin('5vp')
        }
      }
        .width('100%')
        .height('48vp')
      Text(item.name)
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontWeight(item.id === this.themeId ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .width('100%')
    }
      .width(this.tablet() ? '23%' : '31%')
      .margin({ bottom: '8vp' })
      .padding('7vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({
        width: item.id === this.themeId ? 1.5 : 1,
        color: item.id === this.themeId ? Ui.accentRing(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
      .shadow({ radius: item.id === this.themeId ? 12 : 0, color: Ui.accentGlow(this.darkTheme), offsetY: 4 })
      .onClick(() => { this.applyTheme(item); })
  }

  @Builder
  private wallpaperEntry() {
    Row({ space: '12vp' }) {
      Column({ space: '3vp' }) {
        Text('自定义背景')
          .fontSize(Ui.fs('15vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('当前：' + this.wallpaperName())
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '壁纸瀑布流', compact: true, onTap: (): void => {
        router.pushUrl({ url: 'pages/WallpaperPage' }).catch((error: Error) => {
          Logger.error('THEME_PAGE', '打开壁纸页失败：' + String(error));
        });
      } })
    }
      .width('100%')
      .padding('14vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.42 : 0.52 })
      Column() {
        this.header()
        Scroll() {
          Column({ space: '12vp' }) {
            this.modeSelector()
            Row() {
              Text('全部主题')
                .fontSize(Ui.fs('15vp', this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Ui.ink(this.darkTheme))
                .layoutWeight(1)
              Text('27 套')
                .fontSize(Ui.fs('11.5vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
            }
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(ThemeService.themes(), (item: ThemePreset) => {
                this.themeCard(item)
              }, (item: ThemePreset) => 'theme-' + item.id)
            }
              .width('100%')
            this.wallpaperEntry()
            Text('主题会同步改变页面底色、主色、品牌渐变与玻璃高光；壁纸会作为所有页面的自定义背景。')
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .lineHeight('16vp')
              .fontColor(Ui.inkFaint(this.darkTheme))
              .width('100%')
              .padding({ top: '2vp' })
          }
            .width('100%')
            .constraintSize({ maxWidth: this.contentMaxWidth() })
            .padding({
              left: this.tablet() ? '24vp' : '16vp',
              right: this.tablet() ? '24vp' : '16vp',
              bottom: '28vp'
            })
        }
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
          Logger.warn('THEME_PAGE', '更新主题页宽度失败：' + String(error));
        }
      })
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 1000);
  }
}

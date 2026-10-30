import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, PrimaryButton } from '../common/UiWidgets';
import { SymbolIcons } from '../common/SymbolIcons';

// 从首页宿主拆出的“我的”占位页，保留原有文案与返回首页行为。
// 悬浮导航及底部安全区由 HomePage 统一预留，子页面不重复补偿。
// 视觉：pageBg → pageBgAlt 竖向渐变 + 极光柔光，正文是一块居中的玻璃空态卡。
@Component
export struct ProfilePage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('onImmersiveChanged') private darkTheme: boolean = true;
  // 仅用于多端字号与内容限宽，不参与任何业务逻辑。
  @State private viewportWidth: number = 360;

  aboutToAppear(): void {
    this.syncImmersive();
  }

  private onImmersiveChanged(): void {
    this.syncImmersive();
  }

  private syncImmersive(): void {
    try {
      void ImmersiveService.apply(true);
    } catch (error) {
      Logger.error('ProfileImmersive', '同步我的页面沉浸状态失败：' + String(error));
    }
  }

  private returnHome(): void {
    try {
      AppState.go('home');
    } catch (error) {
      Logger.error('ProfileImmersive', '返回首页失败：' + String(error));
    }
  }

  private updateViewportWidth(value: Length): void {
    const measuredWidth: number = Number(value);
    if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
      this.viewportWidth = measuredWidth;
    }
  }

  private tablet(): boolean {
    return Ui.isTablet(this.viewportWidth);
  }

  /** 玻璃空态卡的内容宽度：手机占满可用宽度，平板居中限宽。 */
  private contentWidth(): number {
    const availableWidth: number = Number.isFinite(this.viewportWidth) && this.viewportWidth > 0 ? this.viewportWidth : 360;
    const gutter: number = Ui.gutter(availableWidth);
    const limit: number = this.tablet() ? 520 : 620;
    return Math.max(220, Math.min(availableWidth - gutter * 2, limit));
  }

  private glassBlurRadius(): number {
    return Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur);
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 1 : 0.9 })
      Column() {
        Column({ space: this.tablet() ? 20 : 16 }) {
          Text('无音影视')
            .fontSize(Ui.fs(Ui.fsDisplay(this.viewportWidth), this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .textAlign(TextAlign.Center)
          Column({ space: this.tablet() ? 10 : 6 }) {
            EmptyState({ title: '此业务页面尚未接入', icon: SymbolIcons.doc() })
            PrimaryButton({
              label: '返回首页',
              onTap: (): void => { this.returnHome(); }
            })
          }
            .width('100%')
            .padding({ top: '10vp', bottom: '24vp', left: '12vp', right: '12vp' })
            .borderRadius(Ui.R_XL)
            .linearGradient({
              angle: 135,
              colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
            })
            .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
            .shadow({ radius: 22, color: Ui.shadowSoft(this.darkTheme), offsetY: 10 })
            .backdropBlur(this.glassBlurRadius())
            .clip(true)
        }
          .width(this.contentWidth())
          .alignItems(HorizontalAlign.Center)
      }
        .width('100%')
        .height('100%')
        .padding({ left: Ui.gutter(this.viewportWidth), right: Ui.gutter(this.viewportWidth) })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }
      .width('100%')
      .height('100%')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.updateViewportWidth(newValue.width);
      })
  }
}

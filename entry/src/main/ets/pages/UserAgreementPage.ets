import { common } from '@kit.AbilityKit';
import { AgreementService } from '../common/AgreementService';
import { LegalText } from '../common/LegalText';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, PageHeader, PrimaryButton } from '../common/UiWidgets';

/** 阅读卡里的一段：条款标题（如「一、服务内容」）单独加粗，正文保持原文，不做任何改写。 */
interface AgreementParagraph {
  key: string;
  heading: string;
  body: string;
}

@Entry
@Component
export struct UserAgreementPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('agreementAccepted') private agreementAccepted: boolean = false;
  @StorageLink('darkTheme') private isDarkTheme: boolean = true;
  @State private isSubmitting: boolean = false;
  @State private isExiting: boolean = false;
  @State private actionError: string = '';
  /** 当前展示的文档：用户协议 / 隐私政策，两份都内置在应用里，断网也能看。 */
  @State private docTab: string = 'agreement';

  /** 当前文档的段落块（内置文本，见 LegalText）。 */
  private documentBlocks(): string[] {
    return this.docTab === 'privacy' ? LegalText.PRIVACY_POLICY : LegalText.USER_AGREEMENT;
  }

  /** 小节标题：以「一、」这类中文序号或「1.1」开头且较短的行。 */
  private isSectionHeading(line: string): boolean {
    if (line.length > 24) { return false; }
    return /^[一二三四五六七八九十]+、/.test(line) || /^\d+\.\d+\s/.test(line);
  }

  aboutToAppear(): void {
    try {
      Logger.info('UserAgreement', '展示用户协议免责声明');
    } catch (error) {
      Logger.error('UserAgreement', '展示协议页面失败：' + String(error));
    }
  }

  private primaryTextColor(): string {
    try {
      return Ui.ink(this.isDarkTheme);
    } catch (error) {
      Logger.error('UserAgreement', '读取页面主题失败：' + String(error));
      return Ui.ink(true);
    }
  }

  private secondaryTextColor(): string {
    try {
      return Ui.inkSoft(this.isDarkTheme);
    } catch (error) {
      Logger.error('UserAgreement', '读取辅助文字颜色失败：' + String(error));
      return Ui.inkSoft(true);
    }
  }

  private pageBackgroundColor(): string {
    try {
      return Ui.pageBg(this.isDarkTheme);
    } catch (error) {
      Logger.error('UserAgreement', '读取页面背景颜色失败：' + String(error));
      return Ui.pageBg(true);
    }
  }

  // 仅在普通方法里切分段落：build 内不声明局部变量。
  private paragraphs(): AgreementParagraph[] {
    const blocks: string[] = this.documentBlocks();
    const result: AgreementParagraph[] = [];
    for (let index: number = 0; index < blocks.length; index++) {
      const line: string = blocks[index].trim();
      if (line.length === 0) { continue; }
      if (this.isSectionHeading(line)) {
        result.push({ key: 'head-' + index, heading: line, body: '' });
        continue;
      }
      // 形如「1. 正文」的编号句：序号加粗，正文照排。
      const marker: number = line.indexOf('. ');
      const numbered: boolean = marker > 0 && marker <= 3 && /^\d+$/.test(line.substring(0, marker));
      result.push({
        key: 'para-' + index,
        heading: numbered ? line.substring(0, marker + 2) : '',
        body: numbered ? line.substring(marker + 2) : line
      });
    }
    return result;
  }

  private async agree(): Promise<void> {
    if (this.isSubmitting || this.isExiting || this.agreementAccepted) {
      return;
    }
    try {
      this.isSubmitting = true;
      this.actionError = '';
      Logger.info('UserAgreement', '用户点击同意协议');
      await AgreementService.accept(getContext(this) as common.UIAbilityContext);
      if (!this.agreementAccepted) {
        this.actionError = '保存同意状态失败，请重试或退出软件。';
      }
    } catch (error) {
      this.actionError = '保存同意状态失败，请重试或退出软件。';
      Logger.error('UserAgreement', '同意协议失败：' + String(error));
    } finally {
      this.isSubmitting = false;
    }
  }

  private async exitApp(): Promise<void> {
    if (this.isSubmitting || this.isExiting) {
      return;
    }
    try {
      this.isExiting = true;
      this.actionError = '';
      Logger.info('UserAgreement', '用户点击退出软件');
      await (getContext(this) as common.UIAbilityContext).terminateSelf();
    } catch (error) {
      this.actionError = '退出软件失败，请再次点击退出软件。';
      Logger.error('UserAgreement', '退出软件失败：' + String(error));
    } finally {
      this.isExiting = false;
    }
  }

  // build 保持纯声明式布局，异常捕获放在生命周期和操作方法中。
  build() {
    Stack() {
      // 底层：底色渐变 + 极光柔光
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[this.pageBackgroundColor(), 0], [Ui.pageBgAlt(this.isDarkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.isDarkTheme ? 1 : 0.9 })
      Column() {
        PageHeader({
          title: this.docTab === 'privacy' ? '隐私政策' : '用户协议',
          subtitle: this.docTab === 'privacy' ? '我们如何收集与保护您的信息' : '使用条款与免责声明',
          showBack: false,
          gutter: 16
        })
        // 文档切换：两份都在应用内，不需要联网打开外部链接。
        Row({ space: '8vp' }) {
          ForEach(['agreement', 'privacy'], (tab: string) => {
            Text(tab === 'privacy' ? '隐私政策' : '用户协议')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontWeight(this.docTab === tab ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.docTab === tab ? Ui.accentStrong(this.isDarkTheme) : this.secondaryTextColor())
              .height('30vp')
              .padding({ left: '14vp', right: '14vp' })
              .borderRadius('15vp')
              .backgroundColor(this.docTab === tab ? Ui.accentSoft(this.isDarkTheme) : Ui.glassTintSoft(this.isDarkTheme))
              .border({ width: 1, color: this.docTab === tab ? Ui.accentRing(this.isDarkTheme) : Ui.glassRingSoft(this.isDarkTheme) })
              .textAlign(TextAlign.Center)
              .onClick(() => { this.docTab = tab; })
          }, (tab: string) => 'legal-tab-' + tab)
        }
          .width('100%')
          .padding({ left: '16vp', right: '16vp', bottom: '8vp' })
          .justifyContent(FlexAlign.Start)
        Scroll() {
          Column({ space: '0vp' }) {
            Column({ space: '14vp' }) {
              ForEach(this.paragraphs(), (item: AgreementParagraph) => {
                Text() {
                  Span(item.heading)
                    .fontSize(Ui.fs('15vp', this.fontScale))
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.secondaryTextColor())
                  Span(item.body)
                    .fontSize(Ui.fs('15vp', this.fontScale))
                    .fontColor(this.primaryTextColor())
                }
                  .lineHeight('25.5vp')
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (item: AgreementParagraph) => item.key)
            }
              .width('100%')
              .padding('18vp')
              .borderRadius(Ui.R_LG)
              .linearGradient({
                angle: 135,
                colors: [[Ui.cardTop(this.isDarkTheme), 0], [Ui.cardBottom(this.isDarkTheme), 1]]
              })
              .border({ width: 1, color: Ui.cardBorder(this.isDarkTheme) })
              .shadow({ radius: 18, color: Ui.shadowSoft(this.isDarkTheme), offsetY: 8 })
              .clip(true)
          }
            .width('100%')
            .padding({ left: '16vp', right: '16vp', top: '2vp', bottom: '8vp' })
        }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .layoutWeight(1)
          .width('100%')

        if (this.actionError.length > 0) {
          Text(this.actionError)
            .fontSize(Ui.fs('13vp', this.fontScale))
            .lineHeight('20vp')
            .fontColor(Ui.danger(this.isDarkTheme))
            .width('100%')
            .padding({ left: '20vp', right: '20vp', top: '6vp' })
        }

        // 未成年人提示：首次启动同意前就必须可见，对应隐私政策「对未成年人的保护」一节。
        Text('未满 14 周岁请在监护人陪同下阅读并同意本协议后使用')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.isDarkTheme))
          .textAlign(TextAlign.Center)
          .width('100%')
          .maxLines(2)
          .padding({ left: '20vp', right: '20vp', top: '10vp' })

        Row({ space: '12vp' }) {
          GhostButton({
            label: '退出软件',
            onTap: (): void => { void this.exitApp(); }
          })
          PrimaryButton({
            label: '同意协议',
            onTap: (): void => { void this.agree(); }
          })
        }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .padding({ left: '20vp', right: '20vp', top: '12vp', bottom: '22vp' })
          .enabled(!this.isSubmitting && !this.isExiting)
          .opacity(this.isSubmitting || this.isExiting ? 0.6 : 1)
      }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: '760vp' })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackgroundColor())
  }
}




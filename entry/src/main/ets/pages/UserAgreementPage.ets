import { common } from '@kit.AbilityKit';
import { AgreementService } from '../common/AgreementService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, PageHeader, PrimaryButton } from '../common/UiWidgets';

const DISCLAIMER_TEXT: string = [
  '在使用本软件之前，请您仔细阅读以下内容，并确保您充分理解并同意以下条款：',
  '1、本软件为开源软件，您可以免费获取并使用该软件。',
  '2、本软件完全基于您个人意愿使用，您应该对自己的使用行为和所有结果承担全部责任。',
  '3、本软件仅供学习交流、科研等非商业性质的用途，严禁将本软件用于商业目的。如有任何商业行为，均与本软件无关。',
  '4、本软件并不保证与所有操作系统或硬件设备兼容。本软件作者或贡献者不对因使用本软件而产生的任何技术或安全问题承担责任。',
  '5、本软件作者或贡献者不承担因使用本软件而造成的任何直接、间接、特殊或后果性的损失或损害的责任，包括但不限于财产损失、商业利润损失、信息或数据丢失或损坏等。',
  '6、本软件使用者应遵守国家相关法律法规和使用规范，不得利用本软件从事任何违法违规行为。如因使用本软件而导致的违法行为，使用者应承担相应的法律责任。',
  '7、本软件不会收集、存储、使用任何用户的个人信息，包括但不限于姓名、地址、电子邮件地址、电话号码等。在使用本软件过程中，不会进行任何形式的个人信息采集。如用户提供任何个人信息，将被视为用户已自愿提供，并且用户将自行承担由此产生的所有法律责任。',
  '8、本软件作者或贡献者保留随时修改、增加、删除本免责声明中的内容而不另行通知的权利。',
  '9、如果本软件存在侵犯您的合法权益的情况，请及时与作者联系，作者将会及时删除有关内容。',
  '如您不同意本免责声明中的任何内容，请勿使用本软件。使用本软件即代表您已完全理解并同意上述内容。'
].join('\n\n');

/** 阅读卡里的一段：条款序号单独加粗，正文保持原文，不做任何改写。 */
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

  aboutToAppear(): void {
    try {
      // 协议状态由入口统一恢复，避免在用户点击同意时重复读取旧状态。
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
    const blocks: string[] = DISCLAIMER_TEXT.split('\n\n');
    const result: AgreementParagraph[] = [];
    for (let index: number = 0; index < blocks.length; index++) {
      const line: string = blocks[index].trim();
      if (line.length === 0) { continue; }
      const marker: number = line.indexOf('、');
      const numbered: boolean = marker > 0 && /^\d+$/.test(line.substring(0, marker));
      result.push({
        key: 'para-' + index,
        heading: numbered ? line.substring(0, marker + 1) : '',
        body: numbered ? line.substring(marker + 1) : line
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
          title: '用户协议',
          subtitle: '免责声明',
          showBack: false,
          gutter: 16
        })
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

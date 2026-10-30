import { router } from '@kit.ArkUI';
import { AccountApi, FollowEntry } from '../common/AccountApi';
import { CommunityApi, CommunitySession } from '../common/CommunityApi';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton } from '../common/UiWidgets';
import { replaceRoute } from '../common/compat/RouterCompat';

/**
 * 关注 / 粉丝列表。
 *
 * 接口（follow.php）：
 * - action=followers / following → {status,total,data:[{users,name,avatar,time,is_mutual}]}
 * - action=follow / unfollow      → {status,message}
 */
@Entry
@Component
struct FollowListPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @State private tab: number = 0;
  @State private list: FollowEntry[] = [];
  @State private loading: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';
  private topSafeInset: number = 24;

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.session = await CommunityApi.readSession();
      if (!this.session.valid()) {
        this.showToast('请先登录后查看');
        return;
      }
      const text: string = this.tab === 0
        ? await AccountApi.followers(this.session.user, this.session.pass)
        : await AccountApi.following(this.session.user, this.session.pass);
      this.list = await AccountApi.parseFollowList(text);
      Logger.info('FOLLOW_LIST', (this.tab === 0 ? '粉丝' : '关注') + '列表加载完成，数量=' + String(this.list.length));
    } catch (error) {
      Logger.warn('FOLLOW_LIST', '加载失败：' + String(error));
      this.showToast('加载失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private switchTab(index: number): void {
    if (this.tab === index) { return; }
    this.tab = index;
    this.list = [];
    void this.load();
  }

  private async toggleFollow(entry: FollowEntry): Promise<void> {
    try {
      const message: string = entry.mutual
        ? await AccountApi.unfollow(this.session.user, this.session.pass, entry.user)
        : await AccountApi.follow(this.session.user, this.session.pass, entry.user);
      this.showToast(message.length > 0 ? message : '操作成功');
      await this.load();
    } catch (error) {
      this.showToast('操作失败：' + String(error));
    }
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private gutter(): number {
    return this.tablet() ? 24 : 16;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private initial(name: string): string {
    const value: string = (name || '').trim();
    return value.length > 0 ? value.substring(0, 1) : '友';
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    void replaceRoute({ url: 'pages/Index' });
  }

  @Builder
  private row(entry: FollowEntry) {
    Row({ space: '10vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('44vp')
          .height('44vp')
          .borderRadius('22vp')
          .linearGradient({
            angle: 140,
            colors: [[Ui.glassSheenTop(this.darkTheme), 0], [Ui.accentSoft(this.darkTheme), 1]]
          })
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
        Text(this.initial(entry.name.length > 0 ? entry.name : entry.user))
          .fontSize(Ui.fs('17vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.accentStrong(this.darkTheme))
      }
        .width('44vp')
        .height('44vp')
      Column({ space: '3vp' }) {
        Row({ space: '6vp' }) {
          Text(entry.name.length > 0 ? entry.name : entry.user)
            .fontSize(Ui.fs('14.5vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          if (entry.mutual) {
            Text('互关')
              .fontSize(Ui.fs('9vp', this.fontScale))
              .fontColor(Ui.success(this.darkTheme))
              .height('16vp')
              .padding({ left: '5vp', right: '5vp' })
              .borderRadius('8vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .maxLines(1)
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Text('账号：' + entry.user + (entry.time.length > 0 ? ' · ' + entry.time : ''))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({
        label: entry.mutual ? '取关' : '关注',
        compact: true,
        onTap: (): void => { void this.toggleFollow(entry); }
      })
    }
      .width('100%')
      .padding('10vp')
      .borderRadius('14vp')
      .backgroundColor(this.darkTheme ? Ui.card(this.darkTheme) : '#FFFFFF')
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private segment(label: string, index: number) {
    Text(label)
      .fontSize(Ui.fs('13vp', this.fontScale))
      .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.tab === index ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
      .height('34vp')
      .padding({ left: '16vp', right: '16vp' })
      .borderRadius('17vp')
      .backgroundColor(this.tab === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: this.tab === index ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme) })
      .textAlign(TextAlign.Center)
      .onClick(() => { this.switchTab(index); })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.45 : 0.55 })
      Column() {
        Row({ space: '10vp' }) {
          GhostButton({ label: '返回', compact: true, onTap: (): void => { this.goBack(); } })
          Column({ space: '2vp' }) {
            Text('关注与粉丝')
              .fontSize(Ui.fs('20vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
            Text(this.tab === 0 ? '粉丝 ' + String(this.list.length) : '关注 ' + String(this.list.length))
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          if (this.loading) {
            LoadingProgress().width('18vp').height('18vp').color(Ui.accent(this.darkTheme))
          }
        }
          .width('100%')
          .padding({ left: this.gutter() + 'vp', right: this.gutter() + 'vp', top: (this.safeTop() + 6) + 'vp' })
        Row({ space: '8vp' }) {
          this.segment('粉丝', 0)
          this.segment('关注', 1)
        }
          .width('100%')
          .padding({ left: this.gutter() + 'vp', right: this.gutter() + 'vp', top: '6vp', bottom: '8vp' })
        Scroll() {
          Column({ space: '8vp' }) {
            if (this.list.length === 0) {
              Text(this.tab === 0 ? '还没有粉丝' : '还没有关注任何人')
                .fontSize(Ui.fs('13vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: '48vp' })
            } else {
              ForEach(this.list, (entry: FollowEntry) => {
                this.row(entry)
              }, (entry: FollowEntry) => 'follow-' + entry.user)
            }
          }
            .width('100%')
            .constraintSize({ maxWidth: '760vp' })
            .padding({ left: this.gutter() + 'vp', right: this.gutter() + 'vp', bottom: '24vp' })
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
      }
        .width('100%')
        .height('100%')
      if (this.toastText.length > 0) {
        Text(this.toastText)
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .padding({ left: '16vp', right: '16vp', top: '9vp', bottom: '9vp' })
          .borderRadius('20vp')
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .align(Alignment.Bottom)
          .margin({ bottom: '48vp' })
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const width: number = Number(newValue.width);
          if (Number.isFinite(width) && width > 0) { this.viewportWidth = width; }
        } catch (error) {
          Logger.warn('FOLLOW_LIST', '更新宽度失败：' + String(error));
        }
      })
  }
}

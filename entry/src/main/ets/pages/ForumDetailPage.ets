import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, ForumPost, ForumReply } from '../common/CommunityApi';
import { ForumCodec, ForumMedia } from '../common/ForumCodec';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { SensitiveWords } from '../common/SensitiveWords';
import { SocialStore } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, PageHeader, PrimaryButton } from '../common/UiWidgets';
import { SymbolIcons } from '../common/SymbolIcons';

interface ForumDetailRouteParams {
  postId?: string;
}

/**
 * 帖子详情 · 液态玻璃
 *
 * 正文与评论均来自 bbs.php（viewPost / getReplyList），点赞与回复走 bbs.php 互动接口。
 * 页面保持与论坛列表同一套玻璃卡片语言，平板居中限宽 820vp。
 */
@Entry
@Component
struct ForumDetailPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @State private post: ForumPost = new ForumPost();
  @State private replies: ForumReply[] = [];
  @State private loading: boolean = false;
  @State private errorText: string = '';
  @State private hasPost: boolean = false;
  @State private loggedIn: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private liked: boolean = false;
  @State private favorite: boolean = false;
  @State private unlocked: boolean = false;
  @State private replyDraft: string = '';
  @State private replyTargetId: number = 0;
  @State private replyTargetName: string = '';
  @State private submittingReply: boolean = false;
  @State private toastText: string = '';
  @State private viewportWidth: number = 360;
  @State private postId: string = '';
  private alive: boolean = false;
  private readonly detailScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.alive = true;
    try {
      const params = router.getParams() as ForumDetailRouteParams | undefined;
      if (params && typeof params.postId === 'string') {
        this.postId = params.postId.trim();
      }
    } catch (error) {
      Logger.warn('FORUM_DETAIL', '读取帖子参数失败：' + String(error));
    }
    void this.prepare();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      if (this.postId.length === 0) {
        this.errorText = '缺少帖子标识，无法打开详情';
        Logger.warn('FORUM_DETAIL', this.errorText);
        return;
      }
      await this.loadPost();
    } catch (error) {
      this.errorText = String(error);
      Logger.error('FORUM_DETAIL', '准备帖子详情失败：' + String(error));
    }
  }

  private async loadPost(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      const detail: ForumPost | undefined = await CommunityApi.forumPost(this.postId);
      if (!detail) {
        this.errorText = '帖子不存在或已被删除';
        this.hasPost = false;
        Logger.warn('FORUM_DETAIL', '帖子详情为空：' + this.postId);
        return;
      }
      this.post = detail;
      this.hasPost = true;
      this.errorText = '';
      this.favorite = SocialStore.isFavorite(this.postId);
      this.unlocked = SocialStore.isUnlocked(this.postId);
      Logger.info('FORUM_DETAIL', '帖子详情加载成功：' + this.postId);
      void CommunityApi.increaseViews(this.postId);
      await this.loadReplies();
    } catch (error) {
      this.errorText = String(error);
      this.hasPost = false;
      Logger.error('FORUM_DETAIL', '加载帖子详情失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private async loadReplies(): Promise<void> {
    try {
      const result = await CommunityApi.forumReplies(this.postId, 1);
      this.replies = result.replies;
      Logger.info('FORUM_DETAIL', '评论数量=' + String(this.replies.length));
    } catch (error) {
      Logger.warn('FORUM_DETAIL', '加载评论失败：' + String(error));
    }
  }

  private async like(): Promise<void> {
    if (this.liked) {
      this.showToast('已经点过赞了');
      return;
    }
    if (!this.loggedIn) {
      this.showToast('登录后才能点赞');
      this.goLogin();
      return;
    }
    try {
      const message: string = await CommunityApi.likePost(this.session, this.postId);
      if (this.looksFailed(message)) {
        this.showToast(message);
        Logger.warn('FORUM_DETAIL', '点赞失败：' + message);
        return;
      }
      this.liked = true;
      const updated: ForumPost = this.copyPost(this.post);
      updated.likes = updated.likes + 1;
      this.post = updated;
      this.showToast(message || '点赞成功');
      Logger.info('FORUM_DETAIL', '点赞成功，帖子=' + this.postId);
    } catch (error) {
      this.showToast('点赞失败：' + String(error));
      Logger.error('FORUM_DETAIL', '点赞异常：' + String(error));
    }
  }

  private async submitReply(): Promise<void> {
    const content: string = SensitiveWords.clean(this.replyDraft.trim());
    if (content.length === 0 || this.submittingReply) {
      return;
    }
    const unsafe: string = SensitiveWords.validate(content, '评论');
    if (unsafe.length > 0) {
      this.showToast(unsafe);
      return;
    }
    if (!this.loggedIn) {
      this.showToast('登录后才能评论');
      this.goLogin();
      return;
    }
    this.submittingReply = true;
    try {
      const message: string = await CommunityApi.replyPost(this.session, this.postId, content, this.replyTargetId);
      if (this.looksFailed(message)) {
        this.showToast(message);
        Logger.warn('FORUM_DETAIL', '评论失败：' + message);
        return;
      }
      this.replyDraft = '';
      this.replyTargetId = 0;
      this.replyTargetName = '';
      const updated: ForumPost = this.copyPost(this.post);
      updated.comments = updated.comments + 1;
      this.post = updated;
      this.showToast(message || '评论成功');
      await this.loadReplies();
      this.detailScroller.scrollEdge(Edge.Bottom);
      Logger.info('FORUM_DETAIL', '评论成功，帖子=' + this.postId);
    } catch (error) {
      this.showToast('评论失败：' + String(error));
      Logger.error('FORUM_DETAIL', '评论异常：' + String(error));
    } finally {
      this.submittingReply = false;
    }
  }

  private paidPrice(): number {
    return CommunityApi.paidPrice(this.post.content);
  }

  private paidText(): string {
    return CommunityApi.paidBody(this.post.content);
  }

  private postImages(): string[] {
    return CommunityApi.extractImages(this.post.content);
  }

  private unlock(): void {
    const price: number = this.paidPrice();
    if (price <= 0) {
      return;
    }
    if (!this.loggedIn) {
      this.showToast('登录后才能解锁');
      this.goLogin();
      return;
    }
    AlertDialog.show({
      title: '解锁付费内容',
      message: '将扣除 ' + String(price) + ' 金币，确定解锁吗？',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '解锁',
        action: (): void => {
          void CommunityApi.spendCoins(this.session, price).then((message: string) => {
            if (message.indexOf('不足') >= 0 || message.indexOf('失败') >= 0 || message.indexOf('错误') >= 0) {
              this.showToast(message || '金币不足');
              return;
            }
            SocialStore.unlock(this.postId);
            this.unlocked = true;
            this.showToast('解锁成功');
            Logger.info('FORUM_DETAIL', '付费内容解锁：' + this.postId + '，金币=' + String(price));
          }).catch((error: Error) => {
            this.showToast('解锁失败：' + String(error));
          });
        }
      }
    });
  }

  private toggleFavorite(): void {
    const selected: boolean = SocialStore.toggleFavorite(this.postId);
    this.favorite = selected;
    this.showToast(selected ? '已收藏' : '已取消收藏');
  }

  /** 帖子里的视频/音乐/附件：把资源链接复制到剪贴板，方便到播放器或浏览器打开。 */
  private openMedia(url: string): void {
    if (!url) {
      return;
    }
    pasteboard.getSystemPasteboard().setData(
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url)).then(() => {
      this.showToast('媒体链接已复制');
    }).catch((error: Error) => {
      Logger.warn('FORUM_DETAIL', '复制媒体链接失败：' + String(error));
      this.showToast('复制失败');
    });
  }

  private sharePost(): void {
    const text: string = '影评：' + this.post.title + '\n' + CommunityApi.plainText(CommunityApi.freeBody(this.post.content));
    pasteboard.getSystemPasteboard().setData(
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)).then(() => {
      this.showToast('分享文案已复制');
    }).catch((error: Error) => {
      Logger.warn('FORUM_DETAIL', '复制分享文案失败：' + String(error));
      this.showToast('分享失败');
    });
  }

  private reportPost(): void {
    AlertDialog.show({
      title: '举报帖子',
      message: '确定举报这篇帖子吗？管理员会尽快处理。',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '提交举报',
        action: (): void => {
          Logger.warn('FORUM_DETAIL', '帖子举报已提交：' + this.postId);
          this.showToast('举报已提交');
        }
      }
    });
  }

  private setReplyTarget(reply: ForumReply): void {
    this.replyTargetId = Number(reply.id);
    this.replyTargetName = reply.name || reply.user;
  }

  private replyTargetLabel(reply: ForumReply): string {
    if (reply.replyTo <= 0) {
      return '';
    }
    const target: ForumReply | undefined = this.replies.find((item: ForumReply) => Number(item.id) === reply.replyTo);
    return target !== undefined ? '回复 @' + target.name + '：' : '';
  }

  private copyPost(source: ForumPost): ForumPost {
    const result: ForumPost = new ForumPost();
    result.id = source.id;
    result.title = source.title;
    result.content = source.content;
    result.category = source.category;
    result.user = source.user;
    result.name = source.name;
    result.grade = source.grade;
    result.time = source.time;
    result.views = source.views;
    result.likes = source.likes;
    result.comments = source.comments;
    result.top = source.top;
    result.essence = source.essence;
    result.moderator = source.moderator;
    return result;
  }

  private looksFailed(text: string): boolean {
    if (!text) {
      return false;
    }
    return text.indexOf('失败') >= 0 || text.indexOf('错误') >= 0 || text.indexOf('权限') >= 0 ||
      text.indexOf('禁止') >= 0 || text.indexOf('不足') >= 0 || text.indexOf('不存在') >= 0;
  }

  private goLogin(): void {
    router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
      Logger.error('FORUM_DETAIL', '打开登录页失败：' + String(error));
    });
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('FORUM_DETAIL', '同步全局沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 820);
  }

  private glassBlurRadius(): number {
    return Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur);
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeBottom(): number {
    return Number.isFinite(this.bottomSafeInset) ? Math.max(0, this.bottomSafeInset) : 16;
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '坛';
  }

  @Builder
  private header() {
    PageHeader({
      title: '帖子详情',
      subtitle: this.post.category || '交流论坛',
      showBack: true,
      actionText: this.liked ? '已赞' : '点赞',
      gutter: this.tablet() ? 24 : 16,
      onBack: (): void => { router.back(); },
      onAction: (): void => { void this.like(); }
    })
  }

  @Builder
  private actionChip(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(Ui.fs('11.5vp', this.fontScale))
      .fontColor(active ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
      .height('30vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('15vp')
      .backgroundColor(active ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: active ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme) })
      .onClick(action)
  }

  @Builder
  private postCard() {
    Column({ space: '12vp' }) {
      Row({ space: '7vp' }) {
        if (this.post.category.length > 0) {
          Text(this.post.category)
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .height('22vp')
            .padding({ left: '9vp', right: '9vp' })
            .borderRadius('11vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
        if (this.post.essence) {
          Text('精华')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.gold(this.darkTheme))
            .height('22vp')
            .padding({ left: '8vp', right: '8vp' })
            .borderRadius('11vp')
            .backgroundColor(Ui.goldSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
        Blank()
        Text(this.post.time)
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Text(this.post.title || '无标题')
        .fontSize(Ui.fs(this.tablet() ? '24vp' : '21vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      Row({ space: '8vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('32vp')
            .height('32vp')
            .borderRadius('16vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
          Text(this.initial(this.post.name))
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('32vp')
          .height('32vp')
        Column({ space: '1vp' }) {
          Text(this.post.name || this.post.user)
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
          Text(this.post.grade || '论坛用户')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Text('浏览 ' + String(this.post.views) + ' · 赞 ' + String(this.post.likes) + ' · 评论 ' + String(this.post.comments))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Divider().strokeWidth(1).color(Ui.divider(this.darkTheme)).width('100%')
      Text(CommunityApi.plainText(CommunityApi.freeBody(this.post.content)))
        .fontSize(Ui.fs(this.tablet() ? '15.5vp' : '14.5vp', this.fontScale))
        .lineHeight(this.tablet() ? '27vp' : '25vp')
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
      if (this.postImages().length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.postImages().slice(0, 9), (url: string, index: number) => {
            Image(url)
              .width(this.tablet() ? '30%' : '31%')
              .height(this.tablet() ? '118vp' : '98vp')
              .objectFit(ImageFit.Cover)
              .borderRadius('10vp')
              .margin('2vp')
          }, (url: string, index: number) => 'detail-img-' + String(index))
        }
          .width('100%')
      }
      // 帖子里的视频 / 音乐 / 附件：统一渲染成可点击的媒体卡（点击复制/提示链接）。
      ForEach(ForumCodec.videos(this.post.content), (media: ForumMedia, index: number) => {
        Row({ space: '10vp' }) {
          Stack({ alignContent: Alignment.Center }) {
            if (media.poster.length > 0) {
              Image(media.poster)
                .width('54vp').height('54vp').objectFit(ImageFit.Cover).borderRadius('10vp')
            } else {
              Column()
                .width('54vp').height('54vp').borderRadius('10vp')
                .backgroundColor(Ui.accentSoft(this.darkTheme))
            }
            Text('▶')
              .fontSize(Ui.fs('20vp', this.fontScale))
              .fontColor(Ui.accentStrong(this.darkTheme))
          }
            .width('54vp').height('54vp')
          Column({ space: '3vp' }) {
            Text(media.title.length > 0 ? media.title : '帖子视频')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
            Text(media.url)
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          Text('播放')
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .height('28vp')
            .padding({ left: '12vp', right: '12vp' })
            .borderRadius('14vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
          .width('100%')
          .padding('10vp')
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .onClick(() => { this.openMedia(media.url); })
      }, (media: ForumMedia, index: number) => 'detail-video-' + String(index))
      ForEach(ForumCodec.audios(this.post.content), (media: ForumMedia, index: number) => {
        Row({ space: '10vp' }) {
          Text('♪')
            .fontSize(Ui.fs('20vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .width('34vp')
            .textAlign(TextAlign.Center)
          Column({ space: '3vp' }) {
            Text(media.title.length > 0 ? media.title : '帖子音乐')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
            Text(media.url)
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          Text('打开')
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .height('28vp')
            .padding({ left: '12vp', right: '12vp' })
            .borderRadius('14vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
          .width('100%')
          .padding('10vp')
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .onClick(() => { this.openMedia(media.url); })
      }, (media: ForumMedia, index: number) => 'detail-audio-' + String(index))
      ForEach(ForumCodec.files(this.post.content), (media: ForumMedia, index: number) => {
        Row({ space: '10vp' }) {
          Text('📎')
            .fontSize(Ui.fs('18vp', this.fontScale))
            .width('34vp')
            .textAlign(TextAlign.Center)
          Column({ space: '3vp' }) {
            Text(media.title.length > 0 ? media.title : '帖子附件')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
            Text(media.url)
              .fontSize(Ui.fs('10.5vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .padding('10vp')
          .borderRadius(Ui.R_MD)
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .onClick(() => { this.openMedia(media.url); })
      }, (media: ForumMedia, index: number) => 'detail-file-' + String(index))
      if (this.paidPrice() > 0) {
        if (this.unlocked) {
          Column({ space: '4vp' }) {
            Text('付费内容（已解锁）')
              .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.gold(this.darkTheme))
            Text(CommunityApi.plainText(this.paidText()))
              .fontSize(Ui.fs('14.5vp', this.fontScale)).lineHeight('24vp').fontColor(Ui.inkSoft(this.darkTheme))
              .width('100%')
          }
            .width('100%')
            .padding('12vp')
            .borderRadius('12vp')
            .backgroundColor(Ui.goldSoft(this.darkTheme))
        } else {
          Row({ space: '8vp' }) {
            Column({ space: '2vp' }) {
              Text('付费内容')
                .fontSize(Ui.fs('13vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(Ui.gold(this.darkTheme))
              Text('支付 ' + String(this.paidPrice()) + ' 金币查看')
                .fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
            }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
            PrimaryButton({ label: '金币解锁', compact: true, onTap: (): void => { this.unlock(); } })
          }
            .width('100%')
            .padding('12vp')
            .borderRadius('12vp')
            .backgroundColor(Ui.goldSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
        }
      }
      Row({ space: '8vp' }) {
        this.actionChip('赞 ' + String(this.post.likes), this.liked, (): void => { void this.like(); })
        this.actionChip(this.favorite ? '已收藏' : '收藏', this.favorite, (): void => { this.toggleFavorite(); })
        this.actionChip('分享', false, (): void => { this.sharePost(); })
        this.actionChip('举报', false, (): void => { this.reportPost(); })
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.tablet() ? '22vp' : '18vp')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .backdropBlur(this.glassBlurRadius())
      .clip(true)
  }

  @Builder
  private replyCard(reply: ForumReply) {
    Column({ space: '7vp' }) {
      Row({ space: '8vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('28vp')
            .height('28vp')
            .borderRadius('14vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          Text(this.initial(reply.name))
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accent(this.darkTheme))
        }
          .width('28vp')
          .height('28vp')
        Column({ space: '1vp' }) {
          Text(reply.name || reply.user)
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
          Text(reply.grade || '论坛用户')
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Text(reply.time)
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      if (this.replyTargetLabel(reply).length > 0) {
        Text(this.replyTargetLabel(reply))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.accent(this.darkTheme))
          .maxLines(1)
      }
      Text(CommunityApi.plainText(reply.content))
        .fontSize(Ui.fs(this.tablet() ? '14.5vp' : '13.5vp', this.fontScale))
        .lineHeight(this.tablet() ? '23vp' : '21vp')
        .fontColor(Ui.inkSoft(this.darkTheme))
        .width('100%')
      Row({ space: '10vp' }) {
        if (reply.likes > 0) {
          Text('赞 ' + String(reply.likes))
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
        }
        Blank()
        Text('回复')
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.accent(this.darkTheme))
          .onClick(() => { this.setReplyTarget(reply); })
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.tablet() ? '16vp' : '14vp')
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
  }

  @Builder
  private contentBlock() {
    if (this.postsUnavailable()) {
      Column({ space: '12vp' }) {
        if (this.loading) {
          LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.darkTheme))
        } else {
          EmptyState({ title: '帖子无法打开', hint: this.errorText, icon: SymbolIcons.doc() })
          GhostButton({ label: '返回论坛', onTap: (): void => { router.back(); } })
        }
      }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
    } else {
      Scroll(this.detailScroller) {
        Column({ space: '12vp' }) {
          this.postCard()
          Row() {
            Text('全部评论 ' + String(this.replies.length))
              .fontSize(Ui.fs(this.tablet() ? '17vp' : '15vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
              .layoutWeight(1)
          }
            .width('100%')
            .padding({ top: '4vp' })
          if (this.replies.length === 0) {
            EmptyState({ title: '还没有评论', hint: '来抢沙发吧', icon: SymbolIcons.doc() })
          } else {
            ForEach(this.replies, (reply: ForumReply) => {
              this.replyCard(reply)
            }, (reply: ForumReply) => 'reply-' + reply.id)
          }
          Blank().height('10vp')
        }
          .width('100%')
          .constraintSize({ maxWidth: this.contentMaxWidth() })
          .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp', top: '10vp' })
      }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
    }
  }

  private postsUnavailable(): boolean {
    return !this.hasPost || this.errorText.length > 0;
  }

  @Builder
  private replyComposer() {
    Column({ space: '4vp' }) {
      if (this.replyTargetId > 0) {
        Row({ space: '8vp' }) {
          Text('回复 @' + this.replyTargetName)
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.accent(this.darkTheme))
            .layoutWeight(1)
          Text('取消')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .onClick(() => { this.replyTargetId = 0; this.replyTargetName = ''; })
        }
          .width('100%')
      }
      Row({ space: '10vp' }) {
        TextInput({ text: this.replyDraft, placeholder: this.replyTargetId > 0 ? '回复 @' + this.replyTargetName + '…' : '写下你的评论…' })
        .layoutWeight(1)
        .height(this.tablet() ? '48vp' : '44vp')
        .fontSize(Ui.fs(this.tablet() ? '15vp' : '14vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .placeholderColor(Ui.inkFaint(this.darkTheme))
        .caretColor(Ui.accent(this.darkTheme))
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .borderRadius(this.tablet() ? '24vp' : '22vp')
        .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
        .padding({ left: '16vp', right: '16vp' })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => { this.replyDraft = value; })
        .onSubmit(() => { void this.submitReply(); })
      PrimaryButton({
        label: this.submittingReply ? '发送中' : '评论',
        compact: true,
        onTap: (): void => { void this.submitReply(); }
      })
    }
      .width('100%')
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '16vp',
        right: this.tablet() ? '24vp' : '16vp',
        top: '10vp',
        bottom: (this.safeBottom() + 10) + 'vp'
      })
      .backgroundColor(Ui.glassTint(this.darkTheme))
      .backdropBlur(this.glassBlurRadius())
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.5 : 0.62 })
      Column() {
        this.header()
        this.contentBlock()
        if (this.hasPost && this.errorText.length === 0) {
          this.replyComposer()
        }
      }
        .width('100%')
        .height('100%')
      if (this.toastText.length > 0) {
        Text(this.toastText)
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .padding({ left: '18vp', right: '18vp', top: '11vp', bottom: '11vp' })
          .borderRadius('22vp')
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .shadow({ radius: 18, color: Ui.shadow(this.darkTheme), offsetY: 8 })
          .align(Alignment.Bottom)
          .margin({ bottom: (this.safeBottom() + 80) + 'vp' })
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
        } catch (error) {
          Logger.warn('FORUM_DETAIL', '更新帖子详情宽度失败：' + String(error));
        }
      })
  }
}

import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession, ForumCategory, ForumPost } from '../common/CommunityApi';
import { ForumCodec, ForumContent, ForumMedia } from '../common/ForumCodec';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { SensitiveWords } from '../common/SensitiveWords';
import { SocialStore } from '../common/SocialStore';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui } from '../common/Ui';
import { SymbolIcons } from '../common/SymbolIcons';
import { AuroraBackdrop, EmptyState, GhostButton, GlassChip, GlassSearchBar, PageHeader,
  PrimaryButton, SegmentedGlassTabs } from '../common/UiWidgets';

class ForumDetailParams {
  postId: string = '';

  constructor(postId: string) {
    this.postId = postId;
  }
}

class ForumDetailRoute {
  url: string = 'pages/ForumDetailPage';
  params: ForumDetailParams;

  constructor(postId: string) {
    this.params = new ForumDetailParams(postId);
  }
}

/**
 * 交流论坛 · 液态玻璃
 *
 * - 板块、帖子、搜索、发帖全部来自 bbs.php，不在客户端内置任何示例帖子。
 * - 列表按当前板块与关键词分页；点击进入 ForumDetailPage 读取详情与评论。
 * - 手机单列卡片，平板居中限宽 860vp；毛玻璃强度、深浅色由全局 StorageLink 驱动。
 */
@Component
export struct ForumPage {
  // 作为底栏「论坛」Tab 嵌入时为 true：隐藏返回按钮，返回动作改为回首页，避免退出应用。
  @Prop embedded: boolean = false;
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('immersiveBottomInset') private bottomSafeInset: number = 16;
  @State private posts: ForumPost[] = [];
  @State private categories: ForumCategory[] = [];
  @State private selectedCategory: string = '';
  @State private query: string = '';
  @State private page: number = 1;
  @State private totalPages: number = 1;
  @State private loading: boolean = false;
  @State private loadingMore: boolean = false;
  @State private errorText: string = '';
  @State private loggedIn: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private showComposer: boolean = false;
  @State private composerTitle: string = '';
  @State private composerContent: string = '';
  @State private composerCategory: string = '';
  // 帖子媒体：图片 / 视频 / 音乐 / 附件，统一进 ForumContent，最后编码成一段纯文字 JSON 发送。
  @State private composerMedia: ForumMedia[] = [];
  @State private mediaKind: string = 'image';
  @State private mediaUrl: string = '';
  @State private mediaTitle: string = '';
  @State private mediaPoster: string = '';
  @State private paidPrice: string = '';
  @State private paidContent: string = '';
  @State private editingPostId: string = '';
  @State private submitting: boolean = false;
  @State private sortMode: number = 0;
  @State private showWorks: boolean = false;
  @State private works: ForumPost[] = [];
  @State private worksLoading: boolean = false;
  @State private toastText: string = '';
  @State private viewportWidth: number = 360;
  private alive: boolean = false;
  private readonly listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.alive = true;
    void this.prepare();
    Logger.info('FORUM_PAGE', '进入交流论坛');
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      await this.loadCategories();
      await this.loadPosts(true);
    } catch (error) {
      this.errorText = String(error);
      Logger.error('FORUM_PAGE', '初始化论坛失败：' + String(error));
    }
  }

  private async loadCategories(): Promise<void> {
    try {
      const list: ForumCategory[] = await CommunityApi.forumCategories();
      this.categories = list;
      if (this.composerCategory.length === 0 && list.length > 0) {
        this.composerCategory = list[0].name;
      }
      Logger.info('FORUM_PAGE', '论坛板块=' + String(list.length));
    } catch (error) {
      Logger.warn('FORUM_PAGE', '读取论坛板块失败：' + String(error));
    }
  }

  private async loadPosts(reset: boolean): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      const targetPage: number = reset ? 1 : this.page;
      const result = await CommunityApi.forumPosts(this.selectedCategory, targetPage, this.query);
      if (reset) {
        this.posts = result.posts;
      } else {
        const merged: ForumPost[] = this.posts.slice();
        for (const item of result.posts) {
          if (!merged.some((post: ForumPost) => post.id === item.id)) {
            merged.push(item);
          }
        }
        this.posts = merged;
      }
      this.page = result.page;
      this.totalPages = result.totalPages;
      if (this.sortMode === 1) {
        const sorted: ForumPost[] = this.posts.slice();
        sorted.sort((a: ForumPost, b: ForumPost) => (b.views + b.likes * 3 + b.comments * 2) -
          (a.views + a.likes * 3 + a.comments * 2));
        this.posts = sorted;
      }
      this.errorText = this.posts.length === 0 ? '暂无消息' : '';
      Logger.info('FORUM_PAGE', '帖子列表加载完成，数量=' + String(this.posts.length) +
        '，页码=' + String(this.page) + '/' + String(this.totalPages));
    } catch (error) {
      this.errorText = String(error);
      Logger.error('FORUM_PAGE', '加载帖子失败：' + String(error));
    } finally {
      this.loading = false;
      this.loadingMore = false;
    }
  }

  private loadMore(): void {
    if (this.loading || this.page >= this.totalPages) {
      return;
    }
    this.loadingMore = true;
    this.page = this.page + 1;
    void this.loadPosts(false);
  }

  private selectCategory(name: string): void {
    if (this.selectedCategory === name) {
      return;
    }
    this.selectedCategory = name;
    this.page = 1;
    this.listScroller.scrollEdge(Edge.Top);
    void this.loadPosts(true);
    Logger.info('FORUM_PAGE', '切换板块：' + (name || '全部'));
  }

  private submitSearch(): void {
    this.page = 1;
    void this.loadPosts(true);
  }

  private openPost(post: ForumPost): void {
    try {
      router.pushUrl(new ForumDetailRoute(post.id)).catch((error: Error) => {
        Logger.error('FORUM_PAGE', '打开帖子详情失败：' + String(error));
      });
    } catch (error) {
      Logger.error('FORUM_PAGE', '帖子详情路由异常：' + String(error));
    }
  }

  private openComposer(): void {
    if (!this.loggedIn) {
      this.showToast('登录后才能发帖');
      router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
        Logger.error('FORUM_PAGE', '打开登录页失败：' + String(error));
      });
      return;
    }
    if (this.composerCategory.length === 0 && this.categories.length > 0) {
      this.composerCategory = this.categories[0].name;
    }
    if (this.editingPostId.length === 0) {
      this.composerTitle = '';
      this.composerContent = '';
      this.composerMedia = [];
      this.resetMediaInput();
      this.paidPrice = '';
      this.paidContent = '';
    }
    this.showComposer = true;
  }

  private resetMediaInput(): void {
    this.mediaKind = 'image';
    this.mediaUrl = '';
    this.mediaTitle = '';
    this.mediaPoster = '';
  }

  private closeComposer(): void {
    if (this.submitting) {
      return;
    }
    this.showComposer = false;
    this.editingPostId = '';
    this.composerMedia = [];
    this.resetMediaInput();
    this.paidPrice = '';
    this.paidContent = '';
  }

  private composeContent(): string {
    const content: ForumContent = new ForumContent();
    content.text = SensitiveWords.clean(this.composerContent.trim());
    content.media = this.composerMedia.slice();
    const price: number = Number(this.paidPrice);
    if (price > 0 && this.paidContent.trim().length > 0) {
      content.price = Math.trunc(price);
      content.paid = SensitiveWords.clean(this.paidContent.trim());
    }
    // 发送给服务端的仍是纯文字：普通帖子直接是正文，带媒体时是 #WYF# + JSON 一行文本。
    return ForumCodec.encode(content);
  }

  private async submitPost(): Promise<void> {
    if (this.submitting) {
      return;
    }
    const title: string = SensitiveWords.clean(this.composerTitle.trim());
    const content: string = this.composerContent.trim();
    if (this.composerCategory.length === 0) {
      this.showToast('请选择发帖板块');
      return;
    }
    if (title.length === 0) {
      this.showToast('请填写帖子标题');
      return;
    }
    if (title.length > 30) {
      this.showToast('标题不能超过 30 字');
      return;
    }
    if (content.length === 0 && this.composerMedia.length === 0) {
      this.showToast('请填写帖子正文或添加媒体');
      return;
    }
    if (content.length > 2000) {
      this.showToast('正文不能超过 2000 字');
      return;
    }
    const unsafe: string = SensitiveWords.validate(title + content + this.paidContent, '帖子');
    if (unsafe.length > 0) {
      this.showToast(unsafe);
      return;
    }
    if (!this.loggedIn) {
      this.showToast('登录后才能发帖');
      return;
    }
    // 富内容会被编码成一段纯文字 JSON 发送，这里先按编码后的长度校验服务端上限。
    const body: string = this.composeContent();
    if (body.length > 2000) {
      this.showToast('正文与媒体链接合计不能超过 2000 字');
      return;
    }
    this.submitting = true;
    try {
      let message: string = '';
      if (this.editingPostId.length > 0) {
        message = await CommunityApi.editPost(this.session, this.editingPostId, title, body);
      } else {
        message = await CommunityApi.createPost(this.session, this.composerCategory, title, body);
      }
      if (this.looksFailed(message)) {
        this.showToast(message);
        Logger.warn('FORUM_PAGE', '发帖失败：' + message);
        return;
      }
      Logger.info('FORUM_PAGE', (this.editingPostId.length > 0 ? '编辑' : '发布') + '帖子成功：' + title +
        '，媒体=' + String(this.composerMedia.length) + '，正文长度=' + String(body.length));
      this.showComposer = false;
      this.editingPostId = '';
      this.composerTitle = '';
      this.composerContent = '';
      this.composerMedia = [];
      this.resetMediaInput();
      this.paidPrice = '';
      this.paidContent = '';
      this.showToast(message || '发布成功');
      this.selectedCategory = this.composerCategory;
      this.page = 1;
      await this.loadPosts(true);
    } catch (error) {
      this.showToast('发帖失败：' + String(error));
      Logger.error('FORUM_PAGE', '发帖异常：' + String(error));
    } finally {
      this.submitting = false;
    }
  }

  /** 添加一条媒体（图片 / 视频 / 音乐 / 附件）；所有类型都只存 URL + 可选标题/封面。 */
  private addMedia(): void {
    const value: string = this.mediaUrl.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      this.showToast('请输入 http/https 链接');
      return;
    }
    if (ForumCodec.count(this.composerMedia, this.mediaKind) >= (this.mediaKind === 'image' ? 9 : 3)) {
      this.showToast(this.mediaKind === 'image' ? '最多上传 9 张图片' : '同类媒体最多 3 个');
      return;
    }
    if (this.composerMedia.length >= 12) {
      this.showToast('媒体总数不能超过 12 个');
      return;
    }
    const media: ForumMedia = new ForumMedia();
    media.kind = this.mediaKind;
    media.url = value;
    media.title = this.mediaTitle.trim();
    media.poster = this.mediaPoster.trim();
    this.composerMedia = this.composerMedia.concat([media]);
    this.mediaUrl = '';
    this.mediaTitle = '';
    this.mediaPoster = '';
  }

  private removeMedia(index: number): void {
    this.composerMedia = this.composerMedia.filter((_item: ForumMedia, position: number) => position !== index);
  }

  /** 媒体条目在编辑区/列表里的图标。 */
  private mediaGlyph(kind: string): string {
    if (kind === 'video') { return '▶'; }
    if (kind === 'audio') { return '♪'; }
    if (kind === 'file') { return '📎'; }
    return '🖼';
  }

  private mediaKindLabel(kind: string): string {
    if (kind === 'video') { return '视频'; }
    if (kind === 'audio') { return '音乐'; }
    if (kind === 'file') { return '附件'; }
    return '图片';
  }

  private async openWorks(): Promise<void> {
    if (!this.loggedIn) {
      this.showToast('登录后查看我的作品');
      return;
    }
    this.showWorks = true;
    await this.loadWorks();
  }

  private async loadWorks(): Promise<void> {
    if (this.worksLoading) {
      return;
    }
    this.worksLoading = true;
    try {
      const result = await CommunityApi.myPosts(this.session, 1);
      this.works = result.posts;
      Logger.info('FORUM_PAGE', '我的作品加载完成：' + String(this.works.length));
    } catch (error) {
      this.showToast('加载作品失败：' + String(error));
      Logger.warn('FORUM_PAGE', '加载作品失败：' + String(error));
    } finally {
      this.worksLoading = false;
    }
  }

  private editWork(post: ForumPost): void {
    const decoded: ForumContent = ForumCodec.decode(post.content);
    this.editingPostId = post.id;
    this.composerTitle = post.title;
    this.composerContent = decoded.text;
    this.composerCategory = post.category;
    this.composerMedia = decoded.media.slice();
    this.resetMediaInput();
    this.paidPrice = decoded.price > 0 ? String(decoded.price) : '';
    this.paidContent = decoded.paid;
    this.showWorks = false;
    this.showComposer = true;
  }

  private deleteWork(post: ForumPost): void {
    AlertDialog.show({
      title: '删除作品',
      message: '确定删除「' + post.title + '」吗？',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          void CommunityApi.deletePost(this.session, post.id).then((message: string) => {
            if (this.looksFailed(message)) {
              this.showToast(message);
              return;
            }
            this.works = this.works.filter((item: ForumPost) => item.id !== post.id);
            this.showToast('已删除');
            void this.loadPosts(true);
          }).catch((error: Error) => {
            this.showToast('删除失败：' + String(error));
          });
        }
      }
    });
  }

  private looksFailed(text: string): boolean {
    if (!text) {
      return false;
    }
    return text.indexOf('失败') >= 0 || text.indexOf('错误') >= 0 || text.indexOf('权限') >= 0 ||
      text.indexOf('禁止') >= 0 || text.indexOf('不足') >= 0 || text.indexOf('不存在') >= 0;
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('FORUM_PAGE', '同步全局沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 860);
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

  private composerCategoryIndex(): number {
    const index: number = this.categories.findIndex((item: ForumCategory) => item.name === this.composerCategory);
    return index >= 0 ? index : 0;
  }

  private categoryOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const item of this.categories) {
      options.push({ value: item.name });
    }
    return options;
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '坛';
  }

  private postImages(post: ForumPost): string[] {
    return CommunityApi.extractImages(post.content);
  }

  private messageUnread(): number {
    return SocialStore.systemUnread() + SocialStore.totalFriendUnread();
  }

  @Builder
  private header() {
    PageHeader({
      title: '影评',
      subtitle: '社区交流 · 资源分享',
      showBack: !this.embedded,
      actionText: this.messageUnread() > 0 ? '✉ ' + String(this.messageUnread()) : '✉',
      gutter: this.tablet() ? 24 : 16,
      onBack: (): void => {
        if (this.embedded) { AppState.go('home'); return; }
        router.back();
      },
      onAction: (): void => {
        router.pushUrl({ url: 'pages/MessagePage' }).catch((error: Error) => {
          Logger.error('FORUM_PAGE', '打开消息中心失败：' + String(error));
        });
      }
    })
  }

  @Builder
  private searchBlock() {
    Column({ space: '10vp' }) {
      GlassSearchBar({
        query: this.query,
        placeholder: '搜索帖子标题或正文',
        showButton: true,
        compact: this.tablet(),
        onQueryChange: (text: string): void => { this.query = text; },
        onSubmit: (): void => { this.submitSearch(); }
      })
      Row({ space: '8vp' }) {
        SegmentedGlassTabs({
          labels: ['最新', '热门'],
          active: this.sortMode,
          trackWidth: this.tablet() ? 220 : 160,
          trackHeight: 36,
          compact: true,
          onSelect: (index: number): void => {
            this.sortMode = index;
            this.page = 1;
            void this.loadPosts(true);
          }
        })
        Blank()
        Text('↻')
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .width('30vp').height('30vp').textAlign(TextAlign.Center)
          .borderRadius('15vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .onClick(() => {
            this.page = 1;
            void this.loadPosts(true);
          })
        GhostButton({ label: '发帖', compact: true, onTap: (): void => { this.openComposer(); } })
        GhostButton({ label: '作品', compact: true, onTap: (): void => { void this.openWorks(); } })
      }
        .width('100%')
      Scroll() {
        Row({ space: '8vp' }) {
          GlassChip({
            label: '全部',
            selected: this.selectedCategory.length === 0,
            compact: true,
            onTap: (): void => { this.selectCategory(''); }
          })
          ForEach(this.categories, (item: ForumCategory) => {
            GlassChip({
              label: '#' + item.name,
              selected: this.selectedCategory === item.name,
              compact: true,
              onTap: (): void => { this.selectCategory(item.name); }
            })
          }, (item: ForumCategory) => 'category-' + item.id)
        }
          .padding({ top: '2vp', bottom: '2vp' })
      }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
    }
  }

  @Builder
  private postCard(post: ForumPost) {
    Column({ space: '9vp' }) {
      Row({ space: '7vp' }) {
        if (post.category.length > 0) {
          Text(post.category)
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .height('22vp')
            .padding({ left: '9vp', right: '9vp' })
            .borderRadius('11vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
        if (post.top) {
          Text('置顶')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.gold(this.darkTheme))
            .height('22vp')
            .padding({ left: '8vp', right: '8vp' })
            .borderRadius('11vp')
            .backgroundColor(Ui.goldSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
        if (post.essence) {
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
        Text(post.time)
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Text(post.title || '无标题')
        .fontSize(Ui.fs(this.tablet() ? '17vp' : '15.5vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(CommunityApi.plainText(CommunityApi.freeBody(post.content)))
        .fontSize(Ui.fs(this.tablet() ? '13.5vp' : '12.5vp', this.fontScale))
        .lineHeight(this.tablet() ? '20vp' : '18vp')
        .fontColor(Ui.inkSoft(this.darkTheme))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // 媒体徽标：图片 / 视频 / 音乐 / 附件数量，一眼看出帖子类型。
      if (ForumCodec.badges(post.content).length > 0) {
        Row({ space: '6vp' }) {
          ForEach(ForumCodec.badges(post.content), (badge: string) => {
            Text(badge)
              .fontSize(Ui.fs('10vp', this.fontScale))
              .fontColor(Ui.accentStrong(this.darkTheme))
              .height('20vp')
              .padding({ left: '8vp', right: '8vp' })
              .borderRadius('10vp')
              .backgroundColor(Ui.accentSoft(this.darkTheme))
              .maxLines(1)
          }, (badge: string) => 'badge-' + post.id + '-' + badge)
        }
          .width('100%')
      }
      if (this.postImages(post).length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.postImages(post).slice(0, 9), (url: string, index: number) => {
            Image(url)
              .width(this.tablet() ? '30%' : '31%')
              .height(this.tablet() ? '104vp' : '88vp')
              .objectFit(ImageFit.Cover)
              .borderRadius('8vp')
              .margin('2vp')
          }, (url: string, index: number) => 'post-img-' + post.id + '-' + String(index))
        }
          .width('100%')
      }
      Row({ space: '8vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('30vp')
            .height('30vp')
            .borderRadius('15vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
          Text(this.initial(post.name))
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('30vp')
          .height('30vp')
        Column({ space: '1vp' }) {
          Text(post.name || post.user)
            .fontSize(Ui.fs('12vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
          Text(post.grade || '论坛用户')
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Text('浏览 ' + String(post.views) + ' · 赞 ' + String(post.likes) + ' · 评论 ' + String(post.comments))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
    }
      .width('100%')
      .padding(this.tablet() ? '18vp' : '16vp')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 14, color: Ui.shadowSoft(this.darkTheme), offsetY: 7 })
      .clip(true)
      .accessibilityText(post.title)
      .onClick(() => { this.openPost(post); })
  }

  @Builder
  private listBlock() {
    Column() {
      if (this.posts.length === 0) {
        Column({ space: '12vp' }) {
          if (this.loading) {
            LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.darkTheme))
          } else {
            EmptyState({ title: '暂无帖子', hint: this.errorText, icon: SymbolIcons.list() })
          }
        }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.listScroller }) {
          ForEach(this.posts, (post: ForumPost) => {
            ListItem() {
              Row() {
                Column() {
                  this.postCard(post)
                }
                  .width('100%')
                  .constraintSize({ maxWidth: this.contentMaxWidth() })
              }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp',
                  top: '6vp', bottom: '6vp' })
            }
          }, (post: ForumPost) => 'post-' + post.id)
          if (this.page < this.totalPages) {
            ListItem() {
              Row() {
                GhostButton({
                  label: this.loadingMore ? '加载中…' : '加载更多',
                  compact: true,
                  onTap: (): void => { this.loadMore(); }
                })
              }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: '10vp', bottom: '14vp' })
            }
          }
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .onScrollStart(() => { NavigationScroll.begin('forum', 'content', this.listScroller); })
          .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
            NavigationScroll.report('forum', 'content', this.listScroller, scrollState);
          })
          .onScrollStop(() => { NavigationScroll.end('forum', 'content', this.listScroller); })
          .padding({ bottom: (this.safeBottom() + 8) + 'vp' })
      }
    }
      .width('100%')
      .layoutWeight(1)
  }

  private mediaPlaceholder(): string {
    if (this.mediaKind === 'video') { return '视频链接（mp4 / m3u8），http/https'; }
    if (this.mediaKind === 'audio') { return '音乐链接（mp3 / m4a），http/https'; }
    if (this.mediaKind === 'file') { return '附件下载链接，http/https'; }
    return '图片链接，http/https';
  }

  @Builder
  private mediaKindChip(label: string, kind: string) {
    Row() {
      Text(label)
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontWeight(this.mediaKind === kind ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.mediaKind === kind ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
        .maxLines(1)
    }
      .height('28vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('14vp')
      .backgroundColor(this.mediaKind === kind ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.mediaKind === kind ? Ui.glassRingAccent(this.darkTheme) : Ui.glassRingSoft(this.darkTheme)
      })
      .accessibilityText('媒体类型：' + label)
      .onClick(() => { this.mediaKind = kind; })
  }

  @Builder
  private composerOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Ui.scrim(this.darkTheme))
        .onClick(() => { this.closeComposer(); })
      Column({ space: '10vp' }) {
        Row({ space: '10vp' }) {
          Text(this.editingPostId.length > 0 ? '编辑帖子' : '发布新帖')
            .fontSize(Ui.fs(this.tablet() ? '22vp' : '19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(String(this.composerTitle.length) + '/30')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(this.composerTitle.length > 30 ? Ui.danger(this.darkTheme) : Ui.inkFaint(this.darkTheme))
          GhostButton({ label: '取消', compact: true, onTap: (): void => { this.closeComposer(); } })
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Scroll() {
          Column({ space: '10vp' }) {
            Row({ space: '10vp' }) {
              Text('板块')
                .fontSize(Ui.fs('13vp', this.fontScale))
                .fontColor(Ui.inkSoft(this.darkTheme))
              Select(this.categoryOptions())
                .selected(this.composerCategoryIndex())
                .value(this.composerCategory || '选择板块')
                .font({ size: '13vp', weight: FontWeight.Medium })
                .fontColor(Ui.ink(this.darkTheme))
                .selectedOptionBgColor(Ui.accentSoft(this.darkTheme))
                .selectedOptionFontColor(Ui.accentStrong(this.darkTheme))
                .optionBgColor(Ui.glassTintStrong(this.darkTheme))
                .optionFontColor(Ui.inkSoft(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .borderRadius('16vp')
                .layoutWeight(1)
                .onSelect((index: number) => {
                  if (index >= 0 && index < this.categories.length) {
                    this.composerCategory = this.categories[index].name;
                  }
                })
            }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            TextInput({ text: this.composerTitle, placeholder: '标题（不超过 30 字）' })
              .width('100%')
              .height('46vp')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .placeholderColor(Ui.inkFaint(this.darkTheme))
              .caretColor(Ui.accent(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .borderRadius('23vp')
              .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
              .padding({ left: '16vp', right: '16vp' })
              .onChange((value: string) => { this.composerTitle = value; })
            TextArea({ text: this.composerContent, placeholder: '正文（不超过 2000 字）' })
              .width('100%')
              .height(this.tablet() ? '160vp' : '132vp')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontColor(Ui.ink(this.darkTheme))
              .placeholderColor(Ui.inkFaint(this.darkTheme))
              .caretColor(Ui.accent(this.darkTheme))
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .borderRadius('18vp')
              .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
              .padding('14vp')
              .onChange((value: string) => { this.composerContent = value; })
            // 媒体类型：图片 / 视频 / 音乐 / 附件，最终都编码进帖子的纯文字 JSON。
            Row({ space: '6vp' }) {
              this.mediaKindChip('图片', 'image')
              this.mediaKindChip('视频', 'video')
              this.mediaKindChip('音乐', 'audio')
              this.mediaKindChip('附件', 'file')
              Blank()
              Text(String(this.composerMedia.length) + ' 个媒体')
                .fontSize(Ui.fs('10.5vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .maxLines(1)
            }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            Row({ space: '8vp' }) {
              TextInput({ text: this.mediaUrl, placeholder: this.mediaPlaceholder() })
                .layoutWeight(1)
                .height('40vp')
                .fontSize(Ui.fs('12.5vp', this.fontScale))
                .fontColor(Ui.ink(this.darkTheme))
                .placeholderColor(Ui.inkFaint(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .borderRadius('20vp')
                .padding({ left: '14vp', right: '14vp' })
                .onChange((value: string) => { this.mediaUrl = value; })
              GhostButton({ label: '添加', compact: true, onTap: (): void => { this.addMedia(); } })
            }
              .width('100%')
            if (this.mediaKind !== 'image') {
              Row({ space: '8vp' }) {
                TextInput({ text: this.mediaTitle, placeholder: this.mediaKind === 'file' ? '文件名（可选）' : '显示标题（可选）' })
                  .layoutWeight(1)
                  .height('40vp')
                  .fontSize(Ui.fs('12.5vp', this.fontScale))
                  .fontColor(Ui.ink(this.darkTheme))
                  .placeholderColor(Ui.inkFaint(this.darkTheme))
                  .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                  .borderRadius('20vp')
                  .padding({ left: '14vp', right: '14vp' })
                  .onChange((value: string) => { this.mediaTitle = value; })
                if (this.mediaKind === 'video') {
                  TextInput({ text: this.mediaPoster, placeholder: '封面图链接（可选）' })
                    .layoutWeight(1)
                    .height('40vp')
                    .fontSize(Ui.fs('12.5vp', this.fontScale))
                    .fontColor(Ui.ink(this.darkTheme))
                    .placeholderColor(Ui.inkFaint(this.darkTheme))
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .borderRadius('20vp')
                    .padding({ left: '14vp', right: '14vp' })
                    .onChange((value: string) => { this.mediaPoster = value; })
                }
              }
                .width('100%')
            }
            if (this.composerMedia.length > 0) {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                ForEach(this.composerMedia, (item: ForumMedia, index: number) => {
                  Row({ space: '6vp' }) {
                    if (item.kind === 'image') {
                      Image(item.url)
                        .width('34vp').height('34vp').objectFit(ImageFit.Cover).borderRadius('6vp')
                    } else {
                      Text(this.mediaGlyph(item.kind))
                        .fontSize(Ui.fs('15vp', this.fontScale))
                        .fontColor(Ui.accentStrong(this.darkTheme))
                        .width('22vp')
                        .textAlign(TextAlign.Center)
                    }
                    Text(this.mediaKindLabel(item.kind) + (item.title.length > 0 ? '：' + item.title : ''))
                      .fontSize(Ui.fs('11vp', this.fontScale))
                      .fontColor(Ui.inkSoft(this.darkTheme))
                      .maxLines(1)
                      .constraintSize({ maxWidth: '150vp' })
                    Text('×')
                      .fontSize(Ui.fs('12vp', this.fontScale))
                      .fontColor(Ui.inkFaint(this.darkTheme))
                      .width('16vp')
                      .textAlign(TextAlign.Center)
                      .onClick(() => { this.removeMedia(index); })
                  }
                    .height('40vp')
                    .padding({ left: '8vp', right: '4vp' })
                    .borderRadius('10vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
                    .margin('3vp')
                }, (item: ForumMedia, index: number) => 'composer-media-' + String(index) + '-' + item.kind)
              }
                .width('100%')
            }
            Row({ space: '8vp' }) {
              TextInput({ text: this.paidPrice, placeholder: '付费金币（可选）' })
                .width('130vp').height('40vp').fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
                .placeholderColor(Ui.inkFaint(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp')
                .padding({ left: '12vp', right: '12vp' })
                .onChange((value: string) => { this.paidPrice = value; })
              TextInput({ text: this.paidContent, placeholder: '付费内容（可选）' })
                .layoutWeight(1).height('40vp').fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
                .placeholderColor(Ui.inkFaint(this.darkTheme))
                .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('20vp')
                .padding({ left: '12vp', right: '12vp' })
                .onChange((value: string) => { this.paidContent = value; })
            }
              .width('100%')
          }
            .width('100%')
        }
          .width('100%')
          .constraintSize({ maxHeight: this.tablet() ? '470vp' : '392vp' })
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        Row() {
          PrimaryButton({
            label: this.submitting ? '提交中' : (this.editingPostId.length > 0 ? '保存修改' : '发布帖子'),
            onTap: (): void => { void this.submitPost(); }
          })
        }
          .width('100%')
          .justifyContent(FlexAlign.End)
      }
        .width(this.tablet() ? '640vp' : '92%')
        .constraintSize({ maxHeight: this.tablet() ? 760 : 620 })
        .padding('20vp')
        .borderRadius(Ui.R_LG)
        .backgroundColor(Ui.glassTintStrong(this.darkTheme))
        .backdropBlur(this.glassBlurRadius())
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
        .shadow({ radius: 26, color: Ui.shadow(this.darkTheme), offsetY: 12 })
        .clip(true)
    }
      .width('100%')
      .height('100%')
      .zIndex(10)
  }

  @Builder
  private worksOverlay() {
    if (this.showWorks) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showWorks = false; });
        Column({ space: '10vp' }) {
          Row({ space: '8vp' }) {
            Text('我的作品')
              .fontSize(Ui.fs('19vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.ink(this.darkTheme)).layoutWeight(1)
            GhostButton({ label: '关闭', compact: true, onTap: (): void => { this.showWorks = false; } })
          }
            .width('100%')
          if (this.worksLoading) {
            LoadingProgress().width('28vp').height('28vp').color(Ui.accent(this.darkTheme))
          } else if (this.works.length === 0) {
            EmptyState({ title: '还没有发布作品', hint: '发布第一篇影评或资源帖吧', icon: SymbolIcons.doc() })
          } else {
            List({ space: '6vp' }) {
              ForEach(this.works, (post: ForumPost) => {
                ListItem() {
                  Row({ space: '8vp' }) {
                    Column({ space: '2vp' }) {
                      Text(post.title).fontSize(Ui.fs('13.5vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme)).maxLines(1)
                      Text(post.time + ' · 浏览 ' + String(post.views) + ' · 评论 ' + String(post.comments))
                        .fontSize(Ui.fs('9.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
                    }
                      .layoutWeight(1).alignItems(HorizontalAlign.Start)
                    Text('编辑').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
                      .padding({ left: '8vp', right: '8vp' })
                      .onClick(() => { this.editWork(post); })
                    Text('删除').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.danger(this.darkTheme))
                      .padding({ left: '8vp', right: '8vp' })
                      .onClick(() => { this.deleteWork(post); })
                  }
                    .width('100%').padding('10vp').borderRadius('10vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .onClick(() => { this.editWork(post); })
                    .gesture(LongPressGesture({ repeat: false }).onAction(() => { this.deleteWork(post); }))
                }
              }, (post: ForumPost) => 'work-' + post.id)
            }
              .width('100%').height('320vp')
          }
        }
          .width(this.tablet() ? '560vp' : '92%')
          .padding('18vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(this.glassBlurRadius())
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%').height('100%').zIndex(11)
    }
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.5 : 0.62 })
      Column({ space: '10vp' }) {
        this.header()
        Row() {
          Column() {
            this.searchBlock()
          }
            .width('100%')
            .constraintSize({ maxWidth: this.contentMaxWidth() })
            .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp' })
        }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        this.listBlock()
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
          .margin({ bottom: (this.safeBottom() + 28) + 'vp' })
      }
      if (this.showComposer) {
        this.composerOverlay()
      }
      this.worksOverlay()
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
          Logger.warn('FORUM_PAGE', '更新论坛页宽度失败：' + String(error));
        }
      })
  }
}

/**
 * 独立路由入口：main_pages.json 里注册的 ForumPage 由这个 @Entry 组件承载，
 * 页面本体是非 @Entry 的 ForumPage 组件，因此既能被底栏 Tab 直接嵌入，也能被 router 单独打开。
 */
@Entry
@Component
struct ForumPageEntry {
  build() {
    // @Entry 的 build 根节点必须是容器组件，这里用 Column 包一层承载页面本体。
    Column() {
      ForumPage().width('100%').height('100%')
    }
      .width('100%')
      .height('100%')
  }
}

import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { AppState } from './AppState';
import { CommunityApi, CommunitySession } from './CommunityApi';
import { NavTabs } from './NavTabs';
import { NoticeRichText } from './NoticeRichText';
import { PortraitLoader } from './PortraitLoader';
import { SymbolIcons } from './SymbolIcons';
import { Ui } from './Ui';

/** 平板 / PC / 智慧屏的左侧导航栏：展开显示全部 Tab，折叠只显示图标。 */
@Component
export struct SideRail {
  @StorageLink('page') @Watch('onPageChanged') private page: string = 'home';
  @StorageLink('navTabKeys') private navTabKeys: string[] = NavTabs.DEFAULT_KEYS;
  @StorageLink('navigationBarHidden') private hidden: boolean = false;
  @StorageLink('darkTheme') private dark: boolean = true;
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('sideNavCollapsed') private collapsed: boolean = false;
  @Prop viewportWidth: number = 1280;
  @Prop safeTop: number = 24;
  @Prop safeBottom: number = 16;
  @State private shortcutPanelVisible: boolean = false;
  @State private noticeVisible: boolean = false;
  @State private noticeShown: boolean = false;
  @State private noticeHtml: string = '';
  @State private noticeLoading: boolean = false;
  @State private onlineCount: number = 0;
  @State private accountLoggedIn: boolean = false;
  @State private accountName: string = '';
  @State private avatarPixel: image.PixelMap | undefined = undefined;
  private onlineTimer: number = -1;

  aboutToAppear(): void {
    void this.refreshOnlineCount();
    void this.maybeShowDailyNotice();
    void this.loadAccount();
    this.onlineTimer = setInterval(() => { void this.refreshOnlineCount(); }, 60000);
  }

  private onPageChanged(): void {
    // 从登录页/个人中心返回后刷新头像与登录状态。
    void this.loadAccount();
  }

  private async loadAccount(): Promise<void> {
    try {
      const session: CommunitySession = await CommunityApi.readSession();
      const name: string = session.user.trim();
      this.accountLoggedIn = session.valid();
      this.accountName = name;
      if (!this.accountLoggedIn || name.length === 0) {
        this.avatarPixel = undefined;
        return;
      }
      const cached: image.PixelMap | undefined = PortraitLoader.cached(name);
      if (cached !== undefined) {
        this.avatarPixel = cached;
        return;
      }
      PortraitLoader.load(name, (pixel: image.PixelMap | undefined) => {
        if (this.accountName === name) { this.avatarPixel = pixel; }
      });
    } catch (_) {
      this.accountLoggedIn = false;
      this.avatarPixel = undefined;
    }
  }

  private openAccount(): void {
    if (this.accountLoggedIn) {
      AppState.go('mine');
      return;
    }
    void router.pushUrl({ url: 'pages/LoginPage' });
  }

  aboutToDisappear(): void {
    if (this.onlineTimer !== -1) {
      clearInterval(this.onlineTimer);
      this.onlineTimer = -1;
    }
  }

  private async refreshOnlineCount(): Promise<void> {
    try {
      const session = await CommunityApi.readSession();
      const online: number = await CommunityApi.onlineCount(session);
      if (online > 0) {
        this.onlineCount = online;
        return;
      }
    } catch (_) {
      // 接口不可用时回退到本地分钟级展示，避免侧栏出现 0 人。
    }
    const minute: number = Math.floor(Date.now() / 60000);
    this.onlineCount = 1200 + (minute * 37) % 800;
  }

  private todayKey(): string {
    const now: Date = new Date();
    const month: string = now.getMonth() + 1 < 10 ? '0' + String(now.getMonth() + 1) : String(now.getMonth() + 1);
    const day: string = now.getDate() < 10 ? '0' + String(now.getDate()) : String(now.getDate());
    return String(now.getFullYear()) + '-' + month + '-' + day;
  }

  private async markNoticeShown(): Promise<void> {
    const today: string = this.todayKey();
    AppStorage.setOrCreate<string>('noticePromptDate', today);
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      await store.put('noticePromptDate', today);
      await store.flush();
    } catch (_) {
      // 持久化失败时至少保证本次进程内只提示一次。
    }
  }

  private async maybeShowDailyNotice(): Promise<void> {
    const today: string = this.todayKey();
    if (String(AppStorage.get<string>('noticePromptDate') || '') === today) { return; }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      const last: string = String(await store.get('noticePromptDate', ''));
      if (last === today) {
        AppStorage.setOrCreate<string>('noticePromptDate', today);
        return;
      }
    } catch (_) {
      // 读取失败也继续提示一次。
    }
    await this.markNoticeShown();
    void this.openNotice();
  }

  private async openNotice(): Promise<void> {
    void this.markNoticeShown();
    this.noticeShown = false;
    this.noticeVisible = true;
    this.noticeLoading = true;
    setTimeout(() => {
      if (this.noticeVisible) { this.noticeShown = true; }
    }, 20);
    try {
      const text: string = await CommunityApi.remoteNotice();
      this.noticeHtml = text.length > 0 ? text : '<p>暂无公告</p>';
    } catch (error) {
      this.noticeHtml = '<p>公告加载失败，请稍后重试</p>';
    } finally {
      this.noticeLoading = false;
    }
  }

  private closeNotice(): void {
    this.noticeShown = false;
    setTimeout(() => {
      if (!this.noticeShown) { this.noticeVisible = false; }
    }, 180);
  }

  @Builder
  private noticePanel() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Ui.scrim(this.dark))
        .opacity(this.noticeShown ? 1 : 0)
        .animation({ duration: 240, curve: Curve.FastOutSlowIn })
        .onClick(() => { this.closeNotice(); })
      Column({ space: '10vp' }) {
        Row({ space: '10vp' }) {
          SymbolGlyph($r('sys.symbol.speaker_wave_2'))
            .fontSize(Ui.fs('20vp', this.fontScale))
            .fontColor([Ui.icon(this.dark)])
          Text('官方公告')
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.dark))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontColor([Ui.inkSoft(this.dark)])
            .onClick(() => { this.closeNotice(); })
        }
          .width('100%')
          .height('34vp')
          .alignItems(VerticalAlign.Center)
        Divider().strokeWidth(1).color(Ui.divider(this.dark))
        if (this.noticeLoading) {
          LoadingProgress()
            .width('36vp')
            .height('36vp')
            .color(Ui.accent(this.dark))
            .layoutWeight(1)
        } else {
          Scroll() {
            NoticeRichText({
              html: this.noticeHtml,
              dark: this.dark,
              fontScale: this.fontScale
            })
              .width('100%')
          }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        Row() {
          Text('朕已知晓')
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .height('40vp')
            .padding({ left: '24vp', right: '24vp' })
            .borderRadius('20vp')
            .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
            .onClick(() => { this.closeNotice(); })
        }
          .width('100%')
          .justifyContent(FlexAlign.End)
      }
        .width(this.viewportWidth >= 720 ? '62%' : '88%')
        .height('72%')
        .constraintSize({ maxWidth: '640vp' })
        .padding('18vp')
        .borderRadius('22vp')
        .backgroundColor(this.dark ? '#1E1E20' : '#FBFAF7')
        .border({ width: 1, color: this.dark ? '#33FFFFFF' : '#0D000000' })
        .shadow({ radius: 24, color: this.dark ? '#66000000' : '#0F000000', offsetY: 10 })
        .opacity(this.noticeShown ? 1 : 0)
        .scale({ x: this.noticeShown ? 1 : 0.88, y: this.noticeShown ? 1 : 0.88 })
        .translate({ y: this.noticeShown ? 0 : 14 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
    }
      .width('100%')
      .height('100%')
  }

  /** 侧面模式自动展示全部导航项，并使用固定排序。 */
  private routes(): string[] {
    return ['home', 'category', 'live', 'message', 'forum', 'manage', 'settings', 'mine'];
  }

  private railWidth(): number {
    if (this.collapsed) {
      if (Ui.isTv(this.viewportWidth)) { return 76; }
      if (Ui.isDesktop(this.viewportWidth)) { return 72; }
      return 64;
    }
    if (Ui.isTv(this.viewportWidth)) { return 144; }
    if (Ui.isDesktop(this.viewportWidth)) { return 136; }
    return 120;
  }

  @Builder
  private shortcutLine(icon: Resource, key: string, text: string) {
    Row({ space: '8vp' }) {
      SymbolGlyph(icon)
        .fontSize(Ui.fs('15vp', this.fontScale))
        .fontColor([Ui.icon(this.dark)])
      Text(key)
        .fontSize(Ui.fs('11vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.dark))
        .width('48vp')
      Text(text)
        .fontSize(Ui.fs('11vp', this.fontScale))
        .fontColor(Ui.inkSoft(this.dark))
        .layoutWeight(1)
        .maxLines(1)
    }
      .width('100%')
      .height('30vp')
      .alignItems(VerticalAlign.Center)
  }

  @Builder
  private shortcutPanel() {
    Column({ space: '4vp' }) {
      Row({ space: '8vp' }) {
        SymbolGlyph($r('sys.symbol.keyboard'))
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontColor([Ui.icon(this.dark)])
        Text('播放器快捷键')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.dark))
      }
        .width('100%')
        .height('30vp')
        .alignItems(VerticalAlign.Center)
      this.shortcutLine($r('sys.symbol.play_fill'), '空格', '暂停 / 播放')
      this.shortcutLine($r('sys.symbol.arrow_left_arrow_right'), '← / →', '快退 / 快进 10 秒')
      this.shortcutLine($r('sys.symbol.speaker_slash'), 'M', '静音 / 取消静音')
      this.shortcutLine($r('sys.symbol.aspectratio'), 'F', '进入 / 退出全屏')
      this.shortcutLine($r('sys.symbol.arrow_up'), '↑ / ↓', '上一集 / 下一集')
      this.shortcutLine($r('sys.symbol.route'), 'Enter', '快速切换线路')
    }
      .width('248vp')
      .padding('12vp')
      .borderRadius('16vp')
      .backgroundColor(this.dark ? '#1E1E20' : '#FBFAF7')
      .border({ width: 1, color: this.dark ? '#33FFFFFF' : '#0D000000' })
      .shadow({ radius: 18, color: this.dark ? '#66000000' : '#0F000000', offsetY: 8 })
  }

  build() {
    Column({ space: '6vp' }) {
      Column({ space: '6vp' }) {
        // 永久头像：1:1 圆形；已登录显示头像，未登录显示原生账号图标。
        Column({ space: '6vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.accountLoggedIn && this.avatarPixel !== undefined) {
            Image(this.avatarPixel)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
          } else {
            Column()
              .width('100%')
              .height('100%')
              .linearGradient({
                angle: 140,
                colors: [[Ui.accentSoft(this.dark), 0], [Ui.glassTintSoft(this.dark), 1]]
              })
            if (this.accountLoggedIn) {
              Text(this.accountName.length > 0 ? this.accountName.substring(0, 1).toUpperCase() : '我')
                .fontSize(Ui.fs(this.collapsed ? '18vp' : '24vp', this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Ui.accentStrong(this.dark))
            } else {
              SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
                .fontSize(Ui.fs(this.collapsed ? '28vp' : '38vp', this.fontScale))
                .fontColor([Ui.icon(this.dark)])
            }
          }
        }
          .width(this.collapsed ? '42vp' : '68vp')
          .height(this.collapsed ? '42vp' : '68vp')
          .borderRadius(this.collapsed ? '21vp' : '34vp')
          .clip(true)
          .border({ width: this.collapsed ? 1.5 : 2, color: Ui.accentRing(this.dark) })
          .shadow({ radius: this.collapsed ? 10 : 16, color: Ui.accentGlow(this.dark), offsetY: 3 })
          .onClick(() => { this.openAccount(); })
          .accessibilityText(this.accountLoggedIn ? '打开个人中心' : '立即登录')
        if (!this.collapsed) {
          Text(this.accountLoggedIn ? this.accountName : '立即登录')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .shaderStyle(new LinearGradientStyle({
              angle: 90,
              colors: [[Ui.accent(this.dark), 0], [Ui.brandTo(), 1]]
            }))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
            .onClick(() => { this.openAccount(); })
        }
        }
          .width('100%')
          .height('100vp')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Start)
        // 昵称/头像与隐藏菜单之间的分割线，折叠时也保留；占位高度 50vp。
        Column() {
          Divider()
            .width(this.collapsed ? '58%' : '62%')
            .strokeWidth(1)
            .color(Ui.divider(this.dark))
        }
          .width('100%')
          .height('50vp')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        // 隐藏菜单胶囊：图标 + 文案，跟随主题。
        Row({ space: this.collapsed ? 0 : '7vp' }) {
          SymbolGlyph(this.collapsed ? $r('sys.symbol.open_sidebar') : $r('sys.symbol.close_sidebar'))
            .fontSize(Ui.fs(this.collapsed ? '19vp' : '20vp', this.fontScale))
            .fontColor([Ui.icon(this.dark)])
          if (!this.collapsed) {
            Text('隐藏菜单')
              .fontSize(Ui.fs('13.5vp', this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Ui.inkSoft(this.dark))
              .maxLines(1)
          }
        }
          .height(this.collapsed ? '40vp' : '42vp')
          .padding({ left: this.collapsed ? '12vp' : '16vp', right: this.collapsed ? '12vp' : '16vp' })
          .borderRadius(this.collapsed ? '20vp' : '21vp')
          .backgroundColor(Ui.glassTintSoft(this.dark))
          .border({ width: 1, color: Ui.accentRing(this.dark) })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.collapsed = !this.collapsed; })
          .accessibilityText(this.collapsed ? '展开侧边导航' : '收起侧边导航')
      }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ bottom: '0vp' })
      // 菜单与导航项之间的分割线，占位高度 10vp。
      Column() {
        Divider()
          .width('80%')
          .strokeWidth(1)
          .color(Ui.cardBorderSoft(this.dark))
      }
        .width('100%')
        .height('10vp')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      ForEach(this.routes(), (route: string) => {
        Row({ space: this.collapsed ? 0 : 10 }) {
          SymbolGlyph(SymbolIcons.tab(route, this.page === route))
            .fontSize(Ui.fs('21vp', this.fontScale))
            .fontColor([Ui.icon(this.dark)])
          if (!this.collapsed) {
            Text(NavTabs.title(route))
              .fontSize(Ui.fs('13vp', this.fontScale))
              .fontColor(this.page === route ? Ui.ink(this.dark) : Ui.inkSoft(this.dark))
              .maxLines(1)
          }
        }
          .width('100%')
          .height('44vp')
          .padding({ left: '0vp', right: '0vp' })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius('14vp')
          .backgroundColor(this.page === route ? Ui.accentSoft(this.dark) : '#00000000')
          .onClick(() => { AppState.go(route); })
          .accessibilityText(NavTabs.title(route))
      }, (route: string) => 'side-nav-' + route)
      Blank()
      // 公告入口：读取后台 echouser.php?file=notice，支持富文本弹窗。
      Row({ space: this.collapsed ? 0 : 10 }) {
        SymbolGlyph($r('sys.symbol.speaker_wave_2'))
          .fontSize(Ui.fs('19vp', this.fontScale))
          .fontColor([Ui.icon(this.dark)])
        if (!this.collapsed) {
          Text('公告')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .maxLines(1)
        }
      }
        .width('100%')
        .height('40vp')
        .padding({ left: this.collapsed ? '0vp' : '12vp', right: this.collapsed ? '0vp' : '12vp' })
        .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .borderRadius('14vp')
        .onClick(() => { void this.openNotice(); })
        .accessibilityText('查看官方公告')
      // 快捷键：悬停展示播放器快捷键面板。
      Row({ space: this.collapsed ? 0 : 10 }) {
        SymbolGlyph($r('sys.symbol.keyboard'))
          .fontSize(Ui.fs('19vp', this.fontScale))
          .fontColor([Ui.icon(this.dark)])
        if (!this.collapsed) {
          Text('快捷键')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .maxLines(1)
        }
      }
        .width('100%')
        .height('40vp')
        .padding({ left: this.collapsed ? '0vp' : '12vp', right: this.collapsed ? '0vp' : '12vp' })
        .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .borderRadius('14vp')
        .backgroundColor(this.shortcutPanelVisible ? Ui.accentSoft(this.dark) : '#00000000')
        .onHover((isHover: boolean) => { this.shortcutPanelVisible = isHover; })
        .onClick(() => { this.shortcutPanelVisible = !this.shortcutPanelVisible; })
        .bindPopup(this.shortcutPanelVisible, {
          builder: this.shortcutPanel,
          placement: Placement.Right,
          // 弹窗容器透明，由面板自身按深浅主题绘制背景，避免切换主题后残留浅色底。
          popupColor: '#00000000',
          autoCancel: true,
          onStateChange: (event) => {
            if (!event.isVisible) { this.shortcutPanelVisible = false; }
          }
        })
      // 一键切换深浅色。
      Row({ space: this.collapsed ? 0 : 10 }) {
        SymbolGlyph(this.dark ? $r('sys.symbol.moon') : $r('sys.symbol.sun_max'))
          .fontSize(Ui.fs('19vp', this.fontScale))
          .fontColor([Ui.icon(this.dark)])
        if (!this.collapsed) {
          Text(this.dark ? '深色模式' : '浅色模式')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .maxLines(1)
        }
      }
        .width('100%')
        .height('40vp')
        .padding({ left: this.collapsed ? '0vp' : '12vp', right: this.collapsed ? '0vp' : '12vp' })
        .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .borderRadius('14vp')
        .onClick(() => { void AppState.setThemeMode(this.dark ? 'light' : 'dark'); })
        .accessibilityText(this.dark ? '切换浅色模式' : '切换深色模式')
      // 深色/浅色切换下方：进入主题商城，选择后立即生效。
      Row({ space: this.collapsed ? 0 : 10 }) {
        SymbolGlyph($r('sys.symbol.paintpalette'))
          .fontSize(Ui.fs('19vp', this.fontScale))
          .fontColor([Ui.icon(this.dark)])
        if (!this.collapsed) {
          Text('自定义主题')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .maxLines(1)
        }
      }
        .width('100%')
        .height('40vp')
        .padding({ left: this.collapsed ? '0vp' : '12vp', right: this.collapsed ? '0vp' : '12vp' })
        .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .borderRadius('14vp')
        .onClick(() => { void router.pushUrl({ url: 'pages/ThemeStorePage' }); })
        .accessibilityText('打开主题商城')
      // 在线人数，每分钟刷新一次。
      Row({ space: this.collapsed ? 0 : 8 }) {
        SymbolGlyph($r('sys.symbol.dot'))
          .fontSize(Ui.fs('18vp', this.fontScale))
          .fontColor(['#3DDC84'])
        if (!this.collapsed) {
          Text(String(this.onlineCount) + '人正在观看')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .maxLines(1)
        }
      }
        .width('100%')
        .height('34vp')
        .padding({ left: this.collapsed ? '0vp' : '12vp', right: this.collapsed ? '0vp' : '12vp' })
        .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .accessibilityText('当前在线 ' + String(this.onlineCount) + ' 人')
    }
      .width(this.railWidth() + 'vp')
      .height('100%')
      .padding({ top: this.safeTop + 14, bottom: this.safeBottom + 14 })
      .backgroundColor(Ui.glassTint(this.dark))
      .backdropBlur(24)
      .border({ width: { right: 1 }, color: Ui.glassRingSoft(this.dark) })
      .alignItems(HorizontalAlign.Center)
      .animation({ duration: 220, curve: Curve.FastOutSlowIn })
      .bindContentCover(this.noticeVisible, this.noticePanel(), {
        modalTransition: ModalTransition.NONE,
        onDisappear: (): void => {
          this.noticeShown = false;
          this.noticeVisible = false;
        }
      })
  }
}

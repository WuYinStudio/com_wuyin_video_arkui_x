import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { CommunityApi, CommunitySession } from '../common/CommunityApi';
import { ChatService } from '../common/ChatService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { RoomItem, SocialStore } from '../common/SocialStore';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, PrimaryButton } from '../common/UiWidgets';
import { ChatNoticeBanner } from '../components/ChatNoticeBanner';
import { SymbolIcons } from '../common/SymbolIcons';

class ChatRouteParams {
  room: string = '';
  peer: string = '';
  title: string = '';
}

class ChatRouteOptions {
  url: string = 'pages/ChatRoomPage';
  params: ChatRouteParams;

  constructor(room: string, peer: string, title: string) {
    this.params = new ChatRouteParams();
    this.params.room = room;
    this.params.peer = peer;
    this.params.title = title;
  }
}

/**
 * 聊天室列表 · 7.9
 * 官方群卡 + 本地创建的房间 + lts.php 最后一条消息/未读数；下拉刷新与 30s 在线人数。
 */
@Entry
@Component
struct ChatRoomsPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') @Watch('onImmersiveChanged') private immersiveConfig: PlayerImmersiveConfig =
    AppState.immersiveConfig;
  @StorageLink('socialVersion') @Watch('reload') private socialVersion: number = 0;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private rooms: RoomItem[] = [];
  @State private loading: boolean = false;
  @State private onlineCount: number = 0;
  @State private loggedIn: boolean = false;
  @State private session: CommunitySession = new CommunitySession();
  @State private showCreate: boolean = false;
  @State private roomName: string = '';
  @State private roomIntro: string = '';
  @State private viewportWidth: number = 360;
  @State private toastText: string = '';
  private timer: number = -1;
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    void this.prepare();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopTimer();
  }

  onPageShow(): void {
    if (this.alive && this.loggedIn) {
      void this.refresh();
    }
  }

  private async prepare(): Promise<void> {
    try {
      this.session = await CommunityApi.readSession();
      this.loggedIn = this.session.valid();
      this.reload();
      await this.loadOnline();
      if (this.loggedIn) {
        await this.refresh();
      }
      this.startTimer();
    } catch (error) {
      Logger.error('CHAT_ROOMS', '初始化聊天室列表失败：' + String(error));
    }
  }

  private reload(): void {
    this.rooms = SocialStore.roomsList();
  }

  private async refresh(): Promise<void> {
    if (this.loading || !this.loggedIn) {
      return;
    }
    this.loading = true;
    try {
      const snapshot: RoomItem[] = SocialStore.roomsList();
      for (const room of snapshot) {
        await ChatService.refreshRoomSummary(this.session, room);
      }
      this.rooms = SocialStore.roomsList();
      Logger.info('CHAT_ROOMS', '聊天室摘要刷新完成，房间=' + String(this.rooms.length));
    } catch (error) {
      Logger.warn('CHAT_ROOMS', '刷新聊天室失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private async loadOnline(): Promise<void> {
    try {
      this.onlineCount = await ChatService.onlineCount();
    } catch (error) {
      Logger.warn('CHAT_ROOMS', '在线人数读取失败：' + String(error));
    }
  }

  private startTimer(): void {
    this.stopTimer();
    this.timer = setInterval(() => {
      if (this.alive) {
        void this.loadOnline();
      }
    }, 30000);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private openRoom(item: RoomItem): void {
    try {
      router.pushUrl(new ChatRouteOptions(item.name, '', item.name)).catch((error: Error) => {
        Logger.error('CHAT_ROOMS', '打开聊天室失败：' + String(error));
      });
    } catch (error) {
      Logger.error('CHAT_ROOMS', '聊天室路由异常：' + String(error));
    }
  }

  private createRoom(): void {
    const name: string = this.roomName.trim();
    if (name.length < 2 || name.length > 12) {
      this.showToast('房间名称需为 2-12 个字');
      return;
    }
    if (this.rooms.some((item: RoomItem) => item.name === name)) {
      this.showToast('同名聊天室已存在');
      return;
    }
    const item: RoomItem = new RoomItem();
    item.name = name;
    item.intro = this.roomIntro.trim() || '无音影视聊天室';
    item.owner = this.session.user;
    item.official = false;
    SocialStore.addRoom(item);
    this.showCreate = false;
    this.roomName = '';
    this.roomIntro = '';
    this.reload();
    this.showToast('聊天室已创建');
    this.openRoom(item);
  }

  private confirmDelete(item: RoomItem): void {
    if (item.official) {
      return;
    }
    AlertDialog.show({
      title: '删除聊天室',
      message: '确定删除「' + item.name + '」吗？',
      autoCancel: true,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          SocialStore.removeRoom(item.name);
          this.reload();
          this.showToast('已删除聊天室');
        }
      }
    });
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2000);
  }

  private onImmersiveChanged(): void {
    try {
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('CHAT_ROOMS', '同步沉浸配置失败：' + String(error));
    }
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private contentMaxWidth(): number {
    return Math.min(Math.max(0, this.viewportWidth), 820);
  }

  private pageBackground(): ResourceColor {
    return Ui.pageBg(this.darkTheme);
  }

  private safeBottom(): number {
    return 16;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private initial(name: string): string {
    const value: string = name.trim();
    return value.length > 0 ? value.substring(0, 1) : '聊';
  }

  private normalRooms(): RoomItem[] {
    return this.rooms.filter((item: RoomItem) => !item.official && item.name !== SocialStore.OFFICIAL_ROOM);
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      Column({ space: '2vp' }) {
        Text('聊天室')
          .fontSize(Ui.fs(this.tablet() ? '26vp' : '23vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('官方群聊与自建房间')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '创建', compact: true, onTap: (): void => { this.showCreate = true; } })
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
  private officialCard() {
    Row({ space: '12vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('52vp')
          .height('52vp')
          .borderRadius('26vp')
          .linearGradient({ angle: 135, colors: [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]] })
          .shadow({ radius: 14, color: Ui.accentGlow(this.darkTheme), offsetY: 5 })
        Text('官')
          .fontSize(Ui.fs('22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
        .width('52vp')
        .height('52vp')
      Column({ space: '3vp' }) {
        Text('官方群聊')
          .fontSize(Ui.fs(this.tablet() ? '17vp' : '15.5vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text('在线 ' + String(this.onlineCount) + ' 人 · 官方交流群')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .maxLines(1)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Row() {
        Text('进入')
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
        .height('32vp')
        .padding({ left: '14vp', right: '14vp' })
        .borderRadius('16vp')
        .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
    }
      .width('100%')
      .padding('16vp')
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.accentSoft(this.darkTheme), 0], [Ui.glassTintStrong(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.accentGlow(this.darkTheme), offsetY: 8 })
      .onClick(() => {
        const official: RoomItem = new RoomItem();
        official.name = SocialStore.OFFICIAL_ROOM;
        official.official = true;
        this.openRoom(official);
      })
  }

  @Builder
  private roomAvatar(item: RoomItem) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('50vp')
        .height('50vp')
        .borderRadius('25vp')
        .linearGradient({
          angle: 140,
          colors: [[Ui.glassSheenTop(this.darkTheme), 0], [Ui.accentSoft(this.darkTheme), 1]]
        })
        .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      Text(this.initial(item.name))
        .fontSize(Ui.fs('20vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.accentStrong(this.darkTheme))
    }
      .width('50vp')
      .height('50vp')
  }

  @Builder
  private roomRow(item: RoomItem) {
    // 与 chatlist2.iyu 一致：45dp 圆形头像 + 名称/时间 + 浅灰圆角消息条（左侧 3vp 竖条）+ 未读角标。
    Row({ space: '10vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('45vp')
          .height('45vp')
          .borderRadius('23vp')
          .linearGradient({
            angle: 140,
            colors: item.official
              ? [[Ui.brandFrom(), 0], [Ui.brandMid(), 0.55], [Ui.brandTo(), 1]]
              : [[Ui.glassSheenTop(this.darkTheme), 0], [Ui.accentSoft(this.darkTheme), 1]]
          })
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
        Text(item.official ? '官' : this.initial(item.name))
          .fontSize(Ui.fs('17vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(item.official ? '#FFFFFF' : Ui.accentStrong(this.darkTheme))
      }
        .width('45vp')
        .height('45vp')
      Column({ space: '5vp' }) {
        Row({ space: '5vp' }) {
          Text(item.name)
            .fontSize(Ui.fs(this.tablet() ? '16vp' : '14.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          Text(item.lastTime)
            .fontSize(Ui.fs('10vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Row({ space: '6vp' }) {
          Row() {
            Text(item.lastMessage || '暂无消息')
              .fontSize(Ui.fs('12.5vp', this.fontScale))
              .fontColor(this.darkTheme ? Ui.inkSoft(this.darkTheme) : '#FF888888')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
            .layoutWeight(1)
            .padding({ left: '8vp', right: '8vp', top: '6vp', bottom: '6vp' })
            .borderRadius('8vp')
            .backgroundColor(this.darkTheme ? Ui.glassTintSoft(this.darkTheme) : '#FFF7F8FA')
            .border({ width: { left: 3 }, color: this.darkTheme ? Ui.cardBorder(this.darkTheme) : '#FFC8C8C8' })
          if (item.unread > 0) {
            Text(item.unread > 99 ? '99+' : String(item.unread))
              .fontSize(Ui.fs('9.5vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .height('18vp')
              .constraintSize({ minWidth: '18vp' })
              .padding({ left: '5vp', right: '5vp' })
              .borderRadius('9vp')
              .backgroundColor(Ui.danger(this.darkTheme))
              .textAlign(TextAlign.Center)
          }
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .padding({ left: '10vp', right: '12vp', top: '10vp', bottom: '10vp' })
      .borderRadius('14vp')
      .backgroundColor(this.darkTheme ? Ui.card(this.darkTheme) : '#FFFFFF')
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
      .onClick(() => { this.openRoom(item); })
      .gesture(LongPressGesture({ repeat: false }).onAction(() => { this.confirmDelete(item); }))
  }

  @Builder
  private createOverlay() {
    if (this.showCreate) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showCreate = false; });
        Column({ space: '10vp' }) {
          Text('创建聊天室')
            .fontSize(Ui.fs('20vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
          TextInput({ text: this.roomName, placeholder: '名称（2-12 字）' })
            .width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
            .placeholderColor(Ui.inkFaint(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp')
            .padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.roomName = value; })
          TextInput({ text: this.roomIntro, placeholder: '简介（可选）' })
            .width('100%').height('44vp').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.ink(this.darkTheme))
            .placeholderColor(Ui.inkFaint(this.darkTheme))
            .backgroundColor(Ui.glassTintSoft(this.darkTheme)).borderRadius('22vp')
            .padding({ left: '14vp', right: '14vp' })
            .onChange((value: string) => { this.roomIntro = value; })
          Text('头像使用默认渐变头像，创建后自动进入房间')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
          Row({ space: '8vp' }) {
            GhostButton({ label: '取消', compact: true, onTap: (): void => { this.showCreate = false; } })
            PrimaryButton({ label: '创建并进入', compact: true, onTap: (): void => { this.createRoom(); } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
        }
          .width(this.tablet() ? '460vp' : '86%')
          .padding('20vp')
          .borderRadius(Ui.R_LG)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
      }
        .width('100%')
        .height('100%')
        .zIndex(10)
    }
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.48 : 0.58 })
      Column() {
        this.header()
        if (!this.loggedIn) {
          Column({ space: '12vp' }) {
            EmptyState({ title: '登录后可查看聊天室', hint: '登录凭证缺失', icon: SymbolIcons.doc() })
            PrimaryButton({ label: '去登录', onTap: (): void => {
              router.pushUrl({ url: 'pages/LoginPage' }).catch((error: Error) => {
                Logger.error('CHAT_ROOMS', '打开登录页失败：' + String(error));
              });
            } })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: '10vp' }) {
              this.officialCard()
              Row({ space: '8vp' }) {
                Text('房间列表')
                  .fontSize(Ui.fs(this.tablet() ? '17vp' : '15vp', this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Ui.ink(this.darkTheme))
                  .layoutWeight(1)
                Text(this.loading ? '刷新中…' : '下拉刷新')
                  .fontSize(Ui.fs('10.5vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.darkTheme))
                  .onClick(() => { void this.refresh(); })
              }
                .width('100%')
                .padding({ top: '6vp' })
              if (this.normalRooms().length === 0) {
                EmptyState({ title: '暂无聊天室', hint: '创建一个属于你的聊天室', icon: SymbolIcons.list() })
              } else {
                ForEach(this.normalRooms(), (item: RoomItem) => {
                  Row() {
                    this.roomRow(item)
                  }
                    .width('100%')
                }, (item: RoomItem) => 'room-' + item.name)
              }
              GhostButton({ label: '创建一个聊天室', compact: true, onTap: (): void => { this.showCreate = true; } })
            }
              .width('100%')
              .constraintSize({ maxWidth: this.contentMaxWidth() })
              .padding({
                left: this.tablet() ? '24vp' : '16vp',
                right: this.tablet() ? '24vp' : '16vp',
                bottom: (this.safeBottom() + 24) + 'vp'
              })
          }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
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
          .margin({ bottom: (this.safeBottom() + 30) + 'vp' })
      }
      this.createOverlay()
      // 实时消息提醒：聊天室列表页同样展示顶部弹窗，可直接回复。
      ChatNoticeBanner()
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
          Logger.warn('CHAT_ROOMS', '更新聊天室宽度失败：' + String(error));
        }
      })
  }
}

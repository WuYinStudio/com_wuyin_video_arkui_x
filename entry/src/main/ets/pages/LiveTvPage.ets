import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { LiveChannel, LiveService } from '../common/LiveService';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GhostButton, GlassSearchBar } from '../common/UiWidgets';
import { SymbolIcons } from '../common/SymbolIcons';

class LivePlayerParams {
  vodId: string = '';
  tilie: string = '';
  yhm: string = '';
  feng: string = '';
  wzlj: string = '';
  live: string = '1';
}

/**
 * 直播频道 → 播放器路由参数。
 *
 * PlayerPage 只认 { vodId, tilie, yhm, feng, wzlj }，其中 wzlj 是
 * "标题$地址#标题$地址" 的选集串（parseWzlj 解析）。
 * 这里把频道的每条线路都转成一集：`频道名 线路N$流地址`，因此直播页
 * 可以直接用 PlayerPage 的选集面板切换备用线路，不需要单独的播放页。
 */
class LivePlayerOptions {
  url: string = 'pages/PlayerPage';
  params: LivePlayerParams;

  constructor(channel: LiveChannel) {
    this.params = new LivePlayerParams();
    const name: string = channel.name.length > 0 ? channel.name : '电视直播';
    this.params.vodId = 'live-' + name;
    this.params.tilie = name + ' · 直播';
    this.params.yhm = name;
    this.params.feng = channel.logo;
    const parts: string[] = [];
    for (let index = 0; index < channel.sources.length; index++) {
      const source: string = channel.sources[index].trim();
      if (source.length === 0) { continue; }
      parts.push(name + ' 线路' + String(parts.length + 1) + '$' + source);
    }
    this.params.wzlj = parts.join('#');
  }

  valid(): boolean {
    return this.params.wzlj.length > 0;
  }
}

/**
 * 电视直播频道列表。
 * 数据来自 rawfile/tv_channels.m3u（用户提供的国内电视直播源）。
 */
@Component
export struct LiveTvPage {
  // 作为底栏「直播」Tab 嵌入时为 true：隐藏返回按钮。
  @Prop embedded: boolean = false;
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private channels: LiveChannel[] = [];
  @State private groups: string[] = [];
  @State private selectedGroup: string = '全部';
  @State private query: string = '';
  @State private loading: boolean = true;
  @State private errorText: string = '';
  @State private viewportWidth: number = 360;
  private readonly navScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await LiveService.load(context);
      this.channels = LiveService.channels();
      this.groups = ['全部'].concat(LiveService.groups());
      Logger.info('LIVE_TV', '频道列表就绪：' + String(this.channels.length));
    } catch (error) {
      this.errorText = String(error);
      Logger.error('LIVE_TV', '频道列表加载失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private filteredChannels(): LiveChannel[] {
    const keyword: string = this.query.trim().toLowerCase();
    return this.channels.filter((item: LiveChannel) => {
      const groupOk: boolean = this.selectedGroup === '全部' || item.group === this.selectedGroup;
      const queryOk: boolean = keyword.length === 0 || item.name.toLowerCase().indexOf(keyword) >= 0 ||
        item.group.toLowerCase().indexOf(keyword) >= 0;
      return groupOk && queryOk;
    });
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  /** 点频道：把直播源转换成 PlayerPage 的选集串后直接用播放器打开。 */
  private open(item: LiveChannel): void {
    try {
      const options: LivePlayerOptions = new LivePlayerOptions(item);
      if (!options.valid()) {
        Logger.warn('LIVE_TV', '频道没有可用线路：' + item.name);
        return;
      }
      router.pushUrl(options).catch((error: Error) => {
        Logger.error('LIVE_TV', '打开直播播放器失败：' + String(error));
      });
    } catch (error) {
      Logger.error('LIVE_TV', '直播路由异常：' + String(error));
    }
  }

  @Builder
  private header() {
    Row({ space: '10vp' }) {
      if (!this.embedded) {
        GhostButton({ label: '返回', compact: true, onTap: (): void => { router.back(); } })
      }
      Column({ space: '2vp' }) {
        Text('电视直播')
          .fontSize(Ui.fs(this.tablet() ? '25vp' : '22vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
        Text(this.channels.length > 0 ? String(this.channels.length) + ' 个频道 · 多线路备用' : '加载直播源…')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      GhostButton({ label: '刷新', compact: true, onTap: (): void => { void this.load(); } })
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
  private groupBar() {
    Scroll() {
      Row({ space: '8vp' }) {
        ForEach(this.groups, (group: string) => {
          Row() {
            Text(group)
              .fontSize(Ui.fs('12vp', this.fontScale))
              .fontColor(this.selectedGroup === group ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
              .maxLines(1)
          }
            .height('30vp')
            .padding({ left: '12vp', right: '12vp' })
            .borderRadius('15vp')
            .backgroundColor(this.selectedGroup === group ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .border({ width: 1, color: this.selectedGroup === group ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme) })
            .onClick(() => { this.selectedGroup = group; })
        }, (group: string) => 'live-group-' + group)
      }
        .padding({ top: '2vp', bottom: '2vp' })
    }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      .width('100%')
      .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp' })
  }

  @Builder
  private channelCard(item: LiveChannel) {
    Column({ space: '6vp' }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('58vp').height('58vp').borderRadius('16vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
        if (item.logo.length > 0) {
          Image(item.logo)
            .width('50vp').height('50vp')
            .objectFit(ImageFit.Contain)
            .borderRadius('10vp')
        } else {
          Text(item.name.substring(0, 1))
            .fontSize(Ui.fs('22vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(Ui.accentStrong(this.darkTheme))
        }
      }
        .width('58vp').height('58vp')
      Text(item.name)
        .fontSize(Ui.fs('12.5vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(item.group + ' · ' + String(item.sources.length) + ' 线路')
        .fontSize(Ui.fs('9.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
      .width('100%')
      .padding({ top: '9vp', bottom: '9vp', left: '4vp', right: '4vp' })
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
      .onClick(() => { this.open(item); })
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.4 : 0.5 })
      Column() {
        this.header()
        Row() {
          GlassSearchBar({
            query: this.query,
            placeholder: '搜索频道名称或分组',
            showButton: false,
            compact: true,
            onQueryChange: (text: string): void => { this.query = text; },
            onSubmit: (): void => {}
          })
        }
          .width('100%')
          .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp', bottom: '8vp' })
        this.groupBar()
        if (this.loading) {
          Column() {
            LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.darkTheme))
          }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          Column({ space: '12vp' }) {
            EmptyState({ title: '直播源加载失败', hint: this.errorText, icon: SymbolIcons.play() })
            GhostButton({ label: '重试', onTap: (): void => { void this.load(); } })
          }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.filteredChannels().length === 0) {
          Column() {
            EmptyState({ title: '没有匹配的频道', hint: '换一个分组或关键词', icon: SymbolIcons.play() })
          }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.filteredChannels(), (item: LiveChannel) => {
              GridItem() {
                this.channelCard(item)
              }
            }, (item: LiveChannel) => 'live-channel-' + item.name)
          }
            .columnsTemplate(this.tablet() ? '1fr 1fr 1fr 1fr' : '1fr 1fr 1fr')
            .onScrollStart(() => { NavigationScroll.begin('live', 'content', this.navScroller); })
            .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
              NavigationScroll.report('live', 'content', this.navScroller, scrollState);
            })
            .onScrollStop(() => { NavigationScroll.end('live', 'content', this.navScroller); })
            .columnsGap('8vp')
            .rowsGap('8vp')
            .width('100%')
            .layoutWeight(1)
            .padding({ left: this.tablet() ? '24vp' : '16vp', right: this.tablet() ? '24vp' : '16vp', bottom: '20vp' })
            .scrollBar(BarState.Off)
        }
      }
        .width('100%').height('100%')
    }
      .width('100%').height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
        } catch (error) {
          Logger.warn('LIVE_TV', '更新直播列表宽度失败：' + String(error));
        }
      })
  }
}

/**
 * 独立路由入口：main_pages.json 里注册的 LiveTvPage 由这个 @Entry 组件承载，
 * 页面本体是非 @Entry 的 LiveTvPage 组件，因此既能被底栏 Tab 直接嵌入，也能被 router 单独打开。
 */
@Entry
@Component
struct LiveTvPageEntry {
  build() {
    // @Entry 的 build 根节点必须是容器组件，这里用 Column 包一层承载页面本体。
    Column() {
      LiveTvPage().width('100%').height('100%')
    }
      .width('100%')
      .height('100%')
  }
}

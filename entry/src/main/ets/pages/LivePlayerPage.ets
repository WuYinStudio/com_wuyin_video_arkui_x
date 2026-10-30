import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { LiveChannel, LiveService } from '../common/LiveService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';


interface LivePlayerRouteParams {
  name?: string;
}

/**
 * 电视直播播放页。
 * 使用 ArkUI Video 组件直接播放 m3u8；同一频道可切换备用线路。
 */
@Entry
@Component
struct LivePlayerPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  @State private channel: LiveChannel = new LiveChannel();
  @State private sources: string[] = [];
  @State private sourceIndex: number = 0;
  @State private url: string = '';
  @State private hasChannel: boolean = false;
  @State private errorText: string = '';
  @State private showSources: boolean = false;
  @State private loading: boolean = true;
  @State private viewportWidth: number = 360;
  @State private viewportHeight: number = 780;

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      let name: string = '';
      const params = router.getParams() as LivePlayerRouteParams | undefined;
      if (params && typeof params.name === 'string') {
        name = params.name.trim();
      }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await LiveService.load(context);
      const found: LiveChannel | undefined = LiveService.channel(name);
      if (found === undefined) {
        this.errorText = '频道不存在或直播源已更新';
        this.hasChannel = false;
        return;
      }
      this.channel = found;
      this.sources = found.sources.slice();
      this.hasChannel = true;
      this.sourceIndex = 0;
      this.url = this.sources.length > 0 ? this.sources[0] : '';
      this.errorText = this.url.length > 0 ? '' : '该频道没有可用线路';
      Logger.info('LIVE_PLAYER', '开始播放频道：' + name + '，线路=' + String(this.sources.length));
    } catch (error) {
      this.errorText = String(error);
      this.hasChannel = false;
      Logger.error('LIVE_PLAYER', '直播播放页加载失败：' + String(error));
    } finally {
      this.loading = false;
    }
  }

  private selectSource(index: number): void {
    if (index < 0 || index >= this.sources.length) {
      return;
    }
    this.sourceIndex = index;
    this.errorText = '';
    const next: string = this.sources[index];
    // 先清空再挂载，强制 Video 重新加载新的 m3u8 地址。
    this.url = '';
    setTimeout(() => {
      this.url = next;
    }, 40);
    this.showSources = false;
    Logger.info('LIVE_PLAYER', '切换直播线路：' + String(index + 1));
  }

  private safeTop(): number {
    return Number.isFinite(this.topSafeInset) ? Math.max(0, this.topSafeInset) : 24;
  }

  private tablet(): boolean {
    return this.viewportWidth >= 600;
  }

  @Builder
  private whiteButton(label: string, action: () => void) {
    Text(label)
      .fontSize(Ui.fs('11.5vp', this.fontScale))
      .fontColor('#FFFFFF')
      .height('30vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('15vp')
      .backgroundColor('#33FFFFFF')
      .onClick(action)
  }

  @Builder
  private topBar() {
    Row({ space: '10vp' }) {
      this.whiteButton('返回', (): void => { router.back(); })
      Column({ space: '2vp' }) {
        Text(this.hasChannel ? this.channel.name : '电视直播')
          .fontSize(Ui.fs(this.tablet() ? '19vp' : '16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('线路 ' + String(this.sourceIndex + 1) + '/' + String(this.sources.length) + ' · ' +
          (this.hasChannel ? this.channel.group : ''))
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor('#CCFFFFFF')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      this.whiteButton('换线路', (): void => { this.showSources = true; })
    }
      .width('100%')
      .padding({
        left: this.tablet() ? '24vp' : '12vp',
        right: this.tablet() ? '24vp' : '12vp',
        top: (this.safeTop() + 6) + 'vp',
        bottom: '6vp'
      })
      .backgroundColor('#66000000')
  }

  @Builder
  private sourcePanel() {
    if (this.showSources) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height('100%').backgroundColor('#99000000')
          .onClick(() => { this.showSources = false; })
        Column({ space: '6vp' }) {
          Text('切换直播线路')
            .fontSize(Ui.fs('17vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width('100%')
          List({ space: '4vp' }) {
            ForEach(this.sources, (item: string, index: number) => {
              ListItem() {
                Row({ space: '8vp' }) {
                  Text('线路 ' + String(index + 1))
                    .fontSize(Ui.fs('13vp', this.fontScale))
                    .fontColor(index === this.sourceIndex ? Ui.accentStrong(this.darkTheme) : '#FFFFFF')
                    .layoutWeight(1)
                  if (index === this.sourceIndex) {
                    Text('当前')
                      .fontSize(Ui.fs('10.5vp', this.fontScale))
                      .fontColor('#FFFFFF')
                  }
                }
                  .width('100%')
                  .height('42vp')
                  .padding({ left: '12vp', right: '12vp' })
                  .borderRadius('10vp')
                  .backgroundColor(index === this.sourceIndex ? '#33FFFFFF' : '#1AFFFFFF')
                  .onClick(() => { this.selectSource(index); })
              }
            }, (item: string, index: number) => 'live-source-' + String(index))
          }
            .width('100%')
            .height('300vp')
        }
          .padding('14vp')
          .borderRadius({ topLeft: '22vp', topRight: '22vp' })
          .backgroundColor('#EE111111')
      }
        .width('100%').height('100%').zIndex(5)
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
      if (this.url.length > 0) {
        Video({ src: this.url })
          .width('100%')
          .height('100%')
          .autoPlay(true)
          .controls(true)
          .loop(false)
          .objectFit(ImageFit.Contain)
          .onError(() => {
            this.errorText = '线路 ' + String(this.sourceIndex + 1) + ' 播放失败，请切换线路';
            Logger.warn('LIVE_PLAYER', '直播线路播放失败：' + this.url);
          })
      }
      if (this.loading) {
        Column() {
          LoadingProgress().width('32vp').height('32vp').color('#FFFFFF')
        }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorText.length > 0) {
        Column({ space: '12vp' }) {
          Text(this.errorText)
            .fontSize(Ui.fs('14vp', this.fontScale))
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .maxLines(3)
          if (this.sources.length > 1) {
            this.whiteButton('切换线路', (): void => { this.showSources = true; })
          }
        }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .padding('24vp')
      }
      this.topBar()
      this.sourcePanel()
    }
      .width('100%').height('100%')
      .backgroundColor('#000000')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const measuredWidth: number = Number(newValue.width);
          const measuredHeight: number = Number(newValue.height);
          if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
            this.viewportWidth = measuredWidth;
          }
          if (Number.isFinite(measuredHeight) && measuredHeight > 0) {
            this.viewportHeight = measuredHeight;
          }
        } catch (error) {
          Logger.warn('LIVE_PLAYER', '更新直播播放页尺寸失败：' + String(error));
        }
      })
  }
}

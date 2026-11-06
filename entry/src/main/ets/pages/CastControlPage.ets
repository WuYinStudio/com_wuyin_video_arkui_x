import { router } from '@kit.ArkUI';
import { CastDevice, CastPosition, CastService } from '../common/CastService';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';
import { AuroraBackdrop } from '../common/UiWidgets';

/** 进入投屏控制页时携带的参数。 */
export interface CastControlParams {
  deviceJson: string;
  title: string;
  url: string;
  episodesJson?: string;
  episodeIndex?: string;
}

/** 选集条目（投屏控制页切换集数用）。 */
export interface CastEpisode {
  title: string;
  url: string;
}

/**
 * 手机端投屏控制台。
 *
 * 投屏成功后从播放页跳到这里：暂停/继续/停止/音量/进度/选集都通过 DLNA 直接发给电视，
 * 手机可以退出播放页继续当遥控器用。
 */
@Entry
@Component
struct CastControlPage {
  @State private deviceName: string = '';
  @State private title: string = '';
  @State private connected: boolean = false;
  @State private volume: number = 50;
  @State private paused: boolean = false;
  @State private status: string = '已连接，可直接遥控电视';
  @State private episodes: CastEpisode[] = [];
  @State private episodeIndex: number = 0;
  @State private positionSec: number = 0;
  @State private durationSec: number = 0;
  @State private darkTheme: boolean = true;
  @StorageLink('fontScale') private fontScale: number = 1;
  private device: CastDevice | undefined = undefined;
  private service: CastService = new CastService();
  private url: string = '';
  private posTimer: number = -1;
  private switching: boolean = false;

  aboutToAppear(): void {
    try {
      const params = router.getParams() as Record<string, string>;
      const json: string = params !== undefined && typeof params['deviceJson'] === 'string' ? params['deviceJson'] : '';
      this.title = params !== undefined && typeof params['title'] === 'string' ? params['title'] : '';
      this.url = params !== undefined && typeof params['url'] === 'string' ? params['url'] : '';
      const episodesJson: string = params !== undefined && typeof params['episodesJson'] === 'string' ? params['episodesJson'] : '';
      const indexText: string = params !== undefined && typeof params['episodeIndex'] === 'string' ? params['episodeIndex'] : '0';
      if (episodesJson.length > 0) {
        try {
          this.episodes = JSON.parse(episodesJson) as CastEpisode[];
          this.episodeIndex = Math.max(0, Number(indexText) || 0);
        } catch (error) {
          Logger.warn('CAST_CONTROL', '解析选集失败：' + String(error));
        }
      }
      if (json.length > 0) {
        this.device = JSON.parse(json) as CastDevice;
        this.deviceName = this.device.name || '投屏设备';
        this.connected = true;
      }
      Logger.info('CAST_CONTROL', '进入投屏控制页：' + this.deviceName);
      this.startPolling();
    } catch (error) {
      Logger.warn('CAST_CONTROL', '读取投屏参数失败：' + String(error));
      this.status = '投屏参数异常，请重新投屏';
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.service.close();
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    void router.pushUrl({ url: 'pages/Index' });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (_) {
      Logger.warn('CAST_CONTROL', 'toast 失败');
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.refreshPosition();
    this.posTimer = setInterval(() => {
      this.refreshPosition();
    }, 3000);
  }

  private stopPolling(): void {
    if (this.posTimer !== -1) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
  }

  /** 读取电视上报的进度；部分设备不支持，失败只记日志。 */
  private refreshPosition(): void {
    const device: CastDevice | undefined = this.device;
    if (device === undefined || this.connected === false) {
      return;
    }
    this.service.position(device).then((pos: CastPosition) => {
      this.positionSec = pos.position;
      this.durationSec = pos.duration;
    }).catch((error: Error) => {
      Logger.debug('CAST_CONTROL', '读取进度失败：' + String(error));
    });
  }

  private formatTime(seconds: number): string {
    const total: number = Math.max(0, Math.floor(seconds));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = (m < 10 ? '0' : '') + String(m);
    const ss: string = (s < 10 ? '0' : '') + String(s);
    return h > 0 ? String(h) + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  private async send(action: string, body: string, tip: string): Promise<void> {
    const device: CastDevice | undefined = this.device;
    if (device === undefined) {
      this.toast('投屏设备已断开');
      return;
    }
    try {
      await this.service.command(device, action, body);
      this.status = tip;
      this.toast(tip);
    } catch (error) {
      this.status = '操作失败：' + String(error);
      this.toast('操作失败：' + String(error));
      Logger.warn('CAST_CONTROL', action + ' 失败：' + String(error));
    }
  }

  private togglePause(): void {
    if (this.paused) {
      this.paused = false;
      void this.send('Play', '<Speed>1</Speed>', '已继续播放');
    } else {
      this.paused = true;
      void this.send('Pause', '<Speed>1</Speed>', '已暂停');
    }
  }

  private stopCast(): void {
    void this.send('Stop', '', '已停止投屏');
    this.connected = false;
    this.paused = false;
  }

  /** 切换到某一集：重新下发 SetAVTransportURI 再 Play。 */
  private async switchEpisode(index: number): Promise<void> {
    const device: CastDevice | undefined = this.device;
    if (device === undefined) {
      this.toast('投屏设备已断开');
      return;
    }
    const episode: CastEpisode | undefined = this.episodes[index];
    if (episode === undefined || episode.url.trim().length === 0) {
      this.toast('该集没有可投屏地址');
      return;
    }
    if (this.switching) {
      return;
    }
    this.switching = true;
    try {
      const metadata: string = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>' +
        CastService.escape(this.title + ' · ' + episode.title) + '</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/*:*">' +
        CastService.escape(episode.url) + '</res></item></DIDL-Lite>';
      await this.service.command(device, 'SetAVTransportURI',
        '<CurrentURI>' + CastService.escape(episode.url) + '</CurrentURI><CurrentURIMetaData>' + metadata + '</CurrentURIMetaData>');
      await this.service.command(device, 'Play', '<Speed>1</Speed>');
      this.episodeIndex = index;
      this.paused = false;
      this.positionSec = 0;
      this.status = '已切换到 ' + episode.title;
    } catch (error) {
      this.toast('切换失败：' + String(error));
      Logger.warn('CAST_CONTROL', '切换集数失败：' + String(error));
    } finally {
      this.switching = false;
    }
  }

  /** 音量：RenderingControl.SetVolume，步进 10。 */
  private async changeVolume(delta: number): Promise<void> {
    const device: CastDevice | undefined = this.device;
    if (device === undefined) {
      return;
    }
    const next: number = Math.max(0, Math.min(100, this.volume + delta));
    try {
      await this.service.commandRendering(device, 'SetVolume',
        '<Channel>Master</Channel><DesiredVolume>' + String(next) + '</DesiredVolume>');
      this.volume = next;
      this.status = '音量 ' + String(next) + '%';
    } catch (error) {
      this.toast('调音量失败：' + String(error));
    }
  }

  /** 按秒跳转：Seek REL_TIME（设备需支持）。 */
  private async seekToSecond(seconds: number): Promise<void> {
    const device: CastDevice | undefined = this.device;
    if (device === undefined) {
      return;
    }
    if (this.durationSec <= 0) {
      this.toast('设备未上报时长，暂不支持拖动');
      return;
    }
    const target: number = Math.max(0, Math.min(this.durationSec, Math.floor(seconds)));
    const hh: string = ('0' + String(Math.floor(target / 3600))).slice(-2);
    const mm: string = ('0' + String(Math.floor((target % 3600) / 60))).slice(-2);
    const ss: string = ('0' + String(target % 60)).slice(-2);
    const hms: string = hh + ':' + mm + ':' + ss;
    try {
      await this.service.command(device, 'Seek', '<Unit>REL_TIME</Unit><Target>' + hms + '</Target>');
      this.positionSec = target;
      this.status = '已跳转到 ' + this.formatTime(target);
    } catch (error) {
      this.toast('跳转失败：' + String(error));
    }
  }

  @Builder
  private actionButton(label: string, danger: boolean, onTap: () => void) {
    Text(label)
      .fontSize(Ui.fs('14vp', this.fontScale))
      .fontColor(danger ? '#FF6B6B' : Ui.ink(this.darkTheme))
      .height('46vp')
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius('16vp')
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
      .onClick(onTap)
  }

  build() {
    Stack() {
      // 与其它页面一致的全局背景层（主题渐变 / 本地导入背景），保持全应用视觉统一。
      Column().width('100%').height('100%').backgroundColor(Ui.pageBg(this.darkTheme))
      AuroraBackdrop({ intensity: this.darkTheme ? 0.42 : 0.52 })
      Column({ space: '12vp' }) {
      Row({ space: '10vp' }) {
        Text('‹')
          .fontSize(Ui.fs('22vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .width('34vp')
          .height('34vp')
          .textAlign(TextAlign.Center)
          .borderRadius('17vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .onClick(() => {
            this.goBack();
          })
        Column({ space: '2vp' }) {
          Text('投屏遥控')
            .fontSize(Ui.fs('18vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
          Text(this.connected ? ('已连接：' + this.deviceName) : '未连接设备')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)

      Column({ space: '6vp' }) {
        Text(this.title.length > 0 ? this.title : '正在投屏的影片')
          .fontSize(Ui.fs('14.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.status)
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
          .maxLines(2)
      }
        .width('100%')
        .padding('14vp')
        .borderRadius('16vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .alignItems(HorizontalAlign.Start)

      if (this.episodes.length > 1) {
        Column({ space: '8vp' }) {
          Text('选集（共 ' + String(this.episodes.length) + ' 集）')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Scroll() {
            Row({ space: '8vp' }) {
              ForEach(this.episodes, (episode: CastEpisode, index: number) => {
                Text(episode.title)
                  .fontSize(Ui.fs('12vp', this.fontScale))
                  .fontColor(this.episodeIndex === index ? Ui.accentStrong(this.darkTheme) : Ui.ink(this.darkTheme))
                  .height('30vp')
                  .padding({ left: '12vp', right: '12vp' })
                  .borderRadius('15vp')
                  .backgroundColor(this.episodeIndex === index ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
                  .maxLines(1)
                  .onClick(() => {
                    void this.switchEpisode(index);
                  })
              }, (episode: CastEpisode, index: number) => 'cast-ep-' + String(index))
            }
          }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
        }
          .width('100%')
          .padding('14vp')
          .borderRadius('16vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .alignItems(HorizontalAlign.Start)
      }

      Row({ space: '10vp' }) {
        this.actionButton(this.paused ? '继续' : '暂停', false, (): void => {
          this.togglePause();
        })
        this.actionButton('停止', true, (): void => {
          this.stopCast();
        })
      }
        .width('100%')

      Column({ space: '8vp' }) {
        Row() {
          Text('电视音量')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(String(this.volume) + '%')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('100%')
        Row({ space: '10vp' }) {
          this.actionButton('音量 -', false, (): void => {
            void this.changeVolume(-10);
          })
          this.actionButton('音量 +', false, (): void => {
            void this.changeVolume(10);
          })
        }
          .width('100%')
      }
        .width('100%')
        .padding('14vp')
        .borderRadius('16vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .alignItems(HorizontalAlign.Start)

      Column({ space: '8vp' }) {
        Row() {
          Text('进度')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text(this.formatTime(this.positionSec) + ' / ' +
            (this.durationSec > 0 ? this.formatTime(this.durationSec) : '未知'))
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
        }
          .width('100%')
        Slider({
          value: this.positionSec,
          min: 0,
          max: this.durationSec > 0 ? this.durationSec : 1,
          step: 1
        })
          .width('100%')
          .selectedColor(Ui.accent(this.darkTheme))
          .trackColor(Ui.glassRingSoft(this.darkTheme))
          .blockColor(Ui.accent(this.darkTheme))
          .enabled(this.durationSec > 0)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.positionSec = value;
            if (mode === SliderChangeMode.End) {
              void this.seekToSecond(value);
            }
          })
        Row({ space: '10vp' }) {
          this.actionButton('后退 30s', false, (): void => {
            void this.seekToSecond(this.positionSec - 30);
          })
          this.actionButton('前进 30s', false, (): void => {
            void this.seekToSecond(this.positionSec + 30);
          })
        }
          .width('100%')
      }
        .width('100%')
        .padding('14vp')
        .borderRadius('16vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .alignItems(HorizontalAlign.Start)

      Blank()

      Text('断开投屏')
        .fontSize(Ui.fs('13.5vp', this.fontScale))
        .fontColor('#FF6B6B')
        .height('46vp')
        .width('100%')
        .textAlign(TextAlign.Center)
        .borderRadius('16vp')
        .backgroundColor(Ui.glassTintSoft(this.darkTheme))
        .onClick(() => {
          void this.send('Stop', '', '已断开投屏');
          this.connected = false;
          this.goBack();
        })
    }
      .width('100%')
      .height('100%')
      .padding({ left: '16vp', right: '16vp', top: '12vp', bottom: '20vp' })
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.darkTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}


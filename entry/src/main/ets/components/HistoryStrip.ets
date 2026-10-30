import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from '../common/Logger';
import { AppState, WatchRecord } from '../common/AppState';
import { SearchVideoItem } from '../pages/PlayerPage';
import { Ui } from '../common/Ui';
import { GhostButton } from '../common/UiWidgets';

/**
 * 观影记录横条：本地播放历史（AppState.history）。
 * 首页与「我的」共用；横向滚动，点击续播，右上角「查看全部」。
 */
class StripResume {
  vodId: string = '';
  selectIndex: number = 0;
  playSec: number = 0;
  videoName: string = '';
}

@Component
export struct HistoryStrip {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('historyVersion') @Watch('onHistoryChanged') private historyVersion: number = 0;
  @State private records: WatchRecord[] = [];
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.refresh();
  }

  private onHistoryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    try {
      const all: WatchRecord[] = AppState.history.slice();
      all.sort((first: WatchRecord, second: WatchRecord) => second.id - first.id);
      this.records = all.slice(0, 12);
    } catch (error) {
      Logger.warn('HISTORY_STRIP', '读取播放历史失败：' + String(error));
    }
  }

  private progressText(record: WatchRecord): string {
    const total: number = record.duration > 0 ? record.duration : 0;
    if (total <= 0) { return '第 ' + String(record.episode) + ' 集'; }
    const percent: number = Math.max(1, Math.min(100, Math.round(record.position * 100 / total)));
    return '第 ' + String(record.episode) + ' 集 · ' + String(percent) + '%';
  }

  /** 交给宿主切换到「观看历史」页（PlayHistoryPage 是内嵌组件，不能路由跳转）。 */
  /** 单卡：直接续播（写播放进度后跳播放器）。 */
  private async resumeRecord(record: WatchRecord): Promise<void> {
    if (record.vodId.length === 0 || record.wzlj.length === 0) {
      this.openAll();
      return;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, 'player_watch_history');
      const resume: StripResume = new StripResume();
      resume.vodId = record.vodId;
      resume.selectIndex = Math.max(0, Math.floor(record.episode) - 1);
      resume.playSec = Math.max(0, record.position);
      resume.videoName = record.name;
      await store.put('vod_' + record.vodId, JSON.stringify(resume));
      await store.flush();
      const params: SearchVideoItem = { vodId: record.vodId, yhm: record.name, tilie: record.name,
        feng: record.cover, sfeng: '', data: '', wzlj: record.wzlj, genxi: '', zyuanuuu: '' };
      await router.pushUrl({ url: 'pages/PlayerPage', params: params });
    } catch (error) {
      Logger.warn('HISTORY_STRIP', '续播失败：' + String(error));
      this.openAll();
    }
  }

  private openAll(): void {
    try {
      AppState.go('history');
    } catch (error) {
      Logger.warn('HISTORY_STRIP', '打开播放历史失败：' + String(error));
    }
  }

  build() {
    Column({ space: '8vp' }) {
      Row() {
        Text('观影记录')
          .fontSize(Ui.fs('16vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
        GhostButton({ label: '查看全部', compact: true, onTap: (): void => { this.openAll(); } })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      if (this.records.length === 0) {
        Row({ space: '10vp' }) {
          Column() {
            Text('▶')
              .fontSize(Ui.fs('14vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
          }
            .width('44vp')
            .height('44vp')
            .borderRadius('12vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          Text('暂无观看记录，开始观看后会显示在这里')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .layoutWeight(1)
            .maxLines(2)
        }
          .width('100%')
          .padding('12vp')
          .borderRadius('14vp')
          .backgroundColor(Ui.glassTintSoft(this.darkTheme))
          .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) })
          .alignItems(VerticalAlign.Center)
      } else {
        List({ space: '10vp', scroller: this.scroller }) {
          ForEach(this.records, (record: WatchRecord) => {
            ListItem() {
              Column({ space: '4vp' }) {
                if (record.cover.length > 0) {
                  Image(record.cover)
                    .width('92vp')
                    .height('124vp')
                    .borderRadius('10vp')
                    .objectFit(ImageFit.Cover)
                } else {
                  Column()
                    .width('92vp')
                    .height('124vp')
                    .borderRadius('10vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                }
                Text(record.name.length > 0 ? record.name : '未命名')
                  .fontSize(Ui.fs('11vp', this.fontScale))
                  .fontColor(Ui.ink(this.darkTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('92vp')
                Text(this.progressText(record))
                  .fontSize(Ui.fs('9.5vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.darkTheme))
                  .maxLines(1)
                  .width('92vp')
              }
                .width('92vp')
                .alignItems(HorizontalAlign.Start)
                .onClick(() => { void this.resumeRecord(record); })
            }
          }, (record: WatchRecord) => 'hs-' + String(record.id))
        }
          .width('100%')
          .height('166vp')
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }
}

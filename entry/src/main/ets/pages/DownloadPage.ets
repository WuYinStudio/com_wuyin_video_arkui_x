import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { DownloadOptions, DownloadRecord, DownloadService, DownloadState } from '../common/DownloadService';
import { LocalPlaybackService } from '../common/LocalPlaybackService';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GlassIconButton } from '../common/UiWidgets';
import { SearchVideoItem } from './PlayerPage';
import { SymbolIcons } from '../common/SymbolIcons';

interface DownloadPlaybackParams extends SearchVideoItem {
  resourceType: 'local';
  localPath: string;
}

// 独立列表和 ManagePage 内嵌列表观察同一服务，不维护页面私有的任务状态。
/**
 * 下载管理（文件管理页内嵌子页之一）。
 *
 * 视觉：工具条改成一条玻璃胶囊条（批量操作 + 导入导出），任务卡是玻璃卡片 ——
 *      16:9 封面（14vp 圆角）+ 名称 + 集数 + 状态胶囊 + 主色渐变进度条 + 速度/百分比，
 *      底部操作为小胶囊（暂停/继续/重试/播放/删除），危险操作使用 danger 色。
 * 行为：DownloadService 的全部调用、状态判断、导入导出、错误提示与滚动上报保持不变。
 */
@Component
export struct DownloadPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop embedded: boolean = false;
  @StorageLink('immersiveConfig') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('downloadVersion') @Watch('downloadsChanged') private downloadVersion: number = 0;
  @StorageLink('downloadOptions') private downloadOptions: DownloadOptions = new DownloadOptions();
  @State private records: DownloadRecord[] = [];
  @State private loading: boolean = true;
  @State private busy: boolean = false;
  @State private loadMessage: string = '';
  @State private viewportSize: number = 360;
  // 仅用于卡片按下反馈（scale 0.97），不参与任何下载状态判断。
  @State private pressedId: string = '';
  private disposed: boolean = false;
  // 播放入口单独防重入，不改变下载工具栏、卡片或任务按钮的可视状态。
  private openingPlayback: boolean = false;
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.disposed = false;
    this.pressedId = '';
    Logger.info('DOWNLOAD_PAGE', '进入下载管理');
    this.refresh();
    void this.initialize();
  }
  aboutToDisappear(): void { this.disposed = true; this.pressedId = ''; }

  private scrollRoute(): string { return this.embedded ? 'manage' : 'download'; }

  private async initialize(): Promise<void> {
    this.loading = true;
    this.loadMessage = '';
    try {
      await DownloadService.init(this.context());
      if (this.disposed) { return; }
      this.refresh();
      Logger.info('DOWNLOAD_PAGE', '下载列表加载完成，数量=' + this.records.length);
    } catch (error) {
      if (!this.disposed) { this.loadMessage = '下载列表加载失败，请点击重新加载'; }
      Logger.error('DOWNLOAD_PAGE', String(error));
    } finally { if (!this.disposed) { this.loading = false; } }
  }

  private downloadsChanged(): void { this.refresh(); }
  private refresh(): void { if (!this.disposed) { this.records = DownloadService.snapshot(); } }
  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }
  private toast(message: string): void {
    if (this.disposed) { return; }
    try { this.getUIContext().getPromptAction().showToast({ message: message }); }
    catch (error) { Logger.warn('DOWNLOAD_PAGE', '显示提示失败：' + String(error)); }
  }
  // ---------- 设计令牌（深浅模式统一由 Ui 决定，页面内不再出现写死的十六进制色） ----------
  private ink(): string { return Ui.ink(this.darkTheme); }
  private secondary(): string { return Ui.inkSoft(this.darkTheme); }
  private accent(): string { return Ui.accent(this.darkTheme); }
  private selection(): string { return Ui.accentSoft(this.darkTheme); }
  private dangerInk(): string { return Ui.danger(this.darkTheme); }
  private dangerSurface(): string { return Ui.glassTintSoft(this.darkTheme); }
  private panel(): string { return Ui.glassTintSoft(this.darkTheme); }
  private coverSize(): number { return Math.min(144, Math.max(64, (this.viewportSize - 64) * 0.3)); }
  private stateLabel(record: DownloadRecord): string {
    switch (record.state) {
      case DownloadState.SNIFFING: return '正在嗅探视频地址';
      case DownloadState.RUNNING: return '正在下载';
      case DownloadState.QUEUED: return '等待网络或空闲队列';
      case DownloadState.PAUSED: return '已暂停';
      case DownloadState.COMPLETED: return '已完成 · 点击播放';
      case DownloadState.FAILED: return '下载失败';
      default: return '等待下载';
    }
  }
  /** 卡片右上角状态胶囊的短标签（长文案仍由上方的 stateLabel 展示）。 */
  private stateChip(record: DownloadRecord): string {
    switch (record.state) {
      case DownloadState.SNIFFING: return '嗅探中';
      case DownloadState.RUNNING: return '进行中';
      case DownloadState.QUEUED: return '排队中';
      case DownloadState.PAUSED: return '已暂停';
      case DownloadState.COMPLETED: return '已完成';
      case DownloadState.FAILED: return '失败';
      default: return '等待中';
    }
  }
  private stateTone(record: DownloadRecord): string {
    if (record.state === DownloadState.COMPLETED) { return Ui.success(this.darkTheme); }
    if (record.state === DownloadState.FAILED) { return this.dangerInk(); }
    return this.accent();
  }
  private bytes(value: number): string {
    if (!Number.isFinite(value) || value <= 0) { return '0 B'; }
    if (value < 1024) { return Math.floor(value) + ' B'; }
    if (value < 1024 * 1024) { return (value / 1024).toFixed(1) + ' KB'; }
    if (value < 1024 * 1024 * 1024) { return (value / (1024 * 1024)).toFixed(1) + ' MB'; }
    return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }
  private percent(record: DownloadRecord): number {
    if (record.state === DownloadState.COMPLETED) { return 100; }
    const progress: number = record.state === DownloadState.SNIFFING ? record.sniffProgress : record.progressPercent;
    return Number.isFinite(progress) ? Math.max(0, Math.min(100, progress)) : 0;
  }
  /** 渐变进度条宽度（百分比字符串），只在普通方法里计算，不在 build 内声明变量。 */
  private barWidth(record: DownloadRecord): string {
    return Math.max(0, Math.min(100, Math.round(this.percent(record)))) + '%';
  }
  private sizeLabel(record: DownloadRecord): string {
    if (record.state === DownloadState.SNIFFING) { return '嗅探进度 ' + this.percent(record).toFixed(0) + '%'; }
    return this.bytes(record.receivedBytes) + ' / ' + (record.totalBytes > 0 ? this.bytes(record.totalBytes) : '总大小待确认');
  }
  private active(record: DownloadRecord): boolean {
    return record.state === DownloadState.SNIFFING || record.state === DownloadState.RUNNING || record.state === DownloadState.QUEUED;
  }
  private rulesLabel(): string {
    return (this.downloadOptions.wifiOnly ? '仅 WLAN' : '允许移动网络') + ' · 最多 ' + this.downloadOptions.parallelLimit + ' 个并行任务';
  }
  /** 卡片上的操作按钮统一走这里，业务分支仍是原来的 pause / resume / remove / open。 */
  private performCardAction(action: string, record: DownloadRecord): void {
    if (action === 'play') { void this.open(record); return; }
    void this.operate(action, record.id);
  }

  private async operate(action: string, id: string = ''): Promise<void> {
    if (this.busy || this.disposed) { return; }
    this.busy = true;
    try {
      Logger.info('DOWNLOAD_PAGE', '执行下载操作：' + action + (id ? '，任务=' + id : ''));
      if (action === 'pause') { await DownloadService.pause(id); }
      else if (action === 'resume') { await DownloadService.resume(id); }
      else if (action === 'pauseAll') { await DownloadService.pauseAll(); }
      else if (action === 'resumeAll') { await DownloadService.resumeAll(); }
      else if (action === 'retryAll') { await DownloadService.retryAll(); }
      else if (action === 'remove' || action === 'removeAll') {
        const result = await this.getUIContext().getPromptAction().showDialog({
          title: action === 'removeAll' ? '删除全部下载任务？' : '删除此下载任务？',
            message: '任务记录及对应本地视频将被删除，此操作无法撤销。',
            buttons: [{ text: '取消', color: this.secondary() }, { text: '删除', color: this.dangerInk() }]
        });
        if (result.index !== 1 || this.disposed) {
          Logger.debug('DOWNLOAD_PAGE', '取消删除下载任务');
          return;
        }
        if (action === 'removeAll') { await DownloadService.removeAll(); }
        else { await DownloadService.remove(id); }
      }
      this.refresh();
    } catch (error) {
      Logger.error('DOWNLOAD_PAGE', '下载操作失败：' + String(error));
      this.toast('操作失败，请检查网络或文件权限后重试');
    } finally { if (!this.disposed) { this.busy = false; } }
  }

  private async exportRecords(): Promise<void> {
    if (this.busy || this.disposed) { return; }
    this.busy = true;
    try {
      Logger.info('DOWNLOAD_PAGE', '开始导出下载任务');
      if (await DownloadService.exportFile(this.context())) { this.toast('下载任务已导出，不包含视频文件'); }
      else { Logger.debug('DOWNLOAD_PAGE', '用户取消导出下载任务'); }
    } catch (error) {
      Logger.error('DOWNLOAD_PAGE', '导出失败：' + String(error));
      this.toast('导出失败，请检查文件权限');
    } finally { if (!this.disposed) { this.busy = false; } }
  }

  private async importRecords(): Promise<void> {
    if (this.busy || this.disposed) { return; }
    this.busy = true;
    try {
      Logger.info('DOWNLOAD_PAGE', '开始导入下载任务');
      const incoming: DownloadRecord[] | undefined = await DownloadService.readImport(this.context());
      if (!incoming || this.disposed) { Logger.debug('DOWNLOAD_PAGE', '取消选择下载任务文件'); return; }
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '导入下载任务',
          message: '读取到 ' + incoming.length + ' 个任务。导入仅恢复任务资料，不包含视频文件；导入后可手动继续下载。覆盖不会删除旧视频文件。',
          buttons: [{ text: '取消', color: this.secondary() }, { text: '合并', color: this.accent() }, { text: '覆盖', color: this.dangerInk() }]
      });
      if (this.disposed) { return; }
      if (result.index === 1 || result.index === 2) {
        await DownloadService.importRecords(incoming, result.index === 2);
        this.refresh();
        this.toast('下载任务导入完成');
        Logger.info('DOWNLOAD_PAGE', (result.index === 2 ? '覆盖' : '合并') + '导入下载任务完成');
      } else { Logger.debug('DOWNLOAD_PAGE', '用户取消导入下载任务'); }
    } catch (error) {
      Logger.error('DOWNLOAD_PAGE', '导入失败：' + String(error));
      this.toast('导入失败，请检查文件格式和权限');
    } finally { if (!this.disposed) { this.busy = false; } }
  }

  private checkedPlaybackPath(record: DownloadRecord): string {
    // 与播放器共用本地路径规则，不把网络地址作为本地播放失败后的回退源。
    const storedPath: string = typeof record.localPath === 'string' ? record.localPath.trim() : '';
    if (!storedPath) { throw new Error('本地视频路径缺失，请重新下载'); }
    const localPath: string = LocalPlaybackService.checkedPath(storedPath, this.context());
    // 共享入口不仅检查文件存在和大小，还实际读取一个字节验证可读性；
    // 文件 API 的 401 错误由服务保留原始错误码，不触发远程鉴权或网络回退。
    const readable: fileIo.File = LocalPlaybackService.openFile(localPath, this.context());
    try {
      const fileSize: number = LocalPlaybackService.checkedSize(localPath);
      Logger.info('DOWNLOAD_PAGE', '本地文件校验通过，资源类型=local，路径=' + localPath + '，文件大小=' + fileSize);
    } finally {
      try { fileIo.closeSync(readable); }
      catch (error) {
        Logger.warn('DOWNLOAD_PAGE', '关闭本地校验句柄失败，资源类型=local，路径=' + localPath + '：' + String(error));
      }
    }
    return localPath;
  }

  private localPlaylistAddress(localPath: string): string {
    return 'file://' + localPath.split('/').map((segment: string): string => encodeURIComponent(segment)).join('/');
  }

  private playbackLogPath(storedPath: string): string {
    // 非本地记录仍会被文件校验拒绝；异常地址不输出远程查询参数及用户凭据。
    if (/^https?:\/\//i.test(storedPath)) {
      return storedPath.split(/[?#]/)[0].replace(/^(https?:\/\/)[^/@]+@/i, '$1');
    }
    return storedPath;
  }

  private async open(record: DownloadRecord): Promise<void> {
    if (record.state !== DownloadState.COMPLETED || this.disposed || this.openingPlayback) { return; }
    this.openingPlayback = true;
    let playbackPath: string = '';
    try {
      playbackPath = this.playbackLogPath(typeof record.localPath === 'string' ? record.localPath.trim() : '');
      const localPath: string = this.checkedPlaybackPath(record);
      playbackPath = localPath;
      Logger.info('DOWNLOAD_PAGE', '打开视频，资源类型=local，路径=' + localPath + '，任务=' + record.id);
      // 编码播放列表路径，防止文件名中的分隔符或连续空格破坏集数解析；
      // localPath 独立携带原始路径，播放器以 resourceType=local 选择离线分支。
      const playlistAddress: string = this.localPlaylistAddress(localPath);
      const playlistTitle: string = (record.episodeTitle || '本地视频').replace(/[$#\t\r\n]/g, ' ').trim() || '本地视频';
      const params: DownloadPlaybackParams = {
        vodId: 'local_' + record.id, yhm: record.name, tilie: record.name,
          feng: record.cover, sfeng: '', data: '',
          wzlj: playlistTitle + '$' + playlistAddress,
          genxi: '', zyuanuuu: '', resourceType: 'local', localPath: localPath
      };
      if (this.disposed) { return; }
      Logger.info('DOWNLOAD_PAGE', '跳转离线播放，资源类型=' + params.resourceType + '，路径=' + localPath + '，不发起远程鉴权请求');
      await router.pushUrl({ url: 'pages/PlayerPage', params: params });
    } catch (error) {
      const caught: BusinessError = error as BusinessError;
      const details: string = caught.message || String(error);
      const error401: boolean = caught.code === 401 || /\b401\b/.test(details);
      Logger.error('DOWNLOAD_PAGE', '打开本地视频失败，资源类型=local，路径=' + playbackPath +
      (typeof caught.code === 'number' ? '，错误码=' + caught.code : '') +
      (error401 ? '，401异常，本地资源不使用远程鉴权' : '') + '：' + details);
      this.toast(error401 ? '本地文件无法读取（错误码401），请检查下载文件或重新下载' :
        (/^(本地|离线|当前离线)/.test(details) ? details : '本地视频播放失败，请检查文件是否可读取或重新下载'));
    } finally {
      // 路由或校验失败后也允许再次播放，不让异步跳转锁遗留到下一次点击。
      this.openingPlayback = false;
    }
  }

  /** 工具条 / 卡片操作共用的玻璃胶囊按钮（危险操作转 danger 色）。 */
  @Builder
  private toolbarButton(label: string, action: string) {
    Button(label).fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '14vp', right: '14vp' })
      .fontColor(action === 'removeAll' ? this.dangerInk() : this.accent())
      .backgroundColor(action === 'removeAll' ? this.dangerSurface() : this.selection()).borderRadius('17vp')
      .border({
        width: 1,
        color: action === 'removeAll' ? Ui.danger(this.darkTheme) : Ui.glassRingAccent(this.darkTheme)
      })
      .opacity(this.loading || this.busy ? 0.5 : 1)
      .enabled(!this.loading && !this.busy)
      .onClick(() => { void this.operate(action); });
  }

  @Builder
  private taskAction(label: string, action: string, record: DownloadRecord, danger: boolean) {
    Row() {
      Text(label).fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(danger ? this.dangerInk() : this.accent()).maxLines(1);
    }
      .layoutWeight(1)
      .height('34vp')
      .justifyContent(FlexAlign.Center)
      .borderRadius('17vp')
      .backgroundColor(danger ? this.dangerSurface() : this.selection())
      .border({
        width: 1,
        color: danger ? Ui.danger(this.darkTheme) : Ui.glassRingAccent(this.darkTheme)
      })
      .opacity(this.busy ? 0.5 : 1)
      .enabled(!this.busy)
      .accessibilityText(label)
      .onClick(() => { this.performCardAction(action, record); });
  }

  @Builder
  private statePill(record: DownloadRecord) {
    Row({ space: '4vp' }) {
      Column()
        .width('6vp').height('6vp').borderRadius('3vp')
        .backgroundColor(this.stateTone(record))
      Text(this.stateChip(record)).fontSize(Ui.fs('10.5vp', this.fontScale)).fontWeight(FontWeight.Medium)
        .fontColor(this.stateTone(record)).maxLines(1);
    }
      .height('22vp')
      .padding({ left: '8vp', right: '9vp' })
      .borderRadius('11vp')
      .backgroundColor(this.panel())
      .border({ width: 1, color: Ui.cardBorderSoft(this.darkTheme) });
  }

  @Builder
  private skeleton() {
    List({ space: '12vp', scroller: this.listScroller }) {
      ForEach([0, 1, 2, 3], (item: number) => {
        ListItem() {
          Row({ space: '12vp' }) {
            Row() {}.width(this.coverSize() + 'vp').aspectRatio(16 / 9).borderRadius('14vp')
              .backgroundColor(Ui.glassTintStrong(this.darkTheme));
            Column({ space: '10vp' }) {
              Row() {}.width('80%').height('14vp').borderRadius('7vp').backgroundColor(Ui.glassTintStrong(this.darkTheme));
              Row() {}.width('55%').height('11vp').borderRadius('6vp').backgroundColor(Ui.glassTintSoft(this.darkTheme));
              Row() {}.width('100%').height('6vp').borderRadius('3vp').backgroundColor(Ui.glassTintSoft(this.darkTheme));
            }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          }.width('100%').padding('12vp').borderRadius('20vp')
            .linearGradient({
              angle: 135,
              colors: [[Ui.card(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
            })
            .border({ width: 1, color: Ui.cardBorder(this.darkTheme) });
        }
      }, (item: number) => String(item));
    }.width('100%').layoutWeight(1).accessibilityText('正在加载下载任务')
      .onScrollStart(() => { NavigationScroll.begin(this.scrollRoute(), 'downloads', this.listScroller); })
      .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
      NavigationScroll.report(this.scrollRoute(), 'downloads', this.listScroller, scrollState);
    })
      .onScrollStop(() => { NavigationScroll.end(this.scrollRoute(), 'downloads', this.listScroller); });
  }

  @Builder
  private taskCard(record: DownloadRecord) {
    Column({ space: '10vp' }) {
      Row({ space: '12vp' }) {
        Image(record.cover || $r('app.media.icon')).width(this.coverSize() + 'vp').aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover).borderRadius('14vp')
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) });
        Column({ space: '5vp' }) {
          Row({ space: '8vp' }) {
            Text(record.name || '未命名影片').fontSize(Ui.fs('15vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
            this.statePill(record)
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          Text(record.episodeTitle || ('第 ' + record.episodeIndex + ' 集')).fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
          Text(this.stateLabel(record)).fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.stateTone(record))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
          // 主色渐变进度条：底槽用主题分割线色，前景是 accent → accentStrong 渐变。
          Row() {
            Row()
              .width(this.barWidth(record))
              .height('100%')
              .borderRadius('3vp')
              .linearGradient({
                angle: 110,
                colors: [[Ui.accent(this.darkTheme), 0], [Ui.accentStrong(this.darkTheme), 1]]
              })
          }
            .width('100%')
            .height('6vp')
            .borderRadius('3vp')
            .backgroundColor(Ui.divider(this.darkTheme))
            .clip(true)
          Row({ space: '8vp' }) {
            Text(this.sizeLabel(record)).fontSize(Ui.fs('11vp', this.fontScale)).fontColor(this.secondary())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
            if (record.state === DownloadState.RUNNING) {
              Text(this.bytes(record.speedBytes) + '/s').fontSize(Ui.fs('11vp', this.fontScale)).fontColor(this.accent()).maxLines(1);
            }
            Text(this.percent(record).toFixed(0) + '%').fontSize(Ui.fs('11vp', this.fontScale)).fontColor(this.secondary()).maxLines(1);
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        if (record.state === DownloadState.SNIFFING) {
          LoadingProgress().width('22vp').height('22vp').color(this.accent());
        }
      }
        .width('100%')
        .onClick(() => { void this.open(record); })
      if (record.message) {
        Text(record.message).fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary()).width('100%').maxLines(3);
      }
      Row({ space: '8vp' }) {
        if (this.active(record)) {
          this.taskAction('暂停', 'pause', record, false);
        } else if (record.state !== DownloadState.COMPLETED) {
          this.taskAction(record.state === DownloadState.FAILED ? '重试' : '继续', 'resume', record, false);
        } else {
          this.taskAction('播放', 'play', record, false);
        }
        this.taskAction('删除', 'remove', record, true);
      }
        .width('100%')
    }
      .width('100%')
      .padding('12vp')
      .borderRadius('20vp')
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.darkTheme), 0], [Ui.cardBottom(this.darkTheme), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .scale({
        x: this.pressedId === record.id && !this.busy ? 0.97 : 1,
        y: this.pressedId === record.id && !this.busy ? 0.97 : 1
      })
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .accessibilityText((record.name || '未命名影片') + '，' + this.stateLabel(record))
      .onTouch((event: TouchEvent) => {
        this.pressedId = event.type === TouchType.Down ? record.id : '';
      });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.darkTheme), 0], [Ui.pageBgAlt(this.darkTheme), 1]]
        })
      AuroraBackdrop({ intensity: this.darkTheme ? 0.9 : 0.7 })
      Column({ space: '12vp' }) {
        if (!this.embedded) {
          Row({ space: '10vp' }) {
            GlassIconButton({
              iconSize: 36,
              symbol: $r('sys.symbol.chevron_left_circle'),
              accessibilityLabel: '返回',
              onTap: (): void => { AppState.go('home'); }
            })
            Text('下载管理').fontSize(Ui.fs('20vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
              .layoutWeight(1).maxLines(1);
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
        }
        // 摘要玻璃胶囊：保留原有下载规则文案与任务计数。
        Row({ space: '8vp' }) {
          Column()
            .width('6vp').height('6vp').borderRadius('3vp')
            .backgroundColor(this.accent())
          Text(this.rulesLabel() + ' · 共 ' + this.records.length + ' 个任务')
            .fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(this.secondary()).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
          .width('100%')
          .height('32vp')
          .padding({ left: '12vp', right: '12vp' })
          .borderRadius('16vp')
          .backgroundColor(this.panel())
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .shadow({ radius: 8, color: Ui.shadowSoft(this.darkTheme), offsetY: 3 })
        // 批量操作条：整条是一枚玻璃胶囊，内部按钮横向滚动（顺序与原来一致）。
        Scroll() {
          Row({ space: '8vp' }) {
            this.toolbarButton('全部暂停', 'pauseAll');
            this.toolbarButton('全部继续', 'resumeAll');
            this.toolbarButton('重试失败', 'retryAll');
            Button('导入').fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '14vp', right: '14vp' })
              .fontColor(this.accent()).backgroundColor(this.selection()).borderRadius('17vp')
              .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
              .opacity(this.loading || this.busy ? 0.5 : 1)
              .enabled(!this.loading && !this.busy)
              .onClick(() => { void this.importRecords(); });
            Button('导出').fontSize(Ui.fs('12vp', this.fontScale)).height('34vp').padding({ left: '14vp', right: '14vp' })
              .fontColor(this.accent()).backgroundColor(this.selection()).borderRadius('17vp')
              .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
              .opacity(this.loading || this.busy ? 0.5 : 1)
              .enabled(!this.loading && !this.busy)
              .onClick(() => { void this.exportRecords(); });
            this.toolbarButton('全部删除', 'removeAll');
          }
            .height('100%')
            .padding({ left: '8vp', right: '8vp' })
            .alignItems(VerticalAlign.Center)
        }
          .width('100%')
          .height('50vp')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .borderRadius('25vp')
          .linearGradient({
            angle: 118,
            colors: [
              [Ui.glassSheenTop(this.darkTheme), 0],
              [Ui.glassTintSoft(this.darkTheme), 0.42],
              [Ui.glassSheenClear(), 1]
            ]
          })
          .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          .shadow({ radius: 12, color: Ui.shadowSoft(this.darkTheme), offsetY: 4 })
          .clip(true)
        if (this.loading) {
          this.skeleton();
        } else if (this.loadMessage) {
          Column() {
            EmptyState({
              title: this.loadMessage,
              hint: '点击重新加载',
              glyph: '↻',
              onTap: (): void => { void this.initialize(); }
            })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else if (this.records.length === 0) {
          Column() {
            EmptyState({ title: '暂无下载任务', hint: '在播放器中添加下载，或导入已有任务', icon: SymbolIcons.file() })
          }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          List({ space: '12vp', scroller: this.listScroller }) {
            ForEach(this.records, (record: DownloadRecord) => {
              ListItem() { this.taskCard(record); }
            }, (record: DownloadRecord) => record.id);
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
            .onScrollStart(() => { NavigationScroll.begin(this.scrollRoute(), 'downloads', this.listScroller); })
            .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
            NavigationScroll.report(this.scrollRoute(), 'downloads', this.listScroller, scrollState);
          })
            .onScrollStop(() => { NavigationScroll.end(this.scrollRoute(), 'downloads', this.listScroller); });
        }
      }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: Ui.gutter(this.viewportSize) + 'vp',
          right: Ui.gutter(this.viewportSize) + 'vp',
          top: '8vp',
          bottom: '8vp'
        })
    }
      .width('100%')
      .height('100%')
      .onAreaChange((_previous: Area, current: Area) => {
      const nextSize: number = Number(current.width);
      if (Number.isFinite(nextSize) && nextSize > 0) { this.viewportSize = nextSize; }
    });
  }
}

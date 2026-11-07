import { detectBarcode, scanBarcode, scanCore } from '../common/PlatformScanKit';
import router from '@ohos.router';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { Logger } from '../common/Logger';
import { PlatformInfo } from '../common/PlatformInfo';
import { ShareService, SharedPlayerParams } from '../common/ShareService';
import { SearchSources } from '../common/SearchSources';
import { SourceShareCodec, SourceSharePart } from '../common/SourceShareCodec';
import { Ui } from '../common/Ui';
import { AuroraBackdrop, GhostButton, PrimaryButton } from '../common/UiWidgets';

/** 扫一扫页：扫描无音影视分享的影视参数（Scheme 或 JSON），成功后直达播放器。 */
@Entry
@Component
export struct ScanPage {
  @StorageLink('darkTheme') @Watch('onThemeChanged') private dark: boolean = true;
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('immersiveTopInset') private topInset: number = 24;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @State private scanning: boolean = false;
  @State private statusText: string = '对准二维码即可自动识别';
  @State private manualText: string = '';
  @State private parsedTitle: string = '';
  @State private parsedSubtitle: string = '';
  @State private parsedParams: SharedPlayerParams | undefined = undefined;
  /** 线路分片二维码的暂存（1..N 顺序，扫齐后解码导入）。 */
  private sourceParts: string[] = [];
  private sourceTotal: number = 0;
  /// 相机权限状态：进入页面即检查，未授权时动态申请。
  @State private cameraGranted: boolean = false;
  /// 相册识别进行中：避免连点重复打开相册。
  @State private albumBusy: boolean = false;
  /// 已经发起播放器跳转：避免自动跳转和手动点击重复压栈。
  private navigating: boolean = false;

  aboutToAppear(): void {
    void this.ensureCameraPermission();
  }

  /** 检查相机权限；未授权时向用户动态申请。 */
  private async ensureCameraPermission(): Promise<void> {
    if (PlatformInfo.isAndroid()) {
      // Android 走系统相机 Intent，由相机应用自行处理 CAMERA 权限。
      this.cameraGranted = true;
      this.statusText = '已就绪，点「开始扫描」';
      return;
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const tokenId: number = this.context().applicationInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus =
        await manager.checkAccessToken(tokenId, 'ohos.permission.CAMERA');
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.cameraGranted = true;
        this.statusText = '相机权限已就绪，点「开始扫描」';
        return;
      }
      const permissions: Permissions[] = ['ohos.permission.CAMERA'];
      const result: PermissionRequestResult = await manager.requestPermissionsFromUser(this.context(), permissions);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      this.cameraGranted = granted;
      this.statusText = granted ? '相机权限已授权，点「开始扫描」' : '未授予相机权限，可先粘贴影视参数解析';
      Logger.info('SCAN', '相机权限申请结果：' + String(granted));
    } catch (error) {
      this.cameraGranted = false;
      this.statusText = '相机权限检查失败，可先粘贴影视参数解析';
      Logger.warn('SCAN', '检查/申请相机权限失败：' + String(error));
    }
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  onThemeChanged(): void {
    // 主题切换时仅刷新配色，无需额外处理。
  }

  /** 调起系统扫码 UI（原生能力，无需相机权限）。 */
  private async startScan(): Promise<void> {
    if (this.scanning) { return; }
    if (!this.cameraGranted) {
      await this.ensureCameraPermission();
      if (!this.cameraGranted) {
        this.statusText = '相机权限未授权，无法扫码；可粘贴影视参数解析';
        return;
      }
    }
    this.scanning = true;
    this.statusText = '正在打开相机…';
    try {
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(this.context(), {
        scanTypes: [scanCore.ScanType.QR_CODE],
        // 系统扫码界面自带「相册」入口，没有相机权限也能从截图里识别。
        enableAlbum: true
      });
      void this.handlePayload(result.originalValue);
    } catch (error) {
      Logger.warn('SCAN', '扫码取消或失败：' + String(error));
      this.statusText = '已取消扫码，可粘贴影视参数手动解析';
    } finally {
      this.scanning = false;
    }
  }

  /** 兼容四种载体：新版精简链接、wuyin://player Scheme、wuyinvideo:// 短链、纯 JSON。 */
  /** 线路分片二维码：扫齐后解密、解压并导入。 */
  private async receiveSourcePart(part: SourceSharePart): Promise<void> {
    if (this.sourceTotal !== part.total || this.sourceParts.length !== part.total) {
      this.sourceParts = new Array<string>(part.total).fill('');
      this.sourceTotal = part.total;
    }
    this.sourceParts[part.index - 1] = part.payload;
    let received: number = 0;
    for (const value of this.sourceParts) {
      if (value.length > 0) { received++; }
    }
    this.parsedParams = undefined;
    this.parsedTitle = '无音影视资源线路';
    this.parsedSubtitle = '分片 ' + String(received) + '/' + String(part.total);
    if (received < part.total) {
      this.statusText = '已扫描 ' + String(received) + '/' + String(part.total) + '，请继续扫描下一张二维码';
      return;
    }
    try {
      this.statusText = '二维码已扫齐，正在解密导入…';
      const json: string = await SourceShareCodec.decode(this.sourceParts);
      const count: number = await SearchSources.importText(json, '二维码导入');
      this.statusText = '识别成功，已导入 ' + String(count) + ' 条线路';
      this.parsedSubtitle = '共 ' + String(count) + ' 条线路';
      this.sourceParts = [];
      this.sourceTotal = 0;
      Logger.info('SCAN', '分片线路二维码导入成功：' + String(count) + ' 条');
      setTimeout(() => {
        if (Number(router.getLength()) > 1) { void router.back(); }
      }, 900);
    } catch (error) {
      Logger.warn('SCAN', '分片线路二维码解码失败：' + String(error));
      this.statusText = '线路二维码解密失败，请确认二维码完整且来自无音影视';
      this.sourceParts = [];
      this.sourceTotal = 0;
    }
  }

  private async handlePayload(raw: string): Promise<void> {
    const text: string = (raw || '').trim();
    if (!text) {
      this.statusText = '二维码内容为空';
      return;
    }
    Logger.info('SCAN', '扫码内容长度=' + String(text.length) + '，前 60 字符=' + text.substring(0, 60));
    // 先尝试线路 JSON：{"userlist":[...]} 或根数组，识别成功直接导入源。
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        const count: number = await SearchSources.importText(text);
        this.parsedParams = undefined;
        this.parsedTitle = '无音影视资源线路';
        this.parsedSubtitle = '共 ' + String(count) + ' 条线路';
        this.statusText = '识别成功，已导入 ' + String(count) + ' 条线路';
        Logger.info('SCAN', '扫码导入资源线路 ' + String(count) + ' 条');
        setTimeout(() => {
          if (Number(router.getLength()) > 1) { void router.back(); }
        }, 900);
        return;
      } catch (error) {
        // 不是线路 JSON 时继续走影视分享参数解析。
        Logger.debug('SCAN', '非线路 JSON，继续解析影视分享：' + String(error));
      }
    }
    const sourcePart: SourceSharePart | undefined = SourceShareCodec.parsePart(text);
    if (sourcePart !== undefined) {
      await this.receiveSourcePart(sourcePart);
      return;
    }
    try {
      const params: SharedPlayerParams | undefined = ShareService.parseLink(text);
      if (params === undefined || !params.vodId || !params.wzlj) {
        this.statusText = '这不是无音影视的分享数据';
        this.parsedParams = undefined;
        this.parsedTitle = '';
        this.parsedSubtitle = '';
        return;
      }
      this.parsedParams = params;
      this.parsedTitle = params.tilie || params.yhm || '未命名影片';
      const episode: number = (params.sharedEpisodeIndex || 0) + 1;
      this.parsedSubtitle = '第 ' + String(episode) + ' 集' +
        (params.sharedEpisodeTitle ? ' · ' + params.sharedEpisodeTitle : '');
      this.statusText = '识别成功，正在打开播放器…';
      Logger.info('SCAN', '扫码解析成功，直接进入播放器：' + this.parsedTitle);
      // 解析成功即自动跳播放器；留一帧让「识别成功」先渲染出来，避免看起来没反应。
      setTimeout(() => { this.openPlayer(true); }, 180);
    } catch (error) {
      Logger.warn('SCAN', '扫码内容解析失败：' + String(error));
      this.statusText = '内容解析失败，请确认二维码来自无音影视';
    }
  }

  /**
   * 带着解析结果进入播放器。auto=true 表示扫码解析成功后自动跳转，
   * 用 navigating 标记防止自动跳转与用户点「立即播放」重复压栈。
   */
  private openPlayer(auto: boolean = false): void {
    const params: SharedPlayerParams | undefined = this.parsedParams;
    if (params === undefined) { return; }
    if (this.navigating) { return; }
    this.navigating = true;
    try {
      router.pushUrl({
        url: 'pages/PlayerPage',
        params: {
          yhm: params.yhm, feng: params.feng, sfeng: params.sfeng, data: params.data,
          tilie: params.tilie || params.yhm, genxi: params.genxi, zyuanuuu: params.zyuanuuu,
          vodId: params.vodId, wzlj: params.wzlj,
          sharedEpisodeIndex: params.sharedEpisodeIndex || 0,
          sharedEpisodeTitle: params.sharedEpisodeTitle || '',
          sharedPlayUrl: params.sharedPlayUrl || '',
          sharedPlayProgress: params.sharedPlayProgress || 0,
          shareChannel: 'share',
          shareRequestId: Date.now(),
          fromShare: true
        }
      }).catch((error: Error) => {
        this.navigating = false;
        Logger.error('SCAN', '打开播放器失败：' + String(error));
        this.statusText = '打开播放器失败，请重试';
      });
      Logger.info('SCAN', (auto ? '识别成功自动播放：' : '点击立即播放：') + (params.tilie || params.vodId));
    } catch (error) {
      this.navigating = false;
      Logger.error('SCAN', '打开播放器失败：' + String(error));
      this.statusText = '打开播放器失败，请重试';
    }
  }

  /** 从播放器返回时重置跳转标记，允许再次扫码/播放。 */
  onPageShow(): void {
    this.navigating = false;
  }

  /**
   * 从相册选一张二维码图片并**直接识别**：用 ScanKit 的图片解码接口
   * （detectBarcode.decode，入参就是相册返回的 file://media/Photo/... 地址），
   * 识别到内容后走和相机扫描完全一样的分发逻辑。
   */
  private async pickFromAlbum(): Promise<void> {
    if (this.albumBusy) { return; }
    this.albumBusy = true;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['图片 (.jpg,.jpeg,.png,.webp)|.jpg,.jpeg,.png,.webp'];
      const photoPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(
        getContext(this) as common.UIAbilityContext);
      const picked: string[] = await photoPicker.select(options);
      if (picked.length === 0) {
        this.statusText = '未选择图片';
        return;
      }
      const values: string[] = [];
      this.statusText = '正在识别 ' + String(picked.length) + ' 张图片中的二维码…';
      for (const uri of picked) {
        try {
          const results: scanBarcode.ScanResult[] = await detectBarcode.decode({ uri: uri },
            { scanTypes: [scanCore.ScanType.QR_CODE] });
          for (const result of results) {
            if (result.originalValue && result.originalValue.trim().length > 0) {
              values.push(result.originalValue.trim());
            }
          }
        } catch (error) {
          Logger.warn('SCAN', '图片解码失败：' + uri + '，' + String(error));
        }
      }
      if (values.length === 0) {
        this.statusText = '所选图片里没有识别到二维码';
        this.toast('没有识别到二维码');
        return;
      }
      Logger.info('SCAN', '相册多选识别到二维码 ' + String(values.length) + ' 个');
      await this.handleBatchPayloads(values);
    } catch (error) {
      Logger.warn('SCAN', '相册选图失败：' + String(error));
      this.statusText = '相册选图失败';
    } finally {
      this.albumBusy = false;
    }
  }

  /** 多张图片识别结果：线路分片优先，按分片序号自动排序后合并。 */
  private async handleBatchPayloads(values: string[]): Promise<void> {
    const parts: SourceSharePart[] = [];
    const others: string[] = [];
    for (const value of values) {
      const part: SourceSharePart | undefined = SourceShareCodec.parsePart(value);
      if (part !== undefined) { parts.push(part); } else { others.push(value); }
    }
    if (parts.length === 0) {
      await this.handlePayload(others[0]);
      return;
    }
    parts.sort((first: SourceSharePart, second: SourceSharePart): number => first.index - second.index);
    const total: number = parts[0].total;
    for (const part of parts) {
      if (part.total === total) {
        await this.receiveSourcePart(part);
      }
    }
  }

  private toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 }); }
    catch (_) { /* 忽略 */ }
  }

  private goBack(): void {
    try {
      if (Number(router.getLength()) > 1) { void router.back(); return; }
      AppState.go('home');
      void router.pushUrl({ url: 'pages/Index' });
    } catch (error) {
      Logger.warn('SCAN', '返回失败：' + String(error));
      try { AppState.go('home'); } catch (_) { /* 忽略 */ }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.dark), 0], [Ui.pageBgAlt(this.dark), 1]]
        })
      AuroraBackdrop({ intensity: this.dark ? 1 : 0.9 })

      Column() {
        // 顶部：返回 + 标题（固定在顶部，不随正文滚动）
        Row({ space: 10 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left_circle'))
              .fontSize(Ui.fs('22vp', this.fontScale))
              .fontColor([Ui.ink(this.dark)]);
          }
            .width('40vp').height('40vp').padding(0)
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .onClick(() => { this.goBack(); });
          Text('扫一扫')
            .fontSize(Ui.fs('20vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.dark));
          Blank()
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)

        // 正文区域可滚动：出解析结果卡或系统字体放大时，卡片只会往下延伸出滚动，
        // 不会再像整屏定高的 Column 那样把卡片顶出屏幕。
        Scroll() {
          Column({ space: 14 }) {
            // 扫描卡片
            Column({ space: 14 }) {
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor(Ui.glassTint(this.dark))
                  .backdropBlur(Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur))
                Column({ space: 10 }) {
                  SymbolGlyph($r('sys.symbol.barcode_viewfinder'))
                    .fontSize(Ui.fs('48vp', this.fontScale))
                    .fontColor([Ui.accent(this.dark)]);
                  Text('扫描无音影视分享二维码')
                    .fontSize(Ui.fs('15vp', this.fontScale))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Ui.ink(this.dark));
                  Text(this.statusText)
                    .fontSize(Ui.fs('12vp', this.fontScale))
                    .fontColor(Ui.inkFaint(this.dark))
                    .textAlign(TextAlign.Center)
                    .maxLines(2);
                }
                  .width('100%')
                  .padding({ top: '18vp', bottom: '18vp' })
                  .alignItems(HorizontalAlign.Center)
              }
                .width('100%')
                // 固定高度：原来只用 minHeight，内部 height('100%') 会把卡片撑到整屏，
                // 把「开始扫描」和下面的操作顶出屏幕。
                .height('220vp')
                .borderRadius('26vp')
                .clip(true)

              PrimaryButton({
                label: this.scanning ? '正在扫描…' : '开始扫描',
                onTap: (): void => { void this.startScan(); }
              })

              // 手动粘贴兜底
              Row({ space: 10 }) {
                TextInput({ text: this.manualText, placeholder: '或粘贴影视参数 / Scheme 链接' })
                  .layoutWeight(1)
                  .height('44vp')
                  .fontSize(Ui.fs('13vp', this.fontScale))
                  .fontColor(Ui.ink(this.dark))
                  .placeholderColor(Ui.inkFaint(this.dark))
                  .caretColor(Ui.accent(this.dark))
                  .backgroundColor(Ui.glassTintSoft(this.dark))
                  .borderRadius('22vp')
                  .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
                  .padding({ left: '14vp', right: '14vp' })
                  .onChange((value: string) => { this.manualText = value; })
                GhostButton({
                  label: '解析',
                  compact: true,
                  onTap: (): void => { void this.handlePayload(this.manualText); }
                })
              }
                .width('100%')
                .alignItems(VerticalAlign.Center)

              // 解析结果
              if (this.parsedParams !== undefined) {
                Column({ space: 10 }) {
                  Text(this.parsedTitle)
                    .fontSize(Ui.fs('16vp', this.fontScale))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Ui.ink(this.dark))
                    .maxLines(2);
                  Text(this.parsedSubtitle)
                    .fontSize(Ui.fs('12vp', this.fontScale))
                    .fontColor(Ui.inkSoft(this.dark));
                  PrimaryButton({ label: '立即播放', onTap: (): void => { this.openPlayer(); } })
                }
                  .width('100%')
                  .padding('14vp')
                  .borderRadius('20vp')
                  .backgroundColor(Ui.card(this.dark))
                  .border({ width: 1, color: Ui.cardBorder(this.dark) })
              }
            }
              .width('100%')
              .padding('16vp')
              .borderRadius('28vp')
              .backgroundColor(Ui.card(this.dark))
              .border({ width: 1, color: Ui.cardBorder(this.dark) })
              .shadow({ radius: 18, color: Ui.shadowSoft(this.dark), offsetY: 8 })

            // 底部操作：取消返回、从相册选图
            Row({ space: '12vp' }) {
              GhostButton({ label: '取消', compact: true, onTap: (): void => { this.goBack(); } })
              GhostButton({ label: '相册多选', compact: true, onTap: (): void => { void this.pickFromAlbum(); } })
            }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
          }
            .width('100%')
            .padding({ top: '14vp', bottom: '20vp' })
        }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
      }
        .width('100%')
        .height('100%')
        .padding({ left: '16vp', right: '16vp', top: (this.topInset + 12) + 'vp' })
    }
      .width('100%')
      .height('100%')
  }
}
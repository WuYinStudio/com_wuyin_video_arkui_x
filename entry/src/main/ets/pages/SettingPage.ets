import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { AppConfig } from '../common/AppConfig';
import { ImageHostConfig, ImageHostResult, ImageHostService } from '../common/ImageHostService';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ChatAlertService } from '../common/ChatAlertService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { NavTabDefinition, NavTabs } from '../common/NavTabs';
import { NavigationScroll } from '../common/NavigationScroll';
import { NotificationService } from '../common/NotificationService';
import { SearchSource, SearchSources } from '../common/SearchSources';
import { SourceShareCodec } from '../common/SourceShareCodec';
import { http } from '@kit.NetworkKit';
import { SourceKind, SourceRules, TvboxSite } from '../common/SourceRules';
import { DnsMode, DnsService } from '../common/DnsService';
import { SymbolIcons } from '../common/SymbolIcons';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, GhostButton, GlassIconButton, PageHeader, PrimaryButton } from '../common/UiWidgets';
import { ChatArchive } from '../common/ChatArchive';
import { VoiceFile, VoiceStore } from '../common/VoiceStore';
import { FrameRateConfig, FrameRateService } from '../common/FrameRateService';
import { ThemeService } from '../common/ThemeService';
import { WallpaperKind, WallpaperMedia, WallpaperService } from '../common/WallpaperService';
import { AdBlockService } from '../common/AdBlockService';
import { DockStyleConfig, DockStyleOption, DockStyleStore } from '../common/DockStyleStore';
import { AccountApi } from '../common/AccountApi';
import { CommunityApi } from '../common/CommunityApi';
import { SocialStore } from '../common/SocialStore';

// 日志列表使用懒加载数据源，避免长日志一次性创建全部行组件。
class LogLineDataSource implements IDataSource {
  private lines: string[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.lines.length; }
  getData(index: number): string { return this.lines[index]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }
  setLines(lines: string[]): void {
    this.lines = lines;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

/**
 * 设置页 · 液态玻璃
 *
 * 视觉：页头玻璃胶囊 + 分类菜单（手机是顶部玻璃分段，平板是左侧玻璃侧栏）+
 *      每个设置分组一张玻璃卡片（圆角 24、玻璃底 + 亮描边 + 柔和投影），
 *      行内左侧标题/说明、右侧控件，行间用 hairline 分割线；输入框统一玻璃胶囊。
 * 行为：所有状态、方法、服务调用、日志与提示文案保持原样。
 */
@Component
export struct SettingPage {
  /** 各类型源的填写提示。 */
  private static kindHint(kind: string): string {
    if (kind === SourceKind.TVBOX) { return '在地址栏填 TVBox site 的 api，或点「导入 TVBox」批量导入'; }
    if (kind === SourceKind.WEB) { return '填网页地址（可用 {kw} 占位），高级 JSON 可配 referer / mediaRegex'; }
    if (kind === SourceKind.NETDISK) { return '填网盘解析接口（支持 {share}/{kw}），需返回 url/playUrl'; }
    return '填苹果CMS V10 采集接口，关键词自动拼到末尾';
  }

  @StorageLink('immersiveConfig') @Watch('onImmersiveConfigChanged') private immersiveConfig: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('immersiveEnabled') immersiveEnabled: boolean = true;
  @StorageLink('immersiveBlur') immersiveBlur: number = 20;
  @StorageLink('immersiveOpacity') immersiveOpacity: number = 0.8;
  @StorageLink('darkTheme') darkTheme: boolean = true;
  @StorageLink('logging') logging: boolean = true;
  @StorageLink('playerKernel') playerKernel: string = 'ijk';
  // 聊天提醒：提示音 / 顶部弹窗 / 免打扰，与 ChatAlertService 共用同一组 AppStorage 键。
  @StorageLink('chatSoundEnabled') private chatSoundEnabled: boolean = true;
  @StorageLink('chatBannerEnabled') private chatBannerEnabled: boolean = true;
  @StorageLink('chatDndEnabled') private chatDndEnabled: boolean = false;
  // 提醒弹窗位置：top（默认，紧贴屏幕正上方）/ center / bottom，offset 为垂直微调（vp）。
  @StorageLink('chatAlertPosition') private chatAlertPosition: string = 'top';
  @StorageLink('chatAlertOffset') private chatAlertOffset: number = 0;
  // 后台通知栏提醒：退到后台后用系统通知栏提醒新消息。
  @StorageLink('chatBackgroundNotify') private chatBackgroundNotify: boolean = true;
  // 界面尺寸：底部 Dock 栏缩放与全局字体缩放（1 = 原始尺寸）。
  @StorageLink('dockScale') private dockScale: number = 1;
  @StorageLink('fontScale') private fontScale: number = 1;
  // 底栏 Tab 的显示与顺序；设置页与 LiquidNav 绑定同一个 AppStorage 数组。
  @StorageLink('navTabKeys') private navTabKeys: string[] = NavTabs.DEFAULT_KEYS;
  // 壁纸设置：本地导入背景 + 透明度 / 播放速率 / 动态背景帧率（与 WallpaperService 共用同一组键）。
  @StorageLink('wallpaperMediaId') private wallpaperMediaId: string = '';
  @StorageLink('wallpaperMediaKind') private wallpaperMediaKind: string = '';
  @StorageLink('wallpaperMediaName') private wallpaperMediaName: string = '';
  @StorageLink('wallpaperOpacity') private wallpaperOpacity: number = 0.85;
  @StorageLink('wallpaperRate') private wallpaperRate: number = 1;
  @StorageLink('wallpaperFrameHz') private wallpaperFrameHz: number = 0;
  @StorageLink('wallpaperMotion') private wallpaperMotion: boolean = true;
  @State private wallpaperImporting: boolean = false;
  // 广告拦截：m3u8 播放地址过滤（开关由 AdBlockService 持久化并发布到 AppStorage）。
  @StorageLink('adBlockEnabled') private adBlockEnabled: boolean = true;
  @State private showAdBlockDialog: boolean = false;
  @StorageLink('page') private currentPage: string = 'home';
  // 宿主发布的底栏占位高度：底栏 + 底栏上方渐进模糊带 + 手势条。
  @StorageLink('navClearance') private navClearance: number = 186;
  @State backendDomain: string = AppConfig.DEFAULT_BACKEND_DOMAIN;
  /** 界面尺寸落盘的防抖定时器：拖动过程中只改状态，停手后再保存。 */
  private scaleSaveTimer: number = -1;
  @State backendAccount: string = AppConfig.DEFAULT_BACKEND_ACCOUNT;
  @State savingBackendDomain: boolean = false;
  @State savingBackendAccount: boolean = false;
  // 图床设置：接口地址、表单字段名、返回直链的 JSON 路径，默认值来自 ImageHostService。
  @State imageHostUrl: string = ImageHostService.DEFAULT_UPLOAD_URL;
  @State imageHostField: string = ImageHostService.DEFAULT_FIELD_NAME;
  @State imageHostPath: string = ImageHostService.DEFAULT_RESPONSE_PATH;
  // 需要鉴权的图床（奶昔 Chevereto）用 X-API-Key 头；默认内置一个 key，界面固定按密码态显示，不提供查看明文入口。
  @State imageHostKey: string = ImageHostService.DEFAULT_API_KEY;
  // 直传代理（可选）：原始字节 POST，绕开客户端 multipart，主要给视频/音频用。
  @State imageHostProxy: string = '';
  @State savingImageHost: boolean = false;
  // 「测试接口」：用当前输入框里的值直接传一张图，结果就地展示（不进历史、不改配置）。
  @State testingImageHost: boolean = false;
  @State imageHostTestText: string = '';
  @State imageHostTestOk: boolean = false;
  // 音频管理：本地录音列表 + 自动清理设置。
  @State voiceFiles: VoiceFile[] = [];
  @State voiceAutoClean: boolean = true;
  @State voiceKeepDays: string = String(VoiceStore.DEFAULT_DAYS);
  @State voiceMaxCount: string = String(VoiceStore.DEFAULT_MAX);
  // 帧数设置：跟随系统 / 软件帧率 / 播放器帧率。
  @State private frameFollowSystem: boolean = true;
  @State private frameAppHz: number = 60;
  @State private framePlayerHz: number = 60;
  @State private savingFrameRate: boolean = false;
  /** 设备支持的最高刷新率（0 表示未知，不限制）。 */
  @State private frameMaxHz: number = 0;
  // Dock 栏外观：样式 / 强度 / 低电量自适应。
  @State private dockStyleKey: string = 'glow';
  @State private dockIntensity: number = 70;
  @State private dockBatteryAuto: boolean = true;
  @State private dockThreshold: string = '20';
  @State private dockBatteryNow: number = 100;
  // 直链图床（dbimg）：地址、API Key，语音消息走这家。
  @State directUrl: string = ImageHostService.DEFAULT_DIRECT_URL;
  @State directKey: string = ImageHostService.DEFAULT_DIRECT_KEY;
  @State savingDirect: boolean = false;
  @State isTablet: boolean = false;
  @State showLogDialog: boolean = false;
  @State showClearDialog: boolean = false;
  @State logText: string = '';
  @State toastText: string = '';
  @State activeMenu: string = '沉浸外观';
  @State pressedAction: string = '';
  @State remoteAddress: string = SearchSources.DEFAULT_ADDRESS;
  /** 分类页数据接口地址（用户自行填写，应用不内置）。 */
  /** 自定义搜索规则：列表 + 新增表单（名称/接口地址）+ 提示文案。 */
  @State customRules: SearchSource[] = [];
  /** 本地停用 id 列表：按钮文字直接跟随它，避免持久化回来前状态不刷新。 */
  @State private disabledRuleIds: number[] = [];
  @State customRuleName: string = '';
  /** 源规则类型：cms / tvbox / web / netdisk。 */
  @State customRuleKind: string = 'cms';
  /** 线路管理模式：开启后可勾选批量删除/批量启停。 */
  @State ruleManageMode: boolean = false;
  /** 已勾选的线路 id。 */
  @State selectedRuleIds: number[] = [];
  /** DNS 解析模式：follow / off / aliyun / tencent。 */
  @State dnsMode: string = DnsMode.FOLLOW;
  /** DNS 测试结果文案。 */
  @State dnsProbeResult: string = '';
  /** 高级规则 JSON（搜索模板、Referer、嗅探正则、网盘接口）。 */
  @State customRuleRule: string = '';
  @State customRuleUrl: string = '';
  @State customRuleHint: string = '';
  @State savingAddress: boolean = false;
  @State importingSource: boolean = false;
  /** 自定义规则保存中：防连点重复添加。 */
  @State savingCustomRule: boolean = false;
  // 仅用于输入框的聚焦描边，不影响任何业务状态。
  @State private focusedField: string = '';
  private readonly appConfig: AppConfig = AppConfig.getInstance();
  private readonly panelRadius: string = '24vp';
  private pageScroller: Scroller = new Scroller();
  private logSource: LogLineDataSource = new LogLineDataSource();

  private onImmersiveConfigChanged(): void {
    try {
      // 材质以同一份持久化配置为准；兼容原设置控件使用的分项绑定。
      this.immersiveEnabled = this.immersiveConfig.immersiveEnable;
      this.immersiveBlur = this.immersiveConfig.immersiveBlur;
      this.immersiveOpacity = this.immersiveConfig.immersiveOpacity;
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('SETTING_IMMERSIVE', '同步设置页沉浸配置失败：' + String(error));
      this.showOperationError('同步设置页沉浸配置失败：' + String(error));
    }
  }

  private refreshBackendConfig(): void {
    try {
      this.backendDomain = this.appConfig.backendDomain || AppConfig.DEFAULT_BACKEND_DOMAIN;
      this.backendAccount = this.appConfig.backendAccount || AppConfig.DEFAULT_BACKEND_ACCOUNT;
    } catch (error) {
      Logger.error('SETTING_BACKEND', '回填无音影视后端配置失败：' + String(error));
      this.showOperationError('读取后端配置失败：' + String(error));
    }
  }

  // 页面每次显示时从 AppConfig 单例回填，避免使用 AppStorage 导致配置不同步。
  onPageShow(): void {
    this.refreshBackendConfig();
    this.refreshImageHost();
    this.refreshVoice();
    this.refreshDirect();
    this.refreshFrameRate();
    this.refreshDockStyle();
    this.refreshCustomRules();
  }

  // ---------- 直链图床（dbimg） ----------

  private refreshDirect(): void {
    const config: ImageHostConfig = ImageHostService.current();
    this.directUrl = config.directUrl || ImageHostService.DEFAULT_DIRECT_URL;
    this.directKey = config.directKey;
  }

  private async saveDirect(): Promise<void> {
    if (this.savingDirect) { return; }
    this.savingDirect = true;
    try {
      const config: ImageHostConfig = ImageHostService.current();
      await ImageHostService.save(config.uploadUrl, config.fieldName, config.responsePath,
        config.apiKey, config.proxyUrl, this.directUrl.trim(), this.directKey.trim());
      this.refreshDirect();
      this.showToast('直链设置已保存');
    } catch (error) {
      this.showOperationError('保存直链设置失败：' + String(error));
    } finally {
      this.savingDirect = false;
    }
  }

  private useDbimgDefaults(): void {
    this.directUrl = ImageHostService.DEFAULT_DIRECT_URL;
    this.directKey = ImageHostService.DEFAULT_DIRECT_KEY;
    this.showToast('已填入 dbimg 默认配置，记得保存');
  }

  // ---------- 音频管理 ----------

  // ---------- Dock 栏外观 ----------

  private refreshDockStyle(): void {
    const config: DockStyleConfig = DockStyleStore.current();
    this.dockStyleKey = config.style;
    this.dockIntensity = config.intensity;
    this.dockBatteryAuto = config.batteryAuto;
    this.dockThreshold = String(config.batteryThreshold);
    this.dockBatteryNow = DockStyleStore.batteryPercent();
  }

  private async saveDockStyle(): Promise<void> {
    const threshold: number = Number(this.dockThreshold);
    if (!Number.isFinite(threshold) || threshold < 0 || threshold > 100) {
      this.showToast('低电量阈值需要在 0~100 之间');
      return;
    }
    try {
      await DockStyleStore.save(this.dockStyleKey, this.dockIntensity, this.dockBatteryAuto, threshold);
      this.refreshDockStyle();
      this.showToast('Dock 外观已保存');
    } catch (error) {
      this.showOperationError('保存 Dock 外观失败：' + String(error));
    }
  }

  // ---------- 帧数设置 ----------

  private refreshFrameRate(): void {
    FrameRateService.refreshCapability();
    this.frameMaxHz = FrameRateService.maxSupportedHz();
    const config: FrameRateConfig = FrameRateService.current();
    this.frameFollowSystem = config.followSystem;
    this.frameAppHz = config.appHz;
    this.framePlayerHz = config.playerHz;
  }

  /** 该挡位是否超出设备支持上限（0 表示未知，全部放开）。 */
  private frameRateSupported(hz: number): boolean {
    return this.frameMaxHz <= 0 || hz <= this.frameMaxHz;
  }

  private async saveFrameRate(): Promise<void> {
    if (this.savingFrameRate) { return; }
    this.savingFrameRate = true;
    try {
      await FrameRateService.save(this.frameFollowSystem, this.frameAppHz, this.framePlayerHz);
      this.refreshFrameRate();
      this.showToast(this.frameFollowSystem
        ? '已保存：跟随系统刷新率'
        : '已保存：软件 ' + String(this.frameAppHz) + 'Hz，播放器 ' + String(this.framePlayerHz) + 'Hz');
    } catch (error) {
      this.showOperationError('保存帧数设置失败：' + String(error));
    } finally {
      this.savingFrameRate = false;
    }
  }

  private refreshVoice(): void {
    this.voiceFiles = VoiceStore.list();
    this.voiceAutoClean = VoiceStore.autoClean();
    this.voiceKeepDays = String(VoiceStore.retainDays());
    this.voiceMaxCount = String(VoiceStore.maxCount());
  }

  private voiceStat(): string {
    const count: number = this.voiceFiles.length;
    return '共 ' + String(count) + ' 条 · ' + VoiceStore.formatSize(VoiceStore.totalBytes(this.voiceFiles));
  }

  private deleteVoiceFile(name: string): void {
    VoiceStore.deleteFile(name);
    this.refreshVoice();
    this.showToast('已删除 1 条语音');
  }

  private clearVoiceFiles(): void {
    VoiceStore.clearAll();
    this.refreshVoice();
    this.showToast('已清空本地语音');
  }

  private cleanVoiceNow(): void {
    const removed: number = VoiceStore.enforce();
    this.refreshVoice();
    this.showToast(removed > 0 ? ('已自动清理 ' + String(removed) + ' 条') : '没有需要清理的语音');
  }

  private async saveVoiceSettings(): Promise<void> {
    const days: number = Number(this.voiceKeepDays);
    const max: number = Number(this.voiceMaxCount);
    if (!Number.isFinite(days) || days < 0) {
      this.showToast('保留天数需要是 0 或正整数（0 = 不限）');
      return;
    }
    if (!Number.isFinite(max) || max < 1) {
      this.showToast('数量上限至少为 1');
      return;
    }
    await VoiceStore.saveSettings(this.voiceAutoClean, max, days);
    this.refreshVoice();
    this.showToast('音频设置已保存');
  }

  private async saveBackendDomain(): Promise<void> {
    if (this.savingBackendDomain) { return; }
    this.savingBackendDomain = true;
    try {
      const candidate: string = this.backendDomain.trim();
      if (!AppConfig.isValidDomain(candidate)) {
        const message: string = '域名格式无效，仅支持 http:// 或 https:// 协议';
        this.showOperationError(message);
        return;
      }
      this.backendDomain = candidate;
      await this.appConfig.setBackendDomain(candidate);
      this.backendDomain = this.appConfig.backendDomain;
      Logger.info('SETTING_BACKEND', '保存无音影视默认域名');
      this.showToast('默认域名已保存');
    } catch (error) {
      Logger.error('SETTING_BACKEND', '保存默认域名失败：' + String(error));
      this.showOperationError('保存默认域名失败：' + String(error));
    } finally {
      this.savingBackendDomain = false;
    }
  }

  private async restoreBackendDomain(): Promise<void> {
    if (this.savingBackendDomain) { return; }
    this.savingBackendDomain = true;
    try {
      await this.appConfig.restoreBackendDomain();
      this.backendDomain = this.appConfig.backendDomain;
      Logger.info('SETTING_BACKEND', '恢复无音影视默认域名');
      this.showToast('默认域名已恢复');
    } catch (error) {
      Logger.error('SETTING_BACKEND', '恢复默认域名失败：' + String(error));
      this.showOperationError('恢复默认域名失败：' + String(error));
    } finally {
      this.savingBackendDomain = false;
    }
  }

  private async saveBackendAccount(): Promise<void> {
    if (this.savingBackendAccount) { return; }
    this.savingBackendAccount = true;
    try {
      await this.appConfig.setBackendAccount(this.backendAccount);
      this.backendAccount = this.appConfig.backendAccount;
      Logger.info('SETTING_BACKEND', '保存无音影视默认账号');
      this.showToast('默认账号已保存');
    } catch (error) {
      Logger.error('SETTING_BACKEND', '保存默认账号失败：' + String(error));
      this.showOperationError('保存默认账号失败：' + String(error));
    } finally {
      this.savingBackendAccount = false;
    }
  }

  private async restoreBackendAccount(): Promise<void> {
    if (this.savingBackendAccount) { return; }
    this.savingBackendAccount = true;
    try {
      await this.appConfig.restoreBackendAccount();
      this.backendAccount = this.appConfig.backendAccount;
      Logger.info('SETTING_BACKEND', '恢复无音影视默认账号');
      this.showToast('默认账号已恢复');
    } catch (error) {
      Logger.error('SETTING_BACKEND', '恢复默认账号失败：' + String(error));
      this.showOperationError('恢复默认账号失败：' + String(error));
    } finally {
      this.savingBackendAccount = false;
    }
  }

  private refreshImageHost(): void {
    try {
      const config: ImageHostConfig = ImageHostService.current();
      this.imageHostUrl = config.uploadUrl || ImageHostService.DEFAULT_UPLOAD_URL;
      this.imageHostField = config.fieldName || ImageHostService.DEFAULT_FIELD_NAME;
      // 返回路径允许为空（接口直接返回纯文本直链），所以这里不能用 || 兜默认值。
      this.imageHostPath = config.responsePath;
      this.imageHostKey = config.apiKey;
      this.imageHostProxy = config.proxyUrl;
    } catch (error) {
      Logger.error('SETTING_IMAGE_HOST', '回填图床配置失败：' + String(error));
      this.showOperationError('读取图床配置失败：' + String(error));
    }
  }

  private async saveImageHost(): Promise<void> {
    if (this.savingImageHost) { return; }
    this.savingImageHost = true;
    try {
      await ImageHostService.save(this.imageHostUrl, this.imageHostField, this.imageHostPath, this.imageHostKey, this.imageHostProxy);
      const config: ImageHostConfig = ImageHostService.current();
      this.imageHostUrl = config.uploadUrl;
      this.imageHostField = config.fieldName;
      this.imageHostPath = config.responsePath;
      this.imageHostKey = config.apiKey;
      this.imageHostProxy = config.proxyUrl;
      this.showToast('图床配置已保存');
    } catch (error) {
      Logger.error('SETTING_IMAGE_HOST', '保存图床配置失败：' + String(error));
      this.showOperationError('保存图床配置失败：' + String(error));
    } finally {
      this.savingImageHost = false;
    }
  }

  /** 用输入框里的三个值直接试传一张图，结果就地展示；成功也不会自动保存配置。 */
  private async testImageHost(): Promise<void> {
    if (this.testingImageHost) { return; }
    this.testingImageHost = true;
    this.imageHostTestOk = false;
    this.imageHostTestText = '正在选择图片…';
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      const uris: string[] = selected.photoUris;
      if (uris.length === 0) {
        this.imageHostTestText = '已取消测试';
        return;
      }
      this.imageHostTestText = '正在上传测试…';
      const config: ImageHostConfig = new ImageHostConfig();
      config.uploadUrl = this.imageHostUrl.trim();
      config.fieldName = this.imageHostField.trim();
      config.responsePath = this.imageHostPath.trim();
      config.apiKey = this.imageHostKey.trim();
      config.proxyUrl = this.imageHostProxy.trim();
      const result: ImageHostResult = await ImageHostService.uploadWith(config, uris[0]);
      if (result.ok && result.url.length > 0) {
        this.imageHostTestOk = true;
        this.imageHostTestText = '上传成功（' + (result.host || '已配置图床') + '）：' + result.url;
        Logger.info('SETTING_IMAGE_HOST', '测试图床接口成功，图床=' + result.host);
      } else {
        const status: string = result.httpStatus > 0 ? '（HTTP ' + String(result.httpStatus) + '）' : '';
        this.imageHostTestText = '上传失败' + status + '：' + (result.message || '未知原因') +
          (result.notFound ? ' —— 接口 404，聊天页会要求手填直链' : '');
        Logger.error('SETTING_IMAGE_HOST', '测试图床接口失败：' + this.imageHostTestText);
      }
    } catch (error) {
      this.imageHostTestOk = false;
      this.imageHostTestText = '测试失败：' + String(error);
      Logger.error('SETTING_IMAGE_HOST', '测试图床接口异常：' + String(error));
    } finally {
      this.testingImageHost = false;
    }
  }

  private async restoreImageHost(): Promise<void> {
    if (this.savingImageHost) { return; }
    this.savingImageHost = true;
    try {
      await ImageHostService.restoreDefaults();
      const config: ImageHostConfig = ImageHostService.current();
      this.imageHostUrl = config.uploadUrl;
      this.imageHostField = config.fieldName;
      this.imageHostPath = config.responsePath;
      this.imageHostKey = config.apiKey;
      this.imageHostProxy = config.proxyUrl;
      this.showToast('已恢复默认图床接口');
    } catch (error) {
      Logger.error('SETTING_IMAGE_HOST', '恢复默认图床失败：' + String(error));
      this.showOperationError('恢复默认图床失败：' + String(error));
    } finally {
      this.savingImageHost = false;
    }
  }

  /**
   * 一键填入奶昔（Chevereto）官方 API v1 的三项配置，只用再粘自己的 key。
   * 奶昔的匿名 /api/upload 不存在，真正能用的就是这组值。
   */
  private applyNaishiPreset(): void {
    this.imageHostUrl = ImageHostService.DEFAULT_UPLOAD_URL;
    this.imageHostField = ImageHostService.DEFAULT_FIELD_NAME;
    this.imageHostPath = ImageHostService.DEFAULT_RESPONSE_PATH;
    if (this.imageHostKey.trim().length === 0) {
      this.imageHostKey = ImageHostService.DEFAULT_API_KEY;
    }
    this.imageHostTestText = '已填入奶昔 API v1 配置（未填 key 时用内置 key），可直接点「保存图床设置」或「测试接口」';
    this.imageHostTestOk = false;
    Logger.info('SETTING_IMAGE_HOST', '填入奶昔 API v1 预设配置');
  }

  private pageBackground(): ResourceColor {
    // 设置页与我的/消息/论坛共用主题资源底色：深 #FF212121，浅 #FFFFFFFF。
    return Ui.pageBg(this.darkTheme);
  }

  // 玻璃胶囊输入框的底色：统一走软玻璃，不再按深浅模式手写两种灰。
  private panelColor(): ResourceColor {
    return Ui.glassTintSoft(this.darkTheme);
  }

  private primaryText(): ResourceColor {
    return Ui.ink(this.darkTheme);
  }

  private secondaryText(): ResourceColor {
    return Ui.inkSoft(this.darkTheme);
  }

  private accentColor(): ResourceColor {
    return Ui.accent(this.darkTheme);
  }

  private updateConfig(): void {
    try {
      const nextConfig: PlayerImmersiveConfig = {
        immersiveEnable: this.immersiveEnabled,
          immersiveBlur: Number.isFinite(this.immersiveBlur) ? Math.max(0, Math.min(50, this.immersiveBlur)) : 20,
          immersiveOpacity: Number.isFinite(this.immersiveOpacity) ? Math.max(0.1, Math.min(1, this.immersiveOpacity)) : 0.8,
          autoColorEnable: this.immersiveConfig.autoColorEnable
      };
      AppState.config.enabled = nextConfig.immersiveEnable;
      AppState.config.blur = nextConfig.immersiveBlur;
      AppState.config.opacity = nextConfig.immersiveOpacity;
      AppState.config.dark = this.darkTheme;
      AppState.config.autoColorEnable = nextConfig.autoColorEnable;
      // 替换配置对象触发所有页面的 StorageLink，同时沿用原 Preferences 归档。
      this.immersiveConfig = nextConfig;
      void AppState.save().catch((error: Error) => {
        Logger.error('SETTING_IMMERSIVE', '保存全局沉浸配置失败：' + String(error));
        this.showOperationError('保存沉浸设置失败：' + String(error));
      });
      // 毛玻璃关闭后系统导航区域仍透明，小白条仍保留。
      void ImmersiveService.apply();
    } catch (error) {
      Logger.error('SETTING_IMMERSIVE', '更新全局沉浸配置失败：' + String(error));
      this.showOperationError('更新沉浸设置失败：' + String(error));
    }
  }

  private updateLogging(value: boolean): void {
    Logger.enabled = value;
    AppState.save();
    Logger.info('SETTING', value ? '开启运行日志' : '关闭运行日志');
  }

  /** 聊天提醒三开关统一落盘，避免三个布尔值分叉。 */
  private applyChatNotice(sound: boolean, banner: boolean, dnd: boolean): void {
    try {
      this.chatSoundEnabled = sound;
      this.chatBannerEnabled = banner;
      this.chatDndEnabled = dnd;
      void AppState.setChatNoticeOptions(sound, banner, dnd).catch((error: Error) => {
        Logger.error('SETTING_CHAT', '保存聊天提醒设置失败：' + String(error));
        this.showOperationError('保存聊天提醒设置失败：' + String(error));
      });
    } catch (error) {
      Logger.error('SETTING_CHAT', '更新聊天提醒设置失败：' + String(error));
      this.showOperationError('更新聊天提醒设置失败：' + String(error));
    }
  }

  /** 设置页「聊天提醒 · 后台通知栏提醒」：立即生效，并顺便确认系统通知权限。 */
  private applyBackgroundNotify(value: boolean): void {
    try {
      this.chatBackgroundNotify = value;
      void AppState.setChatBackgroundNotify(value).catch((error: Error) => {
        Logger.error('SETTING_CHAT', '保存后台通知设置失败：' + String(error));
        this.showOperationError('保存后台通知设置失败：' + String(error));
      });
      ChatAlertService.refreshBackgroundMode();
      if (!value) {
        Logger.info('BUTTON', '关闭后台通知栏提醒');
        this.showToast('已关闭后台通知栏提醒');
        return;
      }
      Logger.info('BUTTON', '开启后台通知栏提醒');
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      void NotificationService.ensurePermission(context).then((granted: boolean) => {
        if (!granted) {
          this.showToast('未获得通知权限，后台提醒暂不可用');
        } else {
          this.showToast('已开启后台通知栏提醒');
        }
      }).catch((error: Error) => {
        Logger.warn('SETTING_CHAT', '确认通知权限失败：' + String(error));
      });
    } catch (error) {
      Logger.error('SETTING_CHAT', '更新后台通知设置失败：' + String(error));
      this.showOperationError('更新后台通知设置失败：' + String(error));
    }
  }

  /** 提醒弹窗位置：锚点（顶部/居中/底部）+ 垂直微调，立即发布到全局并落盘。 */
  private applyAlertPlacement(position: string, offset: number): void {
    try {
      const nextPosition: string = position === 'center' || position === 'bottom' ? position : 'top';
      const nextOffset: number = Number.isFinite(offset) ? Math.max(0, Math.min(200, Math.round(offset))) : 0;
      this.chatAlertPosition = nextPosition;
      this.chatAlertOffset = nextOffset;
      void AppState.setChatAlertPlacement(nextPosition, nextOffset).catch((error: Error) => {
        Logger.error('SETTING_CHAT', '保存提醒弹窗位置失败：' + String(error));
        this.showOperationError('保存提醒弹窗位置失败：' + String(error));
      });
      Logger.info('BUTTON', '提醒弹窗位置=' + nextPosition + '，垂直微调=' + String(nextOffset) + 'vp');
    } catch (error) {
      Logger.error('SETTING_CHAT', '更新提醒弹窗位置失败：' + String(error));
      this.showOperationError('更新提醒弹窗位置失败：' + String(error));
    }
  }

  /** 界面尺寸：Dock 缩放与字体缩放同时写回，供底栏与全部页面即时跟随。 */
  private applyUiScale(dock: number, font: number): void {
    try {
      const nextDock: number = Ui.dockScale(dock);
      const nextFont: number = Ui.fontScale(font);
      // 先改状态：拖动过程中界面（含数值气泡、预览、全页字号）立刻跟着变。
      this.dockScale = nextDock;
      this.fontScale = nextFont;
      // 每一帧都写 preferences 会拖慢拖动，停手 200ms 后统一落盘。
      if (this.scaleSaveTimer >= 0) { clearTimeout(this.scaleSaveTimer); }
      this.scaleSaveTimer = setTimeout(() => {
        this.scaleSaveTimer = -1;
        void AppState.setUiScales(this.dockScale, this.fontScale).catch((error: Error) => {
          Logger.error('SETTING_UI_SCALE', '保存界面尺寸失败：' + String(error));
          this.showOperationError('保存界面尺寸失败：' + String(error));
        });
      }, 200);
    } catch (error) {
      Logger.error('SETTING_UI_SCALE', '更新界面尺寸失败：' + String(error));
      this.showOperationError('更新界面尺寸失败：' + String(error));
    }
  }

  private restoreUiScale(): void {
    try {
      if (this.scaleSaveTimer >= 0) {
        clearTimeout(this.scaleSaveTimer);
        this.scaleSaveTimer = -1;
      }
      this.dockScale = 1;
      this.fontScale = 1;
      void AppState.restoreUiScales().catch((error: Error) => {
        Logger.error('SETTING_UI_SCALE', '恢复默认界面尺寸失败：' + String(error));
      });
      this.showToast('已恢复默认界面尺寸');
    } catch (error) {
      Logger.error('SETTING_UI_SCALE', '恢复默认界面尺寸失败：' + String(error));
    }
  }

  private previewSound(): void {
    if (this.chatDndEnabled) {
      this.showToast('免打扰已开启，提示音不会播放');
      return;
    }
    if (!this.chatSoundEnabled) {
      this.showToast('消息提示音已关闭，请先开启');
      return;
    }
    this.showToast(ChatAlertService.previewSound() ? '正在播放提示音' : '提示音资源不可用');
  }

  private previewBanner(): void {
    if (this.chatDndEnabled) {
      this.showToast('免打扰已开启，顶部弹窗不会出现');
      return;
    }
    if (!this.chatBannerEnabled) {
      this.showToast('顶部弹窗已关闭，请先开启');
      return;
    }
    ChatAlertService.previewBanner();
    this.showToast('已发送一条示例提醒');
  }

  private resetSettings(): void {
    try {
      this.immersiveEnabled = true;
      this.immersiveBlur = 20;
      this.immersiveOpacity = 0.8;
      this.darkTheme = false;
      this.immersiveConfig = { immersiveEnable: true, immersiveBlur: 20, immersiveOpacity: 0.8, autoColorEnable: true };
      this.updateConfig();
      void AppState.setThemeMode('light');
      Logger.info('BUTTON', '恢复默认沉浸设置');
      this.showToast('已恢复默认设置');
    } catch (error) {
      Logger.error('SETTING_IMMERSIVE', '恢复沉浸设置失败：' + String(error));
      this.showOperationError('恢复默认设置失败：' + String(error));
    }
  }

  private showToast(message: string): void {
    this.toastText = message;
    setTimeout(() => { this.toastText = ''; }, 2200);
  }

  // ---------------- 壁纸设置 ----------------

  /** 当前背景文案：本地导入资源优先，其次内置渐变壁纸，最后跟随主题。 */
  private wallpaperSummary(): string {
    if (this.wallpaperMediaId.length > 0 && this.wallpaperMediaName.length > 0) {
      return WallpaperKind.label(this.wallpaperMediaKind) + '「' + this.wallpaperMediaName + '」';
    }
    const name: string = ThemeService.backgroundName();
    return name.length > 0 ? '内置壁纸「' + name + '」' : '跟随当前主题背景';
  }

  private openWallpaperPage(): void {
    router.pushUrl({ url: 'pages/WallpaperPage' }).catch((error: Error) => {
      Logger.error('SETTING_WALLPAPER', '打开壁纸页失败：' + String(error));
      this.showOperationError('打开壁纸页失败：' + String(error));
    });
  }

  /** 直接在设置页导入本地图片 / GIF / 视频背景，导入后自动应用第一个文件。 */
  private async importWallpaper(): Promise<void> {
    if (this.wallpaperImporting) {
      return;
    }
    this.wallpaperImporting = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const created: WallpaperMedia[] = await WallpaperService.importFromPicker(context);
      if (created.length === 0) {
        this.showToast('未选择文件，或文件格式不支持');
        return;
      }
      const first: WallpaperMedia = created[0];
      if (ThemeService.applyImportedWallpaper(first.id)) {
        this.showToast('已导入并应用' + WallpaperKind.label(first.kind) + '「' + first.name + '」');
      } else {
        this.showToast('已导入，但应用失败');
      }
    } catch (error) {
      Logger.error('SETTING_WALLPAPER', '导入背景失败：' + String(error));
      this.showToast('导入失败，请重新选择文件');
    } finally {
      this.wallpaperImporting = false;
    }
  }

  private clearWallpaper(): void {
    try {
      ThemeService.clearBackground();
      this.showToast('已恢复主题默认背景');
    } catch (error) {
      Logger.error('SETTING_WALLPAPER', '清空背景失败：' + String(error));
      this.showOperationError('清空背景失败：' + String(error));
    }
  }

  private showErrorDialog(title: string, message: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: title,
        message: message,
        buttons: [{ text: '确定', color: Ui.accent(this.darkTheme) }]
    });
  }

  private showOperationError(message: string): void {
    this.showToast(message);
    this.showErrorDialog('操作失败', message);
  }

  private showSourceError(message: string): void {
    // 修复 10505001：对话框按钮的 color 只接受 string | Resource，不能传 ResourceColor。
    this.showToast(message);
    this.showErrorDialog('搜索源操作失败', message);  }



  // 自定义远端地址：保存至持久化配置，搜索页面进入时读取并请求该地址。
  private async saveSourceAddress(): Promise<void> {
    if (this.savingAddress) { return; }
    this.savingAddress = true;
    try {
      await SearchSources.saveAddress(this.remoteAddress);
      this.remoteAddress = SearchSources.currentAddress();
      Logger.info('SearchEngineLoad', '设置页已保存自定义远端地址');
      this.showToast('远端搜索源地址已保存');
    } catch (error) {
      Logger.error('SearchEngineLoad', '保存远端地址失败：' + String(error));
      this.showSourceError('保存地址失败：' + String(error));
    } finally {
      this.savingAddress = false;
    }
  }

  // 搜索源导入：与搜索页共用文件名校验、导入锁、合并和全局实时发布逻辑。
  private async importSourceFile(): Promise<void> {
    if (this.importingSource) { return; }
    this.importingSource = true;
    try {
      const selected: boolean = await SearchSources.importFile(getContext(this) as common.UIAbilityContext);
      if (selected) { this.showToast('搜索源导入成功，线路已更新'); }
    } catch (error) {
      Logger.error('SearchEngineLoad', '设置页导入失败：' + String(error));
      this.showSourceError('导入失败：' + String(error));
    } finally {
      this.importingSource = false;
      this.refreshCustomRules();
    }
  }

  private exportLongPressAt: number = 0;
  private exportPressTimer: number = -1;

  private clearExportPressTimer(): void {
    if (this.exportPressTimer !== -1) {
      clearTimeout(this.exportPressTimer);
      this.exportPressTimer = -1;
    }
  }

  private enabledRulesForExport(): SearchSource[] {
    // 合并页面状态与 SearchSources 缓存，避免只导出当前已渲染的部分线路。
    const byId: Map<number, SearchSource> = new Map<number, SearchSource>();
    SearchSources.managedList().forEach((item: SearchSource) => {
      if (item.enabled === false || this.disabledRuleIds.indexOf(item.id) >= 0) { return; }
      byId.set(item.id, item);
    });
    this.customRules.forEach((item: SearchSource) => {
      if (!this.isRuleEnabled(item)) {
        byId.delete(item.id);
        return;
      }
      byId.set(item.id, item);
    });
    return Array.from(byId.values());
  }

  private async shareEnabledRules(): Promise<void> {
    try {
      const exportable: SearchSource[] = this.enabledRulesForExport();
      if (exportable.length === 0) {
        this.showToast('没有已启用的自定义线路');
        return;
      }
      const json: string = JSON.stringify({
        version: 1,
        count: exportable.length,
        userlist: exportable
      });
      const parts: string[] = await SourceShareCodec.encode(json);
      AppStorage.setOrCreate<string[]>('sourceShareParts', parts);
      AppStorage.setOrCreate<string>('sourceShareJson', json);
      const cover: string = AppStorage.get<string>('wallpaperMediaUri') || '';
      router.pushUrl({
        url: 'pages/ShareQrPage',
        params: {
          link: 'wuyin://sources',
          qrLink: '',
          title: '无音影视资源线路',
          subtitle: '共 ' + String(exportable.length) + ' 线路',
          cover: cover,
          sourceMode: true
        }
      }).catch((error: Error) => {
        Logger.error('SearchEngineLoad', '打开线路分享二维码失败：' + String(error));
        this.showToast('打开分享二维码失败');
      });
    } catch (error) {
      Logger.error('SearchEngineLoad', '生成线路分享数据失败：' + String(error));
      this.showToast(String(error));
    }
  }

  // 搜索源导出：只导出已启用的自定义线路，文件名固定为 无音影视资源线路.json。
  private async exportEnabledRules(): Promise<void> {
    if (Date.now() - this.exportLongPressAt < 800) { return; }
    try {
      const exportable: SearchSource[] = this.enabledRulesForExport();
      const exported: boolean = await SearchSources.exportEnabled(
        getContext(this) as common.UIAbilityContext, exportable);
      if (exported) {
        this.showToast('已导出 ' + String(exportable.length) + ' 条：' + SearchSources.IMPORT_FILENAME);
      }
    } catch (error) {
      Logger.error('SearchEngineLoad', '设置页导出失败：' + String(error));
      this.showSourceError('导出失败：' + String(error));
    }
  }

  /** 同步自定义规则列表到页面状态。 */
  private refreshCustomRules(): void {
    try {
      this.customRules = SearchSources.managedList();
      this.disabledRuleIds = this.customRules
        .filter((item: SearchSource): boolean => item.enabled === false)
        .map((item: SearchSource): number => item.id);
    }
    catch (error) { Logger.warn('SearchEngineLoad', '读取自定义规则失败：' + String(error)); }
  }

  private isRuleEnabled(rule: SearchSource): boolean {
    return this.disabledRuleIds.indexOf(rule.id) < 0;
  }

  private setLocalRuleEnabled(id: number, enabled: boolean): void {
    if (enabled) {
      this.disabledRuleIds = this.disabledRuleIds.filter((value: number): boolean => value !== id);
    } else if (this.disabledRuleIds.indexOf(id) < 0) {
      this.disabledRuleIds = this.disabledRuleIds.concat([id]);
    }
  }

  /** 添加一条自定义规则（名称 + 接口地址），成功后清空表单。 */
  /** 导入 TVBox 配置：拉配置 JSON，把 sites 批量加进自定义规则。 */
  private async importTvbox(): Promise<void> {
    const url: string = this.customRuleUrl.trim();
    if (!/^https?:\/\//i.test(url)) {
      this.showSourceError('请先在上面的地址栏填写 TVBox 配置地址');
      return;
    }
    try {
      const request = http.createHttp();
      let body: string = '';
      try {
        const response = await request.request(url, {
          method: http.RequestMethod.GET, connectTimeout: 8000, readTimeout: 12000
        });
        body = String(response.result || '');
      } finally {
        request.destroy();
      }
      const sites: TvboxSite[] = SourceRules.parseTvbox(body);
      let added: number = 0;
      for (const site of sites) {
        if (added >= 60) { break; }
        try {
          const ruleJson: string = site.playUrl.length > 0
            ? JSON.stringify({ 'playProxy': site.playUrl }) : '';
          await SearchSources.addCustom(site.name, site.api, '', 'cms', ruleJson);
          added++;
        } catch (error) {
          // 重复接口跳过，不打断批量导入。
        }
      }
      this.refreshCustomRules();
      this.showToast('已从 TVBox 配置导入 ' + String(added) + ' 条源');
    } catch (error) {
      this.showSourceError('导入 TVBox 配置失败：' + String(error));
    }
  }

  /** 单条线路启用/停用：先即时切换按钮文字，再持久化，失败回滚。 */
  private async toggleRule(rule: SearchSource): Promise<void> {
    const nextEnabled: boolean = !this.isRuleEnabled(rule);
    const previousDisabled: number[] = this.disabledRuleIds;
    this.setLocalRuleEnabled(rule.id, nextEnabled);
    try {
      await SearchSources.setEnabled([rule.id], nextEnabled);
      this.showToast(nextEnabled ? '已启用「' + rule.name + '」' : '已停用「' + rule.name + '」');
    } catch (error) {
      this.disabledRuleIds = previousDisabled;
      this.showSourceError('切换线路状态失败：' + String(error));
    }
  }

  /** 批量启用/停用：同样即时刷新每一行的按钮文字。 */
  private async setRulesEnabled(enabled: boolean): Promise<void> {
    if (this.selectedRuleIds.length === 0) { return; }
    const previousDisabled: number[] = this.disabledRuleIds;
    for (const id of this.selectedRuleIds) {
      this.setLocalRuleEnabled(id, enabled);
    }
    try {
      await SearchSources.setEnabled(this.selectedRuleIds, enabled);
      this.showToast((enabled ? '已启用 ' : '已停用 ') + String(this.selectedRuleIds.length) + ' 条线路');
    } catch (error) {
      this.disabledRuleIds = previousDisabled;
      this.showSourceError('批量更新失败：' + String(error));
    }
  }

  /** 批量删除。 */
  private async removeSelectedRules(): Promise<void> {
    if (this.selectedRuleIds.length === 0) { return; }
    try {
      const count: number = await SearchSources.removeMany(this.selectedRuleIds);
      this.selectedRuleIds = [];
      this.refreshCustomRules();
      this.showToast('已删除 ' + String(count) + ' 条线路');
    } catch (error) {
      this.showSourceError('批量删除失败：' + String(error));
    }
  }

  /** 切换 DNS 解析模式并持久化。 */
  /** 用当前 DNS 模式实测一次解析，并把结果写回界面。 */
  private async probeDns(): Promise<void> {
    this.dnsProbeResult = '正在测试…';
    try {
      const result: string = await DnsService.probe('https://www.baidu.com/');
      this.dnsProbeResult = result;
      this.showToast(result);
      Logger.info('SETTING_DNS', 'DNS 测试结果：' + result);
    } catch (error) {
      this.dnsProbeResult = '测试失败：' + String(error);
    }
  }

  private async changeDnsMode(mode: string): Promise<void> {
    try {
      await DnsService.setMode(mode);
      this.dnsMode = DnsService.current();
      this.showToast('DNS 已切换为：' + DnsService.label(this.dnsMode));
    } catch (error) {
      this.showSourceError('切换 DNS 失败：' + String(error));
    }
  }

  private async addCustomRule(): Promise<void> {
    if (this.savingCustomRule) { return; }
    this.savingCustomRule = true;
    this.customRuleHint = '';
    try {
      const item: SearchSource = await SearchSources.addCustom(this.customRuleName, this.customRuleUrl, '',
        this.customRuleKind, this.customRuleRule);
      this.refreshCustomRules();
      this.customRuleName = '';
      this.customRuleUrl = '';
      this.customRuleHint = '已添加「' + item.name + '」，搜索页下一次搜索就会带上这条规则。';
      this.showToast('自定义规则已添加');
    } catch (error) {
      Logger.error('SearchEngineLoad', '添加自定义规则失败：' + String(error));
      this.customRuleHint = String(error);
    } finally {
      this.savingCustomRule = false;
    }
  }

  /** 删除一条自定义规则。 */
  private async removeCustomRule(id: number): Promise<void> {
    try {
      await SearchSources.removeCustom(id);
      this.refreshCustomRules();
      this.customRuleHint = '已删除该规则。';
      this.showToast('已删除自定义规则');
    } catch (error) {
      Logger.error('SearchEngineLoad', '删除自定义规则失败：' + String(error));
      this.customRuleHint = String(error);
    }
  }

  /** 试连当前填写的接口，结果直接显示在提示行。 */
  private async probeCustomRule(): Promise<void> {
    const target: string = this.customRuleUrl.trim().length > 0 ? this.customRuleUrl.trim() : this.remoteAddress;
    this.customRuleHint = '正在测试 ' + target + ' …';
    this.customRuleHint = await SearchSources.probe(target);
    Logger.info('SearchEngineLoad', '接口测试：' + this.customRuleHint);
  }

  // 只解析行内级别标签；旧日志或解析异常均以正文色显示。
  private logLineColor(line: string): ResourceColor {
    try {
      const match: RegExpMatchArray | null = line.match(/\[(INFO|WARN|ERROR)\]/);
      if (match === null) { return this.primaryText(); }
      if (match[1] === 'INFO') { return Ui.success(this.darkTheme); }
      if (match[1] === 'WARN') { return Ui.gold(this.darkTheme); }
      if (match[1] === 'ERROR') { return Ui.danger(this.darkTheme); }
    } catch (error) {
      Logger.error('SETTING_LOG_PARSE', String(error));
      this.showOperationError('日志解析失败：' + String(error));
    }
    return this.primaryText();
  }

  private openLogs(): void {
    try {
      this.logText = Logger.read();
      this.logSource.setLines(this.logText.split('\n'));
      this.showLogDialog = true;
      Logger.info('BUTTON', '查看运行日志');
    } catch (error) {
      Logger.error('SETTING', String(error));
      this.logText = '读取日志失败：' + String(error);
      this.logSource.setLines([this.logText]);
      this.showLogDialog = true;
      this.showOperationError('读取日志失败：' + String(error));
    }
  }

  private clearLogs(): void {
    try {
      Logger.clear();
      this.logText = '';
      this.logSource.setLines([]);
      this.showClearDialog = false;
      this.showToast('日志已清空');
    } catch (error) {
      Logger.error('SETTING', String(error));
      this.showOperationError('清空日志失败：' + String(error));
    }
  }

  /** 导出全部聊天记录（文件选择器保存 JSON）。 */
  private async exportChatArchive(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const rooms: string[] = [];
      for (const room of SocialStore.roomsList()) { rooms.push(room.name); }
      const peers: string[] = [];
      const session = await CommunityApi.readSession();
      if (session.valid()) {
        const friends = await AccountApi.mutualFriends(session.user, session.pass);
        for (const friend of friends) { peers.push(friend.user); }
      }
      const path: string = await ChatArchive.exportAll(context, rooms, peers);
      Logger.info('SETTING', path.length > 0 ? '聊天记录导出成功：' + path : '用户取消导出');
    } catch (error) {
      Logger.error('SETTING', '导出聊天记录失败：' + String(error));
    }
  }

  /** 导入聊天记录 JSON。 */
  private async importChatArchive(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const count: number = await ChatArchive.importFrom(context);
      Logger.info('SETTING', '聊天记录导入完成，会话数=' + String(count));
    } catch (error) {
      Logger.error('SETTING', '导入聊天记录失败：' + String(error));
    }
  }

  private async copyLogs(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText));
      this.showToast('已复制全部日志');
      Logger.info('BUTTON', '复制全部运行日志');
    } catch (error) {
      Logger.error('SETTING_LOG_COPY', String(error));
      this.showOperationError('复制日志失败：' + String(error));
    }
  }

  private async exportLogs(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const success: boolean = await Logger.export(context);
      this.showToast(success ? '日志已导出，请在系统文件中查看' : '已取消导出');
      if (success) { Logger.info('BUTTON', '导出运行日志'); }
    } catch (error) {
      Logger.error('EXPORT', String(error));
      this.showOperationError('导出日志失败：' + String(error));
    }
  }

  private navTabVisible(key: string): boolean {    return this.navTabKeys.includes(key);
  }

  /** 界面尺寸预览里高亮哪个 Tab：与真实底栏一致，取当前页面在底栏中的位置。 */
  private previewActiveIndex(): number {
    const routes: string[] = NavTabs.sanitize(this.navTabKeys);
    const found: number = routes.indexOf(this.currentPage);
    return found >= 0 ? found : 0;
  }

  private navTabIndex(key: string): number {
    return this.navTabKeys.indexOf(key);
  }

  private toggleNavTab(key: string, selected: boolean): void {
    try {
      const changed: boolean = NavTabs.setEnabled(key, selected);
      if (!changed && NavTabs.locked(key)) {
        this.showToast(NavTabs.title(key) + '为固定入口，不能隐藏');
      } else if (!changed && !selected) {
        this.showToast('至少保留两个底部入口');
      } else if (changed) {
        this.showToast((selected ? '已显示' : '已隐藏') + NavTabs.title(key));
        // 隐藏的正是当前页时回到“我的”，避免底栏没有对应高亮项。
        if (!selected && this.currentPage === key) {
          AppState.go('mine');
        }
      }
    } catch (error) {
      Logger.error('SETTING_NAV', '更新底部导航显示项失败：' + String(error));
      this.showOperationError('更新底部导航失败：' + String(error));
    }
  }

  private moveNavTab(key: string, delta: number): void {
    try {
      if (NavTabs.move(key, delta)) {
        this.showToast('已调整' + NavTabs.title(key) + '的顺序');
      }
    } catch (error) {
      Logger.error('SETTING_NAV', '调整底部导航顺序失败：' + String(error));
      this.showOperationError('调整底部导航顺序失败：' + String(error));
    }
  }

  private restoreNavTabs(): void {
    try {
      NavTabs.reset();
      this.showToast('已恢复默认底部导航');
    } catch (error) {
      Logger.error('SETTING_NAV', '恢复默认底部导航失败：' + String(error));
      this.showOperationError('恢复默认底部导航失败：' + String(error));
    }
  }

  // 切换设置分类：沿用原来的选中逻辑、回顶动作与日志记录。
  private selectMenu(title: string): void {
    if (title === '更新日志') {
      void router.pushUrl({ url: 'pages/UpdateLogPage' }).catch((error: Error) => {
        Logger.error('SETTING_UPDATE_LOG', '打开更新日志失败：' + String(error));
      });
      return;
    }
    this.activeMenu = title;
    this.pageScroller.scrollEdge(Edge.Top);
    Logger.info('BUTTON', '切换设置菜单：' + title);
  }

  // ---------------- 视觉层 ----------------

  @Builder
  private menuItem(title: string, icon: Resource) {
    Row({ space: '10vp' }) {
      SymbolGlyph(icon)
        .fontSize(Ui.fs('17vp', this.fontScale))
        .fontColor([this.activeMenu === title ? Ui.accent(this.darkTheme) : Ui.inkFaint(this.darkTheme)])
      Text(title)
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontWeight(this.activeMenu === title ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeMenu === title ? Ui.ink(this.darkTheme) : this.secondaryText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.activeMenu === title) {
        Text('›').fontSize(Ui.fs('18vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
      }
    }
      .width('100%')
      .height('52vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius(Ui.R_MD)
      .backgroundColor(this.activeMenu === title ? Ui.accentSoft(this.darkTheme) : Color.Transparent)
      .border({
        width: 1,
        color: this.activeMenu === title ? Ui.glassRingAccent(this.darkTheme) : Color.Transparent
      })
      .onClick(() => { this.selectMenu(title); })
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private menuChip(title: string, icon: Resource) {
    Row({ space: '6vp' }) {
      SymbolGlyph(icon)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor([this.activeMenu === title ? Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme)])
      Text(title)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontWeight(this.activeMenu === title ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeMenu === title ? Ui.accentStrong(this.darkTheme) : this.secondaryText())
        .maxLines(1)
    }
      .height('36vp')
      .padding({ left: '13vp', right: '13vp' })
      .borderRadius('18vp')
      .backgroundColor(this.activeMenu === title ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.activeMenu === title ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
      .onClick(() => { this.selectMenu(title); })
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  // 手机：顶部横向滚动玻璃分段菜单，分类方向与原侧栏一致。
  @Builder
  private menuChips() {
    Scroll() {
      Row({ space: '8vp' }) {
        this.menuChip('沉浸外观', SymbolIcons.palette())
        this.menuChip('壁纸设置', SymbolIcons.image())
        this.menuChip('账号中心', SymbolIcons.wallet())
        this.menuChip('界面尺寸', SymbolIcons.category(false))
        this.menuChip('聊天提醒', SymbolIcons.bell())
        this.menuChip('底部导航', SymbolIcons.list())
        this.menuChip('无音影视后端', SymbolIcons.doc())
        this.menuChip('图床设置', SymbolIcons.image())
        this.menuChip('直链设置', SymbolIcons.terminal())
        this.menuChip('帧数设置', SymbolIcons.play())
        this.menuChip('音频管理', SymbolIcons.music())
        this.menuChip('播放器设置', SymbolIcons.play())
        this.menuChip('搜索源管理', SymbolIcons.search())
        this.menuChip('运行日志', SymbolIcons.list())
        this.menuChip('更新日志', SymbolIcons.doc())
      }
        .padding({ top: '2vp', bottom: '2vp' })
    }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height('40vp')
  }

  // 平板：左侧玻璃侧栏。
  @Builder
  private sideMenu() {
    Column({ space: '4vp' }) {
      Text('设置菜单')
        .fontSize(Ui.fs('12vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ left: '12vp', bottom: '6vp' })
      this.menuItem('沉浸外观', SymbolIcons.palette())
      this.menuItem('壁纸设置', SymbolIcons.image())
      this.menuItem('账号中心', SymbolIcons.wallet())
      this.menuItem('界面尺寸', SymbolIcons.category(false))
      this.menuItem('聊天提醒', SymbolIcons.bell())
      this.menuItem('底部导航', SymbolIcons.list())
      this.menuItem('无音影视后端', SymbolIcons.doc())
      this.menuItem('图床设置', SymbolIcons.image())
      this.menuItem('直链设置', SymbolIcons.terminal())
      this.menuItem('帧数设置', SymbolIcons.play())
      this.menuItem('音频管理', SymbolIcons.music())
      this.menuItem('播放器设置', SymbolIcons.play())
      this.menuItem('搜索源管理', SymbolIcons.search())
      this.menuItem('运行日志', SymbolIcons.list())
      this.menuItem('更新日志', SymbolIcons.doc())
    }
      .width('220vp')
      .padding('10vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
  }

  @Builder
  private panelHeader(title: string, subtitle: string) {
    Column({ space: '3vp' }) {
      Text(title)
        .fontSize(Ui.fs(this.isTablet ? '22vp' : '19vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(Ui.fs(this.isTablet ? '13vp' : '11.5vp', this.fontScale))
          .lineHeight(this.isTablet ? '19vp' : '17vp')
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: '4vp' })
  }

  @Builder
  private rowDivider() {
    Divider()
      .strokeWidth(1)
      .color(Ui.divider(this.darkTheme))
      .width('100%')
  }

  @Builder
  private switchRow(title: string, subtitle: string, value: boolean, changed: (value: boolean) => void) {
    Row({ space: '12vp' }) {
      Column({ space: '3vp' }) {
        Text(title)
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .width('100%')
        Text(subtitle)
          .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
          .lineHeight(this.isTablet ? '18vp' : '16vp')
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Ui.accent(this.darkTheme))
        .onChange((checked: boolean) => changed(checked))
        .transition(TransitionEffect.OPACITY)
    }
      .width('100%')
      .padding({ top: '12vp', bottom: '12vp' })
      .constraintSize({ minHeight: 54 })
      .alignItems(VerticalAlign.Center)
  }

  @Builder
  private actionButton(title: string, icon: Resource, action: () => void) {
    Row({ space: '5vp' }) {
      SymbolGlyph(icon)
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontColor([this.accentColor()])
      Text(title)
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .height('44vp')
      .layoutWeight(1)
      .padding({ left: '10vp', right: '10vp' })
      .justifyContent(FlexAlign.Center)
      .borderRadius('22vp')
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
      .shadow({
        radius: this.pressedAction === title ? 12 : 6,
        color: this.pressedAction === title ? Ui.accentGlow(this.darkTheme) : Ui.shadowSoft(this.darkTheme),
        offsetY: 2
      })
      .scale({ x: this.pressedAction === title ? 0.96 : 1, y: this.pressedAction === title ? 0.96 : 1 })
      .onTouch((event: TouchEvent) => {
        this.pressedAction = event.type === TouchType.Down ? title : '';
      })
      .onClick(action)
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .transition(TransitionEffect.OPACITY)
  }

  // 玻璃胶囊输入框：高 46、圆角 23、软玻璃底，聚焦时换成品牌描边。
  @Builder
  private glassInput(field: string, text: string, placeholder: string, changed: (value: string) => void) {
      TextInput({ text: text, placeholder: placeholder })
      .width('100%')
      .height(46)
      .fontSize(Ui.fs('14vp', this.fontScale))
      .fontColor(Ui.ink(this.darkTheme))
      .placeholderColor(Ui.inkFaint(this.darkTheme))
      .caretColor(Ui.accent(this.darkTheme))
      .backgroundColor(this.panelColor())
      .borderRadius(23)
      .border({
        width: 1,
        color: this.focusedField === field ? Ui.accentRing(this.darkTheme) : Ui.glassRingSoft(this.darkTheme)
      })
      .shadow({
        radius: this.focusedField === field ? 16 : 0,
        color: this.focusedField === field ? Ui.accentGlow(this.darkTheme) : Ui.glassSheenClear(),
        offsetY: 4
      })
      .padding({ left: '16vp', right: '16vp' })
      .onFocus(() => { this.focusedField = field; })
      .onBlur(() => { this.focusedField = ''; })
      .onChange((value: string) => changed(value))
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  /** API Key 输入框：固定密码态（圆点），不提供显示明文的入口。 */
  @Builder
  private glassKeyInput(field: string, text: string, placeholder: string,
    changed: (value: string) => void) {
    TextInput({ text: text, placeholder: placeholder })
      .width('100%')
      .height(46)
      .type(InputType.Password)
      .showPasswordIcon(false)
      .fontSize(Ui.fs('14vp', this.fontScale))
      .fontColor(Ui.ink(this.darkTheme))
      .placeholderColor(Ui.inkFaint(this.darkTheme))
      .caretColor(Ui.accent(this.darkTheme))
      .backgroundColor(this.panelColor())
      .borderRadius(23)
      .border({
        width: 1,
        color: this.focusedField === field ? Ui.accentRing(this.darkTheme) : Ui.glassRingSoft(this.darkTheme)
      })
      .padding({ left: '16vp', right: '16vp' })
      .onFocus(() => { this.focusedField = field; })
      .onBlur(() => { this.focusedField = ''; })
      .onChange((value: string) => changed(value))
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private sourcePanel() {
    Column() {
      this.panelHeader('搜索源管理', '自定义远端搜索源地址，或导入本地线路文件')
      this.rowDivider()
      Row() {
        SettingField({ field: 'source', value: $remoteAddress, placeholder: 'https://你的接口地址（留空则只用导入/自定义规则）', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'source', onFocusChange: (on: boolean) => { this.focusedField = on ? 'source' : ''; }, onChange: (value: string) => {
          this.remoteAddress = value;
        } })
      }
        .width('100%')
        .padding({ top: '12vp' })
      Row({ space: '10vp' }) {
        PrimaryButton({ label: '保存地址', compact: true, onTap: (): void => { void this.saveSourceAddress(); } })
        GhostButton({ label: '导入搜索源', compact: true, onTap: (): void => { void this.importSourceFile(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
      Text('导入文件名必须为：' + SearchSources.IMPORT_FILENAME)
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp' })
      this.rowDivider()
      // 自定义规则：不依赖 JSON 文件，直接填名称 + 接口地址就能加一条搜索源。
      Column({ space: '10vp' }) {
        Row({ space: '8vp' }) {
          Text('自定义规则')
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .layoutWeight(1)
          Text('导出全部')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .height('28vp')
            .padding({ left: '10vp', right: '10vp' })
            .borderRadius('14vp')
            .backgroundColor(Ui.accentSoft(this.darkTheme))
            .onClick(() => { void this.exportEnabledRules(); })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.clearExportPressTimer();
                this.exportPressTimer = setTimeout(() => {
                  this.exportPressTimer = -1;
                  this.exportLongPressAt = Date.now();
                  void this.shareEnabledRules();
                }, 3000);
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.clearExportPressTimer();
              }
            })
          Text(String(this.customRules.length) + ' 条')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .width('100%')
          .padding({ top: '12vp' })
        if (this.customRules.length > 0) {
        // 线路管理：支持勾选批量删除、批量启用/停用（停用的线路不参与搜索）。
        Row({ space: '8vp' }) {
          Text('全选')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(this.ruleManageMode ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
            .height('28vp')
            .padding({ left: '10vp', right: '10vp' })
            .borderRadius('14vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .onClick(() => {
              this.ruleManageMode = !this.ruleManageMode;
              this.selectedRuleIds = this.ruleManageMode ? this.customRules.map((item: SearchSource) => item.id) : [];
            })
          Blank()
          if (this.ruleManageMode && this.selectedRuleIds.length > 0) {
            Text('启用')
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.accentStrong(this.darkTheme))
              .height('28vp')
              .padding({ left: '10vp', right: '10vp' })
              .borderRadius('14vp')
              .backgroundColor(Ui.accentSoft(this.darkTheme))
              .onClick(() => { void this.setRulesEnabled(true); })
            Text('停用')
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor(Ui.inkSoft(this.darkTheme))
              .height('28vp')
              .padding({ left: '10vp', right: '10vp' })
              .borderRadius('14vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .onClick(() => { void this.setRulesEnabled(false); })
            Text('删除(' + String(this.selectedRuleIds.length) + ')')
              .fontSize(Ui.fs('11.5vp', this.fontScale))
              .fontColor('#FF6B6B')
              .height('28vp')
              .padding({ left: '10vp', right: '10vp' })
              .borderRadius('14vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .onClick(() => { void this.removeSelectedRules(); })
          }
        }
          .width('100%')
          .padding({ top: '8vp' })
          .alignItems(VerticalAlign.Center)
        if (this.customRules.length > 0) {
          ForEach(this.customRules, (rule: SearchSource) => {
            Row({ space: '8vp' }) {
              if (this.ruleManageMode) {
                SymbolGlyph(this.selectedRuleIds.indexOf(rule.id) >= 0
                  ? $r('sys.symbol.checkmark_square_fill')
                  : $r('sys.symbol.checkmark_square'))
                  .fontSize(Ui.fs('20vp', this.fontScale))
                  .fontColor([this.selectedRuleIds.indexOf(rule.id) >= 0
                    ? Ui.accent(this.darkTheme)
                    : Ui.inkSoft(this.darkTheme)])
              }
              Column({ space: '2vp' }) {
                Text(rule.name + (!this.isRuleEnabled(rule) ? '（已停用）' : ''))
                  .fontSize(Ui.fs('13.5vp', this.fontScale))
                  .fontColor(!this.isRuleEnabled(rule) ? Ui.inkFaint(this.darkTheme) : Ui.ink(this.darkTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(rule.url)
                  .fontSize(Ui.fs('10.5vp', this.fontScale))
                  .fontColor(Ui.inkFaint(this.darkTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              // 单条开关：点一下在启用/停用之间切换。
              Text(this.isRuleEnabled(rule) ? '停用' : '启用')
                .fontSize(Ui.fs('11.5vp', this.fontScale))
                .fontColor(!this.isRuleEnabled(rule) ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
                .height('26vp')
                .padding({ left: '10vp', right: '10vp' })
                .borderRadius('13vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .onClick(() => { void this.toggleRule(rule); })
              Text('删除')
                .fontSize(Ui.fs('11.5vp', this.fontScale))
                .fontColor('#FF6B6B')
                .height('26vp')
                .padding({ left: '10vp', right: '10vp' })
                .borderRadius('13vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .onClick(() => { void this.removeCustomRule(rule.id); })
            }
              .width('100%')
              .padding('10vp')
              .borderRadius('14vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .onClick(() => {
                if (!this.ruleManageMode) { return; }
                const index: number = this.selectedRuleIds.indexOf(rule.id);
                if (index >= 0) {
                  this.selectedRuleIds = this.selectedRuleIds.filter((id: number) => id !== rule.id);
                } else {
                  this.selectedRuleIds = this.selectedRuleIds.concat([rule.id]);
                }
              })
          }, (rule: SearchSource) => 'custom-rule-' + rule.id)
        }
        }
        this.rowDivider()
        // DNS 解析：部分源站域名会被运营商 DNS 污染，切到 DoH 可恢复。
        Column({ space: '8vp' }) {
          Text('DNS 解析')
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('部分源站域名会被运营商 DNS 污染，DoH 加密解析可修复；仅影响本应用的网络请求，不改系统 DNS。')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
            .maxLines(3)
          ForEach([DnsMode.FOLLOW, DnsMode.OFF, DnsMode.ALIYUN, DnsMode.TENCENT], (mode: string) => {
            Row({ space: '8vp' }) {
              Text(DnsService.label(mode))
                .fontSize(Ui.fs('13.5vp', this.fontScale))
                .fontColor(this.dnsMode === mode ? Ui.accentStrong(this.darkTheme) : Ui.ink(this.darkTheme))
                .layoutWeight(1)
                .maxLines(1)
              if (this.dnsMode === mode) {
                Text('✓')
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(Ui.accent(this.darkTheme))
              }
            }
              .width('100%')
              .height('38vp')
              .padding({ left: '12vp', right: '12vp' })
              .borderRadius('12vp')
              .backgroundColor(Ui.glassTintSoft(this.darkTheme))
              .alignItems(VerticalAlign.Center)
              .onClick(() => { void this.changeDnsMode(mode); })
          }, (mode: string) => 'dns-mode-' + mode)
          Row({ space: '10vp' }) {
            GhostButton({ label: '测试解析', compact: true, onTap: (): void => { void this.probeDns(); } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .padding({ top: '4vp' })
          Text(this.dnsProbeResult.length > 0 ? this.dnsProbeResult : '点「测试解析」会用当前模式请求一次 www.baidu.com，用于确认 DoH 是否生效。')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
            .maxLines(3)
        }
          .width('100%')
          .padding({ top: '12vp' })
        this.rowDivider()
        // 源类型：四类规则共用同一套列表
        Row({ space: '8vp' }) {
          ForEach(['cms', 'tvbox', 'web', 'netdisk'], (kind: string) => {
            Text(SourceKind.label(kind))
              .fontSize(Ui.fs('12vp', this.fontScale))
              .fontColor(this.customRuleKind === kind ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
              .height('30vp')
              .padding({ left: '12vp', right: '12vp' })
              .borderRadius('15vp')
              .backgroundColor(this.customRuleKind === kind ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
              .border({ width: 1, color: this.customRuleKind === kind ? Ui.accentRing(this.darkTheme) : Ui.glassRingSoft(this.darkTheme) })
              .onClick(() => {
                this.customRuleKind = kind;
                this.customRuleHint = SourceKind.label(kind) + '规则：' + SettingPage.kindHint(kind);
              })
          }, (kind: string) => 'rule-kind-' + kind)
        }
          .width('100%')
        SettingField({ field: 'custom-rule-name', value: $customRuleName, placeholder: '规则名称，例如：我的线路', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'custom-rule-name', onFocusChange: (on: boolean) => { this.focusedField = on ? 'custom-rule-name' : ''; }, onChange: (value: string) => {
          this.customRuleName = value;
        } })
        SettingField({ field: 'custom-rule-url', value: $customRuleUrl, placeholder: '搜索接口地址，例如 https://api.xx.com/api.php/provide/vod/', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'custom-rule-url', onFocusChange: (on: boolean) => { this.focusedField = on ? 'custom-rule-url' : ''; }, onChange: (value: string) => {
          this.customRuleUrl = value;
        } })
        SettingField({ field: 'custom-rule-json', value: $customRuleRule, placeholder: '高级规则 JSON（可选）：searchUrl / referer / mediaRegex / netdiskApi', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'custom-rule-json', onFocusChange: (on: boolean) => { this.focusedField = on ? 'custom-rule-json' : ''; }, onChange: (value: string) => { this.customRuleRule = value; } })
        Row({ space: '10vp' }) {
          GhostButton({ label: '测试连接', compact: true, onTap: (): void => { void this.probeCustomRule(); } })
          GhostButton({ label: '导入 TVBox', compact: true, onTap: (): void => { void this.importTvbox(); } })
          PrimaryButton({ label: '添加规则', compact: true, onTap: (): void => { void this.addCustomRule(); } })
        }
          .justifyContent(FlexAlign.End)
        Text(this.customRuleHint.length > 0 ? this.customRuleHint :
          '自定义规则与远端、导入线路并存；同名接口不会重复添加，冲突时以自定义规则为准。')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(this.customRuleHint.length > 0 ? Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme))
          .width('100%')
          .maxLines(3)
      }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private backendConfigPanel() {
    Column() {
      this.panelHeader('无音影视后端配置', '配置后端域名与默认账号，修改后立即应用并持久化保存')
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('默认域名')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { void this.restoreBackendDomain(); } })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      Row({ space: '10vp' }) {
        Row() {
          SettingField({ field: 'domain', value: $backendDomain, placeholder: AppConfig.DEFAULT_BACKEND_DOMAIN, darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'domain', onFocusChange: (on: boolean) => { this.focusedField = on ? 'domain' : ''; }, onChange: (value: string) => {
            this.backendDomain = value;
          } })
        }
          .layoutWeight(1)
        PrimaryButton({ label: '保存域名', compact: true, onTap: (): void => { void this.saveBackendDomain(); } })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Text('仅支持 http 或 https 协议，保存时会自动去除末尾斜杠')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('默认账号')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { void this.restoreBackendAccount(); } })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      Row({ space: '10vp' }) {
        Row() {
          SettingField({ field: 'account', value: $backendAccount, placeholder: AppConfig.DEFAULT_BACKEND_ACCOUNT, darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'account', onFocusChange: (on: boolean) => { this.focusedField = on ? 'account' : ''; }, onChange: (value: string) => {
            this.backendAccount = value;
          } })
        }
          .layoutWeight(1)
        PrimaryButton({ label: '保存账号', compact: true, onTap: (): void => { void this.saveBackendAccount(); } })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Text('用于无音影视后端请求的默认账号，不能为空')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 图床设置：聊天发图默认走这里配置的上传接口，接口/字段名/返回路径都可改。 */
  @Builder
  private imageHostPanel() {
    Column() {
      this.panelHeader('图床设置', '聊天页发送图片时默认上传到这里；接口地址、表单参数和返回路径都可以自定义')
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('接口地址')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { void this.restoreImageHost(); } })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      Row() {
        SettingField({ field: 'imageHostUrl', value: $imageHostUrl, placeholder: ImageHostService.DEFAULT_UPLOAD_URL, darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'imageHostUrl', onFocusChange: (on: boolean) => { this.focusedField = on ? 'imageHostUrl' : ''; }, onChange: (value: string) => {
          this.imageHostUrl = value;
        } })
      }
        .width('100%')
      Text('默认 https://naixiai.cn/api/1/upload（奶昔 Chevereto，已内置 key，单文件 ≤50MB）')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      Text('表单字段名')
        .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
      Row() {
        SettingField({ field: 'imageHostField', value: $imageHostField, placeholder: ImageHostService.DEFAULT_FIELD_NAME, darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'imageHostField', onFocusChange: (on: boolean) => { this.focusedField = on ? 'imageHostField' : ''; }, onChange: (value: string) => {
          this.imageHostField = value;
        } })
      }
        .width('100%')
      Text('multipart/form-data 里承载文件二进制的那一项，奶昔 Chevereto 为 source')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      Text('返回直链路径')
        .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
      Row() {
        SettingField({ field: 'imageHostPath', value: $imageHostPath, placeholder: ImageHostService.DEFAULT_RESPONSE_PATH, darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'imageHostPath', onFocusChange: (on: boolean) => { this.focusedField = on ? 'imageHostPath' : ''; }, onChange: (value: string) => {
          this.imageHostPath = value;
        } })
      }
        .width('100%')
      Text('返回 JSON 里直链所在位置，用点号分层，奶昔 Chevereto 为 image.url；留空表示接口直接返回纯文本直链')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      Text('奶昔实际是 Chevereto：地址 https://naixiai.cn/api/1/upload、字段 source、返回 image.url、key 走 X-API-Key 头。想要纯文本直链就在地址里加 ?format=txt 并把返回路径留空（程序会把 format 自动改成表单字段发送，直接放查询串会被奶昔判成空文件）。')
        .fontSize(Ui.fs('11vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '6vp' })
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('API Key（可选）')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        GhostButton({ label: '填入奶昔 v1', compact: true, onTap: (): void => { this.applyNaishiPreset(); } })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      Row() {
        this.glassKeyInput('imageHostKey', this.imageHostKey, '匿名图床留空；Chevereto 填 chv_ 开头的 key', (value: string) => {
          this.imageHostKey = value;
        })
      }
        .width('100%')
      Text('默认已内置一个奶昔 API Key，界面固定按密码态显示（不提供查看明文的入口）；非空时按 X-API-Key 请求头发送。奶昔是 Chevereto：「填入奶昔 v1」会把地址/字段/返回路径换成官方那组值（source + image.url）。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      Text('直传代理（可选）')
        .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
        .padding({ top: '12vp', bottom: '10vp' })
      Row() {
        SettingField({ field: 'imageHostProxy', value: $imageHostProxy, placeholder: 'https://api.y11.top/upload.php（留空则不用代理）', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'imageHostProxy', onFocusChange: (on: boolean) => { this.focusedField = on ? 'imageHostProxy' : ''; }, onChange: (value: string) => {
          this.imageHostProxy = value;
        } })
      }
        .width('100%')
      Text('填了代理后，所有上传优先走代理：App 只把文件字节 POST 过去（octet-stream + X-File-Name 头），由服务端转投奶昔并回传直链。绕开客户端 multipart，视频/音频也能传，key 也可以留在服务端。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      Text('接口返回 404 时，聊天页会提示改成手动填写直链；429 表示图床限流，稍后再传即可。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp', bottom: '10vp' })
      Text('奶昔可传 jpg/png/gif/webp、mp4/webm/mov、mp3/wav/flac/m4a/ogg，单文件 ≤50MB；不含 exe/apk 一类可执行文件。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ bottom: '10vp' })
      Row({ space: '10vp' }) {
        GhostButton({
          label: this.testingImageHost ? '测试中…' : '测试接口',
          compact: true,
          onTap: (): void => { void this.testImageHost(); }
        })
        Text('用上面填的值选一张图试传，不会保存配置')
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(2)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      if (this.imageHostTestText.length > 0) {
        Text(this.imageHostTestText)
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontColor(this.imageHostTestOk ? Ui.accent(this.darkTheme) : Ui.danger(this.darkTheme))
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ top: '8vp' })
          .copyOption(CopyOptions.LocalDevice)
      }
      Row({ space: '10vp' }) {
        GhostButton({ label: '恢复默认', compact: true, onTap: (): void => { void this.restoreImageHost(); } })
        PrimaryButton({ label: '保存图床设置', compact: true, onTap: (): void => { void this.saveImageHost(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 账号中心入口：签到 / 钱包 / VIP / 资料 / 三榜都在独立页里。 */
  @Builder
  private accountPanel() {
    Column() {
      this.panelHeader('账号中心', '签到 7 天、金币钱包、VIP、资料编辑与三榜排名')
      this.rowDivider()
      Row({ space: '10vp' }) {
        Column({ space: '3vp' }) {
          Text('打开账号中心')
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('签到日历 / 金币套餐与卡密 / VIP 四档 / 改昵称签名密码 / 三榜')
            .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        PrimaryButton({ label: '进入', compact: true, onTap: (): void => {
          router.pushUrl({ url: 'pages/AccountCenterPage' }).catch((error: Error) => {
            Logger.error('SETTING', '打开账号中心失败：' + String(error));
          });
        } })
      }
        .width('100%')
        .padding({ top: '14vp', bottom: '4vp' })
        .alignItems(VerticalAlign.Center)
      Text('签到、钱包、VIP 的沙箱部分会在页面内明确标注；真实接口按 api.y11.top 文档接入。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 弹窗位置选择胶囊：选中态使用品牌色描边与淡底。 */
  @Builder
  private placementChip(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Ui.fs('12.5vp', this.fontScale))
        .fontWeight(this.chatAlertPosition === value ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.chatAlertPosition === value ? Ui.accentStrong(this.darkTheme) : this.secondaryText())
        .maxLines(1)
    }
      .height('32vp')
      .padding({ left: '12vp', right: '12vp' })
      .borderRadius('16vp')
      .backgroundColor(this.chatAlertPosition === value ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
      .border({
        width: 1,
        color: this.chatAlertPosition === value ? Ui.glassRingAccent(this.darkTheme) : Ui.cardBorderSoft(this.darkTheme)
      })
      .accessibilityText('提醒弹窗位置：' + label)
      .onClick(() => { this.applyAlertPlacement(value, this.chatAlertOffset); })
      .animation({ duration: UiMotion.BASE, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private chatNoticePanel() {
    Column() {
      this.panelHeader('聊天提醒', '新消息弹窗、提示音、弹窗位置与免打扰，修改立即生效并持久化保存')
      this.rowDivider()
      this.switchRow('消息提示音', '收到聊天室 / 私聊新消息时播放「叮咚」提示音', this.chatSoundEnabled,
        (value: boolean) => {
          this.applyChatNotice(value, this.chatBannerEnabled, this.chatDndEnabled);
          Logger.info('BUTTON', value ? '开启消息提示音' : '关闭消息提示音');
        })
      this.rowDivider()
      this.switchRow('弹窗提醒', '新消息以 QQ / 微信样式弹出（位置见下方），可直接在弹窗内回复文字', this.chatBannerEnabled,
        (value: boolean) => {
          this.applyChatNotice(this.chatSoundEnabled, value, this.chatDndEnabled);
          Logger.info('BUTTON', value ? '开启顶部消息弹窗' : '关闭顶部消息弹窗');
        })
      this.rowDivider()
      this.switchRow('后台通知栏提醒',
        '应用退到后台后继续接收新消息，并通过系统通知栏提醒（需允许无音影视发送通知）',
        this.chatBackgroundNotify, (value: boolean) => { this.applyBackgroundNotify(value); })
      this.rowDivider()
      this.switchRow('免打扰', '开启后不播放提示音、不弹出提醒，仅在消息页保留未读数', this.chatDndEnabled,
        (value: boolean) => {
          this.applyChatNotice(this.chatSoundEnabled, this.chatBannerEnabled, value);
          Logger.info('BUTTON', value ? '开启聊天免打扰' : '关闭聊天免打扰');
        })
      this.rowDivider()
      // 弹窗位置：默认顶部（紧贴屏幕正上方），可切到居中 / 底部，并用下面的滑块做垂直微调。
      Column({ space: '8vp' }) {
        Row({ space: '8vp' }) {
          Text('弹窗位置')
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          this.placementChip('顶部', 'top')
          this.placementChip('居中', 'center')
          this.placementChip('Dock 上方', 'bottom')
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Text('默认「顶部」：紧贴屏幕正上方（状态栏下方 2vp）；「底部」紧贴 Dock 栏上方，不会压住导航栏；微调用来在所选锚点的基础上继续挪动。')
          .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
          .lineHeight(this.isTablet ? '18vp' : '16vp')
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '4vp' })
      SettingSliderRow({
        title: '位置微调（vp）',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: Math.round(this.chatAlertOffset),
        minValue: 0,
        maxValue: 200,
        stepValue: 10,
        onChanged: (value: number): void => { this.applyAlertPlacement(this.chatAlertPosition, value); }
      })
      this.rowDivider()
      Row({ space: '10vp' }) {
        GhostButton({ label: '试听提示音', compact: true, onTap: (): void => { this.previewSound(); } })
        GhostButton({ label: '预览提醒弹窗', compact: true, onTap: (): void => { this.previewBanner(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
      Text('提示音音量跟随系统媒体音量；免打扰或关闭顶部弹窗时，新消息仍会计入未读数。')
        .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
        .lineHeight(this.isTablet ? '18vp' : '16vp')
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private uiScalePanel() {
    Column() {
      this.panelHeader('界面尺寸', '自定义底部 Dock 栏大小与全局字体大小，拖动即时预览并自动保存')
      this.rowDivider()
      SettingSliderRow({
        title: 'Dock 栏大小（%）',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: Math.round(this.dockScale * 100),
        minValue: 85,
        maxValue: 125,
        stepValue: 5,
        onChanged: (value: number): void => { this.applyUiScale(value / 100, this.fontScale); }
      })
      this.rowDivider()
      SettingSliderRow({
        title: '全局字体大小（%）',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: Math.round(this.fontScale * 100),
        minValue: 85,
        maxValue: 130,
        stepValue: 5,
        onChanged: (value: number): void => { this.applyUiScale(this.dockScale, value / 100); }
      })
      this.rowDivider()
      // 迷你底栏预览：Tab 顺序、图标、文字全部取自真实底栏（navTabKeys + SymbolIcons），
      // 高度随 Dock 缩放变化，图标与文字随全局字体缩放变化。
      Column({ space: '6vp' }) {
        Row({ space: '8vp' }) {
          Text('预览')
            .fontSize(Ui.fs(this.isTablet ? '13vp' : '11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .maxLines(1)
            .layoutWeight(1)
          Text('Dock ' + Ui.scalePercent(this.dockScale) + ' · 字体 ' + Ui.scalePercent(this.fontScale))
            .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11vp', this.fontScale))
            .fontColor(Ui.accentStrong(this.darkTheme))
            .maxLines(1)
        }
          .width('100%')
        Row() {
          ForEach(NavTabs.sanitize(this.navTabKeys), (route: string, index: number) => {
            Column({ space: '2vp' }) {
              SymbolGlyph(SymbolIcons.tab(route, this.previewActiveIndex() === index))
                .fontSize(Ui.fs('16vp', this.fontScale))
                .fontColor([this.previewActiveIndex() === index ?
                  Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme)])
              Text(NavTabs.title(route))
                .fontSize(Ui.fs('9.5vp', this.fontScale))
                .fontWeight(this.previewActiveIndex() === index ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.previewActiveIndex() === index ?
                  Ui.accentStrong(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
          }, (route: string) => 'ui-scale-preview-' + route)
        }
          .width('100%')
          .height(Math.round(58 * Ui.dockScale(this.dockScale)))
          .padding({ left: '4vp', right: '4vp' })
          .borderRadius(Math.round(58 * Ui.dockScale(this.dockScale)) / 2)
          .backgroundColor(Ui.glassTint(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .clip(true)
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '4vp' })
      this.rowDivider()
      Row() {
        GhostButton({ label: '恢复默认尺寸', compact: true, onTap: (): void => { this.restoreUiScale(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
      Text('「全局字体大小」作用于全部页面的字号与输入框；「Dock 栏大小」只影响底部悬浮导航栏的高度与图标文字，' +
        '页面列表底部的避让高度会自动跟随。')
        .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
        .lineHeight(this.isTablet ? '18vp' : '16vp')
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 壁纸设置：本地导入背景 + 透明度 / 播放速率 / 动态背景帧率。 */
  @Builder
  private wallpaperPanel() {
    Column({ space: '10vp' }) {
      this.panelHeader('壁纸设置',
        '除播放器外的全部页面共用一张背景：本地视频 / 动图 / 图片，或内置渐变壁纸')
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('当前背景')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
          Text(this.wallpaperSummary())
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '14.5vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        GhostButton({ label: '壁纸库', compact: true, onTap: (): void => { this.openWallpaperPage(); } })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      Row({ space: '8vp' }) {
        PrimaryButton({ label: this.wallpaperImporting ? '导入中…' : '导入本地背景', compact: true,
          onTap: (): void => { void this.importWallpaper(); } })
        Text('mp4 / gif / jpg / png / webp，支持 Wallpaper Engine 导出的文件；导入后复制进应用私有目录')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .lineHeight(this.isTablet ? '17vp' : '15.5vp')
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(3)
        if (this.wallpaperImporting) {
          LoadingProgress().width('20vp').height('20vp').color(Ui.accent(this.darkTheme))
        }
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      this.switchRow('动态播放',
        '关闭后视频 / 动图背景停在首帧，静态图片背景不受影响', this.wallpaperMotion,
        (value: boolean) => {
          WallpaperService.setMotion(value);
          Logger.info('BUTTON', value ? '开启动态背景' : '暂停动态背景');
        })
      this.rowDivider()
      SettingSliderRow({
        title: '背景透明度（%）',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: Math.round(this.wallpaperOpacity * 100),
        minValue: Math.round(WallpaperService.OPACITY_MIN * 100),
        maxValue: 100,
        stepValue: 5,
        onChanged: (value: number): void => { WallpaperService.setOpacity(value / 100); }
      })
      this.rowDivider()
      SettingSliderRow({
        title: '播放速率（0.5 / 1 / 1.5x）',
        titleSize: this.isTablet ? '16vp' : '15vp',
        valueText: WallpaperService.rateLabel(this.wallpaperRate),
        value: this.wallpaperRate,
        minValue: 0.5,
        maxValue: 1.5,
        stepValue: 0.5,
        onChanged: (value: number): void => { WallpaperService.setRate(value); }
      })
      this.rowDivider()
      Row({ space: '8vp' }) {
        Text('动态背景帧率')
          .fontSize(Ui.fs('13.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
        Text(WallpaperService.frameLabel(this.wallpaperFrameHz))
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(WallpaperService.FRAME_OPTIONS, (hz: number) => {
          Text(hz <= 0 ? '跟随系统' : String(hz) + 'Hz')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(this.wallpaperFrameHz === hz ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
            .height('34vp')
            .padding({ left: '14vp', right: '14vp' })
            .borderRadius('17vp')
            .backgroundColor(this.wallpaperFrameHz === hz ?
              Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .border({
              width: 1,
              color: this.wallpaperFrameHz === hz ? Ui.accentRing(this.darkTheme) : Color.Transparent
            })
            .margin({ right: '8vp', bottom: '8vp' })
            .onClick(() => { WallpaperService.setFrameHz(hz); })
        }, (hz: number) => 'setting-background-frame-' + String(hz))
      }
        .width('100%')
      Text('「跟随系统」不额外限制刷新率；选 24 / 30 / 60Hz 时，动态背景播放期间向系统申请该帧率上限，' +
        '暂停动效或改用静态图片背景后自动恢复。播放器页仍使用「帧数设置」里的播放器帧率。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .lineHeight(this.isTablet ? '18vp' : '16vp')
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
      Row({ space: '8vp' }) {
        GhostButton({ label: '打开壁纸瀑布流', compact: true, onTap: (): void => { this.openWallpaperPage(); } })
        GhostButton({ label: '恢复默认背景', compact: true, onTap: (): void => { this.clearWallpaper(); } })
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 音频管理：本地录音列表 + 自动清理策略。 */
  /** 帧数设置：整机软件帧率 + 播放器帧率，均可跟随系统。 */
  @Builder
  private frameRatePanel() {
    Column({ space: '10vp' }) {
      this.panelHeader('帧数设置', '向系统申请屏幕刷新率；开启「跟随系统」时交还系统自适应')
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('跟随系统')
            .fontSize(Ui.fs('13.5vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('开启后不申请固定刷新率，省电优先')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.frameFollowSystem })
          .selectedColor(Ui.accent(this.darkTheme))
          .onChange((isOn: boolean) => {
            this.frameFollowSystem = isOn;
            // 只重新探测设备刷新率上限；不能在这里调用 refreshFrameRate()——
            // 它会重新读取已保存配置，把刚切换的开关立刻弹回原值（表现为开关点不动）。
            FrameRateService.refreshCapability();
            this.frameMaxHz = FrameRateService.maxSupportedHz();
          })
      }
        .width('100%')
      this.rowDivider()
      Text('软件帧率')
        .fontSize(Ui.fs('13.5vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(FrameRateService.APP_OPTIONS, (hz: number) => {
          Text(String(hz) + 'Hz')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(this.frameAppHz === hz ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
            .height('34vp')
            .padding({ left: '14vp', right: '14vp' })
            .borderRadius('17vp')
            .backgroundColor(this.frameAppHz === hz ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .border({
              width: 1,
              color: !this.frameRateSupported(hz) ? Ui.divider(this.darkTheme)
                : (this.frameAppHz === hz ? Ui.accentRing(this.darkTheme) : Color.Transparent)
            })
            .margin({ right: '8vp', bottom: '8vp' })
            .opacity(this.frameFollowSystem || !this.frameRateSupported(hz) ? 0.45 : 1)
            .onClick(() => {
              if (!this.frameRateSupported(hz)) {
                this.showToast('当前设备暂不支持 ' + String(hz) + 'Hz' +
                  (this.frameMaxHz > 0 ? '，最高 ' + String(this.frameMaxHz) + 'Hz' : ''));
                return;
              }
              if (this.frameFollowSystem) {
                this.showToast('已开启「跟随系统」，先关闭再选软件帧率');
                return;
              }
              this.frameAppHz = hz;
            })
        }, (hz: number) => 'app-' + String(hz))
      }
        .width('100%')
      Row({ space: '8vp' }) {
        Text('播放器帧率')
          .fontSize(Ui.fs('13.5vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
        Text(this.frameFollowSystem
          ? (this.frameMaxHz > 0 ? '跟随系统上限 ' + String(this.frameMaxHz) + 'Hz' : '跟随系统')
          : (this.frameMaxHz > 0 ? '设备上限 ' + String(this.frameMaxHz) + 'Hz' : '未限制'))
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(FrameRateService.PLAYER_OPTIONS, (hz: number) => {
          Text(String(hz) + 'Hz')
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .fontColor(this.framePlayerHz === hz ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
            .height('34vp')
            .padding({ left: '14vp', right: '14vp' })
            .borderRadius('17vp')
            .backgroundColor(this.framePlayerHz === hz ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .border({
              width: 1,
              color: !this.frameRateSupported(hz) ? Ui.divider(this.darkTheme)
                : (this.framePlayerHz === hz ? Ui.accentRing(this.darkTheme) : Color.Transparent)
            })
            .margin({ right: '8vp', bottom: '8vp' })
            .opacity(!this.frameRateSupported(hz) ? 0.45 : 1)
            .onClick(() => {
              if (!this.frameRateSupported(hz)) {
                this.showToast('当前设备暂不支持 ' + String(hz) + 'Hz' +
                  (this.frameMaxHz > 0 ? '，最高 ' + String(this.frameMaxHz) + 'Hz' : ''));
                return;
              }
              this.framePlayerHz = hz;
            })
        }, (hz: number) => 'player-' + String(hz))
      }
        .width('100%')
      Text((this.frameMaxHz > 0 ? '本机最高支持 ' + String(this.frameMaxHz) + 'Hz，超出的挡位置灰不可选。' : '') +
        '软件帧率作用于整个 App，受「跟随系统」开关控制；播放器帧率默认 60Hz、挡位 60~185Hz，独立生效' +
        '（进入播放页切换到播放器帧率，离开后恢复软件帧率）。部分机型对 120Hz 以上有系统级上限，实际以系统调度为准。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
      Row({ space: '10vp' }) {
        PrimaryButton({ label: '保存帧数设置', compact: true, onTap: (): void => { void this.saveFrameRate(); } })
        Text('默认跟随系统开启、软件与播放器均为 60Hz')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(2)
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  /** 直链设置：dbimg（免费 75MB、支持 wav/mp3/m4a），语音消息走它。 */
  @Builder
  private directPanel() {
    Column({ space: '10vp' }) {
      this.panelHeader('直链设置', '语音消息上传到 dbimg 并取直链；图片、视频仍走「图床设置」里的奶昔，互不影响')
      Text('接口地址')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
      Row() {
        SettingField({ field: 'directUrl', value: $directUrl, placeholder: 'https://dbimg.app/api/upload', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'directUrl', onFocusChange: (on: boolean) => { this.focusedField = on ? 'directUrl' : ''; }, onChange: (value: string) => {
          this.directUrl = value;
        } })
      }
        .width('100%')
      Text('API Key（Bearer）')
        .fontSize(Ui.fs('13vp', this.fontScale))
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
        .padding({ top: '4vp' })
      Row() {
        this.glassKeyInput('directKey', this.directKey, 'dbimg_xxxxxxxx', (value: string) => {
          this.directKey = value;
        })
      }
        .width('100%')
      Text('dbimg 的开放接口：POST /api/upload，字段 file，请求头 Authorization: Bearer <key>；' +
        '返回里的 mediaUrl 就是 CDN 直链。免费账号 75MB/文件、每天 200 次请求、3 把 Key。' +
        '它只收图片/视频/音频，pdf/zip 这类文件仍由奶昔处理。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
      Row({ space: '10vp' }) {
        GhostButton({ label: '填入 dbimg 默认', compact: true, onTap: (): void => { this.useDbimgDefaults(); } })
        GhostButton({ label: '保存', compact: true, onTap: (): void => { void this.saveDirect(); } })
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private voicePanel() {
    Column({ space: '10vp' }) {
      this.panelHeader('音频管理', '聊天室录下的语音存在应用私有目录，可按条删除，也可以让它按数量/天数自动清理')
      Row({ space: '10vp' }) {
        Text(this.voiceStat())
          .fontSize(Ui.fs('12.5vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .layoutWeight(1)
        GhostButton({ label: '立即清理', compact: true, onTap: (): void => { this.cleanVoiceNow(); } })
        GhostButton({ label: '清空', compact: true, onTap: (): void => { this.clearVoiceFiles(); } })
      }
        .width('100%')
      if (this.voiceFiles.length === 0) {
        Text('还没有本地语音')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .width('100%')
          .padding({ top: '10vp', bottom: '10vp' })
      } else {
        List({ space: '6vp' }) {
          ForEach(this.voiceFiles, (file: VoiceFile) => {
            ListItem() {
              Row({ space: '10vp' }) {
                SymbolGlyph(SymbolIcons.music())
                  .fontSize(Ui.fs('16vp', this.fontScale))
                  .fontColor([Ui.accentStrong(this.darkTheme)])
                Column({ space: '2vp' }) {
                  Text(file.name)
                    .fontSize(Ui.fs('11.5vp', this.fontScale))
                    .fontColor(Ui.ink(this.darkTheme))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(VoiceStore.formatTime(file.modified) + ' · ' + VoiceStore.formatSize(file.size))
                    .fontSize(Ui.fs('10vp', this.fontScale))
                    .fontColor(Ui.inkFaint(this.darkTheme))
                    .width('100%')
                }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                Text('删除')
                  .fontSize(Ui.fs('11vp', this.fontScale))
                  .fontColor(Ui.gold(this.darkTheme))
                  .padding({ left: '8vp', right: '8vp', top: '3vp', bottom: '3vp' })
                  .borderRadius('10vp')
                  .backgroundColor(Ui.goldSoft(this.darkTheme))
                  .onClick((): void => { this.deleteVoiceFile(file.name); })
              }
                .width('100%')
                .alignItems(VerticalAlign.Center)
            }
          }, (file: VoiceFile) => 'voice-' + file.name)
        }
          .width('100%')
          .height('220vp')
      }
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('自动清理')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.voiceAutoClean })
          .onChange((isOn: boolean) => { this.voiceAutoClean = isOn; })
      }
        .width('100%')
      // 两个输入框并排：各自放在带权重的 Column 里，否则两个 width('100%') 的输入框
      // 会把整张卡片撑得比屏幕还宽（右侧被裁掉）。
      Row({ space: '10vp' }) {
        Column({ space: '6vp' }) {
          Text('保留天数（0 = 不限）')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SettingField({ field: 'voiceKeepDays', value: $voiceKeepDays, placeholder: '默认 7', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'voiceKeepDays', onFocusChange: (on: boolean) => { this.focusedField = on ? 'voiceKeepDays' : ''; }, onChange: (value: string) => {
            this.voiceKeepDays = value;
          } })
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Column({ space: '6vp' }) {
          Text('数量上限')
            .fontSize(Ui.fs('11.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
            .maxLines(1)
          SettingField({ field: 'voiceMaxCount', value: $voiceMaxCount, placeholder: '默认 20', darkTheme: this.darkTheme, fontScale: this.fontScale, focused: this.focusedField === 'voiceMaxCount', onFocusChange: (on: boolean) => { this.focusedField = on ? 'voiceMaxCount' : ''; }, onChange: (value: string) => {
            this.voiceMaxCount = value;
          } })
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
      }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      Text('数量超过上限时一次删掉最旧的 ' + String(VoiceStore.BATCH) + ' 条；默认保留 ' +
        String(VoiceStore.DEFAULT_DAYS) + ' 天、最多 ' + String(VoiceStore.DEFAULT_MAX) + ' 条。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
      Row({ space: '10vp' }) {
        GhostButton({ label: '保存设置', compact: true, onTap: (): void => { void this.saveVoiceSettings(); } })
        Text('录音文件按 mp3 存在私有目录，上传前会临时复制成 .mp4 再传')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(2)
      }
        .width('100%')
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private playerPanel() {
    Column() {
      this.panelHeader('播放器设置', '调整播放器相关播放内核与播放参数')
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('播放器内核')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        Select([{ value: 'IJKPlayer' }, { value: 'AVPlayer' }])
          .selected(this.playerKernel === 'av' ? 1 : 0)
          .value(this.playerKernel === 'av' ? 'AVPlayer' : 'IJKPlayer')
          .font({ size: '13vp', weight: FontWeight.Medium })
          .fontColor(Ui.ink(this.darkTheme))
          .selectedOptionBgColor(Ui.accentSoft(this.darkTheme))
          .selectedOptionFontColor(Ui.accentStrong(this.darkTheme))
          .optionBgColor(Ui.glassTintStrong(this.darkTheme))
          .optionFontColor(this.secondaryText())
          .backgroundColor(this.panelColor())
          .borderRadius('18vp')
          .onSelect((index: number) => {
            const kernel: string = index === 1 ? 'av' : 'ijk';
            void AppState.setPlayerKernel(kernel).then(() => {
              Logger.info('SETTING', '播放器内核已切换为 ' + kernel);
            }).catch((error: Error) => {
              Logger.error('SETTING', '保存播放器内核失败：' + String(error));
              this.showOperationError('保存播放器内核失败：' + String(error));
            });
          })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '12vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      // 广告拦截：点击打开与播放器风格一致的说明/开关弹窗。
      Row({ space: '10vp' }) {
        Column({ space: '3vp' }) {
          Text('广告拦截')
            .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text(this.adBlockEnabled ? '已开启：按规则清洗播放地址，并过滤 m3u8 广告分片' :
            '已关闭：播放时使用原始地址，不做广告过滤')
            .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
            .lineHeight(this.isTablet ? '18vp' : '16vp')
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        GhostButton({ label: '设置', compact: true, onTap: (): void => { this.showAdBlockDialog = true; } })
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '12vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private appearancePanel() {
    Column() {
      this.panelHeader('沉浸外观', '调整 Dock 栏透明度、面板透明度与主题配色')
      this.switchRow('开启全局 Dock 栏沉浸', '关闭后所有页面取消 backdropBlur 效果', this.immersiveEnabled,
        (value: boolean) => {
          this.immersiveEnabled = value;
          this.updateConfig();
          Logger.info('BUTTON', value ? '开启全局沉浸' : '关闭全局沉浸');
        })
      this.rowDivider()
      // 独立开关通过 StorageLink 发布到全局配置；总沉浸关闭时导航会忽略该开关。
      this.switchRow('导航栏自动取色沉浸背景',
        '开启后底部导航读取导航背后区域画面色彩动态适配背景，关闭使用固定深色背景',
        this.immersiveConfig.autoColorEnable, (value: boolean) => {
          this.immersiveConfig = { immersiveEnable: this.immersiveConfig.immersiveEnable,
              immersiveBlur: this.immersiveConfig.immersiveBlur,
              immersiveOpacity: this.immersiveConfig.immersiveOpacity, autoColorEnable: value };
          this.updateConfig();
          Logger.info('BUTTON', value ? '开启导航局部取色' : '关闭导航局部取色');
        })
      this.rowDivider()
      SettingSliderRow({
        title: 'Dock 栏透明度',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: this.immersiveBlur,
        minValue: 0,
        maxValue: 50,
        stepValue: 1,
        onChanged: (value: number): void => {
          this.immersiveBlur = Math.round(value);
          this.updateConfig();
        }
      })
      this.rowDivider()
      SettingSliderRow({
        title: '沉浸面板透明度',
        titleSize: this.isTablet ? '16vp' : '15vp',
        value: this.immersiveOpacity,
        minValue: 0.1,
        maxValue: 1.0,
        stepValue: 0.1,
        onChanged: (value: number): void => {
          this.immersiveOpacity = Number(value.toFixed(1));
          this.updateConfig();
        }
      })
      this.rowDivider()
      Row({ space: '10vp' }) {
        Text('主题配色')
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        Row({ space: '5vp' }) {
          Radio({ value: 'dark', group: 'theme' })
            .checked(this.darkTheme)
            .radioStyle({
              checkedBackgroundColor: Ui.accent(this.darkTheme),
              uncheckedBorderColor: Ui.inkFaint(this.darkTheme),
              indicatorColor: Ui.inkOnMedia(this.darkTheme)
            })
            .onChange((checked: boolean) => {
              if (checked) { void AppState.setThemeMode('dark'); }
            })
          Text('深色主题').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.secondaryText()).maxLines(1)
        }
        Row({ space: '5vp' }) {
          Radio({ value: 'light', group: 'theme' })
            .checked(!this.darkTheme)
            .radioStyle({
              checkedBackgroundColor: Ui.accent(this.darkTheme),
              uncheckedBorderColor: Ui.inkFaint(this.darkTheme),
              indicatorColor: Ui.inkOnMedia(this.darkTheme)
            })
            .onChange((checked: boolean) => {
              if (checked) { void AppState.setThemeMode('light'); }
            })
          Text('浅色主题').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(this.secondaryText()).maxLines(1)
        }
      }
        .width('100%')
        .padding({ top: '12vp', bottom: '12vp' })
        .constraintSize({ minHeight: 52 })
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      Row() {
        GhostButton({ label: '恢复默认设置', onTap: (): void => { this.resetSettings(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private navTabsPanel() {
    Column() {
      this.panelHeader('底部导航', '管理首页底栏的显示项与顺序，修改后液态玻璃底栏立即更新')
      this.rowDivider()
      ForEach(NavTabs.ALL, (item: NavTabDefinition, index: number) => {
        Column() {
          Row({ space: '10vp' }) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width('34vp')
                .height('34vp')
                .borderRadius('12vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
              // 与 Dock 栏同一套图标（SymbolIcons.tab）。
              SymbolGlyph(SymbolIcons.tab(item.key, this.navTabVisible(item.key)))
                .fontSize(Ui.fs('18vp', this.fontScale))
                .fontColor([this.navTabVisible(item.key) ? Ui.accent(this.darkTheme) : Ui.inkFaint(this.darkTheme)])
            }
              .width('34vp')
              .height('34vp')
            Column({ space: '2vp' }) {
              Text(item.title)
                .fontSize(Ui.fs(this.isTablet ? '15.5vp' : '14.5vp', this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Ui.ink(this.darkTheme))
                .maxLines(1)
              Text(item.subtitle)
                .fontSize(Ui.fs(this.isTablet ? '12vp' : '11vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            if (item.locked) {
              Text('固定')
                .fontSize(Ui.fs('11vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .height('24vp')
                .padding({ left: '9vp', right: '9vp' })
                .borderRadius('12vp')
                .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                .textAlign(TextAlign.Center)
            } else {
              if (this.navTabVisible(item.key)) {
                Row({ space: '4vp' }) {
                  Text('↑')
                    .fontSize(Ui.fs('15vp', this.fontScale))
                    .fontColor(this.navTabIndex(item.key) > 0 ? Ui.accent(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                    .width('28vp')
                    .height('28vp')
                    .textAlign(TextAlign.Center)
                    .borderRadius('14vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .accessibilityText('上移' + item.title)
                    .onClick(() => {
                      if (this.navTabIndex(item.key) > 0) {
                        this.moveNavTab(item.key, -1);
                      }
                    })
                  Text('↓')
                    .fontSize(Ui.fs('15vp', this.fontScale))
                    .fontColor(this.navTabIndex(item.key) < this.navTabKeys.length - 1 ?
                      Ui.accent(this.darkTheme) : Ui.inkFaint(this.darkTheme))
                    .width('28vp')
                    .height('28vp')
                    .textAlign(TextAlign.Center)
                    .borderRadius('14vp')
                    .backgroundColor(Ui.glassTintSoft(this.darkTheme))
                    .accessibilityText('下移' + item.title)
                    .onClick(() => {
                      if (this.navTabIndex(item.key) < this.navTabKeys.length - 1) {
                        this.moveNavTab(item.key, 1);
                      }
                    })
                }
              }
              Toggle({ type: ToggleType.Switch, isOn: this.navTabVisible(item.key) })
                .selectedColor(Ui.accent(this.darkTheme))
                .onChange((value: boolean) => {
                  this.toggleNavTab(item.key, value);
                })
            }
          }
            .width('100%')
            .padding({ top: '10vp', bottom: '10vp' })
            .alignItems(VerticalAlign.Center)
          if (index < NavTabs.ALL.length - 1) {
            this.rowDivider()
          }
        }
          .width('100%')
      }, (item: NavTabDefinition) => 'nav-tab-' + item.key)
      Row() {
        GhostButton({ label: '恢复默认顺序', compact: true, onTap: (): void => { this.restoreNavTabs(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: '12vp' })
      Text('首页与我的为固定入口；隐藏设置后仍可从我的页面右上角进入设置。')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      this.rowDivider()
      // Dock 栏外观：三种样式 + 强度 + 低电量自适应。
      Text('Dock 栏外观')
        .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.ink(this.darkTheme))
        .width('100%')
        .padding({ top: '4vp', bottom: '8vp' })
      ForEach(DockStyleStore.OPTIONS, (option: DockStyleOption) => {
        Row({ space: '10vp' }) {
          Column({ space: '2vp' }) {
            Text(option.title)
              .fontSize(Ui.fs('13.5vp', this.fontScale))
              .fontWeight(this.dockStyleKey === option.key ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.dockStyleKey === option.key ? Ui.accentStrong(this.darkTheme) : Ui.ink(this.darkTheme))
              .width('100%')
            Text(option.desc)
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.darkTheme))
              .width('100%')
              .maxLines(2)
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          Text(this.dockStyleKey === option.key ? '已选' : '选择')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(this.dockStyleKey === option.key ? Ui.accentStrong(this.darkTheme) : Ui.inkSoft(this.darkTheme))
            .height('26vp')
            .padding({ left: '10vp', right: '10vp' })
            .borderRadius('13vp')
            .backgroundColor(this.dockStyleKey === option.key ? Ui.accentSoft(this.darkTheme) : Ui.glassTintSoft(this.darkTheme))
            .textAlign(TextAlign.Center)
        }
          .width('100%')
          .padding({ top: '6vp', bottom: '6vp' })
          .onClick(() => { this.dockStyleKey = option.key; })
      }, (option: DockStyleOption) => option.key)
      Row({ space: '10vp' }) {
        Text('强度')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
        Slider({ value: this.dockIntensity, min: 0, max: 100, step: 5, style: SliderStyle.InSet })
          .layoutWeight(1)
          .trackColor(Ui.glassRing(this.darkTheme))
          .selectedColor(Ui.accent(this.darkTheme))
          .blockColor(Ui.accentStrong(this.darkTheme))
          .onChange((value: number) => { this.dockIntensity = Math.round(value); })
        Text(String(this.dockIntensity) + '%')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .width('42vp')
          .textAlign(TextAlign.End)
      }
        .width('100%')
        .padding({ top: '6vp' })
      Row({ space: '10vp' }) {
        Column({ space: '2vp' }) {
          Text('低电量自动降低强度')
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('当前电量 ' + String(this.dockBatteryNow) + '%，低于阈值后模糊与光感按比例减弱（最低 35%）')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
            .maxLines(2)
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.dockBatteryAuto })
          .onChange((isOn: boolean) => { this.dockBatteryAuto = isOn; })
      }
        .width('100%')
        .padding({ top: '8vp' })
      // 电量阈值：10 间断点的进度条（0/10/…/100），直接拖动选择。
      Row({ space: '10vp' }) {
        Text('电量阈值')
          .fontSize(Ui.fs('13vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
        Slider({ value: Number(this.dockThreshold), min: 0, max: 100, step: 10, style: SliderStyle.InSet })
          .layoutWeight(1)
          .trackColor(Ui.glassRing(this.darkTheme))
          .selectedColor(Ui.accent(this.darkTheme))
          .blockColor(Ui.accentStrong(this.darkTheme))
          .showSteps(true)
          .onChange((value: number) => { this.dockThreshold = String(Math.round(value)); })
        Text(String(Math.round(Number(this.dockThreshold))) + '%')
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontColor(Ui.inkSoft(this.darkTheme))
          .width('42vp')
          .textAlign(TextAlign.End)
      }
        .width('100%')
        .padding({ top: '6vp' })
      Row({ space: '10vp' }) {
        PrimaryButton({ label: '保存 Dock 外观', compact: true, onTap: (): void => { void this.saveDockStyle(); } })
        Text('默认液态玻璃、强度 70%、电量低于 20% 自动降级')
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.darkTheme))
          .layoutWeight(1)
          .maxLines(2)
      }
        .width('100%')
        .padding({ top: '8vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private logPanel() {
    Column() {
      Row({ space: '12vp' }) {
        Column({ space: '3vp' }) {
          Text('软件运行日志')
            .fontSize(Ui.fs(this.isTablet ? '22vp' : '19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('本地保存运行信息，单文件上限 5MB，最多保留 3 份归档')
            .fontSize(Ui.fs(this.isTablet ? '13vp' : '11.5vp', this.fontScale))
            .lineHeight(this.isTablet ? '19vp' : '17vp')
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.logging })
          .selectedColor(Ui.accent(this.darkTheme))
          .onChange((value: boolean) => {
            this.logging = value;
            this.updateLogging(value);
          })
      }
        .width('100%')
        .padding({ bottom: '4vp' })
        .alignItems(VerticalAlign.Center)
      this.rowDivider()
      Row({ space: '8vp' }) {
        GhostButton({ label: '查看日志', compact: true, onTap: (): void => { this.openLogs(); } })
        GhostButton({ label: '清空日志', compact: true, onTap: (): void => { this.showClearDialog = true; } })
        GhostButton({ label: '导出日志', compact: true, onTap: (): void => { void this.exportLogs(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ top: '12vp' })
      this.rowDivider()
      Row({ space: '8vp' }) {
        GhostButton({ label: '导出聊天记录', compact: true, onTap: (): void => { void this.exportChatArchive(); } })
        GhostButton({ label: '导入聊天记录', compact: true, onTap: (): void => { void this.importChatArchive(); } })
      }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ top: '12vp' })
      Text('聊天记录会保存到本地；导出为 JSON（全部群聊 + 好友），导入时自动合并去重。')
        .fontSize(Ui.fs('11vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '8vp' })
      Text('日志等级：DEBUG 调试 · INFO 普通 · WARN 警告 · ERROR 错误')
        .fontSize(Ui.fs('11.5vp', this.fontScale))
        .fontColor(Ui.inkFaint(this.darkTheme))
        .width('100%')
        .padding({ top: '10vp' })
    }
      .width('100%')
      .padding(this.isTablet ? '20vp' : '16vp')
      .borderRadius(this.panelRadius)
      .backgroundColor(Ui.card(this.darkTheme))
      .border({ width: 1, color: Ui.cardBorder(this.darkTheme) })
      .shadow({ radius: 18, color: Ui.shadowSoft(this.darkTheme), offsetY: 8 })
      .transition(TransitionEffect.OPACITY)
  }

  @Builder
  private activePanel() {
    if (this.activeMenu === '沉浸外观') {
      this.appearancePanel()
      this.backendConfigPanel()
      this.playerPanel()
      this.sourcePanel()
      this.logPanel()
    } else if (this.activeMenu === '账号中心') {
      this.accountPanel()
    } else if (this.activeMenu === '壁纸设置') {
      this.wallpaperPanel()
    } else if (this.activeMenu === '界面尺寸') {
      this.uiScalePanel()
    } else if (this.activeMenu === '聊天提醒') {
      this.chatNoticePanel()
    } else if (this.activeMenu === '底部导航') {
      this.navTabsPanel()
    } else if (this.activeMenu === '无音影视后端') {
      this.backendConfigPanel()
    } else if (this.activeMenu === '图床设置') {
      this.imageHostPanel()
    } else if (this.activeMenu === '直链设置') {
      this.directPanel()
    } else if (this.activeMenu === '帧数设置') {
      this.frameRatePanel()
    } else if (this.activeMenu === '音频管理') {
      this.voicePanel()
    } else if (this.activeMenu === '播放器设置') {
      this.playerPanel()
    } else if (this.activeMenu === '搜索源管理') {
      this.sourcePanel()
    } else {
      this.logPanel()
    }
  }

  @Builder
  private logDialog() {
    if (this.showLogDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Ui.scrim(this.darkTheme))
        Column({ space: '12vp' }) {
          Row({ space: '10vp' }) {
            Text('运行日志')
              .fontSize(Ui.fs(this.isTablet ? '22vp' : '19vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.darkTheme))
              .maxLines(1)
              .layoutWeight(1)
            GlassIconButton({
              iconSize: 32,
              symbol: $r('sys.symbol.xmark'),
              accessibilityLabel: '关闭运行日志',
              onTap: (): void => { this.showLogDialog = false; }
            })
          }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          // 逐行解析分级标签；LazyForEach 仅渲染可见行，适配长日志。
          List({ space: '4vp' }) {
            LazyForEach(this.logSource, (line: string, index: number) => {
              ListItem() {
                Text(line).fontSize(Ui.fs(this.isTablet ? '15vp' : '12vp', this.fontScale)).fontColor(this.logLineColor(line))
                  .fontFamily('monospace').lineHeight(this.isTablet ? '23vp' : '19vp')
                  .width('100%').textAlign(TextAlign.Start);
              }
            }, (_line: string, index: number) => index.toString())
          }
            .scrollBar(BarState.Auto).layoutWeight(1).width('100%').padding('12vp')
            .backgroundColor(Ui.glassTintSoft(this.darkTheme))
            .borderRadius(Ui.R_MD)
            .border({ width: 1, color: Ui.glassRingSoft(this.darkTheme) })
          Row({ space: '8vp' }) {
            this.actionButton('清空日志', SymbolIcons.doc(), () => { this.showClearDialog = true; })
            this.actionButton('复制全部日志', SymbolIcons.list(), () => { void this.copyLogs(); })
          }
            .width('100%')
          Row() {
            PrimaryButton({ label: '关闭', onTap: (): void => { this.showLogDialog = false; } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
        }
          .width(this.isTablet ? '680vp' : '92%')
          .height('76%')
          .padding('18vp')
          .borderRadius(this.panelRadius)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .shadow({ radius: 26, color: Ui.shadow(this.darkTheme), offsetY: 12 })
          .clip(true)
      }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY)
    }
  }

  @Builder
  private clearDialog() {
    if (this.showClearDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Ui.scrim(this.darkTheme))
        Column({ space: '12vp' }) {
          Text('清空运行日志？')
            .fontSize(Ui.fs(this.isTablet ? '21vp' : '19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('此操作会删除当前日志及全部归档文件，且无法恢复。')
            .fontSize(Ui.fs(this.isTablet ? '14vp' : '13vp', this.fontScale))
            .lineHeight(this.isTablet ? '22vp' : '20vp')
            .fontColor(this.secondaryText())
            .width('100%')
          Row({ space: '10vp' }) {
            GhostButton({ label: '取消', onTap: (): void => { this.showClearDialog = false; } })
            PrimaryButton({ label: '确认清空', onTap: (): void => { this.clearLogs(); } })
          }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .padding({ top: '6vp' })
        }
          .width(this.isTablet ? '440vp' : '86%')
          .padding('22vp')
          .borderRadius(this.panelRadius)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .shadow({ radius: 26, color: Ui.shadow(this.darkTheme), offsetY: 12 })
          .clip(true)
      }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY)
    }
  }

  /**
   * 广告拦截弹窗：标题 + 说明 + 总开关 + 异常回退提示 + 取消。
   * 开关改动立即持久化，下一集 / 下一条线路开始生效。
   */
  @Builder
  private adBlockDialog() {
    if (this.showAdBlockDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Ui.scrim(this.darkTheme))
          .onClick(() => { this.showAdBlockDialog = false; })
        Column({ space: '12vp' }) {
          Text('广告拦截')
            .fontSize(Ui.fs(this.isTablet ? '21vp' : '19vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.darkTheme))
            .width('100%')
          Text('按配置规则清洗播放地址，并通过本地代理过滤 m3u8 广告分片')
            .fontSize(Ui.fs(this.isTablet ? '14vp' : '13vp', this.fontScale))
            .lineHeight(this.isTablet ? '22vp' : '20vp')
            .fontColor(this.secondaryText())
            .width('100%')
          this.rowDivider()
          Row({ space: '10vp' }) {
            Column({ space: '2vp' }) {
              Text('开启拦截')
                .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Ui.ink(this.darkTheme))
                .width('100%')
              Text(this.adBlockEnabled ? 'm3u8 播放时经本地代理过滤广告分片' : '使用原始播放地址直连')
                .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
                .fontColor(Ui.inkFaint(this.darkTheme))
                .width('100%')
            }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.adBlockEnabled })
              .selectedColor(Ui.accent(this.darkTheme))
              .onChange((value: boolean) => {
                void AdBlockService.setEnabled(value);
                Logger.info('BUTTON', value ? '开启广告拦截' : '关闭广告拦截');
              })
          }
            .width('100%')
            .padding({ top: '4vp', bottom: '4vp' })
            .alignItems(VerticalAlign.Center)
          Text('关闭后如遇播放异常可重新开启；拦截异常时会自动回退原始地址播放')
            .fontSize(Ui.fs(this.isTablet ? '12.5vp' : '11.5vp', this.fontScale))
            .lineHeight(this.isTablet ? '19vp' : '17vp')
            .fontColor(Ui.inkFaint(this.darkTheme))
            .width('100%')
          Row() {
            GhostButton({ label: '取消', onTap: (): void => { this.showAdBlockDialog = false; } })
          }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: '2vp' })
        }
          .width(this.isTablet ? '460vp' : '88%')
          .padding('22vp')
          .borderRadius(this.panelRadius)
          .backgroundColor(Ui.glassTintStrong(this.darkTheme))
          .backdropBlur(Ui.glassBlur(this.immersiveConfig.immersiveEnable, this.immersiveConfig.immersiveBlur))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
          .shadow({ radius: 26, color: Ui.shadow(this.darkTheme), offsetY: 12 })
          .clip(true)
      }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY)
    }
  }

  build() {
    Stack() {
      // 底层：主题资源底色 + 低强度极光柔光。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackground())
      AuroraBackdrop({ intensity: this.darkTheme ? 0.42 : 0.55 })
      Column() {
        PageHeader({
          title: '设置',
          subtitle: '沉浸体验与应用运行管理',
          showBack: false,
          gutter: this.isTablet ? 24 : 16
        })
        Scroll(this.pageScroller) {
          Column({ space: '14vp' }) {
            if (this.isTablet) {
              Row({ space: '16vp' }) {
                this.sideMenu()
                Column({ space: '14vp' }) {
                  this.activePanel()
                }
                  .layoutWeight(1)
              }
                .width('100%')
                .alignItems(VerticalAlign.Top)
            } else {
              this.menuChips()
              Column({ space: '14vp' }) {
                this.activePanel()
              }
                .width('100%')
            }
          }
            .width('100%')
            .padding({
              left: this.isTablet ? '24vp' : '16vp',
              right: this.isTablet ? '24vp' : '16vp',
              top: '10vp',
              bottom: (Number.isFinite(this.navClearance) ? Math.max(0, this.navClearance) : 186) + 'vp'
            })
        }
          .scrollBar(BarState.Auto)
          .layoutWeight(1)
          .width('100%')
          .padding({ bottom: '0vp' })
        // 复用共享控制器：读取 vp 绝对位置、过滤抖动、记录日志并捕获异常。
          .onScrollStart(() => { NavigationScroll.begin('settings', 'content', this.pageScroller); })
          .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
            NavigationScroll.report('settings', 'content', this.pageScroller, scrollState);
          })
          .onScrollStop(() => { NavigationScroll.end('settings', 'content', this.pageScroller); })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
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
          .margin({ bottom: (Number.isFinite(this.navClearance) ? Math.max(0, this.navClearance) : 186) + 12 + 'vp' })
          .transition(TransitionEffect.OPACITY)
      }
      this.logDialog()
      this.clearDialog()
      this.adBlockDialog()
    }
    // 根容器和滚动视口均撑满宿主；不增加系统栏、底部导航或手势条占位。
      .width('100%').height('100%').padding({ bottom: '0vp' }).backgroundColor(this.pageBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .backdropBlur(this.immersiveConfig.immersiveEnable ? this.immersiveConfig.immersiveBlur : 0)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        try {
          const nextSize: number = parseFloat(String(newValue.width));
          if (Number.isFinite(nextSize) && nextSize > 0) {
            this.isTablet = nextSize >= 600;
          }
        } catch (error) {
          Logger.error('SETTING_IMMERSIVE', '更新设置页布局失败：' + String(error));
          this.showOperationError('更新设置页布局失败：' + String(error));
        }
      })
      .onAppear(() => {
        try {
          NavigationScroll.reset('settings', '进入设置页');
          this.onPageShow();
          this.onImmersiveConfigChanged();
          this.darkTheme = AppState.config.dark;
          this.playerKernel = AppState.playerKernel;
          this.logging = Logger.enabled;
          // 聊天提醒与界面尺寸以 AppState 持久化值为准，回填到 StorageLink 保证重进页面显示一致。
          this.chatSoundEnabled = AppState.chatSoundEnabled;
          this.chatBannerEnabled = AppState.chatBannerEnabled;
          this.chatDndEnabled = AppState.chatDndEnabled;
          this.chatAlertPosition = AppState.chatAlertPosition;
          this.chatAlertOffset = AppState.chatAlertOffset;
          this.chatBackgroundNotify = AppState.chatBackgroundNotify;
          this.dockScale = AppState.dockScale;
          this.fontScale = AppState.fontScale;
          void ImmersiveService.apply(true);
          void SearchSources.init().then(() => { this.remoteAddress = SearchSources.currentAddress(); this.refreshCustomRules(); })
          void DnsService.init().then(() => { this.dnsMode = DnsService.current(); })
            .catch((error: Error) => {
              Logger.error('SearchEngineLoad', '读取自定义地址失败：' + String(error));
              this.showOperationError('读取自定义地址失败：' + String(error));
            });
          Logger.info('NAVIGATION', '进入设置页面：全屏沉浸，不预留底部导航避让空间');
        } catch (error) {
          Logger.error('SETTING_IMMERSIVE', '初始化设置页失败：' + String(error));
          this.showOperationError('初始化设置页失败：' + String(error));
        }
      });
  }
}
/**
 * 设置页通用「标题 + 数值气泡 + 进度条」行。
 *
 * 为什么是子组件而不是 @Builder：@Builder 按值传参时，参数变化不会刷新内部 UI，
 * 拖动进度条时右侧数值会停在旧值。改用 @Prop 后，父组件状态一变这里就重新渲染，
 * 数值气泡、进度条位置、页面预览都会实时跟着动。
 */
@Component
struct SettingSliderRow {
  @StorageLink('darkTheme') private darkTheme: boolean = true;
  @StorageLink('fontScale') private fontScale: number = 1;
  @Prop title: string = '';
  @Prop titleSize: string = '15vp';
  @Prop value: number = 0;
  @Prop minValue: number = 0;
  @Prop maxValue: number = 100;
  @Prop stepValue: number = 1;
  /** 自定义数值文案（如播放速率的 "1x"）；为空时按步长自动格式化。 */
  @Prop valueText: string = '';
  onChanged: (value: number) => void = (): void => {};

  /** 数值文案：优先用 valueText；否则步长小于 1 显示一位小数（如 0.7），其余取整。 */
  private displayValue(): string {
    if (this.valueText.length > 0) {
      return this.valueText;
    }
    return this.value.toFixed(this.stepValue < 1 ? 1 : 0);
  }

  build() {
    Column({ space: '6vp' }) {
      Row({ space: '10vp' }) {
        Text(this.title)
          .fontSize(Ui.fs(this.titleSize, this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        Row() {
          Text(this.displayValue())
            .fontSize(Ui.fs('13vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.accentStrong(this.darkTheme))
        }
          .height('26vp')
          .padding({ left: '11vp', right: '11vp' })
          .borderRadius('13vp')
          .backgroundColor(Ui.accentSoft(this.darkTheme))
          .border({ width: 1, color: Ui.glassRingAccent(this.darkTheme) })
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Slider({
        value: this.value,
        min: this.minValue,
        max: this.maxValue,
        step: this.stepValue,
        style: SliderStyle.OutSet
      })
        .blockColor(Ui.accentStrong(this.darkTheme))
        .trackColor(Ui.glassTintSoft(this.darkTheme))
        .selectedColor(Ui.accent(this.darkTheme))
        .showSteps(false)
        .onChange((current: number) => { this.onChanged(current); })
    }
      .width('100%')
      .padding({ top: '12vp', bottom: '12vp' })
      .constraintSize({ minHeight: 54 })
  }
}








/**
 * 设置页文本输入框子组件。
 *
 * 为什么不用 @Builder：@Builder 的 value 参数不会随父组件刷新，键盘收起触发页面重建时
 * TextInput 会拿到旧的 text（表现为「退出输入法后内容被清空」）。改成子组件 + @Link 双向绑定后，
 * 文本始终存在父组件的 @State 里，重建也不会丢。
 */
@Component
struct SettingField {
  field: string = '';
  @Link value: string;
  @Prop placeholder: string = '';
  @Prop darkTheme: boolean = true;
  @Prop fontScale: number = 1;
  @Prop focused: boolean = false;
  onFocusChange: (focused: boolean) => void = (focused: boolean) => {};
  onChange: (value: string) => void = (value: string) => {};

  build() {
    TextInput({ text: $$this.value, placeholder: this.placeholder })
      .width('100%')
      .height(46)
      .fontSize(Ui.fs('14vp', this.fontScale))
      .fontColor(Ui.ink(this.darkTheme))
      .placeholderColor(Ui.inkFaint(this.darkTheme))
      .caretColor(Ui.accent(this.darkTheme))
      .backgroundColor(Ui.glassTintSoft(this.darkTheme))
      .borderRadius(23)
      .border({ width: 1, color: this.focused ? Ui.accentRing(this.darkTheme) : Ui.glassRingSoft(this.darkTheme) })
      .padding({ left: '16vp', right: '16vp' })
      .onFocus(() => { this.onFocusChange(true); })
      .onBlur(() => { this.onFocusChange(false); })
      .onChange((value: string) => {
        this.value = value;
        this.onChange(value);
      })
  }
}









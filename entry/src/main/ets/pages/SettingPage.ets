import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { AppConfig } from '../common/AppConfig';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ChatAlertService } from '../common/ChatAlertService';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { NavTabDefinition, NavTabs } from '../common/NavTabs';
import { NavigationScroll } from '../common/NavigationScroll';
import { NotificationService } from '../common/NotificationService';
import { SearchSources } from '../common/SearchSources';
import { SymbolIcons } from '../common/SymbolIcons';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, GhostButton, GlassIconButton, PageHeader, PrimaryButton } from '../common/UiWidgets';
import { ChatArchive } from '../common/ChatArchive';
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
  @StorageLink('page') private currentPage: string = 'home';
  // 宿主发布的底栏占位高度：底栏 + 底栏上方渐进模糊带 + 手势条。
  @StorageLink('navClearance') private navClearance: number = 186;
  @State backendDomain: string = AppConfig.DEFAULT_BACKEND_DOMAIN;
  @State backendAccount: string = AppConfig.DEFAULT_BACKEND_ACCOUNT;
  @State savingBackendDomain: boolean = false;
  @State savingBackendAccount: boolean = false;
  @State isTablet: boolean = false;
  @State showLogDialog: boolean = false;
  @State showClearDialog: boolean = false;
  @State logText: string = '';
  @State toastText: string = '';
  @State activeMenu: string = '沉浸外观';
  @State pressedAction: string = '';
  @State remoteAddress: string = SearchSources.DEFAULT_ADDRESS;
  @State savingAddress: boolean = false;
  @State importingSource: boolean = false;
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
      this.dockScale = nextDock;
      this.fontScale = nextFont;
      void AppState.setUiScales(nextDock, nextFont).catch((error: Error) => {
        Logger.error('SETTING_UI_SCALE', '保存界面尺寸失败：' + String(error));
        this.showOperationError('保存界面尺寸失败：' + String(error));
      });
    } catch (error) {
      Logger.error('SETTING_UI_SCALE', '更新界面尺寸失败：' + String(error));
      this.showOperationError('更新界面尺寸失败：' + String(error));
    }
  }

  private restoreUiScale(): void {
    try {
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
      this.darkTheme = true;
      this.immersiveConfig = { immersiveEnable: true, immersiveBlur: 20, immersiveOpacity: 0.8, autoColorEnable: true };
      this.updateConfig();
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
    this.showErrorDialog('搜索源操作失败', message);
  }

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
    }
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

  private navTabVisible(key: string): boolean {
    return this.navTabKeys.includes(key);
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
        this.menuChip('账号中心', SymbolIcons.wallet())
        this.menuChip('界面尺寸', SymbolIcons.category(false))
        this.menuChip('聊天提醒', SymbolIcons.bell())
        this.menuChip('底部导航', SymbolIcons.list())
        this.menuChip('无音影视后端', SymbolIcons.doc())
        this.menuChip('播放器设置', SymbolIcons.play())
        this.menuChip('搜索源管理', SymbolIcons.search())
        this.menuChip('运行日志', SymbolIcons.list())
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
      this.menuItem('账号中心', SymbolIcons.wallet())
      this.menuItem('界面尺寸', SymbolIcons.category(false))
      this.menuItem('聊天提醒', SymbolIcons.bell())
      this.menuItem('底部导航', SymbolIcons.list())
      this.menuItem('无音影视后端', SymbolIcons.doc())
      this.menuItem('播放器设置', SymbolIcons.play())
      this.menuItem('搜索源管理', SymbolIcons.search())
      this.menuItem('运行日志', SymbolIcons.list())
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
  private sliderRow(title: string, value: number, min: number, max: number, step: number,
    changed: (value: number) => void) {
    Column({ space: '6vp' }) {
      Row({ space: '10vp' }) {
        Text(title)
          .fontSize(Ui.fs(this.isTablet ? '16vp' : '15vp', this.fontScale))
          .fontColor(Ui.ink(this.darkTheme))
          .maxLines(1)
          .layoutWeight(1)
        Row() {
          Text(value.toFixed(step < 1 ? 1 : 0))
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
      Slider({ value: value, min: min, max: max, step: step, style: SliderStyle.OutSet })
        .blockColor(Ui.accentStrong(this.darkTheme))
        .trackColor(Ui.glassTintSoft(this.darkTheme))
        .selectedColor(Ui.accent(this.darkTheme))
        .showSteps(false)
        .onChange((current: number) => changed(current))
    }
      .width('100%')
      .padding({ top: '12vp', bottom: '12vp' })
      .constraintSize({ minHeight: 54 })
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

  @Builder
  private sourcePanel() {
    Column() {
      this.panelHeader('搜索源管理', '自定义远端搜索源地址，或导入本地线路文件')
      this.rowDivider()
      Row() {
        this.glassInput('source', this.remoteAddress, SearchSources.DEFAULT_ADDRESS, (value: string) => {
          this.remoteAddress = value;
        })
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
          this.glassInput('domain', this.backendDomain, AppConfig.DEFAULT_BACKEND_DOMAIN, (value: string) => {
            this.backendDomain = value;
          })
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
          this.glassInput('account', this.backendAccount, AppConfig.DEFAULT_BACKEND_ACCOUNT, (value: string) => {
            this.backendAccount = value;
          })
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
      this.sliderRow('位置微调（vp）', Math.round(this.chatAlertOffset), 0, 200, 10, (value: number) => {
        this.applyAlertPlacement(this.chatAlertPosition, value);
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
      this.sliderRow('Dock 栏大小（%）', Math.round(this.dockScale * 100), 85, 125, 5, (value: number) => {
        this.applyUiScale(Math.round(value) / 100, this.fontScale);
      })
      this.rowDivider()
      this.sliderRow('全局字体大小（%）', Math.round(this.fontScale * 100), 85, 130, 5, (value: number) => {
        this.applyUiScale(this.dockScale, Math.round(value) / 100);
      })
      this.rowDivider()
      // 迷你底栏预览：高度随 Dock 缩放变化，图标与文字随全局字体缩放变化。
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
          Row({ space: '5vp' }) {
            Text('⌂').fontSize(Ui.fs('17vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
            Text('首页').fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.accent(this.darkTheme))
          }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          Row({ space: '5vp' }) {
            Text('▦').fontSize(Ui.fs('17vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
            Text('分类').fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          Row({ space: '5vp' }) {
            Text('◎').fontSize(Ui.fs('17vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
            Text('设置').fontSize(Ui.fs('10.5vp', this.fontScale)).fontColor(Ui.inkFaint(this.darkTheme))
          }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        }
          .width('100%')
          .height(Math.round(56 * Ui.dockScale(this.dockScale)))
          .borderRadius(Math.round(56 * Ui.dockScale(this.dockScale)) / 2)
          .backgroundColor(Ui.glassTint(this.darkTheme))
          .border({ width: 1, color: Ui.glassRing(this.darkTheme) })
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
      this.panelHeader('沉浸外观', '调整全局页面的毛玻璃强度、透明度与主题配色')
      this.switchRow('开启全局毛玻璃沉浸', '关闭后所有页面取消 backdropBlur 效果', this.immersiveEnabled,
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
      this.sliderRow('毛玻璃模糊强度', this.immersiveBlur, 0, 50, 1, (value: number) => {
        this.immersiveBlur = Math.round(value);
        this.updateConfig();
      })
      this.rowDivider()
      this.sliderRow('沉浸面板透明度', this.immersiveOpacity, 0.1, 1.0, 0.1, (value: number) => {
        this.immersiveOpacity = Number(value.toFixed(1));
        this.updateConfig();
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
              if (checked) { this.darkTheme = true; this.updateConfig(); }
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
              if (checked) { this.darkTheme = false; this.updateConfig(); }
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
    } else if (this.activeMenu === '界面尺寸') {
      this.uiScalePanel()
    } else if (this.activeMenu === '聊天提醒') {
      this.chatNoticePanel()
    } else if (this.activeMenu === '底部导航') {
      this.navTabsPanel()
    } else if (this.activeMenu === '无音影视后端') {
      this.backendConfigPanel()
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
          void SearchSources.init().then(() => { this.remoteAddress = SearchSources.currentAddress(); })
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

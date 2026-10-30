import { window } from '@kit.ArkUI';
import { Logger } from './Logger';

// 与 AppState 和页面 @StorageLink 使用相同的字段，避免以 Object 丢失配置类型。
interface StoredImmersiveConfig {
  immersiveEnable: boolean;
  immersiveBlur: number;
  immersiveOpacity: number;
  autoColorEnable: boolean;
}

// 窗口沉浸与组件毛玻璃分别管理：关闭毛玻璃不会恢复不透明的系统导航区域。
export class ImmersiveService {
  private static activeWindow?: window.Window;
  private static persistenceRegistered: boolean = false;
  private static pending: Promise<void> = Promise.resolve();
  // 仅用于首次测量失败的 vp 兜底；有效测量允许横屏顶部安全区恢复为零。
  private static readonly initialTopInset: number = 24;
  private static readonly initialBottomInset: number = 16;
  private static readonly refreshInsets = (): void => {
    ImmersiveService.publishSafeArea();
  };

  // 沿用工程中已初始化的配置及其数据结构，不另行创建不同类型的默认配置。
  private static persistConfiguration(): void {
    if (ImmersiveService.persistenceRegistered) { return; }
    try {
      if (PersistentStorage.keys().indexOf('immersiveConfig') >= 0) {
        ImmersiveService.persistenceRegistered = true;
        return;
      }
      const currentConfig: StoredImmersiveConfig | undefined = AppStorage.get<StoredImmersiveConfig>('immersiveConfig');
      if (currentConfig === undefined || currentConfig === null) { return; }
      PersistentStorage.persistProp<StoredImmersiveConfig>('immersiveConfig', currentConfig);
      ImmersiveService.persistenceRegistered = PersistentStorage.keys().indexOf('immersiveConfig') >= 0;
      if (!ImmersiveService.persistenceRegistered) {
        Logger.warn('GLOBAL_IMMERSIVE', '沉浸配置未完成持久化注册，下次同步窗口时重试');
      }
    } catch (error) {
      Logger.error('GLOBAL_IMMERSIVE', '持久化沉浸配置失败：' + String(error));
    }
  }

  static async attach(target: window.Window): Promise<void> {
    try {
      ImmersiveService.persistConfiguration();
      if (ImmersiveService.activeWindow !== target) {
        ImmersiveService.detach();
        ImmersiveService.activeWindow = target;
        try { target.on('avoidAreaChange', ImmersiveService.refreshInsets); }
        catch (error) { Logger.warn('GLOBAL_IMMERSIVE', '注册安全区监听失败：' + String(error)); }
        try { target.on('windowSizeChange', ImmersiveService.refreshInsets); }
        catch (error) { Logger.warn('GLOBAL_IMMERSIVE', '注册窗口尺寸监听失败：' + String(error)); }
      }
      // 先初始化缺失的安全间距，再读取实时安全区，窗口创建期间也避让系统栏。
      ImmersiveService.initializeMissingInsets();
      ImmersiveService.publishSafeArea();
      await ImmersiveService.apply(true);
    } catch (error) {
      Logger.error('GLOBAL_IMMERSIVE', '初始化沉浸窗口失败：' + String(error));
    }
  }

  static detach(): void {
    const target = ImmersiveService.activeWindow;
    ImmersiveService.activeWindow = undefined;
    if (!target) { return; }
    try { target.off('avoidAreaChange', ImmersiveService.refreshInsets); }
    catch (error) { Logger.warn('GLOBAL_IMMERSIVE', '移除安全区监听失败：' + String(error)); }
    try { target.off('windowSizeChange', ImmersiveService.refreshInsets); }
    catch (error) { Logger.warn('GLOBAL_IMMERSIVE', '移除窗口尺寸监听失败：' + String(error)); }
  }

  static apply(force: boolean = false): Promise<void> {
    // 串行应用窗口状态，主题切换、返回前台与播放器退出横屏不会互相覆盖。
    // 捕获本次窗口，旧窗口排队任务不能修改重新创建的窗口。
    const requestedWindow = ImmersiveService.activeWindow;
    ImmersiveService.pending = ImmersiveService.pending.then(async () => {
      ImmersiveService.persistConfiguration();
      const target = requestedWindow;
      if (!target || ImmersiveService.activeWindow !== target) { return; }
      const sceneDark: boolean = AppStorage.get<boolean>('darkTheme') !== false;
      try {
        await target.setWindowLayoutFullScreen(true);
      } catch (error) {
        Logger.error('GLOBAL_IMMERSIVE', '开启窗口沉浸布局失败：' + String(error));
      }
      if (ImmersiveService.activeWindow !== target) { return; }
      try {
        // 保留系统小白条，不改变页面对状态栏显示与隐藏的既有处理。
        await target.setSpecificSystemBarEnabled('navigation', true);
      } catch (error) {
        Logger.warn('GLOBAL_IMMERSIVE', '恢复系统导航栏失败：' + String(error));
      }
      if (ImmersiveService.activeWindow !== target) { return; }
      try {
        // 即使布局或导航栏显示设置失败，也独立尝试恢复透明背景。
        await target.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
            navigationBarColor: '#00000000',
            statusBarContentColor: sceneDark ? '#FFFFFF' : '#182A40',
            navigationBarContentColor: sceneDark ? '#FFFFFF' : '#182A40'
        });
      } catch (error) {
        Logger.error('GLOBAL_IMMERSIVE', '应用透明系统栏失败：' + String(error));
      }
      if (ImmersiveService.activeWindow === target) {
        ImmersiveService.publishSafeArea();
        if (force) { Logger.info('GLOBAL_IMMERSIVE', '全局透明导航区域及安全区已同步'); }
      }
    }).catch((error: Error) => {
      Logger.error('GLOBAL_IMMERSIVE', '同步窗口状态失败：' + String(error));
    });
    return ImmersiveService.pending;
  }

  private static storedInset(key: string, fallback: number): number {
    try {
      const previous: number | undefined = AppStorage.get<number>(key);
      return previous !== undefined && Number.isFinite(previous) ? Math.max(0, previous) : fallback;
    } catch (error) {
      Logger.warn('GLOBAL_IMMERSIVE', '读取已保存的安全间距失败：' + String(error));
      return fallback;
    }
  }

  private static publishInset(key: string, value: number): void {
    // 无效测量不能将已有安全区清零；存储异常也不能中断其他方向的更新。
    if (!Number.isFinite(value)) { return; }
    try {
      const nextInset: number = Math.max(0, value);
      const previous: number | undefined = AppStorage.get<number>(key);
      if (previous === undefined || !Number.isFinite(previous) || Math.abs(previous - nextInset) > 0.1) {
        AppStorage.setOrCreate<number>(key, nextInset);
      }
    } catch (error) {
      Logger.error('GLOBAL_IMMERSIVE', '发布安全间距失败：' + String(error));
    }
  }

  private static readAvoidArea(target: window.Window, areaType: window.AvoidAreaType): window.AvoidArea | undefined {
    try {
      return target.getWindowAvoidArea(areaType);
    } catch (error) {
      // 单个区域读取失败不丢弃其他区域提供的有效安全间距。
      Logger.warn('GLOBAL_IMMERSIVE', '读取窗口安全区域失败：' + String(error));
      return undefined;
    }
  }

  private static initializeMissingInsets(): void {
    // 状态栏高度独立于挖孔安全区发布，供首页记录真实状态栏高度并统一计算顶部避让。
    ImmersiveService.publishInset('immersiveStatusBarInset',
      ImmersiveService.storedInset('immersiveStatusBarInset', ImmersiveService.initialTopInset));
    // 每个方向独立捕获存储异常；只初始化缺失值，不覆盖已测得的真实安全区。
    ImmersiveService.publishInset('immersiveTopInset',
      ImmersiveService.storedInset('immersiveTopInset', ImmersiveService.initialTopInset));
    ImmersiveService.publishInset('immersiveBottomInset',
      ImmersiveService.storedInset('immersiveBottomInset', ImmersiveService.initialBottomInset));
    ImmersiveService.publishInset('immersiveLeftInset', ImmersiveService.storedInset('immersiveLeftInset', 0));
    ImmersiveService.publishInset('immersiveRightInset', ImmersiveService.storedInset('immersiveRightInset', 0));
  }

  static publishSafeArea(): void {
    const target = ImmersiveService.activeWindow;
    if (!target) { return; }
    try {
      const gestureArea = ImmersiveService.readAvoidArea(target, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const systemArea = ImmersiveService.readAvoidArea(target, window.AvoidAreaType.TYPE_SYSTEM);
      // 状态栏在播放器横屏时可以隐藏，但屏幕挖孔仍需要独立避让。
      const cutoutArea = ImmersiveService.readAvoidArea(target, window.AvoidAreaType.TYPE_CUTOUT);
      if (!gestureArea && !systemArea && !cutoutArea) { throw new Error('窗口暂未提供有效安全区域'); }
      const uiContext = target.getUIContext();
      // Window 的原始坐标仅在此边界换算，所有发布值及页面布局均为 vp。
      // 系统状态栏与包含挖孔的顶部安全区分别测量，避免把挖孔尺寸当作状态栏高度。
      const statusBarInset: number = systemArea !== undefined ?
        uiContext.px2vp(systemArea.topRect.height) :
        ImmersiveService.storedInset('immersiveStatusBarInset', ImmersiveService.initialTopInset);
      // 各种安全区域取最大值而不是相加，避免同一系统区域被重复补偿。
      const topInset: number = uiContext.px2vp(Math.max(
        gestureArea?.topRect.height ?? 0, systemArea?.topRect.height ?? 0, cutoutArea?.topRect.height ?? 0));
      const bottomInset: number = uiContext.px2vp(Math.max(
        gestureArea?.bottomRect.height ?? 0, systemArea?.bottomRect.height ?? 0, cutoutArea?.bottomRect.height ?? 0));
      const leftInset: number = uiContext.px2vp(Math.max(
        gestureArea?.leftRect.width ?? 0, systemArea?.leftRect.width ?? 0, cutoutArea?.leftRect.width ?? 0));
      const rightInset: number = uiContext.px2vp(Math.max(
        gestureArea?.rightRect.width ?? 0, systemArea?.rightRect.width ?? 0, cutoutArea?.rightRect.width ?? 0));
      if (!Number.isFinite(statusBarInset) || !Number.isFinite(topInset) || !Number.isFinite(bottomInset) ||
        !Number.isFinite(leftInset) || !Number.isFinite(rightInset)) {
        throw new Error('窗口安全区域换算结果无效');
      }
      if (ImmersiveService.activeWindow !== target) { return; }
      // 任一区域读取失败时，其他区域的零值不足以证明可以移除已有避让。
      // 所有区域均恢复后，以实时测量为准，横竖屏转换不会永久保留旧间距。
      const areasComplete: boolean = gestureArea !== undefined && systemArea !== undefined && cutoutArea !== undefined;
      const safeTop: number = areasComplete ? topInset :
        Math.max(topInset, ImmersiveService.storedInset('immersiveTopInset', ImmersiveService.initialTopInset));
      const safeBottom: number = areasComplete ? bottomInset :
        Math.max(bottomInset, ImmersiveService.storedInset('immersiveBottomInset', ImmersiveService.initialBottomInset));
      const safeLeft: number = areasComplete ? leftInset :
        Math.max(leftInset, ImmersiveService.storedInset('immersiveLeftInset', 0));
      const safeRight: number = areasComplete ? rightInset :
        Math.max(rightInset, ImmersiveService.storedInset('immersiveRightInset', 0));
      // 系统栏恢复期间可能暂时返回空区域；保留 vp 兜底，横屏侧边安全区不重复补偿。
      const hasNavigationInset: boolean = safeBottom > 0 || safeLeft > 0 || safeRight > 0;
      ImmersiveService.publishInset('immersiveTopInset', safeTop);
      ImmersiveService.publishInset('immersiveBottomInset', hasNavigationInset ? safeBottom : ImmersiveService.initialBottomInset);
      ImmersiveService.publishInset('immersiveLeftInset', safeLeft);
      ImmersiveService.publishInset('immersiveRightInset', safeRight);
      // 首页通过 StorageLink 实时接收 vp 状态栏高度；测量失败时保留上次有效值。
      const previousStatusInset: number = ImmersiveService.storedInset('immersiveStatusBarInset', -1);
      const measuredStatusInset: number = Math.max(0, statusBarInset);
      ImmersiveService.publishInset('immersiveStatusBarInset', measuredStatusInset);
      if (Math.abs(previousStatusInset - measuredStatusInset) > 0.1) {
        Logger.info('GLOBAL_IMMERSIVE', '系统状态栏高度=' + measuredStatusInset +
        'vp，顶部安全区=' + safeTop + 'vp');
      }
    } catch (error) {
      if (ImmersiveService.activeWindow !== target) { return; }
      ImmersiveService.initializeMissingInsets();
      Logger.error('GLOBAL_IMMERSIVE', '读取安全区失败，保留 vp 安全间距：' + String(error));
    }
  }
}

import { Logger } from './Logger';

// 滚动显隐是临时交互状态，不写入 immersiveConfig，沿用原有外观持久化。
// Scroller.currentOffset() 返回 vp；不进行物理像素换算。
export class NavigationScroll {
  private static readonly visibilityKey: string = 'navigationBarHidden';
  private static readonly thresholdVp: number = 10;
  private static manageSource: string = 'history';
  private static lastRoute: string = '';
  private static lastSource: string = '';
  private static lastPositionVp: number = 0;
  private static trendDistanceVp: number = 0;
  private static scrollActive: boolean = false;
  private static lastLogTime: number = 0;

  static reset(route: string, reason: string): void {
    try {
      NavigationScroll.lastRoute = route;
      NavigationScroll.lastSource = '';
      NavigationScroll.lastPositionVp = 0;
      NavigationScroll.trendDistanceVp = 0;
      NavigationScroll.scrollActive = false;
      NavigationScroll.lastLogTime = 0;
      NavigationScroll.setHidden(false, route, reason);
      Logger.info('NavigationScroll', '重置滚动监听，页面=' + route + '，导航栏=显示，原因=' + reason);
    } catch (error) {
      Logger.error('NavigationScroll', '重置导航栏状态失败：' + String(error));
    }
  }

  static selectManageTab(index: number): void {
    try {
      const sources: string[] = ['history', 'favorites', 'downloads'];
      if (!Number.isInteger(index) || index < 0 || index >= sources.length) { return; }
      NavigationScroll.manageSource = sources[index];
      if (AppStorage.get<string>('page') === 'manage') {
        NavigationScroll.reset('manage', '切换管理标签：' + sources[index]);
      }
    } catch (error) {
      Logger.error('NavigationScroll', '同步管理页滚动来源失败：' + String(error));
    }
  }

  private static accepts(route: string, source: string): boolean {
    const currentRoute: string = AppStorage.get<string>('page') ?? 'home';
    return currentRoute === route && (route !== 'manage' || NavigationScroll.manageSource === source);
  }

  private static readPositionVp(scroller: Scroller): number {
    const measuredPositionVp: number = scroller.currentOffset().yOffset;
    if (!Number.isFinite(measuredPositionVp)) {
      throw new Error('滚动位置不是有效的 vp 数值');
    }
    // 顶部回弹不累计为反向滚动，顶部始终恢复导航栏。
    return Math.max(0, measuredPositionVp);
  }

  static begin(route: string, source: string, scroller: Scroller): void {
    try {
      if (!NavigationScroll.accepts(route, source)) { return; }
      const currentPositionVp: number = NavigationScroll.readPositionVp(scroller);
      NavigationScroll.lastRoute = route;
      NavigationScroll.lastSource = source;
      NavigationScroll.lastPositionVp = currentPositionVp;
      NavigationScroll.trendDistanceVp = 0;
      NavigationScroll.scrollActive = true;
      if (currentPositionVp <= 0) {
        NavigationScroll.setHidden(false, route, '从页面顶部开始滚动');
      }
      NavigationScroll.logPosition(route, source, currentPositionVp, 0, '开始', true);
    } catch (error) {
      Logger.error('NavigationScroll', '读取滚动起始位置失败，页面=' + route + '，来源=' + source + '：' + String(error));
    }
  }

  static report(route: string, source: string, scroller: Scroller, scrollState: ScrollState): void {
    try {
      if (!NavigationScroll.accepts(route, source)) { return; }
      const currentPositionVp: number = NavigationScroll.readPositionVp(scroller);
      // 嵌套 Scroll/Grid 的重排可能同时产生 Idle 回调。非当前来源的静止回调
      // 不得抢占滚动会话，也不得因自身位于零点而错误恢复正在隐藏的导航栏。
      if (scrollState === ScrollState.Idle && NavigationScroll.lastRoute === route &&
        NavigationScroll.lastSource !== '' && NavigationScroll.lastSource !== source) {
        NavigationScroll.logPosition(route, source, currentPositionVp, 0, '忽略非当前来源的静止回调', false);
        return;
      }
      if (NavigationScroll.lastRoute !== route || NavigationScroll.lastSource !== source) {
        NavigationScroll.lastRoute = route;
        NavigationScroll.lastSource = source;
        NavigationScroll.lastPositionVp = currentPositionVp;
        NavigationScroll.trendDistanceVp = 0;
        NavigationScroll.scrollActive = scrollState !== ScrollState.Idle;
        if (currentPositionVp <= 0 && NavigationScroll.scrollActive) {
          NavigationScroll.setHidden(false, route, '到达页面顶部');
        }
        NavigationScroll.logPosition(route, source, currentPositionVp, 0, '同步', true);
        return;
      }
      const deltaVp: number = currentPositionVp - NavigationScroll.lastPositionVp;
      NavigationScroll.lastPositionVp = currentPositionVp;
      if (scrollState !== ScrollState.Idle) { NavigationScroll.scrollActive = true; }
      const motionActive: boolean = NavigationScroll.scrollActive || scrollState !== ScrollState.Idle;
      if (!motionActive) {
        // 没有滚动会话时，数据加载、重排和刷新只同步位置，不改变导航栏。
        // 即使静止容器回到零点，也不能覆盖其他滚动来源产生的显隐状态。
        NavigationScroll.trendDistanceVp = 0;
      } else if (currentPositionVp <= 0) {
        NavigationScroll.trendDistanceVp = 0;
        NavigationScroll.setHidden(false, route, '到达页面顶部');
      } else if (Math.abs(deltaVp) > 0.01) {
        if (NavigationScroll.trendDistanceVp * deltaVp < 0) {
          NavigationScroll.trendDistanceVp = 0;
        }
        NavigationScroll.trendDistanceVp += deltaVp;
        if (Math.abs(NavigationScroll.trendDistanceVp) >= NavigationScroll.thresholdVp) {
          NavigationScroll.setHidden(NavigationScroll.trendDistanceVp > 0, route,
            NavigationScroll.trendDistanceVp > 0 ? '向下滚动' : '向上滚动');
          NavigationScroll.trendDistanceVp = 0;
        }
      }
      NavigationScroll.logPosition(route, source, currentPositionVp, deltaVp,
        !motionActive ? '静止' : deltaVp > 0 ? '向下' : deltaVp < 0 ? '向上' : '保持', false);
    } catch (error) {
      // 读取或状态同步失败时保留当前导航栏状态，不影响原有页面业务。
      Logger.error('NavigationScroll', '处理页面滚动失败，页面=' + route + '，来源=' + source + '：' + String(error));
    }
  }

  static end(route: string, source: string, scroller: Scroller): void {
    try {
      if (!NavigationScroll.accepts(route, source)) { return; }
      if (NavigationScroll.lastRoute !== route || NavigationScroll.lastSource !== source) { return; }
      // 先处理会话的最后一段位移，再结束会话；不丢弃停止回调前的反向滚动。
      NavigationScroll.report(route, source, scroller, ScrollState.Idle);
      NavigationScroll.scrollActive = false;
      NavigationScroll.trendDistanceVp = 0;
      NavigationScroll.logPosition(route, source, NavigationScroll.lastPositionVp, 0, '结束', true);
    } catch (error) {
      NavigationScroll.scrollActive = false;
      NavigationScroll.trendDistanceVp = 0;
      Logger.error('NavigationScroll', '结束滚动监听失败：' + String(error));
    }
  }

  private static setHidden(nextHidden: boolean, route: string, reason: string): void {
    const previousHidden: boolean = AppStorage.get<boolean>(NavigationScroll.visibilityKey) ?? false;
    if (AppStorage.has(NavigationScroll.visibilityKey) && previousHidden === nextHidden) { return; }
    AppStorage.setOrCreate(NavigationScroll.visibilityKey, nextHidden);
    Logger.info('NavigationScroll', '页面=' + route + '，导航栏=' + (previousHidden ? '隐藏' : '显示') +
    '→' + (nextHidden ? '隐藏' : '显示') + '，位置=' + NavigationScroll.lastPositionVp.toFixed(2) + 'vp，原因=' + reason);
  }

  private static logPosition(route: string, source: string, positionVp: number, deltaVp: number,
    direction: string, forceLog: boolean): void {
    const currentTime: number = Date.now();
    // 高频位置日志每 120ms 最多一条，开始、结束及状态切换不节流。
    if (!forceLog && currentTime - NavigationScroll.lastLogTime < 120) { return; }
    NavigationScroll.lastLogTime = currentTime;
    Logger.debug('NavigationScroll', '页面=' + route + '，来源=' + source + '，位置=' + positionVp.toFixed(2) +
    'vp，增量=' + deltaVp.toFixed(2) + 'vp，方向=' + direction + '，导航栏=' +
    (AppStorage.get<boolean>(NavigationScroll.visibilityKey) ? '隐藏' : '显示'));
  }
}

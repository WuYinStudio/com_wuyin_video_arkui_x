import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

/**
 * 首页底部导航的单项定义。
 *
 * 说明：这里只维护"有哪些 Tab、叫什么、是否允许隐藏"，不包含任何布局或动画。
 * LiquidNav 仍然使用原来的玻璃底栏、圆形液体指示器与滚动显隐逻辑，
 * 只是把写死的五项换成这里发布的顺序，因此不存在第二套导航样式。
 */
export class NavTabDefinition {
  key: string;
  title: string;
  subtitle: string;
  glyph: string;
  locked: boolean;

  constructor(key: string, title: string, subtitle: string, glyph: string, locked: boolean) {
    this.key = key;
    this.title = title;
    this.subtitle = subtitle;
    this.glyph = glyph;
    this.locked = locked;
  }
}

/**
 * 底部导航 Tab 管理。
 *
 * 持久化：应用 preferences('wuyin') 的 navTabKeys 字段。
 * 实时同步：AppStorage('navTabKeys')，LiquidNav 与设置页都用 @StorageLink 绑定，
 * 设置页勾选/排序后底栏立即重排，无需重启应用。
 */
export class NavTabs {
  static readonly STORAGE_KEY: string = 'navTabKeys';
  static readonly VERSION_KEY: string = 'navTabsVersion';
  /** 配置版本：2 起新增「消息 / 论坛 / 直播」三个入口，老用户首次升级会补进底栏。 */
  static readonly VERSION: number = 2;
  /** 新增入口的键，供版本迁移使用。 */
  static readonly ADDED_IN_V2: string[] = ['message', 'forum', 'live'];
  /** 默认底栏：首页 / 消息 / 论坛 / 直播 / 我的（分类、管理、设置在设置页里可选开启）。 */
  static readonly DEFAULT_KEYS: string[] = ['home', 'category', 'message', 'forum', 'mine'];
  static readonly ALL: NavTabDefinition[] = [
    new NavTabDefinition('home', '首页', '推荐、轮播与精选片单', '⌂', true),
    new NavTabDefinition('message', '消息', '好友、群聊与聊天室', '✉', false),
    new NavTabDefinition('forum', '论坛', '影评、资源与社区讨论', '✎', false),
    new NavTabDefinition('live', '直播', '电视频道与直播源', '▶', false),
    new NavTabDefinition('category', '分类', '按题材、地区与年份找片', '▦', false),
    new NavTabDefinition('manage', '管理', '观看历史、收藏与离线下载', '▤', false),
    new NavTabDefinition('settings', '设置', '沉浸外观、后端与运行日志', '⚙', false),
    new NavTabDefinition('mine', '我的', '账号、消息、论坛与个人内容', '◉', true)
  ];
  private static store?: preferences.Preferences;

  /** 启动时恢复用户自定义顺序；损坏或缺失时回退默认五项。 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      NavTabs.store = await preferences.getPreferences(context, 'wuyin');
      const savedVersion: number = Number(await NavTabs.store.get(NavTabs.VERSION_KEY, 0));
      const saved: string = String(await NavTabs.store.get(NavTabs.STORAGE_KEY, '[]'));
      let parsed: string[] = [];
      try {
        const value: string[] = JSON.parse(saved) as string[];
        if (Array.isArray(value)) {
          parsed = value;
        }
      } catch (error) {
        Logger.warn('NAV_TABS', '读取底部导航配置失败，使用默认顺序：' + String(error));
      }
      // 旧版本首次启动会把手动保存的“空配置”补成仅首页+我的两项；
      // 配置版本升级时恢复默认导航，避免底栏长期只剩两个入口。
      let keys: string[] = savedVersion < 1 ? NavTabs.DEFAULT_KEYS.slice() : NavTabs.sanitize(parsed);
      // v2：把「消息 / 论坛 / 直播」三个新入口补进用户已有顺序（只补一次，不覆盖用户的显隐与排序）。
      if (savedVersion < NavTabs.VERSION) {
        keys = NavTabs.withAddedKeys(keys);
      }
      if (savedVersion < NavTabs.VERSION) {
        await NavTabs.store.put(NavTabs.VERSION_KEY, NavTabs.VERSION);
        await NavTabs.store.flush();
      }
      NavTabs.publish(keys);
      Logger.info('NAV_TABS', '底部导航配置已恢复：' + keys.join(','));
    } catch (error) {
      Logger.error('NAV_TABS', '初始化底部导航配置失败：' + String(error));
      NavTabs.publish(NavTabs.DEFAULT_KEYS.slice());
    }
  }

  static current(): string[] {
    try {
      return NavTabs.sanitize(AppStorage.get<string[]>('navTabKeys'));
    } catch (error) {
      Logger.warn('NAV_TABS', '读取实时底部导航失败：' + String(error));
      return NavTabs.DEFAULT_KEYS.slice();
    }
  }

  /** 去重、过滤未知项、保持传入顺序，并强制保留首页与我的。 */
  static sanitize(source: string[] | undefined): string[] {
    const result: string[] = [];
    if (source && Array.isArray(source)) {
      for (const key of source) {
        if (!NavTabs.exists(key) || result.includes(key)) {
          continue;
        }
        result.push(key);
      }
    }
    // 首次启动或配置为空时必须回到默认五项，不能只补成「首页 + 我的」两项，
    // 否则底栏只剩两个入口，选中指示器与图标会显得整体偏移。
    if (result.length === 0) {
      return NavTabs.DEFAULT_KEYS.slice();
    }
    if (!result.includes('home')) {
      result.unshift('home');
    }
    if (!result.includes('mine')) {
      result.push('mine');
    }
    return result;
  }

  static exists(key: string): boolean {
    return NavTabs.ALL.some((item: NavTabDefinition) => item.key === key);
  }

  /** 把 v2 新增的入口补到「首页」之后，已存在的不重复添加。 */
  static withAddedKeys(source: string[]): string[] {
    const keys: string[] = NavTabs.sanitize(source);
    let insertAt: number = keys.indexOf('home') + 1;
    for (const key of NavTabs.ADDED_IN_V2) {
      if (keys.includes(key)) {
        continue;
      }
      keys.splice(insertAt, 0, key);
      insertAt++;
    }
    return NavTabs.sanitize(keys);
  }

  static definition(key: string): NavTabDefinition {
    const found: NavTabDefinition | undefined = NavTabs.ALL.find((item: NavTabDefinition) => item.key === key);
    return found !== undefined ? found : NavTabs.ALL[0];
  }

  static title(key: string): string {
    return NavTabs.definition(key).title;
  }

  static glyph(key: string): string {
    return NavTabs.definition(key).glyph;
  }

  static locked(key: string): boolean {
    return NavTabs.definition(key).locked;
  }

  static enabled(key: string): boolean {
    return NavTabs.current().includes(key);
  }

  /** 勾选/取消一个 Tab；首页与我的不可隐藏，至少保留两项。 */
  static setEnabled(key: string, selected: boolean): boolean {
    if (!NavTabs.exists(key)) {
      return false;
    }
    if (NavTabs.locked(key) && !selected) {
      Logger.warn('NAV_TABS', '固定入口不允许隐藏：' + key);
      return false;
    }
    const keys: string[] = NavTabs.current();
    const present: boolean = keys.includes(key);
    if (selected && !present) {
      keys.push(key);
    } else if (!selected && present) {
      if (keys.length <= 2) {
        Logger.warn('NAV_TABS', '至少需要保留两个底部入口');
        return false;
      }
      const index: number = keys.indexOf(key);
      keys.splice(index, 1);
    } else {
      return false;
    }
    NavTabs.publish(keys);
    NavTabs.persist(keys);
    Logger.info('NAV_TABS', (selected ? '显示' : '隐藏') + '底部入口：' + NavTabs.title(key));
    return true;
  }

  /** 在当前可见顺序内上移/下移一个 Tab。 */
  static move(key: string, delta: number): boolean {
    const keys: string[] = NavTabs.current();
    const from: number = keys.indexOf(key);
    if (from < 0 || !Number.isFinite(delta) || delta === 0) {
      return false;
    }
    const to: number = Math.max(0, Math.min(keys.length - 1, from + Math.trunc(delta)));
    if (to === from) {
      return false;
    }
    const moved: string[] = keys.splice(from, 1);
    keys.splice(to, 0, moved[0]);
    NavTabs.publish(keys);
    NavTabs.persist(keys);
    Logger.info('NAV_TABS', '调整底部入口顺序：' + NavTabs.title(key) + ' -> ' + String(to + 1));
    return true;
  }

  static reset(): void {
    const keys: string[] = NavTabs.DEFAULT_KEYS.slice();
    NavTabs.publish(keys);
    NavTabs.persist(keys);
    Logger.info('NAV_TABS', '恢复默认底部导航顺序');
  }

  private static publish(keys: string[]): void {
    AppStorage.setOrCreate<string[]>('navTabKeys', keys);
  }

  private static persist(keys: string[]): void {
    const snapshot: string = JSON.stringify(keys);
    const store: preferences.Preferences | undefined = NavTabs.store;
    if (store === undefined) {
      Logger.warn('NAV_TABS', '偏好存储未就绪，本次底部导航配置仅在本进程生效');
      return;
    }
    const target: preferences.Preferences = store;
    target.put(NavTabs.STORAGE_KEY, snapshot)
      .then(() => target.put(NavTabs.VERSION_KEY, NavTabs.VERSION))
      .then(() => target.flush())
      .catch((error: Error) => {
        Logger.error('NAV_TABS', '保存底部导航配置失败：' + String(error));
      });
  }
}

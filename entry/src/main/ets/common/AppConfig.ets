import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export class AppConfig {
  static readonly DEFAULT_BACKEND_DOMAIN: string = 'https://api.y11.top';
  static readonly DEFAULT_BACKEND_ACCOUNT: string = '3567883293';
  private static instance: AppConfig = new AppConfig();
  private static store?: preferences.Preferences;
  private static context?: common.UIAbilityContext;
  private static initialized: boolean = false;
  private static persistence: Promise<void> = Promise.resolve();

  backendDomain: string = AppConfig.DEFAULT_BACKEND_DOMAIN;
  backendAccount: string = AppConfig.DEFAULT_BACKEND_ACCOUNT;

  private constructor() {}

  static getInstance(): AppConfig {
    return AppConfig.instance;
  }

  static async init(context: common.UIAbilityContext): Promise<AppConfig> {
    AppConfig.context = context;
    try {
      AppConfig.store = await preferences.getPreferences(context, 'wuyin');
      const savedDomain: string = String(await AppConfig.store.get('backendDomain', AppConfig.DEFAULT_BACKEND_DOMAIN));
      const savedAccount: string = String(await AppConfig.store.get('backendAccount', AppConfig.DEFAULT_BACKEND_ACCOUNT));
      AppConfig.instance.backendDomain = AppConfig.isValidDomain(savedDomain) ? savedDomain : AppConfig.DEFAULT_BACKEND_DOMAIN;
      AppConfig.instance.backendAccount = savedAccount.trim() || AppConfig.DEFAULT_BACKEND_ACCOUNT;
      AppConfig.initialized = true;
    } catch (error) {
      AppConfig.instance.restoreBackendDomain();
      AppConfig.instance.restoreBackendAccount();
      throw new Error('配置初始化失败');
    }
    return AppConfig.instance;
  }

  static isValidDomain(value: string): boolean {
    const normalized: string = value.trim();
    const pattern: RegExp = /^https?:\/\/(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?::\\d+)?(?:[/?#].*)?$/i;
    return pattern.test(normalized);
  }

  private static ensureDomain(value: string): string {
    const normalized: string = value.trim().replace(/\/+$/, '');
    if (!AppConfig.isValidDomain(normalized)) {
      throw new Error('后端域名必须使用 http 或 https 协议');
    }
    return normalized;
  }

  private static ensureAccount(value: string): string {
    const normalized: string = value.trim();
    if (!normalized) {
      throw new Error('默认账号不能为空');
    }
    return normalized;
  }

  private async persist(): Promise<void> {
    AppConfig.persistence = AppConfig.persistence.then(async () => {
      if (!AppConfig.store) {
        if (!AppConfig.context) { throw new Error('配置存储未初始化'); }
        AppConfig.store = await preferences.getPreferences(AppConfig.context, 'wuyin');
      }
      await AppConfig.store.put('backendDomain', this.backendDomain);
      await AppConfig.store.put('backendAccount', this.backendAccount);
      await AppConfig.store.flush();
    });
    return AppConfig.persistence;
  }

  async setBackendDomain(value: string): Promise<void> {
    this.backendDomain = AppConfig.ensureDomain(value);
    await this.persist();
  }

  async setBackendAccount(value: string): Promise<void> {
    this.backendAccount = AppConfig.ensureAccount(value);
    await this.persist();
  }

  async restoreBackendDomain(): Promise<void> {
    this.backendDomain = AppConfig.DEFAULT_BACKEND_DOMAIN;
    await this.persist();
  }

  async restoreBackendAccount(): Promise<void> {
    this.backendAccount = AppConfig.DEFAULT_BACKEND_ACCOUNT;
    await this.persist();
  }

  isInitialized(): boolean {
    return AppConfig.initialized;
  }
}

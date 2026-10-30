import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

export interface TencentAuthorizationResult {
  openid: string;
  accessToken: string;
  nickname: string;
  avatar: string;
}

interface TencentSdkResponse {
  openid?: string;
  openId?: string;
  accessToken?: string;
  access_token?: string;
  nickname?: string;
  avatar?: string;
  figureurl_qq_2?: string;
  figureurl_2?: string;
  figureurl?: string;
  data?: TencentSdkResponse;
}

interface TencentSdkError {
  code?: string | number;
  message?: string;
}

interface TencentSdkLoginOptions {
  scope: string;
  targetPackage: string;
}

interface TencentSdkAuthListener {
  onComplete: (result: Object) => void;
  onError: (error: Error) => void;
  onCancel: () => void;
}

interface TencentSdkClient {
  login?: (options: TencentSdkLoginOptions,
    listener?: TencentSdkAuthListener) => Promise<Object | undefined> | Object | undefined;
}

interface TencentOpenApiFactory {
  createQQOpenApi?: (appId: string, context: common.UIAbilityContext) => TencentSdkClient;
}

// 保留命名空间及默认对象导出的适配；QQ、TIM只通过同一个工厂客户端登录。
interface TencentSdkModule {
  QQOpenApiFactory?: TencentOpenApiFactory;
  default?: TencentSdkModule;
}

export enum TencentProvider {
  QQ = 'QQ',
    TIM = 'TIM'
}

export class TencentSdkService {
  // @tencent/qq-open-sdk 仅提供 HarmonyOS HAP 形态，ArkUI-X（Android/iOS）不集成该 SDK。
  // 保持空模块，initializeSdk 会给出“SDK 未提供 QQOpenApiFactory”的明确提示，其余登录方式不受影响。
  private readonly rootModule: TencentSdkModule = {};
  private readonly appId: string = '102091604';
  // EntryAbility、QQ和TIM共用初始化任务与QQOpenApiFactory创建的实例。
  private qqInitialized: boolean = false;
  private qqInitializing?: Promise<void>;
  private client?: TencentSdkClient;

  async initializeQQOpenSdk(context: common.UIAbilityContext): Promise<void> {
    await this.initializeQQ(async (): Promise<void> => {
      await this.initializeSdk(context);
    });
  }

  async initializeQQ(initializer: () => Promise<void>): Promise<void> {
    if (this.qqInitialized) {
      return;
    }
    if (this.qqInitializing) {
      await this.qqInitializing;
      return;
    }
    const pending: Promise<void> = this.runQQInitialization(initializer);
    this.qqInitializing = pending;
    try {
      await pending;
      this.qqInitialized = true;
    } catch (error) {
      // 初始化失败不缓存实例或成功状态，任一登录入口都可重试。
      this.client = undefined;
      this.qqInitialized = false;
      const failure: Error = new Error(this.errorMessage(error as Error));
      throw failure;
    } finally {
      this.qqInitializing = undefined;
    }
  }

  private async runQQInitialization(initializer: () => Promise<void>): Promise<void> {
    try {
      Logger.info('LOGIN_SDK', '开始初始化QQ Open SDK，appId=102091604');
      await initializer();
      Logger.info('LOGIN_SDK', 'QQ Open SDK初始化完成，QQ与TIM共用授权实例');
    } catch (_) {
      // 不输出SDK原始异常或授权响应，避免凭证进入日志。
      Logger.error('LOGIN_SDK', 'QQ Open SDK初始化失败，请检查SDK依赖、appId及querySchemes配置');
      throw new Error('QQ登录SDK初始化失败，请稍后重试并检查SDK接入配置');
    }
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    // 保留原公共入口，但不再为TIM以裸context重新初始化SDK。
    await this.initializeQQOpenSdk(context);
  }

  private async initializeSdk(context: common.UIAbilityContext): Promise<void> {
    if (this.client) {
      return;
    }
    const sdk: TencentSdkModule = this.getSdkModule();
    const factory: TencentOpenApiFactory | undefined = sdk.QQOpenApiFactory;
    if (!factory || !factory.createQQOpenApi) {
      throw new Error('SDK未提供QQOpenApiFactory.createQQOpenApi，请核对QQ登录 SDK 接入配置');
    }
    // 仅创建一次，两个登录入口只在每次请求中切换targetPackage。
    const client: TencentSdkClient = factory.createQQOpenApi(this.appId, context);
    if (!client || !client.login) {
      throw new Error('QQOpenApiFactory未返回可用的login授权实例，请核对SDK接入配置');
    }
    this.client = client;
  }

  async authorize(context: common.UIAbilityContext, provider: TencentProvider): Promise<TencentAuthorizationResult> {
    try {
      await this.initializeQQOpenSdk(context);
      const client: TencentSdkClient | undefined = this.client;
      if (!client || !client.login) {
        throw new Error('QQ/TIM共享授权实例尚未就绪，请重试登录');
      }
      const options: TencentSdkLoginOptions = {
        scope: 'all',
          targetPackage: provider === TencentProvider.QQ ? 'com.tencent.mobileqq' : 'com.tencent.tim'
      };
      Logger.info('LOGIN_SDK', provider + '开始调用SDK授权入口，targetPackage=' + options.targetPackage);
      const result: Object = await this.requestAuthorization(client, options, provider);
      const authorization: TencentAuthorizationResult = this.normalizeResult(result);
      // 不记录授权返回正文、openid或访问凭证。
      Logger.info('LOGIN_SDK', provider + '授权结果解析成功');
      return authorization;
    } catch (error) {
      Logger.error('LOGIN_SDK', provider + '授权调用失败：' + this.errorMessage(error as Error));
      throw new Error(provider + '登录SDK调用失败：' + this.errorMessage(error as Error));
    }
  }

  private requestAuthorization(client: TencentSdkClient, options: TencentSdkLoginOptions,
    provider: TencentProvider): Promise<Object> {
    return new Promise<Object>((resolve, reject) => {
      let settled: boolean = false;
      const complete = (result: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(result);
      };
      const failLaunch = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error(provider + '客户端拉起失败，请确认已安装并可正常打开后重试：' +
        this.errorMessage(error)));
      };
      const listener: TencentSdkAuthListener = {
        onComplete: (result: Object): void => {
          complete(result);
        },
          onError: (error: Error): void => {
          if (settled) {
            return;
          }
          settled = true;
          reject(new Error(provider + '授权失败：' + this.errorMessage(error)));
        },
          onCancel: (): void => {
          if (settled) {
            return;
          }
          settled = true;
          reject(new Error(provider + '授权已取消'));
        }
      };
      try {
        if (!client.login) {
          throw new Error('SDK未提供login授权方法');
        }
        // 同步拉起异常与异步拒绝均交回页面处理，避免未捕获异常。
        const pending: Promise<Object | undefined> | Object | undefined = client.login(options, listener);
        Promise.resolve<Object | undefined>(pending).then((result: Object | undefined): void => {
          // 回调型接口可能只返回拉起状态，授权结果仍等待监听回调。
          if (result !== undefined && result !== null &&
            (typeof result === 'object' || typeof result === 'string')) {
            complete(result);
          }
        }, (error: Error): void => {
          failLaunch(error);
        });
      } catch (error) {
        failLaunch(error as Error);
      }
    });
  }

  private getSdkModule(): TencentSdkModule {
    const sdk: TencentSdkModule = this.rootModule;
    if (sdk.QQOpenApiFactory) {
      return sdk;
    }
    return sdk.default || sdk;
  }

  private normalizeResult(result: Object): TencentAuthorizationResult {
    let response: TencentSdkResponse = result as TencentSdkResponse;
    if (typeof result === 'string') {
      try {
        response = JSON.parse(result) as TencentSdkResponse;
      } catch (_) {
        // 不将可能包含访问凭证的SDK原始响应拼接进错误消息。
        throw new Error('SDK返回结果不是有效JSON');
      }
    }
    if (!response || typeof response !== 'object' || Array.isArray(response)) {
      throw new Error('SDK返回的授权结果格式无效');
    }
    const data: TencentSdkResponse = response.data || response;
    if (typeof data !== 'object' || Array.isArray(data)) {
      throw new Error('SDK返回的授权数据格式无效');
    }
    const openid: string = String(data.openid || data.openId || response.openid || response.openId || '').trim();
    const accessToken: string = String(data.accessToken || data.access_token ||
      response.accessToken || response.access_token || '').trim();
    if (!openid || !accessToken) {
      throw new Error('SDK未返回openid或access_token');
    }
    return {
      openid: openid,
        accessToken: accessToken,
        nickname: String(data.nickname || response.nickname || ''),
        avatar: String(data.figureurl_qq_2 || data.figureurl_2 || data.figureurl || data.avatar ||
        response.figureurl_qq_2 || response.figureurl_2 || response.figureurl || response.avatar || '')
    };
  }

  private errorMessage(error: Error): string {
    const detail: TencentSdkError = error as TencentSdkError;
    let message: string = error instanceof Error ? (error.message || '未知错误') :
      (detail && detail.message ? detail.message : '未知错误');
    message = message.replace(/((?:access_token|accessToken|refresh_token|refreshToken|authorizationCode|password|pass|openid|openId)["']?\s*[:=]\s*["']?)[^&\s,"'}]+/gi,
    '$1***');
  if (detail && detail.code !== undefined) {
    message += '（错误码：' + String(detail.code) + '）';
  }
  return message;
}
}

export const TencentSDK: TencentSdkService = new TencentSdkService();

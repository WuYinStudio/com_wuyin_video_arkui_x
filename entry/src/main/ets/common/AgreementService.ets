import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

// 同意状态以磁盘偏好为准；AppStorage 只负责 @StorageLink 的实时页面同步。
export class AgreementService {
  static async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      // 读取失败时保持未同意，绝不能让首次使用者跳过免责声明。
      AppStorage.setOrCreate('agreementAccepted', false);
      const store = await preferences.getPreferences(context, 'wuyin');
      const accepted: boolean = (await store.get('agreementAccepted', false)) === true;
      AppStorage.setOrCreate('agreementAccepted', accepted);
      if (!accepted) { Logger.info('UserAgreement', '首次启动或尚未同意，展示免责声明'); }
    } catch (error) {
      AppStorage.setOrCreate('agreementAccepted', false);
      Logger.error('UserAgreement', '读取协议状态失败，继续展示免责声明：' + String(error));
    }
  }

  static async accept(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, 'wuyin');
      await store.put('agreementAccepted', true);
      await store.flush();
      // 仅在持久化成功后放行首页，避免写盘失败时错误地视作已同意。
      AppStorage.setOrCreate('agreementAccepted', true);
      Logger.info('UserAgreement', '用户同意免责声明，已持久化');
    } catch (error) {
      Logger.error('UserAgreement', '保存同意状态失败：' + String(error));
      throw new Error('保存同意状态失败：' + String(error));
    }
  }
}

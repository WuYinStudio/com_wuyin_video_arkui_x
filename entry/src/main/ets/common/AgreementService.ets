import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { Logger } from './Logger';

// 同意状态以磁盘为准；AppStorage 只负责 @StorageLink 的实时页面同步。
export class AgreementService {
  private static markerPath(context: common.UIAbilityContext): string {
    try {
      return context.filesDir + '/agreement_accepted.txt';
    } catch (error) {
      Logger.error('UserAgreement', '读取 filesDir 失败：' + String(error));
      return '';
    }
  }

  private static readMarker(context: common.UIAbilityContext): boolean {
    try {
      const path: string = AgreementService.markerPath(context);
      if (path.length > 0 && fs.accessSync(path)) {
        return fs.readTextSync(path).trim() === '1';
      }
    } catch (error) {
      Logger.error('UserAgreement', '读取协议标记失败：' + String(error));
    }
    return false;
  }

  private static writeMarker(context: common.UIAbilityContext): boolean {
    try {
      const path: string = AgreementService.markerPath(context);
      if (path.length > 0) {
        const file = fs.openSync(path,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, '1');
        fs.closeSync(file);
        return true;
      }
    } catch (error) {
      Logger.error('UserAgreement', '写入协议标记失败：' + String(error));
    }
    return false;
  }

  static async restore(context: common.UIAbilityContext): Promise<void> {
    AppStorage.setOrCreate('agreementAccepted', false);
    let accepted: boolean = false;
    try {
      const store = await preferences.getPreferences(context, 'wuyin');
      accepted = (await store.get('agreementAccepted', false)) === true;
    } catch (error) {
      Logger.error('UserAgreement', '读取偏好失败，尝试文件标记：' + String(error));
    }
    if (!accepted) {
      accepted = AgreementService.readMarker(context);
    }
    AppStorage.setOrCreate('agreementAccepted', accepted);
    if (!accepted) { Logger.info('UserAgreement', '首次启动或尚未同意，展示免责声明'); }
  }

  static async accept(context: common.UIAbilityContext): Promise<void> {
    let saved: boolean = false;
    try {
      const store = await preferences.getPreferences(context, 'wuyin');
      await store.put('agreementAccepted', true);
      await store.flush();
      saved = true;
    } catch (error) {
      Logger.error('UserAgreement', '偏好保存失败，尝试文件标记：' + String(error));
    }
    // iOS 上 preferences 可能不可用；文件标记作为兜底，确保能进入首页。
    const fileSaved: boolean = AgreementService.writeMarker(context);
    if (!saved && !fileSaved) {
      Logger.error('UserAgreement', '协议状态无法持久化，本次会话内放行');
    }
    AppStorage.setOrCreate('agreementAccepted', true);
    Logger.info('UserAgreement', '用户同意免责声明，已持久化：' + String(saved || fileSaved));
  }
}

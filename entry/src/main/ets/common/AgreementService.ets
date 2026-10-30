import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';

/**
 * 同意状态以磁盘为准；AppStorage 只负责 @StorageLink 的实时页面同步。
 *
 * iOS 上 `@ohos.data.preferences` 的原生实现可能缺失（与 Android 早期缺插件 .so 同类），
 * 调用会直接抛异常，导致「同意协议」按钮只能报错、进不了首页。这里做两级存储：
 * 先 preferences，失败后退回 filesDir 下的 JSON 标记文件（fileIo 三端都有）。
 * 两级都失败时仍然放行本次启动（内存态置 true），只提示状态未能长期保存。
 */
export class AgreementService {
  private static readonly PREF: string = 'wuyin';
  private static readonly KEY: string = 'agreementAccepted';
  private static readonly FILE: string = 'agreement_accepted.json';

  private static flagPath(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + AgreementService.FILE;
  }

  static async restore(context: common.UIAbilityContext): Promise<void> {
    let accepted: boolean = false;
    try {
      const store = await preferences.getPreferences(context, AgreementService.PREF);
      accepted = (await store.get(AgreementService.KEY, false)) === true;
    } catch (error) {
      Logger.warn('UserAgreement', '偏好读取失败，改用文件标记：' + String(error));
    }
    if (!accepted) {
      accepted = AgreementService.readFlag(context);
    }
    AppStorage.setOrCreate('agreementAccepted', accepted);
    Logger.info('UserAgreement', accepted ? '已同意过免责声明' : '首次启动或尚未同意，展示免责声明');
  }

  /** 返回是否成功持久化；无论是否落盘，都会把内存态置为已同意，保证本次能进首页。 */
  static async accept(context: common.UIAbilityContext): Promise<boolean> {
    let persisted: boolean = false;
    try {
      const store = await preferences.getPreferences(context, AgreementService.PREF);
      await store.put(AgreementService.KEY, true);
      await store.flush();
      persisted = true;
    } catch (error) {
      Logger.warn('UserAgreement', '偏好写入失败，改用文件标记：' + String(error));
    }
    if (!persisted) {
      persisted = AgreementService.writeFlag(context);
    }
    AppStorage.setOrCreate('agreementAccepted', true);
    Logger.info('UserAgreement',
      persisted ? '用户同意免责声明，已持久化' : '用户同意免责声明，仅本次生效（本机存储不可用）');
    return persisted;
  }

  private static readFlag(context: common.UIAbilityContext): boolean {
    try {
      const path: string = AgreementService.flagPath(context);
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) { return false; }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        const bytes: Uint8Array = new Uint8Array(buffer);
        for (let index: number = 0; index < read; index++) {
          text += String.fromCharCode(bytes[index]);
        }
      } finally {
        fileIo.closeSync(file);
      }
      return text.indexOf('true') >= 0;
    } catch (error) {
      Logger.warn('UserAgreement', '读取文件标记失败：' + String(error));
      return false;
    }
  }

  private static writeFlag(context: common.UIAbilityContext): boolean {
    try {
      const path: string = AgreementService.flagPath(context);
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, '{"accepted":true}');
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (error) {
      Logger.warn('UserAgreement', '写入文件标记失败：' + String(error));
      return false;
    }
  }
}

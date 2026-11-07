import common from '@ohos.app.ability.common';
import { PlatformBridge } from './PlatformBridge';
import { PlatformInfo } from './PlatformInfo';

/** 一条后台通知内容。 */
export class ChatNotificationPayload {
  title: string = '';
  text: string = '';
  summary: string = '';
  room: string = '';
  peer: string = '';
}

/**
 * 跨平台通知兼容层。
 *
 * HarmonyOS 使用 NotificationKit；Android / iOS 需要原生通知通道。
 * 首版返回不可用并跳过通知，不影响聊天室本身。
 * 后续通过 PlatformBridge 接 Android NotificationManager / iOS UNUserNotificationCenter。
 */
export class NotificationService {
  static readonly NOTIFICATION_ID: number = 1001;
  static readonly APP_LABEL: string = '无音影视';

  static async ensurePermission(context: common.UIAbilityContext): Promise<boolean> {
    if (PlatformInfo.isAndroid()) {
      if (await PlatformBridge.hasNotificationPermission()) { return true; }
      await PlatformBridge.requestNotificationPermission();
      for (let index: number = 0; index < 20; index++) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 300); });
        if (await PlatformBridge.hasNotificationPermission()) { return true; }
      }
      return false;
    }
    return PlatformInfo.isIOS();
  }

  static async enabled(): Promise<boolean> {
    return false;
  }

  static async publish(context: common.UIAbilityContext, payload: ChatNotificationPayload): Promise<void> {
    const body: string = payload.summary.length > 0 ? payload.summary : payload.text;
    await PlatformBridge.notify(payload.title, body, NotificationService.NOTIFICATION_ID);
  }

  static async cancelAll(): Promise<void> {
  }
}

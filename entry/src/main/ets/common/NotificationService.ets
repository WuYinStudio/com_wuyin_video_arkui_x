import { common, Want } from '@kit.AbilityKit';
import { WantAgent, WantAgentInfo, OperationType, WantAgentFlags, getWantAgent } from './compat/WantAgentCompat';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { PlatformApi } from './compat/PlatformApi';

/**
 * 一条后台通知栏提醒的内容。
 *
 * 只放纯数据（不引用 ChatAlertService 的类型），避免 NotificationService 与
 * ChatAlertService 互相 import 形成循环依赖。
 */
export class ChatNotificationPayload {
  title: string = '';
  text: string = '';
  summary: string = '';
  room: string = '';
  peer: string = '';
}

/**
 * 系统通知栏提醒（前台弹窗之外的第二种提醒形态）。
 *
 * - 应用退到后台时由 ChatAlertService 调用 publish()，把新消息发到通知栏；
 * - 点击通知拉起应用，并把 chatRoom / chatPeer 通过 Want.parameters 带到 EntryAbility，
 *   由 EntryAbility 跳到对应聊天室；
 * - 同一 id 反复 publish 会就地更新同一条通知，不会刷出一堆通知；
 * - 未授予通知权限时 publish 会失败（1600004），这里统一 catch 并降级为"只记录日志"。
 */
export class NotificationService {
  /** 聊天提醒固定使用同一个通知 id：新消息就地更新，不堆叠。 */
  static readonly NOTIFICATION_ID: number = 1001;
  /** 系统通知栏的按钮/文案统一用的应用名。 */
  static readonly APP_LABEL: string = '无音影视';
  private static agent?: WantAgent;

  /** 查询通知权限；未开启时主动拉起系统的"允许通知"询问。 */
  static async ensurePermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await NotificationService.enabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      const granted: boolean = await NotificationService.enabled();
      Logger.info('CHAT_NOTIFY', granted ? '已获得通知权限' : '用户未允许通知');
      return granted;
    } catch (error) {
      Logger.warn('CHAT_NOTIFY', '申请通知权限失败：' + String(error));
      return false;
    }
  }

  static async enabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      Logger.warn('CHAT_NOTIFY', '查询通知权限失败：' + String(error));
      return false;
    }
  }

  /** 发一条（或就地更新）聊天提醒通知；点击可直接进入对应聊天室。 */
  static async publish(context: common.UIAbilityContext, payload: ChatNotificationPayload): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: NotificationService.NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: payload.title,
            text: payload.text,
            additionalText: payload.summary
          }
        }
      };
      const agent: WantAgent | undefined = await NotificationService.buildAgent(context, payload);
      if (agent !== undefined) {
        PlatformApi.attachWantAgent(request, agent as Object);
      }
      await notificationManager.publish(request);
      Logger.info('CHAT_NOTIFY', '已发布通知栏提醒：' + payload.title + '，' + payload.text);
    } catch (error) {
      const detail: BusinessError = error as BusinessError;
      Logger.warn('CHAT_NOTIFY', '发布通知栏提醒失败（code=' + String(detail.code) + '）：' + String(detail.message));
    }
  }

  /** 点通知把应用拉起来，并带上聊天室参数。 */
  private static async buildAgent(context: common.UIAbilityContext,
    payload: ChatNotificationPayload): Promise<WantAgent | undefined> {
    try {
      if (NotificationService.agent !== undefined && (payload.room === '' || payload.peer === '')) {
        // 无房间参数时复用同一个 Agent（纯拉起应用）。
        return NotificationService.agent;
      }
      const parameters: Record<string, string> = {
        'chatRoom': payload.room,
        'chatPeer': payload.peer
      };
      const want: Want = {
        bundleName: NotificationService.bundleName(context),
        abilityName: 'EntryAbility',
        parameters: parameters
      };
      const info: WantAgentInfo = {
        wants: [want],
        operationType: OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await getWantAgent(info);
      if (payload.room === '' && payload.peer === '') {
        NotificationService.agent = agent;
      }
      return agent;
    } catch (error) {
      Logger.warn('CHAT_NOTIFY', '创建通知点击意图失败：' + String(error));
      return undefined;
    }
  }

  private static bundleName(context: common.UIAbilityContext): string {
    try {
      const name: string = context.abilityInfo.bundleName;
      return name && name.length > 0 ? name : 'com.wuyin.video';
    } catch (error) {
      return 'com.wuyin.video';
    }
  }

  /** 清掉聊天提醒通知（回到前台、或用户全部忽略时调用）。 */
  static async cancelAll(): Promise<void> {
    try {
      await PlatformApi.cancelNotification(NotificationService.NOTIFICATION_ID);
    } catch (error) {
      // 通知不存在时也会抛错，这里不当作异常处理。
      Logger.warn('CHAT_NOTIFY', '清除通知栏提醒失败：' + String(error));
    }
  }
}

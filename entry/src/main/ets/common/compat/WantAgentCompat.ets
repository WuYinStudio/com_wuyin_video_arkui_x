/**
 * WantAgent 跨平台适配层。
 * Android/iOS 的通知点击由平台工程处理，这里不再创建跨 Ability 的 WantAgent；
 * 调用方 NotificationService 已对异常做兜底（无点击意图也能正常发通知）。
 */

export class WantAgent {
  constructor() {
  }
}

export interface WantAgentInfo {
  wants: Object[];
  operationType: number;
  requestCode: number;
  wantAgentFlags: number[];
  actionFlags?: number[];
}

export enum OperationType {
  UNKNOWN_TYPE = 0,
  START_ABILITY = 1,
  START_SERVICE = 2,
  SEND_COMMON_EVENT = 3
}

export enum WantAgentFlags {
  ONE_TIME_FLAG = 0,
  NO_BUILD_FLAG = 1,
  CANCEL_PRESENT_FLAG = 2,
  UPDATE_PRESENT_FLAG = 3,
  CONSTANT_FLAG = 4
}

export async function getWantAgent(info: WantAgentInfo): Promise<WantAgent> {
  throw new Error('当前平台不支持通知点击拉起指定页面');
}

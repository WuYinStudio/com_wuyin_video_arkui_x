import { common } from '@kit.AbilityKit';

/** WantAgent 跨平台占位：Android / iOS 由原生后台服务接管。 */
export namespace wantAgent {
  export enum OperationType {
    START_ABILITY = 0,
    START_SERVICE = 1,
    SEND_COMMON_EVENT = 2
  }

  export enum WantAgentFlags {
    UPDATE_PRESENT_FLAG = 0,
    CONSTANT_FLAG = 1,
    RENEW_FLAG = 2
  }

  export interface WantAgentWant {
    bundleName: string;
    abilityName: string;
  }

  export interface WantAgentInfo {
    wants: WantAgentWant[];
    actionType: OperationType;
    requestCode: number;
    actionFlags?: WantAgentFlags[];
  }

  export async function getWantAgent(info: WantAgentInfo): Promise<Object> {
    return new Object();
  }
}

/** 后台连续任务占位。 */
export namespace backgroundTaskManager {
  export async function startBackgroundRunning(context: common.UIAbilityContext,
    modes: string[], agent: Object): Promise<void> {
  }

  export async function stopBackgroundRunning(context: common.UIAbilityContext): Promise<void> {
  }
}

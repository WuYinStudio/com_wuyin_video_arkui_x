import common from '@ohos.app.ability.common';
import { PlatformBridge } from './PlatformBridge';

/**
 * 画中画兼容层。
 * HarmonyOS 使用 PiPWindow；Android / iOS 需要原生 PiP。
 * 未接原生桥前返回不可用，避免编译依赖 HarmonyOS 专属 API。
 */
export namespace PiPWindow {
  export enum PiPTemplateType {
    VIDEO_PLAY = 0,
    VIDEO_CALL = 1,
    VIDEO_MEETING = 2,
    VIDEO_LIVE = 3
  }

  export interface PiPController {
    startPiP(): Promise<void>;
    stopPiP(): Promise<void>;
    updateContentNode(node: Object): void;
  }

  export interface PiPOptions {
    context: common.UIAbilityContext;
    componentController: Object;
    templateType: PiPTemplateType;
  }

  export class PiPControllerImpl implements PiPController {
    async startPiP(): Promise<void> {
      const entered: boolean = await PlatformBridge.enterPip();
      if (!entered) { throw new Error('当前平台暂不支持画中画'); }
    }

    async stopPiP(): Promise<void> {
    }

    updateContentNode(_node: Object): void {
    }
  }

  export function isPiPEnabled(): boolean {
    return true;
  }

  export async function create(options: PiPOptions): Promise<PiPController> {
    return new PiPControllerImpl();
  }
}

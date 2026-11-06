import { common } from '@kit.AbilityKit';
import { PlatformBridge } from './PlatformBridge';
import { PlatformInfo } from './PlatformInfo';

/**
 * 跨平台实况窗兼容层。
 *
 * HarmonyOS 使用 LiveViewKit；Android 使用低优先级常驻进度通知；
 * iOS 暂无 Live Activity 扩展，保持不可用。
 */
export class LiveViewService {
  private static readonly ID: number = 730001;

  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    return PlatformInfo.isAndroid();
  }

  static async openSettings(context: common.UIAbilityContext): Promise<void> {
  }

  static async showCache(title: string, episode: string, percent: number): Promise<void> {
    if (!PlatformInfo.isAndroid()) { return; }
    await PlatformBridge.showLiveView(title, episode, Math.max(0, Math.min(100, Math.round(percent))),
      LiveViewService.ID);
  }

  static async hide(): Promise<void> {
    if (!PlatformInfo.isAndroid()) { return; }
    await PlatformBridge.hideLiveView(LiveViewService.ID);
  }
}

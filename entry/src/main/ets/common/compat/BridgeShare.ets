import bridge from '@arkui-x.bridge';

/**
 * 平台桥接：调用 .arkui-x/android 中 WuYinShareBridge.shareText()，
 * iOS 侧未注册同名 Bridge 时会走剪贴板兜底。
 * 注意：@arkui-x.bridge 由 ArkUI-X SDK 提供，纯 HarmonyOS HAP 构建请使用
 * legacy/harmonyos-only 中的 ShareKit 版本。
 */
export class BridgeShare {
  private static impl: bridge.BridgeObject | undefined = undefined;
  private static unavailable: boolean = false;

  private static instance(): bridge.BridgeObject | undefined {
    if (BridgeShare.impl !== undefined) { return BridgeShare.impl; }
    if (BridgeShare.unavailable) { return undefined; }
    try {
      BridgeShare.impl = bridge.createBridge('WuYinShare');
      return BridgeShare.impl;
    } catch (error) {
      BridgeShare.unavailable = true;
      return undefined;
    }
  }

  static async shareText(title: string, content: string): Promise<boolean> {
    const impl: bridge.BridgeObject | undefined = BridgeShare.instance();
    if (impl === undefined) { return false; }
    try {
      await impl.callMethod('shareText', title, content);
      return true;
    } catch (error) {
      return false;
    }
  }
}

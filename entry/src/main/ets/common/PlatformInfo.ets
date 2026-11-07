/**
 * 运行平台识别。
 *
 * 当前 iOS 壳没有提供 @ohos.deviceInfo，不能静态依赖它；
 * 本工程只构建 iOS，因此直接固定为 iOS，避免设置页/聊天/播放器在模块加载时闪退。
 */
export enum PlatformType {
  HARMONYOS = 'HarmonyOS',
  ANDROID = 'Android',
  IOS = 'iOS',
  UNKNOWN = 'Unknown'
}

export class PlatformInfo {
  static type(): PlatformType {
    return PlatformType.IOS;
  }

  static isHarmonyOS(): boolean { return false; }
  static isAndroid(): boolean { return false; }
  static isIOS(): boolean { return true; }

  /** 用于提示文案与日志，不参与业务分支。 */
  static label(): string {
    if (PlatformInfo.isHarmonyOS()) { return 'HarmonyOS'; }
    if (PlatformInfo.isAndroid()) { return 'Android'; }
    if (PlatformInfo.isIOS()) { return 'iOS'; }
    return '未知平台';
  }
}

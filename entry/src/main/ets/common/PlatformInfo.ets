import deviceInfo from '@ohos.deviceInfo';

/**
 * 运行平台识别。
 * ArkUI-X 用同一份 abc 跑在 HarmonyOS / Android / iOS 上，
 * 系统专有能力必须按平台分流，不能假定 deviceInfo 的字段在 Android/iOS 都存在。
 */
export enum PlatformType {
  HARMONYOS = 'HarmonyOS',
  ANDROID = 'Android',
  IOS = 'iOS',
  UNKNOWN = 'Unknown'
}

export class PlatformInfo {
  private static cached: PlatformType = PlatformType.UNKNOWN;
  private static resolved: boolean = false;

  static type(): PlatformType {
    if (PlatformInfo.resolved) { return PlatformInfo.cached; }
    let fullName: string = '';
    try { fullName = String(deviceInfo.osFullName || ''); } catch (error) { fullName = ''; }
    let value: PlatformType = PlatformType.UNKNOWN;
    if (fullName.indexOf('OpenHarmony') >= 0 || fullName.indexOf('HarmonyOS') >= 0) {
      value = PlatformType.HARMONYOS;
    } else if (fullName.indexOf('Android') >= 0) {
      value = PlatformType.ANDROID;
    } else if (fullName.indexOf('iOS') >= 0) {
      value = PlatformType.IOS;
    }
    PlatformInfo.cached = value;
    PlatformInfo.resolved = true;
    return value;
  }

  static isHarmonyOS(): boolean { return PlatformInfo.type() === PlatformType.HARMONYOS; }
  static isAndroid(): boolean { return PlatformInfo.type() === PlatformType.ANDROID; }
  static isIOS(): boolean { return PlatformInfo.type() === PlatformType.IOS; }

  /** 用于提示文案与日志，不参与业务分支。 */
  static label(): string {
    if (PlatformInfo.isHarmonyOS()) { return 'HarmonyOS'; }
    if (PlatformInfo.isAndroid()) { return 'Android'; }
    if (PlatformInfo.isIOS()) { return 'iOS'; }
    return '未知平台';
  }
}

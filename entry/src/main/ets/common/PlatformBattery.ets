import { PlatformBridge } from './PlatformBridge';

/** 电量跨平台占位：未接原生电池桥时返回固定值。 */
export class BatteryInfo {
  batterySOC: number = 100;
  chargingStatus: number = 0;
}

export const batteryInfo: BatteryInfo = new BatteryInfo();

/** 从原生桥刷新电量。 */
export async function refreshBattery(): Promise<void> {
  try {
    batteryInfo.batterySOC = await PlatformBridge.batteryPercent();
  } catch (_) {
  }
}

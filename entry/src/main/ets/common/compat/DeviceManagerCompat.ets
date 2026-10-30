import { util } from '@kit.ArkTS';
import { Logger } from '../Logger';

/**
 * distributedDeviceManager（分布式设备发现）跨平台适配层。
 *
 * ArkUI-X 未适配 @ohos.distributedDeviceManager：Android/iOS 没有 HarmonyOS 的
 * 分布式软总线。本适配层返回稳定可用的本地设备标识，但不提供系统级设备发现；
 * 协播页的局域网设备列表改由 CoPlayLanService 已有的 UDP 广播（probe/hello）填充。
 */

export interface DeviceBasicInfo {
  deviceId: string;
  deviceName: string;
  networkId?: string;
  deviceType?: string;
}

export enum DeviceStateChange {
  AVAILABLE = 0,
  UNAVAILABLE = 1
}

export class DeviceManager {
  private localDeviceId: string = '';
  private localNetworkId: string = '';

  constructor(bundleName: string) {
    const suffix: string = util.generateRandomUUID(true).replace(/-/g, '').slice(0, 12);
    this.localDeviceId = 'wuyin-' + suffix;
    this.localNetworkId = 'wuyin-net-' + suffix;
    Logger.info('CO_PLAYBACK', '【CoPlay][LAN] 使用跨平台设备标识，bundle=' + bundleName +
      '，deviceId=' + this.localDeviceId);
  }

  getLocalDeviceId(): string {
    return this.localDeviceId;
  }

  getLocalDeviceNetworkId(): string {
    return this.localNetworkId;
  }

  startDiscovering(parameters: Record<string, Object>, filters: Record<string, Object>): void {
    // 无系统级发现能力；由 UDP 广播发现替代。
  }

  stopDiscovering(): void {
  }

  getAvailableDeviceListSync(): DeviceBasicInfo[] {
    return [];
  }

  on(type: string, ...args: Object[]): void {
  }

  off(type: string, ...args: Object[]): void {
  }

  release(): void {
  }
}

export function createDeviceManager(bundleName: string): DeviceManager {
  return new DeviceManager(bundleName);
}

/**
 * 分布式设备管理兼容层。
 *
 * CoPlayLanService 保持原有调用形状；未接原生发现桥时返回空设备列表。
 * Android / iOS 的局域网发现后续由原生 Bridge 提供。
 */
export namespace distributedDeviceManager {
  export enum DeviceStateChange {
    AVAILABLE = 0,
    UNAVAILABLE = 1
  }

  export interface DeviceBasicInfo {
    deviceId: string;
    deviceName: string;
    networkId: string;
    deviceType?: string;
  }

  type Listener = Object;

  export class DeviceManager {
    private localId: string = 'local-' + String(Date.now());

    getLocalDeviceId(): string {
      return this.localId;
    }

    getLocalDeviceNetworkId(): string {
      return 'net-' + this.localId;
    }

    getAvailableDeviceListSync(): DeviceBasicInfo[] {
      return [];
    }

    getTrustedDeviceListSync(): DeviceBasicInfo[] {
      return [];
    }

    startDiscovering(parameters?: Object, filters?: Object): void {
    }

    stopDiscovering(): void {
    }

    on(event: string, callback: Listener): void {
    }

    off(event: string, callback?: Listener): void {
    }

    authenticateDevice(deviceId: string, extra?: Object): Promise<Object> {
      return Promise.reject(new Error('当前平台暂不支持分布式设备认证'));
    }
  }

  export function createDeviceManager(bundleName: string): DeviceManager {
    return new DeviceManager();
  }
}

import bridge from '@arkui-x.bridge';
import { Logger } from './Logger';

/**
 * ArkUI-X 原生桥。
 *
 * Android / iOS 侧注册同名 BridgePlugin（WuyinPlatformBridge），
 * 负责系统分享、打开链接、电量等 HarmonyOS Kit 之外的平台能力。
 */
export class PlatformBridge {
  private static instance?: bridge.BridgeObject;

  private static ensure(): bridge.BridgeObject {
    if (PlatformBridge.instance === undefined) {
      PlatformBridge.instance = bridge.createBridge('WuyinPlatformBridge');
    }
    return PlatformBridge.instance;
  }

  static async shareText(text: string, title: string): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('shareText', text, title);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      Logger.warn('PLATFORM_BRIDGE', '原生分享失败：' + String(error));
      return false;
    }
  }

  static async shareFile(path: string, title: string, mime: string): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('shareFile', path, title, mime);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      Logger.warn('PLATFORM_BRIDGE', '原生文件分享失败：' + String(error));
      return false;
    }
  }

  static async openUrl(url: string): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('openUrl', url);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      Logger.warn('PLATFORM_BRIDGE', '原生打开链接失败：' + String(error));
      return false;
    }
  }

  static async startCameraScan(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('startCameraScan');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async isScanFinished(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('isScanFinished');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return true;
    }
  }

  static async lastScanResult(): Promise<string> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('getLastScanResult');
      return result === undefined || result === null ? '' : String(result);
    } catch (error) {
      return '';
    }
  }

  static async decodeQr(uri: string): Promise<string> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('decodeQr', uri);
      return result === undefined || result === null ? '' : String(result);
    } catch (error) {
      return '';
    }
  }

  static async hasNotificationPermission(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('hasNotificationPermission');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async requestNotificationPermission(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('requestNotificationPermission');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async showLiveView(title: string, episode: string, percent: number, id: number): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('showLiveView', title, episode, percent, id);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async hideLiveView(id: number): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('hideLiveView', id);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async copyText(text: string): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('copyText', text);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async hasMicrophonePermission(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('hasMicrophonePermission');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async requestMicrophonePermission(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('requestMicrophonePermission');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async enterPip(): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('enterPip');
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async setFrameRate(hz: number): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('setFrameRate', hz);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      return false;
    }
  }

  static async notify(title: string, text: string, id: number): Promise<boolean> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('showNotification', title, text, id);
      return String(result) === 'true' || String(result) === '1';
    } catch (error) {
      Logger.warn('PLATFORM_BRIDGE', '原生通知失败：' + String(error));
      return false;
    }
  }

  static async batteryPercent(): Promise<number> {
    try {
      const result: bridge.ResultValue = await PlatformBridge.ensure().callMethod('batteryPercent');
      const value: number = Number(result);
      return Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 100;
    } catch (error) {
      return 100;
    }
  }
}

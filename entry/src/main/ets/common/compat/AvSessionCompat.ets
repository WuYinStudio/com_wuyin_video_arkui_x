import { common } from '@kit.AbilityKit';

/**
 * AVSession（系统级协同同播会话）跨平台适配层。
 *
 * ArkUI-X 未适配 @ohos.multimedia.avsession：Android/iOS 上没有系统媒体会话、
 * 投送设备枚举与跨设备控制通路。原 MediaSessionDialog 的「局域网系统会话」模式
 * 在这些平台不可用，创建/入会会直接失败并提示改用「服务器模式」；
 * 「服务器模式」走原有 WebSocket 信令，完全跨平台。
 *
 * 类型与成员保持与原 SDK 同名，避免改动 1300 行的 UI 与业务代码。
 */

export enum PlaybackState {
  PLAYBACK_STATE_INITIAL = 0,
  PLAYBACK_STATE_PREPARING = 1,
  PLAYBACK_STATE_PLAY = 2,
  PLAYBACK_STATE_PAUSE = 3,
  PLAYBACK_STATE_FAST_FORWARD = 4,
  PLAYBACK_STATE_REWIND = 5,
  PLAYBACK_STATE_STOP = 6,
  PLAYBACK_STATE_COMPLETED = 7,
  PLAYBACK_STATE_RELEASED = 8,
  PLAYBACK_STATE_ERROR = 9
}

export enum ConnectionState {
  STATE_CONNECTING = 0,
  STATE_CONNECTED = 1,
  STATE_DISCONNECTED = 6
}

export interface AVPlaybackPosition {
  elapsedTime: number;
  updateTime: number;
}

export interface AVPlaybackState {
  state: PlaybackState;
  speed: number;
  position: AVPlaybackPosition;
}

export interface AVMetadata {
  assetId?: string;
  title?: string;
  artist?: string;
}

export interface DeviceInfo {
  deviceId: string;
  deviceName: string;
  deviceType?: string;
}

export interface OutputDeviceInfo {
  devices: DeviceInfo[];
}

function notSupported(): Error {
  return new Error('当前平台不支持系统协同同播会话，请改用服务器模式');
}

export class AVCastController {
  async getAVPlaybackState(): Promise<AVPlaybackState> {
    throw notSupported();
  }

  on(type: string, ...args: Object[]): void {
    // 平台不支持，回调永远不会触发。
  }

  off(type: string, ...args: Object[]): void {
  }

  async sendCommonCommand(command: string, args: Record<string, Object>): Promise<void> {
    throw notSupported();
  }
}

export class AVSession {
  sessionId: string = '';

  async activate(): Promise<void> {
    throw notSupported();
  }

  async destroy(): Promise<void> {
  }

  on(type: string, ...args: Object[]): void {
  }

  off(type: string, ...args: Object[]): void {
  }

  async setAVMetadata(metadata: AVMetadata): Promise<void> {
  }

  async setAVPlaybackState(state: AVPlaybackState): Promise<void> {
    throw notSupported();
  }

  dispatchSessionEvent(event: string, args: Record<string, Object>): void {
  }

  async getAVCastController(): Promise<AVCastController> {
    throw notSupported();
  }

  async sendCommonCommand(command: string, args: Record<string, Object>): Promise<void> {
    throw notSupported();
  }
}

export class AVSessionController {
  sessionId: string = '';

  async destroy(): Promise<void> {
  }

  off(type: string, ...args: Object[]): void {
  }

  on(type: string, ...args: Object[]): void {
  }

  async sendCommonCommand(command: string, args: Record<string, Object>): Promise<void> {
    throw notSupported();
  }
}

export async function createAVSession(context: common.UIAbilityContext, tag: string,
  type: string): Promise<AVSession> {
  throw notSupported();
}

export async function createController(sessionId: string): Promise<AVSessionController> {
  throw notSupported();
}

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';

/**
 * ArkUI-X 的 AVSession 兼容层。
 *
 * 保留播放器使用的 AVSession API 形状，用本地会话事件总线维持：
 * - 主控/接收端会话；
 * - 播放状态同步；
 * - play / pause / seek / next / previous 控制命令；
 * - 投送控制器占位。
 *
 * Android / iOS 的系统媒体会话由后续 PlatformBridge 接入；
 * 页面层不再直接导入 HarmonyOS 的 @kit.AVSessionKit。
 */
export namespace avSession {
  export enum PlaybackState {
    PLAYBACK_STATE_INITIAL = 0,
    PLAYBACK_STATE_PLAY = 1,
    PLAYBACK_STATE_PAUSE = 2,
    PLAYBACK_STATE_STOP = 3,
    PLAYBACK_STATE_COMPLETED = 4,
    PLAYBACK_STATE_RELEASED = 5,
    PLAYBACK_STATE_ERROR = 6
  }

  export enum ConnectionState {
    STATE_CONNECTING = 0,
    STATE_CONNECTED = 1,
    STATE_DISCONNECTED = 2
  }

  export interface AVMetadata {
    assetId?: string;
    title?: string;
    artist?: string;
    album?: string;
    duration?: number;
    mediaImage?: image.PixelMap;
  }

  export interface AVPlaybackPosition {
    elapsedTime: number;
    updateTime: number;
  }

  export interface AVPlaybackState {
    state: PlaybackState;
    position?: AVPlaybackPosition;
    speed?: number;
  }

  export interface DeviceInfo {
    deviceId: string;
    deviceName: string;
    deviceType?: number;
  }

  export interface OutputDeviceInfo {
    devices: DeviceInfo[];
  }

  export interface AVSessionArgs {
    payload: string;
  }

  export interface AVControlCommand {
    command: string;
    parameter?: number;
  }

  type VoidListener = () => void;
  type SeekListener = (time: number) => void;
  type CommonCommandListener = (command: string, args: AVSessionArgs) => void;
  type OutputListener = (state: ConnectionState, info: OutputDeviceInfo) => void;
  type PlaybackListener = (state: AVPlaybackState) => void;

  interface ListenerBucket {
    event: string;
    callback: Object;
  }

  const SESSIONS: Map<string, AVSession> = new Map<string, AVSession>();
  let sessionSeed: number = 1;

  function bucketOf(buckets: ListenerBucket[], event: string): ListenerBucket | undefined {
    for (const item of buckets) {
      if (item.event === event) { return item; }
    }
    return undefined;
  }

  function emitPlayback(buckets: ListenerBucket[], state: AVPlaybackState): void {
    for (const item of buckets) {
      if (item.event !== 'playbackStateChange') { continue; }
      try { (item.callback as PlaybackListener)(state); } catch (_) { }
    }
  }

  export class AVSession {
    sessionId: string = 'local-session-' + String(sessionSeed++);
    private buckets: ListenerBucket[] = [];
    private metadata: AVMetadata = {};
    private state: AVPlaybackState = { state: PlaybackState.PLAYBACK_STATE_INITIAL };

    async setAVMetadata(metadata: AVMetadata): Promise<void> {
      this.metadata = metadata;
    }

    async setAVPlaybackState(state: AVPlaybackState): Promise<void> {
      this.state = state;
      emitPlayback(this.buckets, state);
    }

    on(event: string, callback: Object | string, filter?: Object | string): void {
      const cb: Object = (typeof callback === 'string' ? filter : callback) as Object;
      this.buckets.push({ event: event, callback: cb });
    }

    off(event: string, callback?: Object | string, filter?: Object | string): void {
      const cb: Object | undefined = (typeof callback === 'string' ? filter : callback) as Object | undefined;
      for (let index = this.buckets.length - 1; index >= 0; index--) {
        const item: ListenerBucket = this.buckets[index];
        if (item.event !== event) { continue; }
        if (cb !== undefined && item.callback !== cb) { continue; }
        this.buckets.splice(index, 1);
      }
    }

    async activate(): Promise<void> {
      SESSIONS.set(this.sessionId, this);
    }

    async destroy(): Promise<void> {
      SESSIONS.delete(this.sessionId);
      this.buckets = [];
    }

    async getAVCastController(): Promise<AVCastController> {
      return new AVCastController(this.sessionId);
    }

    async getOutputDevice(): Promise<OutputDeviceInfo> {
      return { devices: [] };
    }

    getPlaybackState(): AVPlaybackState {
      return this.state;
    }

    getMetadata(): AVMetadata {
      return this.metadata;
    }

    async dispatchSessionEvent(event: string, args: AVSessionArgs): Promise<void> {
      // 本地兼容层：同播事件由 MediaSessionDialog 的 controller 广播处理。
    }

    emitCommon(command: string, args: AVSessionArgs): void {
      const bucket: ListenerBucket | undefined = bucketOf(this.buckets, 'commonCommand');
      if (bucket !== undefined) {
        try { (bucket.callback as CommonCommandListener)(command, args); } catch (_) { }
      }
    }

    emitCommand(command: string): void {
      const bucket: ListenerBucket | undefined = bucketOf(this.buckets, command);
      if (bucket !== undefined) {
        try { (bucket.callback as VoidListener)(); } catch (_) { }
      }
    }
  }

  export class AVSessionController {
    sessionId: string = '';
    private buckets: ListenerBucket[] = [];

    async destroy(): Promise<void> {
      this.buckets = [];
    }

    on(event: string, callback: Object | string, filter?: Object | string): void {
      const cb: Object = (typeof callback === 'string' ? filter : callback) as Object;
      this.buckets.push({ event: event, callback: cb });
    }

    off(event: string, callback?: Object | string, filter?: Object | string): void {
      const cb: Object | undefined = (typeof callback === 'string' ? filter : callback) as Object | undefined;
      for (let index = this.buckets.length - 1; index >= 0; index--) {
        const item: ListenerBucket = this.buckets[index];
        if (item.event !== event) { continue; }
        if (cb !== undefined && item.callback !== cb) { continue; }
        this.buckets.splice(index, 1);
      }
    }

    async sendCommonCommand(command: string, args: AVSessionArgs): Promise<void> {
      const target: AVSession | undefined = SESSIONS.get(this.sessionId);
      if (target !== undefined) { target.emitCommon(command, args); }
    }

    async sendControlCommand(command: AVControlCommand): Promise<void> {
      const target: AVSession | undefined = SESSIONS.get(this.sessionId);
      if (target !== undefined) { target.emitCommand(command.command); }
    }

    async getAVPlaybackState(): Promise<AVPlaybackState> {
      const target: AVSession | undefined = SESSIONS.get(this.sessionId);
      return target !== undefined ? target.getPlaybackState() : { state: PlaybackState.PLAYBACK_STATE_INITIAL };
    }
  }

  export class AVCastController {
    sessionId: string = '';
    private buckets: ListenerBucket[] = [];

    constructor(sessionId: string) {
      this.sessionId = sessionId;
    }

    on(event: string, callback: Object | string, filter?: Object | string): void {
      const cb: Object = (typeof callback === 'string' ? filter : callback) as Object;
      this.buckets.push({ event: event, callback: cb });
    }

    off(event: string, callback?: Object | string, filter?: Object | string): void {
      for (let index = this.buckets.length - 1; index >= 0; index--) {
        if (this.buckets[index].event === event) { this.buckets.splice(index, 1); }
      }
    }

    async getAVPlaybackState(): Promise<AVPlaybackState> {
      return { state: PlaybackState.PLAYBACK_STATE_INITIAL };
    }

    async sendControlCommand(command: AVControlCommand): Promise<void> {
      // 系统投送由原生桥接实现；跨平台层保持无操作。
    }

    async destroy(): Promise<void> {
      this.buckets = [];
    }
  }

  export async function createAVSession(context: common.UIAbilityContext, name: string,
    type: string): Promise<AVSession> {
    const session: AVSession = new AVSession();
    SESSIONS.set(session.sessionId, session);
    return session;
  }

  export async function createController(sessionId: string): Promise<AVSessionController> {
    const controller: AVSessionController = new AVSessionController();
    controller.sessionId = sessionId;
    return controller;
  }
}

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

/** 原协播邀请字段保持不变；sceneMode 仅是 Quest3 扩展字段。 */
export interface Quest3CoPlayPayload {
  version: number;
  vodId: string;
  sessionId: string;
  currentMs: number;
  timestamp: number;
  episodeIndex: number;
  videoJson: string;
  syncMode?: string;
  serverUrl?: string;
  sceneMode?: Quest3SceneMode;
}
export type Quest3SceneMode = 'plane' | 'arc180' | 'sphere360';
export type Quest3CommandName = 'play' | 'pause' | 'seek' | 'speed' | 'switchEpisode';
export interface Quest3ControlCommand {
  type: 'command';
  command: Quest3CommandName;
  sessionId: string;
  timestamp: number;
  currentMs?: number;
  speed?: number;
  episodeIndex?: number;
  sceneMode?: Quest3SceneMode;
}
export interface Quest3StatePacket {
  type: 'state';
  sessionId: string;
  playState: 'playing' | 'paused' | 'buffering' | 'ended' | 'error';
  currentMs: number;
  timestamp?: number;
}
export interface Quest3DeviceDescriptor {
  deviceId: string;
  deviceName: string;
  deviceType: 'harmony' | 'vr_quest3';
  address: string;
  port: number;
  online: boolean;
}
export interface Quest3ConnectionCallbacks {
  onState: (packet: Quest3StatePacket) => void;
  onConnectionChanged: (online: boolean, message: string) => void;
}

/**
* Quest3 WebSocket client. Quest3 端需提供 ws://<Quest-IP>:43827/ws 服务端，
* 并实现相同 JSON 协议；鸿蒙侧不接收或处理 OpenXR/手柄追踪数据。
*/
export class Quest3ControlService {
  private socket?: webSocket.WebSocket;
  private endpoint: string = '';
  private sessionId: string = '';
  private callbacks?: Quest3ConnectionCallbacks;
  private generation: number = 0;
  private retryTimer: number = -1;
  private debounceTimer: number = -1;
  private retryCount: number = 0;
  private manuallyClosed: boolean = true;
  private online: boolean = false;
  private lastSendAt: number = 0;
  private lastCommandKey: string = '';
  private connecting: boolean = false;
  private pendingPayload?: Quest3CoPlayPayload;
  private sceneMode: Quest3SceneMode = 'plane';

  isOnline(): boolean { return this.online && this.socket !== undefined; }

  async connect(device: Quest3DeviceDescriptor, sessionId: string,
    callbacks: Quest3ConnectionCallbacks): Promise<void> {
    try {
      if (device.deviceType !== 'vr_quest3' || !device.address || device.port < 1 || device.port > 65535) {
        throw new Error('Quest3 设备地址或类型无效');
      }
      this.close(false);
      this.endpoint = 'ws://' + device.address + ':' + String(device.port) + '/ws';
      this.sessionId = sessionId;
      this.callbacks = callbacks;
      this.manuallyClosed = false;
      this.retryCount = 0;
      await this.openSocket();
    } catch (error) {
      this.failure('Connect', error);
      throw new Error('Quest3 WebSocket 连接失败');
    }
  }

  private async openSocket(): Promise<void> {
    if (this.manuallyClosed || this.connecting || !this.endpoint) { return; }
    this.connecting = true;
    const generation: number = ++this.generation;
    let connectingSocket: webSocket.WebSocket | undefined;
    try {
      const socket: webSocket.WebSocket = webSocket.createWebSocket();
      connectingSocket = socket;
      this.socket = socket;
      socket.on('open', (problem: BusinessError, _headers: Object): void => {
        try {
          if (generation !== this.generation || this.socket !== socket) { return; }
          if (problem && problem.code) { this.failure('OpenCallback', problem); this.scheduleRetry(); return; }
          this.online = true;
          this.retryCount = 0;
          this.callbacks?.onConnectionChanged(true, 'Quest3 已连接');
          Logger.info('QUEST3_WS', 'WebSocket 已连接：' + this.endpoint);
          const payload: Quest3CoPlayPayload | undefined = this.pendingPayload;
          if (payload) { void this.sendPayload(payload); }
        } catch (error) { this.failure('OpenCallbackHandler', error); }
      });
      socket.on('message', (problem: BusinessError, data: string | ArrayBuffer): void => {
        try {
          if (generation !== this.generation || this.socket !== socket) { return; }
          if (problem && problem.code) { this.failure('MessageCallback', problem); return; }
          if (typeof data !== 'string' || data.length > 65536) { throw new Error('Quest3 状态包必须是 64KB 内 JSON 文本'); }
          const packet: Quest3StatePacket = JSON.parse(data) as Quest3StatePacket;
          if (packet.type !== 'state' || packet.sessionId !== this.sessionId ||
            typeof packet.playState !== 'string' || !Number.isFinite(packet.currentMs) || packet.currentMs < 0) {
            throw new Error('Quest3 状态包字段无效或 sessionId 不匹配');
          }
          this.callbacks?.onState(packet);
        } catch (error) { this.failure('ParseState', error); }
      });
      socket.on('close', (_problem: BusinessError, _info: Object): void => {
        try { if (generation === this.generation && this.socket === socket) { this.handleSocketLost('Quest3 连接已断开'); } }
        catch (error) { this.failure('CloseCallback', error); }
      });
      socket.on('error', (problem: BusinessError): void => {
        try {
          if (generation === this.generation && this.socket === socket) {
            this.failure('SocketCallback', problem);
            this.handleSocketLost('Quest3 网络异常');
          }
        } catch (error) { this.failure('ErrorCallback', error); }
      });
      const connected: boolean = await socket.connect(this.endpoint);
      if (!connected && generation === this.generation) { this.handleSocketLost('Quest3 连接未建立'); }
    } catch (error) {
      this.failure('OpenSocket', error);
      if (generation === this.generation && connectingSocket && this.socket === connectingSocket) {
        this.handleSocketLost('Quest3 连接失败');
      }
    } finally { this.connecting = false; }
  }

  async sendPayload(payload: Quest3CoPlayPayload): Promise<void> {
    try {
      this.pendingPayload = payload;
      if (!this.isOnline() || !this.socket) { this.callbacks?.onConnectionChanged(false, 'Quest3 离线，载荷已排队，正在重连'); return; }
      const raw: string = JSON.stringify(payload);
      await this.socket.send(raw);
      Logger.info('QUEST3_WS', '协播 payload 已发送，vodId=' + payload.vodId + '，sessionId=' + payload.sessionId +
      '，currentMs=' + String(payload.currentMs) + '，episodeIndex=' + String(payload.episodeIndex) +
      '，sceneMode=' + String(payload.sceneMode || this.sceneMode));
    } catch (error) { this.failure('SendPayload', error); throw new Error('发送 Quest3 协播载荷失败'); }
  }

  async sendCommand(command: Quest3CommandName, currentMs: number = 0,
    speed: number = 1, episodeIndex: number = 0): Promise<void> {
    try {
      if (!this.isOnline() || !this.socket) { this.callbacks?.onConnectionChanged(false, 'Quest3 离线，请检查连接'); throw new Error('Quest3 设备离线'); }
      const key: string = command + ':' + String(currentMs) + ':' + String(speed) + ':' + String(episodeIndex);
      const now: number = Date.now();
      if (key === this.lastCommandKey && now - this.lastSendAt < 350) { return; }
      this.lastCommandKey = key;
      this.lastSendAt = now;
      const packet: Quest3ControlCommand = {
        type: 'command', command: command, sessionId: this.sessionId, timestamp: now,
          currentMs: currentMs, speed: speed, episodeIndex: episodeIndex
      };
      await this.socket.send(JSON.stringify(packet));
      Logger.info('QUEST3_WS', '控制指令已发送：' + command + '，currentMs=' + String(currentMs));
    } catch (error) { this.failure('SendCommand', error); throw new Error('Quest3 控制指令发送失败'); }
  }

  async setSceneMode(mode: Quest3SceneMode): Promise<void> {
    try {
      this.sceneMode = mode;
      if (!this.pendingPayload) { throw new Error('尚无协播 payload，无法切换幕布模式'); }
      const payload: Quest3CoPlayPayload = {
        version: this.pendingPayload.version, vodId: this.pendingPayload.vodId,
          sessionId: this.pendingPayload.sessionId, currentMs: this.pendingPayload.currentMs,
          timestamp: this.pendingPayload.timestamp, episodeIndex: this.pendingPayload.episodeIndex,
          videoJson: this.pendingPayload.videoJson, syncMode: this.pendingPayload.syncMode,
          serverUrl: this.pendingPayload.serverUrl, sceneMode: mode
      };
      this.pendingPayload = payload;
      if (this.isOnline() && this.socket) { await this.socket.send(JSON.stringify(payload)); }
    } catch (error) { this.failure('SetSceneMode', error); throw new Error('切换 Quest3 幕布模式失败'); }
  }

  private handleSocketLost(message: string): void {
    this.online = false;
    this.callbacks?.onConnectionChanged(false, message);
    try { this.socket?.close({ code: 1001, reason: message }); } catch (error) { this.failure('CloseLostSocket', error); }
    this.socket = undefined;
    this.scheduleRetry();
  }
  private scheduleRetry(): void {
    if (this.manuallyClosed || this.retryTimer !== -1) { return; }
    this.online = false;
    this.retryCount++;
    const delay: number = Math.min(15000, 800 * Math.pow(2, Math.min(this.retryCount, 4)));
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (!this.manuallyClosed) { void this.openSocket(); }
    }, delay);
    this.callbacks?.onConnectionChanged(false, 'Quest3 断开，' + String(delay) + 'ms 后重试');
  }
  private failure(stage: string, error: Object): void {
    const problem: BusinessError = error as BusinessError;
    Logger.error('QUEST3_WS', stage + '，code=' + String(problem.code) + '，message=' + String(problem.message) + '，detail=' + String(error));
  }

  close(notify: boolean = true): void {
    try {
      this.manuallyClosed = true;
      ++this.generation;
      if (this.retryTimer !== -1) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
      if (this.debounceTimer !== -1) { clearTimeout(this.debounceTimer); this.debounceTimer = -1; }
      const socket: webSocket.WebSocket | undefined = this.socket;
      this.socket = undefined;
      this.online = false;
      this.connecting = false;
      if (socket) {
        try { socket.off('open'); socket.off('message'); socket.off('close'); socket.off('error'); }
        catch (error) { this.failure('RemoveCallbacks', error); }
        try { void socket.close({ code: 1000, reason: 'PlayerPage disposed' }); }
        catch (error) { this.failure('CloseSocket', error); }
      }
      if (notify) { this.callbacks?.onConnectionChanged(false, 'Quest3 已断开连接'); }
      this.callbacks = undefined;
      this.pendingPayload = undefined;
      this.endpoint = '';
      this.sessionId = '';
      this.lastCommandKey = '';
      Logger.info('QUEST3_WS', 'Quest3 WebSocket 资源已释放');
    } catch (error) { this.failure('Release', error); }
  }
}

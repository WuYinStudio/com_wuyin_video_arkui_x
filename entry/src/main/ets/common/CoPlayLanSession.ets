import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

interface SessionProbe {
  protocol: string;
  kind: string;
  sessionId: string;
  requestId: string;
}
interface SessionHeader {
  action: string;
  sessionId: string;
  deviceId: string;
}
interface SessionPeer {
  outgoing?: socket.TCPSocket;
  incoming?: socket.TCPSocketConnection;
  data: Uint8Array;
  deviceId: string;
  closed: boolean;
  timer: number;
  writes: number;
  tail: Promise<void>;
  reads: Promise<void>;
}

// 邀请仍由 CoPlayLanService 的长载荷通道交付；本类只传递后续成员和播放状态。
// UDP 仅定位当前会话的 TCP 端点，不传 videoJson，也不调用 DeviceManager 扫描。
// 不把远端 sessionId 当成本机 AVSessionController；系统 AVSession/AVCast 通道保持独立。
export class CoPlayLanSession {
  static readonly shared: CoPlayLanSession = new CoPlayLanSession();
  private static readonly PORT: number = 43827;
  private static readonly MAX_FRAME: number = 65536;
  private generation: number = 0;
  private sessionId: string = '';
  private udp?: socket.UDPSocket;
  private server?: socket.TCPSocketServer;
  private client?: SessionPeer;
  private peers: SessionPeer[] = [];
  private packet?: (raw: string) => Promise<void>;
  private ended?: () => void;

  private failure(stage: string, error: Object): void {
    const problem: BusinessError = error as BusinessError;
    Logger.error('CO_PLAYBACK', '【CoPlay][LAN-Session][' + stage + '] code=' + String(problem.code) +
    '，message=' + String(problem.message) + '，堆栈=' + String(problem.stack));
  }
  isHost(sessionId: string): boolean {
    return Boolean(this.server && this.sessionId === sessionId);
  }
  async startHost(sessionId: string, packet: (raw: string) => Promise<void>, ended: () => void): Promise<void> {
    if (this.isHost(sessionId)) { return; }
    await this.close();
    const generation: number = this.generation;
    let udp: socket.UDPSocket | undefined;
    let server: socket.TCPSocketServer | undefined;
    try {
      if (!sessionId || sessionId === 'null' || sessionId === 'undefined') { throw new Error('局域网会话 ID 无效'); }
      udp = socket.constructUDPSocketInstance();
      server = socket.constructTCPSocketServerInstance();
      const probeSocket: socket.UDPSocket = udp;
      const listener: socket.TCPSocketServer = server;
      udp.on('message', (message: socket.SocketMessageInfo): void => {
        if (generation === this.generation && this.udp === probeSocket) {
          void this.answerProbe(probeSocket, message);
        }
      });
      udp.on('error', (error: BusinessError): void => { this.failure('HostProbe', error); });
      server.on('connect', (connection: socket.TCPSocketConnection): void => {
        try {
          if (generation !== this.generation || this.server !== listener || this.peers.length >= 31) {
            void connection.close().catch((error: Error): void => { this.failure('RejectConnection', error); });
            return;
          }
          const peer: SessionPeer = this.makePeer();
          peer.incoming = connection;
          this.peers.push(peer);
          this.bindIncoming(peer, connection, generation);
          peer.timer = setTimeout((): void => {
            if (!peer.deviceId) { this.dropPeer(peer); }
          }, 12000);
        } catch (error) {
          this.failure('Accept', error);
          void connection.close().catch((caught: Error): void => { this.failure('CloseRejected', caught); });
        }
      });
      server.on('error', (error: BusinessError): void => {
        this.failure('HostSocket', error);
        if (generation === this.generation && this.server === listener) { this.connectionEnded(); }
      });
      await udp.setExtraOptions({ reuseAddress: true, broadcast: true });
      await udp.bind({ address: '0.0.0.0', port: CoPlayLanSession.PORT, family: 1 });
      await server.listen({ address: '0.0.0.0', port: CoPlayLanSession.PORT, family: 1 });
      if (generation !== this.generation) { throw new Error('局域网会话创建已取消'); }
      this.sessionId = sessionId;
      this.packet = packet; this.ended = ended;
      this.udp = udp; this.server = server;
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Session] 主控持续同步端点已启动，sessionId=' + sessionId);
    } catch (error) {
      if (udp) { try { udp.off('message'); udp.off('error'); await udp.close(); } catch (caught) { this.failure('CloseHostProbe', caught); } }
      if (server) { try { await server.close(); } catch (caught) { this.failure('CloseHostServer', caught); } }
      this.failure('StartHost', error);
      throw new Error('局域网持续同步通道初始化失败');
    }
  }
  private async answerProbe(udp: socket.UDPSocket, message: socket.SocketMessageInfo): Promise<void> {
    try {
      if (message.message.byteLength > 1024) { return; }
      const raw: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message));
      const probe: SessionProbe = JSON.parse(raw) as SessionProbe;
      if (!probe || probe.protocol !== 'wuyin-coplay-session-v1' || probe.kind !== 'find' ||
        probe.sessionId !== this.sessionId || typeof probe.requestId !== 'string' || probe.requestId.length > 80) { return; }
      const reply: SessionProbe = {
        protocol: probe.protocol, kind: 'host', sessionId: this.sessionId, requestId: probe.requestId
      };
      await udp.send({ address: { address: message.remoteInfo.address, port: message.remoteInfo.port, family: 1 }, data: JSON.stringify(reply) });
    } catch (error) { this.failure('AnswerProbe', error); }
  }
  private async locate(sessionId: string, generation: number): Promise<string> {
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    let timeout: number = -1;
    let retry: number = -1;
    try {
      const requestId: string = util.generateRandomUUID(true);
      const query: SessionProbe = {
        protocol: 'wuyin-coplay-session-v1', kind: 'find', sessionId: sessionId, requestId: requestId
      };
      await udp.setExtraOptions({ broadcast: true });
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      const result: Promise<string> = new Promise((resolve): void => {
        timeout = setTimeout((): void => { resolve(''); }, 1800);
        udp.on('message', (message: socket.SocketMessageInfo): void => {
          try {
            if (generation !== this.generation || message.message.byteLength > 1024) { return; }
            const raw: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message));
            const reply: SessionProbe = JSON.parse(raw) as SessionProbe;
            if (reply && reply.protocol === query.protocol && reply.kind === 'host' &&
              reply.sessionId === sessionId && reply.requestId === requestId) { resolve(message.remoteInfo.address); }
          } catch (error) { this.failure('LocateReply', error); }
        });
        udp.on('error', (error: BusinessError): void => { this.failure('LocateSocket', error); resolve(''); });
      });
      const sendProbe = (): void => {
        if (generation !== this.generation) { return; }
        void udp.send({ address: { address: '255.255.255.255', port: CoPlayLanSession.PORT, family: 1 }, data: JSON.stringify(query) })
          .catch((error: Error): void => { this.failure('LocateSend', error); });
      };
      sendProbe(); retry = setInterval(sendProbe, 500);
      return await result;
    } catch (error) {
      this.failure('Locate', error); return '';
    } finally {
      if (timeout !== -1) { clearTimeout(timeout); }
      if (retry !== -1) { clearInterval(retry); }
      try { udp.off('message'); udp.off('error'); await udp.close(); } catch (error) { this.failure('CloseLocate', error); }
    }
  }
  // 未发现应用级会话时返回 false，由调用方继续原有系统 AVSession 入会链路。
  async tryJoin(sessionId: string, packet: (raw: string) => Promise<void>, ended: () => void): Promise<boolean> {
    await this.close();
    const generation: number = this.generation;
    const address: string = await this.locate(sessionId, generation);
    if (generation !== this.generation) { throw new Error('局域网入会已取消'); }
    if (!address) { return false; }
    const outgoing: socket.TCPSocket = socket.constructTCPSocketInstance();
    const peer: SessionPeer = this.makePeer();
    peer.outgoing = outgoing;
    this.sessionId = sessionId; this.packet = packet; this.ended = ended; this.client = peer;
    try {
      outgoing.on('message', (message: socket.SocketMessageInfo): void => { this.read(peer, message, generation, false); });
      outgoing.on('error', (error: BusinessError): void => {
        this.failure('ClientSocket', error);
        if (generation === this.generation && this.client === peer) { this.connectionEnded(); }
      });
      outgoing.on('close', (): void => {
        if (generation === this.generation && this.client === peer) { this.connectionEnded(); }
      });
      await outgoing.connect({ address: { address: address, port: CoPlayLanSession.PORT, family: 1 }, timeout: 5000 });
      if (generation !== this.generation || this.client !== peer) { throw new Error('局域网连接已取消'); }
      Logger.info('CO_PLAYBACK', '【CoPlay][LAN-Session] TCP 已连接，等待主控成员确认，sessionId=' + sessionId);
      return true;
    } catch (error) {
      this.failure('Join', error);
      if (generation === this.generation) { await this.close(); }
      throw new Error('连接局域网主控失败');
    }
  }
  private makePeer(): SessionPeer {
    return { data: new Uint8Array(0), deviceId: '', closed: false, timer: -1, writes: 0,
        tail: Promise.resolve(), reads: Promise.resolve() };
  }
  private bindIncoming(peer: SessionPeer, connection: socket.TCPSocketConnection, generation: number): void {
    connection.on('message', (message: socket.SocketMessageInfo): void => { this.read(peer, message, generation, true); });
    connection.on('error', (error: BusinessError): void => { this.failure('PeerSocket', error); this.dropPeer(peer); });
    connection.on('close', (): void => { this.dropPeer(peer); });
  }
  private read(peer: SessionPeer, message: socket.SocketMessageInfo, generation: number, host: boolean): void {
    try {
      if (generation !== this.generation || peer.closed) { return; }
      const part: Uint8Array = new Uint8Array(message.message);
      if (peer.data.length + part.length > 4 * (CoPlayLanSession.MAX_FRAME + 4)) { throw new Error('会话消息缓冲超过上限'); }
      const merged: Uint8Array = new Uint8Array(peer.data.length + part.length);
      merged.set(peer.data); merged.set(part, peer.data.length); peer.data = merged;
      while (peer.data.length >= 4) {
        const size: number = new DataView(peer.data.buffer).getUint32(0, false);
        if (size === 0 || size > CoPlayLanSession.MAX_FRAME) { throw new Error('会话消息帧长度无效'); }
        if (peer.data.length < size + 4) { return; }
        const raw: string = util.TextDecoder.create('utf-8').decodeToString(peer.data.subarray(4, size + 4));
        peer.data = peer.data.slice(size + 4);
        const header: SessionHeader = JSON.parse(raw) as SessionHeader;
        if (!header || header.sessionId !== this.sessionId || typeof header.action !== 'string' ||
          typeof header.deviceId !== 'string' || !/^[A-Za-z0-9-]{12,96}$/.test(header.deviceId)) { throw new Error('会话消息身份无效'); }
        if (host) {
          if (!['join', 'pulse', 'leave', 'transfer', 'kick', 'control'].includes(header.action)) { throw new Error('从机消息动作无效'); }
          if (!peer.deviceId) {
            if (header.action !== 'join') { throw new Error('首条会话消息必须入会'); }
            if (this.peers.some((item: SessionPeer): boolean => item !== peer && !item.closed && item.deviceId === header.deviceId)) {
              throw new Error('设备已有会话连接');
            }
            peer.deviceId = header.deviceId;
            if (peer.timer !== -1) { clearTimeout(peer.timer); peer.timer = -1; }
          } else if (peer.deviceId !== header.deviceId) { throw new Error('不允许冒用其他成员身份'); }
        } else if (!['members', 'destroy', 'disconnect'].includes(header.action)) { throw new Error('主控消息动作无效'); }
        const deliver: Promise<void> = peer.reads.then(async (): Promise<void> => {
          if (generation === this.generation && !peer.closed && this.packet) { await this.packet(raw); }
        });
        peer.reads = deliver.catch((error: Error): void => {
          this.failure('DeliverState', error);
          if (host) { this.dropPeer(peer); } else if (generation === this.generation) { this.connectionEnded(); }
        });
      }
    } catch (error) {
      this.failure('ReadFrame', error);
      if (host) { this.dropPeer(peer); } else if (generation === this.generation) { this.connectionEnded(); }
    }
  }
  private write(peer: SessionPeer, raw: string): Promise<void> {
    if (peer.closed || peer.writes >= 16) { return Promise.reject(new Error('会话连接关闭或发送队列已满')); }
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(raw);
    if (!bytes.length || bytes.length > CoPlayLanSession.MAX_FRAME) { return Promise.reject(new Error('会话状态消息超过上限')); }
    const frame: Uint8Array = new Uint8Array(bytes.length + 4);
    new DataView(frame.buffer).setUint32(0, bytes.length, false); frame.set(bytes, 4);
    peer.writes++;
    const task: Promise<void> = peer.tail.then(async (): Promise<void> => {
      if (peer.closed) { throw new Error('会话连接已关闭'); }
      if (peer.outgoing) { await peer.outgoing.send({ data: frame.buffer }); }
      else if (peer.incoming) { await peer.incoming.send({ data: frame.buffer }); }
      else { throw new Error('会话连接不存在'); }
    });
    peer.tail = task.then((): void => { peer.writes--; }, (error: Error): void => {
      peer.writes--; this.failure('WriteFrame', error);
    });
    return task;
  }
  async send(raw: string): Promise<void> {
    if (!this.client) { throw new Error('局域网从机连接尚未就绪'); }
    await this.write(this.client, raw);
  }
  async broadcast(sessionId: string, raw: string): Promise<void> {
    if (!this.isHost(sessionId)) { return; }
    await Promise.all(this.peers.filter((peer: SessionPeer): boolean => !peer.closed && Boolean(peer.deviceId))
      .map(async (peer: SessionPeer): Promise<void> => {
      try { await this.write(peer, raw); }
      catch (error) { this.failure('Broadcast', error); this.dropPeer(peer); }
    }));
  }
  private dropPeer(peer: SessionPeer): void {
    if (peer.closed) { return; }
    peer.closed = true;
    this.peers = this.peers.filter((item: SessionPeer): boolean => item !== peer);
    if (peer.timer !== -1) { clearTimeout(peer.timer); peer.timer = -1; }
    peer.data = new Uint8Array(0);
    try {
      if (peer.incoming) {
            void peer.incoming.close().catch((error: Error): void => { this.failure('ClosePeer', error); });
      }
      if (peer.outgoing) {
            void peer.outgoing.close().catch((error: Error): void => { this.failure('CloseClient', error); });
      }
    } catch (error) { this.failure('DetachPeer', error); }
  }
  private connectionEnded(): void {
    const ended: (() => void) | undefined = this.ended;
    this.ended = undefined;
    void this.close();
    try { if (ended) { ended(); } } catch (error) { this.failure('EndCallback', error); }
  }
  async close(): Promise<void> {
    ++this.generation;
    const udp: socket.UDPSocket | undefined = this.udp;
    const server: socket.TCPSocketServer | undefined = this.server;
    const peers: SessionPeer[] = this.peers.slice();
    if (this.client) { peers.push(this.client); }
    this.udp = undefined; this.server = undefined; this.client = undefined; this.peers = [];
    this.sessionId = ''; this.packet = undefined; this.ended = undefined;
    // 给已排队的 leave/control 一个有界发送窗口；失联设备不能阻塞页面销毁。
    let timer: number = -1;
    try {
      await Promise.race([Promise.all(peers.map((peer: SessionPeer): Promise<void> => peer.tail)),
        new Promise<void>((resolve): void => { timer = setTimeout(resolve, 250); })]);
    } finally {
      if (timer !== -1) { clearTimeout(timer); }
      peers.forEach((peer: SessionPeer): void => { this.dropPeer(peer); });
      if (udp) { try { udp.off('message'); udp.off('error'); await udp.close(); } catch (error) { this.failure('CloseProbe', error); } }
      if (server) { try { await server.close(); } catch (error) { this.failure('CloseServer', error); } }
    }
  }
}

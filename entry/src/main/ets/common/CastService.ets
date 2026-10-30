import { http, socket } from '@kit.NetworkKit';

export interface CastDevice {
  id: string;
  name: string;
  location: string;
  controlUrl: string;
}

// DLNA/UPnP AVTransport：仅在局域网发现设备，不依赖外部投屏服务。
export class CastService {
  private udp?: socket.UDPSocket;
  private searchTimer: number = -1;
  private searchId: number = 0;
  private devices: CastDevice[] = [];
  private inspecting: string[] = [];
  private closed: boolean = false;
  private onDevices?: (devices: CastDevice[]) => void;
  private onSearchEnd?: () => void;

  async search(onDevices: (devices: CastDevice[]) => void, onSearchEnd: () => void): Promise<void> {
    this.stopSearch();
    this.closed = false;
    this.devices = [];
    this.inspecting = [];
    this.onDevices = onDevices;
    this.onSearchEnd = onSearchEnd;
    const id = ++this.searchId;
    // 从搜索开始计时，绑定或发送卡住时也能按时结束扫描。
    this.searchTimer = setTimeout(() => {
      if (id === this.searchId) { this.stopSearch(); onSearchEnd(); }
    }, 8000);
    try {
      const udp = socket.constructUDPSocketInstance();
      this.udp = udp;
      udp.on('message', (message: socket.SocketMessageInfo) => {
        if (id !== this.searchId || this.closed) { return; }
        const bytes = new Uint8Array(message.message);
        let response = '';
        for (let i = 0; i < bytes.length; i++) { response += String.fromCharCode(bytes[i]); }
        const location = /(?:^|\r?\n)location:\s*([^\r\n]+)/i.exec(response)?.[1]?.trim() || '';
        if (/^https?:\/\//i.test(location)) { this.inspectDevice(location, id); }
      });
      await udp.bind({ address: '0.0.0.0', port: 0 });
      if (id !== this.searchId) { await udp.close(); return; }
      const targets = ['urn:schemas-upnp-org:device:MediaRenderer:1', 'urn:schemas-upnp-org:service:AVTransport:1'];
      for (const target of targets) {
        if (id !== this.searchId) { return; }
        await udp.send({ data: 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ' + target + '\r\n\r\n',
            address: { address: '239.255.255.250', port: 1900 } });
      }
    } catch (_) {
      if (id === this.searchId) { this.stopSearch(); onSearchEnd(); }
    }
  }

  private async inspectDevice(location: string, id: number): Promise<void> {
    if (this.inspecting.includes(location) || this.devices.some((device: CastDevice) => device.location === location)) { return; }
    this.inspecting.push(location);
    try {
      const request = http.createHttp();
      let xml = '';
      try {
        const response = await request.request(location, { method: http.RequestMethod.GET,
            connectTimeout: 2500, readTimeout: 2500 });
        if (response.responseCode !== 200) { return; }
        xml = String(response.result);
      } finally { request.destroy(); }
      if (id !== this.searchId || this.closed || !/MediaRenderer/i.test(xml)) { return; }
      const service = /<service>\s*([\s\S]*?<serviceType>\s*urn:schemas-upnp-org:service:AVTransport:1\s*<\/serviceType>[\s\S]*?)<\/service>/i.exec(xml)?.[1] || '';
      const control = /<controlURL>\s*([^<]+)\s*<\/controlURL>/i.exec(service)?.[1]?.trim() || '';
      if (!control) { return; }
      const name = /<friendlyName>\s*([^<]+)\s*<\/friendlyName>/i.exec(xml)?.[1]?.trim() || '投屏设备';
      const base = /<URLBase>\s*([^<]+)\s*<\/URLBase>/i.exec(xml)?.[1]?.trim() || location;
      const origin = /^https?:\/\/[^/]+/i.exec(base)?.[0] || '';
      const root = base.substring(0, base.lastIndexOf('/') + 1);
      const controlUrl = /^https?:\/\//i.test(control) ? control : control.startsWith('/') ? origin + control : root + control;
      if (this.devices.some((device: CastDevice) => device.controlUrl === controlUrl)) { return; }
      this.devices.push({ id: controlUrl, name: name.replace(/&amp;/g, '&').replace(/&lt;/g, '<'), location: location, controlUrl: controlUrl });
      this.onDevices?.(this.devices.slice());
    } catch (_) { /* 忽略无效的 SSDP 响应，继续发现其他设备。 */ }
    finally { this.inspecting = this.inspecting.filter((item: string) => item !== location); }
  }

  stopSearch(): void {
    ++this.searchId;
    if (this.searchTimer !== -1) { clearTimeout(this.searchTimer); this.searchTimer = -1; }
    const udp = this.udp;
    this.udp = undefined;
    if (udp) { udp.close().catch(() => {}); }
  }

  async command(device: CastDevice, action: string, body: string): Promise<string> {
    const request = http.createHttp();
    const envelope = '<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:' + action + ' xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>' + body + '</u:' + action + '></s:Body></s:Envelope>';
    try {
      const result = await request.request(device.controlUrl, { method: http.RequestMethod.POST,
          header: { 'Content-Type': 'text/xml; charset="utf-8"', 'SOAPAction': '"urn:schemas-upnp-org:service:AVTransport:1#' + action + '"' },
          extraData: envelope, connectTimeout: 4000, readTimeout: 4000 });
      if (result.responseCode !== 200 || /<\s*(?:\w+:)?Fault[\s>]/i.test(String(result.result))) { throw new Error('UPnP ' + result.responseCode); }
      return String(result.result);
    } finally { request.destroy(); }
  }

  static escape(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  close(): void { this.closed = true; this.stopSearch(); this.onDevices = undefined; this.onSearchEnd = undefined; }
}

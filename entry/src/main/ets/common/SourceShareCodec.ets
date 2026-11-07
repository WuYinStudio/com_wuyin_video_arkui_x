import util from '@ohos.util';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { Logger } from './Logger';

/**
 * 线路分享编码：紧凑 JSON → AES128-CBC 加密 → Base64 → 分片。
 * 二维码内容格式：WUYIN-SRC:序号/总数:Base64分片
 *
 * 不使用 ZIP：跨设备解压路径与压缩包结构存在差异，容易导致解密后解压失败。
 * JSON 先 minify，再加密，保证多张二维码可以稳定还原。
 */
export class SourceShareCodec {
  static readonly PREFIX: string = 'WUYIN-SRC:';
  static readonly MAX_PARTS: number = 16;
  private static readonly CHUNK_SIZE: number = 900;
  private static readonly KEY: Uint8Array = new Uint8Array([
    87, 117, 121, 105, 110, 83, 114, 99, 83, 104, 97, 114, 101, 86, 49, 33
  ]);
  private static readonly IV: Uint8Array = new Uint8Array([
    87, 117, 121, 105, 110, 83, 114, 99, 73, 118, 50, 48, 50, 54, 33, 65
  ]);

  private static async crypt(bytes: Uint8Array, encrypt: boolean): Promise<Uint8Array> {
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const key: cryptoFramework.SymKey = await (generator.convertKey(
      { data: SourceShareCodec.KEY }) as Promise<cryptoFramework.SymKey>);
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    const iv: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: SourceShareCodec.IV }
    };
    await cipher.init(encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE, key, iv);
    const result: cryptoFramework.DataBlob = await cipher.doFinal({ data: bytes });
    return result.data;
  }

  /** 把完整线路对象压成短数组，显著减少二维码分片数量。 */
  private static compact(json: string): string {
    try {
      const document = JSON.parse(json) as ShareDocument;
      const list: SearchSourceShareRow[] | undefined = document.userlist;
      if (list === undefined || !Array.isArray(list)) { return json; }
      const rows: Array<Array<string | number>> = [];
      for (const item of list) {
        const row: Array<string | number> = [
          Number(item.id) || 0,
          String(item.name || ''),
          String(item.url || ''),
          String(item.urls || ''),
          String(item.kind || ''),
          String(item.rule || '')
        ];
        if (String(item.img || '').length > 0) { row.push(String(item.img)); }
        rows.push(row);
      }
      return JSON.stringify({ v: 2, u: rows });
    } catch (error) {
      Logger.warn('SOURCE_SHARE', '线路紧凑化失败，使用原始 JSON：' + String(error));
      return json;
    }
  }

  /** 解码后还原成 SearchSources 可解析的标准 userlist。 */
  private static expand(json: string): string {
    try {
      const document = JSON.parse(json) as CompactShareDocument;
      const rows: Array<Array<string | number>> | undefined = document.u;
      if (document.v !== 2 || rows === undefined || !Array.isArray(rows)) { return json; }
      const userlist: SearchSourceShareRow[] = [];
      for (const row of rows) {
        const item: SearchSourceShareRow = {
          id: Number(row[0]) || 0,
          name: String(row[1] || ''),
          url: String(row[2] || ''),
          urls: String(row[3] || ''),
          kind: String(row[4] || 'cms'),
          rule: String(row[5] || ''),
          img: row.length > 6 ? String(row[6] || '') : '',
          enabled: true
        };
        userlist.push(item);
      }
      return JSON.stringify({ version: 1, count: userlist.length, userlist: userlist });
    } catch (error) {
      Logger.warn('SOURCE_SHARE', '线路紧凑格式展开失败，使用原始 JSON：' + String(error));
      return json;
    }
  }

  /** 编码为多个二维码内容，每条不超过单张二维码可承载的字符数。 */
  static async encode(json: string): Promise<string[]> {
    let minified: string = json;
    try {
      minified = SourceShareCodec.compact(JSON.stringify(JSON.parse(json)));
    } catch (_) { /* 已是紧凑文本 */ }
    const plain: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(minified);
    const encrypted: Uint8Array = await SourceShareCodec.crypt(plain, true);
    const base64: string = new util.Base64Helper().encodeToStringSync(encrypted);
    const total: number = Math.ceil(base64.length / SourceShareCodec.CHUNK_SIZE);
    if (total > SourceShareCodec.MAX_PARTS) {
      throw new Error('线路过多，二维码需要 ' + String(total) + ' 张，超过单张海报上限，请使用文件导出');
    }
    const parts: string[] = [];
    for (let index: number = 0; index < total; index++) {
      const start: number = index * SourceShareCodec.CHUNK_SIZE;
      const chunk: string = base64.substring(start, Math.min(base64.length, start + SourceShareCodec.CHUNK_SIZE));
      parts.push(SourceShareCodec.PREFIX + String(index + 1) + '/' + String(total) + ':' + chunk);
    }
    Logger.info('SOURCE_SHARE', '线路二维码编码完成：JSON=' + String(minified.length) +
      '，加密=' + String(encrypted.byteLength) + '，分片=' + String(total));
    return parts;
  }

  /** 合并分片后解密，返回原始 JSON。 */
  static async decode(parts: string[]): Promise<string> {
    const base64: string = parts.join('');
    const encrypted: Uint8Array = new util.Base64Helper().decodeSync(base64);
    const plain: Uint8Array = await SourceShareCodec.crypt(encrypted, false);
    const json: string = new util.TextDecoder('utf-8').decodeWithStream(plain);
    if (!json.trim().startsWith('{') && !json.trim().startsWith('[')) {
      throw new Error('解密内容不是 JSON');
    }
    const expanded: string = SourceShareCodec.expand(json);
    Logger.info('SOURCE_SHARE', '线路二维码解码完成，JSON 长度=' + String(expanded.length));
    return expanded;
  }

  /** 解析二维码分片；不匹配时返回 undefined。 */
  static parsePart(text: string): SourceSharePart | undefined {
    const trimmed: string = (text || '').trim();
    const prefixAt: number = trimmed.indexOf(SourceShareCodec.PREFIX);
    if (prefixAt < 0) { return undefined; }
    const rest: string = trimmed.substring(prefixAt + SourceShareCodec.PREFIX.length);
    const colon: number = rest.indexOf(':');
    if (colon <= 0) { return undefined; }
    const header: string = rest.substring(0, colon);
    const slash: number = header.indexOf('/');
    if (slash <= 0) { return undefined; }
    const index: number = Number(header.substring(0, slash));
    const total: number = Number(header.substring(slash + 1));
    if (!Number.isFinite(index) || !Number.isFinite(total) || index < 1 || total < 1 || index > total) {
      return undefined;
    }
    return { index: index, total: total, payload: rest.substring(colon + 1).replace(/\s+/g, '') };
  }
}

export interface SourceSharePart {
  index: number;
  total: number;
  payload: string;
}

interface SearchSourceShareRow {
  id: number;
  name: string;
  url: string;
  urls: string;
  kind?: string;
  rule?: string;
  img?: string;
  enabled?: boolean;
}

interface ShareDocument {
  userlist?: SearchSourceShareRow[];
}

interface CompactShareDocument {
  v?: number;
  u?: Array<Array<string | number>>;
}

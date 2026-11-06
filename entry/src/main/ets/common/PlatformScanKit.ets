import { common } from '@kit.AbilityKit';
import { PlatformBridge } from './PlatformBridge';

/** 扫码类型占位。 */
export namespace scanCore {
  export enum ScanType {
    QR_CODE = 0,
    AZTEC = 1,
    DATAMATRIX = 2,
    PDF417 = 3,
    EAN_13 = 4,
    EAN_8 = 5,
    CODE_128 = 6,
    CODE_39 = 7,
    UPC_A = 8,
    UPC_E = 9
  }
}

/** 扫码结果。 */
export namespace scanBarcode {
  export interface ScanResult {
    originalValue: string;
    scanType?: scanCore.ScanType;
  }

  export interface ScanOptions {
    scanTypes?: scanCore.ScanType[];
    enableAlbum?: boolean;
  }

  export async function startScanForResult(context: common.UIAbilityContext,
    options?: ScanOptions): Promise<ScanResult> {
    const started: boolean = await PlatformBridge.startCameraScan();
    if (!started) { throw new Error('无法启动相机扫码'); }
    for (let index: number = 0; index < 120; index++) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 300); });
      const text: string = await PlatformBridge.lastScanResult();
      if (text.length > 0) {
        return { originalValue: text, scanType: scanCore.ScanType.QR_CODE };
      }
      if (await PlatformBridge.isScanFinished()) {
        throw new Error('已取消扫码');
      }
    }
    throw new Error('已取消扫码');
  }
}

/** 相册图片识别。 */
export namespace detectBarcode {
  export interface DetectOptions {
    uri: string;
  }

  export async function decode(options: DetectOptions, scanOptions?: scanBarcode.ScanOptions): Promise<scanBarcode.ScanResult[]> {
    const text: string = await PlatformBridge.decodeQr(options.uri);
    if (text.length === 0) { return []; }
    return [{ originalValue: text, scanType: scanCore.ScanType.QR_CODE }];
  }
}

/** 二维码生成占位。 */
export namespace generateBarcode {
  export enum ErrorCorrectionLevel {
    LEVEL_L = 0,
    LEVEL_M = 1,
    LEVEL_Q = 2,
    LEVEL_H = 3
  }

  export interface CreateOptions {
    scanType?: scanCore.ScanType;
    height?: number;
    width?: number;
    margin?: number;
    level?: ErrorCorrectionLevel;
    backgroundColor?: number;
    pixelMapColor?: number;
  }

  export interface BarcodeOptions {
    scanType?: scanCore.ScanType;
    height?: number;
    width?: number;
    margin?: number;
    backgroundColor?: number;
    pixelMapColor?: number;
    errorCorrectionLevel?: ErrorCorrectionLevel;
  }

  export async function createBarcode(content: string, options?: CreateOptions): Promise<ArrayBuffer> {
    // 空图占位；原生桥接入后返回真实二维码。
    return new ArrayBuffer(0);
  }
}

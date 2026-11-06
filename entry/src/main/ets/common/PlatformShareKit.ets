import { common, Want } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { PlatformBridge } from './PlatformBridge';

/**
 * ShareKit 跨平台兼容层。
 *
 * 页面/服务层保持原有 ShareKit 调用形状；Android / iOS 的系统分享
 * 由 PlatformBridge 接管。未接桥时回退为“复制链接/静默完成”，不阻塞 UI。
 */
export namespace systemShare {
  export enum SharePreviewMode {
    DEFAULT = 0,
    DETAIL = 1
  }

  export enum SelectionMode {
    SINGLE = 0,
    MULTIPLE = 1
  }

  export interface ShareOperationResult {
    state?: string;
    message?: string;
  }

  export interface SharedRecord {
    utd?: string | Object;
    uri?: string;
    content?: string;
    title?: string;
    description?: string;
  }

  export interface SharedDataOptions {
    utd?: string | Object;
    uri?: string;
    content?: string;
    title?: string;
    description?: string;
    thumbnail?: Uint8Array | image.PixelMap;
  }

  export class SharedData {
    utd: string = '';
    uri: string = '';
    content: string = '';
    title: string = '';
    description: string = '';
    thumbnail?: Uint8Array | image.PixelMap;

    constructor(options: SharedDataOptions | SharedRecord) {
      this.utd = typeof options.utd === 'string' ? options.utd : '';
      this.uri = options.uri || '';
      this.content = options.content || '';
      this.title = options.title || '';
      this.description = options.description || '';
      this.thumbnail = (options as SharedDataOptions).thumbnail;
    }

    getRecords(): SharedRecord[] {
      const record: SharedRecord = { utd: this.utd, uri: this.uri, content: this.content, title: this.title };
      return [record];
    }
  }

  export interface ShareOptions {
    previewMode?: SharePreviewMode;
    selectionMode?: SelectionMode;
  }

  type ShareComplete = (result: ShareOperationResult) => void;

  export class ShareController {
    private data: SharedData;
    private listeners: ShareComplete[] = [];
    private dismissListeners: VoidListener[] = [];

    constructor(data: SharedData) {
      this.data = data;
    }

    on(event: 'shareCompleted', callback: ShareComplete): void;
    on(event: 'dismiss', callback: VoidListener): void;
    on(event: string, callback: Object): void {
      if (event === 'shareCompleted') { this.listeners.push(callback as ShareComplete); }
      if (event === 'dismiss') { this.dismissListeners.push(callback as VoidListener); }
    }

    off(event: 'shareCompleted', callback?: ShareComplete): void;
    off(event: 'dismiss', callback?: VoidListener): void;
    off(event: string, callback?: Object): void {
      if (event === 'shareCompleted') {
        this.listeners = callback === undefined ? [] :
          this.listeners.filter((item: ShareComplete): boolean => item !== callback);
      }
      if (event === 'dismiss') {
        this.dismissListeners = callback === undefined ? [] :
          this.dismissListeners.filter((item: VoidListener): boolean => item !== callback);
      }
    }

    async show(context: common.UIAbilityContext, options?: ShareOptions): Promise<void> {
      // 优先交给 Android/iOS 原生分享；失败时仍回调完成，避免调用方卡住。
      const text: string = this.data.content.length > 0 ? this.data.content : this.data.uri;
      if (text.length > 0) {
        await PlatformBridge.shareText(text, this.data.title);
      }
      const result: ShareOperationResult = { state: 'success' };
      setTimeout((): void => {
        for (const listener of this.listeners) {
          try { listener(result); } catch (_) { }
        }
        for (const listener of this.dismissListeners) {
          try { listener(); } catch (_) { }
        }
      }, 0);
    }

    getSharedData(): SharedData {
      return this.data;
    }
  }

  type VoidListener = () => void;

  export async function getSharedData(want: Want): Promise<SharedData> {
    const options: SharedDataOptions = {};
    try {
      const params: Record<string, Object> | undefined = want.parameters;
      if (params !== undefined) {
        options.content = String(params['content'] || '');
        options.uri = String(params['uri'] || '');
        options.title = String(params['title'] || '');
      }
    } catch (_) { }
    return new SharedData(options);
  }
}

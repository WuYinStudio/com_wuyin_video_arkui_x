import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../Logger';
import { BridgeShare } from './BridgeShare';

/**
 * ShareKit 的跨平台适配层。
 * - HarmonyOS：可改用 legacy/harmonyos-only/ShareKit 原实现（华为分享 / 隔空传送）。
 * - Android：通过平台桥接启动系统分享面板（ACTION_SEND）。
 * - iOS：未接入 Bridge 时降级为复制到剪贴板并提示。
 */

export interface SharedRecord {
  utd: string;
  content: string;
  title?: string;
  description?: string;
  thumbnail?: Uint8Array;
}

export class SharedData {
  private recordList: SharedRecord[] = [];

  constructor(record: SharedRecord) {
    this.recordList = [record];
  }

  getRecords(): SharedRecord[] {
    return this.recordList;
  }
}

export enum SharePreviewMode {
  DEFAULT = 0,
  DETAIL = 1
}

/** ShareController.show 的选项，保持与 ShareKit 同名。 */
export interface ShareOptions {
  previewMode?: SharePreviewMode;
}

export interface ShareOperationResult {
  resultCode?: number;
  code?: number;
  status?: string;
  message?: string;
}

export class ShareController {
  private data: SharedData;
  private completedListener?: (result: ShareOperationResult) => void;
  private dismissListener?: () => void;

  constructor(data: SharedData) {
    this.data = data;
  }

  on(type: string, callback: (result: ShareOperationResult) => void): void {
    if (type === 'shareCompleted') {
      this.completedListener = callback;
    } else if (type === 'dismiss') {
      this.dismissListener = () => { callback({ resultCode: 0 }); };
    }
  }

  async show(context: common.UIAbilityContext, options?: ShareOptions): Promise<void> {
    const records: SharedRecord[] = this.data.getRecords();
    const record: SharedRecord | undefined = records.length > 0 ? records[0] : undefined;
    const content: string = record !== undefined ? record.content : '';
    const title: string = record !== undefined && record.title !== undefined && record.title.length > 0
      ? record.title : '无音影视';
    let nativeShared: boolean = false;
    if (content.length > 0) {
      nativeShared = await BridgeShare.shareText(title, content);
    }
    if (!nativeShared) {
      await ShareController.copyFallback(content);
    }
    const result: ShareOperationResult = {
      resultCode: nativeShared ? 0 : 1,
      status: nativeShared ? 'success' : 'copied',
      message: nativeShared ? '' : '当前平台未接入系统分享面板，内容已复制到剪贴板'
    };
    if (this.completedListener !== undefined) {
      try { this.completedListener(result); } catch (error) { Logger.warn('SHARE', '分享结果回调异常：' + String(error)); }
    }
    if (this.dismissListener !== undefined) {
      try { this.dismissListener(); } catch (error) { Logger.warn('SHARE', '分享面板关闭回调异常：' + String(error)); }
    }
  }

  private static async copyFallback(content: string): Promise<void> {
    if (content.length === 0) { return; }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '分享内容已复制到剪贴板', duration: 2000 });
    } catch (error) {
      Logger.error('SHARE', '复制分享内容失败：' + String(error));
    }
  }
}

/** 读取外部传入的分享文本（Android EXTRA_TEXT / URL Scheme 参数）。 */
export async function getSharedData(want: Want): Promise<SharedData | undefined> {
  try {
    const parameters = want.parameters;
    if (parameters === undefined) { return undefined; }
    const keys: string[] = ['ohos.extra.param.key.share_data', 'share_data', 'text'];
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object | undefined = parameters[keys[index]];
      if (typeof value === 'string' && value.length > 0) {
        return new SharedData({ utd: 'general.text', content: value });
      }
    }
  } catch (error) {
    Logger.warn('SHARE', '读取分享数据失败：' + String(error));
  }
  return undefined;
}

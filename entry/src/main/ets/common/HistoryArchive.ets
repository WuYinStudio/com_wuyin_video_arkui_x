import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { WatchRecord } from './AppState';
import { Logger } from './Logger';
import { PlatformApi } from './compat/PlatformApi';

/** 播放历史归档：固定 zip 文件名及包内 txt 文件名。 */
export class HistoryArchive {
  private static readonly ZIP_NAME: string = '无音影视播放历史.zip';
  private static readonly TXT_NAME: string = '影视名称.txt';
  private static readonly MAX_TEXT_SIZE: number = 16 * 1024 * 1024;
  private static readonly MAX_ZIP_SIZE: number = 32 * 1024 * 1024;

  private static async chooseSaveFile(context: common.UIAbilityContext): Promise<string | undefined> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const result = await documentPicker.save({
      newFileNames: [HistoryArchive.ZIP_NAME],
        fileSuffixChoices: ['.zip']
    });
    return result && result.length > 0 ? result[0] : undefined;
  }

  private static async chooseOpenFile(context: common.UIAbilityContext): Promise<string | undefined> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const openOptions: picker.DocumentSelectOptions = { fileSuffixFilters: ['.zip'] };
    PlatformApi.setMaxSelectNumber(openOptions as Object, 1);
    const result = await documentPicker.select(openOptions);
    return result && result.length > 0 ? result[0] : undefined;
  }

  private static writeAll(descriptor: number, buffer: ArrayBuffer): void {
    let written: number = 0;
    while (written < buffer.byteLength) {
      const count: number = fileIo.writeSync(descriptor, written === 0 ? buffer : buffer.slice(written));
      if (count <= 0) { throw new Error('播放历史文件写入不完整'); }
      written += count;
    }
  }

  private static copyFile(sourcePath: string, targetPath: string, maximumSize: number = HistoryArchive.MAX_ZIP_SIZE): void {
    const source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    try {
      const sourceSize: number = fileIo.statSync(source.fd).size;
      if (sourceSize <= 0 || sourceSize > maximumSize) {
        throw new Error('播放历史压缩包为空或超过大小限制');
      }
      const target = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(64 * 1024);
        let count: number = 0;
        let copied: number = 0;
        while ((count = fileIo.readSync(source.fd, buffer)) > 0) {
          copied += count;
          if (copied > maximumSize) { throw new Error('播放历史压缩包超过大小限制'); }
          HistoryArchive.writeAll(target.fd, count === buffer.byteLength ? buffer : buffer.slice(0, count));
        }
        if (copied !== sourceSize) { throw new Error('播放历史压缩包读取不完整'); }
      } finally { fileIo.closeSync(target); }
    } finally { fileIo.closeSync(source); }
  }

  private static cleanup(directory: string): void {
    if (!directory) { return; }
    try {
      if (fileIo.accessSync(directory)) { fileIo.rmdirSync(directory); }
    } catch (error) {
      // 清理失败不覆盖导入/导出的原始结果；目录仅包含本次操作的临时文件。
      Logger.error('HISTORY_ARCHIVE', '清理临时归档失败：' + String(error));
    }
  }

  static async exportFile(context: common.UIAbilityContext, records: WatchRecord[]): Promise<boolean> {
    let temporaryDirectory: string = '';
    try {
      // 选择器授权及后续文件访问统一放在异常边界内，不申请广泛存储权限。
      const targetUri: string | undefined = await HistoryArchive.chooseSaveFile(context);
      if (!targetUri) {
        Logger.info('HISTORY_ARCHIVE', '取消导出播放历史');
        return false;
      }
      temporaryDirectory = context.cacheDir + '/wuyin_history_export_' + Date.now();
      fileIo.mkdirSync(temporaryDirectory);
      const textPath: string = temporaryDirectory + '/' + HistoryArchive.TXT_NAME;
      const zipPath: string = temporaryDirectory + '/' + HistoryArchive.ZIP_NAME;
      const textFile = fileIo.openSync(textPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const encoded: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(records));
        if (encoded.byteLength > HistoryArchive.MAX_TEXT_SIZE) { throw new Error('播放历史文件过大'); }
        HistoryArchive.writeAll(textFile.fd, encoded.buffer as ArrayBuffer);
      } finally { fileIo.closeSync(textFile); }
      await zlib.compressFile(textPath, zipPath, {});
      HistoryArchive.copyFile(zipPath, targetUri);
      Logger.info('HISTORY_ARCHIVE', '播放历史导出完成，条数=' + records.length);
      return true;
    } catch (error) {
      Logger.error('HISTORY_ARCHIVE', '导出归档失败：' + String(error));
      throw new Error(String(error));
    } finally { HistoryArchive.cleanup(temporaryDirectory); }
  }

  static async importFile(context: common.UIAbilityContext): Promise<WatchRecord[] | undefined> {
    let temporaryDirectory: string = '';
    try {
      const sourceUri: string | undefined = await HistoryArchive.chooseOpenFile(context);
      if (!sourceUri) {
        Logger.info('HISTORY_ARCHIVE', '取消导入播放历史');
        return undefined;
      }
      // 授权 URI 不一定携带显示名称，使用包内固定文本文件校验归档。
      // 独立工作目录避免上一次导入残留文件被误识别为本次内容。
      temporaryDirectory = context.cacheDir + '/wuyin_history_import_' + Date.now();
      fileIo.mkdirSync(temporaryDirectory);
      const zipPath: string = temporaryDirectory + '/' + HistoryArchive.ZIP_NAME;
      const textPath: string = temporaryDirectory + '/' + HistoryArchive.TXT_NAME;
      HistoryArchive.copyFile(sourceUri, zipPath);
      await zlib.decompressFile(zipPath, temporaryDirectory);
      const textFile = fileIo.openSync(textPath, fileIo.OpenMode.READ_ONLY);
      let textBuffer: ArrayBuffer;
      try {
        const textStat = fileIo.statSync(textFile.fd);
        if (textStat.size <= 0 || textStat.size > HistoryArchive.MAX_TEXT_SIZE) {
          throw new Error('播放历史文件为空或超过大小限制');
        }
        textBuffer = new ArrayBuffer(textStat.size);
        const bytes = new Uint8Array(textBuffer);
        const chunk = new ArrayBuffer(Math.min(64 * 1024, textStat.size));
        let received: number = 0;
        while (received < textStat.size) {
          const count: number = fileIo.readSync(textFile.fd, chunk, { length: Math.min(chunk.byteLength, textStat.size - received) });
          if (count <= 0) { throw new Error('播放历史文件读取不完整'); }
          bytes.set(new Uint8Array(chunk, 0, count), received);
          received += count;
        }
      } finally { fileIo.closeSync(textFile); }
      const json: string = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeWithStream(new Uint8Array(textBuffer));
      const parsed: Object = JSON.parse(json) as Object;
      if (!Array.isArray(parsed)) { throw new Error('归档内容不是播放历史列表'); }
      const records: WatchRecord[] = parsed as WatchRecord[];
      if (!records.every((record: WatchRecord) => record !== null && typeof record === 'object' &&
        Number.isFinite(record.id) && Number.isFinite(record.episode) && record.episode >= 1 &&
        Number.isFinite(record.position) && record.position >= 0 && Number.isFinite(record.duration) && record.duration >= 0 &&
        typeof record.time === 'string' &&
        (record.name === undefined || typeof record.name === 'string') &&
        (record.cover === undefined || typeof record.cover === 'string') &&
        (record.vodId === undefined || typeof record.vodId === 'string') &&
        (record.wzlj === undefined || typeof record.wzlj === 'string'))) {
        throw new Error('归档包含无效的播放记录');
      }
      Logger.info('HISTORY_ARCHIVE', '播放历史归档校验完成，条数=' + records.length);
      return records;
    } catch (error) {
      Logger.error('HISTORY_ARCHIVE', '导入归档失败：' + String(error));
      throw new Error(String(error));
    } finally { HistoryArchive.cleanup(temporaryDirectory); }
  }
}

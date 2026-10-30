import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';

// 本地日志轮转：当前文件最大5MB，保留三份归档。通过系统保存面板授权导出。
export class Logger {
  static enabled: boolean = true;
  private static directory: string = '';
  static init(context: common.UIAbilityContext): void {
    Logger.directory = context.filesDir;
    Logger.info('DEVICE', '日志服务初始化');
  }
  static path(): string { return Logger.directory + '/runtime.log'; }
  static write(level: string, tag: string, message: string): void {
    if (!Logger.enabled || !Logger.directory) { return; }
    try {
      // 统一写入可供日志页面逐行解析的分级标签；未知级别按 INFO 处理。
      const logLevel: string = level === 'WARN' || level === 'ERROR' ? level : 'INFO';
      const path = Logger.path();
      if (fs.accessSync(path) && fs.statSync(path).size >= 5 * 1024 * 1024) {
        if (fs.accessSync(path + '.3')) { fs.unlinkSync(path + '.3'); }
        for (let i = 2; i >= 1; i--) {
          if (fs.accessSync(path + '.' + i)) { fs.renameSync(path + '.' + i, path + '.' + (i + 1)); }
        }
        fs.renameSync(path, path + '.1');
      }
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, `[${new Date().toISOString()}] [${logLevel}] [${tag}] ${message} | ${deviceInfo.deviceType},${deviceInfo.displayVersion}\n`);
      } finally { fs.closeSync(file); }
    } catch (error) { console.error('日志写入失败：' + String(error)); }
  }
  // 调试日志沿用 INFO 级别，保持现有日志页面的分级解析兼容。
  static debug(tag: string, message: string): void { Logger.info(tag, message); }
  static info(tag: string, message: string): void { Logger.write('INFO', tag, message); }
  static warn(tag: string, message: string): void { Logger.write('WARN', tag, message); }
  static error(tag: string, error: string): void { Logger.write('ERROR', tag, error); }
  static read(): string {
    let text = '';
    try {
      for (let i = 3; i >= 0; i--) {
        const path = Logger.path() + (i === 0 ? '' : '.' + i);
        if (fs.accessSync(path)) { text += fs.readTextSync(path); }
      }
    } catch (error) { Logger.error('READ', String(error)); }
    return text || '暂无运行日志';
  }
  static clear(): void {
    try {
      for (let i = 0; i <= 3; i++) {
        const path = Logger.path() + (i === 0 ? '' : '.' + i);
        if (fs.accessSync(path)) { fs.unlinkSync(path); }
      }
    } catch (error) { Logger.error('CLEAR', String(error)); }
  }
  static async export(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['wuyin-runtime.txt'];
      const paths = await new picker.DocumentViewPicker(context).save(options);
      if (!paths.length) { return false; }
      const file = fileIo.openSync(paths[0], fileIo.OpenMode.READ_WRITE);
      try { fileIo.writeSync(file.fd, Logger.read()); } finally { fileIo.closeSync(file); }
      return true;
    } catch (error) { Logger.error('EXPORT', String(error)); return false; }
  }
}

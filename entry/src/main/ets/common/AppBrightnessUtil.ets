import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger } from './Logger';

// 仅管理播放页的窗口亮度，不修改系统设置；退出播放页恢复原值。
export class AppBrightnessUtil {
  private target?: window.Window;
  private originalValue: number = -1;
  private currentValue: number = 0.5;
  private released: boolean = false;
  private revision: number = 0;
  private pending: Promise<void> = Promise.resolve();

  async attach(context: common.UIAbilityContext): Promise<number> {
    const revision: number = ++this.revision;
    this.released = false;
    try {
      const target: window.Window = await window.getLastWindow(context);
      if (this.released || revision !== this.revision) { return this.currentValue; }
      this.target = target;
      this.originalValue = target.getWindowProperties().brightness;
      this.currentValue = Number.isFinite(this.originalValue) && this.originalValue >= 0 ?
        Math.max(0.05, Math.min(1, this.originalValue)) : 0.5;
    } catch (error) { Logger.warn('PLAYER_BRIGHTNESS', '读取窗口亮度失败，使用视频遮罩：' + String(error)); }
    return this.currentValue;
  }

  // 返回遮罩强度：窗口调节成功时为零，仅在平台不支持调节时启用视频区遮罩。
  async setValue(value: number): Promise<number> {
    const requested: number = Math.max(0.05, Math.min(1, value));
    this.currentValue = requested;
    const revision: number = this.revision;
    let maskValue: number = 0;
    const task: Promise<void> = this.pending.then(async (): Promise<void> => {
      if (this.released || revision !== this.revision) { return; }
      try {
        if (!this.target) { throw new Error('窗口未就绪'); }
        await this.target.setWindowBrightness(requested);
      } catch (error) {
        maskValue = 1 - requested;
        Logger.warn('PLAYER_BRIGHTNESS', '窗口亮度调节失败，回退视频遮罩：' + String(error));
      }
    });
    this.pending = task;
    try { await task; }
    catch (error) { maskValue = 1 - requested; Logger.error('PLAYER_BRIGHTNESS', '亮度任务失败：' + String(error)); }
    return maskValue;
  }

  async restore(): Promise<void> {
    this.released = true;
    ++this.revision;
    const target: window.Window | undefined = this.target;
    this.target = undefined;
    try {
      await this.pending;
      if (target) { await target.setWindowBrightness(this.originalValue); }
    } catch (error) { Logger.warn('PLAYER_BRIGHTNESS', '恢复窗口亮度失败：' + String(error)); }
  }
}

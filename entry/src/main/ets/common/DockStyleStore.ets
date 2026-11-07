import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { batteryInfo } from './PlatformBattery';
import { Logger } from './Logger';

/** Dock 栏外观样式定义。 */
export class DockStyleOption {
  key: string = '';
  title: string = '';
  desc: string = '';
}

/** Dock 栏外观配置：样式、强度、低电量自适应。 */
export class DockStyleConfig {
  /** glow（沉浸光感，默认）/ liquid（液态玻璃）/ blur（实时高斯模糊）。 */
  /** 默认样式：沉浸光感。 */
  style: string = 'glow';
  /** 强度 0~100。 */
  intensity: number = 70;
  /** 低电量时自动降低强度。 */
  batteryAuto: boolean = true;
  /** 触发自动降级的电量阈值（百分比）。 */
  batteryThreshold: number = 20;
}

/**
 * Dock 栏外观配置中心。
 *
 * 配置写入 AppStorage（dockStyle / dockIntensity / dockBatteryAuto / dockBatteryThreshold），
 * LiquidNav 通过 @StorageLink 实时读取；电量变化也发布到 dockBatteryPercent，
 * 低电量时按阈值线性调低强度（最低约 35%），保证弱电下不额外耗电。
 */
export class DockStyleStore {
  static readonly OPTIONS: DockStyleOption[] = [
    { key: 'liquid', title: '液态玻璃', desc: '渐变高光 + 圆角胶囊，默认风格' },
    { key: 'blur', title: '实时高斯模糊', desc: '强化背景虚化，界面更通透' },
    { key: 'glow', title: '沉浸光感', desc: '主题色光晕 + 玻璃反射，最亮眼' },
  ];
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_STYLE: string = 'dockStyleKey';
  private static readonly KEY_INTENSITY: string = 'dockStyleIntensity';
  private static readonly KEY_AUTO: string = 'dockStyleBatteryAuto';
  private static readonly KEY_THRESHOLD: string = 'dockStyleBatteryThreshold';
  private static store: preferences.Preferences | undefined = undefined;
  private static subscribed: boolean = false;
  private static config: DockStyleConfig = new DockStyleConfig();

  static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      DockStyleStore.store = await preferences.getPreferences(context, DockStyleStore.STORE);
      const style: string = String(await DockStyleStore.store.get(DockStyleStore.KEY_STYLE, 'glow'));
      const intensity: number = Number(await DockStyleStore.store.get(DockStyleStore.KEY_INTENSITY, 70));
      const auto: boolean = Boolean(await DockStyleStore.store.get(DockStyleStore.KEY_AUTO, true));
      const threshold: number = Number(await DockStyleStore.store.get(DockStyleStore.KEY_THRESHOLD, 20));
      DockStyleStore.config.style = DockStyleStore.normalizeStyle(style);
      DockStyleStore.config.intensity = DockStyleStore.clampPercent(intensity, 70);
      DockStyleStore.config.batteryAuto = auto;
      DockStyleStore.config.batteryThreshold = DockStyleStore.clampPercent(threshold, 20);
      DockStyleStore.publish();
      DockStyleStore.watchBattery();
      Logger.info('DOCK_STYLE', 'Dock 外观已恢复：样式=' + DockStyleStore.config.style +
        '，强度=' + String(DockStyleStore.config.intensity) +
        '，低电量自适应=' + String(auto) + '，阈值=' + String(DockStyleStore.config.batteryThreshold) + '%');
    } catch (error) {
      Logger.error('DOCK_STYLE', '读取 Dock 外观配置失败：' + String(error));
      DockStyleStore.publish();
    }
  }

  static current(): DockStyleConfig {
    const copy: DockStyleConfig = new DockStyleConfig();
    copy.style = DockStyleStore.config.style;
    copy.intensity = DockStyleStore.config.intensity;
    copy.batteryAuto = DockStyleStore.config.batteryAuto;
    copy.batteryThreshold = DockStyleStore.config.batteryThreshold;
    return copy;
  }

  static async save(style: string, intensity: number, batteryAuto: boolean,
    batteryThreshold: number): Promise<void> {
    DockStyleStore.config.style = DockStyleStore.normalizeStyle(style);
    DockStyleStore.config.intensity = DockStyleStore.clampPercent(intensity, 70);
    DockStyleStore.config.batteryAuto = batteryAuto;
    DockStyleStore.config.batteryThreshold = DockStyleStore.clampPercent(batteryThreshold, 20);
    DockStyleStore.publish();
    if (DockStyleStore.store !== undefined) {
      await DockStyleStore.store.put(DockStyleStore.KEY_STYLE, DockStyleStore.config.style);
      await DockStyleStore.store.put(DockStyleStore.KEY_INTENSITY, DockStyleStore.config.intensity);
      await DockStyleStore.store.put(DockStyleStore.KEY_AUTO, DockStyleStore.config.batteryAuto);
      await DockStyleStore.store.put(DockStyleStore.KEY_THRESHOLD, DockStyleStore.config.batteryThreshold);
      await DockStyleStore.store.flush();
    }
    Logger.info('DOCK_STYLE', 'Dock 外观已保存：样式=' + DockStyleStore.config.style +
      '，强度=' + String(DockStyleStore.config.intensity));
  }

  /** 当前电量（百分比），供设置页展示。 */
  static batteryPercent(): number {
    try {
      const soc: number = Number(batteryInfo.batterySOC);
      return Number.isFinite(soc) && soc >= 0 ? Math.min(100, Math.round(soc)) : 100;
    } catch (_) {
      return 100;
    }
  }

  /** 低电量降级后的实际强度系数（0.35~1）。 */
  static effectiveFactor(config: DockStyleConfig, battery: number): number {
    const base: number = Math.max(0, Math.min(100, config.intensity)) / 100;
    if (!config.batteryAuto || battery > config.batteryThreshold || config.batteryThreshold <= 0) {
      return base;
    }
    const ratio: number = Math.max(0, Math.min(1, battery / config.batteryThreshold));
    return Math.max(0.35, base * (0.45 + 0.55 * ratio));
  }

  private static publish(): void {
    AppStorage.setOrCreate<string>('dockStyle', DockStyleStore.config.style);
    AppStorage.setOrCreate<number>('dockIntensity', DockStyleStore.config.intensity);
    AppStorage.setOrCreate<boolean>('dockBatteryAuto', DockStyleStore.config.batteryAuto);
    AppStorage.setOrCreate<number>('dockBatteryThreshold', DockStyleStore.config.batteryThreshold);
    AppStorage.setOrCreate<number>('dockBatteryPercent', DockStyleStore.batteryPercent());
  }

  /** 订阅电量变化：只更新 AppStorage 里的电量，Dock 会自动重算强度。 */
  private static watchBattery(): void {
    if (DockStyleStore.subscribed) { return; }
    try {
      // 跨平台电量变化由原生电池桥更新；首版读取一次固定值。
      AppStorage.setOrCreate<number>('dockBatteryPercent', DockStyleStore.batteryPercent());
      DockStyleStore.subscribed = true;
    } catch (error) {
      Logger.warn('DOCK_STYLE', '读取电量失败：' + String(error));
    }
  }

  private static normalizeStyle(style: string): string {
    const key: string = (style || '').trim();
    for (const option of DockStyleStore.OPTIONS) {
      if (option.key === key) { return key; }
    }
    return 'glow';
  }

  private static clampPercent(value: number, fallback: number): number {
    if (!Number.isFinite(value)) { return fallback; }
    return Math.max(0, Math.min(100, Math.round(value)));
  }
}

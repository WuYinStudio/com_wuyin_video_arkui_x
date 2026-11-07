import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { Logger } from './Logger';
import { PlatformBridge } from './PlatformBridge';

/** 帧率设置：软件（整机 App）与播放器分别可选。 */
export class FrameRateConfig {
  followSystem: boolean = true;
  appHz: number = 60;
  playerHz: number = 60;
}

/**
 * 跨平台帧率服务。
 *
 * HarmonyOS 通过 DisplaySync 申请屏幕刷新率；Android / iOS 需要原生
 * preferredDisplayMode / CADisplayLink 才能切换。当前保留配置读写与 UI，
 * 帧率应用交由后续原生桥接；跟随系统时行为与系统一致。
 */
export class FrameRateService {
  static readonly APP_OPTIONS: number[] = [60, 90, 120, 144, 165, 185];
  static readonly PLAYER_OPTIONS: number[] = [60, 90, 120, 144, 165, 185];
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_FOLLOW: string = 'frameRateFollowSystem';
  private static readonly KEY_APP: string = 'frameRateAppHz';
  private static readonly KEY_PLAYER: string = 'frameRatePlayerHz';
  private static store: preferences.Preferences | undefined = undefined;
  private static config: FrameRateConfig = new FrameRateConfig();
  private static playerActive: boolean = false;
  private static wallpaperActive: boolean = false;
  private static wallpaperHz: number = 0;

  static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      FrameRateService.store = await preferences.getPreferences(context, FrameRateService.STORE);
      const follow: boolean = Boolean(await FrameRateService.store.get(FrameRateService.KEY_FOLLOW, true));
      const appHz: number = Number(await FrameRateService.store.get(FrameRateService.KEY_APP, 60));
      const playerHz: number = Number(await FrameRateService.store.get(FrameRateService.KEY_PLAYER, 60));
      FrameRateService.config.followSystem = follow;
      FrameRateService.config.appHz = FrameRateService.alignToOption(appHz);
      FrameRateService.config.playerHz = FrameRateService.alignToOption(playerHz);
      FrameRateService.apply();
    } catch (error) {
      Logger.warn('FRAME_RATE', '读取帧率配置失败：' + String(error));
    }
  }

  static refreshCapability(): void {
  }

  static maxSupportedHz(): number {
    return 0;
  }

  static isSupported(hz: number): boolean {
    return FrameRateService.APP_OPTIONS.includes(hz);
  }

  private static alignToOption(value: number): number {
    let best: number = FrameRateService.APP_OPTIONS[0];
    let distance: number = Math.abs(value - best);
    for (const option of FrameRateService.APP_OPTIONS) {
      const current: number = Math.abs(value - option);
      if (current < distance) { best = option; distance = current; }
    }
    return best;
  }

  static current(): FrameRateConfig {
    const copy: FrameRateConfig = new FrameRateConfig();
    copy.followSystem = FrameRateService.config.followSystem;
    copy.appHz = FrameRateService.config.appHz;
    copy.playerHz = FrameRateService.config.playerHz;
    return copy;
  }

  static async save(followSystem: boolean, appHz: number, playerHz: number): Promise<void> {
    FrameRateService.config.followSystem = followSystem;
    FrameRateService.config.appHz = FrameRateService.alignToOption(appHz);
    FrameRateService.config.playerHz = FrameRateService.alignToOption(playerHz);
    try {
      const store: preferences.Preferences | undefined = FrameRateService.store;
      if (store !== undefined) {
        await store.put(FrameRateService.KEY_FOLLOW, followSystem);
        await store.put(FrameRateService.KEY_APP, FrameRateService.config.appHz);
        await store.put(FrameRateService.KEY_PLAYER, FrameRateService.config.playerHz);
        await store.flush();
      }
    } catch (error) {
      Logger.warn('FRAME_RATE', '保存帧率配置失败：' + String(error));
    }
    FrameRateService.apply();
  }

  static enterPlayer(): void {
    FrameRateService.playerActive = true;
    FrameRateService.apply();
  }

  static leavePlayer(): void {
    FrameRateService.playerActive = false;
    FrameRateService.apply();
  }

  static setWallpaperState(active: boolean, hz: number): void {
    FrameRateService.wallpaperActive = active;
    FrameRateService.wallpaperHz = FrameRateService.normalizeWallpaperHz(hz);
    FrameRateService.apply();
  }

  private static normalizeWallpaperHz(hz: number): number {
    if (!Number.isFinite(hz) || hz <= 0) { return 0; }
    return Math.round(hz);
  }

  static effectiveHz(): number {
    if (FrameRateService.config.followSystem) { return 0; }
    if (FrameRateService.playerActive) { return FrameRateService.config.playerHz; }
    return FrameRateService.config.appHz;
  }

  private static apply(): void {
    void PlatformBridge.setFrameRate(FrameRateService.effectiveHz());
  }
}

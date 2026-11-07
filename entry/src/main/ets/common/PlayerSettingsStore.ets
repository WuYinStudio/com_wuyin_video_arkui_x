import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import { Logger } from './Logger';

/**
 * 播放器「播放设置」面板的持久化配置。
 *
 * 与主题/壁纸不同，这些开关只影响播放器自身：循环方式、跳过片头片尾、护眼、
 * 色觉辅助、高能进度条、礼物特效、快进截图、后台播放、流量辅助等。
 */
export class PlayerExtraSettings {
  /** 循环方式：off / single / list。 */
  loopMode: string = 'off';
  /** 是否启用片头片尾跳过。 */
  skipIntroOutro: boolean = false;
  /** 片头秒数。 */
  introSeconds: number = 0;
  /** 片尾秒数。 */
  outroSeconds: number = 0;
  /** 护眼模式（暖色遮罩）。 */
  eyeCare: boolean = false;
  /** 色觉辅助：off / yellow / blue。 */
  colorAssist: string = 'off';
  /** 高能进度条。 */
  energyBar: boolean = false;
  /** 礼物特效。 */
  giftEffect: boolean = true;
  /** 快进时显示视频截图。 */
  seekSnapshot: boolean = true;
  /** 后台播放。 */
  backgroundPlay: boolean = false;
  /** 流量辅助播放。 */
  trafficAssist: boolean = false;
  /** 分辨率偏好：auto / 1080 / 720 / 480。 */
  resolution: string = 'auto';
  /** 优先选择 HDR 片源。 */
  hdr: boolean = false;
}

export class PlayerSettingsStore {
  private static readonly STORE: string = 'wuyin';
  private static readonly KEY_SETTINGS: string = 'playerExtraSettings';
  private static readonly KEY_BLOCKED: string = 'playerBlockedVods';
  private static store?: preferences.Preferences;

  private static async ensure(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (PlayerSettingsStore.store === undefined) {
      PlayerSettingsStore.store = await preferences.getPreferences(context, PlayerSettingsStore.STORE);
    }
    return PlayerSettingsStore.store;
  }

  static async load(context: common.UIAbilityContext): Promise<PlayerExtraSettings> {
    const result: PlayerExtraSettings = new PlayerExtraSettings();
    try {
      const store: preferences.Preferences = await PlayerSettingsStore.ensure(context);
      const raw: string = String(await store.get(PlayerSettingsStore.KEY_SETTINGS, ''));
      if (raw.length === 0) {
        return result;
      }
      const saved: PlayerExtraSettings = JSON.parse(raw) as PlayerExtraSettings;
      if (saved === undefined || saved === null) {
        return result;
      }
      result.loopMode = saved.loopMode === 'single' || saved.loopMode === 'list' ? saved.loopMode : 'off';
      result.skipIntroOutro = Boolean(saved.skipIntroOutro);
      result.introSeconds = PlayerSettingsStore.clampSeconds(saved.introSeconds);
      result.outroSeconds = PlayerSettingsStore.clampSeconds(saved.outroSeconds);
      result.eyeCare = Boolean(saved.eyeCare);
      result.colorAssist = saved.colorAssist === 'yellow' || saved.colorAssist === 'blue' ? saved.colorAssist : 'off';
      result.energyBar = Boolean(saved.energyBar);
      result.giftEffect = saved.giftEffect !== false;
      result.seekSnapshot = saved.seekSnapshot !== false;
      result.backgroundPlay = Boolean(saved.backgroundPlay);
      result.trafficAssist = Boolean(saved.trafficAssist);
      result.resolution = saved.resolution === '4k' || saved.resolution === '1080' ||
        saved.resolution === '720' || saved.resolution === '480'
        ? saved.resolution : 'auto';
      result.hdr = Boolean(saved.hdr);
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '读取播放设置失败：' + String(error));
    }
    return result;
  }

  static async save(context: common.UIAbilityContext, settings: PlayerExtraSettings): Promise<void> {
    try {
      const store: preferences.Preferences = await PlayerSettingsStore.ensure(context);
      await store.put(PlayerSettingsStore.KEY_SETTINGS, JSON.stringify(settings));
      await store.flush();
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '保存播放设置失败：' + String(error));
    }
  }

  /** 设为禁看：本地记录被禁看的影片 id，供后续列表过滤使用。 */
  static async blockVideo(context: common.UIAbilityContext, vodId: string): Promise<void> {
    const id: string = vodId.trim();
    if (id.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await PlayerSettingsStore.ensure(context);
      const raw: string = String(await store.get(PlayerSettingsStore.KEY_BLOCKED, '[]'));
      let ids: string[] = [];
      try {
        ids = JSON.parse(raw) as string[];
      } catch (error) {
        ids = [];
      }
      if (ids.indexOf(id) < 0) {
        ids.push(id);
        await store.put(PlayerSettingsStore.KEY_BLOCKED, JSON.stringify(ids));
        await store.flush();
      }
      Logger.info('PLAYER_SETTINGS', '已设为禁看：' + id);
    } catch (error) {
      Logger.warn('PLAYER_SETTINGS', '写入禁看列表失败：' + String(error));
    }
  }

  static async blockedVideos(context: common.UIAbilityContext): Promise<string[]> {
    try {
      const store: preferences.Preferences = await PlayerSettingsStore.ensure(context);
      const raw: string = String(await store.get(PlayerSettingsStore.KEY_BLOCKED, '[]'));
      return JSON.parse(raw) as string[];
    } catch (error) {
      return [];
    }
  }

  private static clampSeconds(value: number): number {
    if (!Number.isFinite(value)) {
      return 0;
    }
    return Math.max(0, Math.min(300, Math.round(value)));
  }
}

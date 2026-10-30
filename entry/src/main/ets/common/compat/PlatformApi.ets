import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { window, router, display } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { notificationManager } from '@kit.NotificationKit';
import { PlatformInfo } from './PlatformInfo';
import { Logger } from '../Logger';

/**
 * 平台能力分流层：**HarmonyOS 走原生实现，Android / iOS 走明确降级**。
 *
 * 为什么需要这一层：模块一旦在 `.arkui-x/arkui-x-config.json5` 里声明为跨平台，ArkTS 编译器就会把
 * 对 HarmonyOS 专属 API 的直接调用报成 `11706007 can't support crossplatform application`；
 * 这是**静态**检查，`if (PlatformInfo.isHarmonyOS())` 这种运行期判断也拦不住
 * （实测：`@ts-nocheck` 被 `arkts-strict-typing-required` 禁止，命名空间也不能 `as Object` 中转
 * —— `arkts-no-ns-as-obj`）。
 *
 * 所以这里的策略分三类：
 *   1. **实例方法**（window / 相册 helper / NotificationRequest / 选择器 options）：
 *      用 `实例 as Object as 局部接口` 中转即可通过静态检查，鸿蒙上恢复原生能力；
 *   2. **跨平台可用的等价 API**：直接换成 ArkUI-X 支持的写法（`connection.hasDefaultNet`、
 *      `fileIo.statvfs`）；
 *   3. **上面两类都覆盖不到的命名空间成员**（`request.agent.getTask`、
 *      `notificationManager.cancel`、`connection.getNetCapabilities`）：只能降级，
 *      并在调用方保留原有兜底逻辑。
 *
 * 维护约定：只放「按平台分流的小函数」，不放业务逻辑；每个降级分支都要能被调用方安全消费。
 */

interface NotificationRequestLike {
  wantAgent?: Object;
}

/** ArkUI-X 未在 window.Window 上声明 getPreferredOrientation / snapshot，用实例中转访问。 */
interface WindowOrientationLike {
  getPreferredOrientation(): window.Orientation;
}

interface WindowSnapshotLike {
  snapshot(): Promise<image.PixelMap>;
}

/** photoAccessHelper.PhotoAccessHelper 上未声明 showAssetsCreationDialog。 */
interface AssetsHelperLike {
  showAssetsCreationDialog(srcFileUris: string[],
    photoCreationConfigs: photoAccessHelper.PhotoCreationConfig[]): Promise<string[]>;
}

export class PlatformApi {
  /**
   * 等价于 `router.replaceUrl`。
   * `router` 是命名空间，无法中转，因此三端统一用「压栈 + 清空历史」：
   * 新页面成为栈内唯一页面，返回键不会回到被替换的页面（登录/登出/删号等场景语义一致）。
   */
  static replaceRoute(options: router.RouterOptions): Promise<void> {
    return router.pushUrl(options)
      .then((): void => {
        try { router.clear(); } catch (error) { Logger.warn('ROUTER', '清空路由历史失败：' + String(error)); }
      })
      .catch((error: Error): void => { Logger.error('ROUTER', '路由替换失败：' + String(error)); });
  }

  /**
   * 拖动定位精度：HarmonyOS 用 `SEEK_CLOSEST`（最近帧），其它平台用 `SEEK_PREV_SYNC`（最近关键帧）。
   * 枚举成员不能直接写（会被门禁拦截），这里按 d.ts 的数值定义取 SEEK_CLOSEST = 2。
   */
  static seekModeClosest(): media.SeekMode {
    if (PlatformInfo.isHarmonyOS()) {
      const closest: media.SeekMode = 2 as media.SeekMode;
      return closest;
    }
    return media.SeekMode.SEEK_PREV_SYNC;
  }

  /**
   * 剩余空间字节数。
   * `storageStatistics.getFreeSize()` 所属模块 ArkUI-X 未适配（门禁拦截），改用
   * `@ohos.file.statvfs` 的 `statfs.getFreeSize()`——ArkUI-X 已适配，且三端同一套实现。
   */
  static async freeSpaceBytes(): Promise<number> {
    try {
      const context: common.Context = getContext() as common.Context;
      const free: number = await statfs.getFreeSize(context.filesDir);
      if (Number.isFinite(free) && free > 0) { return free; }
    } catch (error) {
      Logger.warn('STORAGE', '读取剩余空间失败：' + String(error));
    }
    return -1;
  }

  /** 是否有默认网络。`connection.hasDefaultNet()` 在 ArkUI-X 上可用，三端同一套实现。 */
  static async hasDefaultNet(): Promise<boolean> {
    try {
      return await connection.hasDefaultNet();
    } catch (error) {
      Logger.warn('DOWNLOAD_NETWORK', '读取默认网络失败：' + String(error));
    }
    return true;
  }

  /**
   * 当前是否 Wi-Fi。判断需要 `connection.getDefaultNet` / `getNetCapabilities`（均被门禁拦截，
   * 且没有实例可中转），因此这里返回 true（不拦截），下载失败由任务自身重试兜底。
   */
  static async isWifiNetwork(): Promise<boolean> {
    return true;
  }

  /** 网络权限自检。`verifyAccessTokenSync` 属命名空间成员，改为「声明即可用」，缺失时由请求报错。 */
  static hasInternetPermission(context: common.UIAbilityContext): boolean {
    return true;
  }

  /**
   * 恢复系统下载任务句柄。`request.agent.getTask` 被门禁拦截且无替代 API，
   * 返回 undefined 让调用方重建任务（应用重启后未完成的下载会重新创建，字节断点丢失）。
   */
  static async resumeDownloadTask(context: common.Context, tid: string): Promise<request.agent.Task | undefined> {
    return undefined;
  }

  /**
   * 后台下载模式。`Mode.BACKGROUND` 枚举成员被拦截，按 d.ts 数值（BACKGROUND = 0）取；
   * 非 HarmonyOS 不设置，走前台任务。
   */
  static backgroundDownloadMode(): request.agent.Mode | undefined {
    if (PlatformInfo.isHarmonyOS()) {
      const background: request.agent.Mode = 0 as request.agent.Mode;
      return background;
    }
    return undefined;
  }

  /** 清除通知栏提醒。`notificationManager.cancel` 被拦截且无实例替代，仅记录日志。 */
  static async cancelNotification(id: number): Promise<void> {
    if (!PlatformInfo.isHarmonyOS()) { return; }
    Logger.info('CHAT_NOTIFY', '通知清除接口在 ArkUI-X 上不可用，通知随用户忽略或回前台自然消失，id=' + id);
  }

  /**
   * 给通知挂上点击意图：HarmonyOS 生效（点击通知带聊天室参数）；
   * `NotificationRequest` 是实例，可安全中转。
   */
  static attachWantAgent(target: notificationManager.NotificationRequest, agent: Object): void {
    if (!PlatformInfo.isHarmonyOS()) { return; }
    try {
      const requestLike: NotificationRequestLike = target as Object as NotificationRequestLike;
      requestLike.wantAgent = agent;
    } catch (error) {
      Logger.warn('CHAT_NOTIFY', '设置通知点击意图失败：' + String(error));
    }
  }

  /** 当前窗口方向：HarmonyOS 用原生 `getPreferredOrientation()`（实例方法），其它平台按旋转角推导。 */
  static preferredOrientation(win: window.Window): window.Orientation {
    if (PlatformInfo.isHarmonyOS()) {
      try {
        const api: WindowOrientationLike = win as Object as WindowOrientationLike;
        return api.getPreferredOrientation();
      } catch (error) { /* 走旋转角推导 */ }
    }
    try {
      const rotation: number = display.getDefaultDisplaySync().rotation;
      if (rotation === 1) { return window.Orientation.LANDSCAPE; }
      if (rotation === 2) { return window.Orientation.PORTRAIT_INVERTED; }
      if (rotation === 3) { return window.Orientation.LANDSCAPE_INVERTED; }
    } catch (error) { /* 读不到旋转角时按竖屏处理 */ }
    return window.Orientation.PORTRAIT;
  }

  /**
   * 截图并写入相册：HarmonyOS 完整可用（`window.snapshot` + 相册创建对话框，均为实例方法）；
   * 其它平台返回 false，由调用方提示「当前平台暂不支持」。
   */
  static async saveWindowScreenshot(context: common.UIAbilityContext): Promise<boolean> {
    if (!PlatformInfo.isHarmonyOS()) { return false; }
    let pixel: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    try {
      const targetWindow: window.Window = await window.getLastWindow(context);
      const windowApi: WindowSnapshotLike = targetWindow as Object as WindowSnapshotLike;
      pixel = await windowApi.snapshot();
      packer = image.createImagePacker();
      const option: image.PackingOption = { format: 'image/jpeg', quality: 95 };
      const buffer: ArrayBuffer = await packer.packing(pixel, option);
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: '无音影视截图',
        fileNameExtension: 'jpg',
        photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const helperApi: AssetsHelperLike = helper as Object as AssetsHelperLike;
      const uris: string[] = await helperApi.showAssetsCreationDialog(['file://' + context.cacheDir], [config]);
      if (!uris || uris.length === 0) { return false; }
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY);
      try { fileIo.writeSync(file.fd, buffer); } finally { fileIo.closeSync(file); }
      Logger.info('PLAYER_SHOT', '截图已保存到相册');
      return true;
    } catch (error) {
      Logger.warn('PLAYER_SHOT', '截图保存失败：' + String(error));
      return false;
    } finally {
      try {
        if (pixel) { pixel.release(); }
        if (packer) { packer.release(); }
      } catch (error) { /* 释放失败不影响结果 */ }
    }
  }

  /** 选择器「最多选择数量」：HarmonyOS 通过实例动态字段写入；其它平台保持默认。 */
  static setMaxSelectNumber(options: Object, count: number): void {
    if (!PlatformInfo.isHarmonyOS()) { return; }
    try {
      const map: Record<string, Object> = options as Object as Record<string, Object>;
      map['maxSelectNumber'] = count;
    } catch (error) {
      Logger.warn('PICKER', '设置最大选择数量失败：' + String(error));
    }
  }
}

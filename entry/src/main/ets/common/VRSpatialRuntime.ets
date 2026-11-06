import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { Scene } from '@kit.ArkGraphics3D';
import { Logger } from './Logger';

// 不猜测 API 26 的 XR / SpatialAudioKit 接口、权限或设备类型名称。
// 未注册经目标 SDK 核验的适配器时，仅保留原视频 Surface 的平直大屏预览。
// 不依赖 OpenXR、Meta、PICO，不创建第二个 AVPlayer。
export enum VRScreenMode { FLAT = 'flat', HALF = 'half', SPHERE = 'sphere' }
export enum VRPlaybackAction {
  TOGGLE = 'toggle', PREVIOUS = 'previous', NEXT = 'next', SEEK = 'seek',
    SPEED = 'speed', VOLUME = 'volume', BRIGHTNESS = 'brightness', EXIT = 'exit'
}
export interface VRVector { x: number; y: number; z: number; }
export interface VRQuaternion { x: number; y: number; z: number; w: number; }
export interface VRPose { position: VRVector; rotation: VRQuaternion; tracked: boolean; }
export interface VRRay { origin: VRVector; direction: VRVector; }
export interface VRScreenTransform { position: VRVector; yaw: number; pitch: number; scale: number; }
export interface VRPlaybackRequest { action: VRPlaybackAction; value: number; }
export interface VRPlaybackState {
  playing: boolean; currentMs: number; durationMs: number; speedIndex: number;
  episodeIndex: number; episodeCount: number; volume: number; locked: boolean;
}
// 原生空间面板由适配器绘制；ArkUI 面板只用于普通设备预览，不能当作眼镜内的空间 UI。
export interface VRPanelState { visible: boolean; focused: boolean; brightness: number; }
export interface VRCapabilities {
  xr: boolean; videoTexture: boolean; spatialAudio: boolean; controllers: boolean;
  // 仅允许 SDK 实际声明且已在 module.json5 配置的权限，普通预览为空。
  permissions: Permissions[]; description: string;
}
export interface VRMesh {
  positions: number[]; normals: number[]; texcoords: number[]; indices: number[];
  doubleSided: boolean;
}
export interface VRInput {
  head: VRPose; eye: VRPose; ray?: VRRay;
  // 弧幕和球面精确拾取由原生场景负责，不冒用平面命中结果。
  screenHit?: boolean;
  select: boolean; menu: boolean; dragging: boolean;
  translation: VRVector; scaleDelta: number;
  // 真实空间面板的点击经此入口回到 PlayerPage，禁止在适配器中另行控制播放器或另发协播载荷。
  request?: VRPlaybackRequest;
}
export interface VRNativeStartOptions {
  player: media.AVPlayer; originalSurfaceId: string; mesh: VRMesh;
  transform: VRScreenTransform;
}
export interface VRNativeResources { scene: Scene; }

/**
* 真实设备适配契约，不是 XR Interaction Kit / SpatialAudioKit 的仿造实现。
* 实现者必须直接使用目标 API 26 SDK，并通过实际能力查询后才注册。
* start 事务性创建本机 XR 会话、眼/头跟踪及当前 AVPlayer 的视频纹理。
* 同一播放器驱动纹理的暂停、倍速和进度；不得另建 AVPlayer 或通过截图复制帧。
* attachSpatialAudio 绑定同一音轨到屏幕位置；update 随屏幕移动更新声源位置。
* update 的 panel 参数用于真正的空间迷你面板和视频材质亮度，禁止叠加第二条音轨。
* stop 先归还 originalSurfaceId 并恢复普通立体声，再销毁跟踪、会话、材质、纹理和场景。
* 不得 reset/release AVPlayer；部分启动失败时 stop 仍须可调用、可重试且幂等。
* 球幕以观看原点为球心；屏幕 transform 的平移不能直接把观众移出全景球。
*/
export interface VRNativeAdapter {
  capabilities(): Promise<VRCapabilities>;
  start(options: VRNativeStartOptions): Promise<VRNativeResources>;
  attachSpatialAudio(position: VRVector): Promise<void>;
  update(state: VRPlaybackState, transform: VRScreenTransform, panel?: VRPanelState): Promise<void>;
  setMesh(mesh: VRMesh, mode: VRScreenMode): Promise<void>;
  readInput(): Promise<VRInput | undefined>;
  stop(): Promise<void>;
}
export interface VRRuntimeOptions {
  context: common.UIAbilityContext; player: media.AVPlayer; surfaceId: string;
  aspect?: number; adapter?: VRNativeAdapter;
}
export interface VRRuntimeResult { native: boolean; scene?: Scene; message: string; }

export function vrDefaultTransform(): VRScreenTransform {
  const position: VRVector = { x: 0, y: 0, z: -4 };
  const transform: VRScreenTransform = { position: position, yaw: 0, pitch: 0, scale: 1 };
  return transform;
}
export function vrClamp(value: number, low: number, high: number): number {
  return Number.isFinite(value) ? Math.max(low, Math.min(high, value)) : low;
}
export function vrCopyTransform(value: VRScreenTransform): VRScreenTransform {
  const position: VRVector = { x: value.position.x, y: value.position.y, z: value.position.z };
  const result: VRScreenTransform = { position: position, yaw: value.yaw, pitch: value.pitch, scale: value.scale };
  return result;
}

/** UV 连续；球面需要等距柱状全景输入，普通影片不会自动转换为全景。 */
export function vrCreateMesh(mode: VRScreenMode, aspect: number = 16 / 9): VRMesh {
  const mesh: VRMesh = { positions: [], normals: [], texcoords: [], indices: [], doubleSided: true };
  const ratio: number = vrClamp(aspect, 0.25, 4);
  const columns: number = mode === VRScreenMode.FLAT ? 1 : 96;
  const rows: number = mode === VRScreenMode.SPHERE ? 48 : 1;
  for (let row: number = 0; row <= rows; row++) {
    const v: number = row / rows;
    for (let column: number = 0; column <= columns; column++) {
      const u: number = column / columns;
      if (mode === VRScreenMode.FLAT) {
        mesh.positions.push((u - 0.5) * 4, (0.5 - v) * 4 / ratio, 0);
        mesh.normals.push(0, 0, 1);
      } else if (mode === VRScreenMode.HALF) {
        const angle: number = (u - 0.5) * Math.PI;
        mesh.positions.push(Math.sin(angle) * 2, (0.5 - v) * 4 / ratio, 2 - Math.cos(angle) * 2);
        mesh.normals.push(-Math.sin(angle), 0, Math.cos(angle));
      } else {
        const longitude: number = (u - 0.5) * Math.PI * 2;
        const latitude: number = (0.5 - v) * Math.PI;
        const x: number = Math.sin(longitude) * Math.cos(latitude);
        const y: number = Math.sin(latitude);
        const z: number = -Math.cos(longitude) * Math.cos(latitude);
        mesh.positions.push(x * 8, y * 8, z * 8);
        mesh.normals.push(-x, -y, -z);
      }
      mesh.texcoords.push(u, v);
    }
  }
  for (let row: number = 0; row < rows; row++) {
    for (let column: number = 0; column < columns; column++) {
      const a: number = row * (columns + 1) + column;
      const b: number = a + columns + 1;
      mesh.indices.push(a, b, a + 1, a + 1, b, b + 1);
    }
  }
  return mesh;
}

/** 平直幕射线命中：归一化、逆旋转、正向距离检查。 */
export function vrHitFlat(ray: VRRay, screen: VRScreenTransform, aspect: number): boolean {
  const length: number = Math.sqrt(ray.direction.x * ray.direction.x + ray.direction.y * ray.direction.y + ray.direction.z * ray.direction.z);
  if (!Number.isFinite(length) || length < 0.00001 || !Number.isFinite(screen.scale) || screen.scale <= 0) { return false; }
  const yaw: number = -screen.yaw * Math.PI / 180;
  const pitch: number = -screen.pitch * Math.PI / 180;
  const origin: VRVector = {
    x: ray.origin.x - screen.position.x,
      y: ray.origin.y - screen.position.y,
      z: ray.origin.z - screen.position.z
  };
  const direction: VRVector = { x: ray.direction.x / length, y: ray.direction.y / length, z: ray.direction.z / length };
  const ox: number = origin.x * Math.cos(yaw) + origin.z * Math.sin(yaw);
  const oz: number = -origin.x * Math.sin(yaw) + origin.z * Math.cos(yaw);
  const oy: number = origin.y * Math.cos(pitch) - oz * Math.sin(pitch);
  const localOz: number = origin.y * Math.sin(pitch) + oz * Math.cos(pitch);
  const dx: number = direction.x * Math.cos(yaw) + direction.z * Math.sin(yaw);
  const dz: number = -direction.x * Math.sin(yaw) + direction.z * Math.cos(yaw);
  const dy: number = direction.y * Math.cos(pitch) - dz * Math.sin(pitch);
  const localDz: number = direction.y * Math.sin(pitch) + dz * Math.cos(pitch);
  if (Math.abs(localDz) < 0.00001) { return false; }
  const distance: number = -localOz / localDz;
  if (distance <= 0 || !Number.isFinite(distance)) { return false; }
  return Math.abs(ox + dx * distance) <= 2 * screen.scale &&
    Math.abs(oy + dy * distance) <= 2 * screen.scale / vrClamp(aspect, 0.25, 4);
}

/** 串行生命周期；退出使迟到的启动失效，释放失败必须传递给页面而不是伪装恢复成功。 */
export class VRSpatialRuntime {
  // 应用可在初始化时注册经过 SDK 和设备核验的工厂；工厂注册本身不代表设备具备 XR 能力。
  // 当前工程没有真实 Kit 适配实现，默认不注册，所有设备均明确显示平直大屏预览。
  private static adapterFactory?: () => VRNativeAdapter;
  static registerDeviceAdapter(factory: () => VRNativeAdapter): void {
    VRSpatialRuntime.adapterFactory = factory;
  }
  static createDeviceAdapter(): VRNativeAdapter | undefined {
    try { return VRSpatialRuntime.adapterFactory ? VRSpatialRuntime.adapterFactory() : undefined; }
    catch (error) { Logger.error('VR_PLAYER', '创建设备适配器失败：' + String(error)); return undefined; }
  }

  private adapter?: VRNativeAdapter;
  private native: boolean = false;
  private revision: number = 0;
  private queue: Promise<void> = Promise.resolve();
  private polling: boolean = false;
  private updatePending: boolean = false;

  async enter(options: VRRuntimeOptions, transform: VRScreenTransform): Promise<VRRuntimeResult> {
    const revision: number = ++this.revision;
    const initialTransform: VRScreenTransform = vrCopyTransform(transform);
    const adapter: VRNativeAdapter | undefined = options.adapter || VRSpatialRuntime.createDeviceAdapter();
    let result: VRRuntimeResult = { native: false, message: '平直大屏预览 · 普通立体声 · 未接入真实 XR' };
    const task: Promise<void> = this.queue.then(async (): Promise<void> => {
      // 旧资源未释放时不能继续创建，也不能宣称已降级成功。
      await this.releaseAdapter();
      if (revision !== this.revision || !adapter) { return; }
      try {
        if (!options.surfaceId || (options.player.state !== 'prepared' && options.player.state !== 'playing' &&
          options.player.state !== 'paused' && options.player.state !== 'completed')) {
          result.message = '原播放器尚未就绪，暂不创建 XR 资源'; return;
        }
        const capabilities: VRCapabilities = await adapter.capabilities();
        if (revision !== this.revision) { return; }
        if (!capabilities.xr || !capabilities.videoTexture || !capabilities.spatialAudio) {
          result.message = '设备的 XR 视频纹理或空间音频不可用，已使用平直幕预览';
          return;
        }
        if (capabilities.permissions.length > 0) {
          const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
          const granted: abilityAccessCtrl.PermissionRequestResult = await manager.requestPermissionsFromUser(options.context, capabilities.permissions);
          if (granted.authResults.length !== capabilities.permissions.length ||
            granted.authResults.some((code: number): boolean => code !== 0)) {
            result.message = 'XR 权限未授予，已使用平直幕预览'; return;
          }
        }
        if (revision !== this.revision) { return; }
        this.adapter = adapter;
        const start: VRNativeStartOptions = {
          player: options.player, originalSurfaceId: options.surfaceId,
            mesh: vrCreateMesh(VRScreenMode.FLAT, options.aspect), transform: initialTransform
        };
        const resources: VRNativeResources = await adapter.start(start);
        if (revision !== this.revision) { await this.releaseAdapter(); return; }
        await adapter.attachSpatialAudio(initialTransform.position);
        if (revision !== this.revision) { await this.releaseAdapter(); return; }
        this.native = true;
        result = { native: true, scene: resources.scene, message: '本机 XR 空间大屏' };
        Logger.info('VR_PLAYER', 'XR 会话、视频纹理与屏幕空间音源已由设备适配器创建');
      } catch (error) {
        Logger.error('VR_PLAYER', '进入 XR 失败：' + String(error));
        await this.releaseAdapter();
        result = { native: false, message: 'XR 初始化失败，已恢复原视频 Surface 与普通立体声' };
      }
    });
    this.queue = task.catch((error: Error): void => { Logger.error('VR_PLAYER', '空间启动队列失败：' + String(error)); });
    await task;
    return result;
  }

  async setMode(mode: VRScreenMode, aspect: number): Promise<boolean> {
    const revision: number = this.revision;
    let changed: boolean = false;
    const task: Promise<void> = this.queue.then(async (): Promise<void> => {
      try {
        if (!this.native || !this.adapter || revision !== this.revision) { return; }
        await this.adapter.setMesh(vrCreateMesh(mode, aspect), mode);
        changed = revision === this.revision;
      } catch (error) { Logger.error('VR_PLAYER', '切换空间幕面失败：' + String(error)); }
    });
    this.queue = task.catch((error: Error): void => { Logger.error('VR_PLAYER', '幕面队列失败：' + String(error)); });
    await task;
    return changed;
  }

  async update(state: VRPlaybackState, transform: VRScreenTransform, panel?: VRPanelState): Promise<void> {
    try {
      if (!this.native || !this.adapter || this.updatePending) { return; }
      this.updatePending = true;
      const revision: number = this.revision;
      const snapshot: VRPlaybackState = {
        playing: state.playing, currentMs: state.currentMs, durationMs: state.durationMs, speedIndex: state.speedIndex,
          episodeIndex: state.episodeIndex, episodeCount: state.episodeCount, volume: state.volume, locked: state.locked
      };
      const screen: VRScreenTransform = vrCopyTransform(transform);
      const panelSnapshot: VRPanelState | undefined = panel ? {
        visible: panel.visible, focused: panel.focused, brightness: panel.brightness
      } : undefined;
      const task: Promise<void> = this.queue.then(async (): Promise<void> => {
        if (revision === this.revision && this.native && this.adapter) { await this.adapter.update(snapshot, screen, panelSnapshot); }
      });
      this.queue = task.catch((error: Error): void => { Logger.error('VR_PLAYER', '同步播放与空间音源失败：' + String(error)); });
      await task;
    } catch (error) { Logger.error('VR_PLAYER', '更新空间状态失败：' + String(error)); }
    finally { this.updatePending = false; }
  }

  async input(): Promise<VRInput | undefined> {
    try {
      if (!this.native || !this.adapter || this.polling) { return undefined; }
      this.polling = true;
      const revision: number = this.revision;
      let result: VRInput | undefined;
      const task: Promise<void> = this.queue.then(async (): Promise<void> => {
        if (revision === this.revision && this.native && this.adapter) { result = await this.adapter.readInput(); }
      });
      this.queue = task.catch((error: Error): void => { Logger.error('VR_PLAYER', '读取头眼跟踪与手柄失败：' + String(error)); });
      await task;
      return revision === this.revision ? result : undefined;
    } catch (error) { Logger.error('VR_PLAYER', '处理空间输入失败：' + String(error)); return undefined; }
    finally { this.polling = false; }
  }

  private async releaseAdapter(): Promise<void> {
    const adapter: VRNativeAdapter | undefined = this.adapter;
    this.adapter = undefined;
    this.native = false;
    if (!adapter) { return; }
    try { await adapter.stop(); }
    catch (error) {
      Logger.error('VR_PLAYER', '释放 XR 资源或归还 Surface 失败：' + String(error));
      this.adapter = adapter;
      throw new Error('XR 资源释放失败，不能再次进入空间模式');
    }
  }

  async exit(): Promise<void> {
    ++this.revision;
    const task: Promise<void> = this.queue.then(async (): Promise<void> => { await this.releaseAdapter(); });
    this.queue = task.catch((error: Error): void => { Logger.error('VR_PLAYER', '退出空间模式失败：' + String(error)); });
    await task;
  }
}

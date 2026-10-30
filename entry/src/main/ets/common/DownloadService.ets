import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { connection, http } from '@kit.NetworkKit';
import { fileIo, picker, storageStatistics } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppState } from './AppState';
import { Logger } from './Logger';
import { PlatformApi } from './compat/PlatformApi';

export enum DownloadState {
  SNIFFING = 'sniffing',
    QUEUED = 'queued',
    RUNNING = 'running',
    PAUSED = 'paused',
    COMPLETED = 'completed',
    FAILED = 'failed'
}

export class DownloadOptions {
  wifiOnly: boolean = true;
  parallelLimit: number = 2;
  retryAutomatic: boolean = true;
  allowMetered: boolean = false;
  allowRoaming: boolean = false;
}

export class DownloadAsset {
  sourceUrl: string = '';
  localPath: string = '';
  receivedBytes: number = 0;
  totalBytes: number = 0;
  completed: boolean = false;
}

export class DownloadRecord {
  id: string = '';
  systemId: string = '';
  videoId: string = '';
  name: string = '';
  episodeTitle: string = '';
  episodeIndex: number = 1;
  sourceUrl: string = '';
  resolvedUrl: string = '';
  cover: string = '';
  localPath: string = '';
  receivedBytes: number = 0;
  totalBytes: number = 0;
  speedBytes: number = 0;
  sniffProgress: number = 0;
  progressPercent: number = 0;
  state: DownloadState = DownloadState.PAUSED;
  updatedAt: number = 0;
  message: string = '';
  mediaKind: string = 'file';
  manifest: string = '';
  assets: DownloadAsset[] = [];
  assetIndex: number = 0;
  nativeStarted: boolean = false;
}

interface DownloadArchive { format: string; version: number; tasks: DownloadRecord[]; }
class SniffResponse {
  address: string = '';
  text: string = '';
  mime: string = '';
  size: number = 0;
  partial: boolean = false;
}
class SpeedSample { time: number = 0; bytes: number = 0; lastProgress: number = 0; }

// 所有页面只观察 downloadVersion，控制、嗅探、持久化和后台传输均使用同一任务源。
export class DownloadService {
  static readonly ARCHIVE_NAME: string = '无音影视下载任务.json';
  static options: DownloadOptions = new DownloadOptions();
  private static records: DownloadRecord[] = [];
  private static tasks: Map<string, request.agent.Task> = new Map();
  private static probes: Map<string, http.HttpRequest> = new Map();
  private static generations: Map<string, number> = new Map();
  private static probeCounts: Map<string, number> = new Map();
  private static samples: Map<string, SpeedSample> = new Map();
  // 原生 start/resume/pause/remove 串行执行，防止快速跨页面操作产生迟到的启动。
  private static nativeCommands: Map<string, Promise<void>> = new Map();
  private static store?: preferences.Preferences;
  private static host?: common.UIAbilityContext;
  private static initialization?: Promise<void>;
  private static netObserver?: connection.NetConnection;
  private static creating: Set<string> = new Set();
  private static persistence: Promise<void> = Promise.resolve();
  private static saveTimer: number = -1;
  private static refreshTimer: number = -1;
  private static pumping: boolean = false;
  private static networkReady: boolean = true;

  static init(context?: common.UIAbilityContext): Promise<void> {
    if (DownloadService.initialization) { return DownloadService.initialization; }
    const host: common.UIAbilityContext | undefined = context || AppState.context;
    if (!host) { return Promise.reject(new Error('下载服务尚未取得应用上下文')); }
    DownloadService.host = host;
    DownloadService.initialization = DownloadService.load(host).catch((error: Error) => {
      DownloadService.initialization = undefined;
      Logger.error('DOWNLOAD_INIT', String(error));
      throw new Error(error.message || '初始化下载服务失败');
    });
    return DownloadService.initialization;
  }

  private static async load(context: common.UIAbilityContext): Promise<void> {
    try {
      DownloadService.store = await preferences.getPreferences(context, 'wuyin_downloads');
      try {
        const saved = JSON.parse(String(await DownloadService.store.get('options', '{}'))) as DownloadOptions;
        DownloadService.options = DownloadService.validOptions(saved);
      } catch (error) { Logger.warn('DOWNLOAD_CONFIG', '使用默认下载规则：' + String(error)); }
      try {
        const saved = JSON.parse(String(await DownloadService.store.get('tasks', '[]'))) as DownloadRecord[];
        DownloadService.records = DownloadService.validateRecords(saved);
      } catch (error) { Logger.error('DOWNLOAD_LOAD', '读取下载记录失败：' + String(error)); }
      for (const record of DownloadService.records) {
        record.speedBytes = 0;
        if (record.state === DownloadState.SNIFFING) { record.state = DownloadState.QUEUED; record.message = '等待重新解析视频地址'; }
        if (record.state === DownloadState.COMPLETED) {
          if (!DownloadService.hasLocalFile(record)) { record.state = DownloadState.FAILED; record.message = '本地文件或分片已丢失，请重试'; }
          continue;
        }
        if (!record.systemId) { if (record.state === DownloadState.RUNNING) { record.state = DownloadState.QUEUED; } continue; }
        try {
          const info: request.agent.TaskInfo = await request.agent.show(record.systemId);
          if (info.progress.state === request.agent.State.COMPLETED) {
            await DownloadService.completeCurrent(record);
          } else if (info.progress.state === request.agent.State.FAILED) {
            record.state = DownloadState.FAILED; record.message = '系统下载失败，可重试';
          } else {
            const resumed: request.agent.Task | undefined = await PlatformApi.resumeDownloadTask(context, record.systemId);
            if (resumed === undefined) {
              record.systemId = ''; record.nativeStarted = false;
            } else {
              DownloadService.bind(record, resumed);
              if (info.progress.state === request.agent.State.RUNNING) { await resumed.pause(); record.nativeStarted = true; }
            }
            if (record.state === DownloadState.RUNNING || record.state === DownloadState.QUEUED) { record.state = DownloadState.QUEUED; }
          }
        } catch (error) {
          record.systemId = ''; record.nativeStarted = false;
          DownloadService.tasks.delete(record.id);
          if (!DownloadService.isCompleted(record)) { record.state = DownloadState.PAUSED; record.message = '原系统任务已失效，点击继续重新下载'; }
          Logger.warn('DOWNLOAD_RECOVER', '恢复任务失败，保留已下载分片：' + record.id);
        }
      }
      await DownloadService.listenNetwork();
      DownloadService.startRefreshTimer();
      DownloadService.publish();
      await DownloadService.save();
      void DownloadService.pump();
      Logger.info('DOWNLOAD_INIT', '恢复下载任务，数量=' + DownloadService.records.length);
    } catch (error) { Logger.error('DOWNLOAD_INIT', String(error)); throw new Error(String(error)); }
  }

  // 异步操作及系统回调可能更新状态，重新读取完整枚举，避免沿用 await 前的类型窄化。
  private static isCompleted(record: DownloadRecord): boolean {
    return record.state === DownloadState.COMPLETED;
  }

  private static copy(record: DownloadRecord): DownloadRecord {
    const result = new DownloadRecord();
    result.id = record.id; result.systemId = record.systemId; result.videoId = record.videoId;
    result.name = record.name; result.episodeTitle = record.episodeTitle; result.episodeIndex = record.episodeIndex;
    result.sourceUrl = record.sourceUrl; result.resolvedUrl = record.resolvedUrl; result.cover = record.cover;
    result.localPath = record.localPath; result.receivedBytes = record.receivedBytes; result.totalBytes = record.totalBytes;
    result.speedBytes = record.speedBytes; result.sniffProgress = record.sniffProgress; result.progressPercent = record.progressPercent;
    result.state = record.state; result.updatedAt = record.updatedAt; result.message = record.message;
    result.mediaKind = record.mediaKind; result.manifest = record.manifest; result.assetIndex = record.assetIndex; result.nativeStarted = record.nativeStarted;
    result.assets = record.assets.map((asset: DownloadAsset): DownloadAsset => {
      const item = new DownloadAsset(); item.sourceUrl = asset.sourceUrl; item.localPath = asset.localPath;
      item.receivedBytes = asset.receivedBytes; item.totalBytes = asset.totalBytes; item.completed = asset.completed; return item;
    });
    return result;
  }

  static snapshot(): DownloadRecord[] {
    return DownloadService.records.map((record: DownloadRecord): DownloadRecord => DownloadService.copy(record))
      .sort((left: DownloadRecord, right: DownloadRecord) => right.updatedAt - left.updatedAt);
  }

  private static validOptions(value: DownloadOptions): DownloadOptions {
    const result = new DownloadOptions();
    if (!value) { return result; }
    if (typeof value.wifiOnly === 'boolean') { result.wifiOnly = value.wifiOnly; }
    if (typeof value.retryAutomatic === 'boolean') { result.retryAutomatic = value.retryAutomatic; }
    if (typeof value.allowMetered === 'boolean') { result.allowMetered = value.allowMetered; }
    if (typeof value.allowRoaming === 'boolean') { result.allowRoaming = value.allowRoaming; }
    if (Number.isFinite(value.parallelLimit)) { result.parallelLimit = Math.max(1, Math.min(5, Math.floor(value.parallelLimit))); }
    return result;
  }

  static async updateOptions(value: DownloadOptions): Promise<void> {
    await DownloadService.init(); DownloadService.options = DownloadService.validOptions(value);
    // 原生任务配置不可变，保留原任务断点；后续新任务使用新网络规则。
    await DownloadService.save(); DownloadService.publish(); void DownloadService.pump();
    Logger.info('DOWNLOAD_CONFIG', '保存下载网络与并发配置');
  }

  private static publish(): void {
    AppStorage.setOrCreate('downloadOptions', DownloadService.options);
    AppStorage.setOrCreate('downloadVersion', (AppStorage.get<number>('downloadVersion') || 0) + 1);
  }

  private static save(): Promise<void> {
    const taskText: string = JSON.stringify(DownloadService.records);
    const optionText: string = JSON.stringify(DownloadService.options);
    DownloadService.persistence = DownloadService.persistence.then(async () => {
      try {
        const store = DownloadService.store; if (!store) { return; }
        await store.put('tasks', taskText); await store.put('options', optionText); await store.flush();
      } catch (error) { Logger.error('DOWNLOAD_SAVE', String(error)); }
    });
    return DownloadService.persistence;
  }

  private static changed(immediate: boolean = true): void {
    DownloadService.publish();
    if (immediate) { void DownloadService.save(); return; }
    if (DownloadService.saveTimer !== -1) { return; }
    DownloadService.saveTimer = setTimeout(() => { DownloadService.saveTimer = -1; void DownloadService.save(); }, 1000);
  }

  private static startRefreshTimer(): void {
    if (DownloadService.refreshTimer !== -1) { return; }
    DownloadService.refreshTimer = setInterval(() => {
      let active: boolean = false;
      for (const record of DownloadService.records) {
        if (record.state === DownloadState.RUNNING) {
          active = true;
          const sample = DownloadService.samples.get(record.id);
          if (!sample || Date.now() - sample.lastProgress > 3000) { record.speedBytes = 0; }
        }
      }
      if (active) { DownloadService.publish(); }
      if (DownloadService.records.some((record: DownloadRecord) => record.state === DownloadState.QUEUED)) { void DownloadService.pump(); }
    }, 1000);
  }

  private static async listenNetwork(): Promise<void> {
    if (DownloadService.netObserver) { return; }
    try {
      const observer = connection.createNetConnection();
      observer.on('netAvailable', () => { DownloadService.networkReady = true; Logger.info('DOWNLOAD_NETWORK', '网络恢复'); void DownloadService.pump(); });
      observer.on('netLost', () => {
        DownloadService.networkReady = false;
        for (const record of DownloadService.records) { record.speedBytes = 0; }
        Logger.warn('DOWNLOAD_NETWORK', '网络断开，保留下载断点'); DownloadService.publish();
      });
      observer.on('netCapabilitiesChange', () => { void DownloadService.pump(); });
      await new Promise<void>((resolve, reject) => {
        observer.register((error: BusinessError) => {
          if (error) { reject(new Error('注册网络监听失败：' + error.code)); return; }
          resolve();
        });
      });
      DownloadService.netObserver = observer;
      DownloadService.networkReady = await PlatformApi.hasDefaultNet();
    } catch (error) { Logger.warn('DOWNLOAD_NETWORK', '网络监听不可用，由系统任务继续执行网络约束：' + String(error)); }
  }

  private static async permittedNetwork(): Promise<boolean> {
    try {
      DownloadService.networkReady = await PlatformApi.hasDefaultNet();
      if (!DownloadService.networkReady) { return false; }
      if (!DownloadService.options.wifiOnly) { return true; }
      return await PlatformApi.isWifiNetwork();
    } catch (error) { DownloadService.networkReady = false; return false; }
  }

  private static async pump(): Promise<void> {
    if (DownloadService.pumping || !DownloadService.host) { return; }
    DownloadService.pumping = true;
    try {
      const allowed: boolean = await DownloadService.permittedNetwork();
      let slots: number = DownloadService.options.parallelLimit - DownloadService.records.filter((item: DownloadRecord) => item.state === DownloadState.RUNNING || item.state === DownloadState.SNIFFING).length;
      for (const record of DownloadService.records) {
        if (record.state !== DownloadState.QUEUED || DownloadService.creating.has(record.id)) { continue; }
        if (!allowed) { record.message = DownloadService.networkReady ? '等待 Wi-Fi，可在下载设置调整网络规则' : '等待网络恢复'; continue; }
        if (slots <= 0) { record.message = '等待空闲下载名额'; continue; }
        record.state = record.resolvedUrl ? DownloadState.RUNNING : DownloadState.SNIFFING;
        record.message = record.resolvedUrl ? '正在启动下载' : '正在嗅探真实视频地址';
        DownloadService.creating.add(record.id); slots--;
        const generation: number = (DownloadService.generations.get(record.id) || 0) + 1;
        DownloadService.generations.set(record.id, generation);
        void DownloadService.start(record, generation).finally(() => { DownloadService.creating.delete(record.id); void DownloadService.pump(); });
      }
      DownloadService.changed(false);
    } catch (error) { Logger.error('DOWNLOAD_QUEUE', String(error)); }
    finally { DownloadService.pumping = false; }
  }

  private static current(record: DownloadRecord, generation: number): boolean {
    return DownloadService.records.includes(record) && DownloadService.generations.get(record.id) === generation &&
      (record.state === DownloadState.SNIFFING || record.state === DownloadState.RUNNING);
  }

  private static checkCurrent(record: DownloadRecord, generation: number): void {
    if (!DownloadService.current(record, generation)) { throw new Error('任务已暂停或移除'); }
  }

  private static nativeCommand(id: string, operation: () => Promise<void>): Promise<void> {
    const previous: Promise<void> = DownloadService.nativeCommands.get(id) || Promise.resolve();
    const command: Promise<void> = previous.then(operation);
    // 保存吸收异常的尾节点，调用者仍收到原始 command 的失败结果。
    const tail: Promise<void> = command.catch((error: Error) => {
      Logger.debug('DOWNLOAD_COMMAND', '原生操作结束并捕获异常：' + id + '，' + String(error));
    });
    DownloadService.nativeCommands.set(id, tail);
    void tail.then(() => {
      if (DownloadService.nativeCommands.get(id) === tail) { DownloadService.nativeCommands.delete(id); }
    });
    return command;
  }

  private static checkPermission(): void {
    const host = DownloadService.host;
    if (!host) { throw new Error('下载目录不可用'); }
    if (!canIUse('SystemCapability.Request.FileTransferAgent')) { throw new Error('当前设备不支持系统后台下载'); }
    if (!PlatformApi.hasInternetPermission(host)) { throw new Error('应用缺少网络权限，无法嗅探或下载'); }
    // 视频写入应用私有目录，不索取相册或外部存储权限；导入导出由系统 Picker 授权。
  }

  private static async checkStorage(record: DownloadRecord): Promise<void> {
    try {
      const free: number = await PlatformApi.freeSpaceBytes();
      if (free >= 0) {
        const reserve: number = 32 * 1024 * 1024;
        const remaining: number = record.totalBytes > 0 ? Math.max(0, record.totalBytes - record.receivedBytes) : 64 * 1024 * 1024;
        if (free < remaining + reserve) { throw new Error('可用存储空间不足，请清理空间后重试'); }
      }
      const directory: string = DownloadService.directory();
      const probePath: string = directory + '/write_check_' + record.id;
      const probe = fileIo.openSync(probePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(probe.fd, new ArrayBuffer(1)); }
      finally { fileIo.closeSync(probe); if (fileIo.accessSync(probePath)) { fileIo.unlinkSync(probePath); } }
      Logger.debug('DOWNLOAD_STORAGE', '存储空间及私有目录写权限校验通过：' + record.id);
    } catch (error) { Logger.error('DOWNLOAD_STORAGE', String(error)); throw new Error('存储校验失败：' + String(error)); }
  }

  private static async start(record: DownloadRecord, generation: number): Promise<void> {
    const host = DownloadService.host; if (!host) { return; }
    DownloadService.probeCounts.set(record.id, 0);
    try {
      DownloadService.checkPermission();
      // 在网络嗅探和清单目录创建之前先做一次保底校验，解析出大小后再校验实际剩余空间。
      await DownloadService.checkStorage(record); DownloadService.checkCurrent(record, generation);
      if (!record.resolvedUrl) {
        record.sniffProgress = 5; DownloadService.changed(false);
        await DownloadService.sniff(record, record.sourceUrl, generation, [], 0);
        DownloadService.checkCurrent(record, generation);
        record.sniffProgress = 100; record.state = DownloadState.RUNNING; record.message = '';
        DownloadService.changed(false);
        Logger.info('DOWNLOAD_SNIFF', '视频地址解析完成：' + record.id + '，类型=' + record.mediaKind);
      }
      await DownloadService.checkStorage(record); DownloadService.checkCurrent(record, generation);
      if (record.mediaKind === 'hls') {
        record.assetIndex = record.assets.findIndex((asset: DownloadAsset) => !asset.completed);
        if (record.assetIndex < 0) { await DownloadService.finishManifest(record); return; }
      }
      let task = DownloadService.tasks.get(record.id);
      if (!task && record.systemId) {
        const resumed: request.agent.Task | undefined = await PlatformApi.resumeDownloadTask(host, record.systemId);
        if (resumed !== undefined) { task = resumed; DownloadService.bind(record, resumed); }
        else { record.systemId = ''; record.nativeStarted = false; Logger.warn('DOWNLOAD_RESUME', '原生任务失效，重建：' + record.id); }
      }
      DownloadService.checkCurrent(record, generation);
      if (!task) {
        const asset: DownloadAsset | undefined = record.mediaKind === 'hls' ? record.assets[record.assetIndex] : undefined;
        // 新建且 overwrite=true 时无法沿用旧原生任务的字节断点，先重置当前文件统计。
        // 已完成的 HLS 分片不受影响，避免重建后进度和速度出现旧字节重复累计。
        if (asset) { asset.receivedBytes = 0; DownloadService.aggregate(record); }
        else { record.receivedBytes = 0; record.progressPercent = 0; }
        record.speedBytes = 0; DownloadService.samples.delete(record.id); DownloadService.changed(false);
        const config: request.agent.Config = {
          action: request.agent.Action.DOWNLOAD,
            url: asset ? asset.sourceUrl : record.resolvedUrl,
            title: record.name + ' ' + record.episodeTitle,
            description: '无音影视下载任务',
            saveas: asset ? asset.localPath : record.localPath,
            overwrite: true,
            network: DownloadService.options.wifiOnly ? request.agent.Network.WIFI : request.agent.Network.ANY,
            metered: DownloadService.options.allowMetered,
            roaming: DownloadService.options.allowRoaming,
            retry: DownloadService.options.retryAutomatic
        };
        const mode: request.agent.Mode | undefined = PlatformApi.backgroundDownloadMode();
        if (mode !== undefined) { config.mode = mode; }
        task = await request.agent.create(host, config);
        if (!DownloadService.records.includes(record)) { await request.agent.remove(task.tid); return; }
        record.systemId = task.tid; record.nativeStarted = false; DownloadService.bind(record, task);
        await DownloadService.save();
      }
      if (!DownloadService.current(record, generation)) { return; }
      const target: request.agent.Task = task;
      await DownloadService.nativeCommand(record.id, async () => {
        DownloadService.checkCurrent(record, generation);
        if (DownloadService.tasks.get(record.id) !== target) { return; }
        const sample = new SpeedSample(); sample.time = Date.now(); sample.lastProgress = sample.time; sample.bytes = record.receivedBytes;
        DownloadService.samples.set(record.id, sample);
        if (record.nativeStarted) { await target.resume(); }
        else { await target.start(); if (DownloadService.tasks.get(record.id) === target) { record.nativeStarted = true; } }
      });
      if (!DownloadService.current(record, generation)) { return; }
      record.message = ''; DownloadService.changed();
      Logger.info('DOWNLOAD_START', '开始或续传任务：' + record.id);
    } catch (error) {
      if (DownloadService.current(record, generation)) {
        record.state = DownloadState.FAILED; record.speedBytes = 0; record.message = String(error);
        Logger.error('DOWNLOAD_START', '嗅探或启动失败：' + record.id + '，' + String(error)); DownloadService.changed();
      } else { Logger.debug('DOWNLOAD_CANCEL', '忽略已暂停或移除任务的异步结果：' + record.id); }
    } finally {
      // 暂停后的旧请求不得清除后续嗅探轮次的预算。
      if (DownloadService.generations.get(record.id) === generation) { DownloadService.probeCounts.delete(record.id); }
    }
  }

  private static bind(record: DownloadRecord, task: request.agent.Task): void {
    if (DownloadService.tasks.get(record.id) === task) { return; }
    DownloadService.tasks.set(record.id, task);
    task.on('progress', (progress: request.agent.Progress) => {
      if (!DownloadService.records.includes(record) || DownloadService.tasks.get(record.id) !== task || record.state === DownloadState.COMPLETED || record.state === DownloadState.FAILED) { return; }
      if (record.mediaKind === 'hls') {
        const asset = record.assets[record.assetIndex];
        if (asset) { asset.receivedBytes = Math.max(0, progress.processed); asset.totalBytes = Math.max(0, progress.sizes.length > 0 ? progress.sizes[0] : 0); }
        DownloadService.aggregate(record);
      } else {
        record.receivedBytes = Math.max(0, progress.processed);
        record.totalBytes = Math.max(0, progress.sizes.length > 0 ? progress.sizes[0] : 0);
        record.progressPercent = record.totalBytes > 0 ? Math.min(99, record.receivedBytes * 100 / record.totalBytes) : 0;
      }
      if (record.state === DownloadState.RUNNING) { DownloadService.updateSpeed(record); }
      else { record.speedBytes = 0; }
      DownloadService.changed(false);
    });
    task.on('completed', () => {
      if (!DownloadService.records.includes(record) || DownloadService.tasks.get(record.id) !== task || record.state === DownloadState.COMPLETED) { return; }
      void DownloadService.completeCurrent(record).catch((error: Error) => {
        // HLS 完成当前分片时会清除原生句柄；清单写入失败也必须进入可重试状态，不能永久卡在下载中。
        const activeTask = DownloadService.tasks.get(record.id);
        if (DownloadService.records.includes(record) && record.state !== DownloadState.COMPLETED && (!activeTask || activeTask === task)) {
          record.state = DownloadState.FAILED; record.speedBytes = 0; record.message = error.message || String(error); DownloadService.changed();
        }
        Logger.error('DOWNLOAD_COMPLETE', String(error));
      }).finally(() => { void DownloadService.pump(); });
    });
    task.on('failed', () => {
      if (!DownloadService.records.includes(record) || DownloadService.tasks.get(record.id) !== task || record.state === DownloadState.PAUSED || record.state === DownloadState.COMPLETED) { return; }
      record.state = DownloadState.FAILED; record.speedBytes = 0;
      record.message = '下载失败，请检查资源、网络和存储空间后重试';
      DownloadService.changed(); Logger.error('DOWNLOAD_FAILED', '下载失败：' + record.id); void DownloadService.pump();
    });
  }

  private static updateSpeed(record: DownloadRecord): void {
    const now: number = Date.now();
    let sample = DownloadService.samples.get(record.id);
    if (!sample) { sample = new SpeedSample(); sample.time = now; sample.bytes = record.receivedBytes; DownloadService.samples.set(record.id, sample); }
    sample.lastProgress = now;
    const elapsed: number = now - sample.time;
    if (elapsed >= 500) {
      record.speedBytes = Math.max(0, Math.floor((record.receivedBytes - sample.bytes) * 1000 / elapsed));
      sample.time = now; sample.bytes = record.receivedBytes;
    }
  }

  private static aggregate(record: DownloadRecord): void {
    record.receivedBytes = record.assets.reduce((sum: number, asset: DownloadAsset) => sum + asset.receivedBytes, 0);
    const allKnown: boolean = record.assets.every((asset: DownloadAsset) => asset.totalBytes > 0);
    record.totalBytes = allKnown ? record.assets.reduce((sum: number, asset: DownloadAsset) => sum + asset.totalBytes, 0) : 0;
    const completed: number = record.assets.filter((asset: DownloadAsset) => asset.completed).length;
    const current = record.assets[record.assetIndex];
    const fraction: number = current && !current.completed && current.totalBytes > 0 ? Math.min(1, current.receivedBytes / current.totalBytes) : 0;
    record.progressPercent = record.assets.length ? Math.min(99, (completed + fraction) * 100 / record.assets.length) : 0;
  }

  private static async completeCurrent(record: DownloadRecord): Promise<void> {
    try {
      if (!DownloadService.records.includes(record)) { return; }
      const paused: boolean = record.state === DownloadState.PAUSED;
      if (record.mediaKind === 'hls') {
        const asset = record.assets[record.assetIndex];
        if (!asset || !fileIo.accessSync(asset.localPath)) { throw new Error('下载分片未落盘，请重试'); }
        const size: number = fileIo.statSync(asset.localPath).size;
        if (size <= 0) { throw new Error('下载分片为空，请重试'); }
        asset.completed = true; asset.receivedBytes = size; asset.totalBytes = size;
        DownloadService.tasks.delete(record.id); record.systemId = ''; record.nativeStarted = false;
        record.assetIndex = record.assets.findIndex((item: DownloadAsset) => !item.completed);
        DownloadService.aggregate(record); record.speedBytes = 0;
        if (record.assetIndex < 0) { await DownloadService.finishManifest(record); }
        else { record.state = paused ? DownloadState.PAUSED : DownloadState.QUEUED; record.message = paused ? '下载已暂停' : ''; DownloadService.changed(); }
      } else {
        if (!DownloadService.hasLocalFile(record)) { throw new Error('本地视频为空或不存在，请重试'); }
        record.receivedBytes = fileIo.statSync(record.localPath).size;
        record.totalBytes = record.receivedBytes; record.progressPercent = 100; record.speedBytes = 0;
        DownloadService.tasks.delete(record.id); DownloadService.samples.delete(record.id);
        record.state = DownloadState.COMPLETED; record.message = ''; record.updatedAt = Date.now(); DownloadService.changed();
        Logger.info('DOWNLOAD_COMPLETE', '视频下载完成：' + record.id);
      }
    } catch (error) { throw new Error(String(error)); }
  }

  private static async finishManifest(record: DownloadRecord): Promise<void> {
    try {
      if (!DownloadService.records.includes(record)) { return; }
      const output = fileIo.openSync(record.localPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { const data = new util.TextEncoder().encodeInto(record.manifest); fileIo.writeSync(output.fd, data.buffer); }
      finally { fileIo.closeSync(output); }
      if (!DownloadService.hasLocalFile(record)) { throw new Error('离线播放清单不完整，请重试'); }
      record.state = DownloadState.COMPLETED; record.progressPercent = 100; record.totalBytes = record.receivedBytes;
      DownloadService.samples.delete(record.id);
      record.speedBytes = 0; record.message = ''; record.updatedAt = Date.now(); DownloadService.changed();
      Logger.info('DOWNLOAD_COMPLETE', 'HLS 视频及分片下载完成：' + record.id);
    } catch (error) { throw new Error(String(error)); }
  }

  private static directory(): string {
    try {
      const host = DownloadService.host; if (!host) { throw new Error('下载目录不可用'); }
      const directory: string = host.filesDir + '/wuyin_media_downloads';
      if (!fileIo.accessSync(directory)) { fileIo.mkdirSync(directory); }
      return directory;
    } catch (error) { Logger.error('DOWNLOAD_DIRECTORY', String(error)); throw new Error(String(error)); }
  }

  private static extension(source: string): string {
    const match = /\.(mp4|mkv|webm|mov|m4v|avi|ts|m3u8|m4s|aac|key|vtt)(?:[?#]|$)/i.exec(source);
    return match ? '.' + match[1].toLowerCase() : '.bin';
  }

  private static path(id: string, source: string): string {
    return DownloadService.directory() + '/' + id + (DownloadService.extension(source) === '.bin' ? '.mp4' : DownloadService.extension(source));
  }

  private static resolveAddress(value: string, base: string): string {
    const target: string = value.trim().replace(/&amp;/g, '&').replace(/\\\//g, '/');
    if (/^https?:\/\//i.test(target)) { return target; }
    const origin = /^(https?):\/\/([^/?#]+)([^?#]*)/i.exec(base);
    if (!origin) { throw new Error('无法解析相对视频地址'); }
    if (target.startsWith('//')) { return origin[1] + ':' + target; }
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) { throw new Error('不支持该视频地址协议'); }
    if (!target || target.startsWith('#')) { return base.split('#')[0] + target; }
    if (target.startsWith('?')) { return origin[1] + '://' + origin[2] + (origin[3] || '/') + target; }
    // 只规范化路径，不拆分查询参数中的 /、.. 或嵌套网址，保留签名参数原文。
    const suffixIndex: number = target.search(/[?#]/);
    const targetPath: string = suffixIndex < 0 ? target : target.substring(0, suffixIndex);
    const suffix: string = suffixIndex < 0 ? '' : target.substring(suffixIndex);
    const basePath: string = origin[3] || '/';
    const relative: string = targetPath.startsWith('/') ? targetPath : basePath.substring(0, basePath.lastIndexOf('/') + 1) + targetPath;
    const parts: string[] = relative.split('/'); const result: string[] = [];
    for (const part of parts) { if (part === '..') { result.pop(); } else if (part !== '.' && part !== '') { result.push(part); } }
    return origin[1] + '://' + origin[2] + '/' + result.join('/') + (targetPath.endsWith('/') && result.length > 0 ? '/' : '') + suffix;
  }

  private static async probe(record: DownloadRecord, address: string, head: boolean, generation: number, redirects: number = 0, rangeProbe: boolean = false): Promise<SniffResponse> {
    DownloadService.checkCurrent(record, generation);
    if (redirects > 5) { throw new Error('视频地址重定向次数过多'); }
    // 除解析深度外限制整轮请求总量，广告/失效候选不能形成指数级嗅探。
    const attempts: number = (DownloadService.probeCounts.get(record.id) || 0) + 1;
    if (attempts > 32) { throw new Error('视频地址嗅探请求过多，请切换线路后重试'); }
    DownloadService.probeCounts.set(record.id, attempts);
    const client = http.createHttp(); DownloadService.probes.set(record.id, client);
    try {
      const requestHeaders: Record<string, string> = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' };
      // HEAD 被禁用或返回泛型 MIME 时仅探测开头，避免把整部视频读进内存。
      if (!head && rangeProbe) { requestHeaders['Range'] = 'bytes=0-1048575'; }
      const response: http.HttpResponse = await client.request(address, {
        method: head ? http.RequestMethod.HEAD : http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 10000, readTimeout: 15000, usingCache: false, maxLimit: 2 * 1024 * 1024,
          header: requestHeaders
      });
      DownloadService.checkCurrent(record, generation);
      const headers = response.header as Record<string, string>;
      const location: string = String(headers['location'] || headers['Location'] || '');
      if (response.responseCode >= 300 && response.responseCode < 400 && location) {
        return await DownloadService.probe(record, DownloadService.resolveAddress(location, address), head, generation, redirects + 1, rangeProbe);
      }
      if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('视频服务器返回 HTTP ' + response.responseCode); }
      const result = new SniffResponse(); result.address = address;
      result.mime = String(headers['content-type'] || headers['Content-Type'] || '').toLowerCase();
      const length: number = Number(headers['content-length'] || headers['Content-Length'] || 0);
      const contentRange: string = String(headers['content-range'] || headers['Content-Range'] || '');
      const rangeTotal = /\/(\d+)\s*$/.exec(contentRange);
      const fullSize: number = rangeTotal ? Number(rangeTotal[1]) : length;
      result.size = Number.isFinite(fullSize) ? Math.max(0, fullSize) : 0;
      result.partial = response.responseCode === 206;
      result.text = typeof response.result === 'string' ? response.result : '';
      return result;
    } catch (error) { throw new Error(String(error)); }
    finally {
      if (DownloadService.probes.get(record.id) === client) { DownloadService.probes.delete(record.id); }
      try { client.destroy(); } catch (error) { Logger.warn('DOWNLOAD_SNIFF', '释放嗅探连接失败：' + record.id); }
    }
  }

  private static async sniff(record: DownloadRecord, address: string, generation: number, visited: string[], depth: number): Promise<void> {
    DownloadService.checkCurrent(record, generation);
    if (depth > 5 || visited.includes(address)) { throw new Error('未找到真实视频地址，解析链过深或循环'); }
    if (!/^https?:\/\//i.test(address)) { throw new Error('当前线路不是可下载的网络资源'); }
    if (/\.mpd(?:[?#]|$)/i.test(address)) { throw new Error('暂不支持 DASH 离线下载，请切换 MP4 或点播 HLS 线路'); }
    visited.push(address); record.sniffProgress = Math.max(record.sniffProgress, Math.min(80, 10 + depth * 12));
    record.message = depth > 0 ? '正在解析第 ' + (depth + 1) + ' 层视频地址' : '正在嗅探真实视频地址';
    DownloadService.changed(false);
    let metadata: SniffResponse | undefined;
    try { metadata = await DownloadService.probe(record, address, true, generation); }
    catch (error) { DownloadService.checkCurrent(record, generation); Logger.debug('DOWNLOAD_SNIFF', 'HEAD 不可用，继续解析：' + record.id); }
    DownloadService.checkCurrent(record, generation);
    // application/octet-stream 也可能是 HLS 清单，不能仅凭泛型 MIME 把清单当 MP4 保存。
    // 返回 HTML/JSON 的伪视频后缀仍须解析，不能保存错误页并误报下载完成。
    if (metadata && (metadata.mime.startsWith('video/') || /\.(mp4|mkv|webm|mov|m4v|avi|ts)(?:[?#]|$)/i.test(metadata.address)) && !/mpegurl|html|dash|json|javascript|text\//.test(metadata.mime) && !/\.m3u8(?:[?#]|$)/i.test(metadata.address)) {
    record.resolvedUrl = metadata.address; record.totalBytes = metadata.size; record.mediaKind = 'file';
    record.assets = []; record.manifest = ''; record.assetIndex = 0;
    record.localPath = DownloadService.path(record.id, metadata.address); return;
  }
  // 明确的视频文件后缀且服务器不支持 HEAD 时，让系统任务校验并下载，避免 GET 把大视频读入嗅探内存。
  if (!metadata && /\.(mp4|mkv|webm|mov|m4v|avi|ts)(?:[?#]|$)/i.test(address)) {
    record.resolvedUrl = address; record.totalBytes = 0; record.mediaKind = 'file';
    record.assets = []; record.manifest = ''; record.assetIndex = 0;
    record.localPath = DownloadService.path(record.id, address); return;
  }
  const rangeOnly: boolean = !metadata || !/mpegurl|html|json|javascript|text\//.test(metadata.mime);
  let response: SniffResponse = await DownloadService.probe(record, metadata ? metadata.address : address, false, generation, 0, rangeOnly);
  DownloadService.checkCurrent(record, generation);
  let text: string = response.text.trim().replace(/^\uFEFF/, '');
  // 范围响应可能截断清单或文本解析页；重新读取完整文本后再判断。
  if (response.partial && ((text.startsWith('#EXTM3U') && !text.includes('#EXT-X-ENDLIST')) || /html|json|javascript|text\//.test(response.mime) || /^[\[{<]/.test(text))) {
  response = await DownloadService.probe(record, response.address, false, generation);
  DownloadService.checkCurrent(record, generation); text = response.text.trim().replace(/^\uFEFF/, '');
}
if (text.startsWith('#EXTM3U')) { await DownloadService.parseManifest(record, response.address, text, generation, visited, depth); return; }
if (/dash\+xml/.test(response.mime) || text.startsWith('<MPD')) { throw new Error('暂不支持 DASH 或受保护视频的离线下载'); }
if ((response.mime.startsWith('video/') || /octet-stream/.test(response.mime)) && !/mpegurl|html|dash|json|javascript|text\//.test(response.mime) && !/^[\[{<]/.test(text) && !/\.m3u8(?:[?#]|$)/i.test(response.address)) {
record.resolvedUrl = response.address; record.totalBytes = response.size; record.mediaKind = 'file';
record.assets = []; record.manifest = ''; record.assetIndex = 0;
record.localPath = DownloadService.path(record.id, response.address); return;
}
const normalized: string = text.replace(/\\\//g, '/').replace(/\\u002f|\\x2f/gi, '/').replace(/\\u003a|\\x3a/gi, ':').replace(/\\u0026|\\x26/gi, '&').replace(/&amp;/g, '&');
const candidates: string[] = [];
const directPattern: RegExp = /https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mp4|mkv|webm|mov|m4v|ts)(?:\?[^\s"'<>\\]*)?/gi;
let direct: RegExpExecArray | null = directPattern.exec(normalized);
while (direct && candidates.length < 16) {
  if (!candidates.includes(direct[0])) { candidates.push(direct[0]); }
  direct = directPattern.exec(normalized);
}
const embeddedPattern: RegExp = /(?:<(?:source|video)[^>]+src\s*=|["'](?:url|src|playUrl|file)["']\s*:|\b(?:url|src|playUrl|file)\s*[:=])\s*["']([^"']+)["']/gi;
let embedded: RegExpExecArray | null = embeddedPattern.exec(normalized);
while (embedded && candidates.length < 16) {
  try { const target: string = DownloadService.resolveAddress(embedded[1], response.address); if (!candidates.includes(target)) { candidates.push(target); } }
  catch (error) { Logger.debug('DOWNLOAD_SNIFF', '跳过非网络媒体地址：' + record.id); }
  embedded = embeddedPattern.exec(normalized);
}
const encoded = /[?&](?:url|playurl|video)=([^&]+)/i.exec(response.address);
if (encoded) {
  try {
    const nested: string = decodeURIComponent(encoded[1]);
    if (/^https?:\/\//i.test(nested) && !candidates.includes(nested)) { candidates.push(nested); }
  } catch (error) { Logger.warn('DOWNLOAD_SNIFF', '解析内嵌地址失败：' + record.id); }
}
const framePattern: RegExp = /<iframe[^>]+src\s*=\s*["']([^"']+)["']/gi;
let frame: RegExpExecArray | null = framePattern.exec(normalized);
while (frame && candidates.length < 16) {
  try { const target: string = DownloadService.resolveAddress(frame[1], response.address); if (!candidates.includes(target)) { candidates.push(target); } }
  catch (error) { Logger.debug('DOWNLOAD_SNIFF', '跳过非网络框架地址：' + record.id); }
  frame = framePattern.exec(normalized);
}
// 页面可能先给广告/失效线路；逐个验证候选地址，不因首个候选失败而放弃真实媒体。
for (const candidate of candidates.slice(0, 16)) {
  DownloadService.checkCurrent(record, generation);
  if ((DownloadService.probeCounts.get(record.id) || 0) >= 32) { throw new Error('视频地址嗅探请求过多，请切换线路后重试'); }
  if (visited.includes(candidate)) { continue; }
  try { await DownloadService.sniff(record, candidate, generation, visited.slice(), depth + 1); return; }
  catch (error) {
    DownloadService.checkCurrent(record, generation);
    Logger.debug('DOWNLOAD_SNIFF', '候选地址解析失败，继续下一线路：' + record.id + '，' + String(error));
  }
}
throw new Error('未嗅探到可下载视频；动态脚本、DRM 或需要登录的线路请切换资源');
}

private static async parseManifest(record: DownloadRecord, address: string, text: string, generation: number, visited: string[], depth: number): Promise<void> {
  const lines: string[] = text.split(/\r?\n/).map((line: string): string => line.trim());
  let variant: string = ''; let bandwidth: number = -1;
  for (let index: number = 0; index < lines.length; index++) {
    if (!lines[index].startsWith('#EXT-X-STREAM-INF:')) { continue; }
    const match = /(?:^|,)BANDWIDTH=(\d+)/.exec(lines[index].substring(lines[index].indexOf(':') + 1));
    const score: number = match ? Number(match[1]) : 0;
    let next: number = index + 1;
    while (next < lines.length && (!lines[next] || lines[next].startsWith('#'))) { next++; }
    if (next < lines.length && score > bandwidth) { bandwidth = score; variant = DownloadService.resolveAddress(lines[next], address); }
  }
  if (variant) {
    if (/#EXT-X-MEDIA:.*TYPE=AUDIO.*URI=/.test(text) || /#EXT-X-MEDIA:.*URI=.*TYPE=AUDIO/.test(text)) { throw new Error('当前 HLS 使用独立音轨，请切换音视频合一的下载线路'); }
    await DownloadService.sniff(record, variant, generation, visited, depth + 1); return;
  }
  if (!text.includes('#EXT-X-ENDLIST')) { throw new Error('当前为直播 HLS，不能作为完整剧集离线下载'); }
  if (/#EXT-X-BYTERANGE:|#EXT-X-MAP:.*BYTERANGE=|#EXT-X-GAP(?:\r?\n|$)/.test(text)) { throw new Error('当前 HLS 使用字节范围或缺失分片，请切换完整分片线路'); }
  if (/#EXT-X-KEY:.*METHOD=(?!NONE(?:,|\s|$)|AES-128(?:,|\s|$))[^,\r\n]+/.test(text)) { throw new Error('当前视频使用受保护加密方式，无法离线下载'); }
  try {
    const assetDirectory: string = DownloadService.directory() + '/' + record.id + '_assets';
    if (!fileIo.accessSync(assetDirectory)) { fileIo.mkdirSync(assetDirectory); }
    const assets: DownloadAsset[] = []; const output: string[] = [];
    for (const original of lines) {
      const line: string = original.trim();
      if (!line) { output.push(''); continue; }
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY:')) {
          const keyFormat = /KEYFORMAT="([^"]+)"/.exec(line);
          if (keyFormat && keyFormat[1] !== 'identity') { throw new Error('当前 HLS 密钥依赖受保护服务，无法离线下载'); }
        }
        const uri = /URI="([^"]+)"/.exec(line);
        if (uri && (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:'))) {
          const relative: string = DownloadService.addAsset(record, assets, DownloadService.resolveAddress(uri[1], address));
          output.push(line.replace(uri[0], 'URI="' + relative + '"'));
        } else if (!line.startsWith('#EXT-X-SESSION-') && !line.startsWith('#EXT-X-I-FRAME-') && !line.startsWith('#EXT-X-RENDITION-REPORT:')) { output.push(line); }
      } else { output.push(DownloadService.addAsset(record, assets, DownloadService.resolveAddress(line, address))); }
    }
    if (!assets.length) { throw new Error('HLS 播放清单没有可下载分片'); }
    DownloadService.checkCurrent(record, generation);
    // 失败重试重新解析签名清单；仅复用地址、路径及实际文件都一致的已完成分片。
    // 清单改变、分片重排或签名变化时保守重下，避免拼接不同版本的剧集。
    for (const asset of assets) {
      const saved = record.assets.find((item: DownloadAsset) => item.completed && item.sourceUrl === asset.sourceUrl && item.localPath === asset.localPath);
      if (saved && fileIo.accessSync(saved.localPath)) {
        const size: number = fileIo.statSync(saved.localPath).size;
        if (size > 0 && size === saved.receivedBytes) { asset.completed = true; asset.receivedBytes = size; asset.totalBytes = size; }
      }
    }
    record.assets = assets; record.assetIndex = assets.findIndex((asset: DownloadAsset) => !asset.completed); record.manifest = output.join('\n');
    record.mediaKind = 'hls'; record.resolvedUrl = address; record.localPath = DownloadService.directory() + '/' + record.id + '.m3u8';
    DownloadService.aggregate(record);
    Logger.info('DOWNLOAD_SNIFF', '生成离线 HLS 分片计划：' + record.id + '，文件数=' + assets.length);
  } catch (error) { throw new Error(String(error)); }
}

private static addAsset(record: DownloadRecord, assets: DownloadAsset[], address: string): string {
  let index: number = assets.findIndex((asset: DownloadAsset) => asset.sourceUrl === address);
  if (index < 0) {
    if (assets.length >= 5000) { throw new Error('HLS 分片数量过多，超过安全限制'); }
    index = assets.length; const asset = new DownloadAsset(); asset.sourceUrl = address;
    asset.localPath = DownloadService.directory() + '/' + record.id + '_assets/part_' + index + DownloadService.extension(address);
    assets.push(asset);
  }
  return record.id + '_assets/part_' + index + DownloadService.extension(address);
}

static async enqueue(videoId: string, name: string, episodeTitle: string, episodeIndex: number, source: string, cover: string): Promise<void> {
  await DownloadService.init(); DownloadService.checkPermission();
  const target: string = source.trim();
  if (!videoId.trim() || !Number.isInteger(episodeIndex) || episodeIndex < 1 || !/^https?:\/\//i.test(target)) { throw new Error('影片、集数或网络线路无效'); }
  const duplicate = DownloadService.records.find((item: DownloadRecord) => item.videoId === videoId && item.episodeIndex === episodeIndex);
  if (duplicate) { throw new Error('本集已在下载列表中，请继续或重试原任务'); }
  const record = new DownloadRecord();
  record.id = 'wuyin_' + Date.now().toString(36) + '_' + Math.floor(Math.random() * 1000000).toString(36);
  record.videoId = videoId; record.name = name; record.episodeTitle = episodeTitle; record.episodeIndex = episodeIndex;
  record.sourceUrl = target; record.cover = cover;
  await DownloadService.checkStorage(record);
  // 空间校验存在 await，重新检查跨页面并发入队，确保同一集只创建一个共享任务。
  if (DownloadService.records.some((item: DownloadRecord) => item.videoId === videoId && item.episodeIndex === episodeIndex)) { throw new Error('本集已在下载列表中，请继续或重试原任务'); }
  record.localPath = DownloadService.path(record.id, target);
  record.updatedAt = Date.now(); record.state = DownloadState.QUEUED; record.message = '正在加入下载队列';
  DownloadService.records.push(record); DownloadService.publish(); await DownloadService.save();
  Logger.info('DOWNLOAD_ENQUEUE', '加入嗅探及下载队列：' + record.id); void DownloadService.pump();
}

private static cancelProbe(id: string): void {
  DownloadService.generations.set(id, (DownloadService.generations.get(id) || 0) + 1);
  DownloadService.probeCounts.delete(id);
  const probe = DownloadService.probes.get(id); DownloadService.probes.delete(id);
  if (probe) { try { probe.destroy(); } catch (error) { Logger.warn('DOWNLOAD_CANCEL', '关闭嗅探请求失败：' + id); } }
}

static async pause(id: string): Promise<void> {
  await DownloadService.init();
  const record = DownloadService.records.find((item: DownloadRecord) => item.id === id);
  if (!record || record.state === DownloadState.COMPLETED || record.state === DownloadState.PAUSED) { return; }
  record.state = DownloadState.PAUSED; record.speedBytes = 0;
  DownloadService.cancelProbe(id); record.message = '下载已暂停'; DownloadService.changed();
  try {
    await DownloadService.nativeCommand(id, async () => {
      const task = DownloadService.tasks.get(id);
      if (task && record.nativeStarted && DownloadService.records.includes(record) && !DownloadService.isCompleted(record)) { await task.pause(); }
    });
    Logger.info('DOWNLOAD_PAUSE', '暂停嗅探或下载：' + id); void DownloadService.pump();
  } catch (error) {
    if (!DownloadService.records.includes(record) || DownloadService.isCompleted(record)) { return; }
    if (record.state === DownloadState.PAUSED) { record.state = DownloadState.FAILED; record.message = '暂停系统任务失败，请重试'; DownloadService.changed(); }
    Logger.error('DOWNLOAD_PAUSE', String(error)); throw new Error(String(error));
  }
}

static async resume(id: string): Promise<void> {
  await DownloadService.init();
  const record = DownloadService.records.find((item: DownloadRecord) => item.id === id);
  if (!record || record.state === DownloadState.COMPLETED || record.state === DownloadState.RUNNING || record.state === DownloadState.SNIFFING || record.state === DownloadState.QUEUED) { return; }
  try {
    DownloadService.checkPermission();
    if (record.state === DownloadState.FAILED) {
      DownloadService.tasks.delete(id);
      await DownloadService.nativeCommand(id, async () => {
        if (record.systemId) { try { await request.agent.remove(record.systemId); } catch (error) { Logger.warn('DOWNLOAD_RETRY', '旧系统任务已失效：' + id); } }
      });
      if (!DownloadService.records.includes(record) || record.state !== DownloadState.FAILED) { return; }
      record.systemId = ''; record.nativeStarted = false;
      if (record.mediaKind === 'hls') {
        for (const asset of record.assets) {
          if (asset.completed && (!fileIo.accessSync(asset.localPath) || fileIo.statSync(asset.localPath).size <= 0)) { asset.completed = false; asset.receivedBytes = 0; asset.totalBytes = 0; }
        }
        DownloadService.aggregate(record);
      } else {
        record.receivedBytes = 0; record.totalBytes = 0; record.progressPercent = 0;
      }
      // HLS 分片同样可能使用过期签名。失败重试从原始线路重新嗅探，暂停续传则保留原断点。
      record.resolvedUrl = ''; record.sniffProgress = 0;
      Logger.info('DOWNLOAD_RETRY', '重新嗅探失败任务的真实地址：' + id);
    }
    if (!DownloadService.records.includes(record)) { return; }
    record.state = DownloadState.QUEUED; record.message = ''; record.speedBytes = 0; record.updatedAt = Date.now();
    DownloadService.changed(); Logger.info('DOWNLOAD_RESUME', '继续或重试：' + id); void DownloadService.pump();
  } catch (error) {
    if (DownloadService.records.includes(record)) { record.state = DownloadState.FAILED; record.speedBytes = 0; record.message = String(error); DownloadService.changed(); }
    Logger.error('DOWNLOAD_RESUME', String(error)); throw new Error(String(error));
  }
}

static async remove(id: string): Promise<void> {
  await DownloadService.init(); const record = DownloadService.records.find((item: DownloadRecord) => item.id === id); if (!record) { return; }
  DownloadService.records = DownloadService.records.filter((item: DownloadRecord) => item.id !== id);
  DownloadService.cancelProbe(id); DownloadService.tasks.delete(id); DownloadService.samples.delete(id); DownloadService.publish();
  try {
    await DownloadService.nativeCommand(id, async () => {
      if (record.systemId) { try { await request.agent.remove(record.systemId); } catch (error) { Logger.warn('DOWNLOAD_DELETE', '系统任务已不存在：' + id); } }
    });
    if (fileIo.accessSync(record.localPath)) { fileIo.unlinkSync(record.localPath); }
    const directory: string = DownloadService.directory() + '/' + record.id + '_assets';
    if (fileIo.accessSync(directory)) { fileIo.rmdirSync(directory); }
    Logger.info('DOWNLOAD_DELETE', '删除任务及本地文件：' + id);
  } catch (error) { Logger.error('DOWNLOAD_DELETE', String(error)); throw new Error(String(error)); }
  finally { DownloadService.changed(); void DownloadService.pump(); }
}

static async pauseAll(): Promise<void> {
  await DownloadService.init();
  const ids: string[] = DownloadService.snapshot().filter((item: DownloadRecord) => item.state === DownloadState.RUNNING || item.state === DownloadState.QUEUED || item.state === DownloadState.SNIFFING).map((item: DownloadRecord) => item.id);
  for (const id of ids) { await DownloadService.pause(id); }
  Logger.info('DOWNLOAD_BATCH', '全部暂停，数量=' + ids.length);
}
static async resumeAll(): Promise<void> {
  await DownloadService.init();
  const ids: string[] = DownloadService.snapshot().filter((item: DownloadRecord) => item.state === DownloadState.PAUSED || item.state === DownloadState.FAILED).map((item: DownloadRecord) => item.id);
  for (const id of ids) { await DownloadService.resume(id); }
  Logger.info('DOWNLOAD_BATCH', '全部继续，数量=' + ids.length);
}
static async retryAll(): Promise<void> {
  await DownloadService.init();
  const ids: string[] = DownloadService.snapshot().filter((item: DownloadRecord) => item.state === DownloadState.FAILED).map((item: DownloadRecord) => item.id);
  for (const id of ids) { await DownloadService.resume(id); }
  Logger.info('DOWNLOAD_BATCH', '重试失败任务，数量=' + ids.length);
}
static async removeAll(): Promise<void> {
  await DownloadService.init(); const ids: string[] = DownloadService.snapshot().map((item: DownloadRecord) => item.id);
  for (const id of ids) { await DownloadService.remove(id); }
  Logger.info('DOWNLOAD_BATCH', '全部删除，数量=' + ids.length);
}

static hasLocalFile(record: DownloadRecord): boolean {
  try {
    const host = DownloadService.host;
    if (!host || !record.localPath.startsWith(host.filesDir + '/wuyin_media_downloads/') || !fileIo.accessSync(record.localPath) || fileIo.statSync(record.localPath).size <= 0) { return false; }
    return record.mediaKind !== 'hls' || (record.assets.length > 0 && record.assets.every((asset: DownloadAsset) => asset.localPath.startsWith(host.filesDir + '/wuyin_media_downloads/') && fileIo.accessSync(asset.localPath) && fileIo.statSync(asset.localPath).size > 0));
  } catch (error) { Logger.warn('DOWNLOAD_FILE', '检查本地视频失败：' + record.id); return false; }
}

private static validateRecords(incoming: DownloadRecord[]): DownloadRecord[] {
  if (!Array.isArray(incoming)) { throw new Error('下载任务数据格式错误'); }
  const result: DownloadRecord[] = [];
  for (const item of incoming.slice(0, 5000)) {
    if (!item || typeof item.id !== 'string' || !/^wuyin_[a-z0-9_]+$/.test(item.id) || typeof item.sourceUrl !== 'string' || !/^https?:\/\//i.test(item.sourceUrl)) { continue; }
    if (result.some((record: DownloadRecord) => record.id === item.id || (record.videoId === item.videoId && record.episodeIndex === item.episodeIndex))) { continue; }
    const record = new DownloadRecord();
    record.id = item.id; record.sourceUrl = item.sourceUrl;
    record.resolvedUrl = typeof item.resolvedUrl === 'string' && /^https?:\/\//i.test(item.resolvedUrl) ? item.resolvedUrl : '';
    record.videoId = typeof item.videoId === 'string' ? item.videoId : ''; record.name = typeof item.name === 'string' ? item.name : '未命名影片';
    record.episodeTitle = typeof item.episodeTitle === 'string' ? item.episodeTitle : '视频'; record.cover = typeof item.cover === 'string' ? item.cover : '';
    record.systemId = typeof item.systemId === 'string' ? item.systemId : '';
    record.nativeStarted = typeof item.nativeStarted === 'boolean' ? item.nativeStarted : !!record.systemId;
    record.episodeIndex = Number.isFinite(item.episodeIndex) ? Math.max(1, Math.floor(item.episodeIndex)) : 1;
    record.receivedBytes = Number.isFinite(item.receivedBytes) ? Math.max(0, item.receivedBytes) : 0;
    record.totalBytes = Number.isFinite(item.totalBytes) ? Math.max(0, item.totalBytes) : 0;
    record.updatedAt = Number.isFinite(item.updatedAt) ? item.updatedAt : Date.now();
    record.message = typeof item.message === 'string' ? item.message : '';
    record.state = item.state === DownloadState.SNIFFING || item.state === DownloadState.QUEUED || item.state === DownloadState.RUNNING || item.state === DownloadState.PAUSED || item.state === DownloadState.COMPLETED || item.state === DownloadState.FAILED ? item.state : DownloadState.PAUSED;
    record.mediaKind = item.mediaKind === 'hls' ? 'hls' : 'file';
    record.manifest = typeof item.manifest === 'string' ? item.manifest : '';
    record.localPath = record.mediaKind === 'hls' ? DownloadService.directory() + '/' + record.id + '.m3u8' : DownloadService.path(record.id, record.resolvedUrl || record.sourceUrl);
    if (record.mediaKind === 'hls' && Array.isArray(item.assets)) {
      for (let index: number = 0; index < Math.min(item.assets.length, 5000); index++) {
        const saved = item.assets[index]; if (!saved || typeof saved.sourceUrl !== 'string' || !/^https?:\/\//i.test(saved.sourceUrl)) { continue; }
        const asset = new DownloadAsset(); asset.sourceUrl = saved.sourceUrl;
        asset.localPath = DownloadService.directory() + '/' + record.id + '_assets/part_' + index + DownloadService.extension(asset.sourceUrl);
        asset.receivedBytes = Number.isFinite(saved.receivedBytes) ? Math.max(0, saved.receivedBytes) : 0;
        asset.totalBytes = Number.isFinite(saved.totalBytes) ? Math.max(0, saved.totalBytes) : 0; asset.completed = saved.completed === true;
        record.assets.push(asset);
      }
      record.assetIndex = Number.isInteger(item.assetIndex) ? Math.max(0, Math.min(record.assets.length - 1, item.assetIndex)) : 0;
      DownloadService.aggregate(record);
    } else if (record.systemId && !record.resolvedUrl) { record.resolvedUrl = record.sourceUrl; }
    if (record.state === DownloadState.COMPLETED) { record.progressPercent = 100; }
    else if (record.mediaKind !== 'hls') { record.progressPercent = record.totalBytes > 0 ? Math.min(99, record.receivedBytes * 100 / record.totalBytes) : 0; }
    result.push(record);
  }
  return result;
}

static async exportFile(context: common.UIAbilityContext): Promise<boolean> {
  await DownloadService.init(context);
  try {
    const document = new picker.DocumentViewPicker(context);
    const selected = await document.save({ newFileNames: [DownloadService.ARCHIVE_NAME] }); if (!selected.length) { return false; }
    const archive: DownloadArchive = { format: 'wuyin-download-tasks', version: 1, tasks: [] };
    for (const task of DownloadService.snapshot()) {
      const exported = DownloadService.copy(task); exported.systemId = ''; exported.localPath = ''; exported.nativeStarted = false; exported.speedBytes = 0;
      for (const asset of exported.assets) { asset.localPath = ''; }
      archive.tasks.push(exported);
    }
    const data = new util.TextEncoder().encodeInto(JSON.stringify(archive));
    const output = fileIo.openSync(selected[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(output.fd, data.buffer); } finally { fileIo.closeSync(output); }
    Logger.info('DOWNLOAD_EXPORT', '导出任务元数据，数量=' + archive.tasks.length); return true;
  } catch (error) { Logger.error('DOWNLOAD_EXPORT', String(error)); throw new Error(String(error)); }
}

static async readImport(context: common.UIAbilityContext): Promise<DownloadRecord[] | undefined> {
  await DownloadService.init(context);
  try {
    const document = new picker.DocumentViewPicker(context);
    const openOptions: picker.DocumentSelectOptions = { fileSuffixFilters: ['下载任务|.json'] };
    PlatformApi.setMaxSelectNumber(openOptions as Object, 1);
    const selected = await document.select(openOptions); if (!selected.length) { return undefined; }
    const input = fileIo.openSync(selected[0], fileIo.OpenMode.READ_ONLY); let text: string = '';
    try {
      const size: number = fileIo.statSync(input.fd).size;
      if (size <= 0 || size > 8 * 1024 * 1024) { throw new Error('导入文件为空或超过 8MB'); }
      const buffer = new ArrayBuffer(size); const count: number = fileIo.readSync(input.fd, buffer);
      if (count !== size) { throw new Error('导入文件读取不完整'); }
      text = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeWithStream(new Uint8Array(buffer));
    } finally { fileIo.closeSync(input); }
    const archive = JSON.parse(text) as DownloadArchive;
    if (archive.format !== 'wuyin-download-tasks' || archive.version !== 1) { throw new Error('不是受支持的无音影视下载任务文件'); }
    const records = DownloadService.validateRecords(archive.tasks);
    for (const record of records) {
      record.systemId = ''; record.nativeStarted = false;
      record.state = record.state === DownloadState.COMPLETED && DownloadService.hasLocalFile(record) ? DownloadState.COMPLETED : DownloadState.PAUSED;
      if (record.state !== DownloadState.COMPLETED) {
        record.resolvedUrl = ''; record.mediaKind = 'file'; record.assets = []; record.manifest = '';
        record.receivedBytes = 0; record.totalBytes = 0; record.progressPercent = 0; record.sniffProgress = 0;
      }
    }
    Logger.info('DOWNLOAD_IMPORT', '读取任务元数据，数量=' + records.length); return records;
  } catch (error) { Logger.error('DOWNLOAD_IMPORT', String(error)); throw new Error(String(error)); }
}

static async importRecords(incoming: DownloadRecord[], overwrite: boolean): Promise<void> {
  await DownloadService.init();
  // 覆盖仅清理队列，保留本地文件；显式删除任务才删除视频。
  if (overwrite) {
    await DownloadService.pauseAll(); const previous = DownloadService.records.slice(); DownloadService.records = []; DownloadService.publish();
    for (const item of previous) {
      DownloadService.cancelProbe(item.id);
      await DownloadService.nativeCommand(item.id, async () => {
        if (item.systemId) { try { await request.agent.remove(item.systemId); } catch (error) { Logger.warn('DOWNLOAD_IMPORT', '移除旧系统任务失败：' + item.id); } }
      });
    }
    DownloadService.tasks.clear(); DownloadService.samples.clear();
  }
  for (const item of incoming) {
    if (DownloadService.records.some((record: DownloadRecord) => record.id === item.id || (record.videoId === item.videoId && record.episodeIndex === item.episodeIndex))) { continue; }
    DownloadService.records.push(DownloadService.copy(item));
  }
  await DownloadService.save(); DownloadService.publish(); Logger.info('DOWNLOAD_IMPORT', (overwrite ? '覆盖' : '合并') + '导入任务，等待用户手动继续');
}
}

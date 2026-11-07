import audio from '@ohos.multimedia.audio';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import abilityAccessCtrl, { Permissions, PermissionRequestResult } from '@ohos.abilityAccessCtrl';
import { Logger } from './Logger';
import { PlatformBridge } from './PlatformBridge';
import { PlatformInfo } from './PlatformInfo';
import { VoiceStore } from './VoiceStore';

/** 一段录好的语音：本地路径 + 时长（毫秒）。 */
export class VoiceClip {
  path: string = '';
  durationMs: number = 0;
}

/**
 * 聊天室语音录制：输出 **WAV**（PCM 16bit / 单声道 / 44.1kHz）。
 *
 * AVRecorder 没有 WAV 容器选项，所以用 AudioCapturer 取原始 PCM：
 * 文件开头先占 44 字节，边录边追加，停止时按实际长度回填标准 WAV 头。
 * 上传走 dbimg（实测 audio/wav 可以直接传）。
 */
export class VoiceRecorder {
  /** 录太短的片段不当作语音。 */
  static readonly MIN_DURATION_MS: number = 800;
  private static readonly SAMPLE_RATE: number = 44100;
  private static readonly CHANNELS: number = 1;
  private static readonly BITS: number = 16;
  private static readonly HEADER_BYTES: number = 44;
  private capturer?: audio.AudioCapturer = undefined;
  private file?: fs.File = undefined;
  private path: string = '';
  private startedAt: number = 0;
  private pcmBytes: number = 0;
  private recording: boolean = false;

  /** 申请麦克风权限；已授权时直接返回 true。 */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    if (PlatformInfo.isAndroid()) {
      if (await PlatformBridge.hasMicrophonePermission()) { return true; }
      await PlatformBridge.requestMicrophonePermission();
      for (let index: number = 0; index < 20; index++) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 300); });
        if (await PlatformBridge.hasMicrophonePermission()) { return true; }
      }
      return false;
    }
    if (PlatformInfo.isIOS()) { return true; }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, permissions);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      if (!granted) {
        Logger.warn('CHAT_VOICE', '麦克风权限未授权');
      }
      return granted;
    } catch (error) {
      Logger.error('CHAT_VOICE', '申请麦克风权限失败：' + String(error));
      return false;
    }
  }

  /** 每次录音写到私有目录下的新 wav 文件。 */
  static newPath(context: common.UIAbilityContext, suffix: string = '.wav'): string {
    const managed: string = VoiceStore.newPath(suffix);
    if (managed.length > 0) { return managed; }
    return context.filesDir + '/voice_' + String(Date.now()) + suffix;
  }

  isRecording(): boolean {
    return this.recording;
  }

  /** 开始录音；失败会抛出，由调用方提示。 */
  async start(path: string): Promise<void> {
    if (this.recording) { return; }
    const wavPath: string = path.endsWith('.wav') ? path : path.replace(/\.[A-Za-z0-9]+$/, '') + '.wav';
    const file: fs.File = fs.openSync(wavPath,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    // 先占位 44 字节，录完回填 WAV 头。
    fs.writeSync(file.fd, new ArrayBuffer(VoiceRecorder.HEADER_BYTES));
    let capturer: audio.AudioCapturer | undefined = undefined;
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      };
      const options: audio.AudioCapturerOptions = {
        streamInfo: streamInfo,
        capturerInfo: capturerInfo
      };
      capturer = await audio.createAudioCapturer(options);
      this.pcmBytes = 0;
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        if (!this.recording || this.file === undefined) { return; }
        try {
          fs.writeSync(this.file.fd, buffer);
          this.pcmBytes += buffer.byteLength;
        } catch (error) {
          Logger.warn('CHAT_VOICE', '写入录音数据失败：' + String(error));
        }
      });
      await capturer.start();
      this.capturer = capturer;
      this.file = file;
      this.path = wavPath;
      this.startedAt = Date.now();
      this.recording = true;
      Logger.info('CHAT_VOICE', '开始录音（wav）');
    } catch (error) {
      try { if (capturer !== undefined) { await capturer.release(); } } catch (_) { /* 忽略 */ }
      try { fs.closeSync(file); } catch (_) { /* 忽略 */ }
      this.recording = false;
      throw new Error('录音启动失败：' + String(error));
    }
  }

  /** 结束录音：停采集、按 PCM 长度算时长、回填 WAV 头。 */
  async stop(): Promise<VoiceClip> {
    const clip: VoiceClip = new VoiceClip();
    clip.path = this.path;
    const wallClock: number = this.recording ? Math.max(0, Date.now() - this.startedAt) : 0;
    this.recording = false;
    const capturer: audio.AudioCapturer | undefined = this.capturer;
    this.capturer = undefined;
    if (capturer !== undefined) {
      try { await capturer.stop(); } catch (error) {
        Logger.warn('CHAT_VOICE', '停止采集失败：' + String(error));
      }
      try { await capturer.release(); } catch (error) {
        Logger.warn('CHAT_VOICE', '释放采集器失败：' + String(error));
      }
    }
    const file: fs.File | undefined = this.file;
    this.file = undefined;
    if (file !== undefined) {
      try {
        const header: ArrayBuffer = VoiceRecorder.wavHeader(this.pcmBytes);
        fs.writeSync(file.fd, header, { offset: 0, length: header.byteLength });
      } catch (error) {
        Logger.warn('CHAT_VOICE', '写入 WAV 头失败：' + String(error));
      }
      try { fs.closeSync(file); } catch (_) { /* 忽略 */ }
    }
    const bytesPerSecond: number = VoiceRecorder.SAMPLE_RATE * VoiceRecorder.CHANNELS * VoiceRecorder.BITS / 8;
    const fromPcm: number = this.pcmBytes > 0 ? Math.round(this.pcmBytes * 1000 / bytesPerSecond) : 0;
    clip.durationMs = fromPcm > 0 ? fromPcm : wallClock;
    Logger.info('CHAT_VOICE', '录音结束，时长毫秒=' + String(clip.durationMs) + '，PCM 字节=' + String(this.pcmBytes));
    return clip;
  }

  /** 放弃这段录音：停止并删除文件。 */
  async cancel(): Promise<void> {
    const path: string = this.path;
    if (this.capturer !== undefined) {
      const capturer: audio.AudioCapturer = this.capturer;
      this.capturer = undefined;
      this.recording = false;
      try { await capturer.stop(); } catch (_) { /* 忽略 */ }
      try { await capturer.release(); } catch (_) { /* 忽略 */ }
    }
    this.recording = false;
    const file: fs.File | undefined = this.file;
    this.file = undefined;
    if (file !== undefined) {
      try { fs.closeSync(file); } catch (_) { /* 忽略 */ }
    }
    VoiceRecorder.deleteFile(path);
  }

  /** 标准 44 字节 WAV 头（PCM 16bit 单声道）。 */
  private static wavHeader(dataBytes: number): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(VoiceRecorder.HEADER_BYTES);
    const view: DataView = new DataView(buffer);
    const byteRate: number = VoiceRecorder.SAMPLE_RATE * VoiceRecorder.CHANNELS * VoiceRecorder.BITS / 8;
    const blockAlign: number = VoiceRecorder.CHANNELS * VoiceRecorder.BITS / 8;
    view.setUint8(0, 0x52); view.setUint8(1, 0x49); view.setUint8(2, 0x46); view.setUint8(3, 0x46);
    view.setUint32(4, 36 + dataBytes, true);
    view.setUint8(8, 0x57); view.setUint8(9, 0x41); view.setUint8(10, 0x56); view.setUint8(11, 0x45);
    view.setUint8(12, 0x66); view.setUint8(13, 0x6D); view.setUint8(14, 0x74); view.setUint8(15, 0x20);
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, VoiceRecorder.CHANNELS, true);
    view.setUint32(24, VoiceRecorder.SAMPLE_RATE, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, VoiceRecorder.BITS, true);
    view.setUint8(36, 0x64); view.setUint8(37, 0x61); view.setUint8(38, 0x74); view.setUint8(39, 0x61);
    view.setUint32(40, dataBytes, true);
    return buffer;
  }

  static deleteFile(path: string): void {
    if (path.length === 0) { return; }
    try { fs.unlinkSync(path); } catch (_) { /* 文件不存在也无所谓 */ }
  }
}

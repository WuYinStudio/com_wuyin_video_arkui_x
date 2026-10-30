import { common, bundleManager } from '@kit.AbilityKit';
import { tag, nfcController } from '@kit.ConnectivityKit';
import { SearchVideoItem } from '../pages/PlayerPage';
import { ShareService } from './ShareService';
import { Logger } from './Logger';

// 使用公开 NFC_TAG API 写入标准 NDEF URI。手机间隔空投递由 ShareKit 负责，
// 不把读写标签能力伪装成系统未公开的手机对手机 NFC 点对点发送能力。
export class NfcShareService {
  private static owner?: common.UIAbilityContext;
  private static sessionVersion: number = 0;
  private static waiting: boolean = false;
  private static writing: boolean = false;
  private static expiryTimer: number = -1;

  static async shareEpisode(context: common.UIAbilityContext, video: SearchVideoItem,
    episodeTitle: string, playUrl: string, episodeIndex: number): Promise<void> {
    let link: string = '';
    try {
      if (NfcShareService.waiting) {
        if (NfcShareService.writing) {
          context.getPromptAction().showToast({ message: '正在写入 NFC，请保持标签贴近设备' });
          return;
        }
        NfcShareService.cancel();
        context.getPromptAction().showToast({ message: '已取消 NFC 碰一碰' });
        return;
      }
      link = ShareService.createLink(video, episodeTitle, playUrl, episodeIndex, 'nfc');
      if (!nfcController.isNfcAvailable()) {
        throw new Error('当前设备不支持 NFC，可复制参数或使用隔空传送');
      }
      if (!nfcController.isNfcOpen()) {
        throw new Error('请先在系统设置中开启 NFC，再使用碰一碰');
      }
      if (!await ShareService.confirmReceiver(link, 'nfc')) { return; }
      const confirmation = await context.getPromptAction().showDialog({
        title: 'NFC 碰一碰',
          message: '将当前剧集的 wuyin://player 链接写入可写 NFC 标签。接收设备读取标签后可打开无音影视。此入口使用标准 NDEF 标签，不支持直接把另一部手机当作可写标签；手机间传送请使用隔空传送。',
          buttons: [{ text: '取消', color: '#999999' }, { text: '开始写入', color: '#E5484D' }]
      });
      if (confirmation.index !== 1) { return; }
      NfcShareService.owner = context;
      NfcShareService.waiting = true;
      NfcShareService.writing = false;
      const version: number = ++NfcShareService.sessionVersion;
      const element: bundleManager.ElementName = {
        bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
      };
      tag.registerForegroundDispatch(element, [], (error, info) => {
        try {
          if (version !== NfcShareService.sessionVersion || !NfcShareService.waiting) { return; }
          if (error && error.code !== 0) {
            Logger.error('NFC', '发现标签失败，错误码=' + error.code);
            NfcShareService.cancel();
            void ShareService.showCopyFallback(link, 'NFC 标签识别失败，可复制参数后发送。');
            return;
          }
          if (NfcShareService.writing) { return; }
          NfcShareService.writing = true;
          void NfcShareService.writeLink(info, link, version, context);
        } catch (_) {
          Logger.error('NFC', '处理标签发现回调失败');
          NfcShareService.cancel();
        }
      });
      NfcShareService.expiryTimer = setTimeout(() => {
        try {
          if (version !== NfcShareService.sessionVersion) { return; }
          Logger.warn('NFC', '碰一碰等待超时，停止前台标签分发');
          NfcShareService.cancel();
          context.getPromptAction().showToast({ message: 'NFC 碰一碰已超时，请重新点击或复制参数' });
        } catch (_) { Logger.error('NFC', '处理 NFC 超时失败'); }
      }, 60000);
      Logger.info('NFC', '等待可写 NDEF 标签，URI字符数=' + link.length);
      context.getPromptAction().showToast({ message: '请贴近可写 NFC 标签；再次点击碰一碰可取消', duration: 3000 });
    } catch (error) {
      NfcShareService.cancel();
      const caught: Error = error as Error;
      Logger.error('NFC', '启动碰一碰失败：' + (caught.message || '系统 NFC 异常'));
      if (link) { await ShareService.showCopyFallback(link, caught.message || 'NFC 碰一碰未完成'); }
      else { throw new Error(caught.message || '当前剧集无法通过 NFC 分享'); }
    }
  }

  private static async writeLink(info: tag.TagInfo, link: string, version: number,
    context: common.UIAbilityContext): Promise<void> {
    try {
      if (version !== NfcShareService.sessionVersion) { return; }
      const ndefTag = tag.getNdef(info);
      try {
        ndefTag.connect();
        if (!ndefTag.isNdefWritable()) { throw new Error('NFC 标签不可写，请使用可写 NDEF 标签'); }
        // URI 记录类型 U；首字节 0 表示无前缀压缩。createLink 已输出纯 ASCII URI，
        // 不对 URI 再次 JSON 序列化或百分号编码，与 ShareKit 的 url 完全一致。
        const uriBytes: number[] = [0];
        for (let index: number = 0; index < link.length; index++) {
          const value: number = link.charCodeAt(index);
          if (value > 127) { throw new Error('NFC URI 编码无效'); }
          uriBytes.push(value);
        }
        const record: tag.NdefRecord = { tnf: 1, rtdType: [0x55], id: [], payload: uriBytes };
        const message: tag.NdefMessage = [record];
        // 长记录使用四字节长度；给 NDEF 消息头和 URI 类型预留空间。
        if (uriBytes.length + 8 > ndefTag.getNdefTagSize()) {
          throw new Error('NFC 标签容量不足，完整影视选集无法写入，请使用隔空传送或复制参数');
        }
        if (version !== NfcShareService.sessionVersion) { return; }
        Logger.info('NFC', '开始写入标准 NDEF URI，字节数=' + uriBytes.length);
        await ndefTag.writeNdef(message);
        if (version !== NfcShareService.sessionVersion) { return; }
        Logger.info('NFC', 'NDEF 写入完成；接收设备读标签及唤起结果不由发送端推断');
        context.getPromptAction().showToast({ message: '影视链接已写入 NFC 标签，接收设备可碰一碰打开' });
      } finally {
        try { ndefTag.reset(); }
        catch (_) { Logger.warn('NFC', '断开 NFC 标签连接失败'); }
      }
    } catch (error) {
      if (version !== NfcShareService.sessionVersion) { return; }
      const caught: Error = error as Error;
      Logger.error('NFC', '写入 NDEF URI 失败：' + (caught.message || '系统 NFC 异常'));
      await ShareService.showCopyFallback(link, caught.message || 'NFC 写入失败');
    } finally {
      if (version === NfcShareService.sessionVersion) { NfcShareService.cancel(); }
    }
  }

  static cancel(): void {
    try {
      const context: common.UIAbilityContext | undefined = NfcShareService.owner;
      NfcShareService.sessionVersion++;
      NfcShareService.waiting = false;
      NfcShareService.writing = false;
      NfcShareService.owner = undefined;
      if (NfcShareService.expiryTimer !== -1) {
        clearTimeout(NfcShareService.expiryTimer);
        NfcShareService.expiryTimer = -1;
      }
      if (context) {
        const element: bundleManager.ElementName = {
          bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name
        };
        tag.unregisterForegroundDispatch(element);
        Logger.info('NFC', '已清理前台 NFC 标签分发');
      }
    } catch (_) { Logger.warn('NFC', '清理碰一碰会话失败'); }
  }
}

import { common, Want } from '@kit.AbilityKit';
import { ShareController, ShareOperationResult, SharedData, SharedRecord, SharePreviewMode, getSharedData } from './compat/ShareCompat';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { CoPlayInviteHandoff } from './CoPlayInviteHandoff';

const SHARE_DATA_KEY: string = 'ohos.extra.param.key.share_data';

// 协播专用分享边界，不改变普通影视分享、入会协议及播放器。
export class CoPlayShareService {
  private static activeController?: ShareController;
  private static preparing: boolean = false;

  private static notify(notice: (message: string) => void, message: string): void {
    try { notice(message); }
    catch (error) { Logger.warn('MEDIA_SESSION', '【CoPlay][SendShare] 显示分享提示失败：' + String(error)); }
  }

  static async show(context: common.UIAbilityContext, want: Want, title: string,
    notice: (message: string) => void): Promise<void> {
    if (CoPlayShareService.preparing || CoPlayShareService.activeController) {
      Logger.warn('MEDIA_SESSION', '【CoPlay][SendShare] 已有协播分享请求或面板，忽略重复请求');
      CoPlayShareService.notify(notice, '协播分享正在处理，请先关闭分享面板后重试');
      return;
    }
    CoPlayShareService.preparing = true;
    let requestedController: ShareController | undefined;
    try {
      const raw = want.parameters ? want.parameters[SHARE_DATA_KEY] : undefined;
      if (typeof raw !== 'string' || !raw.length) { throw new Error('协播分享载荷不是完整字符串'); }
      // sendData 用于接收端匹配，不能通过隐式 startAbility(sendData) 打开分享面板。
      // SharedRecord 使用 SDK 显式类型，避免 API26 Beta2 的无类型对象字面量错误。
      // content 就是完整业务 JSON，不增加 data/payload 外层，不重复序列化。
      const record: SharedRecord = {
        utd: uniformTypeDescriptor.UniformDataType.TEXT,
          content: raw,
          title: title || '无音影视协播邀请',
          description: '接收设备需安装无音影视；请选择华为分享发送协播邀请'
      };
      const sharedData: SharedData = new SharedData(record);
      const controller: ShareController = new ShareController(sharedData);
      requestedController = controller;
      CoPlayShareService.activeController = controller;
      controller.on('shareCompleted', (result: ShareOperationResult): void => {
        try {
          CoPlayInviteHandoff.logText('SendShareResult', '系统分享结果（不代表已经入会）', JSON.stringify(result));
        } catch (error) {
          Logger.error('MEDIA_SESSION', '【CoPlay][SendShare] 记录分享结果失败：' + String(error));
        } finally {
          // 完成与关闭事件都释放本次面板引用；某些投递路径只回调完成，不能永久拦截后续邀请。
          if (CoPlayShareService.activeController === controller) {
            CoPlayShareService.activeController = undefined;
          }
        }
      });
      controller.on('dismiss', (): void => {
        if (CoPlayShareService.activeController === controller) {
          CoPlayShareService.activeController = undefined;
        }
        Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] 系统分享面板已关闭，关闭面板不代表发送成功或入会成功');
      });
      CoPlayShareService.notify(notice, '正在打开协播分享，请选择华为分享');
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] 正在调用 ShareKit.ShareController.show，utd=general.text，content字符数=' + raw.length);
      await controller.show(context, { previewMode: SharePreviewMode.DEFAULT });
      Logger.info('MEDIA_SESSION', '【CoPlay][SendShare] ShareKit.show 请求已返回，投递结果以系统回调和接收端日志为准');
    } catch (error) {
      if (CoPlayShareService.activeController === requestedController) {
        CoPlayShareService.activeController = undefined;
      }
      const problem: BusinessError | undefined = error as BusinessError | undefined;
      const message: string = problem && problem.message ? problem.message : '唤起协播分享邀请失败';
      Logger.error('MEDIA_SESSION', '【CoPlay][SendShare] ShareKit 唤起异常，code=' +
      String(problem ? problem.code : undefined) + '，message=' + message);
      throw new Error(message);
    } finally {
      CoPlayShareService.preparing = false;
    }
  }

  static async readRaw(want: Want): Promise<string | undefined> {
    const transport = want.parameters ? want.parameters[SHARE_DATA_KEY] : undefined;
    if (typeof transport === 'string') {
      CoPlayInviteHandoff.logText('ReceiveShareTransport', '系统分享原始传输字符串', transport);
    }
    // 系统可能把 SharedData 编码进 share_data，不能把系统封装直接当作业务 JSON。
    // 用官方接口读取 record.content，再由 EntryAbility 对业务顶层 JSON 仅解析一次。
    // 不自行解析系统封装，也不增加业务 data/payload 嵌套解包；兼容旧端直接传原文。
    let sharedData: SharedData | undefined;
    try {
      // API26 Beta2 返回 Promise<SharedData>，必须等待完成后才能读取记录。
      sharedData = await getSharedData(want);
    } catch (_) {
      Logger.debug('MEDIA_SESSION', '【CoPlay][ReceiveShare] 当前 Want 不是 ShareKit SharedData，继续使用原始 share_data');
    }
    if (sharedData) {
      const records: SharedRecord[] = sharedData.getRecords();
      Logger.info('MEDIA_SESSION', '【CoPlay][ReceiveShare] ShareKit 记录数=' + records.length);
      let content: string | undefined;
      for (const record of records) {
        Logger.info('MEDIA_SESSION', '【CoPlay][ReceiveShare] 记录utd=' + record.utd + '，content类型=' + typeof record.content);
        if ((record.utd !== uniformTypeDescriptor.UniformDataType.TEXT &&
          record.utd !== uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) ||
          typeof record.content !== 'string' || !record.content.length) { continue; }
        if (content !== undefined && content !== record.content) {
          Logger.error('MEDIA_SESSION', '【CoPlay][ReceiveShare] 收到多条不一致的文本记录，拒绝混合协播邀请');
          throw new Error('协播数据解析失败');
        }
        content = record.content;
      }
      if (content !== undefined) {
        CoPlayInviteHandoff.logText('ReceiveShare', 'ShareKit 提取的完整原始协播 JSON', content);
        return content;
      }
      if (records.length > 0) {
        Logger.error('MEDIA_SESSION', '【CoPlay][ReceiveShare] 系统分享不含有效的纯文本协播载荷');
        throw new Error('协播数据解析失败');
      }
    }
    if (transport === undefined) { return undefined; }
    if (typeof transport !== 'string') { throw new Error('协播数据解析失败'); }
    Logger.info('MEDIA_SESSION', '【CoPlay][ReceiveShare] 使用旧端直接传入的原始 share_data 文本');
    return transport;
  }
}

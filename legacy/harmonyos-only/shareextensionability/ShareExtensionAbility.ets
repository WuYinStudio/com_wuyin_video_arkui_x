import { ShareExtensionAbility as SystemShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { CoPlayInviteHandoff } from '../common/CoPlayInviteHandoff';
import { Logger } from '../common/Logger';

// 系统分享入口只负责接收并原样透传 share_data；JSON 解析、校验和页面导航留在 EntryAbility。
export default class ShareExtensionAbility extends SystemShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    void this.receiveInvite(want, session);
  }

  private async readShareText(want: Want): Promise<string> {
    if (want.action && want.action !== 'ohos.want.action.sendData') {
      throw new Error('不支持的分享动作');
    }
    const shareKey: string = 'ohos.extra.param.key.share_data';
    const parameters = want.parameters;
    const raw = parameters ? parameters[shareKey] : undefined;
    CoPlayInviteHandoff.logText('ReceiveWant', '分享扩展入口参数键名',
      JSON.stringify(parameters ? Object.keys(parameters) : []));

    // ShareController 传递的是 ShareKit SharedData；其内容不保证直接出现在 Want.parameters。
    // 必须优先用官方 getSharedData(want) 取出文本记录，不能把内部传输封装当业务 JSON。
    try {
      const sharedData: systemShare.SharedData = await systemShare.getSharedData(want);
      const records: systemShare.SharedRecord[] = sharedData.getRecords();
      Logger.info('MEDIA_SESSION', '【CoPlay][ReceiveShare] 分享扩展通过 getSharedData 收到记录数=' + records.length);
      let content: string | undefined;
      for (const record of records) {
        Logger.info('MEDIA_SESSION', '【CoPlay][ReceiveShare] 扩展记录UTD=' + record.utd + '，内容类型=' + typeof record.content);
        if ((record.utd !== uniformTypeDescriptor.UniformDataType.TEXT &&
          record.utd !== uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) ||
          typeof record.content !== 'string' || !record.content.trim()) { continue; }
        if (content !== undefined && content !== record.content) {
          throw new Error('分享中包含多条不一致文本，拒绝混合协播载荷');
        }
        content = record.content;
      }
      if (content !== undefined) {
        CoPlayInviteHandoff.logText('ReceiveShare', 'getSharedData 提取的原始协播载荷', content);
        return content;
      }
    } catch (error) {
      Logger.warn('MEDIA_SESSION', '【CoPlay][ReceiveShare] getSharedData 读取失败，尝试兼容原始参数：' + String(error));
    }

    // 兼容旧系统/旧发送端直接将原文放入 share_data 的路径。
    if (typeof raw !== 'string' || !raw.trim()) {
      throw new Error('协播数据解析失败：ShareKit 未提供文本记录或原始 share_data');
    }
    CoPlayInviteHandoff.logText('ReceiveShare', '分享扩展收到的原始 share_data 载荷', raw);
    return raw;
  }

  private async receiveInvite(want: Want, session: UIExtensionContentSession): Promise<void> {
    try {
      const raw: string = await this.readShareText(want);
      // 使用 UIExtensionContext 自身的启动接口，不转换为 UIAbilityContext，
      // 也不使用缺少 startAbility 接口的 ApplicationContext。
      const parameters: Record<string, string> = {
        'ohos.extra.param.key.share_data': raw
      };
      const launchWant: Want = {
        bundleName: 'com.wuyin.video',
          abilityName: 'EntryAbility',
          action: 'ohos.want.action.sendData',
          parameters: parameters
      };
      await this.context.startAbility(launchWant);
      Logger.info('MEDIA_SESSION', '分享扩展已将原始协播载荷透传至 EntryAbility，字符数=' + raw.length);
    } catch (error) {
      Logger.error('MEDIA_SESSION', '分享扩展接收或交接协播邀请失败：' + String(error));
    } finally {
      try { await session.terminateSelf(); }
      catch (error) { Logger.warn('MEDIA_SESSION', '结束分享扩展会话失败：' + String(error)); }
    }
  }
}

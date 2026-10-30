import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { AppConfig } from './AppConfig';
import { ApiRequestOptions } from './CommunityApi';
import { Logger } from './Logger';

/** 关注/粉丝条目。 */
export class FollowEntry {
  user: string = '';
  name: string = '';
  avatar: string = '';
  time: string = '';
  mutual: boolean = false;
}

/** 私聊单条记录。 */
export class ChatEntry {
  user: string = '';
  content: string = '';
  time: string = '';
}

/** 聊天室列表项。 */
export class LtsRoom {
  title: string = '';
  avatar: string = '';
  count: number = 0;
  latest: string = '';
}

class FollowRow {
  users: string = '';
  name: string = '';
  avatar: string = '';
  time: string = '';
  is_mutual: string = '0';
}

class FollowListResponse {
  status: string = '';
  total: number = 0;
  data: FollowRow[] = [];
}

class FollowMessage {
  status: string = '';
  message: string = '';
}

class LtsRoomRow {
  title: string = '';
  avatar: string = '';
  message_count: number = 0;
  latest_message: string = '';
}

class LtsListResponse {
  message: string = '';
  // 服务端 chatrooms 直接是数组：[{title,avatar,message_count,latest_message}]
  chatrooms: LtsRoomRow[] = [];
}

/**
 * 云逸账号接口封装（api.y11.top）。全部 GET + admin=后台账号，返回纯文本或 JSON。
 */
export class AccountApi {
  private static domain(): string {
    let result: string = AppConfig.getInstance().backendDomain.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  private static url(path: string, query: string): string {
    const admin: string = encodeURIComponent(AppConfig.getInstance().backendAccount);
    const base: string = AccountApi.domain() + path + '?admin=' + admin;
    return query.length > 0 ? base + '&' + query : base;
  }

  private static userQuery(user: string, pass: string): string {
    return 'user=' + encodeURIComponent(user) + '&pass=' + encodeURIComponent(pass);
  }

  private static async get(url: string, label: string): Promise<string> {
    let request: http.HttpRequest | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, new ApiRequestOptions());
      const text: string = String(response.result).trim();
      Logger.info('ACCOUNT_API', label + ' 返回：' + text.substring(0, 160));
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(label + ' HTTP ' + String(response.responseCode));
      }
      return text;
    } catch (error) {
      Logger.error('ACCOUNT_API', label + ' 请求失败：' + String(error));
      throw new Error(label + '失败：' + String(error));
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  private static messageOf(text: string): string {
    try {
      const parsed: FollowMessage = JSON.parse(text) as FollowMessage;
      if (parsed !== undefined && parsed.message !== undefined && String(parsed.message).length > 0) {
        return String(parsed.message);
      }
    } catch (error) {
      Logger.warn('ACCOUNT_API', '返回非 JSON：' + String(error));
    }
    return (text || '').substring(0, 60);
  }

  // ---------------- 金币 / 会员 ----------------

  static async money(user: string, pass: string): Promise<number> {
    const text: string = await AccountApi.get(
      AccountApi.url('/echomoney.php', AccountApi.userQuery(user, pass)), '查看金币');
    const value: number = Number(text.replace(/[^\d.-]/g, ''));
    return Number.isFinite(value) ? value : 0;
  }

  static async vipExpire(user: string, pass: string): Promise<string> {
    const text: string = await AccountApi.get(
      AccountApi.url('/uservipif.php', AccountApi.userQuery(user, pass)), '判断会员');
    if (text.length === 0 || text.includes('过期') || text.includes('不是')) { return ''; }
    const index: number = text.indexOf(':');
    return index >= 0 ? text.substring(index + 1).trim() : text;
  }

  // ---------------- 资料 ----------------

  static async setNickname(user: string, pass: string, name: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/username.php',
      AccountApi.userQuery(user, pass) + '&name=' + encodeURIComponent(name)), '修改昵称');
  }

  static async setSignature(user: string, pass: string, signature: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/autographset.php',
      AccountApi.userQuery(user, pass) + '&autograph=' + encodeURIComponent(signature)), '修改签名');
  }

  static async setPassword(user: string, pass: string, newPass: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/userpass.php',
      AccountApi.userQuery(user, pass) + '&newpass=' + encodeURIComponent(newPass)), '修改密码');
  }

  static async setQQ(user: string, pass: string, qq: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/userqqset.php',
      AccountApi.userQuery(user, pass) + '&QQ=' + encodeURIComponent(qq)), '绑定 QQ');
  }

  // ---------------- 邀请 / 验证码 ----------------

  static async inviteList(user: string, pass: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/InviteList.php', AccountApi.userQuery(user, pass)), '邀请列表');
  }

  static async sendMailCode(user: string, mail: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/send_mail.php',
      'user=' + encodeURIComponent(user) + '&mail=' + encodeURIComponent(mail)), '发送验证码');
  }

  // ---------------- 头像 ----------------

  static portraitUrl(user: string): string {
    const name: string = (user || '').trim();
    if (name.length === 0) { return ''; }
    return AccountApi.url('/echoportrait.php', 'user=' + encodeURIComponent(name));
  }

  static portraitUploadPage(user: string, pass: string): string {
    return AccountApi.url('/portraitupload.php', AccountApi.userQuery(user, pass));
  }

  /** 上传用户头像：用系统上传任务发 multipart，字段名 file。 */
  static async uploadPortrait(context: common.UIAbilityContext, user: string, pass: string,
    fileName: string): Promise<string> {
    const url: string = AccountApi.url('/portraitupload.php', AccountApi.userQuery(user, pass));
    try {
      const file: request.File = {
        filename: fileName,
        name: 'file',
        uri: 'internal://cache/' + fileName,
        type: 'jpg'
      };
      const header: Record<string, string> = {};
      const config: request.UploadConfig = {
        url: url,
        header: header,
        method: 'POST',
        files: [file],
        data: []
      };
      const task: request.UploadTask = await request.uploadFile(context, config);
      const result: string = await AccountApi.waitUpload(task);
      Logger.info('ACCOUNT_API', '上传头像结果：' + result);
      return result;
    } catch (error) {
      Logger.error('ACCOUNT_API', '上传头像失败：' + String(error));
      throw new Error('上传头像失败：' + String(error));
    }
  }

  private static waitUpload(task: request.UploadTask): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      task.on('complete', () => { resolve('上传成功'); });
      task.on('fail', () => { resolve('上传失败'); });
    });
  }

  static chatRoomPortraitUrl(chatroom: string): string {
    return AccountApi.url('/lts_portrait.php', 'chatroom=' + encodeURIComponent(chatroom));
  }

  // ---------------- 关注 / 粉丝 ----------------

  static async follow(user: string, pass: string, target: string): Promise<string> {
    const text: string = await AccountApi.get(AccountApi.url('/follow.php',
      AccountApi.userQuery(user, pass) + '&action=follow&users=' + encodeURIComponent(target)), '关注用户');
    return AccountApi.messageOf(text);
  }

  static async unfollow(user: string, pass: string, target: string): Promise<string> {
    const text: string = await AccountApi.get(AccountApi.url('/follow.php',
      AccountApi.userQuery(user, pass) + '&action=unfollow&users=' + encodeURIComponent(target)), '取消关注');
    return AccountApi.messageOf(text);
  }

  static async followers(user: string, pass: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/follow.php',
      AccountApi.userQuery(user, pass) + '&action=followers'), '粉丝列表');
  }

  static async following(user: string, pass: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/follow.php',
      AccountApi.userQuery(user, pass) + '&action=following'), '关注列表');
  }

  static parseFollowList(json: string): FollowEntry[] {
    const list: FollowEntry[] = [];
    try {
      const text: string = (json || '').trim();
      if (text.length === 0) { return list; }
      const parsed: FollowListResponse = JSON.parse(text) as FollowListResponse;
      const rows: FollowRow[] = parsed.data !== undefined ? parsed.data : [];
      for (let index: number = 0; index < rows.length; index++) {
        const row: FollowRow = rows[index];
        const entry: FollowEntry = new FollowEntry();
        entry.user = row.users !== undefined ? String(row.users) : '';
        entry.name = row.name !== undefined ? String(row.name) : '';
        entry.avatar = row.avatar !== undefined ? String(row.avatar) : '';
        entry.time = row.time !== undefined ? String(row.time) : '';
        entry.mutual = String(row.is_mutual !== undefined ? row.is_mutual : '0') === '1';
        if (entry.user.length > 0) { list.push(entry); }
      }
    } catch (error) {
      Logger.warn('ACCOUNT_API', '解析关注列表失败：' + String(error));
    }
    return list;
  }

  static async mutualFriends(user: string, pass: string): Promise<FollowEntry[]> {
    const json: string = await AccountApi.followers(user, pass);
    const all: FollowEntry[] = AccountApi.parseFollowList(json);
    const result: FollowEntry[] = [];
    for (const entry of all) {
      if (entry.mutual) { result.push(entry); }
    }
    return result;
  }

  // ---------------- 私聊 ----------------

  static async sendFriendChat(user: string, pass: string, target: string, content: string): Promise<string> {
    const text: string = await AccountApi.get(AccountApi.url('/friendchat.php',
      AccountApi.userQuery(user, pass) + '&user2=' + encodeURIComponent(target) +
      '&content=' + encodeURIComponent(content)), '发送私聊消息');
    return AccountApi.messageOf(text);
  }

  static async friendChatList(user: string, target: string): Promise<string> {
    return AccountApi.get(AccountApi.url('/echochat.php',
      'user=' + encodeURIComponent(user) + '&user2=' + encodeURIComponent(target)), '读取私聊记录');
  }

  static parseChatLog(text: string): ChatEntry[] {
    const list: ChatEntry[] = [];
    try {
      const body: string = (text || '').trim();
      if (body.length === 0) { return list; }
      const blocks: string[] = body.replace(/^\[/, '').replace(/\]$/, '').split('][');
      for (const block of blocks) {
        const parts: string[] = block.split('|');
        if (parts.length < 2) { continue; }
        const entry: ChatEntry = new ChatEntry();
        entry.user = parts[0].trim();
        entry.content = parts[1].replace(/&lt;br&gt;/g, '\n').trim();
        entry.time = parts.length > 2 ? parts[parts.length - 1].trim() : '';
        if (entry.content.length > 0) { list.push(entry); }
      }
    } catch (error) {
      Logger.warn('ACCOUNT_API', '解析私聊记录失败：' + String(error));
    }
    return list;
  }

  // ---------------- 聊天室列表 ----------------

  static async roomList(): Promise<LtsRoom[]> {
    const text: string = await AccountApi.get(AccountApi.url('/lts_list.php', ''), '聊天室列表');
    const list: LtsRoom[] = [];
    try {
      const parsed: LtsListResponse = JSON.parse(text) as LtsListResponse;
      const rows: LtsRoomRow[] = parsed.chatrooms !== undefined ? parsed.chatrooms : [];
      for (let index: number = 0; index < rows.length; index++) {
        const row: LtsRoomRow = rows[index];
        const room: LtsRoom = new LtsRoom();
        room.title = row.title !== undefined ? String(row.title) : '';
        room.avatar = row.avatar !== undefined ? String(row.avatar) : '';
        room.count = Number(row.message_count);
        room.latest = row.latest_message !== undefined ? String(row.latest_message) : '';
        if (room.title.length > 0) { list.push(room); }
      }
    } catch (error) {
      Logger.warn('ACCOUNT_API', '解析聊天室列表失败：' + String(error));
    }
    return list;
  }

  /** 排行榜：admin_rank.php?action=board&type=level|praise|fans|money。 */
  static async rankList(type: string): Promise<RankEntry[]> {
    const text: string = await AccountApi.get(AccountApi.url('/admin_rank.php',
      'action=board&type=' + encodeURIComponent(type)), '排行榜');
    const list: RankEntry[] = [];
    try {
      const parsed: RankResponse = JSON.parse(text) as RankResponse;
      const rows: RankRow[] = parsed.data !== undefined ? parsed.data : [];
      for (let index: number = 0; index < rows.length; index++) {
        const row: RankRow = rows[index];
        const entry: RankEntry = new RankEntry();
        entry.user = row.username !== undefined ? String(row.username) : '';
        const nick: string = row.nickname !== undefined ? String(row.nickname) : '';
        entry.name = nick.length > 0 && nick !== '未设置' && nick !== 'null' ? nick : entry.user;
        entry.grade = row.grade !== undefined ? String(row.grade) : '';
        entry.rank = row.rank !== undefined ? Number(row.rank) : (index + 1);
        entry.value = row.value !== undefined ? Number(row.value) : 0;
        entry.money = row.money !== undefined ? Number(row.money) : 0;
        entry.fans = row.fans !== undefined ? Number(row.fans) : 0;
        entry.praise = row.praise !== undefined ? Number(row.praise) : 0;
        entry.exp = row.exp !== undefined ? Number(row.exp) : 0;
        if (entry.user.length > 0) { list.push(entry); }
      }
    } catch (error) {
      Logger.warn('ACCOUNT_API', '解析排行榜失败：' + String(error));
    }
    return list;
  }
}

/** 排行榜条目（admin_rank.php）。 */
export class RankEntry {
  rank: number = 0;
  user: string = '';
  name: string = '';
  grade: string = '';
  value: number = 0;
  money: number = 0;
  fans: number = 0;
  praise: number = 0;
  exp: number = 0;
}

class RankRow {
  rank: number = 0;
  username: string = '';
  nickname: string = '';
  grade: string = '';
  exp: number = 0;
  praise: number = 0;
  fans: number = 0;
  money: number = 0;
  value: number = 0;
}

class RankResponse {
  code: number = 0;
  msg: string = '';
  data: RankRow[] = [];
}

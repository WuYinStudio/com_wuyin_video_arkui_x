import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { AppConfig } from './AppConfig';
import { AppState } from './AppState';
import { ForumCodec, ForumContent } from './ForumCodec';
import { Logger } from './Logger';

/**
 * 云逸开放接口（用户 / 聊天室 / 论坛 / 远程）的唯一客户端。
 *
 * 全部按 https://api.y11.top/docs 的 GET 接口接入：
 * - 用户：userlogin.php、echouserdata.php、echonewsnum.php、online_see.php、sign.php
 * - 聊天室：lts.php?action=get/send/revoke
 * - 论坛：bbs.php?action=getPostList/getCategoryList/viewPost/getReplyList/createPost/replyToPost/likePost
 * - 远程：echouser.php?file=notice/file=new
 *
 * 页面只消费这里的强类型结果，不自行拼接口、不内置假数据。
 */

export class ApiRequestOptions {
  method: http.RequestMethod = http.RequestMethod.GET;
  connectTimeout: number = 12000;
  readTimeout: number = 18000;
  expectDataType: http.HttpDataType = http.HttpDataType.STRING;
}

export class CommunitySession {
  user: string = '';
  pass: string = '';
  loggedIn: boolean = false;

  valid(): boolean {
    return this.loggedIn && this.user.trim().length > 0 && this.pass.length > 0;
  }
}

export class CommunityUser {
  userId: string = '';
  name: string = '';
  grade: string = '';
  exp: number = 0;
  money: number = 0;
  qq: string = '';
  signature: string = '';
  chenhao: string = '';
  seal: string = '';
  registerTime: string = '';
  loginTime: string = '';
  vipTime: string = '';
  avatarUrl: string = '';
  postCount: number = 0;
  fans: number = 0;
  follows: number = 0;
  praise: number = 0;
}

export class ChatMessage {
  id: number = 0;
  user: string = '';
  name: string = '';
  grade: string = '';
  vipTime: string = '';
  time: string = '';
  content: string = '';
  replyTo: number = 0;
  // 本地乐观消息状态：网络返回前先显示，失败保留在列表中可重发。
  pending: boolean = false;
  failed: boolean = false;
  localKey: string = '';

  mine(account: string): boolean {
    return account.length > 0 && this.user === account;
  }
}

export class ChatPageResult {
  messages: ChatMessage[] = [];
  page: number = 1;
  total: number = 0;
  emptyText: string = '';
}

export class ForumCategory {
  id: string = '';
  name: string = '';
  description: string = '';
  postCount: number = 0;
  avatarUrl: string = '';
}

export class ForumPost {
  id: string = '';
  title: string = '';
  content: string = '';
  category: string = '';
  user: string = '';
  name: string = '';
  grade: string = '';
  time: string = '';
  views: number = 0;
  likes: number = 0;
  comments: number = 0;
  top: boolean = false;
  essence: boolean = false;
  moderator: boolean = false;
}

export class ForumPageResult {
  posts: ForumPost[] = [];
  page: number = 1;
  totalPages: number = 1;
}

export class ForumReply {
  id: string = '';
  content: string = '';
  user: string = '';
  name: string = '';
  grade: string = '';
  time: string = '';
  likes: number = 0;
  replyTo: number = 0;
}

export class ForumReplyResult {
  replies: ForumReply[] = [];
  total: number = 0;
}

export class RemoteUpdate {
  version: string = '最新版本';
  content: string = '';
  link: string = '';
}

interface RawUserProfile {
  name?: string;
  grade?: string;
  exp?: string | number;
  viptime?: string;
  seal?: string;
  money?: string | number;
  qq?: string | number;
  autograph?: string;
  chenhao?: string;
  logintime?: string;
  registertime?: string;
  avatar?: string;
  postCount?: string | number;
  followers?: string | number;
  following?: string | number;
  praisenum?: string | number;
}

interface RawChatMessage {
  id?: string | number;
  user?: string;
  name?: string;
  grade?: string;
  viptime?: string;
  time?: string;
  message?: string;
  content_r?: string | number;
}

interface RawChatResponse {
  status?: string;
  message?: string;
  message_id?: string | number;
  messages?: RawChatMessage[];
  page?: string | number;
  total?: string | number;
}

interface RawForumCategory {
  id?: string | number;
  name?: string;
  content?: string;
  post_count?: string | number;
  avatar?: string;
}

interface RawForumCategoryResponse {
  categoryList?: RawForumCategory[];
  error?: string;
}

interface RawForumPost {
  id?: string | number;
  title?: string;
  content?: string;
  category?: string;
  user?: string;
  name?: string;
  grade?: string;
  time?: string;
  views?: string | number;
  likes?: string | number;
  comment_count?: string | number;
  top?: string;
  essence?: string;
  is_moderator?: boolean;
}

interface RawForumListResponse {
  postList?: RawForumPost[];
  currentPage?: string | number;
  totalPages?: string | number;
  error?: string;
  message?: string;
}

interface RawForumDetailResponse {
  postList?: RawForumPost;
  post?: RawForumPost;
  currentPage?: string | number;
  totalPages?: string | number;
  error?: string;
  message?: string;
}

interface RawQueryUser {
  username?: string;
  name?: string;
  grade?: string;
  exp?: string | number;
  seal?: string;
  money?: string | number;
  autograph?: string;
  chenhao?: string;
  vip?: string;
  praisenum?: string | number;
  qq?: string | number;
  registertime?: string;
}

interface RawQueryResponse {
  data?: RawQueryUser[];
  error?: string;
}

interface RawForumReply {
  id?: string | number;
  content?: string;
  user?: string;
  name?: string;
  grade?: string;
  time?: string;
  likes?: string | number;
  content_r?: string | number;
}

interface RawForumReplyResponse {
  replyList?: RawForumReply[];
  error?: string;
  total?: string | number;
}

interface RawActionResult {
  status?: string;
  message?: string;
  message_id?: string | number;
  error?: string;
}

/** 无音影视后端的统一入口。 */
export class CommunityApi {
  private static domain(): string {
    const value: string = AppConfig.getInstance().backendDomain.trim();
    if (!value) {
      throw new Error('后端域名尚未配置');
    }
    let result: string = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static adminQuery(): string {
    return 'admin=' + encodeURIComponent(AppConfig.getInstance().backendAccount);
  }

  static adminValue(): string {
    return AppConfig.getInstance().backendAccount;
  }

  /** 读取登录页保存的账号密码；未登录返回空会话。 */
  static async readSession(): Promise<CommunitySession> {
    const session: CommunitySession = new CommunitySession();
    try {
      const context = AppState.context;
      if (!context) {
        return session;
      }
      const store: preferences.Preferences = await preferences.getPreferences(context, 'wuyin');
      session.user = String(await store.get('$user', '')).trim();
      session.pass = String(await store.get('$pass', ''));
      session.loggedIn = session.user.length > 0 && session.pass.length > 0;
    } catch (error) {
      Logger.error('COMMUNITY_SESSION', '读取登录凭证失败：' + String(error));
    }
    return session;
  }

  static async requireSession(): Promise<CommunitySession> {
    const session: CommunitySession = await CommunityApi.readSession();
    if (!session.valid()) {
      throw new Error('请先登录后再使用社区功能');
    }
    return session;
  }

  private static async requestText(path: string, label: string): Promise<string> {
    let request: http.HttpRequest | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(
        CommunityApi.domain() + (path.startsWith('/') ? path : '/' + path),
        new ApiRequestOptions()
      );
      const body: string = String(response.result);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(label + ' HTTP ' + String(response.responseCode));
      }
      return body;
    } catch (error) {
      Logger.error('COMMUNITY_API', label + '请求失败：' + String(error));
      throw new Error(label + '请求失败：' + String(error));
    } finally {
      if (request !== undefined) {
        request.destroy();
      }
    }
  }

  private static async requestJson<T>(path: string, label: string): Promise<T> {
    const body: string = await CommunityApi.requestText(path, label);
    try {
      return JSON.parse(body) as T;
    } catch (error) {
      Logger.error('COMMUNITY_API', label + ' JSON 解析失败：' + String(error));
      throw new Error(label + '返回格式异常');
    }
  }

  private static numberValue(value: string | number | undefined): number {
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  private static textValue(value: string | number | undefined): string {
    if (value === undefined) {
      return '';
    }
    return String(value);
  }

  private static boolValue(value: string | undefined): boolean {
    return typeof value === 'string' && value.trim().length > 0;
  }

  private static absoluteUrl(path: string): string {
    if (!path) {
      return '';
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return CommunityApi.domain() + (path.startsWith('/') ? path : '/' + path);
  }

  private static segment(text: string, start: string, end: string): string {
    const from: number = text.indexOf(start);
    if (from < 0) {
      return '';
    }
    const contentStart: number = from + start.length;
    const to: number = text.indexOf(end, contentStart);
    if (to < 0) {
      return text.substring(contentStart).trim();
    }
    return text.substring(contentStart, to).trim();
  }

  // ---------------- 用户 ----------------

  /** 从 echouserdata 的文本返回里按中文标签取值（JSON 字段对不上时的兜底）。 */
  private static pickLabel(text: string, label: string): string {
    const index: number = text.indexOf(label);
    if (index < 0) { return ''; }
    const rest: string = text.substring(index + label.length);
    const stop: number = rest.indexOf('<br>');
    const value: string = stop >= 0 ? rest.substring(0, stop) : rest;
    return value.replace(/[:：\s]/g, ' ').trim();
  }

  private static numberLabel(text: string, label: string): number {
    const value: string = CommunityApi.pickLabel(text, label);
    const parsed: number = Number(value.replace(/[^\d.-]/g, ''));
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 文本兜底：接口 JSON 键名与预期不一致时，用中文标签解析。 */
  private static fillFromText(result: CommunityUser, text: string): void {
    const name: string = CommunityApi.pickLabel(text, '账号昵称');
    if (name.length > 0) { result.name = name; }
    const grade: string = CommunityApi.pickLabel(text, '账号等级');
    if (grade.length > 0) { result.grade = grade; }
    result.exp = CommunityApi.numberLabel(text, '账号经验');
    result.money = CommunityApi.numberLabel(text, '金币数量');
    result.postCount = CommunityApi.numberLabel(text, '帖子数量');
    result.praise = CommunityApi.numberLabel(text, '获赞数量');
    result.follows = CommunityApi.numberLabel(text, '关注');
    result.fans = CommunityApi.numberLabel(text, '粉丝');
  }

  static async fetchProfile(session: CommunitySession): Promise<CommunityUser> {
    const path: string = '/echouserdata.php?' + CommunityApi.adminQuery() +
      '&user=' + encodeURIComponent(session.user) + '&type=json';
    const body: string = await CommunityApi.requestText(path, '用户资料');
    const result: CommunityUser = new CommunityUser();
    result.userId = session.user;
    Logger.info('COMMUNITY_API', '用户资料原文(' + String(body.length) + '字)：' + body.substring(0, 200));
    if (body.trim().startsWith('{')) {
      let raw: RawUserProfile = {};
      try {
        raw = JSON.parse(body) as RawUserProfile;
      } catch (error) {
        Logger.warn('COMMUNITY_API', '用户资料 JSON 解析失败，改用文本解析：' + String(error));
        CommunityApi.fillFromText(result, body);
        return result;
      }
      result.name = CommunityApi.textValue(raw.name);
      result.grade = CommunityApi.textValue(raw.grade);
      result.exp = CommunityApi.numberValue(raw.exp);
      result.money = CommunityApi.numberValue(raw.money);
      result.qq = CommunityApi.textValue(raw.qq);
      result.signature = CommunityApi.textValue(raw.autograph);
      result.chenhao = CommunityApi.textValue(raw.chenhao);
      result.seal = CommunityApi.textValue(raw.seal);
      result.registerTime = CommunityApi.textValue(raw.registertime);
      result.loginTime = CommunityApi.textValue(raw.logintime);
      result.vipTime = CommunityApi.textValue(raw.viptime);
      result.avatarUrl = CommunityApi.absoluteUrl(CommunityApi.textValue(raw.avatar));
      result.postCount = CommunityApi.numberValue(raw.postCount);
      result.fans = CommunityApi.numberValue(raw.followers);
      result.follows = CommunityApi.numberValue(raw.following);
      result.praise = CommunityApi.numberValue(raw.praisenum);
      // 键名与预期不符时（金币/帖子/等级全为 0），改用文本标签兜底解析。
      if (result.money === 0 || result.postCount === 0 || result.grade.length === 0) {
        try {
          const textBody: string = await CommunityApi.requestText('/echouserdata.php?' +
            CommunityApi.adminQuery() + '&user=' + encodeURIComponent(session.user), '用户资料(文本)');
          CommunityApi.fillFromText(result, textBody);
          Logger.info('COMMUNITY_API', '用户资料改用文本解析：金币=' + String(result.money) +
            '，帖子=' + String(result.postCount) + '，等级=' + result.grade +
            '，关注=' + String(result.follows) + '，粉丝=' + String(result.fans));
        } catch (error) {
          Logger.warn('COMMUNITY_API', '文本兜底解析失败：' + String(error));
        }
      }
      return result;
    }
    // 兼容关闭 type=json 的后台：逐行解析“字段:值”文本。
    const lines: string[] = body.split('<br>');
    for (const line of lines) {
      const parts: string[] = line.split(':');
      if (parts.length < 2) {
        continue;
      }
      const key: string = parts[0].trim();
      const value: string = parts.slice(1).join(':').trim();
      if (key.indexOf('账号昵称') >= 0) { result.name = value; }
      else if (key.indexOf('账号等级') >= 0) { result.grade = value; }
      else if (key.indexOf('账号经验') >= 0) { result.exp = CommunityApi.numberValue(value); }
      else if (key.indexOf('金币数量') >= 0) { result.money = CommunityApi.numberValue(value); }
      else if (key.indexOf('用户签名') >= 0) { result.signature = value; }
      else if (key.indexOf('佩戴称号') >= 0) { result.chenhao = value; }
      else if (key.indexOf('封禁状态') >= 0) { result.seal = value; }
      else if (key.indexOf('注册时间') >= 0) { result.registerTime = value; }
      else if (key.indexOf('登录时间') >= 0) { result.loginTime = value; }
      else if (key.indexOf('会员状态') >= 0) { result.vipTime = value; }
      else if (key.indexOf('帖子数量') >= 0) { result.postCount = CommunityApi.numberValue(value); }
      else if (key.indexOf('粉丝') >= 0) { result.fans = CommunityApi.numberValue(value); }
      else if (key.indexOf('关注') >= 0) { result.follows = CommunityApi.numberValue(value); }
      else if (key.indexOf('用户头像') >= 0) { result.avatarUrl = CommunityApi.absoluteUrl(value); }
    }
    return result;
  }

  static async newsCount(session: CommunitySession): Promise<number> {
    if (!session.user.trim()) {
      return 0;
    }
    // 该接口必须同时带 admin 与 user，只传 admin 会返回“用户账号不存在”。
    const path: string = '/echonewsnum.php?' + CommunityApi.adminQuery() +
      '&user=' + encodeURIComponent(session.user);
    const body: string = await CommunityApi.requestText(path, '消息数量');
    const parsed: number = Number(body.trim());
    return Number.isFinite(parsed) ? Math.max(0, Math.trunc(parsed)) : 0;
  }

  static async onlineCount(): Promise<number> {
    const path: string = '/online_see.php?' + CommunityApi.adminQuery();
    const body: string = await CommunityApi.requestText(path, '在线统计');
    const match: RegExpMatchArray | null = body.match(/(\d+)/);
    if (match === null) {
      return 0;
    }
    const parsed: number = Number(match[1]);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 返回后台原始提示（签到成功 / 已签到 / 密码错误等），由页面按文案展示。 */
  static async signIn(session: CommunitySession): Promise<string> {
    const path: string = '/sign.php?' + CommunityApi.adminQuery() +
      '&user=' + encodeURIComponent(session.user) + '&pass=' + encodeURIComponent(session.pass);
    return (await CommunityApi.requestText(path, '每日签到')).trim();
  }

  static async remoteNotice(): Promise<string> {
    const path: string = '/echouser.php?' + CommunityApi.adminQuery() + '&file=notice';
    return (await CommunityApi.requestText(path, '远程公告')).trim();
  }

  static async remoteUpdate(): Promise<RemoteUpdate> {
    const path: string = '/echouser.php?' + CommunityApi.adminQuery() + '&file=new';
    const body: string = await CommunityApi.requestText(path, '版本更新');
    const update: RemoteUpdate = new RemoteUpdate();
    const version: string = CommunityApi.segment(body, '软件版本:(', ')');
    const content: string = CommunityApi.segment(body, '更新内容:(', ')');
    const link: string = CommunityApi.segment(body, '更新链接:(', ')');
    update.version = version || '最新版本';
    update.content = content || body.trim();
    update.link = link;
    return update;
  }

  // ---------------- 聊天室 ----------------

  private static chatBase(session: CommunitySession, action: string, room: string): string {
    return '/lts.php?' + CommunityApi.adminQuery() + '&action=' + encodeURIComponent(action) +
      '&chatroom=' + encodeURIComponent(room) +
      '&user=' + encodeURIComponent(session.user) +
      '&pass=' + encodeURIComponent(session.pass);
  }

  static async chatMessages(session: CommunitySession, room: string, page: number,
    size: number, lastMessageId: number): Promise<ChatPageResult> {
    let path: string = CommunityApi.chatBase(session, 'get', room) +
      '&page=' + String(Math.max(1, Math.trunc(page))) + '&size=' + String(Math.max(1, Math.min(200, Math.trunc(size))));
    if (lastMessageId > 0) {
      path += '&last_message_id=' + String(Math.trunc(lastMessageId));
    }
    const raw: RawChatResponse = await CommunityApi.requestJson<RawChatResponse>(path, '聊天室消息');
    if (raw.status === 'error') {
      throw new Error(raw.message || '聊天室消息获取失败');
    }
    const result: ChatPageResult = new ChatPageResult();
    result.page = CommunityApi.numberValue(raw.page) || page;
    result.total = CommunityApi.numberValue(raw.total);
    result.emptyText = raw.message || '';
    const list: RawChatMessage[] = raw.messages !== undefined ? raw.messages : [];
    for (const item of list) {
      const message: ChatMessage = new ChatMessage();
      message.id = CommunityApi.numberValue(item.id);
      message.user = CommunityApi.textValue(item.user);
      message.name = CommunityApi.textValue(item.name) || message.user;
      message.grade = CommunityApi.textValue(item.grade);
      message.vipTime = CommunityApi.textValue(item.viptime);
      message.time = CommunityApi.textValue(item.time);
      message.content = CommunityApi.textValue(item.message);
      message.replyTo = CommunityApi.numberValue(item.content_r);
      if (message.id > 0 || message.content.length > 0) {
        result.messages.push(message);
      }
    }
    return result;
  }

  static async sendChat(session: CommunitySession, room: string, message: string): Promise<number> {
    const path: string = CommunityApi.chatBase(session, 'send', room) + '&message=' + encodeURIComponent(message);
    const body: string = await CommunityApi.requestText(path, '发送消息');
    const text: string = body.trim();
    // 服务端部分房间返回文本「发送成功」而不是 JSON，这两种都按成功处理。
    if (text.startsWith('{')) {
      const raw: RawChatResponse = JSON.parse(text) as RawChatResponse;
      if (raw.status === 'error') {
        throw new Error(raw.message || '消息发送失败');
      }
      return CommunityApi.numberValue(raw.message_id);
    }
    if (text.indexOf('成功') >= 0) {
      Logger.info('COMMUNITY_API', '发送消息返回文本成功：' + text.substring(0, 40));
      return 1;
    }
    throw new Error(text.length > 0 ? text.substring(0, 60) : '消息发送失败');
  }

  static async revokeChat(session: CommunitySession, room: string, messageId: number): Promise<void> {
    const path: string = CommunityApi.chatBase(session, 'revoke', room) + '&message=' + String(Math.trunc(messageId));
    const raw: RawChatResponse = await CommunityApi.requestJson<RawChatResponse>(path, '撤回消息');
    if (raw.status === 'error') {
      throw new Error(raw.message || '撤回失败');
    }
  }

  // ---------------- 论坛 ----------------

  static async forumCategories(): Promise<ForumCategory[]> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=getCategoryList';
    const raw: RawForumCategoryResponse = await CommunityApi.requestJson<RawForumCategoryResponse>(path, '论坛板块');
    if (raw.error) {
      throw new Error(raw.error);
    }
    const result: ForumCategory[] = [];
    const list: RawForumCategory[] = raw.categoryList !== undefined ? raw.categoryList : [];
    for (const item of list) {
      const category: ForumCategory = new ForumCategory();
      category.id = CommunityApi.textValue(item.id);
      category.name = CommunityApi.textValue(item.name);
      category.description = CommunityApi.textValue(item.content);
      category.postCount = CommunityApi.numberValue(item.post_count);
      category.avatarUrl = CommunityApi.absoluteUrl(CommunityApi.textValue(item.avatar));
      if (category.name.length > 0) {
        result.push(category);
      }
    }
    return result;
  }

  private static mapPost(raw: RawForumPost): ForumPost {
    const post: ForumPost = new ForumPost();
    post.id = CommunityApi.textValue(raw.id);
    post.title = CommunityApi.textValue(raw.title);
    post.content = CommunityApi.textValue(raw.content);
    post.category = CommunityApi.textValue(raw.category);
    post.user = CommunityApi.textValue(raw.user);
    post.name = CommunityApi.textValue(raw.name) || post.user;
    post.grade = CommunityApi.textValue(raw.grade);
    post.time = CommunityApi.textValue(raw.time);
    post.views = CommunityApi.numberValue(raw.views);
    post.likes = CommunityApi.numberValue(raw.likes);
    post.comments = CommunityApi.numberValue(raw.comment_count);
    post.top = CommunityApi.boolValue(raw.top);
    post.essence = CommunityApi.boolValue(raw.essence);
    post.moderator = raw.is_moderator === true;
    return post;
  }

  static async forumPosts(category: string, page: number, query: string): Promise<ForumPageResult> {
    const keyword: string = query.trim();
    const action: string = keyword.length > 0 ? 'getSearch' : 'getPostList';
    let path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=' + action +
      '&page=' + String(Math.max(1, Math.trunc(page)));
    if (category.length > 0) {
      path += '&category=' + encodeURIComponent(category);
    }
    if (keyword.length > 0) {
      path += '&search=' + encodeURIComponent(keyword);
    }
    const raw: RawForumListResponse = await CommunityApi.requestJson<RawForumListResponse>(path, '论坛帖子');
    if (raw.error) {
      throw new Error(raw.error);
    }
    const result: ForumPageResult = new ForumPageResult();
    result.page = CommunityApi.numberValue(raw.currentPage) || page;
    result.totalPages = Math.max(1, CommunityApi.numberValue(raw.totalPages) || 1);
    const list: RawForumPost[] = raw.postList !== undefined ? raw.postList : [];
    for (const item of list) {
      result.posts.push(CommunityApi.mapPost(item));
    }
    return result;
  }

  static async forumPost(postId: string): Promise<ForumPost | undefined> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=viewPost&postId=' + encodeURIComponent(postId);
    const raw: RawForumDetailResponse = await CommunityApi.requestJson<RawForumDetailResponse>(path, '帖子详情');
    if (raw.error) {
      throw new Error(raw.error);
    }
    if (raw.postList !== undefined) {
      return CommunityApi.mapPost(raw.postList);
    }
    if (raw.post !== undefined) {
      return CommunityApi.mapPost(raw.post);
    }
    return undefined;
  }

  static async forumReplies(postId: string, page: number): Promise<ForumReplyResult> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=getReplyList&postId=' +
      encodeURIComponent(postId) + '&sort=time&page=' + String(Math.max(1, Math.trunc(page)));
    const raw: RawForumReplyResponse = await CommunityApi.requestJson<RawForumReplyResponse>(path, '帖子评论');
    if (raw.error) {
      throw new Error(raw.error);
    }
    const result: ForumReplyResult = new ForumReplyResult();
    result.total = CommunityApi.numberValue(raw.total);
    const list: RawForumReply[] = raw.replyList !== undefined ? raw.replyList : [];
    for (const item of list) {
      const reply: ForumReply = new ForumReply();
      reply.id = CommunityApi.textValue(item.id);
      reply.content = CommunityApi.textValue(item.content);
      reply.user = CommunityApi.textValue(item.user);
      reply.name = CommunityApi.textValue(item.name) || reply.user;
      reply.grade = CommunityApi.textValue(item.grade);
      reply.time = CommunityApi.textValue(item.time);
      reply.likes = CommunityApi.numberValue(item.likes);
      reply.replyTo = CommunityApi.numberValue(item.content_r);
      if (reply.id.length > 0) {
        result.replies.push(reply);
      }
    }
    return result;
  }

  private static actionMessage(raw: RawActionResult): string {
    if (raw.error) {
      return raw.error;
    }
    if (raw.status === 'error') {
      return raw.message || '操作失败';
    }
    return raw.message || '';
  }

  static async createPost(session: CommunitySession, category: string, title: string,
    content: string): Promise<string> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=createPost' +
      '&category=' + encodeURIComponent(category) +
      '&title=' + encodeURIComponent(title) +
      '&content=' + encodeURIComponent(content) +
      '&user=' + encodeURIComponent(session.user) +
      '&userpass=' + encodeURIComponent(session.pass);
    const raw: RawActionResult = await CommunityApi.requestJson<RawActionResult>(path, '发布帖子');
    return CommunityApi.actionMessage(raw);
  }

  static async replyPost(session: CommunitySession, postId: string, content: string,
    replyTo: number): Promise<string> {
    let path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=replyToPost' +
      '&postId=' + encodeURIComponent(postId) +
      '&content=' + encodeURIComponent(content) +
      '&user=' + encodeURIComponent(session.user) +
      '&userpass=' + encodeURIComponent(session.pass);
    if (replyTo > 0) {
      path += '&content_r=' + String(Math.trunc(replyTo));
    }
    const raw: RawActionResult = await CommunityApi.requestJson<RawActionResult>(path, '发布评论');
    return CommunityApi.actionMessage(raw);
  }

  static async likePost(session: CommunitySession, postId: string): Promise<string> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=likePost&postId=' +
      encodeURIComponent(postId) +
      '&user=' + encodeURIComponent(session.user) +
      '&userpass=' + encodeURIComponent(session.pass);
    const raw: RawActionResult = await CommunityApi.requestJson<RawActionResult>(path, '点赞帖子');
    return CommunityApi.actionMessage(raw);
  }

  static async deletePost(session: CommunitySession, postId: string): Promise<string> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=deletePost&postId=' +
      encodeURIComponent(postId) +
      '&user=' + encodeURIComponent(session.user) +
      '&userpass=' + encodeURIComponent(session.pass);
    const raw: RawActionResult = await CommunityApi.requestJson<RawActionResult>(path, '删除帖子');
    return CommunityApi.actionMessage(raw);
  }

  static async editPost(session: CommunitySession, postId: string, title: string,
    content: string): Promise<string> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=editPost&postId=' +
      encodeURIComponent(postId) +
      '&title=' + encodeURIComponent(title) +
      '&content=' + encodeURIComponent(content) +
      '&user=' + encodeURIComponent(session.user) +
      '&userpass=' + encodeURIComponent(session.pass);
    const raw: RawActionResult = await CommunityApi.requestJson<RawActionResult>(path, '修改帖子');
    return CommunityApi.actionMessage(raw);
  }

  static async myPosts(session: CommunitySession, page: number): Promise<ForumPageResult> {
    const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=getPostList_user&user=' +
      encodeURIComponent(session.user) + '&page=' + String(Math.max(1, Math.trunc(page)));
    const raw: RawForumListResponse = await CommunityApi.requestJson<RawForumListResponse>(path, '我的作品');
    if (raw.error) {
      throw new Error(raw.error);
    }
    const result: ForumPageResult = new ForumPageResult();
    result.page = CommunityApi.numberValue(raw.currentPage) || page;
    result.totalPages = Math.max(1, CommunityApi.numberValue(raw.totalPages) || 1);
    const list: RawForumPost[] = raw.postList !== undefined ? raw.postList : [];
    for (const item of list) {
      result.posts.push(CommunityApi.mapPost(item));
    }
    return result;
  }

  static avatarUrl(account: string): string {
    if (!account.trim()) {
      return '';
    }
    return CommunityApi.domain() + '/echoportrait.php?' + CommunityApi.adminQuery() +
      '&user=' + encodeURIComponent(account);
  }

  /** 按账号精确查询用户资料；用于加好友、资料页。 */
  static async queryUser(account: string): Promise<CommunityUser | undefined> {
    const keyword: string = account.trim();
    if (!keyword) {
      return undefined;
    }
    const path: string = '/userquery.php?' + CommunityApi.adminQuery() +
      '&query=' + encodeURIComponent(keyword) + '&type=json';
    const raw: RawQueryResponse = await CommunityApi.requestJson<RawQueryResponse>(path, '用户查询');
    const list: RawQueryUser[] = raw.data !== undefined ? raw.data : [];
    for (const item of list) {
      if (CommunityApi.textValue(item.username).trim() !== keyword) {
        continue;
      }
      const user: CommunityUser = new CommunityUser();
      user.userId = keyword;
      user.name = CommunityApi.textValue(item.name);
      user.grade = CommunityApi.textValue(item.grade);
      user.exp = CommunityApi.numberValue(item.exp);
      user.seal = CommunityApi.textValue(item.seal);
      user.money = CommunityApi.numberValue(item.money);
      user.signature = CommunityApi.textValue(item.autograph);
      user.chenhao = CommunityApi.textValue(item.chenhao);
      user.vipTime = CommunityApi.textValue(item.vip);
      user.qq = CommunityApi.textValue(item.qq);
      user.praise = CommunityApi.numberValue(item.praisenum);
      user.registerTime = CommunityApi.textValue(item.registertime);
      user.avatarUrl = CommunityApi.avatarUrl(keyword);
      return user;
    }
    return undefined;
  }

  static async spendCoins(session: CommunitySession, amount: number): Promise<string> {
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new Error('金币数量无效');
    }
    const path: string = '/moneyspend.php?' + CommunityApi.adminQuery() +
      '&user=' + encodeURIComponent(session.user) +
      '&pass=' + encodeURIComponent(session.pass) +
      '&num=' + String(Math.trunc(amount));
    return (await CommunityApi.requestText(path, '金币扣除')).trim();
  }

  static async banChat(session: CommunitySession, room: string, ban: boolean): Promise<string> {
    const path: string = CommunityApi.chatBase(session, 'ban', room) + '&ban=' + (ban ? 'true' : 'false');
    const raw: RawChatResponse = await CommunityApi.requestJson<RawChatResponse>(path, ban ? '全体禁言' : '解除全体禁言');
    if (raw.status === 'error') {
      throw new Error(raw.message || '操作失败');
    }
    return raw.message || '';
  }

  static async muteChat(session: CommunitySession, room: string, users: string,
    mute: boolean): Promise<string> {
    const path: string = CommunityApi.chatBase(session, mute ? 'mute' : 'unmute', room) +
      '&users=' + encodeURIComponent(users);
    const raw: RawChatResponse = await CommunityApi.requestJson<RawChatResponse>(path, mute ? '禁言用户' : '解除禁言');
    if (raw.status === 'error') {
      throw new Error(raw.message || '操作失败');
    }
    return raw.message || '';
  }

  /** 从论坛正文中提取最多 9 张图片 URL（兼容 JSON 富内容、img 标签与【imgN】标记）。 */
  static extractImages(content: string): string[] {
    if (ForumCodec.isJson(content)) {
      return ForumCodec.images(content);
    }
    const result: string[] = [];
    if (!content) {
      return result;
    }
    const marker: RegExp = /【img\d】\s*(https?:\/\/[^【\s]+)\s*【img\d】/gi;
    let match: RegExpExecArray | null = marker.exec(content);
    while (match !== null && result.length < 9) {
      if (result.indexOf(match[1]) < 0) {
        result.push(match[1]);
      }
      match = marker.exec(content);
    }
    const html: RegExp = /<img[^>]+src=["']([^"']+)["']/gi;
    match = html.exec(content);
    while (match !== null && result.length < 9) {
      if (result.indexOf(match[1]) < 0) {
        result.push(match[1]);
      }
      match = html.exec(content);
    }
    return result;
  }

  static extractVideos(content: string): string[] {
    if (ForumCodec.isJson(content)) {
      const result: string[] = [];
      for (const media of ForumCodec.videos(content)) {
        result.push(media.url);
      }
      return result;
    }
    const result: string[] = [];
    if (!content) {
      return result;
    }
    const marker: RegExp = /【video】\s*(https?:\/\/[^【\s]+)\s*【video】/gi;
    let match: RegExpExecArray | null = marker.exec(content);
    while (match !== null && result.length < 3) {
      result.push(match[1]);
      match = marker.exec(content);
    }
    return result;
  }

  /** 解析帖子正文：JSON 富内容 → 文本 + 媒体；旧标记格式同样解析。 */
  static forumContent(content: string): ForumContent {
    return ForumCodec.decode(content);
  }

  static paidPrice(content: string): number {
    if (ForumCodec.isJson(content)) {
      return ForumCodec.decode(content).price;
    }
    const match: RegExpMatchArray | null = content.match(/【paid[:：](\d+)】/);
    if (match === null) {
      return 0;
    }
    return CommunityApi.numberValue(match[1]);
  }

  static paidBody(content: string): string {
    if (ForumCodec.isJson(content)) {
      return ForumCodec.decode(content).paid;
    }
    const match: RegExpMatchArray | null = content.match(/【paid[:：]\d+】([\s\S]*?)【\/paid】/);
    return match === null ? '' : match[1];
  }

  static freeBody(content: string): string {
    if (ForumCodec.isJson(content)) {
      return ForumCodec.decode(content).text;
    }
    return content.replace(/【paid[:：]\d+】[\s\S]*?【\/paid】/g, '').trim();
  }

  static async increaseViews(postId: string): Promise<void> {
    try {
      const path: string = '/bbs.php?' + CommunityApi.adminQuery() + '&action=increaseViews&postId=' +
        encodeURIComponent(postId);
      await CommunityApi.requestText(path, '浏览计数');
    } catch (error) {
      Logger.warn('COMMUNITY_FORUM', '浏览计数失败（不影响阅读）：' + String(error));
    }
  }

  /** 把论坛正文里的 HTML 与图片/视频占位符转成纯文本，避免 Text 组件显示尖括号。 */
  static plainText(content: string): string {
    if (!content) {
      return '';
    }
    let result: string = content;
    result = result.replace(/<br\s*\/?>/gi, '\n');
    result = result.replace(/<[^>]+>/g, '');
    result = result.replace(/&nbsp;/g, ' ');
    result = result.replace(/&amp;/g, '&');
    result = result.replace(/&lt;/g, '<');
    result = result.replace(/&gt;/g, '>');
    result = result.replace(/【img\d】null【img\d】/g, '[图片]');
    result = result.replace(/【video】/g, '[视频] ');
    result = result.replace(/【img\d】/g, '');
    return result.trim();
  }
}

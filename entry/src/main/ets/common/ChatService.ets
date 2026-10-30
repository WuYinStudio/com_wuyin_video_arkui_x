import { ChatCard, MediaCodec } from './MediaCodec';
import { ChatMessage, CommunityApi, CommunitySession } from './CommunityApi';
import { FriendItem, RoomItem, SocialStore } from './SocialStore';
import { Logger } from './Logger';

/**
 * 聊天室 / 私聊 / 好友申请的轻量业务层。
 *
 * 云逸文档只有 lts.php 的房间消息接口，没有独立的好友接口：
 * - 官方群、创建的房间直接使用 lts.php 的房间名；
 * - 私聊使用固定的双人房间名；
 * - 好友申请/通过/拒绝写入对方的“好友申请_账号”房间，由客户端轮询处理。
 */
export class ChatService {
  static readonly OFFICIAL_ROOM: string = '官方群聊';

  static privateRoom(first: string, second: string): string {
    const a: string = first.trim();
    const b: string = second.trim();
    return a <= b ? '私聊_' + a + '_' + b : '私聊_' + b + '_' + a;
  }

  static requestRoom(account: string): string {
    return '好友申请_' + account.trim();
  }

  static async lastMessage(session: CommunitySession, room: string): Promise<ChatMessage | undefined> {
    const result = await CommunityApi.chatMessages(session, room, 1, 50, 0);
    return result.messages.length > 0 ? result.messages[result.messages.length - 1] : undefined;
  }

  static async unreadCount(session: CommunitySession, room: string): Promise<number> {
    try {
      const result = await CommunityApi.chatMessages(session, room, 1, 50, SocialStore.lastRead(room));
      return result.messages.length;
    } catch (error) {
      Logger.warn('CHAT_SERVICE', '读取未读数失败：' + String(error));
      return 0;
    }
  }

  static async refreshRoomSummary(session: CommunitySession, room: RoomItem): Promise<void> {
    try {
      const last: ChatMessage | undefined = await ChatService.lastMessage(session, room.name);
      const unread: number = await ChatService.unreadCount(session, room.name);
      const card: ChatCard | undefined = last !== undefined ? MediaCodec.decode(last.content) : undefined;
      SocialStore.touchRoom(room.name, card !== undefined ? MediaCodec.preview(card) :
        (last !== undefined ? last.content : room.lastMessage),
        last !== undefined ? last.time : room.lastTime, unread);
    } catch (error) {
      Logger.warn('CHAT_SERVICE', '刷新房间摘要失败：' + room.name + '，' + String(error));
    }
  }

  static async refreshFriendSummary(session: CommunitySession, friend: FriendItem): Promise<void> {
    try {
      const room: string = ChatService.privateRoom(session.user, friend.account);
      const last: ChatMessage | undefined = await ChatService.lastMessage(session, room);
      const unread: number = await ChatService.unreadCount(session, room);
      const card: ChatCard | undefined = last !== undefined ? MediaCodec.decode(last.content) : undefined;
      const updated: FriendItem = new FriendItem();
      updated.account = friend.account;
      updated.name = friend.name;
      updated.avatar = friend.avatar;
      updated.grade = friend.grade;
      updated.signature = friend.signature;
      updated.lastMessage = card !== undefined ? MediaCodec.preview(card) : (last !== undefined ? last.content : friend.lastMessage);
      updated.lastTime = last !== undefined ? last.time : friend.lastTime;
      updated.unread = unread;
      SocialStore.upsertFriend(updated);
    } catch (error) {
      Logger.warn('CHAT_SERVICE', '刷新好友摘要失败：' + friend.account + '，' + String(error));
    }
  }

  static async sendFriendRequest(session: CommunitySession, target: string, senderName: string): Promise<void> {
    const card: ChatCard = new ChatCard();
    card.kind = 'friend_request';
    card.target = target;
    card.fromName = senderName;
    card.time = new Date().toISOString();
    await CommunityApi.sendChat(session, ChatService.requestRoom(target), MediaCodec.encode(card));
    Logger.info('CHAT_SERVICE', '好友申请已发送：' + target);
  }

  static async sendFriendResponse(session: CommunitySession, target: string, accepted: boolean,
    senderName: string): Promise<void> {
    const card: ChatCard = new ChatCard();
    card.kind = accepted ? 'friend_accept' : 'friend_reject';
    card.target = target;
    card.fromName = senderName;
    card.time = new Date().toISOString();
    await CommunityApi.sendChat(session, ChatService.requestRoom(target), MediaCodec.encode(card));
    Logger.info('CHAT_SERVICE', '好友申请响应已发送：' + target + '，通过=' + String(accepted));
  }

  static async requestEvents(session: CommunitySession): Promise<ChatMessage[]> {
    const result = await CommunityApi.chatMessages(session, ChatService.requestRoom(session.user), 1, 50, 0);
    return result.messages;
  }

  static async onlineCount(): Promise<number> {
    return CommunityApi.onlineCount();
  }
}

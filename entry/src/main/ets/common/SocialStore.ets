import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

export class FriendItem {
  account: string = '';
  name: string = '';
  avatar: string = '';
  grade: string = '';
  signature: string = '';
  lastMessage: string = '';
  lastTime: string = '';
  unread: number = 0;
}

export class FriendRequestItem {
  from: string = '';
  name: string = '';
  time: string = '';
  kind: string = 'request';
}

export class RoomItem {
  name: string = '';
  avatar: string = '';
  intro: string = '';
  official: boolean = false;
  owner: string = '';
  lastMessage: string = '';
  lastTime: string = '';
  unread: number = 0;
}

export class SystemItem {
  id: string = '';
  title: string = '';
  content: string = '';
  time: string = '';
  read: boolean = false;
}

class ReadState {
  room: string = '';
  messageId: number = 0;
}

/**
 * 本地社交资料：好友、好友申请、聊天室、黑名单、已读位置、帖子收藏/解锁。
 *
 * 好友关系没有独立的云逸接口，这里用 lts.php 的“好友申请_账号”房间传递申请/通过消息，
 * 把最终关系与已读位置保存在本机 preferences；私聊消息本身仍完整保存在 lts.php 私聊房间。
 */
export class SocialStore {
  static readonly OFFICIAL_ROOM: string = '官方群聊';
  private static store?: preferences.Preferences;
  private static initialized: boolean = false;
  private static persistence: Promise<void> = Promise.resolve();

  static friends: FriendItem[] = [];
  static requests: FriendRequestItem[] = [];
  static rooms: RoomItem[] = [];
  static systems: SystemItem[] = [];
  static blocks: string[] = [];
  static unlocks: string[] = [];
  static favorites: string[] = [];
  private static reads: ReadState[] = [];

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (SocialStore.initialized) {
      return;
    }
    try {
      SocialStore.store = await preferences.getPreferences(context, 'wuyin');
      SocialStore.friends = SocialStore.parseFriends(String(await SocialStore.store.get('socialFriends', '[]')));
      SocialStore.requests = SocialStore.parseRequests(String(await SocialStore.store.get('socialRequests', '[]')));
      SocialStore.rooms = SocialStore.parseRooms(String(await SocialStore.store.get('socialRooms', '[]')));
      SocialStore.systems = SocialStore.parseSystems(String(await SocialStore.store.get('socialSystems', '[]')));
      SocialStore.blocks = SocialStore.parseStrings(String(await SocialStore.store.get('socialBlocks', '[]')));
      SocialStore.unlocks = SocialStore.parseStrings(String(await SocialStore.store.get('socialUnlocks', '[]')));
      SocialStore.favorites = SocialStore.parseStrings(String(await SocialStore.store.get('socialFavorites', '[]')));
      SocialStore.reads = SocialStore.parseReads(String(await SocialStore.store.get('socialReads', '[]')));
      SocialStore.ensureOfficialRoom();
      SocialStore.initialized = true;
      SocialStore.publishVersion();
      Logger.info('SOCIAL_STORE', '本地社交资料已恢复，好友=' + String(SocialStore.friends.length) +
        '，房间=' + String(SocialStore.rooms.length));
    } catch (error) {
      Logger.error('SOCIAL_STORE', '读取本地社交资料失败：' + String(error));
    }
  }

  static isReady(): boolean {
    return SocialStore.initialized;
  }

  static friendsList(): FriendItem[] {
    return SocialStore.friends.slice();
  }

  static friend(account: string): FriendItem | undefined {
    return SocialStore.friends.find((item: FriendItem) => item.account === account);
  }

  static upsertFriend(item: FriendItem): void {
    SocialStore.friends = SocialStore.friends.filter((value: FriendItem) => value.account !== item.account);
    SocialStore.friends.push(item);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static removeFriend(account: string): void {
    SocialStore.friends = SocialStore.friends.filter((item: FriendItem) => item.account !== account);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static requestsList(): FriendRequestItem[] {
    return SocialStore.requests.slice();
  }

  static addRequest(item: FriendRequestItem): void {
    if (!item.from || item.from === '') {
      return;
    }
    const exists: boolean = SocialStore.requests.some((value: FriendRequestItem) =>
      value.from === item.from && value.kind === item.kind);
    if (exists) {
      return;
    }
    SocialStore.requests.push(item);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static removeRequest(from: string, kind: string): void {
    SocialStore.requests = SocialStore.requests.filter((item: FriendRequestItem) =>
      !(item.from === from && item.kind === kind));
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static roomsList(): RoomItem[] {
    SocialStore.ensureOfficialRoom();
    return SocialStore.rooms.slice();
  }

  static room(name: string): RoomItem | undefined {
    return SocialStore.rooms.find((item: RoomItem) => item.name === name);
  }

  static addRoom(item: RoomItem): void {
    if (!item.name.trim()) {
      return;
    }
    SocialStore.rooms = SocialStore.rooms.filter((value: RoomItem) => value.name !== item.name);
    SocialStore.rooms.push(item);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static removeRoom(name: string): void {
    if (name === SocialStore.OFFICIAL_ROOM) {
      return;
    }
    SocialStore.rooms = SocialStore.rooms.filter((item: RoomItem) => item.name !== name);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static touchRoom(name: string, lastMessage: string, lastTime: string, unread: number): void {
    const found: RoomItem | undefined = SocialStore.room(name);
    if (!found) {
      return;
    }
    found.lastMessage = lastMessage;
    found.lastTime = lastTime;
    found.unread = Math.max(0, Math.trunc(unread));
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static setRoomUnread(name: string, unread: number): void {
    const found: RoomItem | undefined = SocialStore.room(name);
    if (!found) {
      return;
    }
    found.unread = Math.max(0, Math.trunc(unread));
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static systemsList(): SystemItem[] {
    return SocialStore.systems.slice();
  }

  static upsertSystem(item: SystemItem): void {
    const old: SystemItem | undefined = SocialStore.systems.find((value: SystemItem) => value.id === item.id);
    if (old !== undefined) {
      item.read = old.read;
      SocialStore.systems = SocialStore.systems.filter((value: SystemItem) => value.id !== item.id);
    }
    SocialStore.systems.push(item);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static markSystemRead(id: string): void {
    const found: SystemItem | undefined = SocialStore.systems.find((item: SystemItem) => item.id === id);
    if (found === undefined || found.read) {
      return;
    }
    found.read = true;
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static systemUnread(): number {
    return SocialStore.systems.filter((item: SystemItem) => !item.read).length;
  }

  static blocksList(): string[] {
    return SocialStore.blocks.slice();
  }

  static isBlocked(account: string): boolean {
    return SocialStore.blocks.includes(account);
  }

  static block(account: string): void {
    if (!account || SocialStore.blocks.includes(account)) {
      return;
    }
    SocialStore.blocks.push(account);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static unblock(account: string): void {
    SocialStore.blocks = SocialStore.blocks.filter((item: string) => item !== account);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static markRead(room: string, messageId: number): void {
    if (!room || !Number.isFinite(messageId) || messageId <= 0) {
      return;
    }
    const found: ReadState | undefined = SocialStore.reads.find((item: ReadState) => item.room === room);
    if (found !== undefined) {
      if (messageId <= found.messageId) {
        return;
      }
      found.messageId = Math.trunc(messageId);
    } else {
      const state: ReadState = new ReadState();
      state.room = room;
      state.messageId = Math.trunc(messageId);
      SocialStore.reads.push(state);
    }
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static lastRead(room: string): number {
    const found: ReadState | undefined = SocialStore.reads.find((item: ReadState) => item.room === room);
    return found !== undefined ? found.messageId : 0;
  }

  static unlock(postId: string): void {
    if (!postId || SocialStore.unlocks.includes(postId)) {
      return;
    }
    SocialStore.unlocks.push(postId);
    SocialStore.save();
    SocialStore.publishVersion();
  }

  static isUnlocked(postId: string): boolean {
    return SocialStore.unlocks.includes(postId);
  }

  static toggleFavorite(postId: string): boolean {
    const selected: boolean = !SocialStore.favorites.includes(postId);
    SocialStore.favorites = selected
      ? SocialStore.favorites.concat([postId])
      : SocialStore.favorites.filter((item: string) => item !== postId);
    SocialStore.save();
    SocialStore.publishVersion();
    return selected;
  }

  static isFavorite(postId: string): boolean {
    return SocialStore.favorites.includes(postId);
  }

  static totalRoomUnread(): number {
    let total: number = 0;
    for (const item of SocialStore.rooms) {
      total += Math.max(0, item.unread);
    }
    return total;
  }

  static totalFriendUnread(): number {
    let total: number = 0;
    for (const item of SocialStore.friends) {
      total += Math.max(0, item.unread);
    }
    return total;
  }

  private static ensureOfficialRoom(): void {
    if (SocialStore.rooms.some((item: RoomItem) => item.name === SocialStore.OFFICIAL_ROOM)) {
      return;
    }
    const official: RoomItem = new RoomItem();
    official.name = SocialStore.OFFICIAL_ROOM;
    official.intro = '无音影视官方交流群';
    official.official = true;
    official.owner = '官方';
    SocialStore.rooms.unshift(official);
  }

  private static publishVersion(): void {
    const current: number = AppStorage.get<number>('socialVersion') || 0;
    AppStorage.setOrCreate<number>('socialVersion', current + 1);
  }

  private static save(): void {
    const snapshotFriends: string = JSON.stringify(SocialStore.friends);
    const snapshotRequests: string = JSON.stringify(SocialStore.requests);
    const snapshotRooms: string = JSON.stringify(SocialStore.rooms);
    const snapshotSystems: string = JSON.stringify(SocialStore.systems);
    const snapshotBlocks: string = JSON.stringify(SocialStore.blocks);
    const snapshotUnlocks: string = JSON.stringify(SocialStore.unlocks);
    const snapshotFavorites: string = JSON.stringify(SocialStore.favorites);
    const snapshotReads: string = JSON.stringify(SocialStore.reads);
    SocialStore.persistence = SocialStore.persistence.then(async () => {
      try {
        const store: preferences.Preferences | undefined = SocialStore.store;
        if (store === undefined) {
          return;
        }
        await store.put('socialFriends', snapshotFriends);
        await store.put('socialRequests', snapshotRequests);
        await store.put('socialRooms', snapshotRooms);
        await store.put('socialSystems', snapshotSystems);
        await store.put('socialBlocks', snapshotBlocks);
        await store.put('socialUnlocks', snapshotUnlocks);
        await store.put('socialFavorites', snapshotFavorites);
        await store.put('socialReads', snapshotReads);
        await store.flush();
      } catch (error) {
        Logger.error('SOCIAL_STORE', '保存本地社交资料失败：' + String(error));
      }
    });
  }

  private static parseStrings(raw: string): string[] {
    try {
      const value: string[] = JSON.parse(raw) as string[];
      return Array.isArray(value) ? value.filter((item: string) => typeof item === 'string' && item.length > 0) : [];
    } catch (error) {
      return [];
    }
  }

  private static parseFriends(raw: string): FriendItem[] {
    try {
      const value: FriendItem[] = JSON.parse(raw) as FriendItem[];
      if (!Array.isArray(value)) {
        return [];
      }
      const result: FriendItem[] = [];
      for (const item of value) {
        const friend: FriendItem = new FriendItem();
        friend.account = typeof item.account === 'string' ? item.account : '';
        friend.name = typeof item.name === 'string' ? item.name : friend.account;
        friend.avatar = typeof item.avatar === 'string' ? item.avatar : '';
        friend.grade = typeof item.grade === 'string' ? item.grade : '';
        friend.signature = typeof item.signature === 'string' ? item.signature : '';
        friend.lastMessage = typeof item.lastMessage === 'string' ? item.lastMessage : '';
        friend.lastTime = typeof item.lastTime === 'string' ? item.lastTime : '';
        friend.unread = Number.isFinite(Number(item.unread)) ? Number(item.unread) : 0;
        if (friend.account.length > 0) {
          result.push(friend);
        }
      }
      return result;
    } catch (error) {
      return [];
    }
  }

  private static parseRequests(raw: string): FriendRequestItem[] {
    try {
      const value: FriendRequestItem[] = JSON.parse(raw) as FriendRequestItem[];
      if (!Array.isArray(value)) {
        return [];
      }
      const result: FriendRequestItem[] = [];
      for (const item of value) {
        const request: FriendRequestItem = new FriendRequestItem();
        request.from = typeof item.from === 'string' ? item.from : '';
        request.name = typeof item.name === 'string' ? item.name : request.from;
        request.time = typeof item.time === 'string' ? item.time : '';
        request.kind = typeof item.kind === 'string' ? item.kind : 'request';
        if (request.from.length > 0) {
          result.push(request);
        }
      }
      return result;
    } catch (error) {
      return [];
    }
  }

  private static parseRooms(raw: string): RoomItem[] {
    try {
      const value: RoomItem[] = JSON.parse(raw) as RoomItem[];
      if (!Array.isArray(value)) {
        return [];
      }
      const result: RoomItem[] = [];
      for (const item of value) {
        const room: RoomItem = new RoomItem();
        room.name = typeof item.name === 'string' ? item.name : '';
        room.avatar = typeof item.avatar === 'string' ? item.avatar : '';
        room.intro = typeof item.intro === 'string' ? item.intro : '';
        room.official = item.official === true || room.name === SocialStore.OFFICIAL_ROOM;
        room.owner = typeof item.owner === 'string' ? item.owner : '';
        room.lastMessage = typeof item.lastMessage === 'string' ? item.lastMessage : '';
        room.lastTime = typeof item.lastTime === 'string' ? item.lastTime : '';
        room.unread = Number.isFinite(Number(item.unread)) ? Number(item.unread) : 0;
        if (room.name.length > 0) {
          result.push(room);
        }
      }
      return result;
    } catch (error) {
      return [];
    }
  }

  private static parseSystems(raw: string): SystemItem[] {
    try {
      const value: SystemItem[] = JSON.parse(raw) as SystemItem[];
      if (!Array.isArray(value)) {
        return [];
      }
      const result: SystemItem[] = [];
      for (const item of value) {
        const system: SystemItem = new SystemItem();
        system.id = typeof item.id === 'string' ? item.id : '';
        system.title = typeof item.title === 'string' ? item.title : '系统消息';
        system.content = typeof item.content === 'string' ? item.content : '';
        system.time = typeof item.time === 'string' ? item.time : '';
        system.read = item.read === true;
        if (system.id.length > 0) {
          result.push(system);
        }
      }
      return result;
    } catch (error) {
      return [];
    }
  }

  private static parseReads(raw: string): ReadState[] {
    try {
      const value: ReadState[] = JSON.parse(raw) as ReadState[];
      if (!Array.isArray(value)) {
        return [];
      }
      const result: ReadState[] = [];
      for (const item of value) {
        const state: ReadState = new ReadState();
        state.room = typeof item.room === 'string' ? item.room : '';
        state.messageId = Number.isFinite(Number(item.messageId)) ? Number(item.messageId) : 0;
        if (state.room.length > 0) {
          result.push(state);
        }
      }
      return result;
    } catch (error) {
      return [];
    }
  }
}

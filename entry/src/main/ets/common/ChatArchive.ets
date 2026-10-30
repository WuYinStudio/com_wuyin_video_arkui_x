import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { CommunityApi, ChatMessage } from './CommunityApi';
import { Logger } from './Logger';

/** 单个会话的消息集合（群聊用 room，私聊用 account）。 */
export class ArchivedChat {
  key: string = '';
  title: string = '';
  messages: ChatMessage[] = [];
}

/** 导出/导入的整包结构。 */
export class ChatArchiveBundle {
  version: number = 1;
  exportedAt: string = '';
  rooms: ArchivedChat[] = [];
  peers: ArchivedChat[] = [];
}

/**
 * 聊天记录本地归档：按会话分 key 存在 preferences('chat_archive')，
 * 支持导出成 JSON 文件（文件选择器保存到用户目录）与导入合并。
 */
export class ChatArchive {
  private static readonly PREF: string = 'chat_archive';
  private static store?: preferences.Preferences;
  private static readonly PREFIX: string = 'chat_';

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (ChatArchive.store !== undefined) { return; }
    try {
      ChatArchive.store = await preferences.getPreferences(context, ChatArchive.PREF);
    } catch (error) {
      Logger.error('CHAT_ARCHIVE', '初始化归档存储失败：' + String(error));
    }
  }

  private static keyOf(kind: string, name: string): string {
    return ChatArchive.PREFIX + kind + '_' + name;
  }

  /** 保存某个会话的最近消息（最多保留 200 条）。 */
  static async save(kind: string, name: string, messages: ChatMessage[]): Promise<void> {
    const store: preferences.Preferences | undefined = ChatArchive.store;
    if (store === undefined) { return; }
    try {
      const archived: ArchivedChat = new ArchivedChat();
      archived.key = name;
      archived.title = name;
      archived.messages = messages.slice(Math.max(0, messages.length - 200));
      await store.put(ChatArchive.keyOf(kind, name), JSON.stringify(archived));
      await store.flush();
    } catch (error) {
      Logger.warn('CHAT_ARCHIVE', '保存聊天记录失败：' + String(error));
    }
  }

  /** 读取某个会话的本地消息。 */
  static async load(kind: string, name: string): Promise<ChatMessage[]> {
    const store: preferences.Preferences | undefined = ChatArchive.store;
    if (store === undefined) { return []; }
    try {
      const raw: string = String(await store.get(ChatArchive.keyOf(kind, name), ''));
      if (raw.length === 0) { return []; }
      const archived: ArchivedChat = JSON.parse(raw) as ArchivedChat;
      return archived.messages !== undefined ? archived.messages : [];
    } catch (error) {
      Logger.warn('CHAT_ARCHIVE', '读取本地聊天记录失败：' + String(error));
      return [];
    }
  }

  /** 导出全部会话为 JSON 文件，返回文件路径（用户取消返回空串）。 */
  static async exportAll(context: common.UIAbilityContext, roomNames: string[], peerAccounts: string[]): Promise<string> {
    try {
      await ChatArchive.init(context);
      const bundle: ChatArchiveBundle = new ChatArchiveBundle();
      bundle.version = 1;
      bundle.exportedAt = new Date().toISOString();
      for (const room of roomNames) {
        const archived: ArchivedChat = new ArchivedChat();
        archived.key = room;
        archived.title = room;
        archived.messages = await ChatArchive.load('room', room);
        if (archived.messages.length > 0) { bundle.rooms.push(archived); }
      }
      for (const peer of peerAccounts) {
        const archived: ArchivedChat = new ArchivedChat();
        archived.key = peer;
        archived.title = peer;
        archived.messages = await ChatArchive.load('peer', peer);
        if (archived.messages.length > 0) { bundle.peers.push(archived); }
      }
      const json: string = JSON.stringify(bundle);
      // 让用户选择保存位置（默认 Download）
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      const stamp: string = String(Date.now());
      options.newFileNames = ['无音影视聊天记录_' + stamp + '.json'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) { return ''; }
      const target: string = uris[0];
      const file: fileIo.File = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.writeSync(file.fd, json);
      } finally {
        fileIo.closeSync(file);
      }
      Logger.info('CHAT_ARCHIVE', '聊天记录已导出：' + target);
      return target;
    } catch (error) {
      Logger.error('CHAT_ARCHIVE', '导出聊天记录失败：' + String(error));
      throw new Error('导出失败：' + String(error));
    }
  }

  /** 导入 JSON 文件并合并到本地归档。 */
  static async importFrom(context: common.UIAbilityContext): Promise<number> {
    try {
      await ChatArchive.init(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) { return 0; }
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        const bytes: Uint8Array = new Uint8Array(buffer).slice(0, read > 0 ? read : stat.size);
        text = String.fromCharCode(...Array.from(bytes));
      } finally {
        fileIo.closeSync(file);
      }
      const bundle: ChatArchiveBundle = JSON.parse(text) as ChatArchiveBundle;
      let merged: number = 0;
      const store: preferences.Preferences | undefined = ChatArchive.store;
      if (store === undefined) { return 0; }
      for (const room of bundle.rooms) {
        const existing: ChatMessage[] = await ChatArchive.load('room', room.key);
        const combined: ChatMessage[] = ChatArchive.merge(existing, room.messages);
        if (combined.length > existing.length) { merged++; }
        const archived: ArchivedChat = new ArchivedChat();
        archived.key = room.key;
        archived.title = room.title;
        archived.messages = combined;
        await store.put(ChatArchive.keyOf('room', room.key), JSON.stringify(archived));
      }
      for (const peer of bundle.peers) {
        const existing: ChatMessage[] = await ChatArchive.load('peer', peer.key);
        const combined: ChatMessage[] = ChatArchive.merge(existing, peer.messages);
        if (combined.length > existing.length) { merged++; }
        const archived: ArchivedChat = new ArchivedChat();
        archived.key = peer.key;
        archived.title = peer.title;
        archived.messages = combined;
        await store.put(ChatArchive.keyOf('peer', peer.key), JSON.stringify(archived));
      }
      await store.flush();
      Logger.info('CHAT_ARCHIVE', '聊天记录导入完成，更新会话数=' + String(merged));
      return merged;
    } catch (error) {
      Logger.error('CHAT_ARCHIVE', '导入聊天记录失败：' + String(error));
      throw new Error('导入失败：' + String(error));
    }
  }

  /** 合并两组消息，按 id + time 去重后按时间排序。 */
  private static merge(first: ChatMessage[], second: ChatMessage[]): ChatMessage[] {
    const result: ChatMessage[] = [];
    const push = (message: ChatMessage): void => {
      const exists: boolean = result.some((item: ChatMessage) =>
        item.id === message.id && item.time === message.time && item.content === message.content);
      if (!exists) { result.push(message); }
    };
    for (const message of first) { push(message); }
    for (const message of second) { push(message); }
    return result;
  }
}

/**
 * ArkUI-X 对部分 socket 事件接口未开放编译声明，但运行时对象仍提供
 * on/off/close。这里用最小结构避免直接触发平台 API 校验。
 */
export interface SocketLike {
  on(event: string, callback: Object): void;
  off(event: string, callback?: Object): void;
}

export function asSocketLike(value: Object): SocketLike {
  return value as SocketLike;
}

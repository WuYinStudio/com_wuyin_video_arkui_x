import { router } from '@kit.ArkUI';
import { PlatformApi } from './PlatformApi';

/**
 * router.replaceUrl 的跨平台入口（保持原调用点不变）。
 *
 * HarmonyOS 走原生 replaceUrl（行为与改造前一致）；Android/iOS 因 ArkUI-X 未提供该接口，
 * 退化为「压栈 + 清空历史」——新页面成为栈内唯一页面，返回键不会回到被替换的页面。
 */
export function replaceRoute(options: router.RouterOptions): Promise<void> {
  return PlatformApi.replaceRoute(options);
}

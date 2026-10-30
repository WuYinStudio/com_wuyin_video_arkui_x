import { Want } from '@kit.AbilityKit';

/**
 * Want 的 action / uri 读取适配。
 *
 * ArkUI-X 的 Want 类型没有声明 action / uri（直接访问会被编译器以 11706007 拒绝），
 * 但平台壳（Android StageActivity / iOS launchOptions）通常仍会把它们放进 Want 对象。
 * 这里通过 JSON 中转读取，读不到时返回空串，调用方维持原有的“参数缺失”分支。
 */
function readString(want: Want, key: string): string {
  try {
    const map: Record<string, Object> = JSON.parse(JSON.stringify(want)) as Record<string, Object>;
    const value: Object | undefined = map[key];
    return typeof value === 'string' ? value as string : '';
  } catch (error) {
    return '';
  }
}

export function wantAction(want: Want): string {
  return readString(want, 'action');
}

export function wantUri(want: Want): string {
  return readString(want, 'uri');
}

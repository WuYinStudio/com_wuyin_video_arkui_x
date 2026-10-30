# 无音影视 v1.7.8：外部打开协播同步分享 TXT

## 变更
- EntryAbility 注册 `ohos.want.action.viewData` + `file` + `general.text/general.plain-text`，使系统可将文本文件列为打开目标。
- 对 `viewData` 且 URI 后缀为 `.txt` 的文件，读取 UTF-8 文本（上限 2 MiB），去除 UTF-8 BOM，并将原文送入现有协播分享 JSON 校验和播放器入会链路。
- 原有 ShareKit `sendData`、`wuyin://player` 普通分享路径保持不变。
- 读取失败、空文件、超限文件会记录日志并提示重新通过“打开方式”选择。

## TXT 内容约定
TXT 文件应直接包含无音影视协播邀请的完整 JSON 对象（不是说明文字或普通播放链接）。文件 URI 的实际授权、打开方式列表和最终编译行为仍需在目标 HarmonyOS SDK 与真机上验证。

# 无音影视 v1.7.8 — 华为分享协播 JSON 接收修复

## 本次修复

- `EntryAbility` 注册 `ohos.want.action.sendData` 文本接收规则，覆盖 ShareKit 直接唤起 UIAbility 的分发路径。
- `EntryAbility.captureSharedWant()` 在 `share_data` 没有直接以字符串暴露时，调用官方 `systemShare.getSharedData(want)` 读取 `SharedRecord.content`，再进入原有协播 JSON 校验与 PlayerPage 路由。
- 保留 `ShareExtensionAbility` 接收详情页路径，扩展同样优先读取 `getSharedData(want)`，随后将原始文本交给 `EntryAbility`。
- 发送端使用 `UniformDataType.TEXT`，接收规则兼容 `general.text` 与 `general.plain-text`。
- 不二次序列化业务 JSON，不猜测 `data` / `payload` 嵌套字段，不改写 `sessionId`、`videoJson`、集数或进度。
- 添加日志，区分“系统是否唤起目标组件”“ShareKit 是否返回文本记录”“顶层 JSON 是否通过校验”“PlayerPage 是否开始路由”。

## 重要平台行为限制

华为分享中的“分享给另一台设备”和“分享给目标应用”是不同投递路径。系统纯文本跨设备传输可能会保存为 `.txt` 文件，而不是在接收设备上直接唤起无音影视。因此：

- 如果分享面板选择的是**接收设备上的无音影视应用**，本补丁为应用接收路径增加了 UIAbility 和 ShareExtensionAbility 两个入口。
- 如果选择的是**另一台设备本身**，系统仅把文本保存为文件，则不会因为应用声明了分享接收能力而自动启动无音影视。该路径还需要用户在接收设备打开/导入文件，或改用已建立的协播传输通道直接发送邀请。

## 验证状态

- 已用 JSON5 解析器验证 `entry/src/main/module.json5` 语法有效。
- 已静态检查接收入口、`getSharedData(want)` 调用和路由调用存在。
- 当前执行环境没有 DevEco Studio / 官方 API 26 SDK，因此**未声称 ArkTS 编译通过**；也没有两台真机测试。

## 双设备测试日志顺序

发送端应出现：`ShareKit.show 请求已返回`。

接收端应用作为目标时，应出现：`UIAbility 经 ShareKit 提取的原始分享文本` 或 `通过 getSharedData 收到记录数`、`华为分享完整原始载荷`、`顶层解析完成`、`已校验系统分享会话邀请`、`正在交接协播页面`。

若接收设备只生成 `.txt` 文件且完全没有上述接收日志，说明本次投递走的是“设备文件传输”而不是“应用接收”路径，不能通过 JSON.parse 修复，需要打开/导入该文件或改走协播网络通道。

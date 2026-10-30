# 协播解析失败修复说明

本补丁针对华为分享收到文本后在业务解析阶段失败的常见原因：
- 兼容 ShareKit 文本记录被额外 JSON 字符串编码一层的情况；只解开字符串包装，不接受任意 data/payload 嵌套。
- 兼容旧邀请缺少 syncMode 时按 lan 处理。
- 允许 lan/server 两种已支持模式；server 模式必须带有效 ws/wss 信令地址。
- 放宽系统生成的 sessionId 字符集限制，只拒绝控制字符和超长值，保留原始 ID。
- 增强错误日志，尽量显示具体失败阶段。

尚需使用 DevEco Studio 官方 SDK 编译，并用两台同签名真机实际执行“创建会话 -> 华为分享 -> 接收 -> 播放页 -> 入会”。此补丁不代表真机验证已通过。


## 二次排查补充
发现 PlayerPage 仍使用 /^[A-Za-z0-9_-]{1,256}$/ 限制 sessionId，与 EntryAbility 已放宽的规则冲突。系统生成的会话 ID 若含其他合法字符，会在播放页路由阶段被拒绝。现改为仅拒绝控制字符及超长 ID。另统一 SessionInviteParser 的 syncMode 兼容逻辑。

# v1.7.8 协播同步修复补丁说明

本补丁基于用户上传的 `无音影视v1.7.8.zip` 修改，尽量保留原有 AVPlayer、XComponent、手势层、VRPlayer、选集、倍速与页面结构。

## 修改内容
- `MediaSessionCommand` 增加可选 `protocolVersion`、`sequence`、`routeIndex`、`ratio`，旧端字段可缺省，保持旧消息解析兼容。
- 主控每次发布状态时写入 `protocolVersion=1` 与单调递增 `sequence`。
- 接收端优先按序列号丢弃重复/乱序包；旧消息仍使用 timestamp 去重。
- LAN/服务端模式的接收超时从 15 秒调整为 8 秒，保活仍为每 3 秒发送。
- 播放同步 seek 容差调整为 800ms。
- 主控快照携带线路索引和画面比例；从机收到后尝试切换对应线路/画面比例，再校准进度。
- Quest payload 序列化前校验 sessionId 与 videoJson，拒绝空 sessionId。

## 重要架构说明
当前 v1.7.8 工程并非完全使用一种通信底层：
- `CoPlayLanService.ets` 使用 `distributedDeviceManager` 做设备发现/状态监听，并以 UDP 广播发现局域网端点、TCP 传输完整邀请载荷。
- `MediaSessionDialog.ets` 的默认 LAN 同播使用 HarmonyOS AVSession 的 common command / playback state；可选 `server` 模式才使用 WebSocket。
- `Quest3ControlService.ets` 是面向 Quest 3 的 WebSocket 客户端扩展。
- 该 SDK/工程中未发现已接入的“分布式数据通道”消息 API。此补丁没有伪造或擅自替换成未知 API，也没有声称已经实现纯分布式数据通道。
如需严格满足“完全不使用 WebSocket、也不使用 UDP/TCP、仅使用官方分布式数据通道”，必须基于目标 API26 SDK 的实际可用接口再迁移，并在 DevEco Studio 中编译确认。

## 仍需验证
1. 未在 DevEco Studio / API26 真机编译，ArkTS 编译结果需要实际验证。
2. `distributedDeviceManager` 发现到的设备不代表已经验证“同账号 + 支持分布式数据同步”的全部能力条件；目标 SDK 若提供能力查询接口，应继续增加 capability filter。
3. 运行时权限声明已在 `module.json5` 存在，`CoPlayLanService` 有动态授权流程；拒绝授权后的入口隐藏逻辑仍需在页面级按实际 UI 需求补齐。
4. 从机线路切换后再同步进度的等待流程需要真机验证，尤其是线路索引不一致、目标集线路数不足、切源失败等情况。
5. 系统 AVSession 的状态回调和页面内播放状态回调可能同时触发，需用双设备长时间播放验证重复回调与时间水位。
6. 当前主控会话关闭、离线通知仍以既有 MediaSessionService 生命周期为准；应在 API26 真机上验证退出、杀进程、Wi-Fi 切换及账号退出后的资源释放。

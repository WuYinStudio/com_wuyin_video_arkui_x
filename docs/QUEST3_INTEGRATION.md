# 无音影视 v1.7.4 — Quest 3 控制扩展（合并版）

## 已合并文件

- `entry/src/main/ets/common/Quest3ControlService.ets`：Quest 3 WebSocket 客户端、载荷发送、独立控制指令、状态包校验、断线重试、防抖、回调释放。
- `entry/src/main/ets/common/CoPlayLanService.ets`：为发现设备添加可选 `deviceType`；按设备名称包含 Quest 3 / Meta Quest 做标记，旧设备默认 `harmony`。
- `entry/src/main/ets/components/MediaSessionDialog.ets`：原局域网邀请入口保持原样；增加手动 Quest 3 IP/端口连接、协播载荷发送、播放/暂停/跳转/倍速/切集、幕布模式与断开控制。
- `entry/src/main/ets/pages/PlayerPage.ets`：提供现有视频数据的标准 payload、把 Quest 状态回传映射到本地进度和播放状态，并在页面退出时释放 Quest WS 链路。

## 协议

Quest 3 端需要作为 WebSocket 服务端监听 `ws://<Quest-IP>:43827/ws`，并实现与鸿蒙端相同的 JSON 协议。原有标准协播字段保持：`version`、`vodId`、`sessionId`、`currentMs`、`timestamp`、`episodeIndex`、`videoJson`；扩展 `sceneMode` 可选 `plane`、`arc180`、`sphere360`。已有 `syncMode`、`serverUrl`（如有）继续兼容。没有把 OpenXR 头显或手柄追踪数据传给鸿蒙端。

控制包示例：

```json
{"type":"command","command":"seek","sessionId":"quest3-example","timestamp":1790000000000,"currentMs":120000,"speed":1,"episodeIndex":0}
```

Quest 端状态回传示例：

```json
{"type":"state","sessionId":"quest3-example","playState":"playing","currentMs":120000,"timestamp":1790000000000}
```

`playState` 支持 `playing`、`paused`、`buffering`、`ended`、`error`。状态包须携带当前会话 `sessionId`；不匹配或格式无效的包会记录日志并忽略。

## 重要发现与限制

1. 原有 `CoPlayLanService` 是鸿蒙分布式设备发现 + UDP 端点公告 + TCP 邀请传输，不是通用 Quest 发现协议。Quest 3 未必会出现在系统设备扫描结果中，所以本版提供手动填写 Quest 3 IP 和端口的可靠入口；名称匹配只是辅助图标，不伪称自动发现已经打通。
2. Quest 3 应用端的 WebSocket 服务端和播放器执行器不在鸿蒙源码 ZIP 内，必须由 Quest 独立应用实现并在真机联调。
3. 端口默认 `43827`，可在界面更改；两端需在可互通的局域网。当前使用 `ws://`，仅适用于可信本地网络测试；不应将未加密端口暴露到公网。
4. 未新增系统权限，沿用项目原有 `INTERNET`、`GET_NETWORK_INFO` 和 `DISTRIBUTED_DATASYNC` 权限。
5. 此环境没有 DevEco Studio / HarmonyOS SDK 编译工具链，尚未执行 ArkTS 真正编译，也未进行鸿蒙真机和 Quest 3 真机验证。交付前必须在目标 SDK 版本下构建并处理编译器报告。

## 建议验证清单

- [ ] DevEco Studio 打开工程并执行完整 Build/HAP 构建。
- [ ] 普通鸿蒙手机/平板邀请流程与旧版行为一致。
- [ ] Quest 3 IP/端口错误、服务未启动、设备离线时显示提示并产生日志。
- [ ] Quest 端验证标准 payload 字段、`sceneMode` 三种值与 `videoJson` 解码。
- [ ] 逐项验证 play/pause/seek/speed/switchEpisode，特别是倍速数值和集索引是否按 Quest 端约定解释。
- [ ] 验证 Quest 状态回传时 UI 进度对齐、播放状态变化及断线重连。
- [ ] 页面退出/播放器关闭后检查 WS 回调、重试定时器和连接均被释放。

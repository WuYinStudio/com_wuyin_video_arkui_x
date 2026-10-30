# Quest 3 扩展变更记录

- 新增 Quest3ControlService WebSocket 客户端与显式 interface/type 定义。
- 新增 Quest 3 手动连接 UI、状态反馈和播放控制入口。
- 标准协播载荷只增加 `sceneMode` 扩展字段，不重命名或删除旧字段。
- 保留普通鸿蒙设备的既有 LAN 邀请方法和执行分支。
- 页面销毁时释放 Quest 3 连接；控制发送和回传解析均有异常日志。
- 自动发现 Quest 3 与 Quest 端服务实现仍需独立完成/验证，详见 QUEST3_INTEGRATION.md。

# 无音影视 v1.7.8 局域网协播接收器修复说明

针对 W40 日志：
- `CreateReceiver code=2301009, message=Bad file descriptor`
- `CloseFailedUdp code=2300999`
- `ReceiverResume 局域网消息接收服务初始化失败`

本次修改 `entry/src/main/ets/common/CoPlayLanService.ets`：
1. 对 UDP/TCP 接收器初始化增加阶段标记，失败日志会显示 `CreateReceiver:UdpSetExtraOptions`、`CreateReceiver:UdpBind` 或 `CreateReceiver:TcpListen`，以定位原始失败点。
2. 先记录初始化原始异常，再执行资源清理；清理异常单独记录，避免把 `close()` 的次生错误误认为根因。
3. 清理时先解绑事件监听，标注 UDP 是否成功 bind、TCP 是否成功 listen，方便区分资源状态。
4. 初始化过程中应用切后台时，按取消流程解绑并释放资源，不把该情况当作一般初始化失败。

验证状态：已完成源码静态修改与 ZIP 完整性检查；当前环境未配置 DevEco Studio/HarmonyOS SDK，未能进行实际 ArkTS 编译或 W40 真机验证。若仍失败，请提供新版日志中 `CreateReceiver:<阶段>` 的那一行；它会明确指出失败发生在设置 UDP 选项、UDP bind 还是 TCP listen。

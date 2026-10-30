# 仅 HarmonyOS 可用的原实现（归档）

这里的文件是原 v5.1.0 工程中依赖 HarmonyOS 专有能力的实现，**不参与 ArkUI-X 编译**，仅作参考/回迁备份：

| 文件 | 原路径 | 依赖 | 说明 |
| --- | --- | --- | --- |
| `common/NfcShareService.ets` | `entry/src/main/ets/common/NfcShareService.ets` | `@kit.ConnectivityKit`（NFC Tag / nfcController） | 碰一碰写 NDEF URI。原工程中无调用方；若恢复，需同时恢复 `module.json5` 的 NFC 权限/能力声明 |
| `common/VRSpatialRuntime.ets` | `entry/src/main/ets/common/VRSpatialRuntime.ets` | `@kit.ArkGraphics3D`（Scene） | XR 空间大屏运行时。原工程中无调用方 |
| `components/VRPlayer.ets` | `entry/src/main/ets/components/VRPlayer.ets` | `@kit.ArkGraphics3D`、`Component3D` | 空间播放控制组件。原工程中无调用方 |
| `shareextensionability/ShareExtensionAbility.ets` | `entry/src/main/ets/shareextensionability/ShareExtensionAbility.ets` | 系统分享扩展、`@kit.ShareKit` | ArkUI-X 不支持 extensionAbilities；跨平台侧改由 `EntryAbility` 接收分享 |

## 恢复方式

如果后续采用官方的双 HAP 方案（HarmonyOS 壳 + 跨平台壳），可以把这些文件放回 HarmonyOS 专属模块，并在该模块的 `module.json5` 中恢复对应 `extensionAbilities` / 权限，跨平台模块继续使用 `entry/src/main/ets/common/compat/` 下的降级实现。

注意：归档文件的相对 import 仍按原目录计算，其中 `NfcShareService.ets` 引用了 `../pages/PlayerPage`，单独拷回时需连同目录结构一起放回。

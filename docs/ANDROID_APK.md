# Android APK 打包与真机验证

> 本文记录**第三步 / 第四步**：清掉 ArkUI-X 跨平台 API 门禁（`11706007`）产出可运行 APK，
> 并补上**平台分流层**，让鸿蒙侧恢复原生能力。
> 前两步见 [`MIGRATION_TO_ARKUIX_STEP1.md`](MIGRATION_TO_ARKUIX_STEP1.md) 与
> [`PORT_TO_SKELETON.md`](PORT_TO_SKELETON.md)。

## 一、结论

| 项目 | 结果 |
| --- | --- |
| ArkTS 编译 | ✅ `assembleHap` **BUILD SUCCESSFUL**（90 个 ArkTS 文件，0 错误） |
| HAP | `entry/build/default/outputs/default/entry-default-unsigned.hap`（6.5 MB） |
| ArkTS 产物注入 Android | ✅ `assembleApp` → `.arkui-x/android/app/src/main/assets/arkui-x/entry/`（`ets/modules.abc` 4.45 MB、`resources.index`、`module.json`） |
| APK 构建 | ✅ `gradlew assembleDebug` **BUILD SUCCESSFUL**（按 ABI 拆 4 个包） |
| 安装 / 启动 | ✅ 模拟器 Android 17 / x86_64：安装 Success → 启动 → 用户协议页 → 同意 → 首页 |
| 鸿蒙侧能力 | ✅ 通过 `common/compat/PlatformApi.ets` 运行时分流，鸿蒙仍走原生 API（截图、通知点击、后台下载、拖动精度、方向恢复、空间预检等）；仅 3 项确无替代 API 的能力降级，见第三节 |

## 二、怎么打包

```powershell
# 1) 从 ArkUI-X SDK 复制 Android 适配层与运行库（首次必做）
powershell -ExecutionPolicy Bypass -File scripts\sync_arkui_android_libs.ps1 -Abi arm64-v8a -WithRuntimeLibs

# 2) ArkTS 编译 + 注入 assets/arkui-x + 打 APK（一条命令，DevEco 里等价于 Build APP(s)）
hvigorw -p product=default -p buildMode=debug assembleApp --no-daemon

# 3) 产物（按 ABI 拆分）
#    .arkui-x/android/app/build/outputs/apk/debug/app-arm64-v8a-debug.apk   ← 真机用这个
#    .arkui-x/android/app/build/outputs/apk/debug/app-universal-debug.apk
```

只跑 `gradlew assembleDebug` 也可以，但前提是 `assets/arkui-x` 已由第 2 步生成过。

## 三、跨平台 API 门禁怎么过、鸿蒙能力怎么保

### 3.1 门禁本身

模块在 `.arkui-x/arkui-x-config.json5` 声明为跨平台后，ArkTS 编译器会把对 HarmonyOS 专属 API 的直接调用
报成 `11706007 can't support crossplatform application`。实测**三条路都走不通**：

| 尝试 | 结果 |
| --- | --- |
| `buildOption.ignoreCrossPlatform: true`（官方 schema 里的降级开关） | 本机 DevEco 26 + ArkUI-X 插件 4.26.8 **不生效**（开关前后同样报错） |
| `if (PlatformInfo.isHarmonyOS()) { router.replaceUrl(...) }` | 照样报错——这是**静态**检查，不做平台流分析 |
| `// @ts-nocheck` 关掉单文件检查 | 被 `arkts-strict-typing-required` 拒绝 |
| `router as Object as RouterLike` 中转 | **命名空间**不允许当对象用：`arkts-no-ns-as-obj` |

可行的只有两类：

1. **实例方法**可以中转：`win as Object as { snapshot(): Promise<image.PixelMap> }`、
   `req as Object as { wantAgent?: Object }`、`options as Object as Record<string, Object>`；
2. **换成 ArkUI-X 已适配的等价 API**：`connection.hasDefaultNet()`、`statfs.getFreeSize()`
   （`@ohos.file.statvfs`，ArkUI-X 已适配；而被拦的是 `@ohos.file.storageStatistics`）。

### 3.2 平台分流层 `common/compat/PlatformApi.ets`

所有平台相关调用收敛到这一个类，业务代码只调它：

```ts
if (PlatformInfo.isHarmonyOS()) { /* 原生实现 */ }
return /* Android / iOS 的降级值 */;
```

| 能力 | HarmonyOS | Android / iOS | 实现方式 |
| --- | --- | --- | --- |
| `router.replaceUrl` | 语义等价 | 语义等价（`pushUrl` + `router.clear()`） | 命名空间不可中转，三端统一用等价写法 |
| 截图保存（`window.snapshot` + 相册创建） | ✅ 原生 | ❌ 提示不支持 | 实例中转，鸿蒙完整可用 |
| 通知点击带聊天室参数（`NotificationRequest.wantAgent`） | ✅ 原生 | ❌ 只拉起应用 | 实例字段中转 |
| 全屏退出恢复方向（`getPreferredOrientation`） | ✅ 原生 | 按 `display` 旋转角推导 | 实例中转 |
| 头像/导入选择器单选（`maxSelectNumber`） | ✅ 原生 | 可多选，取第一个 | 实例动态字段 |
| 拖动定位精度（`SeekMode.SEEK_CLOSEST`） | ✅ 最近帧 | 最近关键帧 | 枚举数值 `2 as media.SeekMode` |
| 后台下载（`Mode.BACKGROUND`） | ✅ 后台任务 | 前台任务 | 枚举数值 `0 as request.agent.Mode` |
| 剩余空间预检 | ✅ | ✅（同实现） | `statfs.getFreeSize()`，三端通吃 |
| 网络可用性 | ✅ | ✅（同实现） | `connection.hasDefaultNet()` |
| 恢复系统下载任务（`request.agent.getTask`） | ⚠️ 降级 | ⚠️ 降级 | 命名空间成员无替代：重启后重建任务，字节断点丢失 |
| 仅 Wi-Fi 下载（`getNetCapabilities`） | ⚠️ 降级 | ⚠️ 降级 | 无法判断承载类型，开关不生效 |
| 清除通知栏提醒（`notificationManager.cancel`） | ⚠️ 降级 | ⚠️ 降级 | 命名空间成员无实例替代，通知随用户忽略消失 |
| 权限自检（`verifyAccessTokenSync`） | ⚠️ 降级 | ⚠️ 降级 | 改为「清单声明即可用」，缺失时由请求报错 |

> 另有 TCP socket 的 `server.on('error')` / `off('connect'|'error'|'close')` 重载（10 处）：
> 这些在 ArkUI-X 类型面缺失，已删除——关闭仍靠 `close()`，只少了服务端 socket 的错误日志与监听显式注销。

### 3.3 顺带修掉的存量缺陷

第一步遗留、从未被编译过的 20 处真实错误也一并修掉：缺 `DeviceStateChange` 导入、
`AVCastController.sendControlCommand` 不存在（改 `sendCommonCommand`）、8 处无类型对象字面量、
2 处结构类型不匹配（`ShareDataOptions`/`SharePreviewOptions` 与兼容层不一致）等，
详见 [`PORT_TO_SKELETON.md`](PORT_TO_SKELETON.md) 第七节。

## 四、运行期问题与修复

第一次在模拟器上启动时，点「同意协议」报「保存同意状态失败」，logcat 给出根因：

```text
W ArkCompiler: [default] Load native module failed: @ohos:data.preferences
D ArkCompiler: [default] Throw error: Cannot read property getPreferences of undefined
```

原因是 `scripts/sync_arkui_android_libs.ps1` 只按 `plugins/api/lib/*/*/<abi>/*.so` **两层**目录匹配，
而 ArkUI-X SDK 的插件库层级不统一（`data`、`display`、`net`、`request` 等只有一层），
导致 30 个插件 `.so`（含 `libdata_preferences.so`、`libdisplay.so`、`libnet_*.so`）没进 APK。

已改为**按目录名递归匹配**（`$_.Directory.Name -eq "android-<abi>"`），三个 ABI 现在各 137 个 `.so`；
重新打包后 preferences 正常，协议状态可持久化。

> 教训：APK 里缺引擎插件库时，应用能启动、UI 能画，但个别 `@ohos.*` / `@kit.*` 模块在**首次调用时**才炸。
> 打包后建议跑一遍冒烟：`adb logcat | findstr "Load native module failed"`。

## 五、验证记录

环境：Windows + DevEco Studio 26（hvigor 6.26.8 / ArkUI-X 插件 4.26.8）、ArkUI-X SDK 26.0.0、
Android SDK（platform 34 / build-tools 36.0.0）、Gradle 9.4.0 + AGP 9.1.1、JDK（DevEco 内置 jbr）。

1. `assembleHap` → BUILD SUCCESSFUL（0 error）
2. `assembleApp` → 生成 `assets/arkui-x/entry/{ets/modules.abc, resources.index, module.json, resources/**}`
3. `gradlew assembleDebug` → 4 个 APK（arm64 / armv7 / x86_64 / universal）
4. `aapt2 dump badging` → `package: com.wuyin.video versionCode 5010000 versionName 5.1.0`、
   `minSdk 26`、`targetSdk 34`、`application-label: 无音影视`、
   `launchable-activity: com.wuyin.video.EntryEntryAbilityActivity`、`native-code: arm64-v8a armeabi-v7a x86_64`
5. `apksigner verify` → `CN=Android Debug`（AGP 自动生成的调试签名）
6. 模拟器 `Medium_Phone_API_37.0`（Android 17 / x86_64）：安装 Success → 启动 → 协议页渲染 → 同意 → 首页

## 六、已知限制

1. **Debug 签名**：APK 用 Android 调试证书签名，自测可直接装；正式分发需在
   `.arkui-x/android/app/build.gradle` 配置自己的 `signingConfigs`。
2. **体积**：ArkUI-X 引擎 `libarkui_android.so` 单 ABI 约 96 MB（Debug 未裁剪），arm64 包 92 MB 属正常；
   已启用 `splits.abi`。
3. **鸿蒙侧三项降级**：下载断点续传、仅 Wi-Fi、通知清除（见第三节表格），原因是这些 API 是命名空间成员，
   ArkUI-X 既未适配、也不允许 `as Object` 中转。要彻底恢复需拆「双 HAP / 双模块」分层，或等 ArkUI-X 适配。
4. **iOS**：仍未编译（需 macOS + `libarkui_ios.xcframework`），见 `.arkui-x/ios/frameworks/README.md`。
5. **QQ 登录**：`TencentSdkService` 仍是空实现，点击提示未集成（第一步就如此）。

## 七、构建环境适配（2026-10-30 命令行复验）

换到命令行（不带 DevEco 的 Terminal 环境）复验时踩到两个环境问题，均已修：

1. **`local.properties` 的转义路径**：DevEco 按 Java properties 规则写入
   `arkui-x.dir=F\:\\APPS\\ArkUI-X\\Sdk`，`sync_arkui_android_libs.ps1` 直接当路径用会落到不存在的
   `F\:` 上（`Get-ChildItem` 报「找不到 Directory 参数」）。脚本已加 `ConvertFrom-PropertyPath`
   还原 `\:` / `\\`。注意脚本必须保持 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会把中文注释读成乱码而解析失败。
2. **Gradle 起不来（提交内存不足）**：本机 32 GB 内存 + 系统托管 25.6 GB 页面文件时提交上限约 56 GB，
   高峰期 `:app:packageDebug` 会报
   `os::commit_memory(...) failed: 页面文件太小` 或 `Failed to commit static region`。
   `.arkui-x/android/gradle.properties` 已改为
   `-Xms128m -Xmx1024m -XX:+UseSerialGC -XX:MaxMetaspaceSize=384m`（G1 会预留大段虚拟空间，SerialGC 不会），
   并加 `org.gradle.daemon=false`、`org.gradle.workers.max=2`。
   释放内存后 `assembleApp` 与 `gradlew assembleDebug` 均一次通过：
   HAP 6.5 MB、arm64 APK 92.4 MB、universal 191.2 MB。


# 无音影视 · ArkUI-X 跨平台工程（官方空壳框架结构）

由 HarmonyOS 版 **com_wuyin_video v5.1.0** 改造而来：一套 ArkTS 代码 + 三套平台壳（HarmonyOS / Android / iOS），
工程骨架采用 DevEco Studio 生成的 **ArkUI-X 空壳框架工程**。

- 应用包名：`com.wuyin.video`
- 版本：5.1.0（versionCode 5010000）
- 目标框架：ArkUI-X 26.0.0（`F:/APPS/ArkUI-X/Sdk/26.0.0`）+ DevEco Studio 26
- 入口模块：`entry`（跨平台模块，已在 `.arkui-x/arkui-x-config.json5` 注册）
- 规模：90 个 ArkTS 文件、21 个 `@Entry` 页面（`entry/src/main/resources/base/profile/main_pages.json`）

> 已完成移植，并**打通了从 ArkTS 编译到 Android APK 的完整链路**：`assembleHap` / `assembleApp` /
> `gradlew assembleDebug` 全部 BUILD SUCCESSFUL，APK 已在 Android 17（x86_64）模拟器上安装、启动、
> 通过用户协议页进入首页。跨平台 API 门禁（`11706007`）通过 `common/compat/PlatformApi.ets`
> **运行时分流**处理：鸿蒙走原生 API（截图、通知点击、后台下载、拖动精度、方向恢复、空间预检等），
> Android/iOS 走降级分支；仅 3 项确无替代 API 的能力降级。明细见
> **[docs/ANDROID_APK.md](docs/ANDROID_APK.md)**。

## 目录结构

```
com_wuyin_video_arkui_x/
├── .arkui-x/
│   ├── arkui-x-config.json5        # 跨平台配置（crossplatform / modules / platforms / buildOption）
│   ├── android/                    # Android 壳：完整 Gradle 工程（gradlew + wrapper jar）
│   └── ios/                        # iOS 壳：完整 Xcode 工程（app.xcodeproj + Assets + LaunchScreen）
├── AppScope/                       # 应用级配置与图标（bundleName / 版本 / 图标）
├── entry/
│   ├── src/main/ets/
│   │   ├── common/                 # 业务与基础能力（含 compat/ 平台适配层）
│   │   ├── components/             # 播放器、协播、聊天等组件
│   │   ├── entryability/           # EntryAbility（生命周期、Want/分享入口）
│   │   └── pages/                  # 21 个 @Entry 页面
│   ├── src/main/resources/         # 资源（base/dark、rawfile、图标）
│   ├── src/main/module.json5       # 权限、意图、skills（已移除 ArkUI-X 不支持的 extensionAbilities）
│   ├── src/{test,ohosTest,mock}/   # 骨架自带的测试桩（hypium/hamock）
│   └── build-profile.json5
├── hvigor/hvigor-config.json5       # @ohos/hvigor-ohos-arkui-x-plugin 4.26.8
├── docs/                           # 文档：移植记录、第一步改造历史、原工程文档
├── legacy/harmonyos-only/          # 仅 HarmonyOS 可用的原实现（VR / NFC / 分享扩展）
├── scripts/                        # 自检 + 平台库同步 + iOS 图标生成
├── build-profile.json5             # product default，compatibleSdkVersion 26.0.0，runtimeOS HarmonyOS
└── oh-package.json5                # 无三方 ArkTS 依赖；devDependencies 为 hypium/hamock
```

## 快速开始

1. DevEco Studio（含 **ArkUI-X 插件**）打开本目录，等待 Sync。
2. 签名：`File > Project Structure > Signing Configs` 勾选 **Automatically generate signature**
   （`build-profile.json5` 里 `signingConfigs` 故意留空，避免把本机证书写进工程）。
3. 构建 HAP：菜单 **Build > Build Hap(s)/APP(s) > Build Hap(s)**；
   或在 DevEco 自带 Terminal 里执行等价命令：

   ```powershell
   hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
   ```

   > 工程根目录没有放 `hvigorw` 脚本（DevEco Studio 首次 Sync 时生成）。命令行直接调 DevEco 内置 hvigor 也可以：
   > `"<DevEco>/tools/hvigor/bin/hvigorw.bat" assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon`
   > （本次验证就是这么跑的，环境变量需给 `DEVECO_SDK_HOME`、`JAVA_HOME`。）

### Android

```powershell
# 1) 从 ArkUI-X SDK 复制 adapter jar（编译必需）+ 运行库 .so（真机运行必需）
powershell -ExecutionPolicy Bypass -File scripts\sync_arkui_android_libs.ps1 -Abi arm64-v8a -WithRuntimeLibs

# 2) ArkTS 编译 + 注入 assets/arkui-x + 打 APK（一条命令，DevEco 里等价于 Build APP(s)）
hvigorw -p product=default -p buildMode=debug assembleApp --no-daemon

# 3) 产物（按 ABI 拆分）
#    .arkui-x/android/app/build/outputs/apk/debug/app-arm64-v8a-debug.apk   ← 真机用这个
#    .arkui-x/android/app/build/outputs/apk/debug/app-universal-debug.apk
```

> 脚本是 UTF-8 with BOM 保存的（Windows PowerShell 5.1 需要 BOM 才能正确解析中文）；
> 若执行策略禁止运行脚本，用上面的 `-ExecutionPolicy Bypass` 形式。
>
> 已实测：`assembleDebug` **BUILD SUCCESSFUL**，产出 `app-arm64-v8a-debug.apk`（92 MB）等 4 个按 ABI 拆分的 APK，
> 并已在模拟器上安装启动验证通过。完整流程与验证记录见 [docs/ANDROID_APK.md](docs/ANDROID_APK.md)。

`local.properties`（`.arkui-x/android/` 下）需指向本机 Android SDK：`sdk.dir=F:/APPS/AndroidSDK/Sdk`。

### iOS（需 macOS + Xcode）

1. 把 ArkUI-X SDK（macOS 版）的 `libarkui_ios.xcframework` 放到
   `.arkui-x/ios/frameworks/`（说明见该目录 `README.md`）；
2. 用 Xcode 打开 `.arkui-x/ios/app.xcodeproj`，替换 `DEVELOPMENT_TEAM` 后运行；
3. ArkTS 产物目录 `arkui-x` 由 hvigor 的跨平台任务生成，Xcode 工程已把它加入 Resources。

> **Windows 不能构建 iOS**：`ace build ios` 会直接拒绝，Windows SDK 也没有
> `libarkui_ios.xcframework`。无签名包的 macOS/云构建步骤见
> **[docs/IOS_UNSIGNED_CLOUD_BUILD.md](docs/IOS_UNSIGNED_CLOUD_BUILD.md)**；
> 已预生成 `.arkui-x/ios/arkui-x/`，并附 `scripts/build_unsigned_ios.sh` 和
> GitHub Actions 模板。

### 自检

```powershell
python scripts/preflight.py .            # 资源、页面、相对 import、$r() 引用
python scripts/check_arkuix_compat.py .  # arkui-x-config schema、页面注册、专有 API 残留
python scripts/make_ios_appicons.py      # 从 AppScope 图标重建 iOS AppIcon 资源
```

## 平台能力适配

| 能力 | HarmonyOS | Android / iOS | 实现 |
| --- | --- | --- | --- |
| 视频播放 / 弹幕 / 下载 / 历史 | ✅ | ✅（待清 API 门禁） | `@kit.MediaKit`、`http`、`fileIo`、`preferences` |
| 影视分享（链接） | ✅ 华为分享 | ✅ 系统分享面板 | `common/compat/ShareCompat.ets` + Android `WuYinShareBridge`；iOS 未接 Bridge 时复制到剪贴板 |
| 分享接收 / 协播邀请 | ✅ Want / 分享扩展 | ✅ Intent / URL Scheme | `EntryAbility` 解析 `share_data` / `wuyin://player`；Android 壳在 `EntryEntryAbilityActivity` 注入 EXTRA_TEXT |
| 协同同播 · 服务器模式 | ✅ WebSocket | ✅ WebSocket | `MediaSessionDialog`（默认模式） |
| 协同同播 · 局域网 AVSession | ✅ | ❌ 明确提示 | `common/compat/AvSessionCompat.ets` 空实现 |
| 局域网设备发现 | ✅ 分布式软总线 | ✅ UDP 广播 | `common/compat/DeviceManagerCompat.ets` + `CoPlayLanService` UDP probe/hello |
| 聊天通知 | ✅ | ⚠️ 依赖 ArkUI-X 通知实现 | `NotificationService`（无点击意图） |
| NFC / VR / 分享扩展 | ✅ | ❌ 已归档 | `legacy/harmonyos-only/` |
| QQ / TIM 登录 | ✅ qq-open-sdk | ❌ 提示未集成 | `TencentSdkService` 空模块 |

## 文档

- **[docs/ANDROID_APK.md](docs/ANDROID_APK.md)** — 第三步：跨平台 API 门禁的 26 类改造清单、APK 打包命令、模拟器安装启动验证记录、运行期问题（缺插件 `.so`）的定位与修复。
- **[docs/PORT_TO_SKELETON.md](docs/PORT_TO_SKELETON.md)** — 第二步：移植到空壳框架的实施记录，三处让构建失败的存量配置错误、Android/iOS 壳改造明细。
- **[docs/MIGRATION_TO_ARKUIX_STEP1.md](docs/MIGRATION_TO_ARKUIX_STEP1.md)** — 第一步（HarmonyOS → ArkUI-X 手工搭工程）的改造历史，含平台适配层说明与行为变化。
- `docs/` 下另有原工程的 CHANGELOG、UI 规范、协播协议说明等。
- `legacy/harmonyos-only/` — 仅 HarmonyOS 可用的原实现（VR / NFC / 分享扩展）。

## 已知限制

1. **Debug 签名**：APK 用 Android 调试证书签名，自测可直接装；正式分发需在 `.arkui-x/android/app/build.gradle` 配置自己的 `signingConfigs`。
2. **三项能力在两端都降级**：下载断点续传（`request.agent.getTask`）、仅 Wi-Fi 下载（`getNetCapabilities`）、通知清除（`notificationManager.cancel`）。原因是它们是**命名空间**成员，ArkUI-X 既未适配、也不允许 `as Object` 中转；要彻底恢复需拆「双 HAP / 双模块」分层。截图/通知点击参数/后台下载/拖动精度等已通过 `PlatformApi` 在鸿蒙侧恢复原生行为，Android/iOS 侧降级。
3. **iOS 未验证**（Windows 环境 + 缺 `libarkui_ios.xcframework`），见 `.arkui-x/ios/frameworks/README.md`。
4. 通知点击不带 `chatRoom`/`chatPeer` 参数（WantAgent 在跨平台不可用）。

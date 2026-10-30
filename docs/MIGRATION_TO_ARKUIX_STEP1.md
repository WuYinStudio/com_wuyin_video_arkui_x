# 无音影视 v5.1.0 → ArkUI-X 改造说明

> **校订说明（移植到空壳框架时补记）**
>
> 这是**第一步**（HarmonyOS → ArkUI-X，手工搭 `.arkui-x` 壳）的历史记录，保留原文以便追溯。
> 当时环境没有 DevEco / ArkUI-X SDK，本文第八节"静态自检通过"只是自写 Python 脚本的启发式结论。
> 真正跑 hvigor 之后发现三处与本文件相关的问题，已在 [`PORT_TO_SKELETON.md`](PORT_TO_SKELETON.md) 第四节修正：
>
> 1. 第三节写的"`entry/build-profile.json5` 保持 `apiType: stageMode`"之外还加了 `targets[].platforms`（本文件未记录），
>    该字段不在 schema 内，会让构建直接失败；
> 2. `arkui-x-config.json5` 的 `ignoreCrossPlatform: true` 写在了**顶层**，schema 只允许
>    `crossplatform` / `modules` / `buildOption` / `platforms`，正确位置是 `buildOption.ignoreCrossPlatform`；
> 3. 第四节的"ArkUI-X 已支持的能力"判断偏乐观：`router.replaceUrl`、`net.connection.getDefaultNet`、
>    `AVPlayer SEEK_CLOSEST`、`photoAccessHelper.showAssetsCreationDialog`、`display.getPreferredOrientation`、
>    `picker.maxSelectNumber` 等 15 类 API 实际会被 ArkUI-X 编译器以 `11706007` 拒绝，
>    共 46 处调用点，清单见 `PORT_TO_SKELETON.md` 第八节。
>
> 工程骨架（Gradle Wrapper / Xcode 工程 / 测试桩）也已按官方空壳框架工程替换，见 `PORT_TO_SKELETON.md`。

## 一、结论

原工程是 HarmonyOS Stage 模型应用（compileSdk 26、兼容 6.1.1(24)），共 **87 个 ArkTS 文件（约 3.89 万行）**、20 个路由页面、1 个系统分享扩展 Ability、1 个 HarmonyOS HAP 形态三方库。本次改造产出可直接在 DevEco Studio（ArkUI-X 插件）中打开的跨平台工程：

- 跨平台模块：`entry`（已写入 `.arkui-x/arkui-x-config.json5`）；
- 目标框架：ArkUI-X 6.0.2 及以上，Android 8+、iOS 10+（编译 SDK 由本机 DevEco 决定）；
- 业务代码保留率：**90 个 ArkTS 文件中，仅 8 个文件被修改**，其余原样迁移；
- HarmonyOS 专有能力统一收敛到 `entry/src/main/ets/common/compat/` 平台适配层；
- 静态自检（资源、路由、import、ArkUI-X 模块支持列表）全部通过；
- 未执行编译与真机验证（环境缺少 ArkUI-X SDK / DevEco Studio），验证项见第八节。

## 二、工程结构改造

| 项目 | 原工程 | ArkUI-X 工程 |
| --- | --- | --- |
| 工程根 | HarmonyOS 单模块工程 | 同一 OpenHarmony 工程 + `.arkui-x/` 跨平台叠加层 |
| 跨平台标记 | 无 | `.arkui-x/arkui-x-config.json5`：`crossplatform: true`、`modules: ["entry"]`、`ignoreCrossPlatform: true` |
| Android 壳 | 无 | `.arkui-x/android/`：Gradle 脚本、Manifest、`StageApplication`/`StageActivity`、分享 Bridge |
| iOS 壳 | 无 | `.arkui-x/ios/app/`：`AppDelegate`、`StageViewController`、`main.m`、`Info.plist` |
| 分享扩展 | `ShareExtensionAbility` | 已移除（ArkUI-X 不支持 extensionAbilities），改由 `EntryAbility` + Android intent-filter / URL Scheme 接收 |
| 三方依赖 | `@tencent/qq-open-sdk` | 已移除（HAP 形态无法跨平台编译），QQ 登录在各端给出可读失败提示 |

## 三、构建配置改动

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `build-profile.json5` | 去掉 `compileSdkVersion` / `targetSdkVersion`（改为由本机 SDK 决定），`compatibleSdkVersion` 设为 `5.0.0(12)`，`runtimeOS` 保持 `HarmonyOS`，新增空 `signingConfigs` | 官方 ArkUI-X 模板工程即为此结构：跨平台产物跟随本机 DevEco/HarmonyOS SDK 版本 |
| `hvigorfile.ts`（应用级/模块级） | 改为 `AppTasksForArkUIX` / `HapTasks`（来自 `@ohos/hvigor-ohos-arkui-x-plugin`） | 提供跨平台构建任务；原来的 `@ohos/hvigor-ohos-plugin` 只能产 HAP |
| `hvigor/hvigor-config.json5` | 声明 `@ohos/hvigor-ohos-arkui-x-plugin` 依赖；保留 `modelVersion 26.0.0` | 插件版本需与本机 hvigor 匹配（DevEco 26 → 4.26.x） |
| `oh-package.json5` / `entry/oh-package.json5` | 删除 `@tencent/qq-open-sdk`；`modelVersion` 26.0.0 → 6.0.0 | HarmonyOS HAP 依赖不参与 ArkUI-X 编译 |
| `entry/src/main/module.json5` | 删除 `extensionAbilities`；`querySchemes` 只保留 `wuyin`；保留权限声明 | ArkUI-X 不支持系统扩展 Ability；QQ 相关 scheme 随 SDK 移除 |
| `main_pages.json` | 补登记 `pages/UserAgreementPage`（原工程 `router.pushUrl` 指向它但未注册，属原工程遗留缺陷） | 修复“用户协议”页无法路由打开 |
| `entry/build-profile.json5` | 保持 `apiType: stageMode` | ArkUI-X 仍使用 Stage 模型 |

## 四、HarmonyOS 专有 API 的适配方式

改造原则（对应官方《跨平台应用改造指南》的场景 2 / 场景 3）：

1. **ArkUI-X 已支持的能力**：保持原调用（`http`、`socket`、`webSocket`、`preferences`、`fileIo`、`picker`、`image`、`media`、`webview`、`pasteboard`、`cryptoFramework`、`zlib`、`photoAccessHelper`、`notificationManager` 等）；
2. **ArkUI-X 未支持、但可用平台桥接补齐的能力**：抽到 `compat/` 适配层 + `.arkui-x` 原生实现；
3. **ArkUI-X 未支持且无法桥接的能力**：适配层给出空实现/明确提示，原实现归档到 `legacy/harmonyos-only/`。

| 原依赖 | 使用位置 | 处理 | 跨平台效果 |
| --- | --- | --- | --- |
| `@kit.ShareKit`（systemShare） | `ShareService`、`CoPlayShareService`、`MyPage` | 新增 `compat/ShareCompat.ets`：`SharedData`/`ShareController`/`SharePreviewMode`/`getSharedData` 同名兼容；`show()` 调 `BridgeShare` → Android `WuYinShareBridge` 拉起系统分享；失败则复制到剪贴板并 Toast | 分享可用（Android 系统分享面板；iOS 暂为剪贴板兜底） |
| `@kit.AVSessionKit`（avSession） | `MediaSessionDialog`（1300+ 行） | 新增 `compat/AvSessionCompat.ets`，同名类型 + 空实现；`createAVSession`/`createController` 抛出“请使用服务器模式”；协播页默认模式改为 `server`，局域网模式在 Android/iOS 明确禁用 | 协同同播的 **WebSocket 服务器模式** 完整可用；系统 AVSession 局域网模式不可用 |
| `@kit.DistributedServiceKit`（distributedDeviceManager） | `CoPlayLanService` | 新增 `compat/DeviceManagerCompat.ets`：提供本地设备 ID、空设备列表；`CoPlayLanService` 改为用已有 UDP `probe/hello` 广播填充设备列表；Android/iOS 跳过 `DISTRIBUTED_DATASYNC` 权限申请 | 局域网邀请/发现仍可用（UDP 广播），不再依赖分布式软总线 |
| `@kit.IMEKit`（inputMethod） | `ChatRoomPage.hideKeyboard()` | 新增 `compat/InputMethodCompat.ets`，`stopInputSession()` 空实现（`clearFocus` 已能收起软键盘） | 行为一致 |
| `WantAgent` / `wantAgent` | `NotificationService` | 新增 `compat/WantAgentCompat.ets`，`getWantAgent` 抛错；调用方原有 try/catch 兜底为“无点击意图的通知” | 通知可发；点击通知只拉起应用，不带聊天室参数 |
| `@kit.ArkGraphics3D`（Scene） | `VRSpatialRuntime`、`VRPlayer` | 原工程中**未被任何页面引用**，整体归档到 `legacy/harmonyos-only/` | 无影响 |
| `@kit.ConnectivityKit`（NFC） | `NfcShareService` | 原工程中**未被引用**，归档 | 无影响 |
| `ShareExtensionAbility` | 系统分享扩展 | 归档，`module.json5` 移除声明；分享接收改由 `EntryAbility.captureSharedWant` + 平台入口承担 | Android 通过 `ACTION_SEND` / `wuyin://` 进入同一解析链路 |
| `@tencent/qq-open-sdk` | `TencentSdkService` | 移除 import，`rootModule = {}`；初始化时给出“SDK 未提供 QQOpenApiFactory”的明确错误，其它登录方式不受影响 | QQ/TIM 登录不可用 |

## 五、逐文件改动清单

### 新增（7 个适配层）

| 文件 | 行数 | 说明 |
| --- | --- | --- |
| `common/compat/PlatformInfo.ets` | 48 | 基于 `deviceInfo.osFullName` 识别 HarmonyOS / Android / iOS |
| `common/compat/ShareCompat.ets` | 129 | ShareKit 兼容层，含剪贴板兜底 |
| `common/compat/BridgeShare.ets` | 36 | `@arkui-x.bridge` 封装，Bridge 名 `WuYinShare` |
| `common/compat/AvSessionCompat.ets` | 141 | AVSession 类型与空实现 |
| `common/compat/DeviceManagerCompat.ets` | 68 | 分布式设备管理空实现 + 本地设备标识 |
| `common/compat/InputMethodCompat.ets` | 19 | 收起输入法空实现 |
| `common/compat/WantAgentCompat.ets` | 38 | WantAgent 空实现 |

### 修改（8 个业务文件）

| 文件 | 改动 |
| --- | --- |
| `common/ShareService.ets` | `systemShare.*` → `ShareCompat` 同名类型；分享调用链不变 |
| `common/CoPlayShareService.ets` | 同上，含 `getSharedData` 替换 |
| `pages/MyPage.ets` | 同上（更新分享） |
| `components/MediaSessionDialog.ets` | `avSession.*` 全部替换；默认模式按平台选择；局域网模式在非 HarmonyOS 禁用；模式下拉与说明文案标注“仅 HarmonyOS” |
| `common/CoPlayLanService.ets` | 设备管理替换；UDP 广播设备入列表；跳过 HarmonyOS 专属权限申请 |
| `pages/ChatRoomPage.ets` | 输入法 import 替换 |
| `common/NotificationService.ets` | WantAgent 替换 |
| `common/TencentSdkService.ets` | 移除 HAP 三方库 import |

### 归档（4 个文件，原样保留）

`legacy/harmonyos-only/`：`NfcShareService.ets`、`VRSpatialRuntime.ets`、`VRPlayer.ets`、`ShareExtensionAbility.ets`（含原 `shareextensionability` 目录结构）。

### 顺带修复

- `pages/UserAgreementPage.ets` 补充 `@Entry` 并注册到 `main_pages.json`：原工程 `LoginPage` / `RegisterPage` 通过 `router.pushUrl('pages/UserAgreementPage')` 打开协议页，但该页缺少 `@Entry` 且未注册，跳转会失败。

## 六、平台壳工程说明

### Android（`.arkui-x/android`）

- `EntryAbilityActivity`：`setInstanceName("com.wuyin.video:entry:EntryAbility:")`，与 ArkTS 侧 `EntryAbility` 对齐；
- `MyApplication`：`StageApplication`；
- `WuYinShareBridge`：`BridgePlugin` 子类，`shareText(title, content)` 拉起 `ACTION_SEND` 分享面板，与 ArkTS `createBridge('WuYinShare')` 对应；
- Manifest：`INTERNET`、网络状态、媒体读取、通知权限；`wuyin://player` 的 `VIEW`、`text/plain` 的 `SEND`/`VIEW` intent-filter；
- 分享文本转交：`EntryAbilityActivity.forwardSharedText()` 把 `EXTRA_TEXT` 写入 `ohos.extra.param.key.share_data`，复用 `EntryAbility` 既有解析；
- 需手动补齐：`app/libs/arkui_android_adapter.jar`、`libarkui_android.so`、`libhilog.so`，以及 Gradle Wrapper。

### iOS（`.arkui-x/ios/app`）

- `AppDelegate`：`configModuleWithBundleDirectory:@"arkui-x"` + `launchApplication` + `StageViewController` 根控制器，instanceName `com.wuyin.video:entry:EntryAbility`；
- `Info.plist`：`wuyin` URL Scheme、ATS 允许明文（影视源多为 http）、后台音频、本地网络用途说明；
- 需手动补齐：Xcode 工程文件、`libarkui_ios` 等 frameworks、启动图与图标资源；iOS 分享暂未接 Bridge，走剪贴板兜底；URL Scheme 转发需按所用 SDK 的 `StageApplication` 接口补一行调用。

## 七、行为变化

1. **协同同播**：默认进入「服务器模式」；「局域网 AVSession / AVCast」在 Android/iOS 上禁用并提示。局域网设备列表改由 UDP 广播发现，设备名显示为“局域网设备-XXXX”。
2. **分享**：Android 使用系统分享面板；iOS 未接 Bridge 时为复制链接 + Toast。分享结果回调的 `resultCode` 由“是否成功拉起”决定，不再有华为分享的投递结果。
3. **QQ / TIM 登录**：入口保留，点击后提示 SDK 未集成；微信/手机号等其它登录方式不受影响。
4. **聊天通知**：通知内容不变，但点击通知不再携带 `chatRoom` / `chatPeer` 参数。
5. **NFC 碰一碰、VR**：随归档文件移除（原工程中两者均无调用方，不影响现有 UI）。
6. **用户协议页**：修复为可路由打开。

## 八、验证情况

已执行的静态检查（`scripts/preflight.py`、`scripts/check_arkuix_compat.py`）：

- ✅ `AppScope/app.json5`、`module.json5` 的 `$string/$media/$color/$profile` 引用全部命中；
- ✅ 全部相对 import 可解析（90 个 ArkTS 文件）；
- ✅ 全部 `$r('app.*')` 资源引用命中；
- ✅ 21 个 `@Entry` 页面与 `main_pages.json` 双向一致；
- ✅ 无 ArkUI-X 支持列表之外的 `@kit.*` / `@ohos.*` 导入；
- ✅ 业务代码无残留 `systemShare/avSession/distributedDeviceManager/wantAgent/nfc` 等专有标识；
- ✅ `module.json5` 无 `extensionAbilities`；
- ✅ `.arkui-x/arkui-x-config.json5` 已开启跨平台并包含 `entry`。

**未执行**（环境无 ArkUI-X SDK / DevEco Studio / Gradle / Xcode）：

- `hvigorw assembleHap` 与 ArkUI-X 跨平台编译；
- Android APK 构建与真机运行；
- iOS 工程编译与真机运行。

### 建议的真机冒烟清单

1. 冷启动、登录/注册、首页加载；
2. 视频播放（http 明文流、硬解、倍速、选集）、弹幕；
3. 下载、播放历史、收藏（`fileIo` / `preferences` / `request`）；
4. 分享链接（系统面板）、从外部应用分享文本回到本应用、`wuyin://player` 唤起；
5. 协同同播服务器模式：创建 → 分享邀请 → 另一台设备入会 → 播放/暂停/切集同步；
6. 聊天室：发消息、通知栏提醒、点击通知；
7. 主题/壁纸/字体缩放（`Theme`、`window`、`display`）；
8. 返回栈、横竖屏切换、画中画/全屏。

## 九、风险与待办

| 风险 | 说明 | 建议 |
| --- | --- | --- |
| SDK 版本配套 | 工程不锁定 compileSdkVersion，实际以本机 DevEco/HarmonyOS SDK 为准；ArkUI-X SDK 需与该 DevEco 配套 | Sync 后确认 ArkUI-X SDK 版本；若用 ArkUI-X 6.0.2（API 22），需把 `compatibleSdkVersion` 改为 `6.0.2(22)` 并确认 API 差异 |
| 通知渠道 | Android 8+ 需要 NotificationChannel，ArkUI-X 的 `notificationManager` 是否自动创建渠道未验证 | 真机验证；必要时在 `EntryAbility` 启动时通过 Bridge 创建渠道 |
| Bridge 构造签名 | `WuYinShareBridge` 使用 ArkUI-X 6.0.2.118+ 的 `BridgePlugin(String, BridgeType)` 构造；旧 SDK 需改为 `(Context, String, BridgeManager)` | 按实际 SDK 版本调整，一处构造 |
| 分享接收 | Android 依赖 `StageActivity` 把 Intent extras 映射为 Want.parameters | 真机验证；若不生效，改为在 Activity 中通过 `startAbility` 显式传参或读取 URI |
| 系统符号资源 | `SymbolGlyph($r('sys.symbol.*'))` 依赖系统符号库，Android/iOS 可能缺字形 | 关键图标准备 PNG/SVG 兜底 |
| Android 明文流量 | 已开启 `usesCleartextTraffic` + networkSecurityConfig | 发布前按域名收紧 |
| iOS 壳 | 未提供 `.xcodeproj`、frameworks、启动图 | 用 `ace create` 生成空白工程后合并，或按 README 手工建工程 |
| 未使用代码 | 归档的 VR/NFC 代码在原工程中无引用，但若后续要恢复，需要按 HarmonyOS 单独 HAP 方案处理 | 参考官方双 HAP（harmonyos / arkuix）分层方案 |

## 十、后续可选增强

1. **双 HAP 分层**：按官方《跨平台应用改造指南》把 HarmonyOS 专有能力（AVSession、NFC、ShareKit 华为分享、分享扩展）拆到 `products/harmonyos`，跨平台代码抽到 `features/main`，实现“同一工程、两套壳、能力各自最优”。
2. **iOS 分享 Bridge**：实现 `WuYinShareBridge` 的 OC 版本（`UIActivityViewController`），与 Android 对齐。
3. **通知点击参数**：在 Android/iOS 原生侧实现“点击通知 → 携带 chatRoom/chatPeer 启动”，替代 WantAgent。
4. **QQ 登录**：Android 接 QQ 互联 SDK、iOS 接 QQ SDK，或在跨平台版本中隐藏该登录入口。
5. **局域网协播去 AVSession 化**：把播放指令同步改到现有 TCP 通道，可在 Android/iOS 恢复“无服务器”的局域网同播。

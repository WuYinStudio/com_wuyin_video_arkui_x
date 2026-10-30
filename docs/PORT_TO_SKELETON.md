# 移植到官方空壳框架工程 · 实施记录

> 本文档记录 **第二步**：把 `com_wuyin_video_arkuix`（第一步手工搭出来的 ArkUI-X 工程）整体移植到
> `com_wuyin_video_arkui_x`（DevEco Studio 生成的官方 ArkUI-X 空壳框架）上。
> 第一步的改造历史见 [`MIGRATION_TO_ARKUIX_STEP1.md`](MIGRATION_TO_ARKUIX_STEP1.md)。

## 一、结论

| 项目 | 结果 |
| --- | --- |
| 工程骨架 | 完全采用空壳框架 zip：Gradle Wrapper（含 `gradle-wrapper.jar`）、`gradlew`/`gradlew.bat`、Xcode 工程（`app.xcodeproj` + `Assets.xcassets` + `LaunchScreen.storyboard`）、hvigor 配置、ohpm 依赖目录、单元/UI 测试桩 |
| 业务代码 | 90 个 ArkTS 文件、21 个 `@Entry` 页面、21 个页面路由、资源与 rawfile **100% 迁入**（与原工程逐文件一致） |
| 应用标识 | `com.wuyin.video` / 5.1.0（versionCode 5010000），三端（HarmonyOS、Android、iOS）一致 |
| 使构建失败的三处**存量**配置错误 | 已定位并修复（详见第四节，均为第一步遗留，与空壳框架无关） |
| 编译验证 | ✅ **已全部通过**。第二步时曾卡在 `default@CompileArkTS` 的 46 处跨平台 API 调用，第三步（见 [ANDROID_APK.md](ANDROID_APK.md)）把它们全部改造后：`assembleHap` / `assembleApp` / `gradlew assembleDebug` 均 BUILD SUCCESSFUL，APK 已在模拟器安装启动验证 |
| 本次顺带修掉的编码问题 | 3 处让构建直接中断的配置错误 + 20 处 ArkTS 编译错误（缺 `DeviceStateChange` 导入、`AVCastController.sendControlCommand` 不存在、8 处无类型对象字面量、2 处结构类型不匹配、8 处命令参数构造）。这 20 处在第一步从未被编译过，属于隐藏缺陷 |
| 未验证 | Android APK / iOS 真机（本机 Windows 无 ArkUI-X iOS framework；Android 需联网拉 Gradle/AGP 依赖） |

一句话：**工程结构层面的移植已经完成并验证；真正卡住编译的不是框架，而是业务代码里十余类 HarmonyOS 专有 API。**

## 二、两个 zip 的分工

| 来源 | 贡献 |
| --- | --- |
| `com_wuyin_video_arkui_x空客（空壳）框架.zip` | 工程骨架：`hvigorfile.ts`（`AppTasksForArkUIX` / `HapTasks`）、`hvigor/hvigor-config.json5`（插件 4.26.8）、`.arkui-x/arkui-x-config.json5`、`.arkui-x/android`（真正的 Gradle 工程 + wrapper）、`.arkui-x/ios`（真正的 Xcode 工程）、`oh-package-lock.json5`、`oh_modules`（hypium/hamock）、`entry/src/{test,ohosTest,mock}` 测试桩、`code-linter.json5` |
| `com_wuyin_video_arkuix.zip` | 业务实现：`entry/src/main/ets/{common,components,pages,entryability}`、`entry/src/main/resources`、`module.json5` 的权限/意图/skills、`AppScope` 文案与图标、Android 壳定制（分享 Bridge、intent-filter、明文流量）、iOS 壳定制（URL Scheme、ATS、后台音频）、`docs/`、`legacy/harmonyos-only/`、`scripts/` |

第一步的 README 里其实已经写明了正确做法（"用 `ace create` 生成的空壳工程替换 `.arkui-x/android` / `.arkui-x/ios`，再覆盖 app 源码"），本次即按此执行。

## 三、直接获得的能力（第一步缺、骨架补齐）

1. **Android 可构建**：`gradlew`、`gradlew.bat`、`gradle/wrapper/gradle-wrapper.jar` 齐全，不再需要"用 Android Studio 打开以生成 Wrapper"。
2. **iOS 有工程文件**：`app.xcodeproj/project.pbxproj`（含 `libarkui_ios.xcframework` 的 Frameworks/Embed 阶段）、`Assets.xcassets`、`Base.lproj/LaunchScreen.storyboard` 齐全，不再需要"新建 Xcode 工程再合并源码"。
3. **依赖自洽**：`oh-package-lock.json5` + `oh_modules`（`@ohos/hypium`、`@ohos/hamock`），测试 target 可编译。
4. **测试骨架**：`entry/src/test`、`entry/src/ohosTest`、`entry/src/mock` 原样保留，`ohosTest` target 在 `entry/build-profile.json5` 中已登记。

## 四、修复三处让构建失败的存量错误

这三处都是第一步工程的配置错误，用第一步的配置**任何** ArkUI-X 构建都无法通过；本次按 `@ohos/hvigor-ohos-arkui-x-plugin` 实际 schema 修正。

### 1. `.arkui-x/arkui-x-config.json5` 写了非法字段（致命）

第一步写的是：

```json5
{ "crossplatform": true, "modules": ["entry"], "ignoreCrossPlatform": true }   // ← 顶层字段非法
```

hvigor 配置阶段直接退出（实测报错原文）：

```text
00303038 Configuration Error
Schema validate failed, at file: .../.arkui-x/arkui-x-config.json5
  allowedValues: [ 'crossplatform', 'modules', 'buildOption', 'platforms' ]
  message: 'property name must be valid'  propertyName: 'ignoreCrossPlatform'
```

正确写法是把开关放到 `buildOption` 下（schema 见 `hvigor-ohos-plugin/res/schemas/arkui-x-config-schema.json`）：

```json5
{
  "crossplatform": true,
  "modules": ["entry"],
  "platforms": ["android", "ios"],
  "buildOption": { "ignoreCrossPlatform": true }
}
```

### 2. `entry/build-profile.json5` 的 `targets[].platforms` 是非法字段（致命）

第一步为 Android/iOS 写了一段：

```json5
"targets": [ { "name": "default", "platforms": { "android": {...}, "ios": {...} } } ]
```

实测报错：

```text
00303038 Configuration Error
Schema validate failed, at file: .../entry/build-profile.json5
  instancePath: 'targets[0]'
  allowedValues: [ 'name', 'config', 'source', 'resource', 'runtimeOS', 'output' ]
  propertyName: 'platforms'
```

`targets[]` 只接受上面六个字段。**平台应用标识必须落在平台工程自身**，本次已迁入：

- `applicationId` / `versionCode` / `versionName` / `abiFilters` → `.arkui-x/android/app/build.gradle`
- Bundle ID / 版本号 / 团队 → `.arkui-x/ios/app.xcodeproj/project.pbxproj` + `Info.plist`

### 3. `oh_modules` 里的包目录是空的（致命）

zip 无法保存目录链接，`oh_modules/@ohos/hypium`、`@ohos/hamock` 解压后为空目录，导致：

```text
Failed to resolve OhmUrl. Failed to get a resolved OhmUrl for "@ohos/hypium"
```

已用目录联接（junction）指回 `oh_modules/.ohpm/@ohos+hypium@1.0.25/oh_modules/@ohos/hypium` 与
`...@ohos+hamock@1.0.0/...`。重新解压本工程 zip 后若再次出现该报错，在工程根目录执行：

```powershell
cmd /c mklink /J oh_modules\@ohos\hypium oh_modules\.ohpm\@ohos+hypium@1.0.25\oh_modules\@ohos\hypium
cmd /c mklink /J oh_modules\@ohos\hamock oh_modules\.ohpm\@ohos+hamock@1.0.0\oh_modules\@ohos\hamock
```

或直接 `ohpm install` 重建。

## 五、Android 壳改造明细（骨架 → 本应用）

| 文件 | 处理 |
| --- | --- |
| `app/build.gradle` | 保留骨架的 AGP 结构与依赖；`applicationId com.wuyin.video`、`versionCode 5010000`、`versionName "5.1.0"`；`compileSdkVersion/targetSdkVersion` 33 → **34**（本机只装了 android-34/37，模板的 33 与其 buildTools 30.0.3 都不存在）；去掉 `buildToolsVersion` 让 AGP 自选；`abiFilters arm64-v8a, armeabi-v7a`（ArkUI-X SDK 同时提供 arm 与 arm64 库）；`minSdkVersion 26` 保持 |
| `AndroidManifest.xml` | 骨架结构 + 应用定制：`INTERNET`/`ACCESS_NETWORK_STATE`/`ACCESS_WIFI_STATE`/`READ_MEDIA_VIDEO`/`READ_EXTERNAL_STORAGE(≤32)`/`POST_NOTIFICATIONS`；`usesCleartextTraffic` + `networkSecurityConfig`（影视源多为 http）；`Theme.WuYin`；`app_icon`；`wuyin://player` 的 VIEW intent-filter；`text/plain` 的 SEND/VIEW intent-filter；`launchMode singleTask`；`configChanges` 合并骨架与应用两侧 |
| `EntryEntryAbilityActivity.java` | 采用骨架命名（`<Entry><EntryAbility>Activity`），`setInstanceName("com.wuyin.video:entry:EntryAbility:")`；迁入第一步的 `forwardSharedText()`（把 `EXTRA_TEXT` 写成 `ohos.extra.param.key.share_data`，且**在 `super.onCreate` 之前**调用，否则 StageActivity 已经读过 Intent）；注册 `WuYinShareBridge` 并对注册失败做 try/catch（桥不可用时 ArkTS 侧自动回退剪贴板） |
| `WuYinShareBridge.java` | 新增：`BridgePlugin(String, BridgeType)`，Bridge 名 `WuYinShare`，`shareText()` 拉起系统分享面板 |
| `MyApplication.java` | 保留骨架实现（`StageApplication`） |
| `res/values/strings.xml` | `app_name` = 无音影视 |
| `res/values/styles.xml` | 新增 `Theme.WuYin`：**父主题用平台自带的 `@android:style/Theme.Material.NoActionBar`**，不引入 AppCompat，因此骨架 `gradle.properties` 的 `android.useAndroidX=false` 保持不动（第一步为了用 AppCompat 主题把 `useAndroidX` 改成 true，会牵连骨架其它配置） |
| `res/xml/network_security_config.xml` | 迁入（允许明文流量，发布前按域名收紧） |
| `res/drawable/app_icon.png` | 迁入应用图标；删除骨架默认的 `arkuix.png` |
| `app/proguard-rules.pro` | 骨架内容 + `-keep class ohos.**`、`-keep class com.wuyin.video.**`、`-dontwarn ohos.**` |
| `app/libs/` | 留空目录 + 由 `scripts/sync_arkui_android_libs.ps1` 从 ArkUI-X SDK 复制 `arkui_android_adapter.jar`（编译必需）与引擎 `.so`（运行必需） |
| 其余（`build.gradle`、`settings.gradle`、`gradle.properties`、`gradle/wrapper/*`、`local.properties`、测试桩） | 保持骨架原样 |

## 六、iOS 壳改造明细

| 文件 | 处理 |
| --- | --- |
| `AppDelegate.m` | 以骨架为骨架（`configModuleWithBundleDirectory:@"arkui-x"` + `launchApplication` + `EntryEntryAbilityViewController`）重写为精简版：instanceName 固定 `com.wuyin.video:entry:EntryAbility`；根控制器隐藏系统导航栏（应用自带沉浸式导航，避免双标题栏）；`openURL` 仅记录日志并返回 YES。**骨架原文件里 `handleOpenUrlWithBundleName:...` 那段是生成器的坏代码（`[[UIApplication sharedApplication].delegate window].rootViewController` 语法不成立、两个分支完全重复），已删除** |
| `Info.plist` | 骨架是空 `<dict/>`；补全：`CFBundleDisplayName 无音影视`、`CFBundleName WuYinVideo`、版本用 `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`、`CFBundleURLTypes` 注册 `wuyin` scheme、`NSAllowsArbitraryLoads`、`NSLocalNetworkUsageDescription` + `NSBonjourServices(_wuyin._tcp)`（协播设备发现）、`UIBackgroundModes audio`、`UILaunchStoryboardName LaunchScreen`、iPhone/iPad 方向 |
| `project.pbxproj` | `MARKETING_VERSION` 1.0 → **5.1.0**、`CURRENT_PROJECT_VERSION` 1 → **5010000**（Debug/Release 各一处）；`PRODUCT_BUNDLE_IDENTIFIER com.wuyin.video`、`TARGETED_DEVICE_FAMILY "1,2"`、`DEVELOPMENT_TEAM` 保持骨架值（换成自己的 Apple 团队 ID 即可） |
| `Assets.xcassets/AppIcon.appiconset` | 骨架只有 `Contents.json` 且没有 `filename`（等于没图标）。已用 `scripts/make_ios_appicons.py` 从应用图标生成 15 张 PNG（20~1024），并回写带 `filename` 的 `Contents.json` |
| `frameworks/` | 新增 `README.md` 说明：Windows 版 ArkUI-X SDK 不含 iOS 产物，需在 macOS 上把 `libarkui_ios.xcframework` 放到此处 |
| `EntryEntryAbilityViewController.{h,m}`、`main.m`、`LaunchScreen.storyboard` | 保持骨架原样 |

## 七、构建验证记录

环境：Windows，DevEco Studio 26（hvigor 6.26.8、`@ohos/hvigor-ohos-arkui-x-plugin` 4.26.8）、
ArkUI-X SDK `F:/APPS/ArkUI-X/Sdk/26.0.0`、HarmonyOS SDK（DevEco 内置）、JDK（DevEco 内置 jbr）。

命令（等价于 DevEco 的 Build > Build Hap(s)）：

```powershell
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
```

| 阶段 | 结果 |
| --- | --- |
| 配置校验（`build-profile` / `arkui-x-config` / `module.json5` schema） | ✅ 通过（修正上表两处非法字段之后） |
| `PreBuild` → `ProcessProfile` → `ProcessResource` → `CompileResource` | ✅ 通过（资源编译 2.5 s，21 个页面、图标、rawfile 全部打进 `resources.index`） |
| 依赖解析 / `GeneratePkgContextInfo` / `MakePackInfo` / `SyscapTransform` | ✅ 通过 |
| `ohosTest@OhosTestCompileArkTS` + `ohosTest@PackageHap` | ✅ 通过（测试 HAP 能出包，说明 ArkTS 工具链与 JDK 链路正常） |
| `default@CompileArkTS` | ✅ 通过（第三步清掉 26 类跨平台 API 门禁后 0 error，见 [ANDROID_APK.md](ANDROID_APK.md)） |

`11706007` 是 ArkUI-X 的"跨平台 API 支持性"门禁：模块一旦在 `arkui-x-config.json5` 里声明为跨平台，
ArkTS 编译器就会拒绝 HarmonyOS 专有 API。`buildOption.ignoreCrossPlatform: true` 是 SDK schema 里
官方提供的降级开关（[schema 原文](.arkui-x/arkui-x-config.json5)："Whether to suppress errors for unsupported
cross-platform APIs"），但**本机 DevEco 26 / 插件 4.26.8 组合实测未生效**（打开前后同为 64 条），因此只能按第八节改造代码。

### 本次一并修复的 20 处编译错误

编译打通后暴露出的真实缺陷（全部属于第一步遗留、从未被编译过的代码）：

| 文件 | 错误 | 修复 |
| --- | --- | --- |
| `common/CoPlayLanService.ets` | `Cannot find name 'DeviceStateChange'` ×2（第 19、94 行） | 适配层 `DeviceManagerCompat` 已导出该枚举，但 import 列表漏了；补上 `DeviceStateChange` |
| `components/MediaSessionDialog.ets` | `Property 'sendControlCommand' does not exist on type 'AVCastController'. Did you mean 'sendCommonCommand'?` ×3 | API 26 的 `AVCastController` 只有 `sendCommonCommand(command: string, args: Record<string, Object>)`，把 play/pause/setSpeed/seek 三个调用改为 `sendCommonCommand` |
| `components/MediaSessionDialog.ets` | `arkts-no-untyped-obj-literals` ×8（`sendCommonCommand`/`dispatchSessionEvent` 直接传 `{ payload: … }`） | 新增模块级 `sessionArgs(key, value): Record<string, Object>` 统一构造参数，8 处调用点改用它 |
| `pages/MyPage.ets` | `arkts-no-structural-typing` ×2（本地 `ShareDataOptions`/`SharePreviewOptions` 类与适配层 `SharedRecord`/`ShareOptions` 不一致） | 直接用适配层的 `SharedRecord` 构造 `SharedData`，`show(context)` 不再传预览选项；删除两个不再使用的本地类 |
| `pages/MyPage.ets` | `ShareDataOptions.utd` 是 `uniformTypeDescriptor.UniformDataType`，而 `SharedRecord.utd` 是 `string` | 统一为 `'general.hyperlink'` 字符串 |

### Android 壳构建验证（已通过）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync_arkui_android_libs.ps1   # 复制 arkui_android_adapter.jar
cd .arkui-x/android
.\gradlew.bat assembleDebug --no-daemon --console=plain
```

结果：**BUILD SUCCESSFUL**（Gradle 9.4.0 + AGP 9.1.1，32 tasks），产物
`.arkui-x/android/app/build/outputs/apk/debug/app-debug.apk`（1.1 MB）。

这说明骨架的 Gradle 工程、以及本次改造的 `AndroidManifest.xml`、`EntryEntryAbilityActivity`、
`WuYinShareBridge`、`MyApplication`、`Theme.WuYin`、`app_icon`、`network_security_config` 全部编译通过。

两点说明：

- AGP 提示 `package="com.wuyin.video"` 属性已废弃（改用 `build.gradle` 的 `namespace`），只是警告；
- 该 APK 里暂时**没有 `assets/arkui-x`**（ArkTS 产物），因为 ArkTS 编译还卡在第八节的 API 门禁。
  门禁清零后重新 `assembleDebug`（或 DevEco 的跨平台构建任务）才会把 `ets/modules.abc`、
  `resources.index`、`module.json` 打进 APK，届时应用才能正常启动。

### 静态自检（已通过）

`python scripts/preflight.py .` 与 `python scripts/check_arkuix_compat.py .` 均为 0 阻断
（后者已按新的 schema 校验 `arkui-x-config.json5` 的字段合法性）。

## 八、跨平台 API 门禁清单（第三步已全部改造）

> 本节的清单是第二步结束时（2026-10-30）的实测结果，**已在第三步全部处理完**：
> `router.replaceUrl` → `compat/RouterCompat`、`Want.action/uri` → `compat/WantCompat`、
> `SEEK_CLOSEST` → `SEEK_PREV_SYNC`、下载/通知/存储/相册等专有调用按能力降级。
> 逐条处理方式与运行时影响见 [ANDROID_APK.md](ANDROID_APK.md) 第三节。保留本节是为了追溯当时的问题面。

按 API 归类的调用点如下（`11706007` 每条对应一个成员检查，同一行可能触发多条）。**这些不是移植引入的**，
是第一步迁移时漏掉、且因为没有真正跑过编译而未被发现的部分。

> 注意：ArkTS 编译器对错误是**分批截断**的，不同轮次的报错集合与条数会变化（观察到的范围 27~64 条，
> 最后一次只报 27 条且没有 `PlayerPage`、`EntryAbility`、`CoPlayLanService` 的条目）。
> 因此**不要以单次报错条数为准**，以下表为准。

| API | 处数 | 位置 | 跨平台建议 |
| --- | --- | --- | --- |
| `router.replaceUrl` | 14 | `LoginPage:386,400,410`、`RegisterPage:323,338,347`、`AccountCenterPage:278,283`、`MyPage:528`、`MessagePage:108`、`TitleRankPage:61`、`FollowListPage:99`、`AvatarUploadPage:50`、`PlatformSnifferPage:88` | ArkUI-X 不支持 `replaceUrl`；在 `common/compat/` 加 `RouterCompat.replaceUrl()`，内部 `try { router.replaceUrl } catch { router.pushUrl }`，或改用 `Navigation` |
| `Want.action` / `Want.uri` | 6 | `EntryAbility:443,555,558,574,585,593` | 通过 `AppStorage`/`Preferences` 把分享参数与 `wuyin://` 参数由平台壳（Android `Intent`、iOS `launchOptions`）显式注入，不要再读 `want.action/uri` |
| `AVPlayer SEEK_CLOSEST` | 5 | `PlayerPage:516,531,1162,1189,2024` | 移入 `common/compat/`，非 HarmonyOS 平台退化为默认 `seek()`（或 `SEEK_PREV_SYNC` 语义的近似实现） |
| `net.connection.getDefaultNet` / `getNetCapabilities` | 4 | `DownloadService:256,262,266`、`PlayerPage:1089` | 加 `NetCompat`：Android/iOS 用 `connection.hasDefaultNet()` 或直接假定有网 |
| `connection.on/off` | 6 | `CoPlayLanService:318,336,350,420,443,514` | 同上，包进 `NetCompat`，不支持时用定时探测兜底 |
| `request.getTask` / `BACKGROUND` / `verifyAccessTokenSync` | 4 | `DownloadService:133,322,365,378` | 加 `DownloadCompat`：非 HarmonyOS 用 `http` 分片下载 + 自维护任务表 |
| `storageStatistics.getFreeSize` | 2 | `DownloadService:330`、`LocalPlaybackService:294` | 包一层 `StorageCompat.getFreeSize()`，失败返回 -1 并跳过空间校验 |
| `notificationManager.cancel` | 1 | `NotificationService:134` | 加 `NotificationCompat`，失败静默 |
| `wantAgent.getWantAgent` | 1 | `NotificationService:78` | 已有 `compat/WantAgentCompat`，改为显式调用它而不是直接 `wantAgent.*` |
| `photoAccessHelper.showAssetsCreationDialog` | 1 | `PlayerPage:1570` | 保存截图/下载：非 HarmonyOS 走 `saveButton`/`filePicker` 或 `@arkui-x.bridge` 调系统相册 |
| `display.getPreferredOrientation` | 1 | `PlayerPage:1396` | 用 `window.getLastWindow().getPreferredOrientation()` 或 `display.getDefaultDisplaySync().rotation` |
| `picker maxSelectNumber` | 1 | `MyPage:1126` | 换成 `maxSelectNumber` 的平台无关写法（`PhotoViewPicker` 的 `maxSelectNumber` 在 ArkUI-X 未支持，可改为单选循环或 `photoAccessHelper` 自选） |

改造方式与第一步一致：`common/compat/` 加适配层 → 调用点换成适配层 → 再跑 `assembleHap`，
直到 `11706007` 归零，此时可以把 `.arkui-x/arkui-x-config.json5` 的 `buildOption.ignoreCrossPlatform` 去掉，
让门禁恢复为"零容忍"。

## 九、未验证项与后续动作

1. **Android APK**：✅ 已产出并验证（`hvigorw assembleApp` → 4 个 ABI APK → 模拟器安装启动通过），
   详见 [ANDROID_APK.md](ANDROID_APK.md)。
2. **iOS**：需 macOS + ArkUI-X SDK（macOS 版）的 `libarkui_ios.xcframework`（见
   `.arkui-x/ios/frameworks/README.md`），并替换 `DEVELOPMENT_TEAM`。
3. **`wuyin://player` 在 iOS 的转发**：`AppDelegate.m` 目前只记日志。ArkUI-X iOS SDK 没有稳定的
   "向运行中 Ability 投递 Want" 的 ObjC 接口，需要按实际 SDK 头文件补 `StageApplication` 调用。
4. **`buildOption.ignoreCrossPlatform`**：保留在配置里（schema 正确、语义正确）。一旦第八节改完，
   建议删掉，让门禁真正生效。
5. **`deviceTypes`**：目前 `phone`、`tablet`。若要装到 HarmonyOS PC/2in1，需补 `2in1`
   （`scripts/preflight.py` 会提示）。

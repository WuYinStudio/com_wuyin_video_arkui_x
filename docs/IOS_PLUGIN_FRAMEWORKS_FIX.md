# iOS 网络 / 页面跳转 / 设置页闪退修复记录

> 适用工程：`F:\APPS\Haps\Arkui_x\repo514`（GitHub `WuYinStudio/com_wuyin_video_arkui_x`）  
> 交付版本：5.1.4（versionCode 5010004）  
> 修复日期：2026-11-08

## 1. 现象

在 iOS 模拟器/真机包中：

- 首页提示 `加载失败：TypeError: Cannot read property createBridge of undefined`；
- 其他页面点击后无法跳转；
- 点击「设置」进入设置页时 App 闪退（Xcode 日志 `FATAL` / `SIGABRT`）；
- 运行日志反复出现 `日志写入失败：TypeError: Cannot read property accessSync of undefined`。

## 2. 根因

ArkUI-X 的 macOS SDK 把引擎与 `@ohos.*` 插件拆成**独立动态 framework**：

```text
arkui-x/engine/xcframework/arkui/ios-release/libarkui_ios.xcframework   # 引擎
arkui-x/plugins/api/framework/<arch>/libnet_http.framework             # 网络
arkui-x/plugins/api/framework/<arch>/libfile_fs.framework              # 文件
arkui-x/plugins/api/framework/<arch>/librouter.framework               # 路由
arkui-x/plugins/api/framework/<arch>/libbridge.framework               # 原生桥
arkui-x/plugins/component/framework/<arch>/libarkui_slider.framework  # Slider/Checkbox/Radio 等组件
```

原 Xcode 模板只链接了 `libarkui_ios.xcframework`，没有把插件 framework 加入
`Frameworks`/`Embed Frameworks`。因此：

- `@arkui-x.bridge` → `undefined`，`createBridge` 抛错；
- `@ohos.net.http` → `undefined`，首页请求失败；
- `@ohos.file.fs` / `@ohos.data.preferences` → `undefined`，日志、协议标记、设置持久化失败；
- `@ohos.router` → `undefined`，`router.pushUrl` 不生效；
- `Slider` / `Checkbox` / `Radio` 等组件动态模块缺失，页面挂载时直接
  `FATAL: Can't find checkbox dynamic module`，表现为“点设置闪退 / 跳壁纸页闪退”。

## 3. 修复

新增 `scripts/prepare_ios_plugins.py`：

1. 从 ArkUI-X macOS SDK 读取插件 framework；
2. 按应用实际 import 的 `@ohos.*` 与用到的 ArkUI 组件，计算**传递依赖闭包**；
3. 解压到 `build/ios-plugins/`；
4. 生成 `build/ios-plugins.xcconfig`，写入 `FRAMEWORK_SEARCH_PATHS`、
   `OTHER_LDFLAGS -framework ...`、`LD_RUNPATH_SEARCH_PATHS`。

两个 iOS workflow 在 `xcodebuild` 前调用该脚本，并在构建后把 framework 复制进
`app.app/Frameworks`：

- `.github/workflows/ios-simulator.yml`：`ios-x86_64-simulator`
- `.github/workflows/ios-unsigned.yml`：`ios-arm64-release`

当前闭包包含 36 个插件 framework（22 个 API + 11 个组件 + `libarkui_ios` 由工程链接），
覆盖：

```text
abilityaccessctrl bridge data_preferences data_uniformtypedescriptor deviceinfo
file_fs file_picker file_streamrw multimedia_audio multimedia_media
net_connection net_http net_socket net_websocket pasteboard promptaction request
router security_cryptoframework util util_stream zlib
arkui_calendar/checkbox/gauge/indexer/linearsplit/radio/rating/sidebar/slider/stepper/timepicker
```

同时：

- 首页顶部在 iOS 上固定留 59vp 安全区，避免标题被灵动岛/刘海遮挡；
- CI 通过 `WUYIN_SMOKE=1` 写入 `agreement_accepted.txt` / `smoke_mode.txt`，自动跑网络、
  路由、底部标签页冒烟测试，正式包无该环境变量时不生效。

## 4. 验证

云端模拟器日志（2026-11-07 23:35 UTC，commit `b74e5d8`，25 个插件）：

```text
[SMOKE_STORAGE] filesDir=.../Documents/files agreement=yes
[SMOKE_BRIDGE] battery=100
[SMOKE_HTTP] bridge=200 | {"retcode":"200",...}
[SMOKE_HTTP_DIRECT] code=200
[SMOKE_ROUTE] ok pages/PlayerPage
[SMOKE_ROUTE] ok pages/MessagePage
[SMOKE_ROUTE] ok pages/ForumPage
[SMOKE_ROUTE] ok pages/LoginPage
[SMOKE_ROUTE] ok pages/ThemeStorePage
```

修复前在 `pages/WallpaperPage` 处出现：

```text
[Ace:FATAL] [node_checkbox_modifier.cpp(59)] Can't find checkbox dynamic module
```

该 FATAL 由缺少 `libarkui_checkbox` / `libarkui_slider` 等组件 framework 导致。

补齐 36 个插件后（commit `0fab568`，release
`ios-sim-diag-20261107-235932`）的完整结果：

```text
[SMOKE_ROUTE] ok pages/PlayerPage
[SMOKE_ROUTE] ok pages/MessagePage
[SMOKE_ROUTE] ok pages/ForumPage
[SMOKE_ROUTE] ok pages/LoginPage
[SMOKE_ROUTE] ok pages/ThemeStorePage
[SMOKE_ROUTE] ok pages/WallpaperPage
[SMOKE_ROUTE] ok pages/UpdateLogPage
[SMOKE_ROUTE] ok pages/ScanPage
[SMOKE_ROUTE] ok pages/ShareQrPage
[SMOKE_ROUTE] ok pages/CastControlPage
[SMOKE_TAB] ok settings
[SMOKE_TAB] ok mine
[SMOKE_TAB] ok category
[SMOKE_TAB] ok message
[SMOKE_TAB] ok forum
[SMOKE] ==== done ====
```

- 10/10 页面路由 `push` + `back` 成功，0 fail；
- 设置、我的、分类、消息、论坛 5 个底栏页面全部切换成功，设置页不再闪退；
- 网络桥与 `@ohos.net.http` 均返回 HTTP 200；
- 没有 `FATAL` / `abort` / 组件模块缺失日志。

最终首页截图：`docs/images/ios-home-5.1.4.png`（标题已避开灵动岛）。

## 5. 产物

- GitHub Release：`ios-unsigned-20261107-234412`（commit `0fab568`）
  `app-unsigned.ipa`，54,645,341 bytes
- SHA-256：`DD020AAE7F815B6F04C5E2F02BE09CAF4F95954182A09145A2E9E5449A4D2A74`

未签名 IPA 用于模拟器/重签；上架或真机安装需使用 Apple 开发者证书重签。

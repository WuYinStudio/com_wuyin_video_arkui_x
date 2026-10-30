# iOS 依赖框架目录

Xcode 工程（`.arkui-x/ios/app.xcodeproj`）从这里引用 `libarkui_ios.xcframework`：

```
.arkui-x/ios/frameworks/libarkui_ios.xcframework
```

ArkUI-X SDK 的 iOS 产物需要在 macOS 上获取（Windows 版 SDK 只带 Android 侧库），来源二选一：

1. **ArkUI-X SDK（macOS 版）**：`<arkui-x-sdk>/arkui-x/engine/lib/arkui/ios/` 下的
   `libarkui_ios.framework` / `libarkui_ios.xcframework`，整体复制到本目录并改名为
   `libarkui_ios.xcframework`；
2. **DevEco Studio（macOS）** 生成空白 ArkUI-X 工程时自带的 `frameworks/` 目录，直接复制过来。

Xcode 的 Header Search Paths 已指向：

```
$(SRCROOT)/frameworks/libarkui_ios.xcframework/ios-arm64/libarkui_ios.framework/Headers/include
```

若实际 xcframework 的切片名不同（例如 `ios-arm64_armv7`），同步修改 `project.pbxproj`
中 Debug / Release 两个配置的 `USER_HEADER_SEARCH_PATHS`。

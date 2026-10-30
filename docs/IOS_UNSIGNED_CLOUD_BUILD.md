# iOS 无签名包 / 云构建说明

## 结论

**可以用 macOS 云构建出无签名 iOS 包，但不能在 Windows 上完成。**
“未签名”只省掉 Apple 证书和描述文件，仍然需要 macOS、Xcode 和
`libarkui_ios.xcframework`。

## 当前工程已经准备好的部分

| 内容 | 位置 | 状态 |
| --- | --- | --- |
| iOS Xcode 工程 | `.arkui-x/ios/app.xcodeproj` | 已有 |
| ArkTS 预编译产物 | `.arkui-x/ios/arkui-x/{entry,systemres}` | 已用 `ace build bundle` 在 Windows 生成（约 50 MB） |
| 无签名构建脚本 | `scripts/build_unsigned_ios.sh` | 已添加 |
| GitHub Actions 模板 | `.github/workflows/ios-unsigned.yml` | 已添加 |

`ace build bundle` 在 Windows 上能完成 ArkTS 编译并生成 iOS 资源，只是最后一步
“copy library” 会报一个 ACE 自身的 `newContinue is not defined`；不影响
`entry/ets/modules.abc`、`resources.index` 和 `systemres` 的生成。

## 仍然缺的东西

1. **macOS 构建机**（本机或云 runner）；
2. **`libarkui_ios.xcframework`**：
   - 来自 macOS 版 ArkUI-X 26.0.0 SDK 的 `engine/xcframework/`（或 `engine/framework/`）；
   - 放到 `.arkui-x/ios/frameworks/libarkui_ios.xcframework`；
   - Windows 版 SDK 的 `engine/lib/arkui/` 只有 Android 库，没有这个框架。

没有第 2 项时，Xcode 会在编译 `AppDelegate.m` 的
`#import <libarkui_ios/StageApplication.h>` 时失败。

## 在 macOS 本机构建

```bash
# 1. 放入 libarkui_ios.xcframework
cp -R /path/to/libarkui_ios.xcframework \
  .arkui-x/ios/frameworks/

# 2. 构建无签名 ipa
bash scripts/build_unsigned_ios.sh

# 产物
# build/ios-unsigned/app.app
# build/ios-unsigned/app-unsigned.ipa
```

脚本内部等价于：

```bash
xcodebuild \
  -project .arkui-x/ios/app.xcodeproj \
  -target app \
  -configuration Release \
  -sdk iphoneos \
  CONFIGURATION_BUILD_DIR=build/ios-unsigned/Products \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build
```

然后把 `app.app` 放进 `Payload/` 并压缩为 `.ipa`。

## GitHub Actions 云构建

模板见 `.github/workflows/ios-unsigned.yml`，使用 `macos-14` runner。

1. 把工程推到 GitHub（需要包含 `.arkui-x/ios/arkui-x/` 下的预编译产物；
   `.gitignore` 已取消对该目录的忽略）；
2. 把 `libarkui_ios.xcframework` 打包成 zip，上传到某个可访问 URL；
3. 在仓库 Settings → Secrets and variables → Actions 新建
   `ARKUI_X_IOS_FRAMEWORK_URL`，值为该 zip 的 URL；
4. Actions → **iOS unsigned build** → Run workflow；
5. 运行结束后下载 artifact `wuyin-ios-unsigned-Release`。

> 这个模板没有在本机实际跑过（本机没有 macOS runner），只能算可执行的构建入口；
> 第一次跑如果 Xcode 版本或 SDK 切片不匹配，按日志调整 `runs-on` / Xcode 版本。

## 未签名 ipa 的限制

- 不能直接安装到未越狱的 iPhone；
- 需要 Sideloadly、AltStore、企业证书或 App Store 流程重新签名；
- 适合做 CI 产物、静态检查、后续重签，不适合直接分发。

## 为什么 Windows 不行

- `ace build ios --debug --nosign` 直接返回
  `Error: Please go to your MacOS and build ios.`；
- ArkUI-X hvigor 插件的 iOS 任务用 `isMac()` 判断，Windows 会跳过；
- Windows 没有 `xcodebuild` 和 Apple SDK；
- Windows 版 ArkUI-X SDK 不含 `libarkui_ios.xcframework`。

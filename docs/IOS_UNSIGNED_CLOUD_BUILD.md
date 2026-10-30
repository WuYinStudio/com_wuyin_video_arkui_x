# iOS 无签名包 / 云构建说明

## 结论

**可以用 macOS 云构建出无签名 iOS 包，但不能在 Windows 上完成。**
“未签名”只省掉 Apple 证书和描述文件，仍然需要 macOS、Xcode 和
`libarkui_ios.xcframework`。

好消息是：macOS 版 ArkUI-X SDK 的下载地址是公开的，workflow 可以自动拉取，
**不需要 Apple 账号、证书或 Secret**。

## 当前工程已经准备好的部分

| 内容 | 位置 | 状态 |
| --- | --- | --- |
| iOS Xcode 工程 | `.arkui-x/ios/app.xcodeproj` | 已有 |
| ArkTS 预编译产物 | `.arkui-x/ios/arkui-x/{entry,systemres}` | 已用 `ace build bundle` 在 Windows 生成（约 50 MB） |
| 无签名构建脚本 | `scripts/build_unsigned_ios.sh` | 已添加 |
| GitHub Actions 模板 | `.github/workflows/ios-unsigned.yml` | 已添加，自动下载 macOS SDK |

`ace build bundle` 在 Windows 上能完成 ArkTS 编译并生成 iOS 资源，只是最后一步
“copy library” 会报一个 ACE 自身的 `newContinue is not defined`；不影响
`entry/ets/modules.abc`、`resources.index` 和 `systemres` 的生成。

## macOS SDK / framework

workflow 使用以下公开包（ArkUI-X 26.0.0.28，macOS arm64）：

```text
https://contentcenter-drcn.dbankcdn.cn/pub_1/DevEcoSpace_1_900_9/6f/v3/x-GBbqu3So2gK5Y1dc-Blw/nxSlk9koR_-dKDUKV4c26Q.zip
sha256: ee213c09196d4f0433273b65b7c6665083fbb7cef186257fe4bba382744fc9d0
大小:   542,197,171 bytes
```

解压后取：

```text
arkui-x/engine/xcframework/arkui/ios-release/libarkui_ios.xcframework
```

放到：

```text
.arkui-x/ios/frameworks/libarkui_ios.xcframework
```

这个 xcframework 同时带 `ios-arm64`（真机）和
`ios-arm64_x86_64-simulator`（模拟器）两个切片，头文件路径与工程里的
`USER_HEADER_SEARCH_PATHS` 一致。

## 在 macOS 本机构建

```bash
# 1. 下载 macOS SDK
curl -L --fail -o /tmp/arkui-x-macos.zip \
  "https://contentcenter-drcn.dbankcdn.cn/pub_1/DevEcoSpace_1_900_9/6f/v3/x-GBbqu3So2gK5Y1dc-Blw/nxSlk9koR_-dKDUKV4c26Q.zip"

# 2. 取 framework
unzip -q /tmp/arkui-x-macos.zip \
  'arkui-x/engine/xcframework/arkui/ios-release/libarkui_ios.xcframework/*' \
  -d /tmp/arkui-x-framework
mkdir -p .arkui-x/ios/frameworks
cp -R /tmp/arkui-x-framework/arkui-x/engine/xcframework/arkui/ios-release/libarkui_ios.xcframework \
  .arkui-x/ios/frameworks/

# 3. 构建无签名 ipa
bash scripts/build_unsigned_ios.sh
```

产物：

```text
build/ios-unsigned/app.app
build/ios-unsigned/app-unsigned.ipa
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

1. 工程已推到 GitHub（包含 `.arkui-x/ios/arkui-x/` 预编译产物）；
2. 打开仓库 **Actions → iOS unsigned build → Run workflow**；
3. 第一次运行会下载约 542 MB 的 macOS SDK，之后走 Actions cache；
4. 运行结束后下载 artifact `wuyin-ios-unsigned-Release`。

**不需要配置 Secret。** workflow 会自动校验 SDK sha256、解压出
`libarkui_ios.xcframework`，再执行 `scripts/build_unsigned_ios.sh`。

> 这个模板没有在真实 macOS runner 上跑过；第一次跑如果 Xcode 版本、
> deployment target 或 SDK 切片不匹配，按 Actions 日志调整 `runs-on` /
> Xcode 版本。

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

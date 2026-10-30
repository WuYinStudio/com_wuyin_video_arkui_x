#!/usr/bin/env bash
#
# 在 macOS 上构建无签名 iOS .ipa。
#
# 前置条件：
#   1. macOS + Xcode（xcodebuild 可用）
#   2. .arkui-x/ios/frameworks/libarkui_ios.xcframework
#      —— 从 macOS 版 ArkUI-X SDK 复制，Windows 版 SDK 不含此文件
#   3. .arkui-x/ios/arkui-x/{entry,systemres}
#      —— 已由 `ace build bundle` 预编译并放入本工程
#
# 用法：
#   bash scripts/build_unsigned_ios.sh
#   IOS_CONFIGURATION=Debug bash scripts/build_unsigned_ios.sh
#
# 产物：
#   build/ios-unsigned/app-unsigned.ipa
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT/.arkui-x/ios"
PROJECT="$IOS_DIR/app.xcodeproj"
FRAMEWORK="$IOS_DIR/frameworks/libarkui_ios.xcframework"
ASSETS="$IOS_DIR/arkui-x"
OUT="${IOS_OUT_DIR:-$ROOT/build/ios-unsigned}"
CONFIG="${IOS_CONFIGURATION:-Release}"

log() { printf '[ios-unsigned] %s\n' "$*"; }
die() { printf '[ios-unsigned] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "iOS 构建需要 macOS + Xcode；当前系统是 $(uname -s)。"
fi

command -v xcodebuild >/dev/null 2>&1 \
  || die "找不到 xcodebuild，请安装 Xcode 并执行 xcode-select --install。"

[[ -d "$PROJECT" ]] || die "找不到 Xcode 工程：$PROJECT"
[[ -d "$FRAMEWORK" ]] || die "找不到 iOS 框架：$FRAMEWORK
请把 macOS 版 ArkUI-X SDK 中的 libarkui_ios.xcframework 复制到该目录。"
[[ -f "$ASSETS/entry/ets/modules.abc" ]] || die "缺少 ArkTS 产物：$ASSETS/entry/ets/modules.abc"
[[ -d "$ASSETS/systemres" ]] || die "缺少系统资源：$ASSETS/systemres"

rm -rf "$OUT"
mkdir -p "$OUT/Products" "$OUT/ipa"

log "Xcode: $(xcodebuild -version | tr '\n' ' ')"
log "开始构建 $CONFIG / iphoneos（已关闭代码签名）..."

set +e
xcodebuild \
  -project "$PROJECT" \
  -target app \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$OUT/DerivedData" \
  CONFIGURATION_BUILD_DIR="$OUT/Products" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build
status=$?
set -e

if [[ $status -ne 0 ]]; then
  die "xcodebuild 失败（exit $status）。"
fi

APP="$OUT/Products/app.app"
[[ -d "$APP" ]] || die "构建返回成功，但没有找到产物：$APP"

mkdir -p "$OUT/ipa/Payload"
ditto "$APP" "$OUT/ipa/Payload/app.app"
( cd "$OUT/ipa" && /usr/bin/zip -qry "$OUT/app-unsigned.ipa" Payload )

log "无签名 .app：$APP"
log "无签名 .ipa：$OUT/app-unsigned.ipa"
log "注意：未签名 ipa 不能直接安装到未越狱设备，需要用 Sideloadly/AltStore/企业证书或 App Store 流程重签。"

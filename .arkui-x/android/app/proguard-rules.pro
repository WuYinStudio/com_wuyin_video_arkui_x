# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# 无音影视：ArkUI-X 适配层、BridgePlugin 子类与平台 Activity 不能被裁剪 / 混淆。
-keep class ohos.** { *; }
-keep class com.wuyin.video.** { *; }
-dontwarn ohos.**

# 保留源码行号，便于崩溃栈定位（发布版可按需去掉）。
-keepattributes SourceFile,LineNumberTable

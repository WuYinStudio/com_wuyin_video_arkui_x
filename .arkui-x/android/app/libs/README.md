# app/libs

ArkUI-X 的 Android 适配层与引擎库不随源码分发，用脚本从本机 ArkUI-X SDK 复制：

```powershell
pwsh scripts/sync_arkui_android_libs.ps1                   # 只复制编译必需的 arkui_android_adapter.jar
pwsh scripts/sync_arkui_android_libs.ps1 -WithRuntimeLibs   # 再复制 arm64-v8a 引擎与插件 .so
```

- 编译期：只需要 `arkui_android_adapter.jar`（提供 `ohos.stage.ability.adapter.*`、
  `ohos.ace.adapter.capability.bridge.*` 等类）；
- 运行期：还需要 `libs/arm64-v8a/*.so`（`libarkui_android.so`、`libhilog.so` 及各插件）。

`app/build.gradle` 里已配置 `implementation fileTree(dir: 'libs', include: ['*.jar', '*.aar'])`，
所以复制进来即可参与编译，不需要改 Gradle 脚本。

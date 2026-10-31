# 构建故障排查（Windows / DevEco 26）

> 症状按报错原文组织，先看能不能对号入座。

## 1. `CHECK FAILED: (arenas_) != nullptr` / `Failed to execute es2abc`

```
> hvigor ERROR: 10311009 ArkTS: ERROR
Error Message: Failed to execute es2abc.
1 ERROR: CHECK FAILED: (arenas_) != nullptr
  IN: ../../arkcompiler/runtime_core/libpandabase/mem/arena_allocator.cpp:31
```

**这不是代码错误**，是 ArkTS 字节码生成器 `es2abc` 在原生侧申请内存失败（arena 分配为 null）。
本机提交内存（Committed Bytes）逼近上限时必现：

```powershell
(Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit').CounterSamples |
  ForEach-Object { "$($_.Path)=$([math]::Round($_.CookedValue/1GB,2))GB" }
```

本机实测：`Committed 53.8 GB / Limit 56.2 GB`、`Available 0 MB` 时必炸；释放到 ~2 GB 余量后同一命令
一次通过。常见诱因：

- DevEco 开着 + 浏览器 / QQ / 音乐播放器同时占用；
- 之前失败的 hvigor 进程没退干净（`node.exe` / `java.exe` 常驻各占几百 MB）；
- Windows 托管页面文件不够大（页面文件只有 25.6 GB 时上限约 56 GB）。

**处理顺序**

1. 用包装脚本构建（已限制 node / JVM 堆，把内存让给 es2abc）：

   ```powershell
   pwsh scripts/build_hap.ps1                    # assembleHap
   pwsh scripts/build_hap.ps1 -Task assembleApp   # 出 APK
   ```

   脚本会设置：`NODE_OPTIONS=--max-old-space-size=2048`、
   `JAVA_TOOL_OPTIONS=-Xmx512m -XX:+UseSerialGC -Xshare:off`。

2. 还失败就清残留进程：

   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='java.exe'" |
     Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine
   ```

   把父进程已经退出的（ParentProcessId 查不到）`Stop-Process -Force` 掉。

3. 再不行就关 DevEco / 重启系统。重启是清掉「已提交但没人认领」那部分内存最直接的办法
   （本机长跑一天后该值会漂到 54 GB 且不回落）。

## 2. `Unable to start the daemon process` / `页面文件太小`

`:app:packageDebug` 或 `gradlew` 报：

```
os::commit_memory(...) failed; error='页面文件太小，无法完成操作。'
# Native memory allocation (mmap) failed to map 524288000 bytes. Error detail: G1 virtual space
```

Gradle 默认 G1 会预留大段虚拟空间，低提交内存下直接起不来。`.arkui-x/android/gradle.properties` 已经改成：

```properties
org.gradle.jvmargs=-Xms128m -Xmx1024m -XX:+UseSerialGC -XX:MaxMetaspaceSize=384m -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.workers.max=2
```

## 3. `Failed to commit static region #1 (ReadOnly)`

打包阶段 JVM 的 Class Data Sharing 也要一段连续内存。构建时加：

```powershell
$env:JAVA_TOOL_OPTIONS='-Xshare:off -Xmx512m -XX:+UseSerialGC'
```

`build_hap.ps1` 已包含该设置。

## 4. 脚本类工具的两个坑

- **PowerShell 5.1 读 UTF-8 无 BOM 的中文脚本会乱码并解析失败**：`scripts/*.ps1` 必须存成
  UTF-8 with BOM。改完脚本记得检查首三字节是 `239,187,191`。
- **DevEco 写的 `local.properties` 会转义路径**（`arkui-x.dir=F\:\\APPS\\ArkUI-X\\Sdk`）：
  `scripts/sync_arkui_android_libs.ps1` 里的 `ConvertFrom-PropertyPath` 负责还原，不要删。

## 5. 判定「这次是不是环境问题」

同一份代码、同一条命令，隔几分钟重跑就过 = 环境问题（内存 / 残留进程）；
每次都挂在同一个文件同一行 = 代码或资源问题，去看 `.hvigor/outputs/build-logs/build.log`。

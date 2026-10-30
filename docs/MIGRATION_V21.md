# 迁移说明 · 无音影视 → 纯空壳框架（API 26）

本次交付把 v2.0（液态玻璃 UI 重设计版）的**全部源码**迁入「无音影视纯空壳框架」工程，
只替换工程底座与构建配置，业务代码、页面、视觉一行未改。

## 一、采用空壳框架的部分

| 项 | 取值 | 说明 |
| --- | --- | --- |
| `hapcode-project.json` | `projectId = 73b282dc-c66b-4207-b302-42c4b30cc2de` | 换成空壳工程的项目标识；`fileCount / totalBytes / updatedAt` 已按实际重算（86 / 3002040） |
| `build-profile.json5` | 与空壳逐字相同 | `compileSdkVersion / targetSdkVersion = 26.0.0`、`compatibleSdkVersion = 6.1.1(24)`、`strictMode.useNormalizedOHMUrl` |
| `entry/build-profile.json5` | 用空壳版 | 去掉了 v2.0 里的 `buildOption.nativeLib.debugSymbol.strip`（那是为旧的原生播放库调试加的，本工程已无原生库） |
| `hvigorfile.ts` / `entry/hvigorfile.ts` / `hvigor/hvigor-config.json5` / `code-linter.json5` | 与空壳逐字相同 | 构建与 lint 配置 |
| `entry/obfuscation-rules.txt` | 用空壳版 | 混淆规则（release 未开启） |
| `AppScope/resources` | 用空壳版 | `app_name` 字符串 + 应用图标（与 v2.0 同一张图） |

## 二、从 v2.0 迁入的部分

- `entry/src/main/ets/` 全部 50 个 `.ets`（23,165 行）：20 个页面、30 个 `common/*Service`、3 个 component、`EntryAbility`、`ShareExtensionAbility`。
- `entry/src/main/module.json5`：必须用 v2.0 版——空壳的没有 `INTERNET / GET_NETWORK_INFO / DISTRIBUTED_DATASYNC` 三项权限，也没有 `querySchemes` 和 `ShareExtensionAbility` 分享扩展，直接套空壳会导致联网全挂、华为分享收不到协播邀请。
- `entry/src/main/resources/`：`base/element/color.json`（含 `category_*` 10 项）、`dark/element/color.json`、`base/media/category_empty.svg`、`base/profile/main_pages.json`（4 个入口页）。
- 根目录设计文档：`UI_DESIGN_SPEC.md`、`CHANGELOG_UI.md`、`QUEST3_INTEGRATION.md`、`DANMAKU_*`、`COPLAY_*`、`HUAWEI_SHARE_JSON_FIX.md`、`PATCH_SUMMARY.md`、`弹弹play接入说明.md`、`aigc-metadata.json`。

## 三、依赖调整（唯一的功能相关内容）

| 依赖 | 处理 | 原因 |
| --- | --- | --- |
| `@tencent/qq-open-sdk` | **保留**（根 + entry 两处 `oh-package.json5`） | `common/TencentSdkService.ets` 直接 `import * as TencentQQSdk from '@tencent/qq-open-sdk'`，`EntryAbility` 冷启动时初始化，删除会编译失败并让 QQ 登录不可用 |
| `@ohos/ijkplayer` | **删除** | 声明了但全工程没有任何 import（播放器走系统 `@kit.MediaKit` 的 AVPlayer；`SettingPage`/`AppState` 里的 `'ijk'` 只是播放内核偏好值字符串，不是这个包）。留着会在 `ohpm install` 阶段多拉一个没人用的包 |

## 四、与原工程的差异清单（逐字节对比结果）

```
entry/src/main/ets/**                完全一致（50 个文件）
entry/src/main/resources/**          完全一致（6 个文件）
entry/src/main/module.json5          完全一致
```

实际改动只有 5 个文件：

```
hapcode-project.json                 新 projectId + 重算计数
entry/build-profile.json5            改用空壳版（无 nativeLib 段）
oh-package.json5                     去掉 @ohos/ijkplayer
entry/oh-package.json5               去掉 @ohos/ijkplayer
AppScope/app.json5                   保持 无音工作室 / 1.2.7 / versionCode 1000207
```

`AppScope/app.json5` 没有采用空壳的 `HapKit / 1.0.0 / versionCode 1000000`：那是脚手架占位值，
versionCode 从 1000207 退到 1000000 会导致已安装设备无法覆盖升级。若这次要发版，
把 `versionCode` 改成大于 1000207 的值（例如 `1000208`）、`versionName` 改成对应版本号即可。

## 五、静态自检结果

| 检查项 | 结果 |
| --- | --- |
| 15 个 `.json5 / .json` 配置解析 | 全部通过（含 `module.json5` 里的 `//` 注释） |
| 50 个 `.ets` 括号配平（去注释/字符串后） | 全部配平 |
| 相对 import 解析 + 导出符号核对 | 无缺失、无多余导出 |
| `$r('app.color/media/string.*')` 引用 | 全部有定义 / 有文件 |
| `module.json5` 的 `srcEntry / icon / label / description / startWindow*` | 全部命中 |
| `main_pages.json` 注册页与文件 | 4/4 命中 |
| `$r('sys.symbol.*')` | 全部在工程白名单内，未引入新符号 |
| `ForEach` 第三参数（key 生成函数） | 全部具备 |

## 六、迁移时发现的遗留问题（本次**未改动**，属原工程既有问题）

1. **`用户协议` 在登录/注册页点了没反应**（真实缺陷）
   `LoginPage.ets:431` 与 `RegisterPage.ets:297` 调 `router.pushUrl({ url: 'pages/UserAgreementPage' })`，
   但 `main_pages.json` 只注册了 `Index / PlayerPage / LoginPage / RegisterPage`，
   且 `UserAgreementPage.ets` 是 `@Component export struct`（没有 `@Entry`，只被 `Index` 当子组件内联用）。
   结果是 pushUrl 报 100002 页面不存在。修法二选一：
   - 新增一个 `@Entry` 的只读协议页（复用现有玻璃阅读卡样式）+ 注册到 `main_pages.json`，两处跳转改指它；
   - 或把两处跳转改成 `CustomDialog` 弹出协议。

2. `PlayerPage.ets:1833` 用了 `.position()`、`:1824-1825` 用了数组展开 `[...]`，
   与 `UI_DESIGN_SPEC.md` 第 5 节第 3、5 条相违；但这是弹幕轨道的既有功能代码（不是本次视觉重设计引入的），
   且工程此前已在真机发版（versionCode 1000207），故未改动。

3. 空壳自带的 `hapcode-ux.json` 没有带进本工程：它里面是脚手架演示内容（"我的鸿蒙应用 / 拖动组件…"），
   和本项目无关。若 HapCode 客户端需要这个文件才能打开工程，把空壳里的原文件拷回根目录即可。

4. 本环境没有 DevEco Studio / hvigor / HarmonyOS SDK，**本次未编译**。
   上面的结论全部来自静态检查，仍需在 DevEco Studio（API 26）里编译一次确认。

## 七、首轮云构建修复（HB-SERVER-BUILD-COMPILE）

首轮云构建报 7 个 ArkTS 错误，全部是**自定义组件成员名与 `CustomComponent` 基类属性撞名**，
与业务代码无关：

```
Property 'blur'    in GlassSearchBar      is not assignable to the same property in base type 'CustomComponent'
Property 'size'    in GlassIconButton     ...
Property 'height'  in SegmentedGlassTabs  ...
Property 'blur'    in PageHeader          ...
Property 'padding' in GlassCard           ...
Property 'blur'    in GlassCard           ...
```

ArkUI 的 `@Component struct` 天然继承 `CommonAttribute` 的全部属性方法（`width / height / size / padding /
blur / …`），成员名一旦重名，类型（number / boolean / () => number）就对不上基类的 setter 签名。

修法：**只改名，不动逻辑**，同时同步 12 处调用点。

| 组件 | 旧成员 | 新成员 | 文件 |
| --- | --- | --- | --- |
| `GlassSearchBar` | `blur()` | `glassBlurRadius()` | `common/UiWidgets.ets` |
| `PageHeader` | `blur()` | `glassBlurRadius()` | `common/UiWidgets.ets` |
| `GlassIconButton` | `size` | `iconSize` | `common/UiWidgets.ets` + 9 处调用 |
| `SegmentedGlassTabs` | `height` | `trackHeight` | `common/UiWidgets.ets` + 3 处调用 |
| `GlassCard` | `padding` | `contentPadding` | `common/UiWidgets.ets`（该组件暂无调用点） |
| `GlassCard` | `blur` | `withBlur` | `common/UiWidgets.ets`（该组件暂无调用点） |

调用点同步清单（只改参数名，实参值未变）：

```
pages/DownloadPage.ets    GlassIconButton    size -> iconSize
pages/FavoritePage.ets    GlassIconButton    size -> iconSize
pages/HomePage.ets        GlassIconButton    size -> iconSize   ×2
pages/HomePage.ets        SegmentedGlassTabs height -> trackHeight
pages/MyPage.ets          GlassIconButton    size -> iconSize
pages/PlayHistoryPage.ets GlassIconButton    size -> iconSize
pages/SearchPage.ets      GlassIconButton    size -> iconSize   ×2
pages/SearchPage.ets      SegmentedGlassTabs height -> trackHeight
pages/SettingPage.ets     GlassIconButton    size -> iconSize
pages/TapUI.ets           SegmentedGlassTabs height -> trackHeight
```

`UI_DESIGN_SPEC.md` 第 3 节的组件 API 已同步，并补了"成员名不能与 `CommonAttribute` 属性重名"的禁忌说明，
避免后续加组件再踩同一个坑。

改名后重新做了全量静态检查：50 个 `.ets` 括号配平（用正则字面量感知的词法器，规避了 `/[^\]\n]/` 这类
字符串误判）、import 与导出符号、`$r` 资源引用、系统符号白名单、成员撞名——**全部通过**。
剩下的已知问题是第六节第 1 条那个 `UserAgreementPage` 路由未注册（只是运行时点了没反应，不影响编译）。

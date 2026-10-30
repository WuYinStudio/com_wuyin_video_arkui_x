# 无音影视 · 液态玻璃 UI 重设计说明

本次改动**只重做视觉层**：功能、业务逻辑、状态、路由、持久化、播放器内核、协播/投屏/弹幕等全部保持原样。

## 一、新增文件

| 文件 | 说明 |
| --- | --- |
| `entry/src/main/ets/common/Ui.ets` | 设计令牌层：深浅两套配色、圆角/间距/字阶、多端断点、材质强度换算、影片占位封面色 |
| `entry/src/main/ets/common/UiWidgets.ets` | 液态玻璃组件库：`AuroraBackdrop`、`GlassSearchBar`、`GlassSearchEntry`、`GlassIconButton`、`GlassChip`、`SegmentedGlassTabs`、`ProgressiveBlur`、`LiquidNav`、`PageHeader`、`SectionHeader`、`GlassCard`、`PrimaryButton`、`GhostButton`、`EmptyState` |
| `UI_DESIGN_SPEC.md` | 设计规范与组件 API（后续迭代照此扩展） |

## 二、设计语言

- **底色**：深色 `#070A11 → #0B1120`，浅色 `#F4F6FB → #E8EEF9`；上面叠 3 团极光柔光（紫 / 青 / 玫），
  用 `radialGradient` 实现，零模糊节点开销。
- **液态玻璃配方**（全应用统一）：半透明玻璃底色 + `backdropBlur` + 118° 斜向高光 + 1vp 描边 + 柔和投影 +
  完全圆角。深浅模式各有一套 alpha，浅色模式用极淡墨蓝细边保证白底上也有轮廓。
- **品牌渐变**：`#4B7BFF → #6E6BFF → #9B5CFF`，只用在每页唯一的主行动点。
- **字号/圆角/间距**：手机 16 边距、平板 24、宽屏 32；卡片 18~26 圆角；内容在宽屏居中限宽 1180。

## 三、四个重点交互的实现

### 1. 底部液态玻璃栏（`LiquidNav`）

- 悬浮胶囊玻璃栏，五个入口沿用原路由 `home / category / manage / settings / mine`。
- 选中项背后是一枚**圆形液态玻璃球**：玻璃渐变底 + 外圈品牌描边 + 内圈折射高光 + 左上柔光斑 + 品牌色光晕。
- 切换 Tab 时：
  - 球体 460ms 缓动滑到新位置；
  - 同时"先横向拉长 1.26、纵向压扁 0.82，150ms 后回弹成正圆"，形成液体被惯性甩过去的观感；
  - 另有半径 0.92、透明度更低的**尾迹球**以 640ms `Curve.Friction` 跟随，形成拖影。
- 向下滚动时整条底栏（含渐进模糊带）一起下沉隐藏，向上滚动立即回落（沿用 `NavigationScroll` 的显隐信号）。
- 平板/宽屏自动加宽到 620vp 并加高；横屏手机自动压缩到 62vp 高、48vp 球、9.5vp 标签。

### 2. 底栏上方的渐进模糊（`ProgressiveBlur`）

- 把固定高度（手机 78vp / 平板 96vp / 横屏 54vp）的条带切成 12~14 条水平窄带，**每条窄带单独**
  `backdropBlur`，模糊半径按 `(1 - i/n)^1.25` 从"紧贴底栏处最大"平滑衰减到顶部的 0。
- 因为每条窄带只覆盖自己那一条，所以是真正的**竖直方向渐变模糊**，而不是整片糊死。
- 条带之外（正文区域）**没有任何节点**，所以正文永不被糊；模糊带宽固定，页面滚动不会改变它的边界。
- 最后叠一层"透明 → 玻璃色"的竖直渐变：既掩盖窄带之间的接缝，又让模糊区与底栏玻璃底自然衔接。
- 与底栏同属一个容器，滚动隐藏时一起下沉。

### 3. 所有页面的搜索输入条（`GlassSearchBar` / `GlassSearchEntry`）

同一份组件、同一套材质：玻璃底 + 背景模糊 + 斜向高光 + 1vp 描边 + 聚焦时品牌色描边与光晕放大。
首页、搜索页、分类页（只读入口）、播放器弹幕输入条、登录/注册/设置表单输入框全部对齐这一材质。

### 4. Tab 切换的圆形轮廓（`SegmentedGlassTabs`）

题材分组 / 管理页三个子页的 Tab 是一枚**完全圆角**的玻璃胶囊指示器，随选中项 460ms 缓动滑动，
并带同样的"拉长回弹"液体效果；端点保持圆形（`borderRadius = 高度/2`）。

## 四、深浅模式与多端

- 所有颜色来自 `Ui.*(dark)`，`dark` 由 `AppStorage('darkTheme')` 驱动，与原有"跟随系统/深色/浅色"设置联动；
  每个玻璃组件自己 `@StorageLink('darkTheme')`，不需要页面传色值。
- 断点：`<600` 手机单列、`600~1000` 平板双列、`>=1000` 宽屏 3~4 列；内容居中限宽 1180。
- 横屏：首页轮播高度、底栏高度（70→62）、模糊带高度（78→54）都会自动收缩，避免半屏被遮挡。
- 全局沉浸强度（`immersiveConfig`）继续生效：把设置里的模糊/透明度映射为玻璃强度，
  关掉材质时玻璃退化为半透明卡片，不会出现"关不掉"的模糊。

### 底栏占位高度（`navClearance`）

底栏 + 渐进模糊带 + 手势条会盖住页面底部约 180vp。宿主 `HomePage` 把这段高度换算成
`AppStorage('navClearance')` 发布出去，搜索页、分类页、设置页、我的页、文件管理页读取它作为列表末尾的
底部内边距——保证最后一条内容能完整滚到模糊带上方，而不是永远糊在底栏下面。

## 五、页面改动一览

| 页面 | 改动 |
| --- | --- |
| 首页 `HomePage` | 全新页头（品牌标 + 玻璃搜索 + 移动胶囊题材 Tab）、电影感轮播（评分/排名/年份/集数胶囊 + 海报玻璃框 + 品牌播放胶囊 + 右上页码）、快捷入口玻璃磁贴、综艺横向海报流、精选影片网格、液态玻璃底栏 + 渐进模糊 |
| 搜索 `SearchPage` | 吸顶玻璃页头（返回 + 玻璃搜索条）、玻璃线路抽屉（顶部手柄 + 选中勾）、热榜玻璃卡、`GlassChip` 热词流、结果卡（3:4 海报 + 分类胶囊 + 播放圆钮）、玻璃空态 |
| 分类 `CategoryPage` | TapUI 页头不变；筛选面板玻璃化（可折叠、玻璃胶囊筛选组）、瀑布流卡片改为与 `FilmTile` 同语言（题材渐变占位 + 评分角标 + hover 抬升）、骨架屏与空态重绘 |
| 管理 `ManagePage` | 渐变底 + 极光；摘要文字改令牌色；三个子页（历史/收藏/下载）全部卡片化 |
| 设置 `SettingPage` | 页头玻璃胶囊、平板左侧玻璃侧栏 + 手机顶部玻璃分段、五个分组玻璃卡片、玻璃输入胶囊（聚焦光晕）、日志/清空弹窗玻璃化 |
| 我的 `MyPage` | 用户玻璃卡（渐变圆环头像 + 会员标签）、数据摘要、功能宫格、分组玻璃列表、登录面板玻璃化 |
| 登录/注册 | 品牌页头（渐变 Logo + slogan）+ 520vp 玻璃表单卡 + 同款输入胶囊（聚焦光晕）+ 渐变主按钮 |
| 用户协议 | 页头 + 玻璃阅读卡（行高 1.7）+ 渐变同意按钮 |
| 播放器 `PlayerPage` | 顶栏、底部控制条、倍速/线路/选集/弹层、弹幕设置面板、弹幕输入条改为玻璃材质（播放逻辑零改动） |
| 会话弹窗 `MediaSessionDialog` | 弹窗容器、标题、关闭钮、4 个输入框、18 个按钮、设备列表统一玻璃材质 |
| 启动闪屏 `Index` | 协议状态恢复期间显示品牌闪屏，替代原来的纯色块 |

## 六、改动文件清单

```
新增  entry/src/main/ets/common/Ui.ets
新增  entry/src/main/ets/common/UiWidgets.ets
新增  UI_DESIGN_SPEC.md
新增  CHANGELOG_UI.md

重写  entry/src/main/ets/pages/HomePage.ets        (1122 → 1326 行)
重写  entry/src/main/ets/pages/TapUI.ets           (170 → 112 行)
重写  entry/src/main/ets/pages/Shared.ets          (52 → 162 行)
改造  entry/src/main/ets/pages/SearchPage.ets      (651 → 909 行)
改造  entry/src/main/ets/pages/CategoryPage.ets    (1140 → 1234 行)
改造  entry/src/main/ets/pages/ManagePage.ets      (213 → 231 行)
改造  entry/src/main/ets/pages/MyPage.ets          (1566 → 1856 行)
改造  entry/src/main/ets/pages/ProfilePage.ets     (43 → 116 行)
改造  entry/src/main/ets/pages/SettingPage.ets     (751 → 1155 行)
改造  entry/src/main/ets/pages/LoginPage.ets       (597 → 795 行)
改造  entry/src/main/ets/pages/RegisterPage.ets    (530 → 796 行)
改造  entry/src/main/ets/pages/UserAgreementPage.ets (169 → 216 行)
改造  entry/src/main/ets/pages/FavoritePage.ets    (220 → 345 行)
改造  entry/src/main/ets/pages/DownloadPage.ets    (391 → 589 行)
改造  entry/src/main/ets/pages/PlayHistoryPage.ets (291 → 483 行)
改造  entry/src/main/ets/pages/PlayerPage.ets      (2050 → 2139 行，仅外观层)
改造  entry/src/main/ets/components/MediaSessionDialog.ets (1362 → 1385 行，仅外观层)
改造  entry/src/main/ets/pages/Index.ets           (159 → 187 行，品牌闪屏)
改造  entry/src/main/resources/base/element/color.json
改造  entry/src/main/resources/dark/element/color.json
```

未改动：`module.json5`、`main_pages.json`、`build-profile.json5`、`oh-package.json5`、所有 `common/*Service.ets`、
`entryability/`、`shareextensionability/`、播放内核与协播/投屏/弹幕业务代码。

## 七、验证情况

- 本环境**没有 DevEco Studio / hvigor / HarmonyOS SDK**，无法编译或真机运行，
  因此本次交付为**静态代码改动**，需在 DevEco Studio（API 26）中编译验证。
- 已做的静态自检：全部 `.ets` 括号配平、新增导入符号与组件库导出一一对应、
  无旧版写死色残留（播放器等深色专用界面除外）、无 `.position()` 绝对定位。
- 兼容性提示：
  - `ProgressiveBlur` 用了 12~14 层 `backdropBlur`，是本方案唯一的重绘开销点；
    低端机若出现掉帧，把 `LiquidNav` 里的 `slices` 从 12 调到 8 即可（模糊仍连续，只是接缝略明显）。
  - `$r('sys.symbol.*')` 只使用了工程中原本已出现的符号名，未引入新系统资源。

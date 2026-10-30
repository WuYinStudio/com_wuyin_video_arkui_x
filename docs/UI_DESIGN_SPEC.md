# 无音影视 v2.0 · 液态玻璃 UI 重设计规范（供实现参考）

> 本文件是本次「整体 UI 重设计」的唯一视觉与接口约定。所有页面必须严格按此规范改视觉，
> **功能、业务逻辑、状态、路由、持久化一律不改**。只允许改「长什么样」，不允许改「做什么」。

## 0. 已完成的文件（参考实现，不要修改）

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/ets/common/Ui.ets` | 设计令牌：颜色 / 圆角 / 间距 / 断点 / 字阶 / 材质强度 |
| `entry/src/main/ets/common/UiWidgets.ets` | 液态玻璃组件库：背景、搜索条、分段 Tab、底栏、页头、卡片、按钮、空状态 |
| `entry/src/main/ets/pages/HomePage.ets` | 首页（重做完成）：页头、搜索、题材分段、轮播、快捷入口、综艺、精选网格、底栏 |
| `entry/src/main/ets/pages/Shared.ets` | `FilmTile` 影片卡、`PageTitle` |
| `entry/src/main/ets/pages/TapUI.ets` | 管理/分类页顶部（标题 + 搜索入口 + 分段 Tab） |

**改视觉之前先读 `HomePage.ets` 与 `Shared.ets`**，它们展示了本规范的全部写法（玻璃配方、
深浅模式取值、断点、按压反馈、无障碍文案）。

## 1. 设计语言

- 关键词：**液态玻璃（Liquid Glass）· 极光柔光 · 大圆角 · 克制的品牌渐变**。
- 背景两层：页面底色 `Ui.pageBg(dark)` → `Ui.pageBgAlt(dark)` 的竖向渐变，最上面叠一层
  `<AuroraBackdrop>`（三团极光柔光，不拦截手势）。
- 卡片：半透明玻璃 + 1vp 亮描边 + 柔和投影 + 18~24vp 圆角；不要纯灰底、不要直角、不要厚黑边。
- 主色渐变：`Ui.BRAND_FROM → Ui.BRAND_MID → Ui.BRAND_TO`，只用于**一个页面唯一的主行动点**
  （搜索按钮、播放按钮、保存按钮）。其余按钮用玻璃胶囊 `GhostButton`。
- 深浅模式：**所有颜色必须走 `Ui.*(dark)` 或 `Ui.*()`**，禁止再出现 `'#1D3048'` 这类写死的
  深浅二元色；媒体/海报上的文字可以固定用白色（`#FFFFFF` / `#E6FFFFFF`）并加深色渐变底。
- 动效：时长统一用 `UiMotion.PRESS/FAST/BASE/SLOW/LIQUID`，缓动统一 `Curve.FastOutSlowIn`
  （液体位移可在个别处用 `Curve.Friction`）。

## 2. 令牌 API（`import { Ui, UiMotion } from '../common/Ui';`）

```ts
// 背景 / 文字
Ui.pageBg(dark) / Ui.pageBgAlt(dark)
Ui.auroraViolet(dark) / Ui.auroraCyan(dark) / Ui.auroraRose(dark) / Ui.auroraFade()
Ui.ink(dark) / Ui.inkSoft(dark) / Ui.inkFaint(dark)
// 主色
Ui.accent(dark) / Ui.accentStrong(dark) / Ui.accentSoft(dark) / Ui.accentRing(dark) / Ui.accentGlow(dark)
Ui.gold(dark) / Ui.goldSoft(dark)
// 玻璃
Ui.glassTint(dark) / Ui.glassTintStrong(dark) / Ui.glassTintSoft(dark)
Ui.glassRing(dark) / Ui.glassRingSoft(dark) / Ui.glassRingAccent(dark)
Ui.glassSheenTop(dark) / Ui.glassSheenMid(dark) / Ui.glassSheenClear()
Ui.shadow(dark) / Ui.shadowSoft(dark)
// 卡片 / 分割线
Ui.card(dark) / Ui.cardTop(dark) / Ui.cardBottom(dark) / Ui.cardBorder(dark) / Ui.cardBorderSoft(dark) / Ui.divider(dark)
// 功能色
Ui.danger(dark) / Ui.success(dark) / Ui.scrim(dark)
// 圆角 / 间距
Ui.R_XS=10 R_SM=14 R_MD=18 R_LG=24 R_XL=30 R_PILL=999
Ui.S_XS=6 S_SM=10 S_MD=14 S_LG=18 S_XL=24 S_XXL=32
// 多端断点
Ui.isTablet(w) /*>=600*/ Ui.isWide(w) /*>=1000*/ Ui.isCompact(w) /*<380*/
Ui.gutter(w) /*16/24/32*/ Ui.contentMax(w) Ui.columns(w) /*1/2/3/4*/
Ui.fsDisplay(w) Ui.fsHero(w) Ui.fsSection(w) Ui.fsTitle(w) Ui.fsBody(w) Ui.fsCaption(w)
// 材质
Ui.blur(enabled, configured) / Ui.glassBlur(enabled, configured)
// 影片占位封面
Ui.genreTop(genre, dark) / Ui.genreBottom(genre, dark) / Ui.genreGlyph(genre)
```

`UiMotion.PRESS=140 FAST=180 BASE=240 SLOW=380 LIQUID=460`

## 3. 组件 API（`import {...} from '../common/UiWidgets';`）

组件内部已各自 `@StorageLink('darkTheme')` 与 `@StorageLink('immersiveConfig')`，
**调用方不需要传 dark / blur**，主题和材质强度自动同步。

```ts
AuroraBackdrop({ intensity?: number })                       // 铺满父容器，绝对不要传 width/height

GlassSearchBar({                                             // 液态玻璃搜索条（所有搜索输入条都用它）
  query: string, placeholder?: string, showButton?: boolean, compact?: boolean,
  onQueryChange: (text: string) => void,
  onSubmit: () => void,
  onFocusChange?: (focused: boolean) => void
})

GlassSearchEntry({ placeholder?: string, compact?: boolean, onTap: () => void })  // 只读搜索入口

GlassIconButton({ iconSize?: number, strong?: boolean, symbol: Resource,
  accessibilityLabel: string, onTap: () => void })

GlassChip({ label: string, selected?: boolean, emphasize?: boolean, compact?: boolean, onTap?: () => void })

SegmentedGlassTabs({ labels: string[], active: number, trackWidth: number,
  trackHeight?: number, compact?: boolean, onSelect: (index: number) => void })

LiquidNav({ viewportWidth: number, safeBottom: number })     // 首页专用（含渐进模糊 + 圆形液体指示器）

PageHeader({ title: string, subtitle?: string, showBack?: boolean,
  actionText?: string, gutter?: number,
  onBack?: () => void, onAction?: () => void })              // 自带状态栏安全区，子页面直接用

SectionHeader({ title: string, subtitle?: string, actionText?: string,
  viewportWidth: number, onAction?: () => void })

GlassCard({ radius?: number, contentPadding?: number, withBlur?: boolean, strong?: boolean }) {
  // 尾随闭包放内容
}

PrimaryButton({ label: string, compact?: boolean, onTap: () => void })
GhostButton({ label: string, compact?: boolean, onTap: () => void })
EmptyState({ title: string, hint?: string, glyph?: string, onTap?: () => void })
```

> **命名禁忌（API 26 编译器强制）**：`@Component struct` 的成员名不能与 `CustomComponent` / `CommonAttribute`
> 的属性重名，否则报 `Property 'xxx' in type 'TheStruct' is not assignable to the same property in base type
> 'CustomComponent'`。已因此改名的成员：`blur()` → `glassBlurRadius()`（`GlassSearchBar` / `PageHeader`）、
> `size` → `iconSize`（`GlassIconButton`）、`height` → `trackHeight`（`SegmentedGlassTabs`）、
> `padding` → `contentPadding`、`blur` → `withBlur`（`GlassCard`）。
> 新增组件时同理：**不要**用 `width / height / size / padding / margin / blur / opacity / position / scale /
> rotate / translate / clip / shadow / border / enabled / visibility` 等属性名做成员名。

## 4. 每个页面的具体要求

统一要求（所有页面）：

1. 根容器底色改成：`Column().linearGradient({angle:180, colors:[[Ui.pageBg(dark),0],[Ui.pageBgAlt(dark),1]]})`
   + 第一层放 `<AuroraBackdrop>`（在 Stack 里，注意不要挡手势）。
2. 顶部标题改成 `PageHeader`（内嵌页）或自绘玻璃页头；**不要在正文里再画实色标题栏**。
3. 搜索输入条：**必须**换成 `GlassSearchBar`（可输入）或 `GlassSearchEntry`（只跳转）。
4. 列表卡片：圆角 18~24、`Ui.card/·cardBorder`、投影 `Ui.shadowSoft`、间距 12~14、按下 `scale(0.97)`。
5. 按钮：主行动 `PrimaryButton`，其余 `GhostButton` / `GlassChip` / `GlassIconButton`。
6. 空状态 / 错误 / 加载中：用 `EmptyState` 或"玻璃卡片 + LoadingProgress"的统一形态。
7. 多端：内容宽度用 `Ui.gutter(w)`、`Ui.columns(w)`、`Ui.fsXxx(w)`；平板（>=600）字体与内边距放大，
   列表列数 >=2；横屏手机（宽>高）不要出现半屏空条。
8. 深浅模式必须都好看：不要用只在深色下成立的低对比色。

逐页：

- **SearchPage**：`GlassSearchBar` 作页头（吸顶）；线路抽屉用玻璃 + `PageHeader` 风格；
  热搜/最近搜索用 `GlassChip` 流式布局；结果卡片重设计为"海报 + 标题 + 分类胶囊 + 备注 + 播放角标"。
- **CategoryPage**：顶部已由 `TapUI` 提供（标题+搜索入口+分段 Tab）；筛选面板改成玻璃卡片 +
  `GlassChip` 组；影片瀑布流卡片与 `FilmTile` 同一视觉语言（海报渐变占位、豆瓣式评分、圆角 18+）。
- **ManagePage**：只改容器背景与摘要文字样式（顶部已用 `TapUI`）。
- **MyPage**：个人中心重设计——顶部"用户玻璃卡"（头像、昵称、会员标签）、功能宫格（玻璃icon块）、
  列表分组（玻璃卡片分节，行高 52，右箭头），保留所有点击回调与资料字段。
- **SettingPage**：设置项分组为玻璃卡片；`Toggle`/`Slider` 行保持功能；输入框统一玻璃胶囊；
  日志弹窗/清空确认弹窗改成玻璃面板 + 大圆角。
- **LoginPage / RegisterPage**：品牌页风格——顶部渐变 Logo 区、玻璃表单卡、`GlassSearchBar`
  同款材质的输入框（用 `.backgroundColor(Ui.glassTintSoft)` + 描边 + 24 圆角）、主按钮渐变。
- **UserAgreementPage**：玻璃阅读卡 + `PageHeader`，正文行高 1.7，底部同意按钮渐变。
- **FavoritePage / DownloadPage / PlayHistoryPage**：管理页子页，卡片化 + `EmptyState` + 玻璃筛选条
  （这些子页是被 Tabs 内嵌的，**不要**再加 `PageHeader`，顶部已有 `TapUI`）。
- **ProfilePage**：占位页，改成 `EmptyState` 风格 + 返回首页按钮。
- **PlayerPage / MediaSessionDialog**：只把顶栏、底部控制条、弹层容器换成玻璃材质
  （`Ui.glassTint` + `backdropBlur(Ui.glassBlur(...))` + `Ui.glassRing`），弹幕输入条换成
  `GlassSearchBar` 同款玻璃配方；**播放器逻辑、手势层、播放状态一律不动**。

## 5. 硬性约束（违反即构建失败）

1. **ArkTS 严格模式**：不要 `any`、不要对象字面量推断、不要解构、不要展开运算符、不要可选链式赋值。
2. `@Builder` / `build()` 里**不能**写 `try/catch`、不能声明 `const/let`。需要计算就在普通方法里算。
3. 不要用 `.position()`；需要叠放就用 `Stack` + `Blank()`；`alignSelf` 只在 Flex/Row/Column 子项上用。
4. `$r('sys.symbol.xxx')` **只能**用本工程已有的名字：
   `house house_fill square_grid_2x2 square_fill_grid_2x2 folder folder_fill gearshape gearshape_fill
    person person_fill magnifyingglass play_fill pause_fill chevron_left_circle camera share xmark
    sun_max_fill speaker_wave_3_fill arrow_left_arrow_right arrow_down_circle wireless_projection
    timer rectangle list_number forward_end_fill resolution_video arrow_down_right_and_arrow_up_left
    arrow_up_left_and_arrow_down_right`
   新图标优先用文字符号（＋ ✉ ▧ ◎ ▶ ★ › ×）或上述符号。
5. 所有 `ForEach` 的 key 必须稳定且唯一（用 id / 索引拼接前缀，不要用可能重复的字符串）。
6. 不许删改：任何 `@State/@StorageLink/@Prop`、方法、`aboutToAppear/…Disappear`、服务调用、
   `NavigationScroll.*`、`ImmersiveService.*`、`router.*`、日志文案、无障碍文案、业务提示文案。
   只允许把**颜色 / 圆角 / 阴影 / 间距 / 布局结构 / 字号**替换为新规范。
7. 不许新增第三方依赖、不许改 `module.json5`、`main_pages.json`、`oh-package.json5`、`build-profile.json5`。
8. 不许改 `common/Ui.ets`、`common/UiWidgets.ets`、`pages/HomePage.ets`、`pages/Shared.ets`、`pages/TapUI.ets`。
9. 每个文件改完必须自检：括号配平（`{}`/`()`/`[]`）、没有残留旧色值（`#101C2D`、`#1F3046` 等）、
   没有未使用的 import。

## 6. 交付物

- 直接修改指定文件（不要新建文件，除非只是本页私有的小组件）。
- 汇报格式：每个文件一行「文件名 + 改了哪些视觉点」+ 一段「保留了哪些交互/状态」的确认。

# v5.1.0 · 聊天室实时提醒 + 界面尺寸自定义

本次迭代在 v5.0.0 基础上新增五件事，全部为**新增能力**，不改动原有的播放、协播、论坛、分享链路：

1. 聊天室 / 私聊**实时消息提醒**：弹窗（QQ / 微信样式），可直接在弹窗内回复文字；
   约 4 秒轮询，同一房间连续来消息就地刷新内容与条数；弹窗位置可自定义
   （顶部 / 居中 / 底部 + 垂直微调），默认紧贴屏幕正上方；
2. 设置页**消息提示音开关**（含免打扰）；
3. 设置页**免打扰开关**：不响铃、不弹窗，只保留未读数；
4. 设置页**自定义 Dock 栏大小**与**全局字体大小**，拖动即时生效并持久化；
5. **分类 / 管理 / 我的** 移除底部安全区留白，内容铺到屏幕最底部，悬浮底栏只叠加显示；
6. **后台通知栏提醒**：应用退到后台后继续接收新消息，通过系统通知栏提醒（可开关），
   点通知直接进入对应聊天室；
7. **底部导航新增「消息 / 论坛 / 直播」**三个入口（设置页可显隐、排序，老用户升级自动补入）；
   其中「消息」是新的聚合页：好友私聊 / 群聊 / 聊天室三分组，手机单列、平板两列、宽屏三列；
8. **论坛 / 聊天室富媒体**：帖子与聊天消息都改为「纯文字 JSON」协议，可携带图片、视频、音乐、附件
   （帖子还支持付费段落）；列表显示媒体徽标，详情/气泡按类型渲染，发送时仍是纯文字。

---

## 一、新增文件

| 文件 | 说明 |
| --- | --- |
| `entry/src/main/ets/common/ChatAlertService.ets` | 轮询聊天室 / 私聊新消息，维护提醒队列、提示音、免打扰与前后台切换 |
| `entry/src/main/ets/common/NotificationService.ets` | 系统通知栏提醒：发布/更新/清除通知、申请通知权限、点击直达聊天室 |
| `entry/src/main/ets/components/ChatNoticeBanner.ets` | 弹窗提醒组件：会话名 + 发送者 + 预览 + 内联回复框 |
| `entry/src/main/ets/pages/MessageCenterPage.ets` | 新「消息」Tab：好友 / 群聊 / 聊天室三分组，多端自适应卡片布局 |
| `entry/src/main/ets/common/ForumCodec.ets` | 论坛正文协议：`#WYF#` + 纯文字 JSON（图片/视频/音乐/附件/付费），兼容旧标记格式 |
| `entry/src/main/resources/rawfile/chat_notice.wav` | 提示音「叮咚」（C6→G6 双音，44.1kHz/16bit 单声道，0.32s） |
| `CHAT_REMINDER_UI_SCALE.md` | 本文档 |

## 二、聊天提醒链路

### 1. 什么时候提醒

`ChatAlertService` 常驻轮询，前台/后台模式由 `EntryAbility` 切换：

- **前台**（`enterForeground`）：应用内弹窗 + 提示音 + 清掉通知栏遗留；
- **后台**（`enterBackground`）：开关打开时继续轮询，并申请 `dataTransfer` 持续任务
  延长后台运行时间；新消息改发**系统通知栏**；开关关闭则停止轮询。

共同规则：

- 间隔 `INTERVAL = 4000ms`（实时更新：新消息约 4 秒内出现），单轮最多检查 `MAX_TARGETS = 8` 个会话；
- 目标是「本地聊天室列表（含官方群聊）+ 好友私聊房间（`私聊_A_B`）」；
- 每个会话只取最新 `PAGE_SIZE = 5` 条，按 `message.id` **增量**判断，**首轮只建立基线**，
  不会把历史消息当成新消息补提醒；
- **同一房间连续来消息时就地刷新**：正在展示的弹窗直接替换为最新文案、时间与累计条数（标题旁
  显示「N 条」），并重新开始 7 秒倒计时；不会排队弹出第二条，也不会清空用户正在输入的回复草稿
  （弹窗按 `version` 判断是"同一房间刷新"还是"新会话"）；
- 过滤：自己的消息、黑名单用户、好友申请协议卡（`friend_request / accept / reject`）不提醒；
- 正在查看的房间（`AppStorage.activeChatRoom`，由 `ChatRoomPage` 登记/释放）**不弹窗、不响铃**，
  只有页面内自己滚动到底部；房间内新消息由 `ChatRoomPage` 直接调 `playNoticeSound()` 响铃。

### 2. 提醒什么形式

- 弹窗：默认从屏幕顶部滑入的玻璃卡片（位置可改成居中 / 底部），7 秒无操作自动收起
  （展开回复输入框时停表，收起后重新计时）；
  弹窗根节点只占卡片高度并贴锚点对齐、**不铺满整屏** —— 卡片区域正常吃掉点击，卡片之外完全不拦截
  页面触摸，因此不会「点弹窗顺带触发下面的按钮」，也不会挡住视频手势；
  挂载页面：`HomePage`（首页/分类/管理/设置/我的共用外壳）、`ChatRoomPage`、`ChatRoomsPage`、
  `MessagePage`、`FriendsPage`、`PlayerPage`（播放中也会提醒）；
- 提示音：`chat_notice.wav`，通过 `AVPlayer.fdSrc` 播放；每次播放单独取 rawfile 句柄，播放结束
  （completed / error / 5s 兜底）后同时释放播放器并 `closeRawFd`，常驻轮询下不累积 fd；
  `soundBusy` 保证同一时刻只有一路提示音；
- 未读摘要：提醒的同时把该房间 / 好友的最后一条消息、时间、未读数写回 `SocialStore`，
  聊天室列表、消息中心、好友页返回时角标已经是最新值；
- **后台通知栏**（`NotificationService`）：固定 id `1001` 的单条通知，标题为
  `会话名（N 条新消息）`、正文为 `发送者：预览`，重复新消息就地更新同一条通知；
  点通知拉起应用并带上 `chatRoom / chatPeer`，`EntryAbility` 在界面就绪后 `router.pushUrl`
  到 `pages/ChatRoomPage`；回到前台时自动清除该通知。

### 3. 弹窗能做什么

| 操作 | 行为 |
| --- | --- |
| 点卡片主体 / 「进入聊天室」 | `router.pushUrl` 到 `pages/ChatRoomPage`，群聊/私聊按 `peer` 字段自动区分 |
| 「回复」 | 展开内联 `TextInput`，回车或点「发送」→ `CommunityApi.sendChat` 直发该房间 |
| 「×」/ 自动收起 | 关闭当前提醒，若有排队消息则 320ms 后展示下一条 |
| 「全部忽略」 | 清空排队提醒（右上角 `+N` 即排队条数） |

回复成功后会把该房间的已读基线推进到刚发出的 `message_id`，避免下一轮轮询重复提醒同一条。

### 4. 免打扰 / 开关

三个开关共用 `AppState` 持久化，并发布到 AppStorage：

| 键 | 默认 | 含义 |
| --- | --- | --- |
| `chatSoundEnabled` | `true` | 消息提示音 |
| `chatBannerEnabled` | `true` | 弹窗提醒 |
| `chatBackgroundNotify` | `true` | 后台通知栏提醒（退到后台后继续接收并发系统通知） |
| `chatDndEnabled` | `false` | 免打扰：**同时**压制提示音、弹窗与后台通知，仅保留未读数 |

> 免打扰开启时 `soundAllowed()` / `bannerAllowed()` / `backgroundAllowed()` 均返回 false，
> 因此不会响铃、不会弹窗、也不会发通知；房间内页面的响铃同样受此约束。
> 设置页提供「试听提示音」「预览提醒弹窗」两个自检入口。

## 三、设置页新增两个分组

配置页顶部分段菜单（平板为左侧栏）新增 **「界面尺寸」** 与 **「聊天提醒」**，位于「沉浸外观」之后。

### 1. 界面尺寸

- **Dock 栏大小（%）**：85% ~ 125%，步进 5%；
- **全局字体大小（%）**：85% ~ 130%，步进 5%；
- 面板内含**迷你底栏预览**：高度随 Dock 缩放、图标与文字随字体缩放实时变化；
- 「恢复默认尺寸」一键回到 100%。

### 2. 聊天提醒

- 消息提示音 / 弹窗提醒 / **后台通知栏提醒** / 免打扰 四个开关；
- 打开「后台通知栏提醒」时会顺带确认系统通知权限（没权限会弹系统询问，并提示"未获得通知权限"）；
- **弹窗位置**：顶部（默认，屏幕正上方，状态栏下 2vp）/ 居中 / Dock 上方 三选一，
  再加 0~200vp 垂直微调；「Dock 上方」紧贴 Dock 栏上边缘，微调只把它往屏幕中间挪，**不会压住导航栏**；
- 试听提示音、预览提醒弹窗（预览会按当前开关与位置生成一条示例提醒，只演示样式、不会真的发消息）；
- 底部说明：提示音跟随系统媒体音量；免打扰或关闭弹窗时仍计入未读数。

## 三之二、提醒弹窗位置实现

- 位置与微调保存为 `AppStorage.chatAlertPosition`（`top / center / bottom`）与
  `AppStorage.chatAlertOffset`（0~200vp），设置页三枚胶囊 + 一条滑块即时写入；
- `ChatNoticeBanner` 的根节点是**整屏透明锚点容器**，用 `Stack({ alignContent })` 定位：
  - 之前用根节点的 `.align()` 锚定，在首页外壳（其 Stack 的 `alignContent` 是 Bottom）里会被宿主覆盖，
    导致弹窗总出现在导航栏上方；现在改为构造参数 `alignContent`，任何宿主都按设置落点；
  - 顶部：卡片 `margin.top = safeTop + 2 + 微调`，紧贴屏幕正上方；
  - Dock 上方：卡片 `margin.bottom = navClearance + 微调`，其中 `navClearance`
    是 HomePage 发布的「Dock 栏高度 + 手势条 + 余量」，因此永远在导航栏上方；
  - 居中：`alignContent = Center`，两侧留 10vp；
- 触摸：容器整屏但 `HitTestMode.Transparent`，卡片外的区域完全不拦截页面；展开回复输入框时
  改为 `Default`，避免输入时的点击穿透到底层页面；
- 入场动画按锚点切换（顶部从上滑入、Dock 上方从下滑入、居中淡入）；
- 非法值一律回落默认：`position` 非 `center/bottom` 按 `top`，`offset` 非数字按 0。

## 三之三、分类 / 管理 / 我的：移除底部安全区留白

这三个页面不再为底栏、手势条或渐变模糊带预留底部高度，内容可以一直铺到屏幕最底部，
悬浮液态玻璃底栏只叠加显示（向下滚动时自动下沉隐藏），底部不会出现大片空白：

| 位置 | 改动 |
| --- | --- |
| `HomePage.fullScreenBusinessPage()` | 把 `mine` / `profile` 也纳入"全屏业务页"，宿主不再为我的页面加底部/左右避让 |
| `CategoryPage` | 两处 `WaterFlow` 的 `padding.bottom`：`navClearance` → `0vp` |
| `ManagePage` | 删除 `Tabs` 上的 `padding.bottom: navClearance` |
| `MyPage` | `pagePadding()` 的底部由 `max(navClearance, safeBottom+96/108)` → `0vp` |

同时删除了这三个页面里已无用的 `@StorageLink('navClearance')` 字段（避免未使用告警）；
`SearchPage` / `SettingPage` 的底部避让保持不变。

## 三之四、后台通知栏提醒实现

| 环节 | 实现 |
| --- | --- |
| 前后台切换 | `EntryAbility.onForeground/onBackground` → `ChatAlertService.enterForeground()/enterBackground()`；`onDestroy` → `shutdown()` |
| 后台轮询 | 后台模式下若开关打开则**不停止** `INTERVAL` 轮询；同时 `backgroundTaskManager.startBackgroundRunning(context, BackgroundMode.DATA_TRANSFER, wantAgent)` 申请持续任务延长存活（失败只记日志，不影响前台功能） |
| 通知发布 | `NotificationService.publish()`：固定 id `1001`，`NOTIFICATION_CONTENT_BASIC_TEXT`，标题 `会话名（N 条新消息）`，正文 `发送者：预览`，附属文案 `无音影视 · 聊天提醒`；重复新消息就地更新同一条通知 |
| 点击通知 | `wantAgent`（`OperationType.START_ABILITY`）带上 `chatRoom / chatPeer` 参数拉起 `EntryAbility`；`captureChatNotification()` 记录目标，界面就绪后 `router.pushUrl` 到 `pages/ChatRoomPage`（冷启动/热启动都覆盖） |
| 权限 | `module.json5` 申请 `ohos.permission.KEEP_BACKGROUND_RUNNING`，EntryAbility 声明 `"backgroundModes": ["dataTransfer"]`；通知权限通过 `notificationManager.requestEnableNotification()` 在用户打开开关时确认 |
| 回前台 | `enterForeground()` 里 `NotificationService.cancelAll()` + `stopBackgroundRunning()`，通知不会残留 |
| 免打扰 | `backgroundAllowed()` 同时受 `chatDndEnabled` 与 `chatBackgroundNotify` 约束，任一关闭都不发通知 |

> 说明：这是"应用自己轮询 + 系统通知"，不是 Push Kit 服务端推送；系统把进程彻底回收后不会再收到提醒。

## 三之五、底部导航新增入口 + 消息聚合页

- `NavTabs.ALL` 新增三项：`message`（消息 ✉）、`forum`（论坛 ✎）、`live`（直播 ▶），可在
  设置 → 底部导航里显隐与排序；`DEFAULT_KEYS` 变为
  `home / message / forum / live / category / manage / settings / mine`（8 项）；
- 配置版本升到 2：老用户首次启动时 `withAddedKeys()` 把三个新入口补到「首页」之后，
  **只补一次**，不覆盖用户自己排好的顺序与显隐；
- `LiquidNav` 对这三个入口用文字字形渲染（`✉ ✎ ▶`），避免依赖未确认存在的 `sys.symbol` 资源；
  Tab 超过 6 个时图标/文字自动缩到 0.9 / 0.82 倍，8 个入口在手机上也不挤；
- `HomePage.businessPage()` 新增三个分支：`message → MessageCenterPage`、`forum → ForumPage(embedded)`、
  `live → LiveTvPage(embedded)`；它们同样属于"全屏业务页"，宿主不再加底部/左右避让；
- `ForumPage` / `LiveTvPage` 新增 `@Prop embedded`：嵌入底栏时隐藏返回按钮，返回动作改为回首页，
  不会把应用 pop 掉；仍可像以前一样从「我的」以独立路由打开。

**MessageCenterPage（新）**

| 分组 | 内容 |
| --- | --- |
| 好友 | 好友私聊列表（最后一条消息、时间、未读），顶部「好友申请」入口 |
| 群聊 | 官方群聊 + 我创建的聊天室 |
| 聊天室 | 全部自建房间 + 「创建 / 房间列表」入口 |

- 数据全部复用 `SocialStore` / `ChatService`（`refreshRoomSummary` / `refreshFriendSummary`），
  不另造社交模型；`socialVersion` 变化自动重载，30s 刷新在线人数，支持手动刷新；
- 多端：手机单列、平板（≥600vp）两列且内容限宽 980vp、宽屏（≥1000vp）三列限宽 1180vp；
- 点击好友进入私聊房间、点击房间进入群聊，均复用 `pages/ChatRoomPage`；
- 页面同样挂载 `ChatNoticeBanner`，可直接在弹窗里回复。

## 三之六、论坛富媒体（纯文字 JSON 协议）

- 新文件 `common/ForumCodec.ets`：`#WYF#` + JSON，字段
  `{ v, text, media:[{kind,url,title,poster}], price, paid }`，
  `kind ∈ image | video | audio | file`；
- **发送给服务端的仍是纯文字**：没有媒体/付费时直接发正文，有富内容时才发一行 `#WYF#{...}`；
- 解析层兼容三种历史写法：JSON、`【imgN】url【imgN】`、`【video】url【video】`、`【paid:n】…【/paid】`；
- `CommunityApi` 的 `freeBody / paidPrice / paidBody / extractImages / extractVideos` 全部改为
  JSON 优先、旧格式兜底，页面无需各自解析；
- 发布器（`ForumPage`）：媒体类型胶囊（图片 / 视频 / 音乐 / 附件）+ 链接输入 + 标题/封面输入，
  已添加媒体以"图标 + 类型 + 标题 + ×"的胶囊列出；正文区放进 `Scroll`，小屏也不会把"发布"按钮挤出去；
- 列表卡片：正文预览 + 媒体徽标（`图片 3` / `视频 1` / `音乐 1` / `附件 2`）+ 最多 9 张图片九宫格；
- 详情页：图片九宫格、视频卡（封面 + 播放）、音乐卡、附件行，点击复制资源链接（便于到播放器/浏览器打开）。

## 三之七、聊天室富文本（rich 消息）

聊天室沿用 `#WY#` 前缀，但把媒体模型升级为与论坛一致的列表：

- `ChatCard` 新增 `media: ForumMedia[]`（`image / video / audio / file`），新增 `kind = rich`；
- `MediaCodec.encode()`：`rich` 且无媒体时退化为纯文本；`text` 仍不加前缀，服务端网页端正常显示；
- `MediaCodec.decode()`：用 `ForumCodec.parseMedia()` 规范化媒体，老消息（image/video/file/voice 单媒体）
  继续按 `url` 字段兼容渲染；
- `MediaCodec.preview()`：`rich` 优先显示文字，没有文字时显示 `[图片×2 · 视频×1]`；
  `ChatAlertService` 的提醒预览、引用预览、复制消息都自动受益；
- 输入区：＋面板的 图片 / 视频 / 音频 / 文件 现在打开「添加媒体」弹窗（类型胶囊 + 链接 + 标题 / 封面），
  添加后进入输入框上方的**待发送媒体条**（可逐条 ×），可以继续输入文字，点「发送」一起作为一条
  `rich` 消息发出；单条最多 12 个媒体；
- 气泡：`rich` 与 `quote` 气泡共用 `mediaBlock()` —— 图片九宫格（点击提示 URL）、
  视频/音乐/附件行（点击复制链接），文字与媒体同气泡；
- 引用消息带媒体时同样渲染媒体块，不会丢内容。

## 三之八、原生图标 / 等级头衔 / 后台任务调整

- **鸿蒙原生图标**：新增 `common/SymbolIcons.ets` 统一维护「语义 → `sys.symbol`」映射；
  底栏 8 个入口（含消息/论坛/直播）全部改用 `SymbolGlyph`，不再用 `✉ ✎ ▶` 文字字形；
  其它页面的图标后续同样只改这一个文件即可扩展。
  注意：`chat_bubble / doc_text / play_rectangle` 若在当前 SDK 不存在，编译会报资源找不到，
  改 `SymbolIcons.ets` 对应一行即可。
- **聊天室等级头衔**：新增 `common/UserTitles.ets`，12 档无音影视主题头衔
  （光影新人 → 观影学徒 → 银幕常客 → 片单收藏家 → 影评笔杆 → 分镜拆解师 → 剪辑好手 →
  放映室主理人 → 光影导演 → 无音殿堂 → 无音殿堂·金 → 无音殿堂·传奇）；
  等级优先取消息 `grade` 里的数字，取不到时按账号稳定哈希落到 1~6 级，
  气泡里以「Lv.N 头衔」胶囊显示，颜色随等级变化。
- **去掉后台持续任务**：删除 `backgroundTaskManager` 调用、`KEEP_BACKGROUND_RUNNING` 权限与
  `backgroundModes: dataTransfer`；后台仍保留「前台存活期内轮询 + 通知栏提醒」，
  不再申请持续任务、也不会出现系统常驻任务通知。

## 四、自定义 Dock 栏大小实现

`Ui.ets` 新增阈值与换算：

```ts
Ui.DOCK_SCALE_MIN = 0.85; Ui.DOCK_SCALE_MAX = 1.25;
Ui.dockScale(value)         // 收敛到区间
Ui.navBarHeight(w, h, scale) / Ui.navStripHeight(w, h, scale) / Ui.navClearance(w, h, safeBottom, scale)
```

- `LiquidNav` 新增 `@StorageLink('dockScale')`：底栏高度、选中球直径、隐藏位移按 Dock 缩放，
  图标与标签按「Dock 缩放 × 全局字体缩放」（上限 1.45 倍，避免撑破底栏），底栏宽度上限不变；
- `HomePage` 订阅 `dockScale`（`@Watch('onDockScaleChanged')`），变化时重新发布
  `AppStorage.navClearance`，于是分类 / 搜索 / 管理 / 设置 / 我的等内嵌页的列表底部避让高度
  自动跟随，不会出现「底栏变大压住最后一行」或「底栏变小底部多出一块空白」。

## 五、全局字体大小实现

ArkTS 没有运行时全局字号 API，这里用「**令牌换算 + 逐组件订阅**」实现真正全局生效：

1. `Ui.fs(size, scale)`：把字面量字号 `'14.5vp'` 按 `scale` 换算成新字符串，非法值原样返回，`1.0` 时零开销；
2. 全部页面 / 共用组件的 `.fontSize(...)` 参数统一接入：
   - 字面量：`.fontSize('14.5vp')` → `.fontSize(Ui.fs('14.5vp', this.fontScale))`（423 处）；
   - 多端条件式：`.fontSize(this.isTablet ? '16vp' : '15vp')` → 同样包一层（91 处）；
   - 拼接口径（`(this.avatarSize() * 0.46) + 'vp'`、`Ui.fsCaption(w)` 等）→ 同样包一层（34 处）；
   - 合计 **548 处 / 34 个文件**；
3. 每个用到该换算的 `struct` 增加 `@StorageLink('fontScale') private fontScale: number = 1;`，
   因此拖动滑块时**当前所有已挂载页面**立即重排，不需要重启或重新进入；
4. 全局函数式 `@Builder`（如 `MediaSessionDialog` 里的 `SelectItem`）没有 `this`，
   改为直接读 `AppStorage.get<number>('fontScale')`；
5. `SymbolGlyph` 图标字号同样走换算，图标与文字比例保持一致。

## 六、持久化

`preferences('wuyin')` 新增 8 个键，读写都在 `AppState`：

| 键 | 类型 | 默认 |
| --- | --- | --- |
| `chatSoundEnabled` | boolean | true |
| `chatBannerEnabled` | boolean | true |
| `chatDndEnabled` | boolean | false |
| `chatBackgroundNotify` | boolean | true |
| `chatAlertPosition` | string | `top` |
| `chatAlertOffset` | number | 0 |
| `dockScale` | number | 1 |
| `fontScale` | number | 1 |

## 七、真机验证清单

1. 登录两个账号，A 在 **B 的其它页面** 发消息 → B 应看到弹窗 + 听到提示音（默认位置：紧贴屏幕正上方，
   约 4 秒内出现）；
2. A 连续在同一房间发 3 条 → B 的弹窗内容实时刷新为最后一条，标题旁显示「3 条」，倒计时重新开始，
   弹窗不会变成 3 个排队项；
3. 弹窗点「回复」→ 直接回文字 → A 侧收到；弹窗应自动收起，`+N` 计数递减；
4. 点卡片主体 → 进入对应聊天室（群聊 / 私聊分别验证）；
5. 在聊天室内再收消息 → 只响铃、不弹窗；
6. 设置页开「免打扰」→ 不响铃不弹窗，消息页未读数仍增长；
7. 关「消息提示音」→ 只弹窗不响铃；关「弹窗提醒」→ 只响铃不弹窗；
8. 设置页切换弹窗位置 顶部 / 居中 / 底部，各点一次「预览提醒弹窗」，确认落点与滑入方向；
9. 「位置微调」从 0 拖到 200vp，确认弹窗平滑下移（顶部）/ 上移（底部）；
10. 设置页「Dock 栏大小」拉到 85% / 125%，检查底栏不遮挡列表最后一行；
11. 设置页「全局字体大小」拉到 85% / 130%，逐个页面检查文字不溢出、按钮不换行错位；
12. 分类 / 管理 / 我的 三个页面滚到底：内容应铺到屏幕最底部（底部无大片空白），
    下滑时底栏自动隐藏、可看到最后一行；
13. 杀进程重启 → 开关、弹窗位置与两个尺寸都保持上次选择；
14. 应用切到后台（开着「后台通知栏提醒」）→ A 发消息 → B 的通知栏出现
    `会话名（N 条新消息）`；连续多条只更新同一条通知、条数累加；
15. 点该通知 → 应用被拉起并直接进入对应聊天室（群聊 / 私聊各验一次），通知自动消失；
16. 后台时关掉「后台通知栏提醒」或开「免打扰」→ 不再出现通知（日志 `聊天提醒轮询已停止`）；
17. 系统设置里关闭「允许通知」后再打开开关 → 应弹出系统询问或提示"未获得通知权限"。

## 八、已知限制

- 提醒依赖应用自身轮询（4s 粒度），**不是** Push Kit 服务端推送：进程被系统彻底回收后
  不会再收到提醒；
- 后台存活依赖 `dataTransfer` 持续任务（系统对连续任务有策略限制，可能被停止或要求用户确认），
  被停止后只在前台提醒；真机若在 `startBackgroundRunning` 处报错，日志会打印具体错误码；
- 后台通知的响铃/震动由**系统通知设置**决定，应用内「消息提示音」开关只控制前台提示音；
- 首轮只建立基线，因此启动前已存在的未读消息不会补弹窗或通知（仍在未读数里）；
- 单轮最多检查 8 个会话（房间优先、其后为好友私聊），每轮 8 个请求；房间/好友很多时可把
  `ChatAlertService.INTERVAL` 调大以省电，或调 `MAX_TARGETS`，代价是人多的账号覆盖不全；
- 提示音走 AVPlayer，与视频播放共用音频焦点；视频播放中响铃可能短暂压低背景声。

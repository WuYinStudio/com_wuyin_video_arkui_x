# 鸿蒙工程 vs ArkUI-X 工程 · 逐文件对比（pages / common / components）

生成时间：2026-10-30 19:17　｜　脚本：`Arkui_x/tools/portdiff.mjs`　｜　原始 unified diff：`Arkui_x/diff/*.diff`

- 鸿蒙：`com_wuyin_video_v5.1.0/entry/src/main/ets`（91 个 .ets）
- ArkUI-X：`Arkui_x/com_wuyin_video_arkui_x/entry/src/main/ets`（97 个 .ets）
- 结果：**相同 56**、**有差异 27**、**缺失 8**、ArkUI-X 独有（兼容层）10

## 一、已存在（逐字节相同，56 个）

**pages（19）**：`CategoryPage.ets`、`ChatRoomsPage.ets`、`DownloadPage.ets`、`FavoritePage.ets`、`ForumDetailPage.ets`、`ForumPage.ets`、`FriendsPage.ets`、`Index.ets`、`LivePlayerPage.ets`、`LiveTvPage.ets`、`ManagePage.ets`、`MessageCenterPage.ets`、`PlayHistoryPage.ets`、`ProfilePage.ets`、`SearchPage.ets`、`Shared.ets`、`TapUI.ets`、`ThemeStorePage.ets`、`WallpaperPage.ets`

**common（33）**：`AccountStore.ets`、`AgreementService.ets`、`AppBrightnessUtil.ets`、`AppConfig.ets`、`AppState.ets`、`CastService.ets`、`CategoryService.ets`、`ChatAlertService.ets`、`ChatService.ets`、`CoPlayInviteHandoff.ets`、`CoPlayTransport.ets`、`CommunityApi.ets`、`DanmakuService.ets`、`ForumCodec.ets`、`ImmersiveService.ets`、`LiveService.ets`、`Logger.ets`、`MediaCodec.ets`、`MediaSniffer.ets`、`NavTabs.ets`、`NavigationScroll.ets`、`PortraitLoader.ets`、`Quest3ControlService.ets`、`SearchSources.ets`、`SensitiveWords.ets`、`SessionInviteParser.ets`、`SocialStore.ets`、`SymbolIcons.ets`、`ThemeService.ets`、`Ui.ets`、`UiWidgets.ets`、`UserTitles.ets`、`WzljParser.ets`

**components（4）**：`ChatCardMessage.ets`、`ChatNoticeBanner.ets`、`HistoryStrip.ets`、`PlayerGestureLayer.ets`

## 二、有差异（27 个，ArkUI-X 侧为兼容层适配或旧版实现）

| 文件 | 鸿蒙行 | ArkUI-X 行 | +新增 / -删除 | 差异块 | 说明 |
|---|---:|---:|---:|---:|---|
| `pages\PlayerPage.ets` | 2435 | 2224 | +21 / -232 | 15 | ARK 分享到群/好友整段缺失（本轮已补）＋截图/seek/方向改走 PlatformApi |
| `pages\ChatRoomPage.ets` | 2567 | 2399 | +6 / -174 | 12 | ark 卡片、在线绿点、榜单入口、归档保存、@成员在线态缺失（本轮已补）＋输入法走 compat |
| `pages\MyPage.ets` | 1946 | 1915 | +43 / -74 | 7 | 统计条为旧版单行 5 格（本轮已改两行）＋系统分享走 ShareCompat |
| `components\MediaSessionDialog.ets` | 1388 | 1407 | +65 / -46 | 23 | 投屏/关闭图标与协播逻辑的兼容层差异 |
| `pages\HomePage.ets` | 1408 | 1342 | +0 / -66 | 3 | 深链 consumeDeepLink 整段缺失（本轮已补） |
| `common\AccountApi.ets` | 398 | 336 | +0 / -62 | 1 | 排行榜 rankList/RankEntry 缺失（本轮已补） |
| `common\CoPlayLanService.ets` | 506 | 515 | +33 / -24 | 20 | UDP 广播/错误监听在 ArkUI-X 的降级实现 |
| `common\DownloadService.ets` | 981 | 986 | +26 / -21 | 8 | 断点续传/仅 Wi-Fi/空间预检走 PlatformApi |
| `pages\SettingPage.ets` | 1757 | 1710 | +0 / -47 | 3 | 聊天记录导入导出入口缺失（本轮已补） |
| `pages\AccountCenterPage.ets` | 637 | 616 | +9 / -30 | 7 | 充值/分享兼容层差异 |
| `entryability\EntryAbility.ets` | 903 | 891 | +7 / -19 | 7 | want.uri/action 走 WantCompat；深链捕获缺失（本轮已补） |
| `common\CoPlayShareService.ets` | 126 | 126 | +11 / -11 | 5 | 系统分享提取的兼容层差异 |
| `common\NotificationService.ets` | 140 | 142 | +9 / -7 | 4 | 通知点击参数/取消能力降级 |
| `common\ShareService.ets` | 458 | 458 | +7 / -7 | 5 | 分享面板兼容层 |
| `common\CoPlayLanSession.ets` | 313 | 311 | +4 / -6 | 3 | 局域网会话兼容层 |
| `pages\UserProfilePage.ets` | 465 | 455 | +0 / -10 | 2 | 资料页字段与兼容层差异 |
| `common\HistoryArchive.ets` | 159 | 159 | +4 / -4 | 2 | 文件选择器参数差异 |
| `pages\RegisterPage.ets` | 881 | 882 | +4 / -3 | 4 | 注册兼容层差异 |
| `common\TencentSdkService.ets` | 269 | 270 | +4 / -3 | 3 | QQ SDK 空实现差异 |
| `pages\LoginPage.ets` | 854 | 855 | +4 / -3 | 4 | 登录兼容层差异 |
| `common\LocalPlaybackService.ets` | 342 | 343 | +3 / -2 | 2 | 本地播放兼容层差异 |
| `pages\TitleRankPage.ets` | 161 | 162 | +2 / -1 | 2 | 头衔榜兼容层差异 |
| `pages\AvatarUploadPage.ets` | 86 | 87 | +2 / -1 | 2 | 头像选择器差异 |
| `pages\FollowListPage.ets` | 260 | 261 | +2 / -1 | 2 | 关注列表兼容层差异 |
| `pages\MessagePage.ets` | 721 | 722 | +2 / -1 | 2 | 仅 1 行差异（图标/文案） |
| `pages\PlatformSnifferPage.ets` | 129 | 130 | +2 / -1 | 2 | 嗅探页兼容层差异 |
| `pages\UserAgreementPage.ets` | 218 | 219 | +1 / -0 | 1 | 协议页 1 行差异 |

## 三、缺失（鸿蒙有、ArkUI-X 没有，8 个）

| 文件 | 类型 | 处理 |
|---|---|---|
| `common\ArkCard.ets` | 功能：ark 富文本卡片解析 | ✅ 本轮已补齐（聊天室按 scheme 分流渲染） |
| `common\ChatArchive.ets` | 功能：聊天记录归档/导入导出 | ✅ 本轮已补齐（设置页入口 + 聊天室落盘） |
| `common\NfcShareService.ets` | 鸿蒙专有：NFC 分享 | ⏸ 保留 legacy/harmonyos-only（ArkUI-X 无 NFC） |
| `common\VideoCardBuilder.ets` | 功能：影视分享卡 XML 构建 | ✅ 本轮已补齐（播放器分享面板） |
| `common\VRSpatialRuntime.ets` | 鸿蒙专有：VR 空间运行时 | ⏸ 保留 legacy/harmonyos-only（Quest3 走 Quest3ControlService） |
| `components\VRPlayer.ets` | 鸿蒙专有：VR 播放器 | ⏸ 保留 legacy/harmonyos-only |
| `pages\RankPage.ets` | 功能：全服四榜（admin_rank.php） | ✅ 本轮已补齐（AccountApi.rankList + main_pages 注册 + 聊天室入口） |
| `shareextensionability\ShareExtensionAbility.ets` | 鸿蒙专有：分享扩展 Ability | ⏸ 保留（Android 走 ACTION_SEND，iOS 走 Share Extension） |

## 四、ArkUI-X 独有（10 个，均为兼容层，属预期）

`common\compat\AvSessionCompat.ets`、`common\compat\BridgeShare.ets`、`common\compat\DeviceManagerCompat.ets`、`common\compat\InputMethodCompat.ets`、`common\compat\PlatformApi.ets`、`common\compat\PlatformInfo.ets`、`common\compat\RouterCompat.ets`、`common\compat\ShareCompat.ets`、`common\compat\WantAgentCompat.ets`、`common\compat\WantCompat.ets`

## 五、本轮移植（按低风险顺序）

| # | 功能 | 落点 | 状态 |
|---|---|---|---|
| 1 | RankPage 全服四榜 + 聊天室右上角入口 | `pages/RankPage.ets`、`common/AccountApi.ets`、`pages/ChatRoomPage.ets`、`main_pages.json` | ✅ 编译通过 |
| 2 | 聊天室在线绿点 + @成员在线/离线 | `pages/ChatRoomPage.ets`（isOnline + 头像角标 + 成员列表） | ✅ |
| 3 | ark 富文本卡片解析与渲染 | `common/ArkCard.ets`、`pages/ChatRoomPage.ets` | ✅ |
| 4 | 播放器「分享到群/好友」 | `common/VideoCardBuilder.ets`、`pages/PlayerPage.ets` | ✅ |
| 5 | 我的页两行统计条 | `pages/MyPage.ets`（手机两行 / 平板单行） | ✅ |
| 6 | 聊天记录导入导出 | `common/ChatArchive.ets`、`pages/SettingPage.ets`、`pages/ChatRoomPage.ets` | ✅ |
| 7 | 深链 wuyinvideo:// 平台适配 | `pages/HomePage.ets`、`entryability/EntryAbility.ets`、AndroidManifest、iOS Info.plist | ✅ APK 内已含 intent-filter |
| 8 | 图标层 Icons.ets（sys.symbol → app.media） | —— | ⏸ 待定，原因见第六节 |

## 六、图标层为什么先不动

检查 ArkUI-X SDK 26.0.0 发现：`engine/systemres/resources.index`（1.66 MB）**已经包含 `sys.symbol.*` 资源**
（`house_fill`、`trophy`、`magnifyingglass` 等都能在索引里查到），`assembleApp` 会把它打进 APK 的
`assets/arkui-x/systemres/`。因此「ArkUI-X 没有 sys.symbol」在 26.0.0 上至少不成立到资源层。

剩下唯一的不确定是**字形字体**是否随包：如果真机上图标是空白，才需要 `Icons.ets` + 38 个 `app.media` 图标兜底。
建议先在模拟器上跑一遍首页/聊天室确认，再决定是否改这 46 处调用点（改错会破坏布局，收益却可能是 0）。

# 我的 / 消息 / 聊天室 / 私聊好友 / 影评论坛 补齐说明

本次在「无音影视 v2.1 纯空壳框架」上按 7.9–7.13 要求补齐页面与接口，所有远程数据仍按
`https://api.y11.top/docs` 的云逸 GET 接口接入。

## 一、页面与文件

| 功能 | 文件 | 数据来源 |
| --- | --- | --- |
| 消息中心 7.12 | `pages/MessagePage.ets` | `online_see.php`、`echouser.php`、`lts.php`、本地已读 |
| 聊天室列表 7.9 | `pages/ChatRoomsPage.ets` | `lts.php` 最后消息/未读、`online_see.php` |
| 聊天室/私聊 7.10 | `pages/ChatRoomPage.ets` | `lts.php` get/send/revoke/ban/mute；本地消息编码 |
| 好友 7.11 | `pages/FriendsPage.ets` | `userquery.php` + `lts.php` 好友申请房间 |
| 用户资料 7.11 | `pages/UserProfilePage.ets` | `userquery.php` / `echouserdata.php` |
| 影评论坛 7.13 | `pages/ForumPage.ets` | `bbs.php` getCategoryList/getPostList/getSearch/createPost/editPost/deletePost |
| 帖子详情 7.13 | `pages/ForumDetailPage.ets` | `bbs.php` viewPost/getReplyList/likePost/replyToPost/increaseViews + `moneyspend.php` |
| 我的页面 | `pages/MyPage.ets` | `echouserdata.php`、`sign.php`、`echonewsnum.php`、`online_see.php` |
| 底栏 Tab 管理 | `pages/SettingPage.ets` + `common/NavTabs.ets` | preferences + AppStorage |

新增公共层：

- `common/CommunityApi.ets`：所有云逸接口、强类型解析、图片/付费标记解析、好友查询。
- `common/ChatService.ets`：房间/私聊/好友申请协议、最后消息、未读数。
- `common/MediaCodec.ets`：把图片、视频、文件、语音、红包、引用、名片、好友申请编码进
  `lts.php` 的文本 message，普通文本保持原样。
- `common/SocialStore.ets`：好友、申请、房间、黑名单、已读位置、帖子收藏/解锁的本地持久化。
- `common/SensitiveWords.ets`：发布帖子/评论/聊天前的敏感词兜底过滤。

## 二、7.9 聊天室列表

- 官方群渐变卡：群头像、群名、在线人数、进入按钮。
- 房间列表：50vp 头像、名称、最后消息、时间、未读红点；长按删除房间。
- 创建房间：名称 2–12 字、简介、默认渐变头像，创建后自动进入。
- 空状态「暂无聊天室」+「创建一个」；30 秒刷新在线人数。

## 三、7.10 聊天室 / 私聊

- 顶部返回、房间名（点击资料卡）、在线人数、更多菜单（改头像/全体禁言/解禁/管理/清空/退出）。
- 消息类型：文本、表情、图片、视频、文件、语音、红包、名片、引用、系统提示。
- 消息项：36vp 头像（点击资料）、昵称/等级/VIP、每 5 分钟时间、自己蓝色/他人深色气泡、
  发送中/失败重发感叹号。
- 底部：表情按钮、输入框、加号、发送；加号面板含图片/视频/文件/音频/红包/名片/位置；
  表情热门/精选切换；`@` 成员列表。
- 乐观发送 + 失败重发；3 秒 `last_message_id` 轮询、页面隐藏暂停；加载更早消息。
- 长按：复制、回复、转发、撤回、翻译、禁言、删除。
- 全体禁言/解除、指定用户禁言走 `lts.php` 管理 action；被禁言后输入框禁用。
- 私聊模式去掉管理菜单，房间名由双方账号排序生成，显示「已读」。

## 四、7.11 好友 / 资料 / 黑名单

- 好友列表：头像、昵称、最后消息、时间、未读；点击进入私聊。
- 添加好友：输入账号，`userquery.php` 精确匹配；发送申请。
- 申请通过：双方通过 `好友申请_账号` 房间传递申请/通过/拒绝消息，客户端轮询后建立会话。
- 资料页：头像、昵称、ID、签名、等级、称号、VIP；发消息/加好友/举报/拉黑。
- 黑名单：拉黑后从好友列表移除，私聊不再接收该用户消息。

## 五、7.12 消息中心

- 顶部「消息」25sp Bold，右侧搜索/榜单。
- 在线卡：当前在线 N 人 + 头像堆叠 + 立即查看。
- 入口：聊天室、系统消息、官方群聊、好友消息，带未读红点。
- 系统消息：远程公告/版本更新写入本地系统消息列表，含标题、内容、时间、已读/未读，点击详情。
- 空状态：未登录「登录后可查看」，已登录无消息「暂无消息」。
- 搜索浮层过滤入口与系统消息；榜单按论坛浏览/点赞/评论排序取前十。

## 六、7.13 影评 / 论坛

- 顶部「影评」页头、右上角消息入口（带未读数）、最新/热门 Tab。
- 卡片：头像/昵称/时间/标题/正文摘要/最多九宫格图片/浏览/评论/点赞；刷新与加载更多。
- 发布：标题 ≤30 字、正文 ≤2000 字、板块/圈子选择、最多 9 张图片链接、可选付费内容。
- 详情：图片、正文、付费内容金币解锁、点赞/收藏/分享/举报、评论列表、评论输入、回复某人。
- 我的作品：列表、编辑、长按删除；删除/编辑走 `bbs.php` 管理员/作者 action。
- 内容安全：标题/正文/评论敏感词过滤，举报本地记录，管理员删帖接口可用。

## 七、主题与约束

- 新页面底色使用 `$r('app.color.page_background_dark')`（#FF212121）与
  `$r('app.color.page_background_light')`（#FFFFFFFF）。
- 全部页面 `@StorageLink('immersiveConfig')` 并监听变化；毛玻璃开关/强度修改实时生效。
- 系统深浅色由 `AppState.init` 与 `EntryAbility.onConfigurationUpdate` 自动同步。
- 尺寸统一 vp；未在 @Component/@Entry 内使用 `enabled/blur/opacity/width/height/background/fontColor`
  作为变量名；`ForEach` 均有稳定 key；未引入第三方依赖。

## 八、能力边界（重要）

云逸文档没有提供以下能力，本次按“可运行 + 不伪造服务端”的方式处理：

1. **图片/视频/文件上传服务**：lts.php 只接收文本，发布/聊天使用图片链接或
   `MediaCodec` 资源卡，不做本地二进制上传。
2. **好友关系云存储**：文档没有好友接口，使用 `好友申请_账号` 聊天房间传递申请/通过，
   好友关系与已读位置保存在本机。
3. **付费内容/锁帖**：无独立付费/锁帖接口，付费内容使用 `【paid:N】…【/paid】` 标记，
   解锁调用 `moneyspend.php` 扣金币并本地记录；锁帖暂未开放。
4. **红包领取/退款**：无红包接口，红包卡片在本地标记领取；发红包会调用 `moneyspend.php`
   扣除总额，但无法做服务端 24h 退款。
5. **举报、管理员审核**：无举报接口，举报为本地记录并提示；删帖使用 `deletePost`。

当前环境没有 DevEco Studio / HarmonyOS SDK / hvigor，**未实际编译**；需要在 API 26 工程中
编译一次确认（上一轮已修复 `ColorMode` 导出问题）。

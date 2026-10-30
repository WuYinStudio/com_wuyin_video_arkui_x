# 修改文件
- entry/src/main/ets/components/MediaSessionDialog.ets
- entry/src/main/ets/pages/PlayerPage.ets
- COPLAY_SYNC_REPAIR_NOTES.md

# 核心变更
协议版本与序列号、重复包过滤、8 秒心跳超时、800ms seek 容差、线路/画面比例同步字段、sessionId 序列化前校验。


## v1.7.8 协播无法加入二次排查补丁
- 修复 PlayerPage 对 sessionId 的过严字符白名单：系统生成的 AVSession ID 不再被强制限制为字母、数字、下划线和连字符；改为拒绝控制字符及超过 256 字符的值，与 EntryAbility 的校验策略一致。此不一致会导致邀请通过接收解析后，仍在播放页路由校验阶段被拒绝。
- 统一 SessionInviteParser 的旧邀请兼容规则：缺少 syncMode 时默认 lan，并接受带有效 ws/wss 地址的 server 模式。
- 仍需 DevEco Studio/API 26 编译和双真机验证；本补丁属于静态代码修正，不代表真机入会已验证通过。

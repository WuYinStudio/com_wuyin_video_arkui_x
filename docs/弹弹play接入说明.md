# 无音影视：弹弹play在线弹幕接入说明

本版本在原有 B 站在线弹幕基础上，增加弹弹play开放弹幕网络的搜索、候选展示和弹幕加载入口。候选列表会标注来源，匹配不明确时仍由用户手动选择。

## 启用前配置

文件：`entry/src/main/ets/common/DanmakuService.ets`

找到：

```ts
const DANDAN_APP_ID: string = 'cp2j9qfti5';
const DANDAN_APP_SECRET: string = 'REPLACE_WITH_DANDANPLAY_APP_SECRET';
```

请在本地构建副本中，将 `DANDAN_APP_SECRET` 替换为弹弹play开发者中心提供的有效密钥。不要把真实密钥提交到公开仓库或分享 ZIP。未填写密钥时，弹弹play请求会明确提示未配置，B 站搜索仍可独立使用。

## 接入内容

- 搜索：`GET /api/v2/search/episodes?anime=关键词&v2=true`
- 获取弹幕：`GET /api/v2/comment/{episodeId}?withRelated=true`
- 使用 `X-AppId`、`X-Timestamp`、`X-Signature` 请求头，签名算法遵循官方文档：`base64(sha256(AppId + Timestamp + Path + AppSecret))`。
- 结果列表同时显示弹弹play和 B 站候选。
- 弹幕数据统一转换为播放器现有 `DanmakuItem`，沿用现有渲染层。

## 安全提醒

弹弹play官方建议客户端采用签名验证并避免在客户端硬编码 AppSecret。该 ZIP 为纯客户端集成示例，密钥放入客户端仍可被逆向提取；正式发布更推荐通过自有后端代签/转发请求，并在服务端保护密钥。请遵守弹弹play开放弹幕网络的 API 使用约定和额度限制。

## 验证边界

本环境完成源码修改与 ZIP 完整性检查，但没有 DevEco Studio / HarmonyOS 真机编译环境。需在实际 DevEco 工程中验证 ArkTS 编译、签名接口、响应字段及网络访问。若弹弹play响应结构有差异，需根据实际响应调整解析字段。

官方文档：
- https://doc.dandanplay.com/open/
- https://api.dandanplay.net/swagger/index.html

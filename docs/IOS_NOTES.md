# iOS 运行期问题记录

> 本文只记录 **iOS 端**（ArkUI-X + Xcode 壳）在 Windows 上无法复现、只能靠代码推断与日志确认的问题。
> Android / 鸿蒙的构建问题见 [ANDROID_APK.md](ANDROID_APK.md)。

## 1. 启动页「同意协议」点击后报错（2026-10-30）

### 现象

iOS 包首次启动进入用户协议页，点「同意协议」后在按钮上方出现红字：

```
保存同意状态失败，请重试或退出软件。
```

### 原因

这段文案来自 `pages/UserAgreementPage.ets` 的 `actionError`，只在
`AgreementService.accept()` 抛异常时出现。旧实现只有一条存储路径：

```ts
const store = await preferences.getPreferences(context, 'wuyin');
await store.put('agreementAccepted', true);
await store.flush();
```

`@ohos.data.preferences` 在 iOS 上的 ArkUI-X 原生实现未必可用（与 Android 早期缺
`libdata_preferences.so` 时的表现同类：调用即抛、错误信息是底层 Error）。一旦这里抛异常，
页面就把用户挡在协议页，进不了首页。

### 修法（两级存储 + 不拦截）

`common/AgreementService.ets` 改为：

1. 先走 `preferences`（鸿蒙 / Android 正常路径）；
2. 失败后写 `filesDir/agreement_accepted.json`（`fileIo`，三端都有实现）；
3. 两条都失败也把 `AppStorage('agreementAccepted')` 置 `true`，本次启动放行，
   页面只弹一条「下次启动可能需要重新同意」的提示，不再显示红色错误。

`restore()` 同样先读偏好、再读文件标记，所以第二次启动能正确跳过协议页。

### 自测步骤

1. 重新打 iOS 包（macOS + Xcode，见 [IOS_UNSIGNED_CLOUD_BUILD.md](IOS_UNSIGNED_CLOUD_BUILD.md)）；
2. 首次启动 → 协议页 → 点「同意协议」应直接进入首页；
3. 杀进程再启动 → 不应再出现协议页；
4. 若仍出现协议页，查日志里 `UserAgreement` 标签：
   - `偏好读取失败，改用文件标记` → 说明 preferences 在 iOS 确实不可用，走的是文件兜底（正常）；
   - `写入文件标记失败` → `context.filesDir` 不可写，需要把完整错误文本发回；
5. 想强制回到首次启动状态：删除应用沙箱内 `agreement_accepted.json` 并清掉 `wuyin` 偏好。

### 仍未覆盖

- `exitApp()` 走 `terminateSelf()`；iOS 上若该 API 未实现，点「退出软件」会提示失败（不影响同意流程）。
- 设置页的「导出/导入聊天记录」用 `picker.DocumentViewPicker`，iOS 上若未适配会失败并只写日志，
  后续可加「分享到文件 App」的兜底。

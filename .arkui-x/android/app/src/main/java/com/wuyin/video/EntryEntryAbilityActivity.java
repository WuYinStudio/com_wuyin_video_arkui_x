package com.wuyin.video;

import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import ohos.stage.ability.adapter.StageActivity;

/**
 * 对应 ArkTS 侧 EntryAbility 的平台 Activity（ArkUI-X 官方模板命名：&lt;Entry&gt;&lt;EntryAbility&gt;Activity）。
 * instanceName 必须与 module.json5 的 bundleName / moduleName / abilityName 对齐。
 *
 * 额外职责（本站与原模板的唯一差异）：
 * 1. 把 Android 的 ACTION_SEND / ACTION_VIEW 文本补成 ArkTS 约定的 share_data 参数；
 * 2. 注册 WuYinShareBridge，供 ArkTS common/compat/BridgeShare.ets 拉起系统分享面板。
 */
public class EntryEntryAbilityActivity extends StageActivity {
    private static final String TAG = "WuYinVideo";
    static final String SHARE_DATA_KEY = "ohos.extra.param.key.share_data";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        Log.i(TAG, "EntryEntryAbilityActivity onCreate");
        setInstanceName("com.wuyin.video:entry:EntryAbility:");
        registerShareBridge();
        // 必须在 super.onCreate 之前写入：StageActivity 在 super.onCreate 中读取 Intent 生成 Want。
        forwardSharedText(getIntent());
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        forwardSharedText(intent);
    }

    private void registerShareBridge() {
        try {
            WuYinShareBridge.init(this);
            new WuYinShareBridge();
        } catch (Throwable error) {
            // 桥接不可用时 ArkTS 侧 BridgeShare 会回退到剪贴板，不应影响应用启动。
            Log.w(TAG, "WuYinShareBridge unavailable: " + error);
        }
    }

    /**
     * Android 的 ACTION_SEND 文本不在 Want 里，这里补成 ArkTS 侧约定的 share_data 参数，
     * 让 EntryAbility.captureSharedWant() 的现有解析链路直接复用。
     */
    private void forwardSharedText(Intent intent) {
        if (intent == null) {
            return;
        }
        String action = intent.getAction();
        if (!Intent.ACTION_SEND.equals(action) && !Intent.ACTION_VIEW.equals(action)) {
            return;
        }
        CharSequence text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
        if (text == null || text.length() == 0) {
            return;
        }
        if (intent.hasExtra(SHARE_DATA_KEY)) {
            return;
        }
        intent.putExtra(SHARE_DATA_KEY, text.toString());
        Log.i(TAG, "forward shared text, length=" + text.length());
    }
}

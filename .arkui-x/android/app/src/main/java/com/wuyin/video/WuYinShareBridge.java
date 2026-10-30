package com.wuyin.video;

import android.app.Activity;
import android.content.Intent;
import android.util.Log;

import ohos.ace.adapter.capability.bridge.BridgePlugin;

/**
 * 平台桥接：ArkTS 侧 common/compat/BridgeShare.ets 调用 callMethod('shareText', title, content)。
 * Bridge 名称必须与 ArkTS 侧 createBridge('WuYinShare') 一致。
 */
public class WuYinShareBridge extends BridgePlugin {
    private static final String TAG = "WuYinVideo";
    private static final String BRIDGE_NAME = "WuYinShare";
    private static Activity activity;

    public static void init(Activity host) {
        activity = host;
    }

    public WuYinShareBridge() {
        super(BRIDGE_NAME, BridgeType.JSON_TYPE);
    }

    /** 供 ArkUI 侧调用：拉起系统分享面板。返回 "ok" 表示已拉起。 */
    public String shareText(String title, String content) {
        if (activity == null) {
            return "no-activity";
        }
        if (content == null || content.length() == 0) {
            return "empty";
        }
        Intent send = new Intent(Intent.ACTION_SEND);
        send.setType("text/plain");
        send.putExtra(Intent.EXTRA_SUBJECT, title == null ? "无音影视" : title);
        send.putExtra(Intent.EXTRA_TEXT, content);
        Intent chooser = Intent.createChooser(send, title == null ? "分享" : title);
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activity.startActivity(chooser);
        Log.i(TAG, "shareText dispatched, length=" + content.length());
        return "ok";
    }
}

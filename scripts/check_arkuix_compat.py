#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ArkUI-X 跨平台静态自检

检查项：
  1. ArkTS import 的 @kit.* / @ohos.* 模块是否在 ArkUI-X 6.0.2（API 22）跨平台支持列表内；
  2. 业务代码（common/compat 适配层除外）是否还残留 HarmonyOS 专有 API 标识；
  3. @Entry 页面与 main_pages.json 是否双向一致；
  4. module.json5 是否声明了 ArkUI-X 不支持的 extensionAbilities；
  5. .arkui-x/arkui-x-config.json5 是否开启跨平台模块。

用法: python3 scripts/check_arkuix_compat.py [项目根目录]
退出码 0 = 无阻断项。
"""
import json
import os
import re
import sys

# ArkUI-X 6.0.0 Release 跨平台支持的 Kit（官方“OpenHarmony接口定义跨平台支持列表”）
SUPPORTED_KITS = {
    '@kit.AbilityKit', '@kit.ArkUI', '@kit.ArkData', '@kit.ArkTS',
    '@kit.BasicServicesKit', '@kit.CoreFileKit', '@kit.MediaKit',
    '@kit.ImageKit', '@kit.NetworkKit', '@kit.CryptoArchitectureKit',
    '@kit.ArkWeb', '@kit.MediaLibraryKit', '@kit.NotificationKit',
    '@kit.ArkGraphics2D', '@kit.SensorServiceKit', '@kit.LocationKit',
    '@kit.InputKit', '@kit.MDMKit',
}
SUPPORTED_OHOS_PREFIX = (
    '@ohos.app.ability.', '@ohos.bundle.', '@ohos.zlib', '@ohos.window',
    '@ohos.display', '@ohos.effectKit', '@ohos.graphics.', '@ohos.multimedia.',
    '@ohos.i18n', '@ohos.intl', '@ohos.resourceManager', '@ohos.request',
    '@ohos.net.', '@ohos.wifiManager', '@ohos.bluetooth.', '@ohos.file.',
    '@ohos.deviceInfo', '@ohos.pasteboard', '@ohos.data.', '@ohos.abilityAccessCtrl',
    '@ohos.security.', '@ohos.hilog', '@ohos.hiTraceMeter', '@ohos.web.',
    '@ohos.commonEventManager', '@ohos.notificationManager', '@ohos.events.',
    '@ohos.vibrator', '@ohos.geoLocationManager', '@ohos.systemDateTime',
    '@ohos.router', '@ohos.promptAction', '@ohos.animator', '@ohos.arkui.',
)

# HarmonyOS 专有标识：只允许出现在 common/compat 适配层与 legacy 归档里
FORBIDDEN = [
    (re.compile(r'(?<![\w.])systemShare\.'), 'ShareKit 系统分享'),
    (re.compile(r'(?<![\w.])avSession\.'), 'AVSession 系统协同会话'),
    (re.compile(r'(?<![\w.])distributedDeviceManager\.'), '分布式设备管理'),
    (re.compile(r'(?<![\w.])wantAgent\.'), 'WantAgent 通知点击意图'),
    (re.compile(r'(?<![\w.])nfcController\b'), 'NFC 控制器'),
    (re.compile(r'@kit\.(ShareKit|AVSessionKit|ConnectivityKit|DistributedServiceKit|IMEKit|ArkGraphics3D)'),
     'HarmonyOS 专有 Kit'),
    (re.compile(r'@tencent/qq-open-sdk'), 'HarmonyOS 三方 HAP 库'),
    (re.compile(r'\bComponent3D\s*\('), 'ArkGraphics3D 组件'),
]

IMPORT_RE = re.compile(r"import\s+(?:type\s+)?(?:[^;]*?)\s*from\s+['\"]([^'\"]+)['\"]", re.S)

errors = []
warns = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warns.append(msg)


def strip_json5(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return text


def load_json5(path):
    with open(path, encoding='utf-8') as f:
        return json.loads(strip_json5(f.read()))


def code_lines(text):
    """去掉行注释与块注释，避免注释里的历史说明被误判。"""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    out = []
    for line in text.split('\n'):
        idx = line.find('//')
        out.append(line[:idx] if idx >= 0 else line)
    return out


def main():
    # 兼容 python3 check.py <root> 与工具直接调用两种方式
    root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ets_root = os.path.join(root, 'entry', 'src', 'main', 'ets')

    files = []
    for dirpath, _, filenames in os.walk(ets_root):
        for name in filenames:
            if name.endswith('.ets'):
                files.append(os.path.join(dirpath, name))
    print('项目根目录: %s' % root)
    print('扫描 ArkTS 文件: %d 个' % len(files))

    imported = {}
    for path in files:
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        text = open(path, encoding='utf-8').read()
        for spec in IMPORT_RE.findall(text):
            if not spec.startswith('.'):
                imported.setdefault(spec, []).append(rel)
        if '/compat/' in rel or rel.startswith('legacy/'):
            continue
        for index, line in enumerate(code_lines(text), 1):
            for pattern, label in FORBIDDEN:
                if pattern.search(line):
                    err('%s:%d 仍使用 %s' % (rel, index, label))

    for spec, owners in sorted(imported.items()):
        if spec.startswith('@kit.') and spec not in SUPPORTED_KITS:
            err('不在 ArkUI-X 支持列表的 Kit: %s (%s)' % (spec, owners[0]))
        elif spec.startswith('@ohos.') and not spec.startswith(SUPPORTED_OHOS_PREFIX):
            err('不在 ArkUI-X 支持列表的模块: %s (%s)' % (spec, owners[0]))
        elif spec.startswith(('@kit.', '@ohos.', '@arkui-x.')):
            continue
        else:
            err('未声明的三方依赖: %s (%s)' % (spec, owners[0]))

    # @Entry 页面与 main_pages.json 双向一致
    pages_json = os.path.join(root, 'entry/src/main/resources/base/profile/main_pages.json')
    if not os.path.exists(pages_json):
        err('缺少 main_pages.json')
        declared = []
    else:
        declared = load_json5(pages_json).get('src', [])
    entry_pages = []
    for path in files:
        rel = os.path.relpath(path, ets_root).replace(os.sep, '/')
        if not rel.startswith('pages/'):
            continue
        if '@Entry' in open(path, encoding='utf-8').read():
            entry_pages.append(rel[:-4])
    for page in declared:
        if not os.path.exists(os.path.join(ets_root, page + '.ets')):
            err('main_pages.json 声明的页面不存在: %s' % page)
    for page in entry_pages:
        if page not in declared:
            err('@Entry 页面未注册到 main_pages.json: %s' % page)
    print('页面: @Entry %d 个 / 已注册 %d 个' % (len(entry_pages), len(declared)))

    # extensionAbilities 不受 ArkUI-X 支持
    module_json = os.path.join(root, 'entry/src/main/module.json5')
    if os.path.exists(module_json):
        raw = strip_json5(open(module_json, encoding='utf-8').read())
        if '"extensionAbilities"' in raw:
            err('module.json5 仍声明 extensionAbilities（ArkUI-X 不支持系统扩展 Ability）')

    # 跨平台配置
    cfg_path = os.path.join(root, '.arkui-x/arkui-x-config.json5')
    if not os.path.exists(cfg_path):
        err('缺少 .arkui-x/arkui-x-config.json5')
    else:
        cfg = load_json5(cfg_path)
        if not cfg.get('crossplatform'):
            err('.arkui-x/arkui-x-config.json5 未开启 crossplatform')
        if 'entry' not in (cfg.get('modules') or []):
            err('.arkui-x/arkui-x-config.json5 modules 未包含 entry')
        # schema：arkui-x-config.json5 只允许 crossplatform / modules / buildOption / platforms，
        # ignoreCrossPlatform 必须写在 buildOption 下（写在顶层会直接让 hvigor 配置阶段失败）。
        allowed = {'crossplatform', 'modules', 'buildOption', 'platforms'}
        for key in cfg:
            if key not in allowed:
                err('.arkui-x/arkui-x-config.json5 含非法字段 "%s"（schema 只允许 %s）'
                    % (key, ' / '.join(sorted(allowed))))
        build_option = cfg.get('buildOption') or {}
        if not build_option.get('ignoreCrossPlatform'):
            warn('buildOption.ignoreCrossPlatform 未开启：'
                 'ArkTS 跨平台 API 检查会把 router.replaceUrl 等调用报为编译错误')

    print()
    for line in warns:
        print('  [WARN] %s' % line)
    for line in errors:
        print('  [FAIL] %s' % line)
    print()
    print('结论: %s (阻断 %d / 警告 %d)' % ('通过' if not errors else '存在阻断项', len(errors), len(warns)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

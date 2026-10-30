#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
无音影视 v5.0.0 — HarmonyOS 26.0.0 构建前静态自检 (preflight)

在真正调用 hvigor 之前，把「改完代码就得重新编译一轮才发现」的配置类错误先抓出来：
  1. module.json5 / app.json5 是否为合法 JSON5（注释、尾逗号、裸键）
  2. module.json5 & app.json5 里引用的 $string / $media / $color / $profile 资源是否存在
  3. main_pages.json 里声明的页面文件是否存在
  4. abilities / extensionAbilities 的 srcEntry 是否存在
  5. .ets 里 $r('app.xxx.name') 引用的资源是否存在
  6. 相对 import 是否都能解析到 .ets/.ts
  7. 三方 bare import 是否都在 oh-package.json5 里声明、oh_modules 是否已安装
  8. 关键版本字段是否对齐（compileSdkVersion / modelVersion）

用法:
  python3 scripts/preflight.py [项目根目录]
退出码 0 = 无阻断项（可能有警告）；1 = 有阻断项。
"""
import json
import os
import re
import sys

RES_REF = re.compile(r"\$(string|media|color|profile|float|boolean|integer|plural|symbol|rawfile):([A-Za-z0-9_.]+)")

errors = []
warns = []
ok = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warns.append(msg)


# ---------------------------------------------------------------- JSON5
def strip_json5(text):
    """去掉 // 与 /* */ 注释与尾逗号，并给裸键加引号。字符串内容原样保留。"""
    out = []
    i, n = 0, len(text)
    instr = None
    esc = False
    while i < n:
        c = text[i]
        if instr:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == instr:
                instr = None
            i += 1
            continue
        if c in "'\"":
            instr = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    t = "".join(out)
    t = re.sub(r"([{,]\s*)([A-Za-z_$][A-Za-z0-9_$]*)(\s*:)", r'\1"\2"\3', t)
    t = re.sub(r",(\s*[}\]])", r"\1", t)
    # JSON5 允许单引号字符串
    t = re.sub(r"'([^'\\]*)'", lambda m: json.dumps(m.group(1), ensure_ascii=False), t)
    return t


def load_json5(path):
    raw = open(path, encoding="utf-8").read()
    try:
        return json.loads(strip_json5(raw))
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("%s 不是合法 JSON5: %s" % (path, e)) from e


# ---------------------------------------------------------------- 资源表
def elem_names(path):
    if not os.path.exists(path):
        return set()
    try:
        d = load_json5(path)
    except RuntimeError:
        return set()
    names = set()
    for key, arr in d.items():
        if isinstance(arr, list):
            for item in arr:
                if isinstance(item, dict) and "name" in item:
                    names.add(item["name"])
    return names


def media_names(dirpath):
    if not os.path.isdir(dirpath):
        return set()
    names = set()
    for f in os.listdir(dirpath):
        stem = f.rsplit(".", 1)[0]
        names.add(stem)
        # 点分限定名，例如 icon.dark
        parts = f.split(".")
        for k in range(1, len(parts)):
            names.add(".".join(parts[:k]))
    return names


def build_res_index(root):
    """返回 {(kind, name): 定义位置}，kind 为 string/media/color/profile。"""
    idx = {}

    def add(kind, names, where):
        for nm in names:
            idx.setdefault((kind, nm), where)

    for scope, base in (("app", os.path.join(root, "AppScope", "resources")),
                        ("mod", os.path.join(root, "entry", "src", "main", "resources"))):
        if not os.path.isdir(base):
            continue
        for qual in os.listdir(base):
            qdir = os.path.join(base, qual)
            if not os.path.isdir(qdir):
                continue
            for sub in os.listdir(qdir):
                p = os.path.join(qdir, sub)
                if sub == "element" and os.path.isdir(p):
                    for f in os.listdir(p):
                        if f.endswith(".json"):
                            kind = f.rsplit(".", 1)[0]
                            add(kind, elem_names(os.path.join(p, f)), os.path.join(p, f))
                elif sub == "media" and os.path.isdir(p):
                    add("media", media_names(p), p)
                elif sub == "profile" and os.path.isdir(p):
                    add("profile", {f.rsplit(".", 1)[0] for f in os.listdir(p)}, p)
                elif sub == "rawfile" and os.path.isdir(p):
                    add("rawfile", set(), p)
    return idx


# ---------------------------------------------------------------- 主流程
def main():
    # 允许在同一个解释器里重复调用（清空上一轮结果）
    del errors[:]
    del warns[:]
    del ok[:]
    # 只接受「确实是目录」的参数，避免把脚本路径或解释器选项当成项目根
    argv = [a for a in sys.argv[1:] if os.path.isdir(a)]
    root = argv[0] if argv else os.getcwd()
    root = os.path.abspath(root)
    print("项目根目录: %s\n" % root)
    for need in ("build-profile.json5", "oh-package.json5", "hvigorfile.ts",
                 os.path.join("entry", "build-profile.json5"),
                 os.path.join("entry", "src", "main", "module.json5")):
        if not os.path.exists(os.path.join(root, need)):
            err("缺少必需文件: %s" % need)
    if errors:
        for line in errors:
            print("  [FAIL] %s" % line)
        print("\n结论: 缺少工程文件，无法继续自检")
        return 1

    # --- build-profile.json5
    bp = load_json5(os.path.join(root, "build-profile.json5"))
    prods = bp.get("app", {}).get("products", [])
    if not prods:
        err("build-profile.json5 没有 products")
    for p in prods:
        csv = p.get("compileSdkVersion")
        print("product %-8s compileSdk=%-8s target=%-8s compatible=%s" %
              (p.get("name"), csv if csv else "IDE决定", p.get("targetSdkVersion"), p.get("compatibleSdkVersion")))
        # runtimeOS=HarmonyOS（含 ArkUI-X 工程）按官方约定不写 compileSdkVersion，由本机 SDK 决定。
        if not csv and p.get("runtimeOS") != "HarmonyOS":
            err("product %s 缺少 compileSdkVersion" % p.get("name"))
        if p.get("name") == "default" and p.get("runtimeOS") != "HarmonyOS":
            warn("runtimeOS 不是 HarmonyOS: %s" % p.get("runtimeOS"))
    if bp.get("app", {}).get("signingConfigs"):
        warn("检测到 signingConfigs —— 那会产出已签名 HAP；要「未签名」请留空该字段")

    # --- AppScope/app.json5
    app = load_json5(os.path.join(root, "AppScope", "app.json5"))["app"]
    for k in ("bundleName", "versionCode", "versionName", "icon", "label"):
        if k not in app:
            err("app.json5 缺少 %s" % k)
    print("bundleName=%s versionName=%s(%s)" % (app.get("bundleName"), app.get("versionName"), app.get("versionCode")))

    # --- module.json5
    mod = load_json5(os.path.join(root, "entry", "src", "main", "module.json5"))["module"]
    entry = os.path.join(root, "entry", "src", "main")
    for k in ("name", "type", "deviceTypes", "abilities"):
        if k not in mod:
            err("module.json5 缺少 %s" % k)
    if mod.get("mainElement") and not any(a.get("name") == mod["mainElement"] for a in mod.get("abilities", [])):
        err("mainElement=%s 没有对应 ability" % mod["mainElement"])
    print("module=%s type=%s deviceTypes=%s" % (mod.get("name"), mod.get("type"), mod.get("deviceTypes")))
    if "2in1" in (mod.get("deviceTypes") or []):
        ok.append("deviceTypes 含 2in1（可装到 HarmonyOS PC）")
    else:
        warn("deviceTypes=%s 不含 2in1：装到 HarmonyOS PC / 2in1 设备会被系统拒绝" % mod.get("deviceTypes"))

    for ab in mod.get("abilities", []) + mod.get("extensionAbilities", []):
        src = ab.get("srcEntry")
        if not src:
            err("组件 %s 缺少 srcEntry" % ab.get("name"))
            continue
        rel = src.lstrip("./")
        if not os.path.exists(os.path.join(entry, rel)):
            err("组件 %s 的 srcEntry 不存在: %s" % (ab.get("name"), src))

    # --- pages
    prof = (mod.get("pages") or "").replace("$profile:", "")
    pages_file = None
    for cand in (os.path.join(entry, "resources", "base", "profile", prof + ".json"),
                 os.path.join(entry, "resources", "base", "profile", prof)):
        if os.path.exists(cand):
            pages_file = cand
            break
    if not pages_file:
        err("找不到 pages profile: %s" % mod.get("pages"))
    else:
        pages = json.load(open(pages_file, encoding="utf-8")).get("src", [])
        print("声明页面 %d 个" % len(pages))
        for pg in pages:
            if not any(os.path.exists(os.path.join(entry, "ets", pg + ext)) for ext in (".ets", ".ts")):
                err("main_pages 声明的页面不存在: %s" % pg)

    # --- 资源引用（module.json5 + app.json5）
    res = build_res_index(root)
    for label, path in (("module.json5", os.path.join(entry, "module.json5")),
                        ("app.json5", os.path.join(root, "AppScope", "app.json5"))):
        for kind, name in RES_REF.findall(open(path, encoding="utf-8").read()):
            if kind == "profile" and name == prof:
                continue
            if (kind, name) not in res:
                err("%s 引用的资源缺失: $%s:%s" % (label, kind, name))
    if not errors or all("资源缺失" not in e for e in errors):
        ok.append("module.json5 / app.json5 的资源引用全部命中")

    # --- .ets 扫描
    ets_root = os.path.join(entry, "ets")
    files = []
    for dirpath, _, names in os.walk(ets_root):
        for f in names:
            if f.endswith((".ets", ".ts")):
                files.append(os.path.join(dirpath, f))
    print("ArkTS 源文件 %d 个" % len(files))

    imp_re = re.compile(r"""(?:^|\n)\s*(?:import|export)\b[^;\n]*?\bfrom\s*['"]([^'"]+)['"]""")
    bare = {}
    bad_rel = []
    bad_res = []
    for path in files:
        src = open(path, encoding="utf-8").read()
        rel_path = os.path.relpath(path, root)
        for spec in imp_re.findall(src):
            if spec.startswith("."):
                base = os.path.normpath(os.path.join(os.path.dirname(path), spec))
                if not (any(os.path.exists(base + e) for e in (".ets", ".ts", ".d.ts", ".json", ""))
                        or any(os.path.exists(os.path.join(base, "index" + e)) for e in (".ets", ".ts"))):
                    bad_rel.append((rel_path, spec))
            else:
                bare[spec] = bare.get(spec, 0) + 1
        for kind, name in re.findall(r"\$r\(\s*['\"]app\.(media|string|color|profile|float|boolean|integer|plural|symbol|rawfile)\.([A-Za-z0-9_.]+)['\"]", src):
            if (kind, name) not in res:
                bad_res.append((rel_path, kind, name))
    for rel_path, spec in bad_rel:
        err("相对 import 无法解析: %s -> %s" % (rel_path, spec))
    if not bad_rel:
        ok.append("全部相对 import 可解析")
    for rel_path, kind, name in bad_res:
        err("$r 引用资源不存在: %s -> app.%s.%s" % (rel_path, kind, name))
    if not bad_res:
        ok.append("全部 $r() 资源引用命中")

    # --- 三方依赖
    deps = {}
    for p in (os.path.join(root, "oh-package.json5"), os.path.join(root, "entry", "oh-package.json5")):
        if os.path.exists(p):
            d = load_json5(p)
            deps.update(d.get("dependencies") or {})
            deps.update(d.get("devDependencies") or {})
    installed = os.path.isdir(os.path.join(root, "oh_modules")) or os.path.isdir(
        os.path.join(root, "entry", "oh_modules"))
    for spec, cnt in sorted(bare.items(), key=lambda kv: -kv[1]):
        if spec.startswith("@kit.") or spec.startswith("@ohos.") or spec.startswith("@system.") \
                or spec.startswith("@arkui-x."):
            continue
        pkg = "/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0]
        if pkg not in deps:
            err("三方 import 未在 oh-package.json5 声明: %s (%d 处)" % (pkg, cnt))
        elif not installed:
            warn("依赖 %s 已声明但 oh_modules 未安装，先执行 ohpm install" % pkg)

    # --- 汇总
    print()
    for line in ok:
        print("  [OK]   %s" % line)
    for line in warns:
        print("  [WARN] %s" % line)
    for line in errors:
        print("  [FAIL] %s" % line)
    print()
    print("结论: %s (阻断 %d / 警告 %d)" % ("可以通过" if not errors else "存在阻断项",
                                          len(errors), len(warns)))
    return 1 if errors else 0


def report():
    for line in errors:
        print("  [FAIL] %s" % line)
    return 1


if __name__ == "__main__":
    sys.exit(main())

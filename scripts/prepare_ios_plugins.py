#!/usr/bin/env python3
"""Prepare the ArkUI-X iOS plugin frameworks required by this app.

The ArkUI-X macOS SDK ships the engine (libarkui_ios.xcframework) and a large
set of dynamically linked plugin frameworks (net.http, file.fs, router,
preferences, bridge, ...).  The stock "arkui-x" Xcode template only links the
engine, so every @ohos.* plugin resolves to `undefined` at runtime on iOS.
This script extracts the transitive closure of the plugin frameworks used by
the ArkTS sources and writes a temporary xcconfig that links them.

Usage:
    python3 scripts/prepare_ios_plugins.py \
        --sdk-zip /tmp/arkui-x-macos-sdk.zip \
        --arch-dir ios-x86_64-simulator \
        --out build/ios-plugins \
        --xcconfig build/ios-plugins.xcconfig

Arch directory names in the SDK:
    ios-x86_64-simulator   Intel simulator (the CI runner)
    ios-arm64-simulator    Apple Silicon simulator
    ios-arm64-release      physical device
"""

import argparse
import os
import re
import struct
import sys
import zipfile

# Modules imported by entry/src/main/ets (see scripts/README or run
# `grep -r "from '@ohos" entry/src/main/ets`).  Keep this list in sync when a
# new @ohos.* module is imported.
REQUIRED = [
    "libabilityaccessctrl",
    "libbridge",
    "libdata_preferences",
    "libdata_uniformtypedescriptor",
    "libdeviceinfo",
    "libfile_fs",
    "libfile_picker",
    "libfile_streamrw",
    "libmultimedia_audio",
    "libmultimedia_media",
    "libnet_connection",
    "libnet_http",
    "libnet_socket",
    "libnet_websocket",
    "libpasteboard",
    "libpromptaction",
    "librequest",
    "librouter",
    "libsecurity_cryptoframework",
    "libutil",
    "libutil_stream",
    "libzlib",
    # ArkUI 组件在 iOS 上也是独立动态模块；缺少时会在页面挂载瞬间 FATAL
    # （例如 WallpaperPage 的 Slider 会先报 "Can't find checkbox dynamic module"）。
    "libarkui_checkbox",
    "libarkui_radio",
    "libarkui_slider",
    "libarkui_gauge",
    "libarkui_rating",
    "libarkui_stepper",
    "libarkui_sidebar",
    "libarkui_calendarpicker",
    "libarkui_indexer",
    "libarkui_linearsplit",
    "libarkui_timepicker",
]

LOAD_DYLIB = 0xC
LOAD_WEAK_DYLIB = 0x80000018
REEXPORT_DYLIB = 0x8000001F

# Search roots for a framework binary inside the SDK zip.  The first root that
# contains <root>/<arch-dir>/<name>.framework/<name> wins.
ROOTS = [
    "arkui-x/plugins/api/framework",
    "arkui-x/plugins/component/framework",
    "arkui-x/engine/framework/arkui",
    "arkui-x/engine/framework/utils",
    "arkui-x/engine/framework/third_party",
]


def macho_slices(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack(">I", data[4:8])[0]
        for i in range(count):
            off = 8 + i * 20
            _cputype, _sub, offset, size, _align = struct.unpack(">iiIII", data[off:off + 20])
            yield offset, size
    else:
        yield 0, len(data)


def dylib_deps(data):
    out = []
    for offset, size in macho_slices(data):
        s = data[offset:offset + size]
        if len(s) < 28:
            continue
        try:
            _m, _ct, _cs, _ft, ncmds, _sz, _fl = struct.unpack("<IiiIIII", s[:28])
        except struct.error:
            continue
        p = 32
        for _ in range(ncmds):
            if p + 12 > len(s):
                break
            cmd, cmdsize = struct.unpack("<II", s[p:p + 8])
            if cmdsize < 8:
                break
            if cmd in (LOAD_DYLIB, LOAD_WEAK_DYLIB, REEXPORT_DYLIB):
                name_off = struct.unpack("<I", s[p + 8:p + 12])[0]
                end = s.find(b"\x00", p + name_off)
                if end > p + name_off:
                    out.append(s[p + name_off:end].decode("utf-8", "replace"))
            p += cmdsize
    return out


class Sdk:
    def __init__(self, zip_path, arch_dir):
        self.z = zipfile.ZipFile(zip_path)
        self.arch_dir = arch_dir
        self.names = set(self.z.namelist())
        self.index = {}
        for root in ROOTS:
            prefix = f"{root}/{arch_dir}/"
            for name in self.names:
                if not name.startswith(prefix):
                    continue
                rest = name[len(prefix):]
                parts = rest.split("/")
                if len(parts) != 2 or not parts[0].endswith(".framework"):
                    continue
                fw = parts[0][:-10]
                if parts[1] == fw and fw not in self.index:
                    self.index[fw] = name

    def binary(self, name):
        return self.index.get(name)

    def dependencies(self, name):
        path = self.index.get(name)
        if path is None:
            return []
        data = self.z.read(path)
        out = []
        for dep in dylib_deps(data):
            m = re.match(r"@rpath/(.+?)\.framework/", dep)
            if m and not m.group(1).startswith("libarkui_ios"):
                out.append(m.group(1))
        return out

    def closure(self, roots):
        seen = set()
        missing = set()
        queue = list(roots)
        while queue:
            name = queue.pop()
            if name in seen:
                continue
            seen.add(name)
            if name not in self.index:
                missing.add(name)
                continue
            queue.extend(self.dependencies(name))
        return seen, missing

    def extract_framework(self, name, out_dir):
        src = f"{os.path.dirname(self.index[name])}/"
        target = os.path.join(out_dir, name + ".framework")
        if os.path.isdir(target):
            return target
        os.makedirs(target, exist_ok=True)
        for entry in self.names:
            if not entry.startswith(src):
                continue
            rel = entry[len(src):]
            if not rel:
                continue
            dest = os.path.join(target, *rel.split("/"))
            if entry.endswith("/"):
                os.makedirs(dest, exist_ok=True)
                continue
            parent = os.path.dirname(dest)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with self.z.open(entry) as f, open(dest, "wb") as out:
                out.write(f.read())
            # Preserve the executable bit for the framework binary.
            if rel == os.path.basename(target)[:-10]:
                os.chmod(dest, 0o755)
        return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-zip", required=True)
    parser.add_argument("--arch-dir", required=True,
                        choices=["ios-x86_64-simulator", "ios-arm64-simulator", "ios-arm64-release"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--xcconfig", required=True)
    args = parser.parse_args()

    sdk = Sdk(args.sdk_zip, args.arch_dir)
    names, missing = sdk.closure(REQUIRED)
    if missing:
        print("Missing plugin frameworks in SDK: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    os.makedirs(args.out, exist_ok=True)
    names = sorted(names)
    for name in names:
        sdk.extract_framework(name, args.out)

    os.makedirs(os.path.dirname(os.path.abspath(args.xcconfig)), exist_ok=True)
    flags = " ".join("-framework " + name for name in names)
    with open(args.xcconfig, "w", encoding="utf-8") as f:
        f.write("// Generated by scripts/prepare_ios_plugins.py - do not edit.\n")
        f.write("FRAMEWORK_SEARCH_PATHS = $(inherited) " + os.path.abspath(args.out) + "\n")
        f.write("OTHER_LDFLAGS = $(inherited) -ObjC " + flags + "\n")
        f.write("LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks\n")

    print("extracted {} plugin frameworks to {}".format(len(names), args.out))
    print("xcconfig: " + args.xcconfig)
    print("frameworks: " + " ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())

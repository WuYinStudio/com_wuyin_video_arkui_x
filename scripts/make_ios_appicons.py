"""Generate the iOS AppIcon asset set from the app's own icon.

Run from the repo root:
    python scripts/make_ios_appicons.py

Source: AppScope/resources/base/media/icon.png
Target: .arkui-x/ios/app/Assets.xcassets/AppIcon.appiconset/
"""

import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "AppScope", "resources", "base", "media", "icon.png")
OUT = os.path.join(ROOT, ".arkui-x", "ios", "app", "Assets.xcassets", "AppIcon.appiconset")

# (idiom, size, scale, pixel)
ENTRIES = [
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20),
    ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29),
    ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40),
    ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76),
    ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def main() -> int:
    if not os.path.exists(SRC):
        print(f"icon not found: {SRC}")
        return 1
    os.makedirs(OUT, exist_ok=True)

    src = Image.open(SRC).convert("RGBA")
    written = {}

    for idiom, size, scale, pixels in ENTRIES:
        name = f"AppIcon-{size.replace('.', '_')}@{scale}.png"
        if name not in written:
            img = src.resize((pixels, pixels), Image.LANCZOS)
            # App Store icon must be opaque (no alpha channel).
            if pixels == 1024:
                flat = Image.new("RGB", img.size, (0, 0, 0))
                flat.paste(img, mask=img.split()[3])
                flat.save(os.path.join(OUT, name))
            else:
                img.save(os.path.join(OUT, name))
            written[name] = pixels

    images = [
        {"idiom": idiom, "size": size, "scale": scale,
         "filename": f"AppIcon-{size.replace('.', '_')}@{scale}.png"}
        for idiom, size, scale, _ in ENTRIES
    ]
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(OUT, "Contents.json"), "w", encoding="utf-8") as fp:
        json.dump(contents, fp, indent=2, ensure_ascii=False)
        fp.write("\n")

    print(f"generated {len(written)} png + Contents.json -> {OUT}")
    for name in sorted(written):
        print(f"  {name}  {written[name]}x{written[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

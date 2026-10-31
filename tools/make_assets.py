#!/usr/bin/env python3
"""Generates RIFT RIVALS' original artwork: the app icon and launch logo.

Run from the repository root:  python3 tools/make_assets.py
Requires Pillow. Output goes into App/RiftRivals/Resources/Assets.xcassets.
"""
import json
import math
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "RiftRivals", "Resources", "Assets.xcassets")
EMBER = (255, 90, 60)
TIDE = (34, 225, 195)
RIFT = (217, 210, 255)
INK = (7, 10, 20)
INK2 = (16, 22, 44)


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def glow(size, center, radius, color, strength=1.0):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    steps = 40
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(255 * strength * (1 - i / steps) ** 2)
        d.ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=color + (a,))
    return layer.filter(ImageFilter.GaussianBlur(radius / 12))


def make_icon(S=1024):
    img = Image.new("RGBA", (S, S), INK + (255,))
    d = ImageDraw.Draw(img)
    # Vertical gradient background.
    for y in range(S):
        t = y / S
        c = tuple(int(INK2[k] * (1 - t) + INK[k] * t) for k in range(3))
        d.line([(0, y), (S, y)], fill=c + (255,))
    # Team halves split by a diagonal rift.
    def half(color, left):
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        off = 90
        if left:
            poly = [(0, 0), (S * 0.5 + off, 0), (S * 0.5 - off, S), (0, S)]
        else:
            poly = [(S * 0.5 + off, 0), (S, 0), (S, S), (S * 0.5 - off, S)]
        ld.polygon(poly, fill=color + (70,))
        return layer
    img = Image.alpha_composite(img, half(EMBER, True))
    img = Image.alpha_composite(img, half(TIDE, False))
    img = Image.alpha_composite(img, glow((S, S), (S * 0.22, S * 0.5), S * 0.45, EMBER, 0.55))
    img = Image.alpha_composite(img, glow((S, S), (S * 0.78, S * 0.5), S * 0.45, TIDE, 0.55))
    # The rift: a jagged bright crack.
    rift = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rift)
    pts = [(S * 0.5 + 95, -20), (S * 0.53, S * 0.22), (S * 0.47, S * 0.36), (S * 0.535, S * 0.5),
           (S * 0.465, S * 0.64), (S * 0.53, S * 0.78), (S * 0.5 - 95, S + 20)]
    rd.line(pts, fill=RIFT + (255,), width=34, joint="curve")
    rift_glow = rift.filter(ImageFilter.GaussianBlur(28))
    img = Image.alpha_composite(img, rift_glow)
    img = Image.alpha_composite(img, rift_glow)
    rd2 = ImageDraw.Draw(rift)
    rd2.line(pts, fill=(255, 255, 255, 255), width=12, joint="curve")
    img = Image.alpha_composite(img, rift)
    # The shard: a diamond in the centre with a glow.
    img = Image.alpha_composite(img, glow((S, S), (S / 2, S / 2), S * 0.3, (255, 255, 255), 0.6))
    shard = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shard)
    r = S * 0.17
    c = (S / 2, S / 2)
    diamond = [(c[0], c[1] - r), (c[0] + r, c[1]), (c[0], c[1] + r), (c[0] - r, c[1])]
    sd.polygon(diamond, fill=(255, 255, 255, 255))
    inner = [(c[0], c[1] - r * 0.55), (c[0] + r * 0.55, c[1]), (c[0], c[1] + r * 0.55), (c[0] - r * 0.55, c[1])]
    sd.polygon(inner, fill=RIFT + (255,))
    sd.polygon([(c[0], c[1] - r), (c[0] + r, c[1]), (c[0], c[1])], fill=(255, 220, 210, 255))
    sd.polygon([(c[0], c[1] + r), (c[0] - r, c[1]), (c[0], c[1])], fill=(200, 255, 245, 255))
    img = Image.alpha_composite(img, shard)
    # Orbiting pulse rings.
    rings = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(rings)
    for rr, col in [(S * 0.3, EMBER), (S * 0.36, TIDE)]:
        gd.arc([c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], start=200 if col == EMBER else 20, end=320 if col == EMBER else 140,
               fill=col + (255,), width=18)
    img = Image.alpha_composite(img, rings.filter(ImageFilter.GaussianBlur(1)))
    return img.convert("RGB")  # App Store icons must not contain alpha


def make_launch_logo(W=900, H=240):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Diamond shard + rift line, matching the icon (text is rendered by the app).
    cx, cy, r = W / 2, H / 2, 70
    img = Image.alpha_composite(img, glow((W, H), (cx, cy), 120, (255, 255, 255), 0.5))
    d = ImageDraw.Draw(img)
    d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=(255, 255, 255, 255))
    d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy)], fill=EMBER + (255,))
    d.polygon([(cx, cy + r), (cx - r, cy), (cx, cy)], fill=TIDE + (255,))
    d.line([(cx + 30, 0), (cx - 30, H)], fill=RIFT + (200,), width=5)
    return img


def main():
    icon_dir = os.path.join(ROOT, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    make_icon().save(os.path.join(icon_dir, "AppIcon-1024.png"))
    write_json(os.path.join(icon_dir, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })
    logo_dir = os.path.join(ROOT, "LaunchLogo.imageset")
    os.makedirs(logo_dir, exist_ok=True)
    logo = make_launch_logo()
    logo.save(os.path.join(logo_dir, "LaunchLogo@3x.png"))
    logo.resize((600, 160), Image.LANCZOS).save(os.path.join(logo_dir, "LaunchLogo@2x.png"))
    write_json(os.path.join(logo_dir, "Contents.json"), {
        "images": [
            {"idiom": "universal", "scale": "1x"},
            {"filename": "LaunchLogo@2x.png", "idiom": "universal", "scale": "2x"},
            {"filename": "LaunchLogo@3x.png", "idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    })
    for name, rgb in [("LaunchBackground", INK), ("AccentColor", RIFT)]:
        write_json(os.path.join(ROOT, name + ".colorset", "Contents.json"), {
            "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
                "red": "%.3f" % (rgb[0] / 255), "green": "%.3f" % (rgb[1] / 255), "blue": "%.3f" % (rgb[2] / 255), "alpha": "1.000"}}}],
            "info": {"author": "xcode", "version": 1},
        })
    write_json(os.path.join(ROOT, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    print("assets written to", os.path.abspath(ROOT))


if __name__ == "__main__":
    main()

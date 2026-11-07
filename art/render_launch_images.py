#!/usr/bin/env python3
# rebuilds the launch images: a red gradient with the app icon in the middle, in every size the plist lists
import glob
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "app" / "icons"

# the icon art lives in render_app_icon.py, which renders on import; run it without its final call
ns = {"__file__": str(ROOT / "art" / "render_app_icon.py")}
source = (ROOT / "art" / "render_app_icon.py").read_text()
assert source.rstrip().endswith("main()")
exec(compile(source.rstrip()[:-len("main()")], "render_app_icon.py", "exec"), ns)
rgb, mask = ns["plate"](ns["SIZE"])
ICON = ns["compose"](rgb, mask, False)

TOP = np.array([200, 22, 32], np.float32)
BOTTOM = np.array([62, 8, 14], np.float32)


def background(w, h):
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    img = TOP[None, None, :] * (1 - y) + BOTTOM[None, None, :] * y
    img = np.broadcast_to(img, (h, w, 3)).copy()
    # a soft lift behind the icon keeps the middle from reading flat
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - w / 2) / w) ** 2 + ((yy - h * 0.46) / h) ** 2)
    img += (np.exp(-(d / 0.28) ** 2) * 26)[:, :, None] * np.array([1.0, 0.25, 0.28], np.float32)
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def render(path):
    w, h = Image.open(path).size
    base = background(w, h)
    side = int(round(min(w, h) * 0.30))
    icon = ICON.resize((side, side), Image.LANCZOS)
    x, y = (w - side) // 2, int(h * 0.46) - side // 2
    shadow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + side // 24, x + side, y + side + side // 24),
                                             radius=int(side * 0.215), fill=120)
    shadow = shadow.filter(ImageFilter.GaussianBlur(side * 0.05))
    base.alpha_composite(Image.merge("RGBA", (Image.new("L", (w, h), 0),) * 3 + (shadow,)))
    base.alpha_composite(icon, (x, y))
    base.convert("RGB").save(path, optimize=True)


names = sorted(glob.glob(str(ICONS / "Default*.png")))
if not names:
    sys.exit("no launch images in %s" % ICONS)
for name in names:
    render(name)
print("rendered %d launch images" % len(names))

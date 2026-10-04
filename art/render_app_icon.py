#!/usr/bin/env python3
# rebuilds the home screen icons: a plate in the stock ios icon outline with the vinyl from the master art
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import distance_transform_edt

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "app" / "icons"
MASTER_SRC = ROOT / "art" / "vinyl-source.png"
SIZE = 1024
SS = 2
# stock icon corner radius as a share of the side
CORNER = 0.215
# vinyl disc in the 1070px source art
DISC_CX, DISC_CY, DISC_R = 531, 511, 424
DISC_SCALE = 0.80

OUTPUTS = {
    "RewindIcon.png": 57, "RewindIcon@2x.png": 114,
    "RewindIcon-60@2x.png": 120, "RewindIcon-60@3x.png": 180,
    "RewindIcon-72.png": 72, "RewindIcon-72@2x.png": 144,
    "RewindIcon-76.png": 76, "RewindIcon-76@2x.png": 152,
    "RewindIcon-83.5@2x.png": 167,
}
# ipad and ios 7+ paint their own mask over the icon and show black behind transparent or black corners, so
# these ship square and opaque with the plate colour running into the corners; the iphone 57/114 pair keeps its own outline
SQUARE = {"RewindIcon-60@2x.png", "RewindIcon-60@3x.png", "RewindIcon-72.png", "RewindIcon-72@2x.png",
          "RewindIcon-76.png", "RewindIcon-76@2x.png", "RewindIcon-83.5@2x.png"}


def shape_mask(n):
    m = Image.new("L", (n * SS, n * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, n * SS - 1, n * SS - 1), radius=CORNER * n * SS, fill=255)
    return m.resize((n, n), Image.LANCZOS)


def plate(n):
    mask = np.array(shape_mask(n)).astype(np.float32) / 255.0
    # the pad makes the image border count as the outline, edt only sees zeros inside the array
    dist = distance_transform_edt(np.pad(mask > 0.5, 1))[1:-1, 1:-1].astype(np.float32)
    yy = np.linspace(0, 1, n, dtype=np.float32)[:, None]
    top = np.array([112, 24, 30], np.float32)
    bot = np.array([46, 8, 12], np.float32)
    rgb = top[None, None, :] * (1 - yy[:, :, None]) + bot[None, None, :] * yy[:, :, None]
    rgb = np.broadcast_to(rgb, (n, n, 3)).copy()
    # rim: bright red line a few px inside the edge, dark falloff behind it
    rim = np.exp(-((dist - 0.008 * n) / (0.006 * n)) ** 2)
    rgb += rim[:, :, None] * np.array([150, 40, 50], np.float32)
    rgb *= (1 - 0.25 * np.exp(-(dist - 0.02 * n).clip(0) / (0.03 * n)))[:, :, None]
    # gloss lens across the upper third, clipped inside the rim
    gloss = Image.new("L", (n, n), 0)
    ImageDraw.Draw(gloss).rounded_rectangle((0.05 * n, 0.04 * n, 0.95 * n, 0.27 * n), radius=0.11 * n, fill=255)
    g = np.array(gloss.filter(ImageFilter.GaussianBlur(n * 0.004))).astype(np.float32) / 255.0
    g *= (dist > 0.03 * n)
    fade = np.clip(1 - (yy - 0.04) / 0.23, 0, 1) * 0.30 + 0.06
    rgb = rgb * (1 - g[:, :, None] * fade[:, :, None]) + 255 * g[:, :, None] * fade[:, :, None]
    return rgb, mask


def vinyl(n):
    src = Image.open(MASTER_SRC).convert("RGBA")
    box = (DISC_CX - DISC_R, DISC_CY - DISC_R, DISC_CX + DISC_R, DISC_CY + DISC_R)
    disc = src.crop(box)
    d = DISC_R * 2
    m = Image.new("L", (d * 4, d * 4), 0)
    ImageDraw.Draw(m).ellipse((0, 0, d * 4 - 1, d * 4 - 1), fill=255)
    disc.putalpha(m.resize((d, d), Image.LANCZOS))
    side = int(round(n * DISC_SCALE))
    return disc.resize((side, side), Image.LANCZOS)


def compose(rgb, mask, square):
    if square:
        # corners take the nearest plate pixel so the system mask never meets black
        _, idx = distance_transform_edt(mask <= 0.5, return_indices=True)
        rgb = rgb[idx[0], idx[1]]
    base = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    # soft shadow under the disc so it sits on the plate
    disc = vinyl(SIZE)
    off = (SIZE - disc.width) // 2
    sh = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(sh).ellipse((off, off + SIZE // 60, off + disc.width, off + disc.width + SIZE // 60), fill=170)
    sh = sh.filter(ImageFilter.GaussianBlur(SIZE * 0.012))
    base.alpha_composite(Image.merge("RGBA", (Image.new("L", (SIZE, SIZE), 0),) * 3 + (sh,)))
    base.alpha_composite(disc, (off, off))
    if not square:
        base.putalpha(Image.fromarray((mask * 255).astype(np.uint8), "L"))
    return base


def main():
    if not MASTER_SRC.exists():
        sys.exit("missing %s" % MASTER_SRC)
    rgb, mask = plate(SIZE)
    rounded = compose(rgb, mask, False)
    square = compose(rgb, mask, True)
    rounded.save(ICONS / "rewind-icon.png")
    for name, px in OUTPUTS.items():
        base = square if name in SQUARE else rounded
        img = base.resize((px, px), Image.LANCZOS)
        if name in SQUARE:
            img = img.convert("RGB")
        img.save(ICONS / name, optimize=True)
    print("rendered %d icons" % (len(OUTPUTS) + 1))


main()

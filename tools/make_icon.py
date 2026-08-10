#!/usr/bin/env python3
"""
Draw the Stark mark and build the macOS app icon from it.

The mark is a lightning bolt struck through a ring, drawn as outlines rather
than solids: the bolt knocks a gap out of the ring where the two cross, which
is what stops it reading as a generic bolt-in-a-badge. Everything is graphite
on white — the product's whole palette is monochrome now, so the icon leads.

Drawn rather than traced from an image so it can be regenerated at any size
without a raster to lose, and so the knockout stays exact.

Writes assets/icon.png (1024) and app/Stark.icns.
"""

import os
import subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

S = 1024
GRAPHITE = (68, 68, 72, 255)
WHITE = (255, 255, 255, 255)

RING_R = 330
STROKE = 34
GAP = 22          # white halo that breaks the ring where the bolt crosses it

# Traced from assets/logo.svg's bolt at 512, doubled. Kept as the outline of the
# shape, not a fill: the bolt's interior is the background colour.
BOLT = [(634, 198), (322, 584), (460, 584), (408, 826), (702, 440), (564, 440)]


def draw_mark(size, bg=WHITE, fg=GRAPHITE, ring=True):
    """The mark on a square canvas, at `size` px."""
    img = Image.new("RGBA", (S, S), bg)
    d = ImageDraw.Draw(img)
    c = S // 2

    if ring:
        d.ellipse([c - RING_R, c - RING_R, c + RING_R, c + RING_R],
                  outline=fg, width=STROKE)

    closed = BOLT + [BOLT[0]]
    # The halo first, in the background colour, so the ring appears to pass
    # behind the bolt with a clean break on both sides.
    d.line(closed, fill=bg, width=STROKE + GAP * 2, joint="curve")
    d.line(closed, fill=fg, width=STROKE, joint="curve")
    # `joint="curve"` rounds the corners but leaves the two free ends square.
    for p in (BOLT[0], BOLT[3]):
        r = STROKE // 2
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fg)

    return img.resize((size, size), Image.LANCZOS)


def rounded_square(size, radius_ratio=0.2255):
    """macOS app icons are a squircle, not a full-bleed square."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=WHITE)
    return img


def app_icon(size):
    # The mark sits inside the tile with Apple's usual breathing room rather
    # than running to the edges.
    tile = rounded_square(size)
    inner = int(size * 0.72)
    mark = draw_mark(inner)
    flat = Image.new("RGBA", (inner, inner), WHITE)
    flat.alpha_composite(mark)
    off = (size - inner) // 2
    tile.alpha_composite(flat, (off, off))
    # Re-apply the squircle so the pasted square does not square off the corners.
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(tile, (0, 0), rounded_square(size))
    return out


def main():
    os.makedirs(os.path.join(ROOT, "assets"), exist_ok=True)
    draw_mark(1024).save(os.path.join(ROOT, "assets", "icon.png"))
    print("  assets/icon.png")

    iconset = os.path.join(ROOT, "app", "Stark.iconset")
    os.makedirs(iconset, exist_ok=True)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        app_icon(px).save(os.path.join(iconset, f"icon_{px}x{px}.png"))
        if px <= 512:
            app_icon(px * 2).save(os.path.join(iconset, f"icon_{px}x{px}@2x.png"))

    icns = os.path.join(ROOT, "app", "Stark.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)
    print(f"  app/Stark.icns — {os.path.getsize(icns) / 1024:.0f} KB")


if __name__ == "__main__":
    print("drawing the mark…")
    main()

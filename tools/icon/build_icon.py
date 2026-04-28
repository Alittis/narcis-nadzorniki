"""Generates the app icon set for Terenska beležnica.

Produces:
  assets/icon/app_icon.png            -- 1024x1024, full icon (green bg + flower)
  assets/icon/app_icon_foreground.png -- 1024x1024, adaptive-icon foreground
                                          (flower only, transparent bg, sized for
                                          Android's ~66% safe zone)

Re-run after editing this file:
  python3 tools/icon/build_icon.py
  flutter pub run flutter_launcher_icons
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "assets" / "icon"

BG_GREEN = (46, 125, 50, 255)      # Material Green 800, theme-adjacent
BG_GREEN_DARK = (27, 94, 32, 255)  # Green 900, used for the soft vignette
PETAL_WHITE = (255, 255, 255, 255)
PETAL_SHADOW = (0, 0, 0, 38)       # subtle drop shadow under petals
CUP_YELLOW = (255, 193, 7, 255)    # Amber 500, the narcissus' inner cup
CUP_RIM_RED = (211, 47, 47, 255)   # Red 700, Narcissus poeticus' red rim
CUP_INNER = (255, 224, 130, 255)   # Amber 100, gradient highlight

PETAL_COUNT = 6
PETAL_LEN = 0.36   # as fraction of canvas (tip-to-tip = 0.72 of canvas)
PETAL_WID = 0.18
CUP_RADIUS = 0.115
CUP_RIM = 0.13
ICON_RADIUS = 0.225  # rounded-square corner radius as fraction of canvas


def rounded_square_mask(size: int, radius_frac: float) -> Image.Image:
    """Solid white rounded square, used as a mask for the green background."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_frac)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=r, fill=255)
    return mask


def radial_vignette(size: int, inner_color, outer_color) -> Image.Image:
    """Soft radial gradient from `inner_color` at center to `outer_color` at edge."""
    img = Image.new("RGBA", (size, size), inner_color)
    pixels = img.load()
    cx = cy = size / 2
    max_r = math.hypot(cx, cy)
    for y in range(size):
        for x in range(size):
            r = math.hypot(x - cx, y - cy) / max_r
            t = min(1.0, r ** 1.4)
            pixels[x, y] = tuple(
                int(inner_color[i] * (1 - t) + outer_color[i] * t) for i in range(4)
            )
    return img


def draw_petal(canvas_size: int, angle_deg: float) -> Image.Image:
    """One petal as a transparent RGBA tile the size of the canvas."""
    layer = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = canvas_size / 2
    cy = canvas_size / 2
    pl = canvas_size * PETAL_LEN
    pw = canvas_size * PETAL_WID
    # Petal is an ellipse centered above the icon center, then rotated.
    # Bounding box for the ellipse:
    bbox = (
        cx - pw / 2,
        cy - pl,             # tip pushed upward
        cx + pw / 2,
        cy + pw * 0.25,      # base slightly past center -> overlaps the cup
    )
    d.ellipse(bbox, fill=PETAL_WHITE)

    return layer.rotate(-angle_deg, resample=Image.BICUBIC, center=(cx, cy))


def draw_flower(size: int) -> Image.Image:
    """Flower-only RGBA layer (transparent background)."""
    flower = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Soft drop shadow underneath the petals -- one dark blob, blurred.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    cx = cy = size / 2
    sr = size * 0.36
    sd.ellipse((cx - sr, cy - sr * 0.95, cx + sr, cy + sr * 1.05), fill=PETAL_SHADOW)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.025))
    flower = Image.alpha_composite(flower, shadow)

    # Six petals.
    for i in range(PETAL_COUNT):
        angle = i * (360 / PETAL_COUNT)
        flower = Image.alpha_composite(flower, draw_petal(size, angle))

    # Inner cup: red rim ring -> yellow disc -> small highlight.
    d = ImageDraw.Draw(flower)
    rim_r = size * CUP_RIM
    cup_r = size * CUP_RADIUS
    hi_r = size * 0.04
    d.ellipse((cx - rim_r, cy - rim_r, cx + rim_r, cy + rim_r), fill=CUP_RIM_RED)
    d.ellipse((cx - cup_r, cy - cup_r, cx + cup_r, cy + cup_r), fill=CUP_YELLOW)
    d.ellipse(
        (cx - hi_r - size * 0.02, cy - hi_r - size * 0.025,
         cx + hi_r - size * 0.02, cy + hi_r - size * 0.025),
        fill=CUP_INNER,
    )

    return flower


def build_full_icon() -> Image.Image:
    """Green rounded-square background + flower, full-canvas size."""
    bg = radial_vignette(SIZE, BG_GREEN, BG_GREEN_DARK)
    mask = rounded_square_mask(SIZE, ICON_RADIUS)
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), mask)

    flower = draw_flower(SIZE)
    icon = Image.alpha_composite(icon, flower)
    return icon


def build_adaptive_foreground() -> Image.Image:
    """Flower on transparent canvas, scaled to ~66% so Android's launcher mask
    doesn't clip it. The launcher composites this over the configured
    background colour."""
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    inner = SIZE * 0.66
    flower = draw_flower(int(inner))
    offset = int((SIZE - inner) / 2)
    fg.paste(flower, (offset, offset), flower)
    return fg


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    full = build_full_icon()
    full.save(OUT_DIR / "app_icon.png", "PNG")
    fg = build_adaptive_foreground()
    fg.save(OUT_DIR / "app_icon_foreground.png", "PNG")
    print(f"wrote {OUT_DIR / 'app_icon.png'}")
    print(f"wrote {OUT_DIR / 'app_icon_foreground.png'}")


if __name__ == "__main__":
    main()

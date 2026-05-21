"""Generates the Play Store feature graphic for Terenska beležnica.

Produces:
  /tmp/play_feature_graphic_1024x500.png  -- 1024x500, 24-bit RGB (no alpha)

Spec per project/PLAY_CLOSED_TEST.md §6:
  - 1024x500 PNG/JPG, 24-bit (no alpha), < 15 MB
  - Green background matching the launcher-icon palette
  - White narcissus icon + "Terenska beležnica" wordmark in white

Layout: flower on the left, two-line wordmark stacked on the right. Title font
auto-sizes down until the longer line fits inside Play's 80% center-aligned
safe zone (Play may crop the outer 10% on small surfaces).

Re-run after editing this file:
  python3 tools/icon/build_feature_graphic.py

Then upload at:
  Play Console -> Grow -> Store presence -> Main store listing -> Graphics
  -> Feature graphic
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from build_icon import BG_GREEN, BG_GREEN_DARK, draw_flower

W, H = 1024, 500
OUT = Path("/tmp") / "play_feature_graphic_1024x500.png"

# Layout (px on the 1024x500 canvas).
FLOWER_SIZE = 320
FLOWER_CX = 220
FLOWER_CY = H // 2

TEXT_LEFT = 420                 # text block starts here (40 px gap past flower)
SAFE_RIGHT = int(W * 0.92)      # stay inside Play's 80% center-aligned safe zone
TEXT_MAX_WIDTH = SAFE_RIGHT - TEXT_LEFT

TITLE_LINES = ("Terenska", "beležnica")
LINE_GAP_FRAC = 0.05            # gap between the two lines, as fraction of font size

# Font candidates (macOS first, generic Linux fallback last).
FONT_CANDIDATES = (
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Black.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)


def load_font(px: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, px)
            except OSError:
                continue
    # Last-ditch: PIL's bitmap default. Looks bad but keeps the builder runnable.
    return ImageFont.load_default()


def horizontal_vignette(w: int, h: int, inner_color, outer_color) -> Image.Image:
    """Soft radial gradient anchored on the flower's centre.

    Inner colour holds across the flower area; falls off toward the canvas
    corners so the right edge of the banner is a touch darker than the left.
    """
    img = Image.new("RGB", (w, h), inner_color[:3])
    pixels = img.load()
    cx, cy = FLOWER_CX, h / 2
    max_r = math.hypot(w - cx, h)  # distance from anchor to far corner
    for y in range(h):
        for x in range(w):
            r = math.hypot(x - cx, y - cy) / max_r
            t = min(1.0, r ** 1.3)
            pixels[x, y] = (
                int(inner_color[0] * (1 - t) + outer_color[0] * t),
                int(inner_color[1] * (1 - t) + outer_color[1] * t),
                int(inner_color[2] * (1 - t) + outer_color[2] * t),
            )
    return img


def fit_title_font(draw: ImageDraw.ImageDraw) -> ImageFont.FreeTypeFont:
    """Largest font size where the longer of the two title lines fits."""
    for px in range(120, 40, -2):
        font = load_font(px)
        widths = [draw.textbbox((0, 0), line, font=font)[2] for line in TITLE_LINES]
        if max(widths) <= TEXT_MAX_WIDTH:
            return font
    return load_font(40)  # extreme fallback


def draw_title(canvas: Image.Image) -> None:
    """Two-line title in white with a soft drop shadow for legibility."""
    measure = ImageDraw.Draw(canvas)
    font = fit_title_font(measure)
    px = font.size

    # Vertical layout: stack the two lines centred on the canvas midline.
    # Use the font's ascent+descent (consistent per-glyph) instead of a per-line
    # bbox so the gap between lines isn't pulled around by tall/short glyphs.
    ascent, descent = font.getmetrics()
    line_h = ascent + descent
    gap = int(px * LINE_GAP_FRAC)
    block_h = 2 * line_h + gap
    y0 = (H - block_h) // 2

    # Shadow pass: render text into an RGBA layer, blur it, composite over canvas.
    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow_layer)
    for i, line in enumerate(TITLE_LINES):
        y = y0 + i * (line_h + gap)
        sd.text((TEXT_LEFT + 4, y + 4), line, font=font, fill=(0, 0, 0, 130))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=5))
    canvas.paste(shadow_layer, (0, 0), shadow_layer)

    # White text on top.
    draw = ImageDraw.Draw(canvas)
    for i, line in enumerate(TITLE_LINES):
        y = y0 + i * (line_h + gap)
        draw.text((TEXT_LEFT, y), line, font=font, fill=(255, 255, 255))


def main() -> None:
    canvas = horizontal_vignette(W, H, BG_GREEN, BG_GREEN_DARK)

    flower = draw_flower(FLOWER_SIZE)
    fx = FLOWER_CX - FLOWER_SIZE // 2
    fy = FLOWER_CY - FLOWER_SIZE // 2
    canvas.paste(flower, (fx, fy), flower)  # RGBA flower onto RGB canvas via its alpha

    draw_title(canvas)

    canvas.save(OUT, "PNG", optimize=True)
    out_kb = OUT.stat().st_size // 1024
    print(f"wrote {OUT} ({W}x{H}, {out_kb} KB, RGB)")


if __name__ == "__main__":
    main()

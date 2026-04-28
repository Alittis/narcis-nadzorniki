"""Downsamples the full-resolution login background photo into a lean asset.

Reads:  tools/icon/sources/login_bg.jpg  (committed; full original from camera)
Writes: assets/images/login_bg.jpg       (committed; bundled into the APK/IPA)

Re-run after replacing the source:
    python3 tools/icon/build_login_bg.py
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "icon" / "sources" / "login_bg.jpg"
OUT = ROOT / "assets" / "images" / "login_bg.jpg"

# Target longest-edge in pixels. Login bg is BoxFit.cover behind a darkening
# gradient and translucent form fields, so retina-perfect sharpness is wasted;
# 1800 px is plenty for a 3x device pixel ratio on the tallest phones we'd
# realistically run on, and lands around 400-600 KB at quality 78.
MAX_EDGE = 1800
JPEG_QUALITY = 78


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"missing source: {SRC}")
    OUT.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(SRC) as im:
        im = im.convert("RGB")  # drop any alpha and EXIF orientation quirks
        w, h = im.size
        scale = min(1.0, MAX_EDGE / max(w, h))
        if scale < 1.0:
            im = im.resize(
                (round(w * scale), round(h * scale)), resample=Image.LANCZOS
            )
        im.save(OUT, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)

    src_kb = SRC.stat().st_size // 1024
    out_kb = OUT.stat().st_size // 1024
    print(f"src: {SRC} ({w}x{h}, {src_kb} KB)")
    print(f"out: {OUT} ({im.size[0]}x{im.size[1]}, {out_kb} KB)")


if __name__ == "__main__":
    main()

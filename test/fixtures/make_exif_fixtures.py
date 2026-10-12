# TB-50 fixtures: camera-like JPEGs carrying the metadata stripJpegMetadata must remove.
# Regenerate (Pillow 11+): python3 -I test/fixtures/make_exif_fixtures.py test/fixtures
# Not byte-identical between runs: the sRGB ICC profile stamps its creation time. The tests
# depend only on the metadata, so a regenerated set passes the same way.

import io, sys
from PIL import Image, ImageCms
out = sys.argv[1]
icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
xmp = (b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
       b'<rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="45,47.4N" '
       b'exif:GPSLongitude="14,21.6E"/></rdf:RDF></x:xmpmeta>')

def build(name, endian, orientation):
    img = Image.new("RGB", (64, 48))
    for x in range(64):
        for y in range(48):
            img.putpixel((x, y), (x * 4, y * 5, 128 if x < 32 else 30))
    exif = Image.Exif()
    exif.endian = endian
    exif[0x010F] = "samsung"           # Make
    exif[0x0110] = "SM-A566B"          # Model
    if orientation is not None:
        exif[0x0112] = orientation     # Orientation
    exif[0x0132] = "2026:10:12 09:41:00"
    sub = exif.get_ifd(0x8769)
    sub[0x9003] = "2026:10:12 09:41:00"  # DateTimeOriginal
    sub[0xA431] = "R58N12345XY"          # BodySerialNumber
    gps = exif.get_ifd(0x8825)
    gps[1] = "N"; gps[2] = (45.0, 47.0, 24.0)
    gps[3] = "E"; gps[4] = (14.0, 21.0, 36.0)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85, exif=exif.tobytes(), icc_profile=icc, xmp=xmp,
             comment=b"Galaxy A56 / Notranjski park")
    data = buf.getvalue() + b"SEFH\x00\x00\x00\x00trailer-Image_UTC_Data1728726060SEFT"
    open(f"{out}/{name}", "wb").write(data)
    print(name, len(data), "bytes")

build("exif_gps_le.jpg", "<", 6)
build("exif_gps_be.jpg", ">", 8)
build("exif_gps_upright.jpg", "<", None)

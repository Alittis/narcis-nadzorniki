import 'dart:typed_data';

/// TB-50: removes the metadata a JPEG carries about where, when and on what
/// it was taken, keeping only how it must be rotated.
///
/// `image_picker` re-encodes every photo (`imageQuality: 85`), and on Android
/// copies the original's EXIF onto the result, GPS and phone make/model
/// included (`ImageResizer.copyExif`). So the file the app stores and uploads
/// says where it was taken — for a gallery pick, possibly far from the record.
///
/// Dropped: every APP1 (Exif and XMP), APP13 (IPTC) and COM segment, and
/// anything after EOI (vendor trailers). Kept: everything else — JFIF, the ICC
/// profile, Adobe's colour transform and the image data — byte for byte, with
/// no re-encode. When the original's Exif says the image is rotated, a minimal
/// Exif segment carrying only that Orientation goes back where the original
/// Exif was, since viewers rotate by it.
///
/// Anything that is not a JPEG, or that does not parse as one, comes back
/// unchanged: a photo is never refused for its metadata.
Uint8List stripJpegMetadata(Uint8List input) {
  try {
    return _strip(input) ?? input;
  } catch (_) {
    return input;
  }
}

Uint8List? _strip(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  int? orientation;
  var exifSlotFilled = false;
  var i = 2;
  var inScan = false;

  while (i < b.length) {
    if (inScan) {
      // Entropy-coded data: a 0xFF is either stuffed (FF 00) or a restart
      // marker (FF D0–D7); any other FF xx ends the scan.
      final start = i;
      while (i + 1 < b.length &&
          !(b[i] == 0xFF &&
              b[i + 1] != 0x00 &&
              (b[i + 1] < 0xD0 || b[i + 1] > 0xD7))) {
        i++;
      }
      if (i + 1 >= b.length) return null; // no EOI
      out.add(Uint8List.sublistView(b, start, i));
      inScan = false;
      continue;
    }
    if (b[i] != 0xFF) return null;
    // Fill bytes may pad a marker.
    while (i < b.length && b[i] == 0xFF) {
      i++;
    }
    if (i >= b.length) return null;
    final marker = b[i++];
    if (marker == 0xD9) {
      out.add(const [0xFF, 0xD9]);
      return out.takeBytes(); // drop any trailer
    }
    if (i + 2 > b.length) return null;
    final len = (b[i] << 8) | b[i + 1];
    if (len < 2 || i + len > b.length) return null;
    final payload = Uint8List.sublistView(b, i + 2, i + len);
    final segmentEnd = i + len;

    if (marker == 0xE1) {
      if (_isExif(payload)) {
        orientation ??= _orientation(payload);
        // The minimal segment takes the first Exif's place.
        if (!exifSlotFilled) {
          exifSlotFilled = true;
          final o = orientation;
          if (o != null && o >= 2 && o <= 8) out.add(_minimalExif(o));
        }
      }
    } else if (marker != 0xED && marker != 0xFE) {
      out
        ..add([0xFF, marker])
        ..add(Uint8List.sublistView(b, i, segmentEnd));
      if (marker == 0xDA) inScan = true;
    }
    i = segmentEnd;
  }
  return null; // ran out before EOI
}

bool _isExif(Uint8List p) =>
    p.length >= 6 &&
    p[0] == 0x45 && // E
    p[1] == 0x78 && // x
    p[2] == 0x69 && // i
    p[3] == 0x66 && // f
    p[4] == 0 &&
    p[5] == 0;

/// IFD0's Orientation (tag 0x0112, SHORT), or null.
int? _orientation(Uint8List p) {
  final tiff = ByteData.sublistView(p, 6);
  if (tiff.lengthInBytes < 8) return null;
  final Endian e;
  if (tiff.getUint16(0) == 0x4949) {
    e = Endian.little;
  } else if (tiff.getUint16(0) == 0x4D4D) {
    e = Endian.big;
  } else {
    return null;
  }
  if (tiff.getUint16(2, e) != 42) return null;
  final ifd0 = tiff.getUint32(4, e);
  if (ifd0 + 2 > tiff.lengthInBytes) return null;
  final count = tiff.getUint16(ifd0, e);
  for (var n = 0; n < count; n++) {
    final entry = ifd0 + 2 + n * 12;
    if (entry + 12 > tiff.lengthInBytes) return null;
    if (tiff.getUint16(entry, e) == 0x0112 &&
        tiff.getUint16(entry + 2, e) == 3) {
      return tiff.getUint16(entry + 8, e);
    }
  }
  return null;
}

/// APP1 Exif holding IFD0 with the single entry Orientation = [o].
Uint8List _minimalExif(int o) => Uint8List.fromList([
  0xFF, 0xE1, 0x00, 0x22, // APP1, length 34
  0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
  0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // big-endian TIFF, IFD0 at 8
  0x00, 0x01, // one entry
  0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // Orientation, SHORT, 1
  0x00, o, 0x00, 0x00, // value
  0x00, 0x00, 0x00, 0x00, // no next IFD
]);

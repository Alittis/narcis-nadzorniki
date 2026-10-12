// TB-50: a photo leaves the phone without the metadata saying where, when and
// on what it was taken.
//
// The fixtures are camera-like JPEGs made with Pillow
// (test/fixtures/make_exif_fixtures.py): Make "samsung", Model
// "SM-A566B", a body serial number, DateTimeOriginal, a GPS IFD (45°47'24"N
// 14°21'36"E), an XMP packet repeating the GPS, a comment, an sRGB ICC profile
// and a Samsung-style trailer after EOI. `_le` is little-endian Exif with
// Orientation 6, `_be` big-endian with Orientation 8 (Android's ExifInterface
// writes big-endian), `_upright` has no Orientation.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/services/jpeg_metadata.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

int _indexOf(Uint8List hay, List<int> needle, [int from = 0]) {
  outer:
  for (var i = from; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _has(Uint8List hay, String ascii) => _indexOf(hay, ascii.codeUnits) != -1;

/// The minimal Exif segment the stripper writes, for Orientation [o].
List<int> _orientationOnlyExif(int o) => [
  0xFF, 0xE1, 0x00, 0x22, //
  ...ascii.encode('Exif'), 0, 0,
  0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
  0x00, 0x01,
  0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,
  0x00, o, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
];

void main() {
  group('stripJpegMetadata', () {
    for (final (name, orientation) in [
      ('exif_gps_le.jpg', 6),
      ('exif_gps_be.jpg', 8),
    ]) {
      test(
        '$name: drops location, device and time; keeps Orientation $orientation',
        () {
          final input = _fixture(name);
          // The fixture really carries what the test claims to remove.
          for (final s in [
            'samsung',
            'SM-A566B',
            'R58N12345XY',
            'xmpmeta',
            'Galaxy A56',
            'SEFT',
            '2026:10:12',
          ]) {
            expect(_has(input, s), isTrue, reason: 'fixture lacks "$s"');
          }

          final out = stripJpegMetadata(input);

          for (final s in [
            'samsung',
            'SM-A566B',
            'R58N12345XY',
            'xmpmeta',
            'Galaxy A56',
            'SEFT',
            '2026:10:12',
          ]) {
            expect(_has(out, s), isFalse, reason: '"$s" survived');
          }
          expect(
            _indexOf(out, _orientationOnlyExif(orientation)),
            isNot(-1),
            reason:
                'Orientation must survive, or portrait photos turn sideways',
          );
          expect(
            _has(out, 'ICC_PROFILE'),
            isTrue,
            reason: 'colour profile kept',
          );
          expect(out.sublist(0, 2), [0xFF, 0xD8]);
          expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
        },
      );
    }

    test('the image data is copied byte for byte, not re-encoded', () {
      final input = _fixture('exif_gps_le.jpg');
      final out = stripJpegMetadata(input);
      final inSos = _indexOf(input, [0xFF, 0xDA]);
      final outSos = _indexOf(out, [0xFF, 0xDA]);
      expect(inSos, isNot(-1));
      final scan = out.sublist(outSos);
      expect(input.sublist(inSos, inSos + scan.length), scan);
    });

    test('an upright photo keeps no Exif at all', () {
      final out = stripJpegMetadata(_fixture('exif_gps_upright.jpg'));
      expect(_has(out, 'Exif'), isFalse);
      expect(_has(out, 'samsung'), isFalse);
    });

    test('stripping twice changes nothing more', () {
      final once = stripJpegMetadata(_fixture('exif_gps_be.jpg'));
      expect(stripJpegMetadata(once), once);
    });

    test('a PNG passes through untouched', () {
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        1,
        2,
        3,
        4,
      ]);
      expect(stripJpegMetadata(png), same(png));
    });

    test('a truncated JPEG comes back as it was rather than half-written', () {
      final input = _fixture('exif_gps_le.jpg');
      final cut = Uint8List.sublistView(input, 0, input.length ~/ 2);
      expect(stripJpegMetadata(cut), same(cut));
    });
  });

  group('PhotoStorage.savePicked', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tb50_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'stores the stripped photo, which is the file that gets uploaded',
      () async {
        final picked = File('${tmp.path}/picked.jpg')
          ..writeAsBytesSync(_fixture('exif_gps_le.jpg'));
        final storage = PhotoStorage(
          rootResolver: () => Directory('${tmp.path}/photos'),
        );

        final path = await storage.savePicked(
          motnjaId: 'm1',
          photoId: 'f1',
          sourcePath: picked.path,
          mimeType: 'image/jpeg',
        );

        final stored = File(path).readAsBytesSync();
        expect(_has(stored, 'samsung'), isFalse);
        expect(_has(stored, 'xmpmeta'), isFalse);
        expect(_indexOf(stored, _orientationOnlyExif(6)), isNot(-1));
      },
    );
  });
}

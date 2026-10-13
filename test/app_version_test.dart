// TB-46: the build number the app sends as X-App-Build is written in
// lib/app_version.dart, because Dart cannot read it from the build without a
// plugin. This keeps it equal to pubspec.yaml's `version: x.y.z+N`, so a
// release bump cannot forget it — a stale number would let the server's
// minimum-build check block a current build, or pass an old one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/app_version.dart';

void main() {
  test('kAppBuild equals the +N of pubspec.yaml\'s version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*\S+\+(\d+)\s*$', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml has no version x.y.z+N');
    expect(kAppBuild, int.parse(m!.group(1)!),
        reason: 'bump lib/app_version.dart with pubspec.yaml');
  });
}

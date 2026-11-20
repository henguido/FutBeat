import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/platform_goldens.dart';

Future<Uint8List> _pixels({bool changeOnePixel = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFFF0000), ui.BlendMode.src);
  if (changeOnePixel) {
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xFF00FF00),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only reviewed keys use Linux baselines', () {
    for (final name in linuxGoldenNames) {
      final key = 'goldens/$name.png';
      expect(
        platformGoldenPath(key, platform: 'linux'),
        'goldens/linux/$name.png',
      );
      expect(platformGoldenPath(key, platform: 'windows'), key);
      expect(platformGoldenPath(key, platform: 'macos'), key);
    }
  });

  test('unknown goldens remain mandatory native comparisons', () {
    expect(
      platformGoldenPath('goldens/new-screen.png', platform: 'linux'),
      'goldens/new-screen.png',
    );
    expect(
      platformGoldenPath('other/timeline_v2_empty.png', platform: 'linux'),
      'other/timeline_v2_empty.png',
    );
  });

  test(
    'Linux baseline accepts identical pixels and rejects one changed pixel',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'futbeat-golden-strict-',
      );
      try {
        final golden = Uri.parse(
          platformGoldenPath(
            'goldens/timeline_v2_empty.png',
            platform: 'linux',
          ),
        );
        final file = File.fromUri(root.uri.resolveUri(golden));
        await file.parent.create(recursive: true);
        final reference = await _pixels();
        await file.writeAsBytes(reference);
        final comparator = LocalFileComparator(
          root.uri.resolve('strict_test.dart'),
        );
        expect(await comparator.compare(reference, golden), isTrue);
        await expectLater(
          comparator.compare(await _pixels(changeOnePixel: true), golden),
          throwsA(isA<FlutterError>()),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'missing Linux reference fails instead of falling back to Windows',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'futbeat-golden-missing-',
      );
      try {
        final comparator = LocalFileComparator(
          root.uri.resolve('missing_test.dart'),
        );
        final golden = Uri.parse(
          platformGoldenPath(
            'goldens/timeline_v2_empty.png',
            platform: 'linux',
          ),
        );
        await expectLater(
          comparator.compare(await _pixels(), golden),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              contains('non-existent'),
            ),
          ),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

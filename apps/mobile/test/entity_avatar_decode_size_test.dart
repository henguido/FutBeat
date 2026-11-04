import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/sports_image_cache.dart';
import 'package:futbeat/shared/widgets.dart';

Entity _person() => Entity({
  'id': 'fb_player_avatar_decode',
  'name': 'Persona verificada',
  'media': {
    'verificationStatus': 'VERIFIED',
    'url': 'https://media.example.test/local-512.png',
  },
});

Future<Uint8List> _local512Png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 512, 512),
    Paint()..color = const Color(0xff00a060),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 512);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<({int width, int height, int bytes})> _decoded(
  Uint8List png, {
  int? width,
}) async {
  final codec = await ui.instantiateImageCodec(png, targetWidth: width);
  try {
    final frame = await codec.getNextFrame();
    try {
      final rgba = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      return (
        width: frame.image.width,
        height: frame.image.height,
        bytes: rgba!.lengthInBytes,
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

void main() {
  late Directory directory;
  late SportsImageDiskCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('avatar-decode-test-');
    cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) => throw const SocketException('fixture offline'),
    );
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<SportsImage> show(
    WidgetTester tester, {
    required double size,
    required double dpr,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: EntityAvatar(_person(), size: size, cache: cache),
        ),
      ),
    );
    return tester.widget<SportsImage>(find.byType(SportsImage));
  }

  testWidgets('20dp avatar decodes local512 photo at its physical pixel size', (
    tester,
  ) async {
    final widget = await show(tester, size: 20, dpr: 3);
    final measured = await tester.runAsync(() async {
      final png = await _local512Png();
      return (
        original: await _decoded(png),
        hinted: await _decoded(png, width: widget.cacheWidth),
      );
    });
    // Local decoder payload measurement, not Android process RSS or latency.
    // ignore: avoid_print
    print(
      'AVATAR_DECODE original=${measured!.original} '
      'hinted=${measured.hinted} cacheWidth=${widget.cacheWidth}',
    );
    expect(widget.cacheWidth, 60);
    expect(measured.original.width, 512);
    expect(measured.original.height, 512);
    expect(measured.original.bytes, 1048576);
    expect(measured.hinted.width, 60);
    expect(measured.hinted.height, 60);
    expect(measured.hinted.bytes, 14400);
    expect(widget.canonicalId, 'fb_player_avatar_decode');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final sample in [
    (size: 20.0, dpr: 1.0, pixels: 20),
    (size: 42.0, dpr: 2.625, pixels: 111),
    (size: 84.0, dpr: 3.0, pixels: 252),
    (size: 400.0, dpr: 5.0, pixels: 1024),
  ]) {
    testWidgets(
      'avatar ${sample.size}dp at${sample.dpr}x has bounded decode hint',
      (tester) async {
        final widget = await show(tester, size: sample.size, dpr: sample.dpr);
        expect(widget.cacheWidth, sample.pixels);
        expect(widget.width, sample.size);
        expect(widget.height, sample.size);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/sports_image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'validation memo stays bounded and drops externally deleted files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-bound260-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final png = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      final cache = SportsImageDiskCache(
        directory: directory,
        maxEntries: 2,
        fetch: (_) async => png,
      );
      for (var i = 0; i < 3; i++) {
        await cache.resolve(
          canonicalId: 'fb_player_bound260_$i',
          url: 'https://fixture.invalid/$i.png',
        );
        expect(cache.validatedEntryCount, lessThanOrEqualTo(2));
      }
      for (final file in await directory.list().toList()) {
        await file.delete();
      }
      await cache.resolve(
        canonicalId: 'fb_player_bound260_new',
        url: 'https://fixture.invalid/new.png',
      );
      expect(cache.validatedEntryCount, 1);
      expect(await directory.list().length, 1);
      await directory.delete(recursive: true);
      await cache.evict();
      expect(cache.validatedEntryCount, 0);
      await directory.create();
    },
  );
  test(
    'changed corrupt file cannot reuse an earlier validation memo',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-changed260-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final png = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      var requests = 0;
      final cache = SportsImageDiskCache(
        directory: directory,
        fetch: (_) async {
          requests++;
          return png;
        },
      );
      final file = await cache.resolve(
        canonicalId: 'fb_player260',
        url: 'https://fixture.invalid/photo.png',
      );
      await file!.writeAsBytes([1, 2, 3], flush: true);
      final repaired = await cache.resolve(
        canonicalId: 'fb_player260',
        url: 'https://fixture.invalid/photo.png',
      );
      expect(await repaired!.readAsBytes(), png);
      expect(requests, 2);
      expect(cache.validationCount, 3);
    },
  );

  test(
    'legacy corrupt disk entry is removed offline without repeated fetches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-legacy260-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const id = 'fb_player260';
      const url = 'https://fixture.invalid/photo.png';
      final key = sha256.convert('$id\u0000$url'.codeUnits).toString();
      await File('${directory.path}/$key.img').writeAsBytes([1, 2, 3]);
      var requests = 0;
      final cache = SportsImageDiskCache(
        directory: directory,
        fetch: (_) async {
          requests++;
          throw const SocketException('offline');
        },
      );
      expect(await cache.resolve(canonicalId: id, url: url), isNull);
      expect(requests, 1);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('18 representative local photos validate once and reuse disk without HTTP', () async {
    final directory = await Directory.systemTemp.createTemp(
      'futbeat-18photos260-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff00a060), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(320, 320);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
    var requests = 0;
    final cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        return png;
      },
    );
    Future<void> load(SportsImageDiskCache target) async {
      for (var i = 0; i < 18; i++) {
        expect(
          await target.resolve(
            canonicalId: 'fb_player_photo260_$i',
            url: 'https://fixture.invalid/$i.png',
          ),
          isNotNull,
        );
      }
    }

    final timer = Stopwatch()..start();
    await load(cache);
    final initialMicros = timer.elapsedMicroseconds;
    timer.reset();
    await load(cache);
    final repeatMicros = timer.elapsedMicroseconds;
    expect(requests, 18);
    expect(cache.validationCount, 18);
    final offline = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        throw const SocketException('unexpected offline HTTP');
      },
    );
    timer.reset();
    await load(offline);
    final reopenedMicros = timer.elapsedMicroseconds;
    await load(offline);
    expect(offline.validationCount, 18);
    expect(requests, 18);
    // Controlled local benchmark, not A32 or provider latency.
    debugPrint(
      'MEDIA260 local18x320 first_us=$initialMicros repeat_us=$repeatMicros reopened_us=$reopenedMicros fetches=$requests validations=${cache.validationCount}/${offline.validationCount}',
    );
  });

  test('a failed image download cannot poison later online photo opens for the cache TTL', () async {
    final directory = await Directory.systemTemp.createTemp(
      'futbeat-corrupt260-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final png = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      ),
    );
    var requests = 0;
    final first = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    await first.resolve(
      canonicalId: 'fb_player260',
      url: 'https://fixture.invalid/photo.png',
    );
    final reopened = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        return png;
      },
    );
    final recovered = await reopened.resolve(
      canonicalId: 'fb_player260',
      url: 'https://fixture.invalid/photo.png',
    );
    expect(requests, 2);
    expect(await recovered!.readAsBytes(), png);
  });
}

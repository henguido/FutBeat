import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/sports_image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DateTime now;
  final png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==',
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('futbeat-media-test-');
    now = DateTime.now();
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'download survives a new cache instance and an offline restart',
    () async {
      var requests = 0;
      final online = SportsImageDiskCache(
        directory: directory,
        clock: () => now,
        fetch: (_) async {
          requests++;
          return png;
        },
      );
      final first = await online.resolve(
        canonicalId: 'fb_player_tarkowski',
        url: 'https://media.example.test/tarkowski.png',
      );
      expect(first, isNotNull);
      expect(await first!.readAsBytes(), png);
      final offline = SportsImageDiskCache(
        directory: directory,
        clock: () => now,
        fetch: (_) => throw const SocketException('offline'),
      );
      final restored = await offline.resolve(
        canonicalId: 'fb_player_tarkowski',
        url: 'https://media.example.test/tarkowski.png',
      );
      expect(restored?.path, first.path);
      expect(requests, 1);
    },
  );

  test('invalid URL, absent URL and untyped identity never fetch', () async {
    var requests = 0;
    final cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        return png;
      },
    );
    for (final url in [
      null,
      '',
      'http://media.example.test/a.png',
      'https://user:pass@media.example.test/a.png',
    ]) {
      expect(await cache.resolve(canonicalId: 'fb_player_a', url: url), isNull);
    }
    expect(
      await cache.resolve(
        canonicalId: 'Tarkowski',
        url: 'https://media.example.test/a.png',
      ),
      isNull,
    );
    expect(requests, 0);
  });

  test('canonical ID and URL both isolate cached images', () async {
    var requests = 0;
    final cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        return png;
      },
    );
    final a = await cache.resolve(
      canonicalId: 'fb_player_a',
      url: 'https://media.example.test/a.png',
    );
    final b = await cache.resolve(
      canonicalId: 'fb_player_b',
      url: 'https://media.example.test/a.png',
    );
    final changed = await cache.resolve(
      canonicalId: 'fb_player_a',
      url: 'https://media.example.test/new.png',
    );
    expect({a?.path, b?.path, changed?.path}.length, 3);
    expect(requests, 3);
  });

  test('expiry removes old media and does not show it offline', () async {
    final online = SportsImageDiskCache(
      directory: directory,
      clock: () => now,
      fetch: (_) async => png,
    );
    final file = await online.resolve(
      canonicalId: 'fb_player_a',
      url: 'https://media.example.test/a.png',
    );
    expect(file, isNotNull);
    now = now.add(const Duration(days: 8));
    final offline = SportsImageDiskCache(
      directory: directory,
      clock: () => now,
      fetch: (_) => throw const SocketException('offline'),
    );
    expect(
      await offline.resolve(
        canonicalId: 'fb_player_a',
        url: 'https://media.example.test/a.png',
      ),
      isNull,
    );
    expect(await file!.exists(), isFalse);
  });

  test('entry and byte limits evict oldest media', () async {
    final cache = SportsImageDiskCache(
      directory: directory,
      maxEntries: 2,
      maxBytes: png.length * 2,
      fetch: (_) async => png,
    );
    final a = await cache.resolve(
      canonicalId: 'fb_player_a',
      url: 'https://media.example.test/a.png',
    );
    await a!.setLastModified(DateTime.now().subtract(const Duration(hours: 2)));
    await cache.resolve(
      canonicalId: 'fb_player_b',
      url: 'https://media.example.test/b.png',
    );
    await cache.resolve(
      canonicalId: 'fb_player_c',
      url: 'https://media.example.test/c.png',
    );
    expect(await a.exists(), isFalse);
    expect(directory.listSync().whereType<File>().length, 2);
  });

  test('simultaneous views share one download', () async {
    var requests = 0;
    final cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return png;
      },
    );
    await Future.wait([
      cache.resolve(
        canonicalId: 'fb_player_a',
        url: 'https://media.example.test/a.png',
      ),
      cache.resolve(
        canonicalId: 'fb_player_a',
        url: 'https://media.example.test/a.png',
      ),
    ]);
    expect(requests, 1);
  });

  test(
    'different players download concurrently without losing partial files',
    () async {
      final errors = <Object>[];
      final cache = SportsImageDiskCache(
        directory: directory,
        onError: errors.add,
        fetch: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return png;
        },
      );
      final files = await Future.wait([
        for (var i = 0; i < 18; i++)
          cache.resolve(
            canonicalId: 'fb_player_$i',
            url: 'https://media.example.test/$i.png',
          ),
      ]);
      expect(files.whereType<File>().length, 18, reason: '$errors');
      expect(directory.listSync().whereType<File>().length, 18);
    },
  );

  testWidgets('missing or revoked URL and corrupt image show fallback', (
    tester,
  ) async {
    final cache = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async => Uint8List.fromList([1, 2, 3]),
    );
    Future<void> show(String? url) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SportsImage(
            canonicalId: 'fb_player_a',
            url: url,
            cache: cache,
            width: 40,
            height: 40,
            fallback: const Text('placeholder'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('https://media.example.test/broken.png');
    expect(find.text('placeholder'), findsOneWidget);
    await show(null);
    expect(find.text('placeholder'), findsOneWidget);
  });
}

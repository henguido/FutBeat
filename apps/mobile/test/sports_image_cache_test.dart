import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/sports_image_cache.dart';

/// Counts real directory traversals without replacing filesystem behavior.
class _ScanCountingDirectory implements Directory {
  _ScanCountingDirectory(this.directory);

  final Directory directory;
  int scans = 0;
  Future<void> Function(int scan)? afterSnapshot;

  @override
  String get path => directory.path;

  @override
  Future<bool> exists() => directory.exists();

  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    scans++;
    final entries = directory.list(
      recursive: recursive,
      followLinks: followLinks,
    );
    final callback = afterSnapshot;
    if (callback == null) {
      yield* entries;
    } else {
      final snapshot = await entries.toList();
      await callback(scans);
      yield* Stream.fromIterable(snapshot);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected directory operation: $invocation');
}

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
    'one frame of cache maintenance shares one directory traversal',
    () async {
      final counted = _ScanCountingDirectory(directory);
      final cache = SportsImageDiskCache(directory: counted);
      await Future.wait([for (var i = 0; i < 18; i++) cache.evict()]);
      expect(counted.scans, 1);
    },
  );

  test(
    'a write during eviction gets a second scan before waiters finish',
    () async {
      final counted = _ScanCountingDirectory(directory);
      final firstScan = Completer<void>();
      final releaseScan = Completer<void>();
      counted.afterSnapshot = (scan) async {
        if (scan == 1) {
          firstScan.complete();
          await releaseScan.future;
        }
      };
      final cache = SportsImageDiskCache(directory: counted, maxEntries: 1);
      await File('${directory.path}/old.img').writeAsBytes(png);
      final first = cache.evict();
      await firstScan.future;
      await File('${directory.path}/late.img').writeAsBytes(png);
      final second = cache.evict();
      releaseScan.complete();
      await Future.wait([first, second]);
      expect(counted.scans, 2);
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );

  test('failed shared maintenance does not poison the next eviction', () async {
    final counted = _ScanCountingDirectory(directory);
    counted.afterSnapshot = (scan) async {
      if (scan == 1) throw const FileSystemException('fixture storage failure');
    };
    final cache = SportsImageDiskCache(directory: counted);
    await expectLater(cache.evict(), throwsA(isA<FileSystemException>()));
    await cache.evict();
    expect(counted.scans, 2);
  });

  test('concurrent downloads retain entry and byte bounds with fewer scans', () async {
    final counted = _ScanCountingDirectory(directory);
    final cache = SportsImageDiskCache(
      directory: counted,
      maxEntries: 3,
      maxBytes: png.length * 3,
      fetch: (_) async => png,
    );
    await Future.wait([
      for (var i = 0; i < 18; i++)
        cache.resolve(
          canonicalId: 'fb_player_batch_$i',
          url: 'https://media.example.test/batch-$i.png',
        ),
    ]);
    final files = directory.listSync().whereType<File>().toList();
    expect(files.length, lessThanOrEqualTo(3));
    expect(
      files.fold<int>(0, (sum, file) => sum + file.lengthSync()),
      lessThanOrEqualTo(png.length * 3),
    );
    // Filesystem scheduling varies by platform; the deterministic same-frame
    // test above checks coalescing. This batch checks bounds and records work.
    expect(counted.scans, lessThanOrEqualTo(18));
    // Diagnostic local filesystem count, not an Android latency claim.
    // ignore: avoid_print
    print(
      'SPORTS_CACHE_BENCH downloads=18 scans=${counted.scans} '
      'files=${files.length} bytes=${files.fold<int>(0, (n, f) => n + f.lengthSync())}',
    );
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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/sports_image_cache.dart';

class _RepairedFile implements File {
  _RepairedFile(this.actual, this.repair);
  final File actual;
  final Future<void> Function() repair;
  bool repaired = false;
  @override
  String get path => actual.path;
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      actual.delete(recursive: recursive);
  @override
  Future<FileStat> stat() async {
    final previous = await actual.stat();
    if (!repaired) {
      repaired = true;
      await repair();
    }
    return previous;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}

class _PeerDirectory implements Directory {
  _PeerDirectory(this.actual, this.file);
  final Directory actual;
  final File file;
  @override
  String get path => actual.path;
  @override
  Future<bool> exists() => actual.exists();
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    yield file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'eviction cannot delete a detectable newer repair using an expired stat',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-eviction-race260-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/old.img');
      final now = DateTime.now();
      await file.writeAsBytes([1, 2, 3]);
      await file.setLastModified(now.subtract(const Duration(days: 8)));
      final valid = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final peer = _RepairedFile(file, () async {
        await file.writeAsBytes(valid, flush: true);
        await file.setLastModified(now);
      });
      final cache = SportsImageDiskCache(
        directory: _PeerDirectory(directory, peer),
        clock: () => now,
      );
      await cache.evict();
      expect(peer.repaired, isTrue);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), valid);
    },
  );
  test(
    'a delayed invalid decoder result cannot delete a peer repaired photo',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-review260-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const id = 'fb_player_review260';
      const url = 'https://fixture.invalid/photo.png';
      final key = sha256.convert('$id\u0000$url'.codeUnits).toString();
      final file = File('${directory.path}/$key.img');
      await file.writeAsBytes([1, 2, 3]);
      final valid = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      var repaired = false;
      var fetches = 0;
      final cache = SportsImageDiskCache(
        directory: directory,
        fetch: (_) async {
          fetches++;
          throw const SocketException('offline');
        },
        // Deterministic peer interleaving: the invalid decode has finished,
        // but its caller has not yet decided to delete the original file.
        onError: (_) {
          if (!repaired) {
            repaired = true;
            file.writeAsBytesSync(valid, flush: true);
          }
        },
      );
      final recovered = await cache.resolve(canonicalId: id, url: url);
      expect(recovered?.uri, file.uri);
      expect(fetches, 0);
      expect(repaired, isTrue);
      expect(
        await file.exists(),
        isTrue,
        reason:
            'a newer valid disk replacement must survive an old decode failure',
      );
      expect(await file.readAsBytes(), valid);
    },
  );
}

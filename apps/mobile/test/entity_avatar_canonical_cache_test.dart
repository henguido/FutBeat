import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/sports_image_cache.dart';
import 'package:futbeat/shared/widgets.dart';

const _photo = 'https://media.example.test/verified-player.png';
const _canonical = 'fb_player_shared';

EntityMediaMemory _memory() => EntityMediaMemory()
  ..absorb(
    Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-10-31T00:00:00Z',
      'teams': <dynamic>[],
      'competitions': <dynamic>[],
      'matches': <dynamic>[],
      'standings': <dynamic>[],
      'players': [
        {
          'id': _canonical,
          'name': 'Persona verificada',
          'media': {'verificationStatus': 'VERIFIED', 'url': _photo},
        },
      ],
    }),
  );

void main() {
  late Directory directory;
  final png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    ),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('futbeat-avatar-cache-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('legacy squad avatar keeps the verified canonical disk cache', (
    tester,
  ) async {
    final memory = _memory();
    addTearDown(memory.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: EntityMediaScope(
          memory: memory,
          child: EntityAvatar(
            Entity({
              'id': 'provider-squad-17',
              'canonicalId': _canonical,
              'name': 'Persona verificada',
            }),
            cache: SportsImageDiskCache(
              directory: directory,
              fetch: (_) async => png,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SportsImage), findsOneWidget);
    final image = tester.widget<SportsImage>(find.byType(SportsImage));
    expect(image.canonicalId, _canonical);
    expect(image.url, _photo);
  });

  testWidgets(
    'club and national aliases reuse one file after an offline restart',
    (tester) async {
      final memory = _memory();
      addTearDown(memory.dispose);
      var requests = 0;
      final online = SportsImageDiskCache(
        directory: directory,
        fetch: (_) async {
          requests++;
          return png;
        },
      );
      Future<SportsImage> showAlias(
        String id,
        SportsImageDiskCache cache,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: EntityMediaScope(
              memory: memory,
              child: EntityAvatar(
                Entity({
                  'id': id,
                  'canonicalId': _canonical,
                  'name': 'Persona verificada',
                }),
                cache: cache,
              ),
            ),
          ),
        );
        return tester.widget<SportsImage>(find.byType(SportsImage));
      }

      final downloaded = await tester.runAsync(
        () => online.resolve(canonicalId: _canonical, url: _photo),
      );
      expect(downloaded, isNotNull);
      final club = await showAlias('provider-squad-17', online);
      await tester.pumpWidget(const SizedBox.shrink());
      final offline = SportsImageDiskCache(
        directory: directory,
        fetch: (_) => throw const SocketException('offline'),
      );
      final restored = await tester.runAsync(
        () => offline.resolve(canonicalId: club.canonicalId, url: club.url),
      );
      final national = await showAlias('provider-national-88', offline);
      expect(restored?.path, downloaded!.path);
      expect(national.canonicalId, club.canonicalId);
      expect(requests, 1);
      expect(directory.listSync().whereType<File>().length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('canonical row does not rekey its photo to a conflicting field', (
    tester,
  ) async {
    final memory = _memory();
    addTearDown(memory.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: EntityMediaScope(
          memory: memory,
          child: EntityAvatar(
            Entity({
              'id': _canonical,
              'canonicalId': 'fb_player_other',
              'name': 'Persona verificada',
            }),
            cache: SportsImageDiskCache(
              directory: directory,
              fetch: (_) async => png,
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<SportsImage>(find.byType(SportsImage)).canonicalId,
      _canonical,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('homonym without verified media keeps initials', (tester) async {
    final memory = _memory();
    addTearDown(memory.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: EntityMediaScope(
          memory: memory,
          child: EntityAvatar(
            Entity({
              'id': 'provider-homonym-99',
              'canonicalId': 'fb_player_other',
              'name': 'Persona verificada',
            }),
          ),
        ),
      ),
    );
    expect(find.byType(SportsImage), findsNothing);
    expect(find.text('Pv'), findsOneWidget);
  });
}

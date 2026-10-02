import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/profile_context.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/team_profile.dart';
import 'package:futbeat/features/favorites/favorites_screen.dart';

const _alias = 'fb_comp_cr';
const _canonical = 'fb_competition_3e03182862764420947393642a407616';

Snapshot _snapshot({
  Map<String, String> redirects = const {},
  List<Json> competitions = const [],
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-01T12:00:00Z',
  'entityRedirects': redirects,
  'teams': <dynamic>[],
  'players': <dynamic>[],
  'competitions': competitions,
  'matches': <dynamic>[],
  'standings': <dynamic>[],
});

const _aliasCompetition = <String, dynamic>{
  'id': _alias,
  'name': 'Costa-Rica Liga FPD',
  'country': 'Costa Rica',
};
const _canonicalCompetition = <String, dynamic>{
  'id': _canonical,
  'name': 'Primera División',
  'country': 'Costa Rica',
};

void main() {
  group('EntityRedirectMemory', () {
    test('resolves chains and follow keys; matches never redirect', () {
      final memory = EntityRedirectMemory();
      addTearDown(memory.dispose);
      var notified = 0;
      memory.addListener(() => notified++);

      memory.absorb({_alias: 'fb_mid', 'fb_mid': _canonical});
      expect(memory.resolve(_alias), _canonical);
      expect(memory.resolve('fb_other'), 'fb_other');
      expect(
        memory.resolveFollowKey('competition:$_alias'),
        'competition:$_canonical',
      );
      expect(memory.resolveFollowKey('match:$_alias'), 'match:$_alias');
      expect(memory.resolveFollowKey('broken'), 'broken');
      expect(notified, 1);

      // Nothing new: no notification.
      memory.absorb({_alias: 'fb_mid'});
      memory.absorb(const {});
      expect(notified, 1);
    });

    test('every snapshot absorbed by the media memory teaches redirects', () {
      final media = EntityMediaMemory();
      addTearDown(media.dispose);
      media.absorb(_snapshot(redirects: {_alias: _canonical}));
      expect(media.redirects.resolve(_alias), _canonical);
    });
  });

  group('follows stored under an alias id', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.addFollows(['competition:$_alias', 'team:fb_team_1']);
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('read as the canonical entity once the redirect is known, '
        'without rewriting what is stored', () async {
      final sub = container.listen(followsProvider, (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(followsProvider.future), {
        'competition:$_alias',
        'team:fb_team_1',
      });

      container
          .read(entityMediaProvider)
          .absorb(_snapshot(redirects: {_alias: _canonical}));
      await pumpEventQueue();
      expect(container.read(followsProvider).value, {
        'competition:$_canonical',
        'team:fb_team_1',
      });
      // Stored (and synced) follows are untouched.
      expect(await db.watchFollows().first, {
        'competition:$_alias',
        'team:fb_team_1',
      });
    });

    test('unfollowing the canonical entity removes the alias follow', () async {
      final redirects = container.read(entityMediaProvider).redirects
        ..absorb({_alias: _canonical});
      await toggleFollow(db, redirects, 'competition', _canonical);
      expect(await db.watchFollows().first, {'team:fb_team_1'});
      // Following again stores the canonical id.
      await toggleFollow(db, redirects, 'competition', _canonical);
      expect(await db.watchFollows().first, {
        'team:fb_team_1',
        'competition:$_canonical',
      });
    });
  });

  testWidgets('Siguiendo lists the canonical competition of an alias follow', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.addFollows(['competition:$_alias']);
    final requested = <String>[];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Like the server: the canonical entity for a canonical key; the
        // alias entity itself when asked by its alias id.
        favoritesSnapshotProvider.overrideWith((ref, keys) async {
          requested.add(keys);
          return _snapshot(
            competitions: [
              keys.contains(_canonical)
                  ? _canonicalCompetition
                  : _aliasCompetition,
            ],
          );
        }),
        liveMatchUpdatesProvider.overrideWith(
          (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Any snapshot read this session (calendar, search...) carries the
    // redirect table.
    container
        .read(entityMediaProvider)
        .absorb(_snapshot(redirects: {_alias: _canonical}));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FavoritesScreen()),
      ),
    );
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    expect(find.text('Primera División'), findsOneWidget);
    expect(find.text('Costa-Rica Liga FPD'), findsNothing);
    expect(requested.last, 'competition:$_canonical');
    await tester.pumpWidget(const SizedBox());
  });

  test('profile context option under an alias id shows the canonical name', () {
    final memory = EntityRedirectMemory();
    addTearDown(memory.dispose);
    final data = _snapshot(
      competitions: [_aliasCompetition, _canonicalCompetition],
    );
    // Not known as an alias yet: the server's own name stays.
    expect(canonicalCompetitionName(data, memory, _alias), isNull);
    memory.absorb({_alias: _canonical});
    expect(canonicalCompetitionName(data, memory, _alias), 'Primera División');
    expect(canonicalCompetitionName(data, memory, _canonical), isNull);

    final option = ProfileContextOption({
      'competitionId': _alias,
      'competitionName': 'Costa-Rica Liga FPD',
      'seasonKey': '2026-2027',
    });
    final renamed = option.withCompetitionName('Primera División');
    expect(renamed.label, 'Primera División 2026/27');
    expect(renamed.key, option.key);
    expect(renamed.competitionId, _alias);
  });
}

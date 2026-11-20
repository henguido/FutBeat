import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/favorites/favorites_screen.dart';

Snapshot _storedFavorite() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp_a', 'name': 'Stored competition'},
  ],
  'teams': [
    {'id': 'fb_team_a', 'name': 'Followed team'},
    {'id': 'fb_team_b', 'name': 'Opponent'},
  ],
  'players': <dynamic>[],
  'matches': [
    {
      'id': 'fb_match_stored',
      'competitionId': 'fb_comp_a',
      'homeTeamId': 'fb_team_a',
      'awayTeamId': 'fb_team_b',
      'startTime': '2099-11-03T18:00:00Z',
      'status': 'SCHEDULED',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
});

void main() {
  testWidgets('removing the last favorite clears its retained LIVE scope', (
    tester,
  ) async {
    final changes = StreamController<Set<String>>();
    final dio = Dio();
    final client = LiveRealtimeClient(
      const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
      dio,
      scopedRealtime: true,
    );
    var loads = 0;
    final container = ProviderContainer(
      overrides: [
        followsProvider.overrideWith((ref) => changes.stream),
        favoritesSnapshotProvider.overrideWith((ref, keys) async {
          loads++;
          return _storedFavorite();
        }),
        liveRealtimeClientProvider.overrideWithValue(client),
        liveMatchUpdatesProvider.overrideWith(
          (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await changes.close();
      client.dispose();
      dio.close(force: true);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FavoritesScreen()),
      ),
    );
    changes.add({'team:fb_team_a'});
    await tester.pumpAndSettle();
    expect(client.realtimeMatchIds, ['fb_match_stored']);
    expect(find.text('Followed team'), findsOneWidget);

    changes.add({});
    await tester.pumpAndSettle();

    expect(find.text('Aún no sigues equipos.'), findsOneWidget);
    expect(client.realtimeMatchIds, isEmpty);
    // A cached re-follow restores this screen's scope; clearing it again
    // must leave an independently open Match Center subscription untouched.
    client.setScope('match:open', ['fb_match_open']);
    changes.add({'team:fb_team_a'});
    await tester.pumpAndSettle();
    expect(client.realtimeMatchIds, ['fb_match_open', 'fb_match_stored']);
    changes.add({});
    await tester.pumpAndSettle();
    expect(client.realtimeMatchIds, ['fb_match_open']);
    expect(
      loads,
      1,
      reason: 'clearing favorites does not fetch another snapshot',
    );
    expect(tester.takeException(), isNull);
  });
}

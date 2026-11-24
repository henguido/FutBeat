import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

// Optional recommendations have no server route. Existing catalog players
// and explicit search remain usable. Synthetic ids and names only.

Map<String, dynamic> _snapshot({
  List<Map<String, dynamic>> players = const [],
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-05T00:00:00Z',
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': <dynamic>[],
  'teams': <dynamic>[],
  'players': players,
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

void main() {
  test(
    'unavailable recommendations never read repository or preferences',
    () async {
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWith(
            (ref) => throw StateError('No repository read allowed'),
          ),
          preferenceProvider.overrideWith(
            (ref) => throw StateError('No preferences read allowed'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        await container.read(playerSuggestionsProvider('fb_team_a').future),
        isEmpty,
      );
    },
  );

  test('followedTeamsKey keeps only team follows, sorted', () {
    expect(
      followedTeamsKey({
        'player:p1',
        'team:fb_team_b',
        'competition:c',
        'team:fb_team_a',
      }),
      'fb_team_a,fb_team_b',
    );
  });

  testWidgets(
    'R4 Explorar uses existing catalog players without watching recommendations',
    (tester) async {
      var recommendationsWatched = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            expect(o.path, isNot('/v1/player-suggestions'));
            final players = o.path == '/v1/explore'
                ? [
                    {
                      'id': 'fb_player_s1',
                      'name': 'Jugador Sugerido',
                      'teamId': 'fb_team_a',
                    },
                  ]
                : const <Map<String, dynamic>>[];
            h.resolve(
              Response(
                requestOptions: o,
                data: _snapshot(players: players),
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerSuggestionsProvider.overrideWith((ref, key) async {
              recommendationsWatched++;
              return const <Entity>[];
            }),
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            followsProvider.overrideWith(
              (ref) => Stream.value({'team:fb_team_a'}),
            ),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: 'CR',
                  selectedCountry: null,
                  bootstrapDismissed: true,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: ExploreScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(recommendationsWatched, 0);
      expect(find.text('Jugadores sugeridos'), findsOneWidget);
      expect(find.text('Jugador Sugerido'), findsOneWidget);
    },
  );

  testWidgets('Explorar never requests the absent recommendations route', (
    tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          expect(o.path, isNot('/v1/player-suggestions'));
          h.resolve(Response(requestOptions: o, data: _snapshot()));
        },
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(ApiRepository(dio)),
          followsProvider.overrideWith((ref) => Stream.value(const {})),
        ],
        child: const MaterialApp(home: ExploreScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jugadores sugeridos'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

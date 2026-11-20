import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

// Player suggestions without a query come from /v1/player-suggestions (real
// squad players; followed teams first). Synthetic ids and names only.

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
    'request: followed team ids sorted, deduplicated, at most 20, plus country',
    () async {
      final dio = Dio();
      RequestOptions? seen;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            seen = o;
            h.resolve(Response(requestOptions: o, data: _snapshot()));
          },
        ),
      );
      final ids = [for (var i = 25; i > 0; i--) 'fb_team_$i', 'fb_team_3'];
      await ApiRepository(dio).loadPlayerSuggestions(ids, 'cr');
      expect(seen!.path, '/v1/player-suggestions');
      final teams = (seen!.queryParameters['teams'] as String).split(',');
      expect(teams, hasLength(20));
      expect(teams, [...teams]..sort());
      expect(teams.toSet(), hasLength(20));
      expect(seen!.queryParameters['country'], 'CR');
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

  testWidgets('Explorar shows suggested players without a query', (
    tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          final players = o.path == '/v1/player-suggestions'
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
    expect(find.text('Jugadores sugeridos'), findsOneWidget);
    expect(find.text('Jugador Sugerido'), findsOneWidget);
  });

  testWidgets('a failing suggestions request never breaks Explorar', (
    tester,
  ) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (o.path == '/v1/player-suggestions') {
            h.reject(DioException(requestOptions: o, message: 'down'));
            return;
          }
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

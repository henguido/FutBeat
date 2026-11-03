import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/match_prefetch_plan.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

void main() {
  for (final status in ['SCHEDULED', 'VERIFIED']) {
    testWidgets('followed $status match warms saved detail without HTTP', (
      tester,
    ) async {
      final day = costaRicaNow().add(const Duration(days: 1));
      final date = DateTime(day.year, day.month, day.day, 8);
      final db = AppDatabase(NativeDatabase.memory());
      final rawDetail = <String, dynamic>{
        'matchId': 'fb_match_local',
        'available': true,
        'pending': false,
        'detailLevel': 'full',
        'home': <String, dynamic>{},
        'away': <String, dynamic>{},
        'statistics': <dynamic>[],
        'incidents': <dynamic>[],
        'coverage': <String, dynamic>{},
      };
      await db.savePublicSnapshot(
        'public:match-detail:fb_match_local',
        jsonEncode(rawDetail),
      );
      final data = Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'competitions': [
          {'id': 'fb_comp_local', 'name': 'Liga local'},
        ],
        'teams': [
          {'id': 'fb_team_home', 'name': 'Local'},
          {'id': 'fb_team_away', 'name': 'Visita'},
        ],
        'players': <dynamic>[],
        'matches': [
          {
            'id': 'fb_match_local',
            'competitionId': 'fb_comp_local',
            'homeTeamId': 'fb_team_home',
            'awayTeamId': 'fb_team_away',
            'startTime': DateTime.utc(
              day.year,
              day.month,
              day.day,
              18,
            ).toIso8601String(),
            'status': status,
          },
        ],
        'standings': <dynamic>[],
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://qa.invalid'));
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
      final repository = ApiRepository(dio, db);
      expect(
        (await repository.readStoredMatchDetail('fb_match_local'))?.available,
        isTrue,
      );
      final games = data.onDate(date, 'Todos');
      expect(games, hasLength(1));
      expect(
        MatchPrefetchPlan.build(
          matches: games,
          follows: {'team:fb_team_home'},
          selectedCountry: null,
          competitions: {for (final c in data.competitions) c.id: c},
        ).matchIds,
        ['fb_match_local'],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(repository),
          calendarSnapshotProvider.overrideWith(
            (ref, date) => Stream.value(data),
          ),
          followsProvider.overrideWith(
            (ref) => Stream.value({'team:fb_team_home'}),
          ),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: null,
                selectedCountry: null,
                bootstrapDismissed: true,
              ),
            ),
          ),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close(force: true);
        await tester.runAsync(db.close);
      });
      final paintToLocalDetail = Stopwatch()..start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: MatchesScreen(now: () => date)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('match-row-fb_match_local')),
        findsNWidgets(2),
        reason: '#220 keeps the followed fixture in Favoritos and its league; '
            'both presentations share the same local warm-up',
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          if (container.read(matchDetailMemoryProvider)['fb_match_local'] !=
              null) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(
        container.read(matchDetailMemoryProvider)['fb_match_local']?.available,
        isTrue,
      );
      paintToLocalDetail.stop();
      // Diagnostic only: CI/host timing is not an Android latency guarantee.
      debugPrint(
        'MOBILE201 local detail warm: '
        '${paintToLocalDetail.elapsedMilliseconds} ms, $requests HTTP',
      );
      expect(requests, 0);
    });
  }
}

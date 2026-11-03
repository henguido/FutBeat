import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

const _id = 'fb_match_resume_fixture';
MatchDetail _stored() => MatchDetail({
  ...MatchDetail.empty(_id).json,
  'available': true,
  'fetchedAt': '2026-11-03T18:00:00Z',
});

class _HeldDiskRead extends ApiRepository {
  _HeldDiskRead(super.dio);
  final first = Completer<MatchDetail?>();
  final started = Completer<void>();
  final reads = <String>[];
  @override
  Future<MatchDetail?> readStoredMatchDetail(String id) async {
    reads.add(id);
    if (reads.length == 1) {
      started.complete();
      return first.future;
    }
    return _stored();
  }
}

Snapshot _data() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T18:00:00Z',
  'teams': [
    {'id': 'fb_team_a', 'name': 'Team A'},
    {'id': 'fb_team_b', 'name': 'Team B'},
  ],
  'competitions': [
    {'id': 'fb_comp_a', 'name': 'Fixture league'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': _id,
      'competitionId': 'fb_comp_a',
      'homeTeamId': 'fb_team_a',
      'awayTeamId': 'fb_team_b',
      'startTime': '2026-11-03T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 1},
    },
  ],
});
void main() {
  for (final completesWhilePaused in [false, true]) {
    testWidgets(
      'interrupted disk warm can resume when first completes paused=$completesWhilePaused',
      (tester) async {
        final dio = Dio();
        var http = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              http++;
              handler.reject(DioException(requestOptions: request));
            },
          ),
        );
        final repository = _HeldDiskRead(dio);
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(repository),
            calendarSnapshotProvider.overrideWith(
              (ref, date) => Stream.value(_data()),
            ),
            followsProvider.overrideWith(
              (ref) => Stream.value({'team:fb_team_a'}),
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
          if (!repository.first.isCompleted) repository.first.complete(null);
          await tester.pumpWidget(const SizedBox());
          container.dispose();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          dio.close(force: true);
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: MatchesScreen(now: () => DateTime(2026, 11, 3, 12)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(repository.started.isCompleted, isTrue);
        expect(repository.reads, [_id]);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        if (!completesWhilePaused) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        }
        repository.first.complete(_stored());
        await tester.pumpAndSettle();
        if (completesWhilePaused) {
          expect(
            container.read(matchDetailMemoryProvider),
            isEmpty,
            reason: 'paused read must not publish detail into the visible warm scope',
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
        }
        expect(
          container.read(matchDetailMemoryProvider)[_id]?.available,
          isTrue,
          reason: 'an interrupted attempt cannot permanently exclude a stored favorite',
        );
        expect(repository.reads, [_id, _id]);
        expect(http, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

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
  _HeldDiskRead(super.dio, {this.holdSecond = false});
  final bool holdSecond;
  final first = Completer<MatchDetail?>();
  final second = Completer<MatchDetail?>();
  final started = Completer<void>();
  final secondStarted = Completer<void>();
  final reads = <String>[];
  var active = 0;
  var peak = 0;
  @override
  Future<MatchDetail?> readStoredMatchDetail(String id) async {
    reads.add(id);
    active++;
    if (active > peak) peak = active;
    try {
      if (reads.length == 1) {
        started.complete();
        return await first.future;
      }
      if (reads.length == 2 && holdSecond) {
        secondStarted.complete();
        return await second.future;
      }
      return _stored();
    } finally {
      active--;
    }
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

class _WarmFixture {
  _WarmFixture({bool holdSecond = false}) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          http++;
          handler.reject(DioException(requestOptions: request));
        },
      ),
    );
    repository = _HeldDiskRead(dio, holdSecond: holdSecond);
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        calendarSnapshotProvider.overrideWith(
          (ref, date) => Stream.value(_data()),
        ),
        followsProvider.overrideWith((ref) => Stream.value({'team:fb_team_a'})),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              selectedCountry: null,
              detectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
  }
  final dio = Dio();
  late final _HeldDiskRead repository;
  late final ProviderContainer container;
  var http = 0;
  Future<void> mount(WidgetTester tester) async {
    addTearDown(() async {
      if (!repository.first.isCompleted) repository.first.complete(null);
      if (!repository.second.isCompleted) repository.second.complete(null);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      dio.close(force: true);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
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
  }

  bool get warmed =>
      container.read(matchDetailMemoryProvider)[_id]?.available == true;
}

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
  testWidgets(
    'successive pause-resume cycles keep one pending warm attempt owner',
    (tester) async {
      final fixture = _WarmFixture(holdSecond: true);
      await fixture.mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, [
        _id,
      ], reason: 'old disk read still owns the running slot');
      fixture.repository.first.complete(_stored());
      await tester.pumpAndSettle();
      expect(fixture.repository.secondStarted.isCompleted, isTrue);
      expect(fixture.repository.reads, [_id, _id]);
      // Rebuild while the replacement read remains pending. The old finally
      // cannot release that new operation's slot or launch duplicate work.
      tester.element(find.byType(MatchesScreen)).markNeedsBuild();
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, [_id, _id]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, [_id, _id]);
      fixture.repository.second.complete(_stored());
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, [_id, _id, _id]);
      expect(fixture.warmed, isTrue);
      tester.element(find.byType(MatchesScreen)).markNeedsBuild();
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, hasLength(3));
      expect(fixture.repository.peak, 1);
      expect(fixture.repository.active, 0);
      expect(fixture.http, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final cancelled in [false, true]) {
    testWidgets('SQLite warm failure remains contained cancelled=$cancelled', (
      tester,
    ) async {
      final fixture = _WarmFixture();
      await fixture.mount(tester);
      if (cancelled) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
      }
      fixture.repository.first.completeError(
        StateError('Synthetic SQLite read failure'),
      );
      await tester.pumpAndSettle();
      expect(fixture.repository.reads, [_id]);
      expect(fixture.warmed, isFalse);
      expect(tester.takeException(), isNull);
      if (cancelled) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(fixture.repository.reads, [_id, _id]);
        expect(fixture.warmed, isTrue);
      } else {
        // An active best-effort disk error is not an automatic retry loop.
        tester.element(find.byType(MatchesScreen)).markNeedsBuild();
        await tester.pumpAndSettle();
        expect(fixture.repository.reads, [_id]);
      }
      expect(fixture.repository.peak, lessThanOrEqualTo(2));
      expect(fixture.repository.reads.length, lessThanOrEqualTo(8));
      expect(fixture.http, 0);
      expect(tester.takeException(), isNull);
    });
  }
}

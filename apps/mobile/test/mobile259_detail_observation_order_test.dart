import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_diagnostics.dart';

const matchId = 'fb_match_revision259';
Json detail(String? fetchedAt, {required bool cancelled}) => {
  'matchId': matchId,
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'fetchedAt': ?fetchedAt,
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': [
    {'label': 'shots', 'home': cancelled ? 2 : 3, 'away': 1},
  ],
  'incidents': cancelled
      ? <Json>[]
      : [
          {'id': 'goal259', 'type': 'GOAL', 'minute': 20, 'side': 'home'},
        ],
};

class _DelayedDetailRepository implements FootballRepository {
  _DelayedDetailRepository(this.next);
  final MatchDetail next;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => next;
  @override
  Future<Snapshot> load() async => throw UnimplementedError();
  @override
  Future<Snapshot> loadDate(DateTime date) => load();
}

void main() {
  test(
    'verified detail from yesterday survives database reopen and ten opens',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-cache01-',
      );
      final file = File.fromUri(directory.uri.resolve('match.sqlite'));
      final seed = AppDatabase(NativeDatabase(file));
      final now = DateTime.now().toUtc();
      final yesterday = now.subtract(const Duration(days: 1)).toIso8601String();
      final raw = detail(yesterday, cancelled: true)
        ..['coverage'] = {'lineup': 'unavailable', 'statistics': 'available'};
      await seed
          .into(seed.catalogSnapshots)
          .insert(
            CatalogSnapshotsCompanion.insert(
              cacheKey: 'public:match-detail:$matchId',
              payload: jsonEncode(raw),
              savedAt: DateTime.parse(yesterday),
            ),
          );
      final context = <String, dynamic>{
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': yesterday,
        'teams': [
          {'id': 'fb_team_home_cache01', 'name': 'Local'},
          {'id': 'fb_team_away_cache01', 'name': 'Visitante'},
        ],
        'competitions': [
          {'id': 'fb_comp_cache01', 'name': 'Competición'},
        ],
        'players': [],
        'matches': [
          {
            'id': matchId,
            'competitionId': 'fb_comp_cache01',
            'homeTeamId': 'fb_team_home_cache01',
            'awayTeamId': 'fb_team_away_cache01',
            'startTime': yesterday,
            'status': 'VERIFIED',
            'score': {'home': 2, 'away': 1},
          },
        ],
        'standings': [],
      };
      await seed.savePublicSnapshot(
        'public:match-context:$matchId',
        jsonEncode(context),
      );
      await seed.close();
      final db = AppDatabase(NativeDatabase(file));
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() async {
        dio.close(force: true);
        await db.close();
        for (final entry in directory.listSync().whereType<File>()) {
          await entry.delete();
        }
        await directory.delete();
      });
      final requests = <String, int>{};
      final correctionRead = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.update(
              options.path,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            if (options.path == '/v1/match-detail' &&
                !correctionRead.isCompleted) {
              correctionRead.complete();
            }
            final response = switch (options.path) {
              '/v1/match-context' => context,
              '/v1/match-preview' => {'matchId': matchId},
              '/v1/match-detail' => raw,
              _ => throw StateError('Unexpected route: ${options.path}'),
            };
            handler.resolve(Response(requestOptions: options, data: response));
          },
        ),
      );
      for (var open = 0; open < 10; open++) {
        final settled = Completer<void>();
        final events = <String>[];
        final updates =
            StreamController<Map<String, LiveMatchUpdate>>.broadcast();
        final repository = ApiRepository(
          dio,
          db,
          const CalendarCachePolicy(),
          null,
          QaDiagnostics(
            onRecord: (_, event, _, _) {
              events.add(event);
              if (event == 'settledCacheHit' && !settled.isCompleted) {
                settled.complete();
              }
            },
          ),
        );
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(repository),
            liveMatchUpdatesProvider.overrideWith((ref) => updates.stream),
          ],
        );
        final subscription = container.listen(matchDetailProvider(matchId), (
          _,
          next,
        ) {
          if (next.hasError && !settled.isCompleted) {
            settled.completeError(next.error!, next.stackTrace);
          }
        });
        final freshContext = Completer<void>();
        final contextSubscription = container.listen(
          matchContextSnapshotProvider(matchId),
          (_, next) {
            if (next.hasError && !freshContext.isCompleted) {
              freshContext.completeError(next.error!, next.stackTrace);
            } else if (next.asData?.value.stale == false &&
                !freshContext.isCompleted) {
              freshContext.complete();
            }
          },
        );
        final previewSubscription = container.listen(
          matchPreviewProvider(matchId),
          (_, _) {},
        );
        try {
          final result = await container.read(
            matchDetailProvider(matchId).future,
          );
          expect(result.available, isTrue);
          expect(result.offlineStale, isTrue);
          await settled.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('Open ${open + 1}: $events, HTTP=$requests'),
          );
          await freshContext.future.timeout(const Duration(seconds: 2));
          await container.read(matchPreviewProvider(matchId).future);
          await repository.settleBackground();
          if (open == 9) {
            expect(requests, {
              '/v1/match-context': 10,
              '/v1/match-preview': 10,
            });
            debugPrint(
              'MATCH-CACHE-01 opens=10 detail=0 context=10 preview=10 other=0',
            );
            updates.add({
              matchId: LiveMatchUpdate(
                matchId: matchId,
                provider: 'goal_api',
                externalMatchId: 'fixture',
                status: 'VERIFIED',
                homeScore: 1,
                awayScore: 1,
                minute: 90,
                revision: 2,
                eventCount: 0,
                changedAt: now,
                events: const [],
              ),
            });
            await correctionRead.future.timeout(const Duration(seconds: 2));
            await container.read(matchDetailProvider(matchId).future);
            await repository.settleBackground();
          }
        } finally {
          previewSubscription.close();
          contextSubscription.close();
          subscription.close();
          container.dispose();
          await updates.close();
        }
      }
      expect(requests, {
        '/v1/match-context': 10,
        '/v1/match-preview': 10,
        '/v1/match-detail': 1,
      });
      debugPrint('MATCH-CACHE-01 correction=1 detail=1 other=0');
    },
  );

  test(
    'older stored detail cannot resurrect an annulled goal or old stats',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final repository = ApiRepository(dio, db);
      addTearDown(() async {
        await repository.settleBackground();
        dio.close(force: true);
        await db.close();
      });
      repository.persistMatchDetail(
        matchId,
        MatchDetail(detail('2026-11-03T20:20:00Z', cancelled: true)),
      );
      repository.persistMatchDetail(
        matchId,
        MatchDetail(detail('2026-11-03T20:10:00Z', cancelled: false)),
      );
      await repository.settleBackground();
      final saved = await repository.readStoredMatchDetail(matchId);
      expect(saved!.json['incidents'], isEmpty);
      expect((saved.json['statistics'] as List).single['home'], 2);
      expect(saved.fetchedAt, '2026-11-03T20:20:00Z');
    },
  );

  test(
    'reopening Match Center rejects older observations in memory too',
    () async {
      final current = MatchDetail(
        detail('2026-11-03T20:20:00Z', cancelled: true),
      );
      final older = MatchDetail(
        detail('2026-11-03T20:10:00Z', cancelled: false),
      );
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(_DelayedDetailRepository(older)),
        ],
      );
      addTearDown(container.dispose);
      container.read(matchDetailMemoryProvider)[matchId] = current;
      final revalidated = Completer<void>();
      var observations = 0;
      final subscription = container.listen(matchDetailProvider(matchId), (
        _,
        next,
      ) {
        if (next.asData != null && ++observations == 2) {
          revalidated.complete();
        }
      });
      addTearDown(subscription.close);
      await revalidated.future.timeout(const Duration(seconds: 2));
      final rendered = container
          .read(matchDetailProvider(matchId))
          .asData!
          .value;
      expect(rendered.json['incidents'], isEmpty);
      expect(rendered.fetchedAt, current.fetchedAt);
      expect(
        container.read(matchDetailMemoryProvider)[matchId]!.json['incidents'],
        isEmpty,
      );
    },
  );

  for (final stamp in [
    '2026-11-03T20:20:00Z',
    '2026-11-03T20:21:00Z',
    null,
    'invalid',
  ]) {
    test(
      'authoritative correction remains accepted with timestamp $stamp',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final repository = ApiRepository(dio, db);
        addTearDown(() async {
          await repository.settleBackground();
          dio.close(force: true);
          await db.close();
        });
        repository.persistMatchDetail(
          matchId,
          MatchDetail(detail('2026-11-03T20:20:00Z', cancelled: false)),
        );
        repository.persistMatchDetail(
          matchId,
          MatchDetail(detail(stamp, cancelled: true)),
        );
        await repository.settleBackground();
        final saved = await repository.readStoredMatchDetail(matchId);
        expect(saved!.json['incidents'], isEmpty);
        expect((saved.json['statistics'] as List).single['home'], 2);
      },
    );
  }
}

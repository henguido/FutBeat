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
    'pending, no-store and transport-cached previews do not seed SQLite',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final repository = ApiRepository(dio, db);
      addTearDown(() async {
        await repository.settleBackground();
        dio.close();
        await db.close();
      });
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'cache-control': [
                    'public, max-age=30',
                    if (requests == 2) 'no-store',
                  ],
                }),
                extra: {if (requests == 3) 'futbeatTransportCacheHit': true},
                data: {
                  'matchId': matchId,
                  'h2h': {
                    'availability': requests == 1 ? 'PENDING' : 'AVAILABLE',
                  },
                },
              ),
            );
          },
        ),
      );
      for (var open = 0; open < 4; open++) {
        await repository.loadMatchPreview(matchId);
        await repository.settleBackground();
      }
      expect(requests, 4);
    },
  );

  test('expired match preview refreshes and shares concurrent reads', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    final repository = ApiRepository(dio, db);
    addTearDown(() async {
      await repository.settleBackground();
      dio.close();
      await db.close();
    });
    await db
        .into(db.catalogSnapshots)
        .insert(
          CatalogSnapshotsCompanion.insert(
            cacheKey: 'public:match-preview:$matchId',
            payload: jsonEncode({'matchId': matchId, 'matches': []}),
            savedAt: DateTime.now().toUtc().subtract(
              matchCacheRetention + const Duration(seconds: 5),
            ),
          ),
        );
    var requests = 0;
    final fresh = {
      'matchId': matchId,
      'h2h': {'availability': 'AVAILABLE'},
      'matches': [
        {'matchId': 'fb_match_new'},
      ],
    };
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          handler.resolve(
            Response(
              requestOptions: request,
              data: fresh,
              headers: Headers.fromMap({
                'cache-control': ['public, max-age=30'],
              }),
            ),
          );
        },
      ),
    );
    final first = repository.loadMatchPreview(matchId);
    final second = repository.loadMatchPreview(matchId);
    expect(second, same(first));
    expect((await first).json, fresh);
    await repository.settleBackground();
    expect(
      (await ApiRepository(dio, db).loadMatchPreview(matchId)).json,
      fresh,
    );
    expect(requests, 1);
  });

  test(
    'a VERIFIED correction survives late HTTP and reopening SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-be14-live-',
      );
      final file = File.fromUri(directory.uri.resolve('match.sqlite'));
      var db = AppDatabase(NativeDatabase(file));
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() async {
        dio.close();
        await db.close();
        for (final entry in directory.listSync().whereType<File>()) {
          await entry.delete();
        }
        await directory.delete();
      });
      final now = DateTime.now().toUtc();
      final raw = {
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': now.toIso8601String(),
        'teams': [
          {'id': 'fb_h', 'name': 'Local'},
          {'id': 'fb_a', 'name': 'Visita'},
        ],
        'competitions': [
          {'id': 'fb_c', 'name': 'Competición'},
        ],
        'players': [],
        'standings': [],
        'matches': [
          {
            'id': matchId,
            'competitionId': 'fb_c',
            'homeTeamId': 'fb_h',
            'awayTeamId': 'fb_a',
            'startTime': now
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
            'status': 'LIVE',
            'score': {'home': 1, 'away': 0},
          },
        ],
      };
      final released = Completer<void>();
      final started = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            started.complete();
            await released.future;
            handler.resolve(Response(requestOptions: request, data: raw));
          },
        ),
      );
      final repository = ApiRepository(dio, db);
      final lateHttp = repository.loadMatchContext(matchId);
      await started.future;
      final update = LiveMatchUpdate(
        matchId: matchId,
        provider: 'goal_api',
        externalMatchId: 'fixture',
        status: 'VERIFIED',
        minute: null,
        homeScore: 0,
        awayScore: 0,
        revision: 2,
        eventCount: 0,
        changedAt: now,
        events: const [],
      );
      await repository.persistTerminalObservations({
        matchId: update,
      }, includeLive: true);
      released.complete();
      final immediate = (await lateHttp).match(matchId)!;
      expect(immediate.status, 'VERIFIED');
      expect(immediate.score, '0 - 0');
      await repository.settleBackground();
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final reopened = ApiRepository(dio, db);
      final match = (await reopened.watchPublicMatchContext(matchId).first)
          .match(matchId)!;
      expect(match.status, 'VERIFIED');
      expect(match.score, '0 - 0');
      expect(match.json['liveRevision'], 2);
    },
  );

  test(
    'legacy and BE14 v3 detail envelopes survive reopening SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-be14-v3-',
      );
      addTearDown(() async {
        for (final entry in directory.listSync().whereType<File>()) {
          await entry.delete();
        }
        await directory.delete();
      });
      final file = File.fromUri(directory.uri.resolve('detail.sqlite'));
      final dio = Dio();
      addTearDown(dio.close);
      const timestamp = '2026-11-11T20:00:00Z';
      final legacy = detail(timestamp, cancelled: false);
      final versioned = {
        ...detail(null, cancelled: true),
        'detailLevel': 'live',
        'fetchedAt': null,
        'observedAt': timestamp,
        'live': null,
        'sections': {'events': 'd751713988987e9331980363e24189ce'},
      };
      final stamped = {
        ...versioned,
        'live': {
          'provider': 'goal_api',
          'revision': 3,
          'changedAt': timestamp,
          'status': 'VERIFIED',
        },
      };
      for (final (index, raw) in [legacy, versioned, stamped].indexed) {
        final id = '${matchId}_$index';
        final db = AppDatabase(NativeDatabase(file));
        try {
          final repository = ApiRepository(dio, db);
          repository.persistMatchDetail(
            id,
            MatchDetail({...raw, 'matchId': id}),
          );
          await repository.settleBackground();
        } finally {
          await db.close();
        }
        final reopened = AppDatabase(NativeDatabase(file));
        try {
          final restored = await ApiRepository(
            dio,
            reopened,
          ).readStoredMatchDetail(id);
          expect(restored, isNotNull);
          for (final key in ['observedAt', 'live', 'sections', 'fetchedAt']) {
            expect(restored!.sourceJson.containsKey(key), raw.containsKey(key));
            expect(restored.sourceJson[key], raw[key]);
          }
          expect(restored!.incidents, raw['incidents']);
        } finally {
          await reopened.close();
        }
      }
    },
  );

  test(
    'BE14 keeps omitted sections and rejects stale or incomparable clocks',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final repository = ApiRepository(dio, db);
      addTearDown(() async {
        await repository.settleBackground();
        dio.close();
        await db.close();
      });
      Json stamp(int? revision, [String provider = 'goal_api']) => {
        'provider': provider,
        'revision': revision,
        'changedAt': '2026-11-11T20:00:00Z',
      };
      Future<MatchDetail> save(Json raw) async {
        repository.persistMatchDetail(matchId, MatchDetail(raw));
        await repository.settleBackground();
        return (await repository.readStoredMatchDetail(matchId))!;
      }

      final first = detail(null, cancelled: false)
        ..addAll({
          'observedAt': '2026-11-11T20:00:00Z',
          'sections': {'events': 'a', 'lineup': 'a', 'statistics': 'a'},
          'live': stamp(4),
          'home': {
            'starters': [
              {'name': 'Titular'},
            ],
          },
        });
      await save(first);
      final partial = await save({
        ...detail(null, cancelled: true),
        'observedAt': '2026-11-11T20:02:00Z',
        'sections': {'statistics': 'b'},
        'live': stamp(5),
      });
      expect(partial.homeStarters.single['name'], 'Titular');
      expect(partial.statistics.single['home'], 2);
      expect(partial.incidents, hasLength(1));
      expect((partial.sourceJson['live'] as Map)['revision'], 4);

      for (final (observation, live) in [
        ('2026-11-11T20:01:00Z', stamp(6)),
        (null, stamp(6)),
        ('2026-11-11T20:03:00Z', stamp(null)),
        ('2026-11-11T20:04:00Z', stamp(99, 'other')),
        ('2026-11-11T20:05:00Z', stamp(3)),
      ]) {
        final rejected = await save({
          ...detail(null, cancelled: true),
          'observedAt': observation,
          'sections': {'events': 'b'},
          'live': live,
        });
        expect(rejected.incidents, hasLength(1));
      }
      final corrected = await save({
        ...detail(null, cancelled: true),
        'observedAt': '2026-11-11T20:06:00Z',
        'sections': {'events': 'b'},
        'live': stamp(6),
      });
      expect(corrected.incidents, isEmpty);
      expect(corrected.homeStarters.single['name'], 'Titular');
      expect(corrected.statistics.single['home'], 2);
    },
  );

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
              '/v1/match-preview' => {
                'matchId': matchId,
                'h2h': {'availability': 'AVAILABLE'},
              },
              '/v1/match-detail' => raw,
              _ => throw StateError('Unexpected route: ${options.path}'),
            };
            handler.resolve(
              Response(
                requestOptions: options,
                data: response,
                headers: Headers.fromMap({
                  if (options.path == '/v1/match-preview')
                    'cache-control': ['public, max-age=30'],
                }),
              ),
            );
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
            expect(requests, {'/v1/match-context': 10, '/v1/match-preview': 1});
            debugPrint(
              'MATCH-CACHE-01 opens=10 detail=0 context=10 preview=1 other=0',
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
        '/v1/match-preview': 1,
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

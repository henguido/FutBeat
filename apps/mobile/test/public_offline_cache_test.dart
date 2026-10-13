import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

Map<String, dynamic> _snapshot() => jsonDecode(
  File('assets/demo.snapshot.json')
      .readAsStringSync()
      .replaceFirst('"demo": true', '"demo": false'),
) as Map<String, dynamic>;

Dio _dio(Map<String, dynamic> Function(RequestOptions) answer) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        try {
          handler.resolve(
            Response(requestOptions: request, data: answer(request)),
          );
        } catch (_) {
          handler.reject(
            DioException(
              requestOptions: request,
              response: Response(requestOptions: request, statusCode: 503),
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

void main() {
  test('cached entity is visible before a slow network reply', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final gate = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          await gate.future;
          handler.resolve(Response(requestOptions: request, data: _snapshot()));
        },
      ),
    );
    try {
      await db.savePublicSnapshot(
        'public:entity:team:fb_team_sap',
        jsonEncode(_snapshot()),
      );
      final stream = ApiRepository(
        dio,
        db,
      ).watchPublicEntity('team', 'fb_team_sap');
      final first = await stream.first.timeout(const Duration(seconds: 2));
      expect(first.stale, true);
      expect(first.team('fb_team_sap'), isNotNull);
      gate.complete();
      final values = await ApiRepository(
        dio,
        db,
      ).watchPublicEntity('team', 'fb_team_sap').toList();
      expect(values.first.stale, true);
      expect(values.last.stale, false);
    } finally {
      if (!gate.isCompleted) gate.complete();
      dio.close();
      await db.close();
    }
  });

  test('503 leaves the cached match context visibly stale', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = _dio((_) => throw StateError('503'));
    try {
      await db.savePublicSnapshot(
        'public:match-context:fb_match_clasico',
        jsonEncode(_snapshot()),
      );
      final values = await ApiRepository(
        dio,
        db,
      ).watchPublicMatchContext('fb_match_clasico').toList();
      expect(values, hasLength(1));
      expect(values.single.stale, true);
      expect(values.single.match('fb_match_clasico'), isNotNull);
    } finally {
      dio.close();
      await db.close();
    }
  });

  test('an older HTTP response cannot replace a newer stored entity', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final newer = _snapshot()..['updatedAt'] = '2026-10-12T00:00:00Z';
    final older = _snapshot()..['updatedAt'] = '2026-09-15T00:00:00Z';
    final dio = _dio((_) => older);
    try {
      await db.savePublicSnapshot(
        'public:entity:team:fb_team_sap',
        jsonEncode(newer),
      );
      final repository = ApiRepository(dio, db);
      final values = await repository
          .watchPublicEntity('team', 'fb_team_sap')
          .toList();
      expect(values, hasLength(1));
      expect(values.single.stale, true);
      expect(values.single.updatedAt.toUtc(), DateTime.utc(2026, 10, 12));
      await repository.settleBackground();
      final stored = await db.readPublicSnapshot(
        'public:entity:team:fb_team_sap',
      );
      expect(
        (jsonDecode(stored!.payload) as Map<String, dynamic>)['updatedAt'],
        '2026-10-12T00:00:00Z',
      );
    } finally {
      dio.close();
      await db.close();
    }
  });

  test('expired public rows are removed without deleting Explore', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.saveCatalogSnapshot('explore:global', '{"ok":true}');
      await db.savePublicSnapshot('public:old', '{"ok":true}');
      await db.customStatement(
        'UPDATE catalog_snapshots SET saved_at = ? WHERE cache_key = ?',
        [
          DateTime.now()
                  .toUtc()
                  .subtract(const Duration(days: 8))
                  .millisecondsSinceEpoch ~/
              1000,
          'public:old',
        ],
      );
      expect(await db.readPublicSnapshot('public:old'), isNull);
      expect(await db.readCatalogEntry('public:old'), isNull);
      expect(await db.readCatalogEntry('explore:global'), isNotNull);
    } finally {
      await db.close();
    }
  });

  test('private fields are never persisted in public cache', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final raw = _snapshot();
    raw['access_token'] = 'test-only-secret';
    final dio = _dio((_) => raw);
    try {
      final repository = ApiRepository(dio, db);
      await repository.loadEntity('team', 'fb_team_sap');
      await repository.settleBackground();
      expect(
        await db.readPublicSnapshot('public:entity:team:fb_team_sap'),
        isNull,
      );
    } finally {
      dio.close();
      await db.close();
    }
  });

  test(
    'public profiles and match context survive process restart and 503',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-public-cache-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      var dio = _dio((_) => _snapshot());
      try {
        final online = ApiRepository(dio, db);
        expect((await online.loadEntity('team', 'fb_team_sap')).stale, false);
        expect(
          (await online.loadMatchContext('fb_match_clasico')).stale,
          false,
        );
        await online.settleBackground();
        await db.close();
        dio.close();

        db = AppDatabase(NativeDatabase(file));
        dio = _dio((_) => throw StateError('503'));
        final offline = ApiRepository(dio, db);
        final team = await offline.loadEntity('team', 'fb_team_sap');
        final match = await offline.loadMatchContext('fb_match_clasico');
        expect(team.stale, true);
        expect(team.team('fb_team_sap'), isNotNull);
        expect(match.stale, true);
        expect(match.match('fb_match_clasico'), isNotNull);
      } finally {
        dio.close();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('success after an offline answer replaces stale data', () async {
    final db = AppDatabase(NativeDatabase.memory());
    var failing = true;
    final dio = _dio((_) {
      if (failing) throw StateError('503');
      return _snapshot();
    });
    try {
      await db.savePublicSnapshot(
        'public:entity:team:fb_team_sap',
        jsonEncode(_snapshot()),
      );
      final repository = ApiRepository(dio, db);
      expect((await repository.loadEntity('team', 'fb_team_sap')).stale, true);
      failing = false;
      expect((await repository.loadEntity('team', 'fb_team_sap')).stale, false);
    } finally {
      dio.close();
      await db.close();
    }
  });

  test('a recent LIVE update wins over an offline match context', () {
    final raw = _snapshot();
    final match = (raw['matches'] as List).first as Map<String, dynamic>;
    match['status'] = 'LIVE';
    match['score'] = {'home': 0, 'away': 0};
    final cached = Snapshot(raw).asStale();
    final id = match['id'] as String;
    final now = DateTime.now().toUtc();
    final update = LiveMatchUpdate.fromJson({
      'match_id': id,
      'provider': 'goal_api',
      'external_match_id': 'fixture-1',
      'status': 'LIVE',
      'minute': 60,
      'home_score': 2,
      'away_score': 1,
      'revision': 9,
      'event_count': 0,
      'latest_events': <dynamic>[],
      'changed_at': now.toIso8601String(),
    }, receivedAt: now);
    final visible = cached.withLiveUpdates({id: update}, now: now);
    expect(visible.match(id)?.score, '2 - 1');
    expect(visible.stale, true);
  });

  test('demo answers are never persisted for offline use', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = _dio(
      (_) =>
          jsonDecode(File('assets/demo.snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
    );
    try {
      await expectLater(
        ApiRepository(dio, db).loadEntity('team', 'fb_team_sap'),
        throwsA(isA<StateError>()),
      );
      expect(
        await db.readPublicSnapshot('public:entity:team:fb_team_sap'),
        isNull,
      );
    } finally {
      dio.close();
      await db.close();
    }
  });

  test(
    'corrupt, wrong-identity and user-scoped entries are never shown',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = _dio((_) => throw StateError('offline'));
      try {
        await db.savePublicSnapshot(
          'public:entity:team:fb_team_sap',
          '{bad json',
        );
        final repository = ApiRepository(dio, db);
        await expectLater(
          repository.loadEntity('team', 'fb_team_sap'),
          throwsA(isA<DioException>()),
        );
        await db.savePublicSnapshot(
          'public:entity:team:fb_team_sap',
          jsonEncode({..._snapshot(), 'teams': <dynamic>[]}),
        );
        await expectLater(
          repository.loadEntity('team', 'fb_team_sap'),
          throwsA(isA<DioException>()),
        );
        await db.savePublicSnapshot('account:user-1', '{}');
        expect(await db.readPublicSnapshot('account:user-1'), isNull);
      } finally {
        dio.close();
        await db.close();
      }
    },
  );

  test('public partition is bounded and never evicts Explore', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.saveCatalogSnapshot('explore:global', '{"ok":true}');
      for (var i = 0; i < 40; i++) {
        await db.savePublicSnapshot('public:entity:team:fb_$i', '{"id":$i}');
      }
      final count = await (db.select(
        db.catalogSnapshots,
      )..where((row) => row.cacheKey.like('public:%'))).get();
      expect(count.length, maxPublicSnapshots);
      expect(await db.readCatalogEntry('explore:global'), isNotNull);
      await db.savePublicSnapshot(
        'public:large',
        'x' * (maxPublicSnapshotBytes + 1),
      );
      expect(await db.readPublicSnapshot('public:large'), isNull);
    } finally {
      await db.close();
    }
  });

  test(
    'match detail only persists available data with the requested identity',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = _dio((_) => throw StateError('offline'));
      try {
        final repository = ApiRepository(dio, db);
        repository.persistMatchDetail(
          'fb_a',
          const _DetailFixture('fb_b').value,
        );
        expect(await repository.readStoredMatchDetail('fb_a'), isNull);
        repository.persistMatchDetail(
          'fb_a',
          const _DetailFixture('fb_a').value,
        );
        await repository.settleBackground();
        final cached = await repository.readStoredMatchDetail('fb_a');
        expect(cached?.available, true);
        expect(cached?.offlineStale, true);
      } finally {
        dio.close();
        await db.close();
      }
    },
  );
}

class _DetailFixture {
  const _DetailFixture(this.id);
  final String id;
  MatchDetail get value => MatchDetail({
    'matchId': id,
    'available': true,
    'detailLevel': 'partial',
    'home': <String, dynamic>{},
    'away': <String, dynamic>{},
    'statistics': <dynamic>[],
    'incidents': <dynamic>[],
    'videos': <dynamic>[],
  });
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/qa_development.dart';

import 'support/stored_fixture_server.dart';

void main() {
  late StoredFixtureServer server;
  late Dio dio;
  late QaStoredReadInterceptor policy;
  final now = DateTime.utc(2026, 10, 31, 20);
  setUp(() async {
    server = await StoredFixtureServer.start();
    policy = QaStoredReadInterceptor(
      origin: server.origin,
      clock: () => now,
      sessionLimit: 30,
      minuteLimit: 8,
      concurrentLimit: 2,
      sessionDuration: const Duration(minutes: 15),
    );
    dio = Dio(BaseOptions(baseUrl: server.origin.toString()))
      ..httpClientAdapter = StoredFixtureWire(server.server.port)
      ..interceptors.add(policy);
  });
  tearDown(() async {
    policy.close();
    dio.close(force: true);
    await server.close();
  });

  test('stored LIVE preserves stale age, accepts score correction and recovery', () async {
    final match = <String, dynamic>{
      'id': 'fb_match_synthetic243',
      'competitionId': 'fb_comp_synthetic',
      'homeTeamId': 'fb_team_h',
      'awayTeamId': 'fb_team_a',
      'startTime': now.subtract(const Duration(hours: 1)).toIso8601String(),
      'status': 'LIVE',
      'score': {'home': 2, 'away': 1},
      'liveObservedAt': now.toIso8601String(),
    };
    server.payloads['/v1/qa-stored/match-context'] = {
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': now.toIso8601String(),
      'teams': [
        {'id': 'fb_team_h', 'name': 'Synthetic H'},
        {'id': 'fb_team_a', 'name': 'Synthetic A'},
      ],
      'competitions': [
        {'id': 'fb_comp_synthetic', 'name': 'Synthetic'},
      ],
      'players': [],
      'matches': [match],
      'standings': [],
    };
    Future<FootballMatch> read() async {
      final response = await dio.get<Map<String, dynamic>>('/v1/match-context');
      return Snapshot(response.data!).match('fb_match_synthetic243')!;
    }

    expect((await read()).liveDataStaleAt(now), isFalse);
    match['liveObservedAt'] = now
        .subtract(const Duration(minutes: 20))
        .toIso8601String();
    expect((await read()).liveDataStaleAt(now), isTrue);
    server.status = 503;
    await expectLater(read(), throwsA(isA<DioException>()));
    expect(
      server.requests.length,
      3,
    ); // No automatic retry or ordinary-route fallback.
    server.status = 200;
    match['score'] = {
      'home': 1,
      'away': 1,
    }; // Verified correction, not monotonic score.
    match['liveObservedAt'] = now.toIso8601String();
    final corrected = await read();
    expect(corrected.score, '1 - 1');
    expect(corrected.liveDataStaleAt(now), isFalse);
    expect(policy.counters, {'requests': 4, 'active': 0, 'blocked': 0});
    expect(
      server.requests.every((uri) => uri.path == '/v1/qa-stored/match-context'),
      isTrue,
    );
    expect(server.bytes, greaterThan(0));
    // Local server handling only; not Android, Internet or TLS latency.
    debugPrint(
      'MOBILE243_LOOPBACK requests=${server.requests.length} bytes=${server.bytes} serverMicros=${server.elapsedMicros}',
    );
  });
  for (final state in ['available', 'unavailable']) {
    test(
      'stored table $state survives HTTP to SQLite with explicit coverage',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final rows = state == 'available'
            ? [
                {
                  'competitionId': 'fb_comp_synthetic',
                  'season': '2026',
                  'rows': [
                    {
                      'teamId': 'fb_team_h',
                      'position': 1,
                      'played': 1,
                      'points': 3,
                      'won': 1,
                      'drawn': 0,
                      'lost': 0,
                      'gf': 1,
                      'ga': 0,
                    },
                  ],
                },
              ]
            : <Map<String, dynamic>>[];
        server.payloads['/v1/qa-stored/match-context'] = {
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': now.toIso8601String(),
          'teams': [],
          'players': [],
          'competitions': [],
          'matches': [
            {
              'id': 'fb_match_synthetic243',
              'competitionId': 'fb_comp_synthetic',
              'homeTeamId': 'fb_team_h',
              'awayTeamId': 'fb_team_a',
              'startTime': now.toIso8601String(),
              'status': 'SCHEDULED',
            },
          ],
          'standings': rows,
          'coverage': {'standings': state},
        };
        final repository = ApiRepository(dio, db);
        final answer = await repository.loadMatchContext(
          'fb_match_synthetic243',
        );
        expect(answer.standingsState, state);
        expect(answer.standings.length, state == 'available' ? 1 : 0);
        await repository.settleBackground();
        final saved = await db.readPublicSnapshot(
          'public:match-context:fb_match_synthetic243',
        );
        expect(saved, isNotNull);
        final stored = Snapshot(
          jsonDecode(saved!.payload) as Map<String, dynamic>,
        );
        expect(stored.standings, answer.standings);
        expect(stored.standingsState, state);
        expect(server.requests, hasLength(1));
        expect(policy.counters['active'], 0);
      },
    );
  }
}

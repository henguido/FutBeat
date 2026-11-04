import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/player_display_identity.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_diagnostics.dart';

const _id = 'fb_match_boundary261';
Json _snapshot(
  DateTime now, {
  String status = 'LIVE',
  bool localMarker = false,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': now.toIso8601String(),
  'teams': [
    {'id': 'fb_team_h', 'name': 'Local fixture'},
    {'id': 'fb_team_a', 'name': 'Visita fixture'},
  ],
  'competitions': [
    {'id': 'fb_comp_c', 'name': 'Competición fixture'},
  ],
  'players': <Json>[],
  'standings': <Json>[],
  'matches': [
    {
      'id': _id,
      'homeTeamId': 'fb_team_h',
      'awayTeamId': 'fb_team_a',
      'competitionId': 'fb_comp_c',
      'startTime': now.subtract(const Duration(hours: 2)).toIso8601String(),
      'status': status,
      'minute': 89,
      'score': {'home': status == 'LIVE' ? 1 : 2, 'away': 0},
      'events': <Json>[],
      if (localMarker) localTerminalObservationKey: true,
    },
  ],
};
LiveMatchUpdate _terminal(DateTime now, {bool private = false}) =>
    LiveMatchUpdate.fromJson({
      'match_id': _id,
      'provider': 'fixture',
      'external_match_id': 'fixture-boundary',
      'status': 'VERIFIED',
      'minute': 90,
      'home_score': 3,
      'away_score': 0,
      'revision': 3,
      'event_count': private ? 1 : 0,
      'changed_at': now.toIso8601String(),
      'provider_observed_at': now.toIso8601String(),
      'latest_events': private
          ? <Json>[
              {
                'id': 'fb_event_private_fixture',
                'matchId': _id,
                'type': 'GOAL',
                'token': 'synthetic-private-token',
                'email': 'fixture@invalid.test',
              },
            ]
          : <Json>[],
    }, receivedAt: now);

void main() {
  test('R06: rejected private event cannot reach SQLite through a later calendar refresh', () async {
    final now = DateTime.now().toUtc();
    final date = DateTime.utc(now.year, now.month, now.day);
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    addTearDown(db.close);
    addTearDown(() => dio.close(force: true));
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          calls++;
          handler.resolve(
            Response(requestOptions: request, data: _snapshot(now)),
          );
        },
      ),
    );
    final records = <String>[];
    final metrics = QaDiagnostics(
      onRecord: (endpoint, event, ms, bytes) => records.add('$endpoint:$event'),
    );
    final repo = ApiRepository(
      dio,
      db,
      const CalendarCachePolicy(),
      null,
      metrics,
    );
    await repo.loadDate(date);
    await repo.settleBackground();
    await repo.persistTerminalObservations({
      _id: _terminal(now, private: true),
    });
    expect(
      (await db.readCalendarSnapshot(key))!.contains('synthetic-private-token'),
      isFalse,
    );
    expect(
      (metrics.snapshot()['counts']
          as Map)['/local/terminal:sqliteWriteRejected'],
      1,
    );
    repo.refreshDate(date);
    await repo.loadDate(date);
    await repo.settleBackground();
    final payload = (await db.readCalendarSnapshot(key))!;
    expect(payload.contains('synthetic-private-token'), isFalse);
    expect(payload.contains('fixture@invalid.test'), isFalse);
    expect(records.join().contains('synthetic-private-token'), isFalse);
    expect(records.join().contains('fixture@invalid.test'), isFalse);
    expect(calls, 2, reason: 'Only the two explicit synthetic calendar reads');
  });
  for (final route in ['catalog', 'adjudicated-entity']) {
    test('$route: network marker cannot weaken a canonical terminal', () async {
      final now = DateTime.now().toUtc();
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() => dio.close(force: true));
      final raw = _snapshot(now, status: 'VERIFIED', localMarker: true);
      final decision = adjudicatedPlayerDisplayAliases.first;
      if (route == 'adjudicated-entity') {
        raw['entityRedirects'] = {decision.aliasId: decision.visibleId};
        raw['players'] = [
          {'id': decision.visibleId, 'name': 'Synthetic redirect fixture'},
        ];
      }
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            calls++;
            handler.resolve(Response(requestOptions: request, data: raw));
          },
        ),
      );
      final repo = ApiRepository(dio);
      final snapshot = route == 'catalog'
          ? await repo.searchCatalog('fixture', null)
          : await repo.loadEntity('player', decision.aliasId);
      expect(
        snapshot.match(_id)!.json.containsKey(localTerminalObservationKey),
        isFalse,
      );
      final after = snapshot.withLiveUpdates({
        _id: _terminal(now.add(const Duration(seconds: 20))),
      });
      expect(after.match(_id)!.json['score']['home'], 2);
      expect(calls, 1);
      expect(
        jsonEncode(raw).contains(localTerminalObservationKey),
        isTrue,
        reason: 'The untrusted input is retained solely as a fixture; reader must sanitize its own result',
      );
    });
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

Json row(int revision, List<Json> events) => {
  'match_id': 'fb_match_clasico',
  'provider': 'api_football',
  'external_match_id': '123',
  'status': 'LIVE',
  'minute': 63,
  'home_score': 1,
  'away_score': 0,
  'revision': revision,
  'event_count': events.length,
  'latest_events': events,
  'changed_at': '2026-09-16T16:00:00Z',
};
final goal = <String, dynamic>{
  'id': 'fb_event_goal',
  'matchId': 'fb_match_clasico',
  'type': 'GOAL',
  'minute': 63,
  'teamId': 'fb_team_lda',
};

void main() {
  test('snapshot preserves canonical entity redirects across LIVE overlays', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    raw['demo'] = false;
    raw['entityRedirects'] = {
      'fb_team_legacy_sap': 'fb_team_sap',
    };

    final snapshot = Snapshot(raw);
    expect(snapshot.resolveEntityId('fb_team_legacy_sap'), 'fb_team_sap');
    expect(snapshot.resolveEntityId('fb_team_sap'), 'fb_team_sap');

    final merged = snapshot.withLiveUpdates({
      'fb_match_clasico': LiveMatchUpdate.fromJson(row(2, [goal])),
    });
    expect(merged.resolveEntityId('fb_team_legacy_sap'), 'fb_team_sap');
  });

  test('snapshot merge deduplicates canonical events and rejects unrelated fixture events', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    final snapshot = Snapshot({...raw, 'demo': false});
    final update = LiveMatchUpdate.fromJson(
      row(2, [
        goal,
        goal,
        {...goal, 'id': 'fb_event_wrong', 'matchId': 'fb_match_other'},
      ]),
    );
    final first = snapshot.withLiveUpdates({'fb_match_clasico': update});
    final again = first.withLiveUpdates({'fb_match_clasico': update});
    expect(
      again
          .match('fb_match_clasico')!
          .events
          .where((e) => e['id'] == 'fb_event_goal')
          .length,
      1,
    );
    expect(
      again
          .match('fb_match_clasico')!
          .events
          .where((e) => e['id'] == 'fb_event_wrong'),
      isEmpty,
    );
    expect(
      again.match('fb_match_clasico')!.events.length,
      first.match('fb_match_clasico')!.events.length,
    );
    final old = LiveMatchUpdate.fromJson(row(1, []));
    expect(
      again
          .withLiveUpdates({'fb_match_clasico': old})
          .match('fb_match_clasico')!
          .json['liveRevision'],
      2,
    );
  });
  test('newer canonical terminal state cannot be reopened by a stale LIVE overlay', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    raw['demo'] = false;
    final matches = raw['matches'] as List;
    final canonical = Map<String, dynamic>.from(
      matches.firstWhere((item) => item['id'] == 'fb_match_clasico') as Map,
    )
      ..['status'] = 'VERIFIED'
      ..['minute'] = null
      ..['score'] = {'home': 2, 'away': 1}
      ..['provenance'] = {
        'source': 'GOAL API',
        'receivedAt': '2026-09-18T13:16:26.355Z',
        'verificationStatus': 'PROVISIONAL',
      };
    matches[matches.indexWhere((item) => item['id'] == 'fb_match_clasico')] =
        canonical;

    final snapshot = Snapshot(raw);
    final stale = LiveMatchUpdate.fromJson({
      ...row(9, [goal]),
      'minute': 55,
      'home_score': 1,
      'away_score': 0,
      'changed_at': '2026-09-17T18:20:02.432Z',
    });

    final reconciled = snapshot.withLiveUpdates({
      'fb_match_clasico': stale,
    });
    final match = reconciled.match('fb_match_clasico')!;

    expect(match.status, 'VERIFIED');
    expect(match.score, '2 - 1');
    expect(match.json['liveRevision'], isNull);
  });

  test('stale LIVE data is visible instead of pretending to be current', () {
    final stale = FootballMatch({
      'id': 'fb_match_stale',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-09-18T18:00:00Z',
      'status': 'LIVE',
      'score': {'home': 1, 'away': 0},
      'minute': 55,
      'liveChangedAt': DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 20))
          .toIso8601String(),
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    });
    final fresh = FootballMatch({
      ...stale.json,
      'liveChangedAt': DateTime.now().toUtc().toIso8601String(),
    });

    expect(stale.liveDataStale, isTrue);
    expect(stale.statusLabel, contains('datos atrasados'));
    expect(fresh.liveDataStale, isFalse);
    expect(fresh.statusLabel, isNot(contains('datos atrasados')));
  });

  test('timeline orders stoppage time deterministically and exposes the latest event', () {
    final match = FootballMatch({
      'id': 'fb_match_test',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-09-18T18:00:00Z',
      'status': 'LIVE',
      'score': {'home': 1, 'away': 0},
      'minute': 45,
      'events': [
        {
          'id': 'fb_event_var',
          'type': 'VAR',
          'minute': 45,
          'extraMinute': 2,
        },
        {
          'id': 'fb_event_goal',
          'type': 'GOAL',
          'minute': 45,
          'extraMinute': 1,
        },
        {'id': 'fb_event_kickoff', 'type': 'KICKOFF', 'minute': 0},
      ],
      'statistics': [],
    });

    expect(
      match.events.map((event) => event['id']).toList(),
      ['fb_event_kickoff', 'fb_event_goal', 'fb_event_var'],
    );
    expect(eventMinuteLabel(match.events[1]), '45+1′');
    expect(eventMinuteLabel(match.events[2]), '45+2′');
    expect(match.latestEvent?['id'], 'fb_event_var');
  });

  test('MatchDetail exposes normalized stats lineups and incidents', () {
    final detail = MatchDetail({
      'matchId': 'fb_match_test',
      'available': true,
      'pending': false,
      'detailLevel': 'full',
      'referee': 'Ref Test',
      'stadium': 'Estadio Test',
      'round': '9',
      'home': {
        'formation': '4-3-3',
        'starters': [
          {
            'id': 'p1',
            'name': 'Home One',
            'number': '9',
            'position': 'Forward',
          },
        ],
        'substitutes': <dynamic>[],
      },
      'away': {
        'formation': '4-2-3-1',
        'starters': [
          {
            'id': 'p2',
            'name': 'Away One',
            'number': '1',
            'position': 'Goalkeeper',
          },
        ],
        'substitutes': <dynamic>[],
      },
      'statistics': [
        {'label': 'Ball Possession', 'home': '55%', 'away': '45%'},
      ],
      'incidents': [
        {
          'type': 'YELLOW_CARD',
          'minute': 44,
          'label': 'Yellow Card',
          'detail': 'Home One',
        },
      ],
    });

    expect(detail.available, isTrue);
    expect(detail.pending, isFalse);
    expect(detail.homeFormation, '4-3-3');
    expect(detail.awayFormation, '4-2-3-1');
    expect(detail.homeStarters.single['name'], 'Home One');
    expect(detail.statistics.single['home'], '55%');
    expect(detail.incidents.single['minute'], 44);
    expect(detail.referee, 'Ref Test');
  });

  test('unified timeline keeps synthetic phases and prefers richer detail incidents', () {
    final match = FootballMatch({
      'id': 'fb_match_test',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-09-18T18:00:00Z',
      'status': 'LIVE',
      'score': {'home': 1, 'away': 0},
      'minute': 63,
      'events': [
        {'id': 'kickoff', 'type': 'KICKOFF', 'minute': 0},
        {'id': 'goal-live', 'type': 'GOAL', 'minute': 63},
      ],
      'statistics': [],
    });
    final detail = MatchDetail({
      'matchId': 'fb_match_test',
      'available': true,
      'pending': false,
      'detailLevel': 'full',
      'home': <String, dynamic>{},
      'away': <String, dynamic>{},
      'statistics': <dynamic>[],
      'incidents': [
        {
          'type': 'YELLOW_CARD',
          'minute': 44,
          'label': 'Tarjeta amarilla',
          'detail': 'Jugador local',
        },
        {
          'type': 'GOAL',
          'minute': 63,
          'label': 'Gol',
          'detail': 'Goleador · Asistencia: Compañero · 1-0',
        },
      ],
    });

    final timeline = mergedMatchTimeline(match, detail);

    expect(
      timeline.map((event) => event['type']).toList(),
      ['KICKOFF', 'YELLOW_CARD', 'GOAL'],
    );
    expect(
      timeline.where((event) => event['type'] == 'GOAL').length,
      1,
    );
    expect(
      timeline.last['detail'],
      contains('Goleador'),
    );
  });

  test('Realtime reconnect bootstraps missing events and ignores repeated/older revisions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var revision = 1, connections = 0;
    final sockets = <WebSocket>[];
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        sockets.add(ws);
        connections++;
        ws.listen((raw) {
          final message = jsonDecode(raw as String) as Map;
          if (message['event'] == 'phx_join') {
            ws.add(
              jsonEncode({
                'event': 'phx_reply',
                'ref': message['ref'],
                'payload': {'status': 'ok'},
              }),
            );
          }
        });
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            row(revision, revision > 1 ? [goal] : []),
          ]),
        );
        await request.response.close();
      }
    });
    final dio = Dio();
    final client = LiveRealtimeClient(
      LiveRealtimeConfig(
        supabaseUrl: 'http://127.0.0.1:${server.port}',
        publicKey: 'test',
      ),
      dio,
      retryDelay: const Duration(milliseconds: 20),
      refreshInterval: const Duration(hours: 1),
    );
    final seen = <LiveMatchUpdate>[];
    final first = Completer<void>(), second = Completer<void>();
    final subscription = client.watch().listen((rows) {
      final value = rows['fb_match_clasico'];
      if (value == null) return;
      seen.add(value);
      if (value.revision == 1 && !first.isCompleted) first.complete();
      if (value.revision == 2 && connections >= 2 && !second.isCompleted) {
        second.complete();
      }
    });
    try {
      await first.future.timeout(const Duration(seconds: 5));
      while (sockets.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      revision = 2;
      await sockets.first.close();
      await second.future.timeout(const Duration(seconds: 5));
      expect(connections, greaterThanOrEqualTo(2));
      sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'UPDATE', 'record': row(1, [])},
          },
        }),
      );
      sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {
              'type': 'UPDATE',
              'record': row(2, [goal]),
            },
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last.revision, 2);
      expect(seen.last.events.length, 1);
    } finally {
      await subscription.cancel();
      for (final ws in sockets) {
        await ws.close();
      }
      dio.close(force: true);
      await server.close(force: true);
    }
  });
}

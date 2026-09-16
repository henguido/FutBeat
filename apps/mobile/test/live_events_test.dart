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

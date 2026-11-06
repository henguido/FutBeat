import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Local LIVE fixture did not reach its milestone');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Json _canonical(String id) => {
  'id': id,
  'competitionId': 'fb_comp_synthetic244',
  'homeTeamId': 'fb_team_home',
  'awayTeamId': 'fb_team_away',
  'startTime': DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 4))
      .toIso8601String(),
  'status': 'SCHEDULED',
  'events': <Json>[],
};

void main() {
  for (final skew in [const Duration(hours: -2), const Duration(hours: 2)]) {
    test(
      'Realtime uses learned server clock for fresh and stale observations ($skew)',
      () async {
        const id = 'fb_match_clock244';
        const oldId = 'fb_match_replay244';
        DateTime serverNow() => DateTime.now().toUtc().add(skew);
        final server = FakeSupabase([liveRow(id, updatedAt: serverNow())]);
        await server.start();
        addTearDown(server.stop);
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onResponse: (response, handler) {
              // Model a real HTTP Date from a server whose clock differs from the
              // device. Only this loopback response is changed; no system clock edit.
              response.headers.set(
                HttpHeaders.dateHeader,
                HttpDate.format(serverNow()),
              );
              handler.next(response);
            },
          ),
        );
        addTearDown(() => dio.close(force: true));
        final client = LiveRealtimeClient(
          LiveRealtimeConfig(
            supabaseUrl: server.url,
            publicKey: 'local-fixture',
          ),
          dio,
          scopedRealtime: true,
          refreshInterval: const Duration(hours: 1),
        )..setScope('match:open', [id, oldId]);
        var latest = <String, LiveMatchUpdate>{};
        final subscription = client.watch().listen(
          (updates) => latest = updates,
        );
        addTearDown(() async {
          await subscription.cancel();
          client.dispose();
        });
        await _until(
          () => latest[id]?.revision == 1 && server.restRequests.length >= 2,
        );
        void send(Json row) => server.sockets.last.add(
          jsonEncode({
            'event': 'postgres_changes',
            'payload': {
              'data': {'type': 'UPDATE', 'record': row},
            },
          }),
        );
        final fresh = serverNow();
        send(liveRow(id, updatedAt: fresh, revision: 2, home: 1));
        await _until(() => latest[id]?.revision == 2);
        final shown = FootballMatch(latest[id]!.applyTo(_canonical(id)));
        expect(shown.score, '1 - 0');
        expect(shown.liveDataStaleAt(DateTime.now()), isFalse);
        send(
          liveRow(
            oldId,
            updatedAt: fresh.subtract(const Duration(minutes: 20)),
          ),
        );
        await _until(() => latest.containsKey(oldId));
        final replayed = FootballMatch(
          latest[oldId]!.applyTo(_canonical(oldId)),
        );
        expect(replayed.liveDataStaleAt(DateTime.now()), isTrue);
        // A correction may decrease the score; the server observation, not
        // websocket delivery or a monotonically increasing score, is authoritative.
        send(
          liveRow(
            id,
            updatedAt: fresh.add(const Duration(seconds: 1)),
            revision: 3,
            home: 0,
          ),
        );
        await _until(() => latest[id]?.revision == 3);
        final corrected = FootballMatch(latest[id]!.applyTo(shown.json));
        expect(corrected.score, '0 - 0');
        expect(corrected.liveDataStaleAt(DateTime.now()), isFalse);
        send(liveRow(id, updatedAt: fresh, revision: 2, home: 1));
        // Ordered WebSocket frames: the following new key is an acknowledgement
        // that the older revision above has been handled without a timed guess.
        send(liveRow(oldId, updatedAt: fresh, revision: 2));
        await _until(() => latest[oldId]?.revision == 2);
        expect(latest[id]?.revision, 3);
        expect(latest[id]?.homeScore, 0);
      },
    );
  }
}

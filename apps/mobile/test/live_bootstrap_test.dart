import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

/// `live_match_updates` row as PostgREST returns it.
Json liveRow(
  String id, {
  String status = 'LIVE',
  int revision = 1,
  int home = 0,
  int away = 0,
  required DateTime updatedAt,
  DateTime? changedAt,
}) => {
  'match_id': id,
  'provider': 'goal_api',
  'external_match_id': 'ext-$id',
  'status': status,
  'minute': status == 'LIVE' ? 30 : null,
  'home_score': home,
  'away_score': away,
  'revision': revision,
  'event_count': 0,
  'latest_events': <dynamic>[],
  'changed_at': (changedAt ?? updatedAt).toUtc().toIso8601String(),
  'updated_at': updatedAt.toUtc().toIso8601String(),
};

/// Minimal PostgREST + Realtime double: `updated_at=gte.`, `match_id=gt.`,
/// `order=match_id.asc`, `limit`, and the server row cap (max-rows).
class FakeSupabase {
  FakeSupabase(
    Iterable<Json> rows, {
    this.maxRows = 1000,
    this.realtime = true,
    this.sendDate = true,
  }) {
    for (final row in rows) {
      this.rows[row['match_id'] as String] = row;
    }
  }

  final Map<String, Json> rows = {};
  final int maxRows;
  final bool realtime;
  final bool sendDate;
  final List<Uri> restRequests = [];
  final Set<int> failingRequests = {};
  final List<WebSocket> sockets = [];
  void Function(int request)? beforeAnswer;
  late HttpServer server;

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        if (!realtime) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        sockets.add(ws);
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
        return;
      }
      final index = restRequests.length;
      restRequests.add(request.uri);
      beforeAnswer?.call(index);
      if (sendDate) {
        request.response.headers.date = DateTime.now().toUtc();
      } else {
        request.response.headers.removeAll(HttpHeaders.dateHeader);
      }
      if (failingRequests.contains(index)) {
        request.response.statusCode = 503;
        request.response.write('{"message":"unavailable"}');
        await request.response.close();
        return;
      }
      final q = request.uri.queryParameters;
      var result = rows.values.toList();
      final since = q['changed_at'];
      if (since != null) {
        final from = DateTime.parse(since.substring('gte.'.length));
        result = result
            .where((r) => !DateTime.parse(r['changed_at']).isBefore(from))
            .toList();
      }
      final after = q['match_id'];
      if (after != null) {
        final cursor = after.substring('gt.'.length);
        result = result
            .where((r) => (r['match_id'] as String).compareTo(cursor) > 0)
            .toList();
      }
      if (q['order'] == 'match_id.asc') {
        result.sort(
          (a, b) => (a['match_id'] as String).compareTo(b['match_id']),
        );
      }
      final limit = int.tryParse(q['limit'] ?? '') ?? maxRows;
      result = result.take(limit < maxRows ? limit : maxRows).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
  }

  Future<void> stop() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await server.close(force: true);
  }
}

LiveMatchUpdate overlay(
  String id, {
  String status = 'LIVE',
  int revision = 1,
  required DateTime receivedAt,
}) => LiveMatchUpdate.fromJson(
  liveRow(id, status: status, revision: revision, updatedAt: receivedAt),
  receivedAt: receivedAt,
);

void main() {
  final now = DateTime.now().toUtc();
  const policy = LiveBootstrapPolicy();
  String id(int i) => 'fb_match_${i.toString().padLeft(5, '0')}';

  group('fetchLiveBootstrap', () {
    test(
      'more than 1000 rows: every row of the window, paged, no duplicates',
      () async {
        final server = FakeSupabase([
          for (var i = 0; i < 2600; i++)
            liveRow(id(i), updatedAt: now.subtract(Duration(minutes: i % 600))),
          // Outside the 72 h window: never read.
          for (var i = 2600; i < 7600; i++)
            liveRow(
              id(i),
              status: 'VERIFIED',
              updatedAt: now.subtract(const Duration(days: 10)),
            ),
        ]);
        await server.start();
        final dio = Dio();
        try {
          final config = LiveRealtimeConfig(
            supabaseUrl: server.url,
            publicKey: 'test',
          );
          // The previous request (select=*, no filter) is capped: partial.
          final legacy = await dio.getUri<dynamic>(config.restUri);
          expect((legacy.data as List).length, 1000);

          final read = await fetchLiveBootstrap(
            dio,
            config,
            policy,
            since: now.subtract(policy.window),
          );
          expect(read.complete, isTrue);
          expect(read.serverNow, isNotNull);
          expect(read.rows.length, 2600);
          final ids = read.rows.map((r) => r['match_id']).toSet();
          expect(ids.length, 2600, reason: 'no duplicates across pages');
          // 2600 / 250 = 10 full pages + 1 short page (the last one).
          expect(server.restRequests.length, 1 + 11);
          final page = server.restRequests.last.queryParameters;
          expect(page['order'], 'match_id.asc');
          expect(page['limit'], '250');
          expect(page['select'], liveBootstrapColumns);
          expect(page['changed_at'], startsWith('gte.'));
          expect(page.containsKey('updated_at'), isFalse);
          expect(page['match_id'], 'gt.${id(2499)}');
        } finally {
          dio.close(force: true);
          await server.stop();
        }
      },
    );

    test('paging ends on the first short page (page size far below the '
        '1000-row cap)', () async {
      final server = FakeSupabase([
        for (var i = 0; i < 600; i++) liveRow(id(i), updatedAt: now),
      ], maxRows: 1000);
      await server.start();
      final dio = Dio();
      try {
        final read = await fetchLiveBootstrap(
          dio,
          LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
          const LiveBootstrapPolicy(pageSize: 250),
          since: now.subtract(const Duration(hours: 1)),
        );
        expect(read.complete, isTrue);
        expect(read.rows.length, 600);
        expect(server.restRequests.length, 3);
      } finally {
        dio.close(force: true);
        await server.stop();
      }
    });

    test('a failure after the first page is a partial read; on the first '
        'page it throws', () async {
      final server = FakeSupabase([
        for (var i = 0; i < 900; i++) liveRow(id(i), updatedAt: now),
      ])..failingRequests.add(2);
      await server.start();
      final dio = Dio();
      final config = LiveRealtimeConfig(
        supabaseUrl: server.url,
        publicKey: 't',
      );
      try {
        final read = await fetchLiveBootstrap(
          dio,
          config,
          policy,
          since: now.subtract(policy.window),
        );
        expect(read.complete, isFalse);
        expect(read.rows.length, 500);

        server.failingRequests.add(3);
        await expectLater(
          fetchLiveBootstrap(
            dio,
            config,
            policy,
            since: now.subtract(policy.window),
          ),
          throwsA(isA<DioException>()),
        );
      } finally {
        dio.close(force: true);
        await server.stop();
      }
    });

    test(
      'rows inserted or updated between pages are never duplicated',
      () async {
        final server = FakeSupabase([
          for (var i = 0; i < 600; i++) liveRow(id(i * 2), updatedAt: now),
        ]);
        server.beforeAnswer = (request) {
          if (request == 1) {
            // Behind the cursor (not re-read) and ahead of it (read once).
            server.rows[id(1)] = liveRow(id(1), updatedAt: now);
            server.rows[id(1101)] = liveRow(id(1101), updatedAt: now);
            server.rows[id(0)] = liveRow(id(0), revision: 2, updatedAt: now);
          }
        };
        await server.start();
        final dio = Dio();
        try {
          final read = await fetchLiveBootstrap(
            dio,
            LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
            policy,
            since: now.subtract(policy.window),
          );
          final ids = read.rows.map((r) => r['match_id']).toList();
          expect(ids.toSet().length, ids.length);
          expect(ids, contains(id(1101)));
        } finally {
          dio.close(force: true);
          await server.stop();
        }
      },
    );
  });

  group('reconcileLiveBootstrapSnapshot (windowed, partial-aware)', () {
    Map<String, LiveMatchUpdate> reconcile(
      Map<String, LiveMatchUpdate> current,
      List<Json> rows, {
      required bool complete,
    }) => reconcileLiveBootstrapSnapshot(
      current,
      rows,
      keysBeforeRequest: current.keys.toSet(),
      serverNow: now,
      deviceNow: now,
      complete: complete,
      removableSince: now.subtract(policy.window).add(policy.removalMargin),
    );

    test('a partial answer never removes an overlay', () {
      final current = {
        for (var i = 0; i < 5; i++)
          id(i): overlay(
            id(i),
            receivedAt: now.subtract(const Duration(minutes: 2)),
          ),
      };
      final result = reconcile(current, [
        liveRow(id(0), revision: 2, home: 1, updatedAt: now),
      ], complete: false);
      expect(result.keys, containsAll(current.keys));
      expect(result[id(0)]!.homeScore, 1);
    });

    test('complete paged REST does not erase an existing key refreshed by '
        'Realtime after its cursor passed', () {
      final matchId = id(7);
      final before = {
        matchId: overlay(
          matchId,
          receivedAt: now.subtract(const Duration(hours: 2)),
        ),
      };
      final realtime = LiveMatchUpdate.fromJson(
        liveRow(matchId, revision: 2, home: 1, updatedAt: now),
        receivedAt: now,
      );
      final result = reconcileLiveBootstrapSnapshot(
        {matchId: realtime},
        const <Json>[],
        stateBeforeRequest: before,
        serverNow: now,
        deviceNow: now,
        complete: true,
        removableSince: now.subtract(const Duration(hours: 71)),
      );
      expect(result[matchId]?.revision, 2);
      expect(result[matchId]?.homeScore, 1);

      final unchanged = reconcileLiveBootstrapSnapshot(
        before,
        const <Json>[],
        stateBeforeRequest: before,
        serverNow: now,
        deviceNow: now,
        complete: true,
        removableSince: now.subtract(const Duration(hours: 71)),
      );
      expect(unchanged.containsKey(matchId), isFalse);
    });

    test('a complete answer removes in-window overlays the server deleted '
        '(prune), and keeps those outside the window', () {
      final current = {
        'fb_match_pruned': overlay(
          'fb_match_pruned',
          receivedAt: now.subtract(const Duration(minutes: 20)),
        ),
        'fb_match_kept': overlay(
          'fb_match_kept',
          receivedAt: now.subtract(const Duration(minutes: 1)),
        ),
        // LIVE outside the window (e.g. stuck four days ago): not asked
        // for, so kept; the overlay already ignores it (staleAfter).
        'fb_match_old_live': overlay(
          'fb_match_old_live',
          receivedAt: now.subtract(const Duration(days: 4)),
        ),
        'fb_match_old_final': overlay(
          'fb_match_old_final',
          status: 'VERIFIED',
          receivedAt: now.subtract(const Duration(days: 5)),
        ),
        // At the window edge: within the margin, never removed.
        'fb_match_edge': overlay(
          'fb_match_edge',
          receivedAt: now
              .subtract(policy.window)
              .add(const Duration(minutes: 5)),
        ),
      };
      final result = reconcile(current, [
        liveRow('fb_match_kept', revision: 2, updatedAt: now),
      ], complete: true);
      expect(result.containsKey('fb_match_pruned'), isFalse);
      expect(
        result.keys,
        containsAll(<String>[
          'fb_match_kept',
          'fb_match_old_live',
          'fb_match_old_final',
          'fb_match_edge',
        ]),
      );
      final match = {
        'id': 'fb_match_old_live',
        'status': 'SCHEDULED',
        'homeTeamId': 'h',
        'awayTeamId': 'a',
      };
      expect(
        identical(result['fb_match_old_live']!.applyTo(match, now: now), match),
        isTrue,
        reason: 'a stale LIVE overlay never changes the match',
      );
    });

    test('goal corrections: a newer revision replaces the score, an older '
        'one is ignored', () {
      var state = <String, LiveMatchUpdate>{};
      state = reconcile(state, [
        liveRow(id(1), revision: 5, home: 2, away: 1, updatedAt: now),
      ], complete: true);
      // Annulled goal: revision 6 back to 1-1.
      state = reconcile(state, [
        liveRow(id(1), revision: 6, home: 1, away: 1, updatedAt: now),
      ], complete: true);
      expect([state[id(1)]!.homeScore, state[id(1)]!.awayScore], [1, 1]);
      // A late, older row (revision 5) does not bring the 2-1 back.
      state = reconcile(state, [
        liveRow(id(1), revision: 5, home: 2, away: 1, updatedAt: now),
      ], complete: true);
      expect(state[id(1)]!.revision, 6);
      expect(state[id(1)]!.homeScore, 1);
    });

    test('a finished match overlays its terminal state', () {
      final state = reconcile(const {}, [
        liveRow(
          id(2),
          status: 'FINISHED_PENDING_VERIFICATION',
          revision: 9,
          home: 3,
          away: 2,
          updatedAt: now,
        ),
      ], complete: true);
      final match = state[id(2)]!.applyTo({
        'id': id(2),
        'status': 'LIVE',
        'homeTeamId': 'h',
        'awayTeamId': 'a',
      }, now: now);
      expect(match['status'], 'FINISHED_PENDING_VERIFICATION');
      expect((match['score'] as Map)['home'], 3);
    });
  });

  group('LiveRealtimeClient', () {
    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('reads the whole window, survives a 503, recovers, and does not '
        'poll REST every tick while realtime is joined', () async {
      final server = FakeSupabase([
        for (var i = 0; i < 1200; i++)
          liveRow(id(i), home: i % 3, updatedAt: now),
      ]);
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
        dio,
        retryDelay: const Duration(milliseconds: 20),
        refreshInterval: const Duration(milliseconds: 50),
        bootstrapPolicy: const LiveBootstrapPolicy(
          joinedRefreshInterval: Duration(hours: 1),
        ),
      );
      var latest = <String, LiveMatchUpdate>{};
      final subscription = client.watch().listen((value) => latest = value);
      try {
        await until(() => latest.length == 1200 && server.sockets.isNotEmpty);
        // Joined: ticks every 50 ms must not keep reading REST.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final settled = server.restRequests.length;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(server.restRequests.length, settled);

        // Reconnect: the server fails the next read (503), then recovers.
        server.failingRequests.add(server.restRequests.length);
        server.rows[id(7)] = liveRow(
          id(7),
          revision: 2,
          home: 4,
          updatedAt: now,
        );
        await server.sockets.last.close();
        await until(
          () => latest[id(7)]?.homeScore == 4 && server.sockets.length >= 2,
        );
        expect(latest.length, 1200, reason: 'nothing lost during the 503');
      } finally {
        await subscription.cancel();
        dio.close(force: true);
        await server.stop();
      }
    });

    test('without realtime the periodic REST read keeps running', () async {
      final server = FakeSupabase([
        liveRow(id(1), updatedAt: now),
      ], realtime: false);
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
        dio,
        retryDelay: const Duration(seconds: 30),
        refreshInterval: const Duration(milliseconds: 40),
      );
      final subscription = client.watch().listen((_) {});
      try {
        await until(() => server.restRequests.length >= 4);
      } finally {
        await subscription.cancel();
        dio.close(force: true);
        await server.stop();
      }
    });
  });

  group('hardening: changed_at window, races and late rows', () {
    Map<String, LiveMatchUpdate> reconcileWindow(
      Map<String, LiveMatchUpdate> current,
      LiveBootstrapRead read,
      DateTime since,
    ) => reconcileLiveBootstrapSnapshot(
      current,
      read.rows,
      keysBeforeRequest: current.keys.toSet(),
      serverNow: read.serverNow,
      deviceNow: now,
      complete: read.complete,
      removableSince: since.add(policy.removalMargin),
    );

    test('a row rewritten without a change (old changed_at, fresh '
        'updated_at) is not read, and its overlay is kept', () async {
      final old = now.subtract(const Duration(days: 5));
      final server = FakeSupabase([
        liveRow(id(1), status: 'VERIFIED', updatedAt: now, changedAt: old),
        liveRow(id(2), updatedAt: now),
      ]);
      await server.start();
      final dio = Dio();
      try {
        final since = now.subtract(policy.window);
        final read = await fetchLiveBootstrap(
          dio,
          LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
          policy,
          since: since,
        );
        expect(read.complete, isTrue);
        expect(read.rows.map((r) => r['match_id']), [id(2)]);
        final result = reconcileWindow(
          {id(1): overlay(id(1), status: 'VERIFIED', receivedAt: old)},
          read,
          since,
        );
        expect(result.containsKey(id(1)), isTrue);
        expect(result.containsKey(id(2)), isTrue);
      } finally {
        dio.close(force: true);
        await server.stop();
      }
    });

    test('changes between pages never remove a valid overlay; a row pruned '
        'mid-read is removed', () async {
      final rows = [
        for (var i = 0; i < 600; i++)
          liveRow(id(i * 2), updatedAt: now.subtract(const Duration(hours: 1))),
      ];
      final server = FakeSupabase(rows);
      server.beforeAnswer = (request) {
        if (request != 1) return;
        // Behind the cursor (already read): a goal.
        server.rows[id(2)] = liveRow(
          id(2),
          revision: 2,
          home: 1,
          updatedAt: now,
        );
        // Ahead of the cursor: a goal and a prune.
        server.rows[id(1000)] = liveRow(
          id(1000),
          revision: 2,
          home: 2,
          updatedAt: now,
        );
        server.rows.remove(id(1100));
        // Behind the cursor and new to the window: read next cycle.
        server.rows[id(3)] = liveRow(id(3), updatedAt: now);
      };
      await server.start();
      final dio = Dio();
      try {
        final since = now.subtract(policy.window);
        final read = await fetchLiveBootstrap(
          dio,
          LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
          policy,
          since: since,
        );
        expect(read.complete, isTrue);
        final current = {
          for (final row in rows)
            row['match_id'] as String: LiveMatchUpdate.fromJson(
              row,
              receivedAt: now.subtract(const Duration(hours: 1)),
            ),
        };
        final result = reconcileWindow(current, read, since);
        expect(result.length, 599);
        expect(result.containsKey(id(1100)), isFalse, reason: 'pruned');
        expect(result[id(1000)]!.homeScore, 2);
        expect(result.containsKey(id(2)), isTrue);
        final ids = read.rows.map((r) => r['match_id']).toList();
        expect(ids.toSet().length, ids.length);
      } finally {
        dio.close(force: true);
        await server.stop();
      }
    });

    test(
      'hitting maxPages is partial and exhausted: nothing removed',
      () async {
        final server = FakeSupabase([
          for (var i = 0; i < 30; i++) liveRow(id(i), updatedAt: now),
        ]);
        await server.start();
        final dio = Dio();
        try {
          final since = now.subtract(policy.window);
          final read = await fetchLiveBootstrap(
            dio,
            LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
            const LiveBootstrapPolicy(pageSize: 10, maxPages: 2),
            since: since,
          );
          expect(
            [read.complete, read.exhausted, read.rows.length],
            [false, true, 20],
          );
          final result = reconcileWindow(
            {id(25): overlay(id(25), receivedAt: now)},
            read,
            since,
          );
          expect(result.containsKey(id(25)), isTrue);
        } finally {
          dio.close(force: true);
          await server.stop();
        }
      },
    );

    test('a late REST row never undoes a newer realtime correction', () {
      final realtime = LiveMatchUpdate.fromJson(
        liveRow(id(4), revision: 6, home: 1, away: 1, updatedAt: now),
        receivedAt: now,
      );
      final read = (
        rows: [
          liveRow(
            id(4),
            revision: 5,
            home: 2,
            away: 1,
            updatedAt: now.subtract(const Duration(minutes: 2)),
          ),
        ],
        complete: true,
        exhausted: false,
        serverNow: now,
      );
      final result = reconcileWindow(
        {id(4): realtime},
        read,
        now.subtract(policy.window),
      );
      expect(result[id(4)]!.revision, 6);
      expect([result[id(4)]!.homeScore, result[id(4)]!.awayScore], [1, 1]);
    });

    test('without a server Date header a pruned row is still removed and the '
        'others stay', () async {
      final server = FakeSupabase(
        [liveRow(id(1), updatedAt: now), liveRow(id(2), updatedAt: now)],
        realtime: false,
        sendDate: false,
      );
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 't'),
        dio,
        retryDelay: const Duration(seconds: 30),
        refreshInterval: const Duration(milliseconds: 40),
      );
      var latest = <String, LiveMatchUpdate>{};
      final subscription = client.watch().listen((value) => latest = value);
      Future<void> until(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!done()) {
          if (DateTime.now().isAfter(deadline)) fail('timed out');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      try {
        await until(() => latest.length == 2);
        server.rows.remove(id(2));
        await until(() => !latest.containsKey(id(2)));
        expect(latest.containsKey(id(1)), isTrue);
      } finally {
        await subscription.cancel();
        dio.close(force: true);
        await server.stop();
      }
    });
  });
}

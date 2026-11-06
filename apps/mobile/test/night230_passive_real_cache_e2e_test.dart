import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';
import 'package:futbeat/core/qa_diagnostics.dart';

// HTTPS remains mandatory in the real policy. Only this test wire maps the
// approved logical origin to a disposable HTTP loopback server: NOT a TLS test.
class _LocalWire implements HttpClientAdapter {
  _LocalWire(this.port);
  final int port;
  final delegate = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..findProxy = ((_) => 'DIRECT'),
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) {
    if (options.uri.host != '127.0.0.1' || options.uri.port != port) {
      throw StateError('Non-loopback request is forbidden');
    }
    return delegate.fetch(
      options.copyWith(baseUrl: 'http://127.0.0.1:$port'),
      stream,
      cancellation,
    );
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

class _NoNetworkWire implements HttpClientAdapter {
  int attempts = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) async {
    attempts++;
    throw StateError('Offline restart must not create any socket');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'real stored-only HTTP payload survives repository and SQLite restart',
    () async {
      final fixture = jsonDecode(
        File('test/fixtures/everton_newcastle_qa225_timeline.json')
            .readAsStringSync(),
      ) as Json;
      final match = Map<String, dynamic>.from(fixture['match'] as Map);
      final detailPayload = Map<String, dynamic>.from(fixture['detail'] as Map);
      final id = match['id'] as String;
      final date = DateTime.utc(2026, 10, 29);
      // Only envelope metadata is synthetic. The 25 canonical events and 22
      // detail incidents are the unchanged, previously exported A32 payload.
      // Required entity labels are their own IDs, not invented sporting facts.
      final snapshotPayload = <String, dynamic>{
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-31T00:00:00Z',
        'teams': [
          for (final key in ['homeTeamId', 'awayTeamId'])
            {'id': match[key], 'name': match[key]},
        ],
        'competitions': [
          {'id': match['competitionId'], 'name': match['competitionId']},
        ],
        'players': <Json>[],
        'matches': [match],
        'standings': <Json>[],
      };
      void verify(Snapshot snapshot, MatchDetail detail) {
        expect(snapshot.demo, isFalse);
        final storedMatch = snapshot.match(id)!;
        expect(storedMatch.id, id);
        expect(storedMatch.events, hasLength(25));
        expect(detail.matchId, id);
        expect(detail.incidents, hasLength(22));
        final timeline = mergedMatchTimeline(storedMatch, detail);
        expect(timeline, hasLength(25));
        expect(
          timeline
              .map((row) => row['providerEventId'])
              .whereType<String>()
              .toSet(),
          detail.incidents.map((row) => row['providerEventId']).toSet(),
        );
        expect(
          timeline
              .where((row) => row['type'] == 'GOAL')
              .map((row) => row['score']),
          [
            {'home': 1, 'away': 0},
            {'home': 2, 'away': 0},
            {'home': 3, 'away': 0},
            {'home': 3, 'away': 1},
          ],
        );
      }

      final directory = await Directory.systemTemp.createTemp('qa230-passive-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cache.sqlite');
      final requests = <Uri>[];
      final methods = <String>[];
      var active = 0;
      var maxActive = 0;
      var contextDetailRequests = 0;
      final simultaneous = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var serverClosed = false;
      addTearDown(() async {
        if (!simultaneous.isCompleted) simultaneous.complete();
        if (!serverClosed) await server.close(force: true);
      });
      server.listen((request) async {
        requests.add(request.uri);
        methods.add(request.method);
        active++;
        if (active > maxActive) maxActive = active;
        try {
          final route = request.uri.path;
          final payload = switch (route) {
            '/v1/qa-stored/calendar' ||
            '/v1/qa-stored/match-context' => snapshotPayload,
            '/v1/qa-stored/match-detail' => detailPayload,
            _ => null,
          };
          if (request.method != 'GET' || payload == null) {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            if (!route.endsWith('/calendar')) {
              contextDetailRequests++;
              if (contextDetailRequests == 2) simultaneous.complete();
              await simultaneous.future;
            }
            request.response.headers.contentType = ContentType.json;
            request.response.headers.set('x-futbeat-qa-stored', 'v1');
            request.response.write(jsonEncode(payload));
          }
          await request.response.close();
        } finally {
          active--;
        }
      });
      final origin = Uri.parse('https://127.0.0.1:${server.port}');
      final policy = QaStoredReadInterceptor(origin: origin);
      addTearDown(policy.close);
      final dio = Dio(BaseOptions(baseUrl: origin.toString()))
        ..httpClientAdapter = _LocalWire(server.port)
        ..interceptors.add(policy);
      var db = AppDatabase(NativeDatabase(file));
      var dbClosed = false;
      addTearDown(() async {
        dio.close(force: true);
        if (!dbClosed) await db.close();
      });
      final onlineMetrics = QaDiagnostics();
      final online = ApiRepository(
        dio,
        db,
        const CalendarCachePolicy(),
        null,
        onlineMetrics,
      );
      final calendars = await Future.wait([
        online.loadDate(date),
        online.loadDate(date),
      ]);
      expect(identical(calendars[0], calendars[1]), isTrue);
      final contextFuture = online.loadMatchContext(id);
      final details = await Future.wait([
        online.loadMatchDetail(id),
        online.loadMatchDetail(id),
      ]);
      final context = await contextFuture;
      expect(identical(details[0], details[1]), isTrue);
      verify(context, details.first);
      await online.settleBackground();
      expect(requests.map((uri) => uri.path), [
        '/v1/qa-stored/calendar',
        '/v1/qa-stored/match-context',
        '/v1/qa-stored/match-detail',
      ]);
      expect(methods, everyElement('GET'));
      expect(requests.first.queryParameters['date'], '2026-10-29');
      expect(
        requests.skip(1).every((uri) => uri.queryParameters['id'] == id),
        isTrue,
      );
      expect(maxActive, 2);
      expect(policy.counters, {'requests': 3, 'active': 0, 'blocked': 0});
      final onlineCounts = onlineMetrics.snapshot()['counts'] as Map;
      expect(onlineCounts['/v1/calendar:sharedFlight'], 1);
      expect(onlineCounts['/v1/match-detail:sharedFlight'], 1);
      for (final endpoint in ['calendar', 'match-context', 'match-detail']) {
        expect(onlineCounts['/v1/$endpoint:httpSuccess'], 1);
      }
      await db.close();
      dbClosed = true;
      dio.close(force: true);
      policy.close();
      await server.close(force: true);
      serverClosed = true;

      // New database connection, repository, policy and transport: no in-memory
      // repository state survives. The server is already shut down.
      db = AppDatabase(NativeDatabase(file));
      dbClosed = false;
      final offlineWire = _NoNetworkWire();
      final offlinePolicy = QaStoredReadInterceptor(origin: origin);
      addTearDown(offlinePolicy.close);
      final offlineDio = Dio(BaseOptions(baseUrl: origin.toString()))
        ..httpClientAdapter = offlineWire
        ..interceptors.add(offlinePolicy);
      addTearDown(() => offlineDio.close(force: true));
      final offlineMetrics = QaDiagnostics();
      final offline = ApiRepository(
        offlineDio,
        db,
        const CalendarCachePolicy(),
        null,
        offlineMetrics,
      );
      // Cache-first consumers stop at the stored emission while offline.
      offline.setAppActive(false);
      final localDay = await offline.watchDate(date).first;
      final localContext = await offline.watchPublicMatchContext(id).first;
      final localDetail = await offline.readStoredMatchDetail(id);
      expect(localContext.stale, isTrue);
      expect(localDetail?.offlineStale, isTrue);
      expect(localDay.match(id), isNotNull);
      verify(localContext, localDetail!);
      expect(await offline.readStoredMatchDetail('provider_857092'), isNull);
      await offline.settleBackground();
      expect(offlineWire.attempts, 0);
      expect(offlinePolicy.counters, {
        'requests': 0,
        'active': 0,
        'blocked': 0,
      });
      final offlineCounts = offlineMetrics.snapshot()['counts'] as Map;
      expect(offlineCounts['/v1/calendar:sqliteHit'], 1);
      expect(offlineCounts['/v1/match-detail:sqliteHit'], 1);
      expect(
        offlineCounts.keys.where((key) => key.toString().contains('http')),
        isEmpty,
      );
      // Local test measurements only; not an Android/TLS/production benchmark.
      debugPrint(
        'QA230_LOCAL_E2E storedHTTP=3 sharedFlights=2 maxConcurrent=2 '
        'offlineHTTP=0 canonicalEvents=25 detailEvents=22 '
        'structuredGoalScores=4 sqliteBytes=${await file.length()}',
      );
    },
  );
}

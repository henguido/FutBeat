import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/qa_development.dart';
import 'package:futbeat/core/models.dart';

// Only the test wire adapter maps approved HTTPS requests to an ephemeral HTTP
// loopback server. The production interceptor still requires HTTPS unchanged.
// TLS is not measured: the local certificate could not be pinned in this environment.
class _LoopbackWireAdapter implements HttpClientAdapter {
  _LoopbackWireAdapter(this.port);
  final int port;
  final delegate = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..findProxy = ((_) => 'DIRECT'),
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) async {
    if (options.uri.host != '127.0.0.1' || options.uri.port != port) {
      throw StateError('Only the test loopback server is reachable');
    }
    try {
      return await delegate.fetch(
        options.copyWith(baseUrl: 'http://127.0.0.1:$port'),
        stream,
        cancellation,
      );
    } on DioException catch (error) {
      // Only this test adapter clones the request to translate HTTPS to HTTP.
      // Real IO receives the original object. Preserve that identity on errors
      // too, otherwise the harness falsely leaks a concurrency slot.
      throw error.copyWith(requestOptions: options);
    }
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

void main() {
  late HttpServer server;
  late Dio dio;
  late QaStoredReadInterceptor policy;
  late DateTime now;
  late List<String> paths;
  Completer<void>? holdCalendar;
  var acknowledge = true;
  var redirect = false;
  var disconnectOnce = false;
  late Map<String, dynamic> payload;

  setUp(() async {
    now = DateTime.utc(2026, 10, 31);
    paths = [];
    acknowledge = true;
    redirect = false;
    disconnectOnce = false;
    payload = {'schemaVersion': 1, 'matches': []};
    holdCalendar = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      paths.add(request.uri.path);
      final ack = acknowledge;
      final redirectResponse = redirect;
      if (request.uri.path.endsWith('/calendar')) {
        await holdCalendar?.future;
      }
      try {
        if (disconnectOnce) {
          disconnectOnce = false;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        if (ack) request.response.headers.set('x-futbeat-qa-stored', 'v1');
        if (redirectResponse) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set('location', '/v1/calendar');
        }
        request.response.write(jsonEncode(payload));
        await request.response.close();
      } on SocketException {
        // Cancellation deliberately closes these loopback sockets.
      }
    });
    final origin = Uri.parse('https://127.0.0.1:${server.port}');
    dio = Dio(BaseOptions(baseUrl: origin.toString()))
      ..httpClientAdapter = _LoopbackWireAdapter(server.port);
    policy = QaStoredReadInterceptor(origin: origin, clock: () => now);
    dio.interceptors.add(policy);
  });
  tearDown(() async {
    policy.close();
    if (holdCalendar != null && !holdCalendar!.isCompleted) {
      holdCalendar!.complete();
    }
    dio.close(force: true);
    await server.close(force: true);
  });

  Future<void> waitFor(int count) async {
    for (var i = 0; i < 100 && paths.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(paths.length, count);
  }

  test(
    'HTTP loopback emits stored routes only, never writes or hydration',
    () async {
      for (final path in [
        '/v1/calendar',
        '/v1/match-context',
        '/v1/match-detail',
      ]) {
        await dio.get(path);
      }
      for (final path in [
        '/v1/snapshot',
        '/v1/entity',
        '/v1/qa-stored/calendar',
      ]) {
        await expectLater(dio.get(path), throwsA(isA<DioException>()));
      }
      await expectLater(dio.post('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, [
        '/v1/qa-stored/calendar',
        '/v1/qa-stored/match-context',
        '/v1/qa-stored/match-detail',
      ]);
    },
  );

  test(
    'real sockets respect 12/minute and 60/session without retries',
    () async {
      for (var minute = 0; minute < 5; minute++) {
        for (var i = 0; i < 12; i++) {
          await dio.get('/v1/calendar');
        }
        await expectLater(
          dio.get('/v1/calendar'),
          throwsA(isA<DioException>()),
        );
        now = now.add(const Duration(minutes: 1));
      }
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, hasLength(60));
      expect(policy.counters, {'requests': 60, 'active': 0, 'blocked': 6});
    },
  );

  test(
    'two concurrent sockets; STOP cancels both and seals navigation',
    () async {
      holdCalendar = Completer<void>();
      final first = dio.get('/v1/calendar');
      final second = dio.get('/v1/calendar');
      final firstStopped = expectLater(first, throwsA(isA<DioException>()));
      final secondStopped = expectLater(second, throwsA(isA<DioException>()));
      await waitFor(2);
      await expectLater(
        dio.get('/v1/match-detail'),
        throwsA(isA<DioException>()),
      );
      policy.close();
      await Future.wait([firstStopped, secondStopped]);
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, hasLength(2));
      expect(policy.counters['active'], 0);
    },
  );

  test('missing contract cancels another in-flight request', () async {
    holdCalendar = Completer<void>();
    final pending = dio.get('/v1/calendar');
    final stopped = expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await waitFor(1);
    acknowledge = false;
    await expectLater(
      dio.get('/v1/match-detail'),
      throwsA(isA<DioException>()),
    );
    await stopped;
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    expect(paths, hasLength(2));
    expect(policy.counters['active'], 0);
  });

  test(
    'three-hour expiry rejects late data and subsequent navigation',
    () async {
      holdCalendar = Completer<void>();
      final pending = dio.get('/v1/calendar');
      final rejected = expectLater(pending, throwsA(isA<DioException>()));
      await waitFor(1);
      now = now.add(const Duration(hours: 3));
      holdCalendar!.complete();
      await rejected;
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, hasLength(1));
      expect(policy.counters['active'], 0);
    },
  );

  test(
    'redirect never follows ordinary route, including same origin',
    () async {
      redirect = true;
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, ['/v1/qa-stored/calendar']);
    },
  );

  test('expiry timer cancels a hanging socket without a response', () async {
    policy.close();
    dio.interceptors.clear();
    policy = QaStoredReadInterceptor(
      origin: Uri.parse(dio.options.baseUrl),
      sessionDuration: const Duration(milliseconds: 300),
    );
    dio.interceptors.add(policy);
    holdCalendar = Completer<void>();
    final request = dio.get('/v1/calendar');
    final stopped = expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await waitFor(1);
    await stopped.timeout(const Duration(seconds: 2));
    expect(paths, hasLength(1));
    expect(policy.counters['active'], 0);
  });

  test('invalid or excessive durations fail closed', () {
    for (final duration in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(hours: 4),
    ]) {
      expect(
        () => QaStoredReadInterceptor(
          origin: Uri.parse(dio.options.baseUrl),
          sessionDuration: duration,
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'connection loss has no retry or fallback and recovery keeps the budget',
    () async {
      policy.close();
      dio.interceptors.clear();
      policy = QaStoredReadInterceptor(
        origin: Uri.parse(dio.options.baseUrl),
        clock: () => now,
        sessionLimit: 2,
      );
      dio.interceptors.add(policy);
      disconnectOnce = true;
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, ['/v1/qa-stored/calendar']);
      expect(policy.counters['active'], 0);
      // Explicit retry by the local test, not an automatic recovery loop.
      await dio.get('/v1/match-context');
      expect(policy.counters['requests'], 2);
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(paths, ['/v1/qa-stored/calendar', '/v1/qa-stored/match-context']);
    },
  );

  test('first-session proposal enforces 30 total, 8 per minute and 15-minute expiry', () async {
    policy.close();
    dio.interceptors.clear();
    final started = now;
    policy = QaStoredReadInterceptor(
      origin: Uri.parse(dio.options.baseUrl),
      clock: () => now,
      sessionLimit: 30,
      minuteLimit: 8,
      concurrentLimit: 2,
      sessionDuration: const Duration(minutes: 15),
    );
    dio.interceptors.add(policy);
    for (final allowance in [8, 8, 8, 6]) {
      for (var i = 0; i < allowance; i++) {
        await dio.get('/v1/calendar');
      }
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      now = now.add(const Duration(minutes: 1));
    }
    expect(paths, hasLength(30));
    expect(policy.counters, {'requests': 30, 'active': 0, 'blocked': 4});
    now = started.add(const Duration(minutes: 15));
    await expectLater(
      dio.get('/v1/match-detail'),
      throwsA(isA<DioException>()),
    );
    expect(paths, hasLength(30));
  });

  test(
    'stored response acknowledgment never renews an old LIVE observation',
    () async {
      final old = now.subtract(const Duration(minutes: 20));
      final match = <String, dynamic>{
        'id': 'fb_match_fixture',
        'competitionId': 'fb_comp_fixture',
        'homeTeamId': 'fb_team_h',
        'awayTeamId': 'fb_team_a',
        'startTime': old.subtract(const Duration(hours: 1)).toIso8601String(),
        'status': 'LIVE',
        'score': {'home': 2, 'away': 1},
        'liveObservedAt': old.toIso8601String(),
      };
      payload = {
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': now.toIso8601String(),
        'matches': [match],
        'teams': [
          {'id': 'fb_team_h', 'name': 'Local sintético'},
          {'id': 'fb_team_a', 'name': 'Visitante sintético'},
        ],
        'players': [],
        'competitions': [
          {'id': 'fb_comp_fixture', 'name': 'Competición sintética'},
        ],
        'standings': [],
      };
      final response = await dio.get<Map<String, dynamic>>('/v1/match-context');
      final shown = Snapshot(response.data!).match('fb_match_fixture')!;
      expect(shown.score, '2 - 1');
      expect(shown.liveDataStaleAt(now), isTrue);
      match['liveObservedAt'] = now.toIso8601String();
      final recovered = await dio.get<Map<String, dynamic>>(
        '/v1/match-context',
      );
      expect(
        Snapshot(recovered.data!)
            .match('fb_match_fixture')!
            .liveDataStaleAt(now),
        isFalse,
      );
      expect(paths.every((path) => path.startsWith('/v1/qa-stored/')), isTrue);
    },
  );
}

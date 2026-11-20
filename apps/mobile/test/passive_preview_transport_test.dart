import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/passive_preview_transport.dart';
import 'package:futbeat/core/qa_development.dart';

final _base = Uri.parse(
  'https://fixture.invalid/functions/v1/futbeat-passive-api',
);

ResponseBody _response(int status, {List<String> passive = const ['v1']}) =>
    ResponseBody.fromString(
      '{}',
      status,
      headers: {
        'content-type': ['application/json'],
        'x-futbeat-qa-stored': ['v1'],
        if (passive.isNotEmpty) 'x-futbeat-passive': passive,
      },
    );

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.reply);
  final FutureOr<ResponseBody> Function(RequestOptions) reply;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => reply(options);

  @override
  void close({bool force = false}) {}
}

Dio _client(PassivePreviewTransport transport, _FixtureAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: _base.toString()))
    ..httpClientAdapter = adapter
    ..interceptors.add(transport);
  addTearDown(() {
    transport.close();
    dio.close(force: true);
  });
  return dio;
}

void main() {
  test('cancelled queued context never reaches the network', () async {
    final held = Completer<ResponseBody>();
    final entered = Completer<void>();
    var sent = 0;
    final transport = PassivePreviewTransport(
      baseUri: _base,
      concurrentLimit: 1,
    );
    final dio = _client(
      transport,
      _FixtureAdapter((_) {
        sent++;
        entered.complete();
        return held.future;
      }),
    );
    final active = dio.get('/v1/match-detail');
    await entered.future;
    final token = CancelToken();
    final cancelled = expectLater(
      dio.get('/v1/match-context', cancelToken: token),
      throwsA(isA<DioException>()),
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await cancelled;
    held.complete(_response(200));
    await active;
    expect(sent, 1);
  });

  test('fresh transport cache is immediate even while the network slot is occupied', () async {
    final held = Completer<ResponseBody>();
    final entered = Completer<void>();
    final transport = PassivePreviewTransport(
      baseUri: _base,
      concurrentLimit: 1,
    );
    var sent = 0;
    final dio = _client(
      transport,
      _FixtureAdapter((options) {
        sent++;
        if (options.path.endsWith('calendar')) {
          return _response(200)..headers['cache-control'] = ['max-age=30'];
        }
        entered.complete();
        return held.future;
      }),
    );
    await dio.get('/v1/calendar');
    final active = dio.get('/v1/match-detail');
    await entered.future;
    expect((await dio.get('/v1/calendar')).statusCode, 200);
    expect(sent, 2);
    held.complete(_response(200));
    await active;
  });

  test(
    'initial context waits for two concurrent detail reads instead of failing',
    () async {
      final first = Completer<ResponseBody>();
      final second = Completer<ResponseBody>();
      final occupied = Completer<void>();
      final paths = <String>[];
      final transport = PassivePreviewTransport(baseUri: _base);
      final dio = _client(
        transport,
        _FixtureAdapter((options) {
          paths.add(options.path);
          if (paths.length == 2) occupied.complete();
          if (options.path.endsWith('match-detail')) return first.future;
          if (options.path.endsWith('match-preview')) return second.future;
          return _response(200);
        }),
      );
      final detail = dio.get('/v1/match-detail');
      final preview = dio.get('/v1/match-preview');
      await occupied.future;
      final context = dio.get('/v1/match-context');
      final accepted = expectLater(
        context,
        completion(isA<Response<dynamic>>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(paths, hasLength(2));
      first.complete(_response(200));
      await accepted;
      second.complete(_response(200));
      await Future.wait([detail, preview]);
      expect(paths.where((p) => p.endsWith('match-context')), hasLength(1));
      expect(transport.counters['active'], 0);
    },
  );

  test(
    'replays fresh and absent results without network until their TTL',
    () async {
      var now = DateTime.utc(2026, 11, 4);
      final transport = PassivePreviewTransport(
        baseUri: _base,
        clock: () => now,
      );
      final dio = _client(
        transport,
        _FixtureAdapter((request) {
          final absent = request.path.endsWith('match-detail');
          return _response(absent ? 404 : 200)
            ..headers['cache-control'] = [
              absent ? 'no-store' : 'public, max-age=15',
            ];
        }),
      );
      Future<void> expectAbsent() => expectLater(
        dio.get('/v1/match-detail', queryParameters: {'id': 'fb_match_absent'}),
        throwsA(predicate<Object>(isQaStoredDetailAbsent)),
      );
      await dio.get('/v1/match-context');
      await expectAbsent();
      now = now.add(const Duration(seconds: 14));
      await dio.get('/v1/match-context');
      await expectAbsent();
      expect(transport.counters['requests'], 2);
      now = now.add(const Duration(seconds: 1));
      await dio.get('/v1/match-context');
      await expectAbsent();
      expect(transport.counters['requests'], 3);
      now = now.add(const Duration(seconds: 15));
      await expectAbsent();
      expect(transport.counters['requests'], 4);
    },
  );

  test(
    '503 backs off across routes and permits a later explicit read',
    () async {
      var now = DateTime.utc(2026, 11, 4);
      final transport = PassivePreviewTransport(
        baseUri: _base,
        clock: () => now,
      );
      var sent = 0;
      final dio = _client(
        transport,
        _FixtureAdapter((_) {
          return _response(++sent == 1 ? 503 : 200)
            ..headers['retry-after'] = ['7'];
        }),
      );
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      now = now.add(const Duration(seconds: 6));
      await expectLater(
        dio.get('/v1/match-context'),
        throwsA(isA<DioException>()),
      );
      expect(sent, 1);
      now = now.add(const Duration(seconds: 1));
      await dio.get('/v1/match-context');
      expect(sent, 2);
    },
  );

  test(
    'sends only stored alias and dedicated headers to the passive function',
    () async {
      final transport = PassivePreviewTransport(
        baseUri: _base,
        clientKey: 'synthetic-preview-token',
      );
      final dio = _client(
        transport,
        _FixtureAdapter((options) {
          expect(options.uri.path, '${_base.path}/v1/qa-stored/calendar');
          expect(options.uri.host, _base.host);
          expect(options.uri.queryParameters, {'date': '2026-11-04'});
          expect(options.followRedirects, isFalse);
          expect(options.headers, {
            'accept': 'application/json',
            'x-futbeat-client-key': 'synthetic-preview-token',
          });
          return _response(200);
        }),
      );
      final response = await dio.get(
        '/v1/calendar',
        queryParameters: {'date': '2026-11-04'},
        options: Options(
          headers: {
            'Authorization': 'fixture',
            'Cookie': 'fixture',
            'apikey': 'fixture',
          },
        ),
      );
      expect(response.statusCode, 200);
      expect(
        response.requestOptions.headers,
        isNot(contains('x-futbeat-client-key')),
      );
    },
  );

  test('rejects writes, absolute URLs, unknown routes and credential query keys before the adapter', () async {
    final transport = PassivePreviewTransport(baseUri: _base);
    final dio = _client(
      transport,
      _FixtureAdapter((_) => throw StateError('unexpected adapter')),
    );
    final blocked = throwsA(
      isA<DioException>().having(
        (e) => e.type,
        'type',
        DioExceptionType.cancel,
      ),
    );
    await expectLater(dio.post('/v1/calendar'), blocked);
    await expectLater(dio.get('https://other.invalid/v1/calendar'), blocked);
    await expectLater(dio.get('/v1/snapshot'), blocked);
    await expectLater(
      dio.get('/v1/calendar', queryParameters: {'apikey': 'fixture'}),
      blocked,
    );
    await expectLater(
      dio.get('/v1/match-detail', queryParameters: {'request': '1'}),
      blocked,
    );
    expect(transport.counters, {'requests': 0, 'active': 0, 'blocked': 5});
  });

  test(
    'acknowledged absence keeps the existing detail error contract',
    () async {
      final transport = PassivePreviewTransport(baseUri: _base);
      final dio = _client(
        transport,
        _FixtureAdapter((options) {
          expect(options.uri.queryParameters, isNot(contains('request')));
          return _response(404);
        }),
      );
      await expectLater(
        dio.get('/v1/match-detail', queryParameters: {'request': '0'}),
        throwsA(predicate<Object>(isQaStoredDetailAbsent)),
      );
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(transport.counters['requests'], 2);
    },
  );

  for (final scenario in [
    (status: 404, passive: <String>[]),
    (status: 200, passive: ['v1', 'v1']),
    (status: 302, passive: ['v1']),
    (status: 401, passive: ['v1']),
    (status: 403, passive: ['v1']),
  ]) {
    test(
      'seals the transport on ambiguous contract ${scenario.status}',
      () async {
        final transport = PassivePreviewTransport(baseUri: _base);
        final dio = _client(
          transport,
          _FixtureAdapter(
            (_) => _response(scenario.status, passive: scenario.passive),
          ),
        );
        final blocked = throwsA(
          isA<DioException>().having((e) => e.response, 'response', isNull),
        );
        await expectLater(dio.get('/v1/calendar'), blocked);
        await expectLater(dio.get('/v1/calendar'), blocked);
        expect(transport.counters['requests'], 1);
      },
    );
  }

  test('rolling budgets recover without enabling bursts', () async {
    var now = DateTime.utc(2026, 11, 4);
    final transport = PassivePreviewTransport(
      baseUri: _base,
      clock: () => now,
      sessionLimit: 2,
      minuteLimit: 1,
    );
    final dio = _client(transport, _FixtureAdapter((_) => _response(200)));
    await dio.get('/v1/calendar');
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    now = now.add(const Duration(minutes: 1));
    await dio.get('/v1/calendar');
    now = now.add(const Duration(minutes: 1));
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    now = now.add(const Duration(minutes: 13));
    await dio.get('/v1/calendar');
    expect(transport.counters['requests'], 3);
  });

  test('caps in-flight reads and explicit close cancels them', () async {
    final transport = PassivePreviewTransport(
      baseUri: _base,
      concurrentLimit: 1,
    );
    final held = Completer<ResponseBody>();
    final entered = Completer<void>();
    final dio = _client(
      transport,
      _FixtureAdapter((_) {
        entered.complete();
        return held.future;
      }),
    );
    final pending = expectLater(
      dio.get('/v1/calendar'),
      throwsA(isA<DioException>()),
    );
    await entered.future;
    final queued = expectLater(
      dio.get('/v1/match-context'),
      throwsA(isA<DioException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(transport.counters['active'], 1);
    transport.close();
    held.complete(_response(200));
    await Future.wait([pending, queued]);
    expect(transport.counters, {'requests': 1, 'active': 0, 'blocked': 1});
  });
}

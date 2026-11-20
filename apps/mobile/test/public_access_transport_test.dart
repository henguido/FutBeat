import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/passive_preview_transport.dart';
import 'package:futbeat/core/qa_development.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
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

ResponseBody _body(
  int status, {
  String owner = 'public',
  String? retry,
  String? cache,
}) => ResponseBody.fromString(
  jsonEncode({'owner': owner}),
  status,
  headers: {
    'content-type': ['application/json'],
    if (retry != null) 'retry-after': [retry],
    if (cache != null) 'cache-control': [cache],
  },
);

void main() {
  late Dio dio;
  late PassivePreviewTransport transport;
  late String scope, token;
  late DateTime now;
  late int sends, refreshes;
  var sessionAvailable = true;
  late FutureOr<ResponseBody> Function(RequestOptions) reply;
  late Future<UserApiSession?> Function(String) renew;
  setUp(() {
    sessionAvailable = true;
    scope = 'guest-1:1';
    token = 'synthetic-old';
    now = DateTime.utc(2026, 11, 5, 12);
    sends = 0;
    refreshes = 0;
    reply = (_) => _body(200);
    renew = (_) async {
      token = 'synthetic-new';
      return (accessToken: token, scope: scope);
    };
    dio = Dio(
      BaseOptions(
        baseUrl: 'https://fixture.invalid/functions/v1/futbeat-api',
        headers: {
          'Authorization': 'must-be-replaced',
          'x-futbeat-client-key': 'must-not-send',
        },
      ),
    );
    dio.httpClientAdapter = _Adapter((options) {
      sends++;
      return reply(options);
    });
    transport = PassivePreviewTransport(
      baseUri: Uri.parse(dio.options.baseUrl),
      publishableKey: 'sb_publishable_fixture',
      retryClient: dio,
      clock: () => now,
      currentScope: () => scope,
      userSession: ({String? rejectedToken}) async {
        if (!sessionAvailable) return null;
        if (rejectedToken != null) {
          refreshes++;
          return renew(rejectedToken);
        }
        return (accessToken: token, scope: scope);
      },
    );
    dio.interceptors.add(transport);
  });
  tearDown(() {
    transport.close();
    dio.close(force: true);
  });

  test('production uses original GET route, publishable and individual JWT, no Preview credential', () async {
    reply = (request) {
      expect(request.path, '/v1/match-detail');
      expect(request.headers['apikey'], 'sb_publishable_fixture');
      expect(request.headers['Authorization'], 'Bearer synthetic-old');
      expect(request.headers.containsKey('x-futbeat-client-key'), isFalse);
      expect(request.queryParameters.containsKey('request'), isFalse);
      expect(request.followRedirects, isFalse);
      return _body(200);
    };
    await dio.get(
      '/v1/match-detail',
      queryParameters: {'id': 'fb_match_test', 'request': '0'},
    );
    expect(sends, 1);
  });
  test(
    '401 refreshes once and retries with new JWT within the same limits',
    () async {
      final headers = <String>[];
      reply = (request) {
        headers.add('${request.headers['Authorization']}');
        return _body(sends == 1 ? 401 : 200);
      };
      await dio.get('/v1/calendar');
      expect(headers, ['Bearer synthetic-old', 'Bearer synthetic-new']);
      expect(sends, 2);
      expect(refreshes, 1);
      expect(transport.counters['requests'], 2);
      expect(transport.counters['active'], 0);
    },
  );
  test('a second 401 never loops or falls back to an open endpoint', () async {
    reply = (_) => _body(401);
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    expect(sends, 2);
    expect(refreshes, 1);
    expect(transport.counters['active'], 0);
  });
  test(
    'refresh failure sends no retry and exposes no refresh error detail',
    () async {
      reply = (_) => _body(401);
      renew = (_) async => throw StateError('synthetic-private-error');
      await expectLater(
        dio.get('/v1/calendar'),
        throwsA(
          isA<DioException>().having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('synthetic-private-error')),
          ),
        ),
      );
      expect(sends, 1);
      expect(refreshes, 1);
    },
  );
  test('leaving during refresh cancels the retry', () async {
    final pending = Completer<UserApiSession?>();
    final entered = Completer<void>();
    reply = (_) => _body(401);
    renew = (_) {
      entered.complete();
      return pending.future;
    };
    final cancel = CancelToken();
    final result = expectLater(
      dio.get('/v1/calendar', cancelToken: cancel),
      throwsA(isA<DioException>()),
    );
    await entered.future;
    cancel.cancel();
    pending.complete((accessToken: 'synthetic-new', scope: scope));
    await result;
    expect(sends, 1);
  });
  test('old account response cannot replace the next account', () async {
    final pending = Completer<ResponseBody>();
    final entered = Completer<void>();
    reply = (_) {
      entered.complete();
      return pending.future;
    };
    final result = expectLater(
      dio.get('/v1/favorites'),
      throwsA(isA<DioException>()),
    );
    await entered.future;
    scope = 'account-B:2';
    token = 'synthetic-B';
    pending.complete(_body(200, owner: 'A', cache: 'max-age=60'));
    await result;
    reply = (_) => _body(200, owner: 'B');
    final b = await dio.get('/v1/favorites');
    expect(b.data['owner'], 'B');
    expect(sends, 2);
  });
  test('HTTP cache is scoped to identity and fresh hits need no renewal or network', () async {
    reply = (_) => _body(200, owner: scope, cache: 'max-age=60');
    await dio.get('/v1/favorites');
    await dio.get('/v1/favorites');
    expect(sends, 1);
    scope = 'account-B:2';
    token = 'synthetic-B';
    final b = await dio.get('/v1/favorites');
    expect(b.data['owner'], scope);
    expect(sends, 2);
  });
  test(
    'HTTP-date Retry-After on 429 is respected without automatic retry',
    () async {
      reply = (_) => _body(
        429,
        retry: HttpDate.format(now.add(const Duration(minutes: 2))),
      );
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      now = now.add(const Duration(seconds: 119));
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(sends, 1);
      now = now.add(const Duration(seconds: 1));
      reply = (_) => _body(200);
      await dio.get('/v1/calendar');
      expect(sends, 2);
      expect(refreshes, 0);
    },
  );
  test(
    '503 Retry-After pauses reads and never refreshes the session',
    () async {
      reply = (_) => _body(503, retry: '5');
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      await expectLater(
        dio.get('/v1/match-context'),
        throwsA(isA<DioException>()),
      );
      expect(sends, 1);
      now = now.add(const Duration(seconds: 5));
      reply = (_) => _body(200);
      await dio.get('/v1/match-context');
      expect(sends, 2);
      expect(refreshes, 0);
    },
  );
  test(
    'no API reader credentials means cache fallback, not public-token fallback',
    () async {
      scope = 'guest:0';
      transport.close();
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(sends, 0);
    },
  );
  test(
    'absolute URLs, writes and hydration demands never reach the wire',
    () async {
      for (final uri in [
        'https://goal-api.com/fixtures',
        'https://fixture.invalid/functions/v1/futbeat-api/v1/calendar',
        '/v1/match-detail?request=1',
      ]) {
        await expectLater(dio.get(uri), throwsA(isA<DioException>()));
      }
      await expectLater(dio.post('/v1/calendar'), throwsA(isA<DioException>()));
      await expectLater(
        dio.get('/v1/match-detail', queryParameters: {'request': '1'}),
        throwsA(isA<DioException>()),
      );
      expect(sends, 0);
    },
  );
  test(
    'stored detail 404 is an absence, with no Preview ACK or hydration',
    () async {
      reply = (_) => _body(404);
      try {
        await dio.get('/v1/match-detail');
        fail('Expected absence');
      } on DioException catch (e) {
        expect(isQaStoredDetailAbsent(e), isTrue);
      }
      expect(sends, 1);
    },
  );
  test('the 401 retry cannot exceed the minute budget', () async {
    for (var i = 0; i < 7; i++) {
      await dio.get(
        '/v1/calendar',
        queryParameters: {'date': '2026-11-${i + 1}'},
      );
    }
    reply = (_) => _body(401);
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    expect(sends, 8);
    expect(refreshes, 1);
    expect(transport.counters['requests'], 8);
  });
  test('user reader cannot be constructed with the shared Preview key or admin key', () {
    expect(
      () => PassivePreviewTransport(
        baseUri: Uri.parse(dio.options.baseUrl),
        clientKey: 'synthetic-preview-key',
        userSession: ({String? rejectedToken}) async => null,
        currentScope: () => scope,
        retryClient: dio,
        publishableKey: 'sb_publishable_fixture',
      ),
      throwsArgumentError,
    );
    expect(
      () => PassivePreviewTransport(
        baseUri: Uri.parse(dio.options.baseUrl),
        userSession: ({String? rejectedToken}) async => null,
        currentScope: () => scope,
        retryClient: dio,
        publishableKey: 'sb_secret_invalid',
      ),
      throwsArgumentError,
    );
  });
}

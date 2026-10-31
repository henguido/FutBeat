import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';

// Contract candidate from autonomous-244/API-CONTRACTS.md. No network socket,
// production endpoint, credentials or implicit provider fallback exists here.
class _StoredReply implements HttpClientAdapter {
  int status = 200;
  bool acknowledge = true;
  Json? initialPayload;
  final requests = <RequestOptions>[];
  Json payload = {
    'matchId': 'fb_match_stored245',
    'available': true,
    'pending': false,
    'hydrationNeeded': true,
    'detailLevel': 'partial',
    'coverage': {'storedRead': true},
    'home': <String, dynamic>{},
    'away': <String, dynamic>{},
    'statistics': <Json>[],
    'incidents': <Json>[],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) async {
    requests.add(options);
    final initial = requests.length == 1 ? initialPayload : null;
    return ResponseBody.fromString(
      jsonEncode(initial ?? payload),
      initial == null ? status : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (acknowledge) 'x-futbeat-qa-stored': ['v1'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late _StoredReply wire;
  late QaStoredReadInterceptor policy;
  setUp(() {
    wire = _StoredReply();
    final origin = Uri.parse('https://127.0.0.1:9');
    policy = QaStoredReadInterceptor(
      origin: origin,
      sessionLimit: 30,
      minuteLimit: 8,
      concurrentLimit: 2,
      sessionDuration: const Duration(minutes: 15),
    );
    dio = Dio(BaseOptions(baseUrl: origin.toString()))
      ..httpClientAdapter = wire
      ..interceptors.add(policy);
  });
  tearDown(() {
    policy.close();
    dio.close(force: true);
  });

  Future<MatchDetail> settledProvider() async {
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(ApiRepository(dio)),
        detailPollScheduleProvider.overrideWithValue(const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ]),
      ],
    );
    addTearDown(container.dispose);
    final settled = Completer<MatchDetail>();
    final subscription = container.listen(
      matchDetailProvider('fb_match_stored245'),
      (previous, next) {
        final detail = next.asData?.value;
        if (detail != null && !detail.pending && !settled.isCompleted) {
          settled.complete(detail);
        }
      },
    );
    addTearDown(subscription.close);
    return settled.future.timeout(const Duration(seconds: 5));
  }

  test(
    'pending=false preserves missing coverage without passive polling',
    () async {
      final detail = await settledProvider();
      expect(detail.pending, isFalse);
      expect(detail.hydrationNeeded, isTrue);
      expect(detail.json['coverage']['storedRead'], isTrue);
      expect(wire.requests, hasLength(1));
      expect(wire.requests.single.path, '/v1/qa-stored/match-detail');
      expect(policy.counters, {'requests': 1, 'active': 0, 'blocked': 0});
    },
  );

  test('acknowledged passive detail 404 must settle without polling nonexistent work', () async {
    wire.status = 404;
    wire.payload = {'error': 'not_stored'};
    final detail = await settledProvider();
    expect(detail.available, isFalse);
    expect(detail.pending, isFalse);
    // The passive reader cannot materialize anything in the background.
    // Repeated reads of this known absence waste the finite 30-call session.
    expect(wire.requests, hasLength(1));
    expect(wire.requests.single.path, '/v1/qa-stored/match-detail');
    expect(policy.counters['active'], 0);
  });

  test(
    'passive 404 during refresh stops polling and preserves shown detail',
    () async {
      wire.initialPayload = {...wire.payload, 'pending': true};
      wire.status = 404;
      wire.payload = {'error': 'not_stored'};
      final detail = await settledProvider();
      expect(detail.available, isTrue);
      expect(detail.pending, isFalse);
      expect(detail.hydrationNeeded, isTrue);
      expect(detail.json['coverage']['storedRead'], isTrue);
      expect(wire.requests, hasLength(2));
      expect(
        wire.requests.map((request) => request.path),
        everyElement('/v1/qa-stored/match-detail'),
      );
      expect(policy.counters['active'], 0);
    },
  );

  test('absence helper requires exact passive GET status and single ACK', () {
    DioException failure({
      int status = 404,
      String path = '/v1/qa-stored/match-detail',
      String method = 'GET',
      List<String>? ack = const ['v1'],
    }) {
      final options = RequestOptions(path: path, method: method);
      return DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: status,
          headers: Headers.fromMap({
            if (ack != null) 'x-futbeat-qa-stored': ack,
          }),
        ),
        type: DioExceptionType.badResponse,
      );
    }

    expect(isQaStoredDetailAbsent(failure()), isTrue);
    for (final error in <Object>[
      failure(status: 403),
      failure(status: 503),
      failure(ack: null),
      failure(ack: const ['v2']),
      failure(ack: const ['v1', 'v1']),
      failure(path: '/v1/match-detail'),
      failure(path: '/v1/qa-stored/calendar'),
      failure(method: 'POST'),
      StateError('synthetic'),
    ]) {
      expect(isQaStoredDetailAbsent(error), isFalse);
    }
  });

  test(
    '404 with ACK means not stored, never an ordinary-route fallback',
    () async {
      wire.status = 404;
      wire.payload = {'error': 'not_stored'};
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(wire.requests.single.path, '/v1/qa-stored/calendar');
      expect(policy.counters, {'requests': 1, 'active': 0, 'blocked': 0});
      // A known missing item is not evidence the passive contract is disabled.
      wire.status = 200;
      await dio.get('/v1/match-context');
      expect(wire.requests.map((request) => request.path), [
        '/v1/qa-stored/calendar',
        '/v1/qa-stored/match-context',
      ]);
    },
  );

  test('disabled 404 without ACK seals the session', () async {
    wire.status = 404;
    wire.acknowledge = false;
    wire.payload = {'error': 'disabled'};
    await expectLater(
      dio.get('/v1/match-detail'),
      throwsA(isA<DioException>()),
    );
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    expect(wire.requests, hasLength(1));
    expect(policy.counters, {'requests': 1, 'active': 0, 'blocked': 1});
  });

  test(
    'forbidden passive route stays an error without retries or fallback',
    () async {
      wire.status = 403;
      wire.payload = {'error': 'out_of_scope'};
      await expectLater(
        dio.get('/v1/match-context'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            403,
          ),
        ),
      );
      expect(wire.requests.single.path, '/v1/qa-stored/match-context');
      expect(policy.counters, {'requests': 1, 'active': 0, 'blocked': 0});
    },
  );
}

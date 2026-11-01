import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';

const _id = 'fb_match_passive_reopen246';

class _Wire implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool hydrationNeeded = true;
  bool includeStoredMetadata = true;
  bool acknowledge = true;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancellation,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'matchId': _id,
        'available': true,
        'pending': false,
        'hydrationNeeded': hydrationNeeded,
        'detailLevel': 'partial',
        'coverage': {if (includeStoredMetadata) 'storedRead': true},
        'home': <String, dynamic>{},
        'away': <String, dynamic>{},
        'statistics': <Json>[],
        'incidents': <Json>[],
      }),
      200,
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
  late _Wire wire;
  QaStoredReadInterceptor? policy;
  ApiRepository create({bool passive = true}) {
    wire = _Wire();
    dio = Dio(BaseOptions(baseUrl: 'https://127.0.0.1:9'))
      ..httpClientAdapter = wire;
    if (passive) {
      policy = QaStoredReadInterceptor(
        origin: Uri.parse('https://127.0.0.1:9'),
        sessionLimit: 30,
        minuteLimit: 8,
        concurrentLimit: 2,
        sessionDuration: const Duration(minutes: 15),
      );
      dio.interceptors.add(policy!);
    }
    return ApiRepository(dio);
  }

  tearDown(() {
    policy?.close();
    policy = null;
    dio.close(force: true);
  });

  test('partial stored detail reopens with one read, not a demand-shaped duplicate', () async {
    final repo = create();
    await repo.loadMatchDetail(_id);
    final second = await repo.loadMatchDetail(_id);
    expect(second.available, isTrue);
    expect(second.pending, isFalse);
    expect(second.hydrationNeeded, isTrue);
    expect(second.json['coverage']['storedRead'], isTrue);
    expect(wire.requests, hasLength(2));
    expect(
      wire.requests.map((r) => r.path),
      everyElement('/v1/qa-stored/match-detail'),
    );
    expect(wire.requests[1].queryParameters, {'id': _id, 'request': '0'});
    expect(policy!.counters, {'requests': 2, 'active': 0, 'blocked': 0});
  });
  test('repeated stored partial visits consume one budget slot each', () async {
    final repo = create();
    for (var i = 0; i < 3; i++) {
      await repo.loadMatchDetail(_id);
    }
    expect(wire.requests, hasLength(3));
    expect(policy!.counters, {'requests': 3, 'active': 0, 'blocked': 0});
  });
  test(
    'stored policy suppresses duplicates even without optional stored metadata',
    () async {
      final repo = create();
      wire.includeStoredMetadata = false;
      await repo.loadMatchDetail(_id);
      final detail = await repo.loadMatchDetail(_id);
      expect(detail.hydrationNeeded, isTrue);
      expect(detail.json['coverage'], isEmpty);
      expect(wire.requests, hasLength(2));
    },
  );
  test(
    'ordinary incomplete detail still performs its request-aware fallback',
    () async {
      final repo = create(passive: false);
      await repo.loadMatchDetail(_id);
      await repo.loadMatchDetail(_id);
      expect(wire.requests, hasLength(3));
      expect(
        wire.requests.map((r) => r.path),
        everyElement('/v1/match-detail'),
      );
      expect(wire.requests.map((r) => r.queryParameters['request']), [
        null,
        '0',
        null,
      ]);
    },
  );
  test('ordinary complete detail does not gain an extra request', () async {
    final repo = create(passive: false);
    wire.hydrationNeeded = false;
    await repo.loadMatchDetail(_id);
    await repo.loadMatchDetail(_id);
    expect(wire.requests, hasLength(2));
  });
  test(
    'unacknowledged stored reopen remains an error without fallback',
    () async {
      final repo = create();
      await repo.loadMatchDetail(_id);
      wire.acknowledge = false;
      await expectLater(
        repo.loadMatchDetail(_id),
        throwsA(isA<DioException>()),
      );
      expect(wire.requests, hasLength(2));
      expect(policy!.counters['active'], 0);
    },
  );
}

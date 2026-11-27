import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/passive_preview_transport.dart';

class _Wire implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'history route requires the existing individual FutBeat session',
    () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://fixture.invalid/functions/v1/futbeat-api',
        ),
      );
      final wire = _Wire();
      dio.httpClientAdapter = wire;
      final transport = PassivePreviewTransport(
        baseUri: Uri.parse(dio.options.baseUrl),
        publishableKey: 'sb_publishable_fixture',
        currentScope: () => 'fixture-user',
        retryClient: dio,
        userSession: ({String? rejectedToken}) async =>
            (accessToken: 'synthetic-token', scope: 'fixture-user'),
      );
      dio.interceptors.add(transport);
      addTearDown(() {
        transport.close();
        dio.close(force: true);
      });
      await dio.get(
        '/v1/match-last-lineups',
        queryParameters: {'id': 'fb_match_target'},
      );
      expect(wire.calls, 1);
      await expectLater(
        dio.post('/v1/match-last-lineups'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get(
          '/v1/match-last-lineups',
          queryParameters: {'providerKey': 'bad'},
        ),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get('https://provider.invalid/v1/match-last-lineups'),
        throwsA(isA<DioException>()),
      );
      expect(wire.calls, 1);
    },
  );
  test('history route is not added to the passive Preview allowlist', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://fixture.invalid/functions/v1/futbeat-passive-api',
      ),
    );
    final wire = _Wire();
    dio.httpClientAdapter = wire;
    final transport = PassivePreviewTransport(
      baseUri: Uri.parse(dio.options.baseUrl),
    );
    dio.interceptors.add(transport);
    addTearDown(() {
      transport.close();
      dio.close(force: true);
    });
    await expectLater(
      dio.get(
        '/v1/match-last-lineups',
        queryParameters: {'id': 'fb_match_target'},
      ),
      throwsA(isA<DioException>()),
    );
    expect(wire.calls, 0);
  });
}

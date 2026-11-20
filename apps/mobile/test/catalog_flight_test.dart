import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';

Map<String, dynamic> catalog() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-06T00:00:00Z',
  for (final key in [
    'teams',
    'players',
    'competitions',
    'matches',
    'standings',
  ])
    key: <dynamic>[],
};

void main() {
  test('different country parameters never share catalog responses', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    addTearDown(() => dio.close(force: true));
    final countries = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final country = options.queryParameters['country'] as String;
          countries.add(country);
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                ...catalog(),
                'teams': [
                  {'id': 'fb_team_$country', 'name': country},
                ],
              },
            ),
          );
        },
      ),
    );
    final repo = ApiRepository(dio);
    final answers = await Future.wait([
      repo.searchCatalog('arsenal', 'CR'),
      repo.searchCatalog('arsenal', 'ES'),
    ]);
    expect(countries, ['CR', 'ES']);
    expect(answers[0].teams.single.name, 'CR');
    expect(answers[1].teams.single.name, 'ES');
  });

  test('abandoned flight is cancelled and a later search can retry', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    addTearDown(() => dio.close(force: true));
    final first = Completer<RequestOptions>();
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls++;
          if (calls == 1) {
            first.complete(options);
          } else {
            handler.resolve(Response(requestOptions: options, data: catalog()));
          }
        },
      ),
    );
    final repo = ApiRepository(dio);
    final token = CancelToken();
    final abandoned = repo.searchCatalog('arsenal', 'CR', cancelToken: token);
    final check = expectLater(abandoned, throwsA(isA<DioException>()));
    final options = await first.future;
    token.cancel('Search closed');
    await check;
    expect(options.cancelToken!.isCancelled, isTrue);
    expect((await repo.searchCatalog('arsenal', 'CR')).demo, isFalse);
    expect(calls, 2);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
    'concurrent equivalent searches use one HTTP request and memory cache',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() => dio.close(force: true));
      final pending =
          <({RequestOptions options, RequestInterceptorHandler handler})>[];
      final started = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            pending.add((options: options, handler: handler));
            if (!started.isCompleted) started.complete();
          },
        ),
      );
      final repo = ApiRepository(dio);
      final a = repo.searchCatalog(' Arsenal ', 'cr');
      final b = repo.searchCatalog('arsenal', 'CR');
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final requests = pending.length;
      for (final request in pending) {
        request.handler.resolve(
          Response(requestOptions: request.options, data: catalog()),
        );
      }
      await Future.wait([a, b]);
      await repo.searchCatalog('arsenal', 'CR');
      expect(
        requests,
        1,
        reason: 'One resource/parameter set must share its flight',
      );
      expect(
        pending.length,
        1,
        reason: 'A completed result must remain cached',
      );
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'cancelling one search waiter leaves the other consumer alive',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() => dio.close(force: true));
      final pending =
          <({RequestOptions options, RequestInterceptorHandler handler})>[];
      final started = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            pending.add((options: options, handler: handler));
            if (!started.isCompleted) started.complete();
          },
        ),
      );
      final repo = ApiRepository(dio);
      final token = CancelToken();
      final abandoned = repo.searchCatalog('arsenal', 'CR', cancelToken: token);
      final abandonedCheck = expectLater(
        abandoned,
        throwsA(isA<DioException>()),
      );
      final retained = repo.searchCatalog('arsenal', 'CR');
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('Query changed');
      await abandonedCheck;
      for (final request in pending) {
        request.handler.resolve(
          Response(requestOptions: request.options, data: catalog()),
        );
      }
      expect((await retained).demo, isFalse);
      expect(pending.length, 1);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}

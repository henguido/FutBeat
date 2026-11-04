import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/passive_preview_transport.dart';

/// The app still requests its synthetic HTTPS origin. This test-only adapter
/// sends the approved request to an actual loopback HTTP fixture server.
class LoopbackAdapter implements HttpClientAdapter {
  LoopbackAdapter(this.port);
  final int port;
  final client = HttpClient();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: options.uri.path,
      query: options.uri.query,
    );
    final request = await client.getUrl(uri);
    request.followRedirects = options.followRedirects;
    options.headers.forEach(
      (name, value) => request.headers.set(name, value.toString()),
    );
    final response = await request.close();
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) => headers[name] = values);
    return ResponseBody(
      response.map(Uint8List.fromList),
      response.statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) => client.close(force: force);
}

void main() {
  test(
    'API276 wire fixture: passive read, rate limit and sticky revoke',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      final statuses = [200, 429, 403];
      server.listen((request) async {
        requests.add('${request.method} ${request.uri}');
        request.response
          ..statusCode = statuses[requests.length - 1]
          ..headers.contentType = ContentType.json
          ..headers.set('x-futbeat-passive', 'v1')
          ..headers.set('x-futbeat-qa-stored', 'v1')
          ..headers.set('retry-after', '2')
          ..write('{}');
        await request.response.close();
      });
      final base = Uri.parse(
        'https://fixture.invalid/functions/v1/futbeat-passive-api',
      );
      var now = DateTime.utc(2026, 11, 4);
      final transport = PassivePreviewTransport(
        baseUri: base,
        clock: () => now,
      );
      final dio = Dio(BaseOptions(baseUrl: base.toString()))
        ..httpClientAdapter = LoopbackAdapter(server.port)
        ..interceptors.add(transport);
      addTearDown(() => dio.close(force: true));
      expect((await dio.get('/v1/calendar')).statusCode, 200);
      await expectLater(
        dio.get('/v1/calendar'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            429,
          ),
        ),
      );
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(requests, hasLength(2));
      now = now.add(const Duration(seconds: 2));
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      await expectLater(dio.get('/v1/snapshot'), throwsA(isA<DioException>()));
      expect(
        requests,
        List.filled(
          3,
          'GET /functions/v1/futbeat-passive-api/v1/qa-stored/calendar',
        ),
      );
    },
  );
}

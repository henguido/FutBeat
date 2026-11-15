import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Test-only wire: logical HTTPS policy, ephemeral loopback HTTP transport.
/// Does not exercise TLS or prove deployment of a production contract.
class StoredFixtureWire implements HttpClientAdapter {
  StoredFixtureWire(this.port);
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
      throw StateError('Fixture transport forbids non-loopback destinations');
    }
    try {
      return await delegate.fetch(
        options.copyWith(baseUrl: 'http://127.0.0.1:$port'),
        stream,
        cancellation,
      );
    } on DioException catch (error) {
      throw error.copyWith(requestOptions: options);
    }
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

/// No remote credentials, proxy, provider, or production endpoint required.
class StoredFixtureServer {
  StoredFixtureServer._(this.server);
  final HttpServer server;
  final payloads = <String, Map<String, dynamic>>{};
  final requests = <Uri>[];
  int status = 200;
  int bytes = 0;
  final elapsedMicros = <int>[];
  Uri get origin => Uri.parse('https://127.0.0.1:${server.port}');
  static Future<StoredFixtureServer> start() async {
    final fixture = StoredFixtureServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) async {
      final timer = Stopwatch()..start();
      fixture.requests.add(request.uri);
      final payload = fixture.payloads[request.uri.path];
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('x-futbeat-qa-stored', 'v1');
      request.response.statusCode = request.method == 'GET' && payload != null
          ? fixture.status
          : HttpStatus.forbidden;
      final body = jsonEncode(payload ?? {'error': 'fixture_route_forbidden'});
      fixture.bytes += utf8.encode(body).length;
      request.response.write(body);
      await request.response.close();
      fixture.elapsedMicros.add(timer.elapsedMicroseconds);
    });
    return fixture;
  }

  Future<void> close() async => server.close(force: true);
}

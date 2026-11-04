import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/sports_image_cache.dart';

class _FixtureHeaders implements HttpHeaders {
  _FixtureHeaders({this.contentType, this.location});
  @override
  final ContentType? contentType;
  final String? location;
  @override
  String? value(String name) =>
      name.toLowerCase() == 'location' ? location : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse({
    required this.statusCode,
    required this.headers,
    this.contentLength = -1,
    this.isRedirect = false,
  }) {
    body = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
  }
  late final StreamController<List<int>> body;
  bool cancelled = false;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  final int contentLength;
  @override
  final bool isRedirect;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureRequest implements HttpClientRequest {
  _FixtureRequest(this.response);
  final HttpClientResponse response;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureClient implements HttpClient {
  _FixtureClient(this.responses);
  final List<HttpClientResponse> responses;
  final requests = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requests.add(uri);
    return _FixtureRequest(responses.removeAt(0));
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media244-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  for (final rejected in [
    'status',
    'content-type',
    'oversize',
    'unsafe-redirect',
  ]) {
    test(
      'discard $rejected body without waiting for server to finish streaming',
      () async {
        final response = _FixtureResponse(
          statusCode: rejected == 'status'
              ? 503
              : rejected == 'unsafe-redirect'
              ? 302
              : 200,
          headers: _FixtureHeaders(
            contentType: ContentType(
              rejected == 'content-type' ? 'text' : 'image',
              'png',
            ),
            location: rejected == 'unsafe-redirect'
                ? 'http://unsafe.example.test/photo.png'
                : null,
          ),
          isRedirect: rejected == 'unsafe-redirect',
          contentLength: rejected == 'oversize' ? 3 * 1024 * 1024 : -1,
        );
        addTearDown(response.body.close);
        final client = _FixtureClient([response]);
        final cache = SportsImageDiskCache(directory: directory);
        final file = await HttpOverrides.runZoned(
          () => cache.resolve(
            canonicalId: 'fb_player_fixture244',
            url: 'https://media.example.test/photo.png',
          ),
          createHttpClient: (_) => client,
        ).timeout(const Duration(seconds: 1));
        expect(file, isNull);
        expect(response.cancelled, isTrue);
        expect(client.closed, isTrue);
        expect(client.requests.length, 1);
        expect(directory.listSync(), isEmpty);
      },
    );
  }

  test(
    'HTTPS redirect discards its body and fetches one bounded image',
    () async {
      final redirect = _FixtureResponse(
        statusCode: 302,
        headers: _FixtureHeaders(location: '/canonical.png'),
        isRedirect: true,
      );
      final image = _FixtureResponse(
        statusCode: 200,
        headers: _FixtureHeaders(contentType: ContentType('image', 'png')),
      );
      addTearDown(redirect.body.close);
      addTearDown(image.body.close);
      final png = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      image.body.add(png);
      unawaited(image.body.close());
      final client = _FixtureClient([redirect, image]);
      final cache = SportsImageDiskCache(directory: directory);
      final file = await HttpOverrides.runZoned(
        () => cache.resolve(
          canonicalId: 'fb_player_fixture244',
          url: 'https://media.example.test/photo.png',
        ),
        createHttpClient: (_) => client,
      ).timeout(const Duration(seconds: 1));
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), png);
      expect(redirect.cancelled, isTrue);
      expect(client.requests.map((uri) => uri.path), [
        '/photo.png',
        '/canonical.png',
      ]);
      expect(client.closed, isTrue);
    },
  );
  test('complete HTTP deadline stops a valid slow-drip body and frees identity', () async {
    final stalled = _FixtureResponse(
      statusCode: 200,
      headers: _FixtureHeaders(contentType: ContentType('image', 'png')),
    );
    final client = _FixtureClient([stalled]);
    final failures = <Object>[];
    final cache = SportsImageDiskCache(
      directory: directory,
      downloadTimeout: const Duration(milliseconds: 50),
      onError: failures.add,
    );
    // Keep sending below the old 8-second idle timeout. This body never ends;
    // its progress must not reset the aggregate HTTP deadline.
    stalled.body.add([1]);
    final drip = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (!stalled.body.isClosed) stalled.body.add([1]);
    });
    addTearDown(() async {
      drip.cancel();
      await stalled.body.close();
    });
    final file = await HttpOverrides.runZoned(
      () => cache.resolve(
        canonicalId: 'fb_player_deadline244',
        url: 'https://media.example.test/drip.png',
      ),
      createHttpClient: (_) => client,
    ).timeout(const Duration(seconds: 5));
    drip.cancel();
    // End the fake transport too, like the real HttpClient.close(force: true).
    await stalled.body.close();
    expect(file, isNull);
    expect(failures.single, isA<TimeoutException>());
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);

    final image = _FixtureResponse(
      statusCode: 200,
      headers: _FixtureHeaders(contentType: ContentType('image', 'png')),
    );
    // The successful retry must carry a decoder-valid image, not arbitrary bytes.
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    image.body.add(bytes);
    unawaited(image.body.close());
    final retryClient = _FixtureClient([image]);
    final retried = await HttpOverrides.runZoned(
      () => cache.resolve(
        canonicalId: 'fb_player_deadline244',
        url: 'https://media.example.test/drip.png',
      ),
      createHttpClient: (_) => retryClient,
    ).timeout(const Duration(seconds: 5));
    expect(retried, isNotNull);
    expect(await retried!.readAsBytes(), bytes);
    expect(retryClient.requests, hasLength(1));
    expect(retryClient.closed, isTrue);
  });

  test('image deadline cannot be disabled or expanded', () {
    for (final timeout in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(seconds: 16),
    ]) {
      expect(
        () => SportsImageDiskCache(
          directory: directory,
          downloadTimeout: timeout,
        ),
        throwsArgumentError,
      );
    }
  });
}

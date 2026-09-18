import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';

void main() {
  final providerUrl = Platform.environment['FUTBEAT_VERIFY_URL'];
  if (providerUrl != null) {
    test(
      'real persisted provider snapshot reaches the mobile repository',
      () async {
        final token = Platform.environment['FUTBEAT_VERIFY_TOKEN'];
        final dio = Dio(
          BaseOptions(
            baseUrl: providerUrl,
            headers: token == null ? null : {'Authorization': 'Bearer $token'},
          ),
        );
        addTearDown(() => dio.close(force: true));
        final snapshot = await ApiRepository(dio).load();
        expect(snapshot.demo, isFalse);
        expect(snapshot.coverage?['source'], 'TheSportsDB');
        expect(snapshot.matches, isNotEmpty);
        for (final match in snapshot.matches) {
          expect(snapshot.team(match.homeId), isNotNull);
          expect(snapshot.team(match.awayId), isNotNull);
          expect(match.json['provenance']['verificationStatus'], 'PROVISIONAL');
        }
      },
    );
  }
  test(
    'Dio reads canonical snapshot over HTTP and surfaces server failures',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var failed = false;
      server.listen((request) async {
        if (failed) {
          request.response.statusCode = 503;
        } else {
          request.response.headers.contentType = ContentType.json;
          final body = File('assets/demo.snapshot.json')
              .readAsStringSync()
              .replaceFirst('"demo": true', '"demo": false');
          request.response.write(body);
        }
        await request.response.close();
      });
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      try {
        final repository = ApiRepository(dio);
        final snapshot = await repository.load();
        expect(snapshot.match('fb_match_clasico')!.score, '2 - 1');
        failed = true;
        await expectLater(repository.load(), throwsA(isA<DioException>()));
      } finally {
        dio.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test('calendar day is loaded from FutBeat instead of an external provider', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Uri? requested;
    server.listen((request) async {
      requested = request.uri;
      request.response.headers.contentType = ContentType.json;
      final body = File('assets/demo.snapshot.json')
          .readAsStringSync()
          .replaceFirst('"demo": true', '"demo": false');
      request.response.write(body);
      await request.response.close();
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    try {
      final snapshot = await ApiRepository(dio).loadDate(DateTime(2026, 9, 18));
      expect(snapshot.demo, isFalse);
      expect(requested?.path, '/v1/calendar');
      expect(requested?.queryParameters['date'], '2026-09-18');
      expect(
        requested?.queryParameters['timezone'],
        'America/Costa_Rica',
      );
    } finally {
      dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('entity detail is loaded from the FutBeat canonical endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Uri? requested;
    server.listen((request) async {
      requested = request.uri;
      request.response.headers.contentType = ContentType.json;
      final body = File('assets/demo.snapshot.json')
          .readAsStringSync()
          .replaceFirst('"demo": true', '"demo": false');
      request.response.write(body);
      await request.response.close();
    });

    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    try {
      final snapshot = await ApiRepository(dio).loadEntity(
        'team',
        'fb_team_sap',
      );
      expect(snapshot.demo, isFalse);
      expect(requested?.path, '/v1/entity');
      expect(requested?.queryParameters['type'], 'team');
      expect(requested?.queryParameters['id'], 'fb_team_sap');
    } finally {
      dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('cloud repository never silently accepts demo data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        File('assets/demo.snapshot.json').readAsStringSync(),
      );
      await request.response.close();
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    try {
      await expectLater(ApiRepository(dio).load(), throwsA(isA<StateError>()));
    } finally {
      dio.close(force: true);
      await server.close(force: true);
    }
  });
}

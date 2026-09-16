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
        final dio = Dio(BaseOptions(baseUrl: providerUrl));
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
          request.response.write(
            File('assets/demo.snapshot.json').readAsStringSync(),
          );
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
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<ResponseBody> Function(RequestOptions) reply;
  final List<String> paths = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    paths.add(options.path);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const base = 'https://fixture.test/functions/v1/futbeat-api';
  ResponseBody answer(Object data, {bool ack = true}) =>
      ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          if (ack) 'x-futbeat-qa-stored': ['v1'],
        },
      );
  test(
    'all Dart HTTP is rejected before a socket in local-cache mode',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        expect(() => HttpClient(), throwsA(isA<SocketException>()));
      }, QaOfflineHttpOverrides());
    },
  );
  test(
    'SQLite restart serves real calendar/context/detail with HTTP blocked',
    () async {
      final fixture = jsonDecode(
        File('test/fixtures/everton_newcastle_qa225_timeline.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final match = Map<String, dynamic>.from(fixture['match']);
      final id = match['id'] as String;
      final snapshot = {
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'matches': [match],
        'teams': [
          {'id': match['homeTeamId'], 'name': 'Everton'},
          {'id': match['awayTeamId'], 'name': 'Newcastle United'},
        ],
        'players': [],
        'competitions': [
          {'id': match['competitionId'], 'name': 'League Cup'},
        ],
        'standings': [],
        'news': [],
        'transfers': [],
      };
      final folder = await Directory.systemTemp.createTemp('qa227-sqlite-');
      final file = File('${folder.path}/public.sqlite');
      final before = AppDatabase(NativeDatabase(file));
      await before.saveCalendarSnapshot('2026-10-29', jsonEncode(snapshot));
      await before.savePublicSnapshot(
        'public:match-context:$id',
        jsonEncode(snapshot),
      );
      await before.savePublicSnapshot(
        'public:match-detail:$id',
        jsonEncode(fixture['detail']),
      );
      await before.close();
      final after = AppDatabase(NativeDatabase(file));
      final dio = Dio(BaseOptions(baseUrl: base));
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final repo = ApiRepository(dio, after);
          final calendar = await repo.watchDate(DateTime(2026, 10, 29)).first;
          expect(calendar.matches.single.id, id);
          expect(
            (await repo.readStoredMatchDetail(id))!.incidents,
            hasLength(22),
          );
          expect((await repo.loadMatchContext(id)).matches.single.id, id);
          repo.setAppActive(false);
        }, QaOfflineHttpOverrides());
      } finally {
        dio.close(force: true);
        await after.close();
        await folder.delete(recursive: true);
      }
    },
  );
  test('real cached detail fixture is read through dedicated route, never ordinary demand route', () async {
    final fixture = jsonDecode(
      File('test/fixtures/everton_newcastle_qa225_timeline.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final adapter = _Adapter((_) async => answer(fixture['detail']));
    final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
    final policy = QaStoredReadInterceptor(origin: Uri.parse(base));
    dio.interceptors.add(policy);
    final detail = await ApiRepository(dio)
        .loadMatchDetail('fb_match_e1a2f376dd034af69f203f5bb959c73e');
    expect(detail.incidents, hasLength(22));
    expect(adapter.paths, ['/v1/qa-stored/match-detail']);
    expect(policy.counters['requests'], 1);
    dio.close();
  });
  test('writes, unknown routes, other hosts, redirects and exhausted budget are blocked', () async {
    var now = DateTime.utc(2026, 10, 31);
    final adapter = _Adapter((options) async {
      expect(options.followRedirects, false);
      return answer({});
    });
    final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
    final policy = QaStoredReadInterceptor(
      origin: Uri.parse(base),
      clock: () => now,
      sessionLimit: 2,
      minuteLimit: 1,
    );
    dio.interceptors.add(policy);
    await expectLater(dio.post('/v1/calendar'), throwsA(isA<DioException>()));
    await expectLater(dio.get('/v1/entity'), throwsA(isA<DioException>()));
    await expectLater(
      dio.get('https://provider.test/v1/calendar'),
      throwsA(isA<DioException>()),
    );
    await dio.get('/v1/calendar');
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    now = now.add(const Duration(minutes: 1));
    await dio.get('/v1/calendar');
    now = now.add(const Duration(minutes: 1));
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    expect(adapter.paths, hasLength(2));
    expect(policy.counters['active'], 0);
    dio.close();
  });
  test(
    'two concurrent reads maximum and STOP forbids further navigation',
    () async {
      final release = Completer<void>();
      final adapter = _Adapter((_) async {
        await release.future;
        return answer({});
      });
      final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
      final policy = QaStoredReadInterceptor(origin: Uri.parse(base));
      dio.interceptors.add(policy);
      final first = dio.get('/v1/calendar');
      final second = dio.get('/v1/match-context');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(
        dio.get('/v1/match-detail'),
        throwsA(isA<DioException>()),
      );
      final firstStopped = expectLater(first, throwsA(isA<DioException>()));
      final secondStopped = expectLater(second, throwsA(isA<DioException>()));
      policy.close();
      release.complete();
      await Future.wait([firstStopped, secondStopped]);
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(adapter.paths, hasLength(2));
      expect(policy.counters['active'], 0);
      dio.close();
    },
  );
  test(
    'old server without stored-read contract cannot cause ordinary-route retry',
    () async {
      final adapter = _Adapter((_) async => answer({}, ack: false));
      final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
      dio.interceptors.add(QaStoredReadInterceptor(origin: Uri.parse(base)));
      await expectLater(
        ApiRepository(dio).loadMatchDetail('fb_match_test'),
        throwsA(isA<DioException>()),
      );
      await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
      expect(adapter.paths, ['/v1/qa-stored/match-detail']);
      dio.close();
    },
  );
  test('404 from an old or disabled backend seals the transport', () async {
    final adapter = _Adapter((_) async => ResponseBody.fromString('{}', 404));
    final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
    dio.interceptors.add(QaStoredReadInterceptor(origin: Uri.parse(base)));
    await expectLater(dio.get('/v1/calendar'), throwsA(isA<DioException>()));
    await expectLater(
      dio.get('/v1/match-detail'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.paths, ['/v1/qa-stored/calendar']);
    dio.close();
  });
}

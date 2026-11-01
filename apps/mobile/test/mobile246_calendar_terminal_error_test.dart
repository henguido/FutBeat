import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';

class _CalendarWire implements HttpClientAdapter {
  List<int> statuses = [200];
  bool cancel = false;
  final requests = <RequestOptions>[];
  final Json payload = {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-11-01T12:00:00Z',
    'competitions': <Json>[
      {'id': 'fb_comp_246', 'name': 'Fixture local competition'},
    ],
    'teams': <Json>[
      {'id': 'fb_team_home246', 'name': 'Fixture local home'},
      {'id': 'fb_team_away246', 'name': 'Fixture local away'},
    ],
    'players': <Json>[],
    'matches': [
      {
        'id': 'fb_match_calendar246',
        'competitionId': 'fb_comp_246',
        'homeTeamId': 'fb_team_home246',
        'awayTeamId': 'fb_team_away246',
        'startTime': '2026-11-01T12:00:00Z',
        'status': 'SCHEDULED',
        'score': {'home': null, 'away': null},
      },
    ],
    'standings': <Json>[],
    'coverage': {'pending': false},
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelled,
  ) async {
    requests.add(options);
    if (cancel)
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    final status =
        statuses[(requests.length - 1).clamp(0, statuses.length - 1)];
    return ResponseBody.fromString(
      jsonEncode(status == 200 ? payload : {'error': 'fixture failure'}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'x-futbeat-qa-stored': ['v1'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late _CalendarWire wire;
  QaStoredReadInterceptor? policy;
  final day = DateTime(2026, 11, 1);
  ApiRepository create({bool passive = false}) {
    wire = _CalendarWire();
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
    // All TTLs zero and no prefetch: independent of the wall-clock date/window.
    return ApiRepository(
      dio,
      null,
      const CalendarCachePolicy(
        todayTtl: Duration.zero,
        pastTtl: Duration.zero,
        futureTtl: Duration.zero,
        recoveringTtl: Duration.zero,
        prefetchRadius: 0,
        visibleDeadline: Duration(seconds: 2),
        maxAttempts: 3,
      ),
    );
  }

  tearDown(() {
    policy?.close();
    policy = null;
    dio.close(force: true);
  });
  for (final status in [400, 401, 403, 404, 422, 429]) {
    test(
      'ordinary calendar status $status terminates without immediate retries',
      () async {
        final repo = create();
        wire.statuses = [status];
        await expectLater(
          repo.watchDate(day, retryDelay: Duration.zero).toList(),
          throwsA(isA<DioException>()),
        );
        expect(wire.requests, hasLength(1));
      },
    );
  }
  test('acknowledged passive calendar 404 stays unavailable after exactly one read', () async {
    final repo = create(passive: true);
    wire.statuses = [404];
    await expectLater(
      repo.watchDate(day, retryDelay: Duration.zero).toList(),
      throwsA(isA<DioException>()),
    );
    expect(wire.requests, hasLength(1));
    expect(wire.requests.single.path, '/v1/qa-stored/calendar');
    expect(policy!.counters, {'requests': 1, 'active': 0, 'blocked': 0});
  });
  for (final status in [403, 404]) {
    test(
      'calendar $status preserves cached match without repeating the error',
      () async {
        final repo = create();
        await repo.loadDate(day);
        wire.statuses = [status];
        final answers = await repo
            .watchDate(day, retryDelay: Duration.zero)
            .toList();
        expect(answers.last.match('fb_match_calendar246'), isNotNull);
        expect(answers.last.stale, isTrue);
        expect(answers.last.calendarPending, isFalse);
        expect(wire.requests, hasLength(2));
      },
    );
  }
  test(
    'transient calendar 503 still retries and can recover within budget',
    () async {
      final repo = create();
      wire.statuses = [503, 503, 200];
      final answers = await repo
          .watchDate(day, retryDelay: Duration.zero)
          .toList();
      expect(answers.last.match('fb_match_calendar246'), isNotNull);
      expect(wire.requests, hasLength(3));
    },
  );
  test(
    'persistent transient errors remain bounded to three attempts',
    () async {
      final repo = create();
      wire.statuses = [503];
      await expectLater(
        repo.watchDate(day, retryDelay: Duration.zero).toList(),
        throwsA(isA<DioException>()),
      );
      expect(wire.requests, hasLength(3));
    },
  );
  test(
    'cancelled calendar request does not schedule replacement requests',
    () async {
      final repo = create();
      wire.cancel = true;
      await expectLater(
        repo.watchDate(day, retryDelay: Duration.zero).toList(),
        throwsA(isA<DioException>()),
      );
      expect(wire.requests, hasLength(1));
    },
  );
}

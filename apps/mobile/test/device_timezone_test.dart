import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/device_time.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/main.dart';
import 'package:futbeat/shared/widgets.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

const zone = String.fromEnvironment('FB_TEST_TIME_ZONE');

class _StoredCalendar implements FootballRepository {
  _StoredCalendar(this.data);
  final Snapshot data;
  @override
  Future<Snapshot> load() async => data;
  @override
  Future<Snapshot> loadDate(DateTime date) async => data;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

// Changes only this Linux test process, never the host/device configuration.
void setTestProcessZone(String value) {
  final libc = DynamicLibrary.open('libc.so.6');
  final allocate = libc
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final release = libc
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  final setenv = libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int)
      >('setenv');
  final tzset = libc.lookupFunction<Void Function(), void Function()>('tzset');
  Pointer<Uint8> string(String text) {
    final bytes = utf8.encode(text);
    final pointer = allocate(bytes.length + 1);
    pointer.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return pointer;
  }

  final name = string('TZ'), zoneName = string(value);
  try {
    expect(setenv(name, zoneName, 1), 0);
    tzset();
  } finally {
    release(name);
    release(zoneName);
  }
}

Json payload(String id, {String start = '2026-07-01T00:30:00Z'}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-07-01T12:00:00Z',
  'teams': [
    {'id': 'home', 'name': 'Local'},
    {'id': 'away', 'name': 'Visitante'},
  ],
  'competitions': [
    {'id': 'league', 'name': 'Liga'},
  ],
  'players': <dynamic>[],
  'standings': <dynamic>[],
  'matches': <Json>[
    <String, dynamic>{
      'id': id,
      'homeTeamId': 'home',
      'awayTeamId': 'away',
      'competitionId': 'league',
      'status': 'SCHEDULED',
      'startTime': start,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'FB-01 stale neighbouring-day data cannot certify an empty local day',
    (tester) async {
      final date = DateTime(2026, 7, 1);
      final old = Snapshot(payload('other-day', start: '2026-07-03T12:00:00Z'))
          .asStale();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(_StoredCalendar(old)),
            calendarSnapshotProvider(date)
                .overrideWith((ref) => Stream.value(old)),
          ],
          child: MaterialApp(
            home: CalendarDataView(
              date: date,
              builder: (data, loading, failed) =>
                  Text('loading=$loading failed=$failed stale=${data.stale}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('loading=false failed=false stale=true'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'FB-01 resume resolves the zone before enabling sports reads and cannot undo a later pause',
    (tester) async {
      Completer<String?>? waiting;
      final clock = DeviceClock(
        zoneId: 'Europe/Madrid',
        readZone: () => waiting?.future ?? Future.value('Europe/Madrid'),
      );
      final container = ProviderContainer(
        overrides: [
          deviceClockProvider.overrideWithValue(clock),
          profileSettingsProvider.overrideWith(
            (ref) async => const UserProfileSettings(),
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/matches',
        routes: [
          GoRoute(
            path: '/matches',
            builder: (_, _) => const Scaffold(body: Text('calendar')),
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: FutBeatApp(router: router),
          ),
        );
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        waiting = Completer<String?>();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(container.read(sportsAppActiveProvider).value, isFalse);
        waiting.complete('America/New_York');
        await tester.pumpAndSettle();
        expect(container.read(sportsAppActiveProvider).value, isTrue);
        expect(clock.calendarZoneId, 'America/New_York');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        waiting = Completer<String?>();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        waiting.complete('Europe/Madrid');
        await tester.pumpAndSettle();
        expect(container.read(sportsAppActiveProvider).value, isFalse);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        clock.dispose();
        router.dispose();
        container.dispose();
      }
    },
  );

  test('FB-01 a native change during a zone read is not dropped', () async {
    final first = Completer<String?>();
    var reads = 0;
    final clock = DeviceClock(
      zoneId: 'Europe/Madrid',
      readZone: () =>
          ++reads == 1 ? first.future : Future.value('America/New_York'),
    );
    try {
      final reading = clock.refresh();
      final queued = clock.refresh();
      first.complete('Europe/Madrid');
      await reading;
      await queued;
      expect(clock.calendarZoneId, 'America/New_York');
      expect(reads, 2);
    } finally {
      clock.dispose();
    }
  });

  test(
    'FB-01 an unavailable native read cannot reuse a previous region for HTTP',
    () async {
      final clock = DeviceClock(
        zoneId: 'Europe/Madrid',
        readZone: () async {
          throw PlatformException(code: 'unavailable');
        },
      );
      try {
        await clock.refresh();
        expect(clock.calendarZoneId, isEmpty);
        expect(clock.now.isUtc, isFalse);
      } finally {
        clock.dispose();
      }
    },
  );

  test(
    'FB-01 unavailable device zone never falls back to a guessed region',
    () async {
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            requests++;
            h.resolve(Response(requestOptions: o, data: payload('unexpected')));
          },
        ),
      );
      final repo = ApiRepository(
        dio,
        null,
        const CalendarCachePolicy(maxAttempts: 1, prefetchRadius: 0),
        null,
        null,
        () => '',
      );
      try {
        await expectLater(
          repo.loadDate(DateTime(2026, 7, 1)),
          throwsStateError,
        );
        expect(requests, 0);
      } finally {
        dio.close(force: true);
      }
    },
  );

  testWidgets(
    'FB-01 calendar keeps a selected civil date across an actual zone change',
    (tester) async {
      final original = Platform.environment['TZ'] ?? 'UTC';
      var configured = 'Europe/Madrid';
      setTestProcessZone(configured);
      final clock = DeviceClock(
        zoneId: configured,
        now: () => DateTime.utc(2026, 7, 1, 12),
        readZone: () async => configured,
      );
      clock.start(android: true);
      final first = payload('day1', start: '2026-07-01T12:00:00Z');
      final second = payload('day2', start: '2026-07-02T12:00:00Z');
      final data = Snapshot({
        ...first,
        'matches': [...first['matches'], ...second['matches']],
      });
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              followsProvider.overrideWith((ref) => Stream.value(<String>{})),
              preferenceProvider.overrideWith(
                (ref) => Stream.value(
                  const CountryPreference(
                    detectedCountry: null,
                    selectedCountry: null,
                    bootstrapDismissed: true,
                  ),
                ),
              ),
              repositoryProvider.overrideWithValue(_StoredCalendar(data)),
              deviceClockProvider.overrideWithValue(clock),
            ],
            child: MaterialApp(
              home: DeviceTimeScope(
                clock: clock,
                child: MatchesScreen(now: () => clock.now),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        List<String> visible() => tester
            .widgetList<MatchCard>(find.byType(MatchCard))
            .map((card) => card.match.id)
            .toList();
        expect(visible(), ['day1']);
        await tester.tap(find.text('MAÑANA'));
        await tester.pumpAndSettle();
        expect(visible(), ['day2']);
        configured = 'America/New_York';
        setTestProcessZone(configured);
        await clock.refresh();
        await tester.pumpAndSettle();
        expect(visible(), ['day2']);
      } finally {
        await tester.pumpWidget(const SizedBox());
        clock.dispose();
        setTestProcessZone(original);
      }
    },
    skip: !Platform.isLinux,
  );

  if (zone.isNotEmpty) {
    test(
      'FB-01 $zone uses the real OS zone, UTC storage and local grouping',
      () {
        final expected = switch (zone) {
          'America/Costa_Rica' => (6, 30, 18, 30, -360),
          'Europe/Madrid' => (7, 1, 2, 30, 120),
          'America/New_York' => (6, 30, 20, 30, -240),
          _ => throw StateError('Unexpected test zone'),
        };
        final raw = payload('midnight');
        final data = Snapshot(raw);
        final instant = data.matches.single.startTime;
        expect(instant.isUtc, isTrue);
        expect(instant.hour, 0);
        expect(raw['matches'][0]['startTime'], '2026-07-01T00:30:00Z');
        final local = instant.toLocal();
        expect((
          local.month,
          local.day,
          local.hour,
          local.minute,
          local.timeZoneOffset.inMinutes,
        ), expected);
        expect(
          data.onDate(DateTime(2026, expected.$1, expected.$2), 'Todos'),
          hasLength(1),
        );
        expect(
          data.onDate(DateTime(2026, expected.$1, expected.$2 + 1), 'Todos'),
          isEmpty,
        );
        expect(
          deviceDayLabel(
            instant,
            now: DateTime(2026, expected.$1, expected.$2, 12),
          ),
          'Hoy',
        );
        expect(
          deviceDayLabel(
            instant,
            now: DateTime(2026, expected.$1, expected.$2 - 1, 12),
          ),
          'Mañana',
        );
        final crossing = DateTime.parse('2026-06-30T23:30:00Z').toLocal();
        expect((
          crossing.month,
          crossing.day,
        ), zone == 'Europe/Madrid' ? (7, 1) : (6, 30));
      },
    );

    test(
      'FB-01 $zone applies winter/summer offsets per instant, not today',
      () {
        final winter = DateTime.parse('2026-01-01T00:30:00Z').toLocal();
        final summer = DateTime.parse('2026-07-01T00:30:00Z').toLocal();
        final offsets = switch (zone) {
          'America/Costa_Rica' => (-360, -360),
          'Europe/Madrid' => (60, 120),
          'America/New_York' => (-300, -240),
          _ => throw StateError('Unexpected test zone'),
        };
        expect((
          winter.timeZoneOffset.inMinutes,
          summer.timeZoneOffset.inMinutes,
        ), offsets);
        if (zone == 'America/New_York') {
          expect(DateTime.parse('2026-03-08T06:59:00Z').toLocal().hour, 1);
          expect(DateTime.parse('2026-03-08T07:01:00Z').toLocal().hour, 3);
          expect(
            DateTime(2026, 3, 9).difference(DateTime(2026, 3, 8)).inHours,
            23,
          );
          expect(
            DateTime(2026, 11, 2).difference(DateTime(2026, 11, 1)).inHours,
            25,
          );
        }
        if (zone == 'Europe/Madrid') {
          expect(DateTime.parse('2026-03-29T00:59:00Z').toLocal().hour, 1);
          expect(DateTime.parse('2026-03-29T01:01:00Z').toLocal().hour, 3);
          expect(
            DateTime(2026, 3, 30).difference(DateTime(2026, 3, 29)).inHours,
            23,
          );
          expect(
            DateTime(2026, 10, 26).difference(DateTime(2026, 10, 25)).inHours,
            25,
          );
        }
      },
    );

    testWidgets('FB-01 $zone renders the converted kickoff once', (
      tester,
    ) async {
      final instant = DateTime.parse('2026-07-01T00:30:00Z');
      final expected = switch (zone) {
        'America/Costa_Rica' => '18:30',
        'Europe/Madrid' => '02:30',
        'America/New_York' => '20:30',
        _ => throw StateError('Unexpected test zone'),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(alwaysUse24HourFormat: true),
              child: Builder(
                builder: (context) => Text(localTime(context, instant)),
              ),
            ),
          ),
        ),
      );
      expect(find.text(expected), findsOneWidget);
    });
  }

  testWidgets(
    'FB-01 real OS time-zone switch updates the open screen and keeps its state',
    (tester) async {
      final original = Platform.environment['TZ'] ?? 'UTC';
      var configured = 'Europe/Madrid';
      setTestProcessZone(configured);
      final instant = DateTime.utc(2026, 7, 1, 0, 30);
      final clock = DeviceClock(
        zoneId: configured,
        now: () => DateTime.utc(2026, 7, 1, 12),
        readZone: () async => configured,
      );
      clock.start(android: true);
      try {
        var count = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: DeviceTimeScope(
              clock: clock,
              child: StatefulBuilder(
                builder: (context, setState) {
                  final current = DeviceTimeScope.watch(context)!;
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(alwaysUse24HourFormat: true),
                    child: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => setState(() => count++),
                        child: Text(
                          '${deviceDayLabel(instant, now: current.now)} ${localTime(context, instant)} $count',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        expect(find.text('Hoy 02:30 0'), findsOneWidget);
        await tester.tap(find.byType(TextButton));
        await tester.pump();
        configured = 'America/New_York';
        setTestProcessZone(configured);
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'futbeat/device',
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('clockChanged'),
              ),
              (_) {},
            );
        await tester.pump();
        expect(instant.toLocal().timeZoneOffset.inMinutes, -240);
        expect(find.text('Mar 30 jun 20:30 1'), findsOneWidget);
        expect(instant, DateTime.utc(2026, 7, 1, 0, 30));
      } finally {
        clock.dispose();
        setTestProcessZone(original);
      }
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'FB-01 open screen refreshes at midnight and on native zone changes without losing state',
    (tester) async {
      var wall = DateTime(2026, 7, 1, 23, 59, 59);
      var configured = 'Europe/Madrid';
      const channel = MethodChannel('futbeat/device');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => configured);
      final clock = DeviceClock(
        now: () => wall,
        readZone: () => channel.invokeMethod<String>('timeZone'),
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) clock.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      clock.start(android: true);
      await tester.pump();
      final instant = DateTime(2026, 7, 2, 12).toUtc();
      var count = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceTimeScope(
            clock: clock,
            child: StatefulBuilder(
              builder: (context, setState) {
                final observed = DeviceTimeScope.watch(context)!;
                return TextButton(
                  onPressed: () => setState(() => count++),
                  child: Text(
                    '${observed.calendarZoneId} ${deviceDayLabel(instant, now: observed.now)} $count',
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('Europe/Madrid Mañana 0'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      wall = DateTime(2026, 7, 2);
      // The midnight timer itself updates the still-open screen.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Europe/Madrid Hoy 1'), findsOneWidget);
      configured = 'America/New_York';
      await messenger.handlePlatformMessage(
        'futbeat/device',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('clockChanged'),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text('America/New_York Hoy 1'), findsOneWidget);
      clock.dispose();
      disposed = true;
    },
  );

  test('FB-01 calendar sends the real zone and isolates late responses and SQLite partitions', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    var currentZone = 'America/Costa_Rica';
    final pending = Completer<void>();
    final entered = Completer<void>();
    final requests = <Map<String, dynamic>>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) async {
          requests.add({...o.queryParameters});
          expect(o.path, '/v1/calendar');
          expect(o.queryParameters['date'], '2026-07-01');
          final old = o.queryParameters['timezone'] == 'America/Costa_Rica';
          if (old) {
            entered.complete();
            await pending.future;
          }
          h.resolve(
            Response(
              requestOptions: o,
              data: payload(old ? 'old-zone' : 'new-zone'),
            ),
          );
        },
      ),
    );
    final repo = ApiRepository(
      dio,
      db,
      const CalendarCachePolicy(prefetchRadius: 0),
      null,
      null,
      () => currentZone,
    );
    try {
      final old = repo.loadDate(DateTime(2026, 7, 1));
      await entered.future;
      currentZone = 'Europe/Madrid';
      await repo.loadDate(DateTime(2026, 7, 1));
      pending.complete();
      await old;
      await repo.settleBackground();
      expect(
        repo.peekDate(DateTime(2026, 7, 1))!.matches.single.id,
        'new-zone',
      );
      for (final z in ['America/Costa_Rica', 'Europe/Madrid']) {
        final cached = jsonDecode(
          (await db.readCalendarSnapshot('2026-07-01@$z'))!,
        );
        expect(cached['matches'][0]['startTime'], '2026-07-01T00:30:00Z');
      }
      expect(requests.map((r) => r['timezone']), [
        'America/Costa_Rica',
        'Europe/Madrid',
      ]);
    } finally {
      dio.close(force: true);
      await db.close();
    }
  });

  test('FB-01 legacy cache survives offline without being claimed fresh in a new zone', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.saveCalendarSnapshot('2026-07-01', jsonEncode(payload('legacy')));
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.reject(
            DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
            ),
          ),
        ),
      );
    final repo = ApiRepository(
      dio,
      db,
      const CalendarCachePolicy(maxAttempts: 1, prefetchRadius: 0),
      null,
      null,
      () => 'Europe/Madrid',
    );
    try {
      final values = await repo
          .watchDate(DateTime(2026, 7, 1), retryDelay: Duration.zero)
          .toList();
      expect(values, isNotEmpty);
      expect(values.every((v) => v.stale), isTrue);
      expect(values.last.matches.single.id, 'legacy');
      expect(await db.readCalendarSnapshot('2026-07-01'), isNotNull);
      expect(await db.readCalendarSnapshot('2026-07-01@Europe/Madrid'), isNull);
    } finally {
      dio.close(force: true);
      await db.close();
    }
  });

  test('FB-01 offline regrouping borrows adjacent days without losing a VERIFIED result', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final previous = payload('verified', start: '2026-06-30T23:30:00Z');
    previous['updatedAt'] = '2026-07-02T00:00:00Z';
    previous['matches'][0]['status'] = 'VERIFIED';
    previous['matches'][0]['score'] = {'home': 2, 'away': 1};
    await db.saveCalendarSnapshot(
      '2026-07-01@Europe/Madrid',
      jsonEncode(previous),
    );
    final dio = Dio();
    var offline = true;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (offline) {
            h.reject(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            h.resolve(
              Response(
                requestOptions: o,
                data: payload('verified', start: '2026-06-30T23:30:00Z'),
              ),
            );
          }
        },
      ),
    );
    final repo = ApiRepository(
      dio,
      db,
      const CalendarCachePolicy(maxAttempts: 1, prefetchRadius: 0),
      null,
      null,
      () => 'America/New_York',
    );
    try {
      final values = await repo
          .watchDate(DateTime(2026, 6, 30), retryDelay: Duration.zero)
          .toList();
      expect(values.last.stale, isTrue);
      expect(values.last.matches.single.status, 'VERIFIED');
      offline = false;
      final current = await repo.loadDate(DateTime(2026, 6, 30));
      await repo.settleBackground();
      expect(current.matches.single.status, 'VERIFIED');
      expect(current.matches.single.score, '2 - 1');
      expect(
        await db.readCalendarSnapshot('2026-06-30@America/New_York'),
        isNotNull,
      );
      expect(
        await db.readCalendarSnapshot('2026-07-01@Europe/Madrid'),
        isNotNull,
      );
    } finally {
      dio.close(force: true);
      await db.close();
    }
  });
}

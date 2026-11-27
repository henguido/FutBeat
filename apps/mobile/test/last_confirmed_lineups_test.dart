import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/last_confirmed_lineups.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/last_confirmed_lineups_section.dart';

const targetId = 'fb_match_target';
FootballMatch target([String status = 'SCHEDULED']) => FootballMatch({
  'id': targetId,
  'homeTeamId': 'fb_team_home',
  'awayTeamId': 'fb_team_away',
  'competitionId': 'fb_comp_current',
  'startTime': '2026-12-02T20:00:00Z',
  'status': status,
});
Snapshot snapshot() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-26T20:00:00Z',
  'teams': [
    {'id': 'fb_team_home', 'name': 'Local'},
    {'id': 'fb_team_away', 'name': 'Visitante'},
    {'id': 'fb_team_rival', 'name': 'Rival anterior'},
  ],
  'competitions': [
    {'id': 'fb_comp_previous', 'name': 'Copa anterior'},
  ],
  'standings': [],
  'players': [],
  'matches': [],
});
Json payload({int starters = 11, bool canonical = false}) => {
  'schemaVersion': 1,
  'matchId': targetId,
  'eligible': true,
  'kind': 'LAST_CONFIRMED',
  'home': {
    'kind': 'LAST_CONFIRMED',
    'teamId': 'fb_team_home',
    'sourceMatch': {
      'matchId': 'fb_match_previous',
      'startTime': '2026-11-28T20:00:00Z',
      'competitionId': 'fb_comp_previous',
      'opponentTeamId': 'fb_team_rival',
      'side': 'away',
    },
    'lineups': [
      for (var i = 0; i < starters + 2; i++)
        {
          'team': 'home',
          'type': i < starters ? 'starting_lineups' : 'substitutes',
          'lineupPlayer': 'Futbolista $i',
          'playerKey': 'provider-$i',
          'lineupNumber': i + 1,
          if (canonical && i == 0) 'canonicalPlayerId': 'fb_player_known',
        },
    ],
  },
  'away': null,
};
HistoricalLineupSide? parseSide(Json raw, [String status = 'SCHEDULED']) =>
    LastConfirmedLineups.parse(
      raw,
      targetId,
    ).side('home', target(status), snapshot());

Future<void> openHistory(
  WidgetTester tester, {
  Json? raw,
  MatchDetail? detail,
  String status = 'SCHEDULED',
  Future<LastConfirmedLineups?>? future,
  bool? enabled,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: MatchLastLineupsSection(
              data: snapshot(),
              match: target(status),
              detail: detail ?? MatchDetail.empty(targetId),
              currentLineups: const Text('Actual oficial'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/match/:id',
        builder: (_, s) =>
            Scaffold(body: Text('Partido ${s.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, s) =>
            Scaffold(body: Text('Perfil ${s.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        lastConfirmedLineupsEnabledProvider.overrideWithValue(enabled ?? true),
        if (enabled == null)
          matchLastConfirmedLineupsProvider(targetId).overrideWith(
            (ref) =>
                future ??
                Future.value(
                  raw == null
                      ? null
                      : LastConfirmedLineups.parse(raw, targetId),
                ),
          ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  test('reader v1 rows use target side and preserve UTC/source identity', () {
    final side = parseSide(payload())!;
    expect(side.matchId, 'fb_match_previous');
    expect(side.starters.length, 11);
    expect(side.bench.length, 2);
    expect(side.kickoff, DateTime.utc(2026, 11, 28, 20));
    expect(side.formation, isNull);
    expect(side.starters.first.containsKey('id'), isFalse);
  });
  for (final count in [6, 7, 11, 12]) {
    test(
      'reader starter count $count',
      () => expect(
        parseSide(payload(starters: count)),
        count >= 7 && count <= 11 ? isNotNull : isNull,
      ),
    );
  }
  for (final field in ['schemaVersion', 'matchId', 'eligible', 'kind']) {
    test('rejects incompatible root $field', () {
      final raw = payload()..remove(field);
      expect(
        () => LastConfirmedLineups.parse(raw, targetId),
        throwsFormatException,
      );
    });
  }
  test('ineligible response needs no rows or kind', () {
    expect(
      parseSide({'schemaVersion': 1, 'matchId': targetId, 'eligible': false}),
      isNull,
    );
  });
  for (final status in [
    'LIVE',
    'HALFTIME',
    'FINISHED',
    'VERIFIED',
    'CANCELLED',
  ]) {
    test(
      'no historical replacement for $status',
      () => expect(parseSide(payload(), status), isNull),
    );
  }
  for (final date in [
    '2026-12-02T20:00:00Z',
    '2026-12-03T20:00:00Z',
    '2026-10-18T20:00:00Z',
    '2026-11-28T20:00:00',
    'bad',
  ]) {
    test('rejects unsafe source date $date', () {
      final raw = payload();
      raw['home']['sourceMatch']['startTime'] = date;
      expect(parseSide(raw), isNull);
    });
  }
  test('source must belong to the correct team and other match', () {
    for (final mutate in <void Function(Json)>[
      (raw) => raw['home']['teamId'] = 'fb_team_away',
      (raw) => raw['home']['sourceMatch']['matchId'] = targetId,
      (raw) => raw['home']['sourceMatch']['opponentTeamId'] = 'fb_team_home',
      (raw) => raw['home']['lineups'][0]['team'] = 'away',
      (raw) => raw['home']['lineups'][0]['lineupPlayer'] = '',
    ]) {
      final raw = payload();
      mutate(raw);
      expect(parseSide(raw), isNull);
    }
  });
  test('no name-based merging; repeated provider/canonical IDs rejected', () {
    final raw = payload();
    raw['home']['lineups'][1]['lineupPlayer'] = 'Futbolista 0';
    expect(parseSide(raw)!.starters.length, 11);
    raw['home']['lineups'][1]['playerKey'] = 'provider-0';
    expect(parseSide(raw), isNull);
    final canonical = payload(canonical: true);
    canonical['home']['lineups'][1]['canonicalPlayerId'] = 'fb_player_known';
    expect(parseSide(canonical), isNull);
  });
  test('formation appears only with explicit confirmation, never inferred', () {
    final raw = payload();
    raw['home']['formation'] = '4-3-3';
    expect(parseSide(raw)!.formation, isNull);
    raw['home']['formationConfirmed'] = true;
    expect(parseSide(raw)!.formation, '4-3-3');
  });
  testWidgets(
    'renders source, starters and substitutes without prediction/rating',
    (tester) async {
      await openHistory(tester, raw: payload());
      expect(find.text('Última alineación confirmada'), findsOneWidget);
      expect(find.textContaining('No es una predicción'), findsOneWidget);
      expect(find.text('Contra Rival anterior'), findsOneWidget);
      expect(find.text('Copa anterior'), findsOneWidget);
      expect(find.text('Titulares (11)'), findsOneWidget);
      expect(find.text('Suplentes (2)'), findsOneWidget);
      expect(find.text('Futbolista 0'), findsOneWidget);
      expect(find.textContaining('Formación confirmada:'), findsNothing);
      expect(
        find.byKey(const ValueKey('last-lineups-date-fb_team_home')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'current official players take priority without reading history',
    (tester) async {
      final pending = Completer<LastConfirmedLineups?>();
      await openHistory(
        tester,
        future: pending.future,
        detail: MatchDetail({
          'matchId': targetId,
          'available': true,
          'home': {
            'starters': [
              {'id': 'fb_player_current', 'name': 'Actual'},
            ],
          },
        }),
      );
      expect(find.text('Actual oficial'), findsOneWidget);
      expect(find.byKey(const ValueKey('last-lineups-title')), findsNothing);
      pending.complete(null);
    },
  );
  testWidgets('loading/empty/off switch remain clear and nonblocking', (
    tester,
  ) async {
    final pending = Completer<LastConfirmedLineups?>();
    await openHistory(tester, future: pending.future);
    expect(find.byKey(const ValueKey('last-lineups-loading')), findsOneWidget);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('last-lineups-empty')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await openHistory(tester, enabled: false);
    expect(find.text('Actual oficial'), findsOneWidget);
    expect(find.byKey(const ValueKey('last-lineups-title')), findsNothing);
  });
  testWidgets('previous match navigation never opens the target match', (
    tester,
  ) async {
    await openHistory(tester, raw: payload());
    final button = find.byKey(
      const ValueKey('last-lineups-source-fb_team_home'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Partido fb_match_previous'), findsOneWidget);
  });
  testWidgets('provider IDs cannot navigate; canonical IDs can open profile', (
    tester,
  ) async {
    await openHistory(tester, raw: payload(canonical: true));
    final canonical = find.byKey(
      const ValueKey('last-lineup-player-fb_team_home-provider-0'),
    );
    final external = find.byKey(
      const ValueKey('last-lineup-player-fb_team_home-provider-1'),
    );
    expect(tester.widget<ListTile>(external).onTap, isNull);
    await tester.ensureVisible(canonical);
    await tester.tap(canonical);
    await tester.pumpAndSettle();
    expect(find.text('Perfil fb_player_known'), findsOneWidget);
  });
  testWidgets('transport error is an honest empty state', (tester) async {
    final pending = Completer<LastConfirmedLineups?>();
    await openHistory(tester, future: pending.future);
    pending.completeError(StateError('fixture failure'));
    await tester.pumpAndSettle();
    expect(
      find.text('El historial no está disponible en este momento.'),
      findsOneWidget,
    );
  });

  test('rejects explicit prediction response', () {
    expect(
      () => LastConfirmedLineups.parse(
        payload()..['isPrediction'] = true,
        targetId,
      ),
      throwsFormatException,
    );
  });
  testWidgets('same-response metadata is used even without snapshot entities', (
    tester,
  ) async {
    final raw = payload();
    raw['home']['sourceMatch']['opponentTeamId'] = 'fb_team_new';
    raw['home']['sourceMatch']['competitionId'] = 'fb_comp_new';
    raw['teams'] = [
      {'id': 'fb_team_new', 'name': 'Rival de la fuente'},
    ];
    raw['competitions'] = [
      {'id': 'fb_comp_new', 'name': 'Copa de la fuente'},
    ];
    await openHistory(tester, raw: raw);
    expect(find.text('Contra Rival de la fuente'), findsOneWidget);
    expect(find.text('Copa de la fuente'), findsOneWidget);
  });
  testWidgets(
    'coverage available suppresses history even if player rows are missing',
    (tester) async {
      await openHistory(
        tester,
        raw: payload(),
        detail: MatchDetail({
          'matchId': targetId,
          'available': true,
          'coverage': {'lineup': 'available'},
        }),
      );
      expect(find.text('Actual oficial'), findsOneWidget);
      expect(find.byKey(const ValueKey('last-lineups-title')), findsNothing);
    },
  );
  testWidgets('narrow layout with large text remains readable', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openHistory(tester, raw: payload());
    expect(tester.takeException(), isNull);
  });
  testWidgets('current lineup arriving replaces history in the same section', (
    tester,
  ) async {
    final current = ValueNotifier(false);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lastConfirmedLineupsEnabledProvider.overrideWithValue(true),
          matchLastConfirmedLineupsProvider(targetId).overrideWith(
            (ref) async => LastConfirmedLineups.parse(payload(), targetId),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<bool>(
                valueListenable: current,
                builder: (_, official, _) => MatchLastLineupsSection(
                  data: snapshot(),
                  match: target(),
                  detail: official
                      ? MatchDetail({
                          'matchId': targetId,
                          'coverage': {'lineup': 'available'},
                        })
                      : MatchDetail.empty(targetId),
                  currentLineups: const Text('Nueva oficial'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Titulares (11)'), findsOneWidget);
    current.value = true;
    await tester.pump();
    expect(find.text('Nueva oficial'), findsOneWidget);
    expect(find.text('Titulares (11)'), findsNothing);
  });

  testWidgets('formation is rendered only when explicitly confirmed', (
    tester,
  ) async {
    final raw = payload();
    raw['home']['formation'] = '4-3-3';
    raw['home']['formationConfirmed'] = true;
    await openHistory(tester, raw: raw);
    expect(find.text('Formación confirmada: 4-3-3'), findsOneWidget);
  });
  testWidgets(
    'no historical data is fabricated for missing metadata or bench',
    (tester) async {
      final raw = payload();
      raw['home']['sourceMatch']['opponentTeamId'] = 'fb_team_missing';
      raw['home']['sourceMatch']['competitionId'] = 'fb_comp_missing';
      (raw['home']['lineups'] as List).removeWhere(
        (row) => row['type'] == 'substitutes',
      );
      await openHistory(tester, raw: raw);
      expect(find.text('Rival no disponible'), findsOneWidget);
      expect(find.text('Competición no disponible'), findsOneWidget);
      expect(find.text('Suplentes no disponibles'), findsOneWidget);
    },
  );
  testWidgets(
    'LIVE transition while history loads cannot display stale historical rows',
    (tester) async {
      final status = ValueNotifier('SCHEDULED');
      addTearDown(status.dispose);
      final pending = Completer<LastConfirmedLineups?>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            lastConfirmedLineupsEnabledProvider.overrideWithValue(true),
            matchLastConfirmedLineupsProvider(targetId)
                .overrideWith((ref) => pending.future),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, state, _) => MatchLastLineupsSection(
                    data: snapshot(),
                    match: target(state),
                    detail: MatchDetail.empty(targetId),
                    currentLineups: const Text('Estado actual'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('last-lineups-loading')),
        findsOneWidget,
      );
      status.value = 'LIVE';
      await tester.pump();
      pending.complete(LastConfirmedLineups.parse(payload(), targetId));
      await tester.pumpAndSettle();
      expect(find.text('Estado actual'), findsOneWidget);
      expect(find.text('Titulares (11)'), findsNothing);
    },
  );
  test('feature disabled performs no repository or HTTP reads', () async {
    final container = ProviderContainer(
      overrides: [lastConfirmedLineupsEnabledProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);
    expect(
      await container.read(matchLastConfirmedLineupsProvider(targetId).future),
      isNull,
    );
  });

  testWidgets(
    'server ineligible removes historical UI despite scheduled calendar',
    (tester) async {
      await openHistory(
        tester,
        raw: {'schemaVersion': 1, 'matchId': targetId, 'eligible': false},
      );
      expect(find.text('Actual oficial'), findsOneWidget);
      expect(find.byKey(const ValueKey('last-lineups-title')), findsNothing);
      expect(find.byKey(const ValueKey('last-lineups-empty')), findsNothing);
    },
  );
  testWidgets(
    'both null sides give an explicit empty state without invented players',
    (tester) async {
      final raw = payload()..['home'] = null;
      await openHistory(tester, raw: raw);
      expect(find.byKey(const ValueKey('last-lineups-empty')), findsOneWidget);
      expect(find.textContaining('Todavía no hay'), findsOneWidget);
      expect(find.text('Titulares (11)'), findsNothing);
    },
  );
  testWidgets(
    'stored production coach-only rows are not a historical starting XI',
    (tester) async {
      final stored = jsonDecode(
        File('test/fixtures/last_lineups_stored_coaches.json')
            .readAsStringSync(),
      ) as Json;
      final raw = payload();
      raw['home']['lineups'] = (stored['rows'] as List)
          .where((r) => r['team'] == 'home')
          .toList();
      expect(parseSide(raw), isNull);
      await openHistory(tester, raw: raw);
      expect(find.byKey(const ValueKey('last-lineups-empty')), findsOneWidget);
      expect(find.text('K. Hashikawa'), findsNothing);
    },
  );
  testWidgets(
    'v1 raw rows retain their order with nullable provider playerId',
    (tester) async {
      final raw = jsonDecode(jsonEncode(payload())) as Json;
      raw['isPrediction'] = false;
      raw['teams'] = [
        {
          'id': 'fb_team_rival',
          'name': 'Rival del contrato',
          'shortName': null,
          'media': {},
        },
      ];
      raw['competitions'] = [
        {'id': 'fb_comp_previous', 'name': 'Competición del contrato'},
      ];
      for (final row in raw['home']['lineups']) {
        row['playerId'] = null;
        row['lineupPosition'] = '';
      }
      final previous = parseSide(raw)!;
      expect(previous.starters.map((r) => r['name']).toList(), [
        for (var i = 0; i < 11; i++) 'Futbolista $i',
      ]);
      expect(previous.starters.every((r) => !r.containsKey('id')), isTrue);
      await openHistory(tester, raw: raw);
      expect(find.text('Contra Rival del contrato'), findsOneWidget);
      expect(find.text('Competición del contrato'), findsOneWidget);
    },
  );
  for (final status in [404, 503]) {
    test(
      'HTTP $status without local history remains an explicit read failure',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) => h.reject(
              DioException(
                requestOptions: r,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: r, statusCode: status),
              ),
            ),
          ),
        );
        await expectLater(
          ApiRepository(dio).loadMatchLastLineups(targetId),
          throwsA(isA<DioException>()),
        );
      },
    );
  }
  test(
    'network timeout without history does not create or invent a cache',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      addTearDown(() async {
        dio.close();
        await db.close();
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) => h.reject(
            DioException(
              requestOptions: r,
              type: DioExceptionType.receiveTimeout,
            ),
          ),
        ),
      );
      await expectLater(
        ApiRepository(dio, db).loadMatchLastLineups(targetId),
        throwsA(isA<DioException>()),
      );
      expect(
        await db.readPublicSnapshot('public:match-last-lineups:$targetId'),
        isNull,
      );
    },
  );

  test(
    'actual coach-only refresh never promotes missing lineup to available',
    () async {
      final raw = jsonDecode(
        File('test/fixtures/last_lineups_coach_only_detail.json')
            .readAsStringSync(),
      ) as Json;
      final id = raw['matchId'] as String;
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final repo = ApiRepository(dio, db);
      addTearDown(() async {
        await repo.settleBackground();
        dio.close();
        await db.close();
      });
      final previous = jsonDecode(jsonEncode(raw)) as Json;
      previous['home'] = {};
      previous['away'] = {};
      await db.savePublicSnapshot(
        'public:match-detail:$id',
        jsonEncode(previous),
      );
      repo.persistMatchDetail(id, MatchDetail(raw));
      await repo.settleBackground();
      final merged = MatchDetail(
        jsonDecode(
          (await db.readPublicSnapshot('public:match-detail:$id'))!.payload,
        ) as Json,
      );
      expect(merged.sectionState('lineup'), 'missing');
      expect(hasCurrentLineup(merged), isFalse);
      expect(merged.home['coach']['name'], 'Jafet Soto');
      expect(merged.away['coach']['name'], 'Andres Arias');
    },
  );
  test(
    'coach refresh keeps an already confirmed current XI and its priority',
    () async {
      final raw = jsonDecode(
        File('test/fixtures/last_lineups_coach_only_detail.json')
            .readAsStringSync(),
      ) as Json;
      final id = raw['matchId'] as String;
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final repo = ApiRepository(dio, db);
      addTearDown(() async {
        await repo.settleBackground();
        dio.close();
        await db.close();
      });
      final previous = jsonDecode(jsonEncode(raw)) as Json;
      previous['home']['starters'] = [
        {'id': 'fb_player_confirmed', 'name': 'Confirmado'},
      ];
      previous['coverage']['lineup'] = 'available';
      await db.savePublicSnapshot(
        'public:match-detail:$id',
        jsonEncode(previous),
      );
      repo.persistMatchDetail(id, MatchDetail(raw));
      await repo.settleBackground();
      final merged = MatchDetail(
        jsonDecode(
          (await db.readPublicSnapshot('public:match-detail:$id'))!.payload,
        ) as Json,
      );
      expect(merged.homeStarters.single['name'], 'Confirmado');
      expect(merged.sectionState('lineup'), 'available');
      expect(hasCurrentLineup(merged), isTrue);
    },
  );
  test(
    'FutBeat GET only, coalesced, explicit public cache and offline fallback',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final repo = ApiRepository(dio, db);
      addTearDown(() async {
        await repo.settleBackground();
        dio.close();
        await db.close();
      });
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests++;
            expect(request.method, 'GET');
            expect(request.path, '/v1/match-last-lineups');
            expect(request.queryParameters, {'id': targetId});
            handler.resolve(
              Response(
                requestOptions: request,
                data: payload(),
                headers: Headers.fromMap({
                  'cache-control': ['public, max-age=300'],
                }),
              ),
            );
          },
        ),
      );
      final first = repo.loadMatchLastLineups(targetId);
      expect(repo.loadMatchLastLineups(targetId), same(first));
      await first;
      await repo.settleBackground();
      expect(
        (await ApiRepository(dio, db).loadMatchLastLineups(targetId)).offline,
        isFalse,
      );
      expect(requests, 1);
      final key = 'public:match-last-lineups:$targetId';
      await (db.delete(
        db.catalogSnapshots,
      )..where((t) => t.cacheKey.equals(key))).go();
      final savedAt = DateTime.now().toUtc().subtract(
        const Duration(minutes: 6),
      );
      await db
          .into(db.catalogSnapshots)
          .insert(
            CatalogSnapshotsCompanion.insert(
              cacheKey: key,
              payload: jsonEncode(payload()),
              savedAt: savedAt,
            ),
          );
      dio.interceptors.clear();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          ),
        ),
      );
      expect(
        (await ApiRepository(dio, db).loadMatchLastLineups(targetId)).offline,
        isTrue,
      );
      expect(
        (await db.readPublicSnapshot(key))!.savedAt.millisecondsSinceEpoch ~/
            1000,
        savedAt.millisecondsSinceEpoch ~/ 1000,
      );
      dio.interceptors.clear();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: request, statusCode: 403),
            ),
          ),
        ),
      );
      await expectLater(
        ApiRepository(dio, db).loadMatchLastLineups(targetId),
        throwsA(isA<DioException>()),
      );
    },
  );
  for (final policy in [
    'no-store',
    'private, max-age=300',
    'public, max-age=300, no-store',
  ]) {
    test('does not persist $policy', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final repo = ApiRepository(dio, db);
      addTearDown(() async {
        await repo.settleBackground();
        dio.close();
        await db.close();
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) => h.resolve(
            Response(
              requestOptions: r,
              data: payload(),
              headers: Headers.fromMap({
                'cache-control': [policy],
              }),
            ),
          ),
        ),
      );
      await repo.loadMatchLastLineups(targetId);
      await repo.settleBackground();
      expect(
        await db.readPublicSnapshot('public:match-last-lineups:$targetId'),
        isNull,
      );
    });
  }
}

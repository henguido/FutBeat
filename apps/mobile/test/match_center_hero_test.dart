import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

// #99 Hero v2: competition line + teams + score/state centre + scorers.
// Date and venue chips are gone from the hero (MatchInfoCard owns them);
// the state shown is exactly the FootballMatch state (never the clock).

const _match = 'fb_match_hv';
const _home = 'fb_team_hv_home';
const _away = 'fb_team_hv_away';
const _comp = 'fb_comp_hv';

Map<String, dynamic> _snapshot({
  String status = 'VERIFIED',
  Map<String, int>? score = const {'home': 2, 'away': 1},
  int? minute,
  String competition = 'Liga Héroe',
  String homeName = 'Local Héroe',
  String awayName = 'Visita Héroe',
  Duration kickoffOffset = const Duration(hours: -3),
  bool hasPlayedEvidence = false,
}) {
  final now = DateTime.now().toUtc();
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': _comp, 'name': competition, 'country': 'Costa Rica'},
    ],
    'teams': [
      {'id': _home, 'name': homeName},
      {'id': _away, 'name': awayName},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': _comp,
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': now.add(kickoffOffset).toIso8601String(),
        'status': status,
        'season': '2026',
        'venue': 'Estadio Héroe',
        'score': ?score,
        'minute': ?minute,
        if (status == 'LIVE' || status == 'HALFTIME' || status == 'EXTRA_TIME')
          'liveChangedAt': now.toIso8601String(),
        if (hasPlayedEvidence) 'hasPlayedEvidence': true,
        'events': const <dynamic>[],
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _goal(String side, int minute, {String? name}) => {
  'type': 'GOAL',
  'minute': minute,
  'label': 'Gol',
  'side': side,
  'playerName': ?name,
};

Map<String, dynamic> _detail({
  List<Map<String, dynamic>> incidents = const [],
}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'round': '7',
  'stadium': 'Estadio Héroe',
  'referee': 'Árbitro Héroe',
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const <dynamic>[],
  'incidents': incidents,
  'videos': const <dynamic>[],
};

class _Server {
  _Server(this.snapshot, this.detail);
  Map<String, dynamic> Function(int read) snapshot;
  final Map<String, dynamic> detail;
  int contextReads = 0;
  int detailReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: snapshot(contextReads++)),
            );
            return;
          }
          if (options.path == '/v1/match-preview') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 503),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          if (options.path == '/v1/match-detail') detailReads++;
          handler.resolve(Response(requestOptions: options, data: detail));
        },
      ),
    );
}

ProviderContainer? _container;

Future<_Server> _open(
  WidgetTester tester, {
  Map<String, dynamic>? snapshot,
  Map<String, dynamic> Function(int read)? snapshots,
  Map<String, dynamic>? detail,
  double width = 360,
}) async {
  final server = _Server(
    snapshots ?? (_) => snapshot ?? _snapshot(),
    detail ?? _detail(),
  );
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  addTearDown(() => tester.runAsync(db.close));
  _container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  final router = GoRouter(
    initialLocation: '/match',
    routes: [
      GoRoute(
        path: '/match',
        builder: (_, _) => const MatchScreen(id: _match),
      ),
      GoRoute(
        path: '/competition/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Competición ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Equipo ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container!,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _settle(tester);
  return server;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  _container?.dispose();
  _container = null;
}

final _hero = find.byKey(const ValueKey('match-hero'));
Finder _inHero(Finder finder) => find.descendant(of: _hero, matching: finder);

Color? _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(_inHero(find.text(text))).style?.color;

void main() {
  testWidgets('1. PRE: kickoff time + date + PROGRAMADO, no score, no '
      'date/venue chips', (tester) async {
    await _open(
      tester,
      snapshot: _snapshot(
        status: 'SCHEDULED',
        score: null,
        kickoffOffset: const Duration(days: 1),
      ),
    );
    expect(_inHero(find.text('PROGRAMADO')), findsOneWidget);
    expect(_inHero(find.textContaining(' - ')), findsNothing);
    expect(_inHero(find.text('Estadio Héroe')), findsNothing);
    expect(_inHero(find.byIcon(Icons.calendar_today_rounded)), findsNothing);
    expect(_inHero(find.byIcon(Icons.location_on_outlined)), findsNothing);
    // Time (big) and date (discreet) in the centre.
    final texts = tester
        .widgetList<Text>(_inHero(find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts.any((t) => RegExp(r'\d{1,2}:\d{2}').hasMatch(t)), isTrue);
    expect(
      texts.any(
        (t) => RegExp(r'^[A-ZÁÉÍÓÚ][a-záéíóú]{2} \d{1,2} ').hasMatch(t),
      ),
      isTrue,
    );
    await _close(tester);
  });

  testWidgets('2. LIVE: score in the live tone, minute, EN VIVO dot', (
    tester,
  ) async {
    await _open(tester, snapshot: _snapshot(status: 'LIVE', minute: 63));
    expect(_inHero(find.text('2 - 1')), findsOneWidget);
    expect(_inHero(find.text('63′ · EN VIVO')), findsOneWidget);
    expect(_textColor(tester, '2 - 1'), lime);
    expect(_inHero(find.byIcon(Icons.circle)), findsOneWidget);
    await _close(tester);
  });

  testWidgets('3. HALFTIME: score, DESCANSO, not the live tone', (
    tester,
  ) async {
    await _open(tester, snapshot: _snapshot(status: 'HALFTIME'));
    expect(_inHero(find.text('2 - 1')), findsOneWidget);
    expect(_inHero(find.text('DESCANSO')), findsOneWidget);
    expect(_textColor(tester, '2 - 1'), Colors.white);
    expect(_textColor(tester, 'DESCANSO'), Colors.amber);
    await _close(tester);
  });

  testWidgets('4. FINAL: score, FINALIZADO, no live indicator', (tester) async {
    await _open(tester);
    expect(_inHero(find.text('2 - 1')), findsOneWidget);
    expect(_inHero(find.text('FINALIZADO')), findsOneWidget);
    expect(_inHero(find.textContaining('EN VIVO')), findsNothing);
    expect(_inHero(find.byIcon(Icons.circle)), findsNothing);
    expect(_textColor(tester, '2 - 1'), Colors.white);
    await _close(tester);
  });

  for (final (status, label) in [
    ('POSTPONED', 'APLAZADO'),
    ('SUSPENDED', 'SUSPENDIDO'),
    ('CANCELLED', 'CANCELADO'),
    ('ABANDONED', 'ABANDONADO'),
  ]) {
    testWidgets('5-7. $status is shown as $label, never live', (tester) async {
      await _open(tester, snapshot: _snapshot(status: status));
      expect(_inHero(find.text(label)), findsOneWidget);
      expect(_inHero(find.textContaining('EN VIVO')), findsNothing);
      expect(_inHero(find.byIcon(Icons.circle)), findsNothing);
      expect(_textColor(tester, label), Colors.redAccent);
      await _close(tester);
    });
  }

  testWidgets('8. awaiting update with a score: MARCADOR PARCIAL, neither '
      'live nor final', (tester) async {
    await _open(
      tester,
      snapshot: _snapshot(
        status: 'SCHEDULED',
        kickoffOffset: const Duration(hours: -2),
      ),
    );
    expect(_inHero(find.text('2 - 1')), findsOneWidget);
    expect(_inHero(find.text('MARCADOR PARCIAL')), findsOneWidget);
    expect(_inHero(find.text('FINALIZADO')), findsNothing);
    expect(_inHero(find.textContaining('EN VIVO')), findsNothing);
    expect(_inHero(find.byIcon(Icons.circle)), findsNothing);
    await _close(tester);
  });

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('9-12/21-24. ${width.toInt()} px: long names, 2-digit score, '
        '120′ LIVE, many long scorers — no overflow', (tester) async {
      await _open(
        tester,
        width: width,
        snapshot: _snapshot(
          status: 'LIVE',
          minute: 120,
          score: const {'home': 10, 'away': 11},
          competition: 'Campeonato Internacional de Clubes Campeones de la Confederación',
          homeName: 'Club Deportivo Social y Cultural Atlético Municipal Local',
          awayName: 'Asociación Deportiva Recreativa Unión Visitante Central',
        ),
        detail: _detail(
          incidents: [
            for (var i = 0; i < 7; i++)
              _goal('home', 10 + i, name: 'Maximiliano de la Trinidad $i'),
            for (var i = 0; i < 7; i++)
              _goal('away', 50 + i, name: 'Constantinos Papadopoulos $i'),
          ],
        ),
      );
      expect(_inHero(find.text('10 - 11')), findsOneWidget);
      expect(_inHero(find.text('120′ · EN VIVO')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  testWidgets('13-17. scorers: home, away, grouped minutes, anonymous goals, '
      'limit + "+n"', (tester) async {
    await _open(
      tester,
      snapshot: _snapshot(score: const {'home': 7, 'away': 2}),
      detail: _detail(
        incidents: [
          _goal('home', 10, name: 'A. Doblete'),
          _goal('home', 30, name: 'A. Doblete'),
          _goal('home', 40, name: 'B. Uno'),
          _goal('home', 50, name: 'C. Dos'),
          _goal('home', 60, name: 'D. Tres'),
          _goal('home', 70, name: 'E. Cuatro'),
          _goal('home', 80, name: 'F. Cinco'),
          _goal('away', 20),
          _goal('away', 25),
        ],
      ),
    );
    Text line(String key) => tester.widget<Text>(find.byKey(ValueKey(key)));
    expect(line('scorer-home-0').data, 'A. Doblete 10′, 30′');
    expect(line('scorer-away-0').data, 'Gol 20′');
    expect(line('scorer-away-1').data, 'Gol 25′');
    // 6 home lines, max 5 shown + "+1".
    expect(find.byKey(const ValueKey('scorer-home-5')), findsNothing);
    expect(_inHero(find.text('+1')), findsOneWidget);
    await _close(tester);
  });

  for (final (label, target, route) in [
    ('competition', 'Liga Héroe · Jornada 7', 'Competición $_comp'),
    ('home', 'Local Héroe', 'Equipo $_home'),
    ('away', 'Visita Héroe', 'Equipo $_away'),
  ]) {
    testWidgets('18-20. tap $label navigates to the right route', (
      tester,
    ) async {
      await _open(tester);
      await tester.tap(_inHero(find.text(target)));
      await tester.pumpAndSettle();
      expect(find.text(route), findsOneWidget);
      await _close(tester);
    });
  }

  testWidgets('25/26/29. PRE -> LIVE -> FINAL by refresh: same TabController '
      'and selected tab, label follows', (tester) async {
    final server = await _open(
      tester,
      snapshots: (read) => switch (read) {
        0 => _snapshot(
          status: 'SCHEDULED',
          score: null,
          kickoffOffset: const Duration(minutes: 5),
        ),
        1 => _snapshot(
          status: 'LIVE',
          minute: 3,
          score: const {'home': 0, 'away': 0},
        ),
        _ => _snapshot(),
      },
    );
    final bar = find.byType(TabBar);
    final controller = tester.widget<TabBar>(bar).controller!;
    expect(_inHero(find.text('PROGRAMADO')), findsOneWidget);
    // Select Tabla without scrolling the hero away (ensureVisible would also
    // scroll the outer NestedScrollView).
    final tabla = tester
        .widget<TabBar>(bar)
        .tabs
        .indexWhere((tab) => tab is Tab && tab.text == 'Tabla');
    controller.animateTo(tabla);
    await _settle(tester);
    final index = controller.index;
    expect(index, tabla);
    for (final expected in ['3′ · EN VIVO', 'FINALIZADO']) {
      _container!.invalidate(matchContextSnapshotProvider(_match));
      await _settle(tester);
      expect(_inHero(find.text(expected)), findsOneWidget, reason: expected);
      expect(tester.widget<TabBar>(bar).controller, same(controller));
      expect(controller.index, index);
    }
    expect(server.contextReads, 3);
    await _close(tester);
  });

  testWidgets('27/28. rendering the hero reads no extra match detail', (
    tester,
  ) async {
    final server = await _open(tester);
    final reads = server.detailReads;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(_hero, findsOneWidget);
    expect(server.detailReads, reads);
    await _close(tester);
  });
}

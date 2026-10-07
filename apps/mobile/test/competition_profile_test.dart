import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:go_router/go_router.dart';

Map<String, dynamic> _payload({bool table = true, bool ambiguous = false}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-07T12:00:00Z',
  'competitions': [
    {
      'id': 'fb_comp',
      'name': 'Liga FutBeat',
      'country': 'Costa Rica',
      'season': '2026/27',
    },
    if (ambiguous) {'id': 'fb_other', 'name': 'Otra Liga', 'country': 'Panamá'},
  ],
  'teams': [
    {
      'id': 'home',
      'name': 'Club Local',
      'country': 'Costa Rica',
      'competitionId': 'fb_comp',
    },
    {
      'id': 'away',
      'name': 'Club Visitante',
      'country': 'Costa Rica',
      'competitionId': 'fb_comp',
    },
  ],
  'players': <dynamic>[],
  'standings': [
    if (table)
      {
        if (!ambiguous) 'competitionId': 'fb_comp',
        'name': 'Grupo A',
        'rows': [
          {
            'teamId': 'home',
            'played': 3,
            'won': 2,
            'drawn': 1,
            'lost': 0,
            'gf': 5,
            'ga': 1,
            'points': 7,
          },
          {
            'teamId': 'away',
            'played': 3,
            'won': 1,
            'drawn': 0,
            'lost': 2,
            'gf': 2,
            'ga': 4,
            'points': 3,
          },
        ],
      },
  ],
  'matches': [
    {
      'id': 'past',
      'competitionId': 'fb_comp',
      'homeTeamId': 'home',
      'awayTeamId': 'away',
      'startTime': '2026-09-20T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 1},
      'stage': 'Semifinal',
      'round': 'Vuelta',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
    {
      'id': 'next',
      'competitionId': 'fb_comp',
      'homeTeamId': 'away',
      'awayTeamId': 'home',
      'startTime': '2099-10-20T18:00:00Z',
      'status': 'SCHEDULED',
      'group': 'Grupo A',
      'round': 'Jornada 4',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'news': <dynamic>[],
  'transfers': <dynamic>[],
};

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() async => db.customSelect('select 1').get());
  final router = GoRouter(
    initialLocation: '/competition/fb_comp',
    routes: [
      GoRoute(
        path: '/competition/:id',
        builder: (_, state) =>
            EntityScreen(type: 'competition', id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Equipo ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/match/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Partido ${state.pathParameters['id']}')),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      entitySnapshotProvider.overrideWith(
        (ref, request) async => Snapshot(payload),
      ),
      followsProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _tabs(WidgetTester tester) => [
  for (final tab in tester.widget<TabBar>(find.byType(TabBar)).tabs)
    (tab as Tab).text!,
];

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows real identity, season and available competition sections',
    (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Liga FutBeat'), findsWidgets);
      expect(find.text('Costa Rica'), findsWidgets);
      expect(find.text('2026/27'), findsOneWidget);
      expect(_tabs(tester), [
        'Resumen',
        'Partidos',
        'Tabla',
        'Equipos',
        'Noticias',
      ]);
      expect(find.text('Próximos partidos'), findsOneWidget);
      expect(find.text('Últimos resultados'), findsOneWidget);
      expect(find.textContaining('Grupo A'), findsWidgets);
      expect(find.text('Goleadores'), findsNothing);
    },
  );

  testWidgets('preserves phase context and opens matches', (tester) async {
    await _pump(tester, _payload());
    expect(find.textContaining('Jornada 4'), findsOneWidget);
    expect(find.textContaining('Semifinal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('competition-match-next')));
    await tester.pumpAndSettle();
    expect(find.text('Partido next'), findsOneWidget);
  });

  testWidgets('opens participating team profiles', (tester) async {
    await _pump(tester, _payload());
    await _openTab(tester, 'Equipos');
    await tester.tap(find.byKey(const ValueKey('competition-team-home')));
    await tester.pumpAndSettle();
    expect(find.text('Equipo home'), findsOneWidget);
  });

  testWidgets('fails closed when standings identity is ambiguous', (
    tester,
  ) async {
    await _pump(tester, _payload(ambiguous: true));
    expect(_tabs(tester), ['Resumen', 'Partidos', 'Equipos', 'Noticias']);
    expect(find.text('Clasificación'), findsNothing);
  });

  testWidgets('partial data stays usable at a narrow width', (tester) async {
    final payload = _payload(table: false)
      ..['matches'] = <dynamic>[]
      ..['teams'] = <dynamic>[];
    await _pump(tester, payload, size: const Size(320, 700));

    expect(tester.takeException(), isNull);
    expect(_tabs(tester), ['Resumen', 'Partidos', 'Equipos', 'Noticias']);
    expect(find.text('Información todavía no disponible'), findsOneWidget);
    await _openTab(tester, 'Partidos');
    expect(find.text('Sin partidos disponibles'), findsOneWidget);
  });
}

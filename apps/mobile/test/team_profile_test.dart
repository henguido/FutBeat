import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/features/entities/team_profile.dart';
import 'package:go_router/go_router.dart';

const _longTeam = 'Club Deportivo Asociación Muy Larga de Nombre Extenso FC';

Map<String, dynamic> _player(
  String id,
  String name,
  String? position, {
  int? number,
  String country = 'Costa Rica',
  bool photo = false,
}) => {
  'id': id,
  'name': name,
  'teamId': 'fb_team',
  'country': country,
  'position': ?position,
  'shirtNumber': ?number,
  if (photo)
    'media': {
      'url': 'https://media.example.test/$id.png',
      'verificationStatus': 'VERIFIED',
    },
};

final _squad = [
  _player('fb_p_fw', 'Delantero Nueve', 'Forwards', number: 9),
  _player('fb_p_gk2', 'Portero Suplente', 'Goalkeeper', number: 23),
  _player('fb_p_gk1', 'Portero Titular', 'Goalkeepers', number: 1, photo: true),
  _player('fb_p_df', 'Defensa Central', 'Defender', number: 4),
  _player('fb_p_mf', 'Volante Mixto', 'Midfielders', number: 8),
  _player('fb_p_x', 'Jugador Sin Posición', null),
];

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? players,
  bool table = false,
  bool longName = false,
  bool emptyTable = false,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-20T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba', 'country': 'Costa Rica'},
  ],
  'teams': [
    {
      'id': 'fb_team',
      'name': longName ? _longTeam : 'Club Local',
      'country': 'Costa Rica',
      'competitionId': 'fb_comp',
    },
    {'id': 'fb_rival', 'name': 'Rival FC', 'country': 'Costa Rica'},
  ],
  'players': players ?? _squad,
  'standings': [
    if (table || emptyTable)
      {
        'competitionId': 'fb_comp',
        'rows': [
          if (table)
            {
              'teamId': 'fb_team',
              'played': 3,
              'won': 2,
              'drawn': 1,
              'lost': 0,
              'gf': 6,
              'ga': 2,
              'points': 7,
            },
        ],
      },
  ],
  'matches': [
    {
      'id': 'fb_match_past',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_team',
      'awayTeamId': 'fb_rival',
      'startTime': '2026-09-01T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 0},
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'news': <dynamic>[],
  'transfers': <dynamic>[],
};

Future<void> _pumpTeam(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Size size = const Size(360, 780),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() async {
    await db.customSelect('select 1').get();
  });
  final router = GoRouter(
    initialLocation: '/team/fb_team',
    routes: [
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            EntityScreen(type: 'team', id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Perfil ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/competition/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Competición ${state.pathParameters['id']}')),
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

List<String> _tabLabels(WidgetTester tester) => [
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
  test('positions group in football order, sorted by shirt number', () {
    final groups = squadGroups(_squad.map(Entity.new));
    expect(groups.map((group) => group.$1).toList(), [
      'Porteros',
      'Defensas',
      'Mediocampistas',
      'Delanteros',
      'Otros',
    ]);
    expect(groups.first.$2.map((p) => p.name).toList(), [
      'Portero Titular',
      'Portero Suplente',
    ]);
    for (final (raw, group) in [
      ('GK', 'Porteros'),
      ('Centre-Back', 'Defensas'),
      ('Mediocampista', 'Mediocampistas'),
      ('Attacker', 'Delanteros'),
      ('Coach', 'Otros'),
      ('', 'Otros'),
    ]) {
      expect(squadGroupOf(raw), group, reason: raw);
    }
  });

  testWidgets('team with squad shows header and grouped Plantilla', (
    tester,
  ) async {
    await _pumpTeam(tester, _payload());
    expect(find.text('Club Local'), findsWidgets);
    expect(find.text('Liga de Prueba'), findsWidgets);
    expect(find.text('6 jugadores'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Seguir'),
      ),
      findsOneWidget,
    );
    expect(find.text('Partidos destacados'), findsOneWidget);
    expect(find.text('Último resultado'), findsOneWidget);

    await _openTab(tester, 'Plantilla');
    for (final label in squadGroupOrder) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    final porteros = tester.getTopLeft(find.text('Porteros')).dy;
    final delanteros = tester.getTopLeft(find.text('Delanteros')).dy;
    expect(porteros, lessThan(delanteros));
    expect(
      tester.getTopLeft(find.text('Portero Titular')).dy,
      lessThan(tester.getTopLeft(find.text('Portero Suplente')).dy),
    );
    expect(find.text('Portero · Costa Rica'), findsNWidgets(2));
    expect(find.text('23'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('players with and without photo never show broken images', (
    tester,
  ) async {
    await _pumpTeam(tester, _payload());
    await _openTab(tester, 'Plantilla');
    // Only the verified canonical photo is requested; others use initials.
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('DN'), findsOneWidget);
    expect(find.text('PT'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('team without squad keeps every tab and no spinner', (
    tester,
  ) async {
    await _pumpTeam(tester, _payload(players: const []));
    expect(_tabLabels(tester), [
      'Resumen',
      'Partidos',
      'Plantilla',
      'Noticias',
      'Transferencias',
    ]);
    await _openTab(tester, 'Plantilla');
    expect(find.text('Plantilla no disponible'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _openTab(tester, 'Transferencias');
    expect(find.text('Sin cambios de plantilla disponibles'), findsOneWidget);
  });

  testWidgets('Tabla appears only with real standings rows', (tester) async {
    await _pumpTeam(tester, _payload(emptyTable: true));
    expect(find.text('Tabla'), findsNothing);
    expect(find.text('Tabla no disponible'), findsNothing);
  });

  testWidgets('Tabla tab renders real standings', (tester) async {
    await _pumpTeam(tester, _payload(table: true));
    expect(_tabLabels(tester), [
      'Resumen',
      'Partidos',
      'Tabla',
      'Plantilla',
      'Noticias',
      'Transferencias',
    ]);
    await _openTab(tester, 'Tabla');
    expect(find.text('Clasificación'), findsOneWidget);
  });

  testWidgets('tapping a player opens the existing player profile', (
    tester,
  ) async {
    await _pumpTeam(tester, _payload());
    await _openTab(tester, 'Plantilla');
    await tester.tap(find.text('Defensa Central'));
    await tester.pumpAndSettle();
    expect(find.text('Perfil fb_p_df'), findsOneWidget);
  });

  testWidgets('main competition chip opens the competition', (tester) async {
    await _pumpTeam(tester, _payload());
    await tester.tap(find.text('Liga de Prueba').first);
    await tester.pumpAndSettle();
    expect(find.text('Competición fb_comp'), findsOneWidget);
  });

  testWidgets('long names, no crest and a large squad fit 320px', (
    tester,
  ) async {
    final big = [
      for (var i = 1; i <= 40; i++)
        _player(
          'fb_big_$i',
          'Jugador Con Un Nombre Larguísimo Número $i',
          ['Goalkeeper', 'Defender', 'Midfielder', 'Forward'][i % 4],
          number: i,
          country: 'República Democrática de Ejemplo',
        ),
    ];
    await _pumpTeam(
      tester,
      _payload(players: big, longName: true, table: true),
      size: const Size(320, 640),
    );
    expect(find.text(_longTeam), findsWidgets);
    expect(tester.takeException(), isNull);
    await _openTab(tester, 'Plantilla');
    expect(find.text('40 jugadores'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _openTab(tester, 'Partidos');
    expect(find.text('Resultados'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

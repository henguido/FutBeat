import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:go_router/go_router.dart';

const _longName =
    'Jugador Con Un Nombre Larguísimo De Prueba Extensa Número Diez';

Map<String, dynamic> _payload({
  Map<String, dynamic> player = const {},
  bool team = true,
  List<Map<String, dynamic>> news = const [],
  List<Map<String, dynamic>> transfers = const [],
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-20T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba', 'country': 'Costa Rica'},
  ],
  'teams': [
    {'id': 'fb_team', 'name': 'Club Local', 'country': 'Costa Rica'},
    {'id': 'fb_rival', 'name': 'Rival FC', 'country': 'Costa Rica'},
  ],
  'players': [
    {
      'id': 'fb_player',
      'name': 'Delantero Estrella',
      if (team) 'teamId': 'fb_team',
      ...player,
    },
  ],
  'standings': <dynamic>[],
  'matches': [
    {
      'id': 'fb_match_past',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_team',
      'awayTeamId': 'fb_rival',
      'startTime': '2026-09-01T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 0},
      'events': [
        {
          'id': 'fb_event_goal',
          'type': 'GOAL',
          'minute': 23,
          'teamId': 'fb_team',
          'playerId': 'fb_player',
        },
        {
          'id': 'fb_event_assist',
          'type': 'GOAL',
          'minute': 70,
          'teamId': 'fb_team',
          'playerId': 'fb_other',
          'assistPlayerId': 'fb_player',
        },
      ],
      'statistics': <dynamic>[],
    },
    {
      'id': 'fb_match_next',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_rival',
      'awayTeamId': 'fb_team',
      'startTime': '2099-01-10T18:00:00Z',
      'status': 'SCHEDULED',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'news': news,
  'transfers': transfers,
};

Future<void> _pumpPlayer(
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
    initialLocation: '/player/fb_player',
    routes: [
      GoRoute(
        path: '/player/:id',
        builder: (_, state) =>
            EntityScreen(type: 'player', id: state.pathParameters['id']!),
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

List<String> _tabLabels(WidgetTester tester) => [
  for (final tab in tester.widget<TabBar>(find.byType(TabBar)).tabs)
    (tab as Tab).text!,
];

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _scrollSummaryTo(WidgetTester tester, String text) =>
    tester.dragUntilVisible(
      find.text(text),
      find.byType(CustomScrollView).first,
      const Offset(0, -200),
    );

/// A player with every optional field the profile supports.
const _rich = {
  'position': 'Centre-Forward',
  'secondaryPositions': ['Right Winger', 'Attacking Midfield', 'Striker'],
  'shirtNumber': 10,
  'country': 'Costa Rica',
  'age': 24,
  'dateOfBirth': '2002-05-14',
  'height': 182,
  'preferredFoot': 'left',
  'marketValue': {'amount': 12500000, 'currency': 'EUR'},
  'matchesPlayed': 12,
  'goals': 7,
  'assists': 3,
  'yellowCards': 2,
  'rating': 7.4,
  'media': {
    'url': 'https://media.example.test/fb_player.png',
    'verificationStatus': 'VERIFIED',
  },
};

void main() {
  testWidgets('rich profile: sheet, position pitch and real season numbers', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(player: _rich));
    expect(find.text('#10'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Seguir'),
      ),
      findsOneWidget,
    );
    // Player sheet: every real field, formatted, in Spanish.
    for (final (value, label) in [
      ('182 cm', 'Altura'),
      ('24 años', 'Edad'),
      ('14/05/2002', 'Nacimiento'),
      ('Costa Rica', 'Nacionalidad'),
      ('10', 'Dorsal'),
      ('Izquierdo', 'Pie preferido'),
      ('EUR 12.5 M', 'Valor de mercado'),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
      expect(find.text(value), findsWidgets, reason: value);
    }
    await _scrollSummaryTo(tester, 'Posición principal');
    expect(find.text('Delantero centro'), findsWidgets);
    expect(find.text('Otras posiciones'), findsOneWidget);
    expect(find.text('Extremo derecho'), findsOneWidget);
    expect(find.text('Mediapunta'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-position-pitch')), findsOneWidget);
    await _scrollSummaryTo(tester, 'Temporada actual');
    expect(find.text('Goles'), findsOneWidget);
    expect(find.text('Rating'), findsOneWidget);
    expect(find.text('7.4'), findsOneWidget);
    // Matches belong to the Partidos tab only.
    expect(find.text('Próximos partidos'), findsNothing);
    expect(find.text('Últimos partidos'), findsNothing);
    expect(find.text('Partidos destacados'), findsNothing);
    expect(_tabLabels(tester), [
      'Resumen',
      'Partidos',
      'Estadísticas',
      'Noticias',
      'Transferencias',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Partidos tab keeps upcoming and past matches', (tester) async {
    await _pumpPlayer(tester, _payload(player: _rich));
    await _openTab(tester, 'Partidos');
    expect(find.text('Próximos'), findsOneWidget);
    expect(find.text('Resultados'), findsOneWidget);
  });

  testWidgets('Estadísticas tab lists real numbers aligned to the edge', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(player: _rich));
    await _openTab(tester, 'Estadísticas');
    expect(find.text('Goles'), findsOneWidget);
    expect(
      tester.getTopRight(find.text('7')).dx,
      moreOrLessEquals(tester.getTopRight(find.text('12')).dx),
    );
  });

  testWidgets('nested season stats show competition, starts and minutes', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      _payload(
        player: {
          'position': 'Goalkeeper',
          'seasonStats': {
            'competition': 'Liga Promerica',
            'season': '2026/27',
            'matchesPlayed': 11,
            'starts': 10,
            'minutesPlayed': 900,
          },
        },
      ),
    );
    await _scrollSummaryTo(tester, 'Temporada actual');
    expect(find.text('Liga Promerica · 2026/27'), findsOneWidget);
    expect(find.text('Titularidades'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('Goles'), findsNothing);
  });

  testWidgets('missing fields are hidden, not filled with placeholders', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      _payload(player: {'goals': 3, 'country': 'Chile'}),
    );
    for (final label in [
      'Altura',
      'Edad',
      'Nacimiento',
      'Dorsal',
      'Pie preferido',
      'Valor de mercado',
      'Posición principal',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.text('Nacionalidad'), findsOneWidget);
    expect(find.text('Datos no disponibles'), findsNothing);
    // One real number: season card yes, Estadísticas tab no.
    await _scrollSummaryTo(tester, 'Temporada actual');
    expect(_tabLabels(tester), [
      'Resumen',
      'Partidos',
      'Noticias',
      'Transferencias',
    ]);
  });

  testWidgets('a single known position shows it on the pitch, alone', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(player: {'position': 'Defender'}));
    await _scrollSummaryTo(tester, 'Posición principal');
    expect(find.text('Defensa'), findsWidgets);
    expect(find.text('Otras posiciones'), findsNothing);
    expect(find.byKey(const ValueKey('player-position-pitch')), findsOneWidget);
  });

  testWidgets('an unknown position keeps its label without a pitch', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(player: {'position': 'Libero'}));
    await _scrollSummaryTo(tester, 'Posición principal');
    expect(find.text('Libero'), findsWidgets);
    expect(find.byKey(const ValueKey('player-position-pitch')), findsNothing);
  });

  testWidgets('player without photo, team, number or data stays compact', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(team: false));
    expect(find.byType(Image), findsNothing);
    expect(find.text('DE'), findsOneWidget);
    expect(find.text('Sin equipo'), findsOneWidget);
    expect(find.text('Datos no disponibles'), findsOneWidget);
    expect(find.text('Equipo no disponible'), findsOneWidget);
    expect(find.text('Temporada actual'), findsNothing);
    expect(find.textContaining('#'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _openTab(tester, 'Partidos');
    expect(find.text('Sin partidos disponibles'), findsOneWidget);
    await _openTab(tester, 'Noticias');
    expect(find.text('Sin noticias disponibles'), findsOneWidget);
    await _openTab(tester, 'Transferencias');
    expect(find.text('Sin transferencias registradas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('team chip opens the team profile', (tester) async {
    await _pumpPlayer(tester, _payload(player: _rich));
    await tester.tap(find.text('Club Local').first);
    await tester.pumpAndSettle();
    expect(find.text('Equipo fb_team'), findsOneWidget);
  });

  testWidgets('stored goal and assist events appear as recent activity', (
    tester,
  ) async {
    await _pumpPlayer(tester, _payload(player: _rich));
    await _scrollSummaryTo(tester, 'Actividad reciente');
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.text('Asistencia · 70′'), findsOneWidget);
    await tester.tap(find.text('Gol · 23′'));
    await tester.pumpAndSettle();
    expect(find.text('Partido fb_match_past'), findsOneWidget);
  });

  testWidgets('news and only this player transfers are listed', (tester) async {
    await _pumpPlayer(
      tester,
      _payload(
        player: _rich,
        news: [
          {
            'title': 'El delantero renueva',
            'sourceName': 'Diario',
            'publishedAt': '2026-09-10T12:00:00Z',
          },
        ],
        transfers: [
          {
            'playerId': 'fb_player',
            'fromTeamId': 'fb_old',
            'fromTeamName': 'Club Viejo',
            'toTeamId': 'fb_team',
            'toTeamName': 'Club Local',
            'detectedAt': '2026-08-01T12:00:00Z',
          },
          {
            'playerId': 'fb_someone_else',
            'fromTeamName': 'Otro Club',
            'toTeamName': 'Club Local',
          },
        ],
      ),
    );
    await _openTab(tester, 'Noticias');
    expect(find.text('El delantero renueva'), findsOneWidget);
    await _openTab(tester, 'Transferencias');
    expect(find.text('Club Viejo'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
    expect(find.text('Otro Club'), findsNothing);
    await tester.tap(find.text('Club Viejo'));
    await tester.pumpAndSettle();
    expect(find.text('Equipo fb_team'), findsOneWidget);
  });

  for (final size in [const Size(320, 640), const Size(360, 740)]) {
    testWidgets('rich and long profile fits ${size.width.toInt()}px', (
      tester,
    ) async {
      await _pumpPlayer(
        tester,
        _payload(
          player: {
            ..._rich,
            'name': _longName,
            'nationality': 'República Democrática de Ejemplo Muy Larga',
            'marketValue': 'Valor publicado muy largo sin divisa conocida',
            'media': null,
          },
        ),
        size: size,
      );
      expect(find.text(_longName), findsWidgets);
      await _scrollSummaryTo(tester, 'Temporada actual');
      expect(tester.takeException(), isNull);
      for (final tab in ['Partidos', 'Estadísticas', 'Transferencias']) {
        await _openTab(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  }
}

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/features/entities/player_profile.dart';
import 'package:futbeat/features/matches/match_screen.dart';
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
  PlayerProfileMatchContext? matchContext,
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
        builder: (_, state) => EntityScreen(
          type: 'player',
          id: state.pathParameters['id']!,
          playerMatchContext: matchContext,
        ),
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
        (ref, request) => Stream.value(Snapshot(payload)),
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
  test(
    'season stats hide negative, fractional and non-finite counts/rating',
    () {
      final season = playerSeason(
        Entity({
          'id': 'fb_player_invalid_stats',
          'name': 'Jugador',
          'seasonStats': {
            'matchesPlayed': -1,
            'starts': 2.5,
            'minutesPlayed': '-90',
            'goals': '1.5',
            'assists': 0,
            'yellowCards': 3,
            'rating': double.nan,
          },
        }),
      );
      expect(season.rows.map((row) => (row.$2, row.$3)).toList(), [
        ('Asistencias', '0'),
        ('Amarillas', '3'),
      ]);
      expect(
        playerSeason(
          Entity({
            'id': 'fb_player_negative_rating',
            'name': 'Jugador',
            'rating': -2,
          }),
        ).rows,
        isEmpty,
      );
    },
  );

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

  testWidgets('Partidos resolves an explicit alias of the current team', (
    tester,
  ) async {
    final payload = _payload(player: {'teamId': 'fb_team_old'});
    payload['entityRedirects'] = {'fb_team_old': 'fb_team'};
    await _pumpPlayer(tester, payload);
    await _openTab(tester, 'Partidos');
    expect(find.text('Próximos'), findsOneWidget);
    expect(find.text('Resultados'), findsOneWidget);
  });

  testWidgets(
    'Partidos includes confirmed club activity when current team is national',
    (tester) async {
      final payload = _payload(player: {'teamId': 'fb_national_team'});
      (payload['teams'] as List).add({
        'id': 'fb_national_team',
        'name': 'Selección Local',
      });
      (payload['matches'] as List).add({
        'id': 'fb_national_match',
        'competitionId': 'fb_comp',
        'homeTeamId': 'fb_national_team',
        'awayTeamId': 'fb_rival',
        'startTime': '2026-10-04T18:00:00Z',
        'status': 'VERIFIED',
        'score': {'home': 1, 'away': 0},
        'events': <dynamic>[],
      });
      (payload['matches'] as List).add({
        'id': 'fb_club_match',
        'competitionId': 'fb_comp',
        'homeTeamId': 'fb_team',
        'awayTeamId': 'fb_rival',
        'startTime': '2026-10-18T18:00:00Z',
        'status': 'VERIFIED',
        'score': {'home': 1, 'away': 0},
        'events': [
          {
            'id': 'club_goal',
            'type': 'GOAL',
            'minute': 44,
            'playerId': 'fb_player',
            'teamId': 'fb_team',
          },
        ],
      });
      await _pumpPlayer(tester, payload);
      await _openTab(tester, 'Partidos');
      expect(
        find.textContaining('Dom 18 oct', findRichText: true),
        findsWidgets,
      );
    },
  );

  test('club activity requires player ID, not a matching name', () {
    final payload = _payload(player: {'teamId': 'fb_national_team'});
    (payload['teams'] as List).add({
      'id': 'fb_national_team',
      'name': 'Selección Local',
    });
    (payload['matches'] as List).add({
      'id': 'fb_same_name_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_team',
      'awayTeamId': 'fb_rival',
      'startTime': '2026-10-18T18:00:00Z',
      'status': 'VERIFIED',
      'events': [
        {
          'type': 'GOAL',
          'minute': 44,
          'playerId': 'fb_other_player',
          'playerName': 'Delantero Estrella',
        },
      ],
    });
    final data = Snapshot(payload);
    expect(
      playerProfileMatches(data, data.player('fb_player')!).map((m) => m.id),
      isNot(contains('fb_same_name_match')),
    );
  });

  testWidgets('Partidos never labels LIVE or suspended as Próximos', (
    tester,
  ) async {
    final payload = _payload(player: _rich);
    final matches = payload['matches'] as List;
    for (final (id, status) in [
      ('fb_match_live', 'LIVE'),
      ('fb_match_suspended', 'SUSPENDED'),
    ]) {
      matches.add({
        'id': id,
        'competitionId': 'fb_comp',
        'homeTeamId': 'fb_team',
        'awayTeamId': 'fb_rival',
        'startTime': '2026-09-20T18:00:00Z',
        'status': status,
        'events': <dynamic>[],
        'statistics': <dynamic>[],
      });
    }
    await _pumpPlayer(tester, payload);
    await _openTab(tester, 'Partidos');
    expect(find.text('En vivo'), findsOneWidget);
    expect(find.text('Próximos'), findsOneWidget);
    expect(find.text('Otros estados'), findsOneWidget);
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

  testWidgets('an unknown dorsal (0, "0", empty) shows no badge or card', (
    tester,
  ) async {
    for (final unknown in <Object>[0, '0', '', ' ']) {
      await _pumpPlayer(
        tester,
        _payload(player: {'shirtNumber': unknown, 'country': 'Chile'}),
      );
      expect(find.text('#0'), findsNothing, reason: '$unknown');
      expect(find.text('Dorsal'), findsNothing, reason: '$unknown');
    }
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
    final payload = _payload(team: false);
    for (final match in payload['matches'] as List) {
      match['events'] = <dynamic>[];
    }
    await _pumpPlayer(tester, payload);
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

  test('recent activity follows an explicit canonical player redirect', () {
    final payload = _payload();
    payload['entityRedirects'] = {'fb_player_old': 'fb_player'};
    final events = ((payload['matches'] as List).first['events'] as List);
    (events.first as Map)['playerId'] = 'fb_player_old';
    (events.last as Map)['assistPlayerId'] = 'fb_player_old';

    final activity = playerRecentEvents(Snapshot(payload), 'fb_player');
    expect(activity, hasLength(2));
    expect(activity.where((entry) => entry.$3), hasLength(1));
  });

  test(
    'club and national-team events share an ID without merging homonyms',
    () {
      final payload = _payload();
      (payload['teams'] as List).add({
        'id': 'fb_national_team',
        'name': 'Selección Local',
        'country': 'Costa Rica',
      });
      (payload['matches'] as List).add({
        'id': 'fb_national_match',
        'competitionId': 'fb_comp',
        'homeTeamId': 'fb_national_team',
        'awayTeamId': 'fb_rival',
        'startTime': '2026-09-22T18:00:00Z',
        'status': 'FINISHED',
        'events': [
          {
            'type': 'GOAL',
            'minute': 12,
            'playerId': 'fb_player',
            'teamId': 'fb_national_team',
          },
          {
            'type': 'GOAL',
            'minute': 20,
            'playerId': 'fb_homonym',
            'teamId': 'fb_national_team',
          },
        ],
        'statistics': <dynamic>[],
      });

      final activity = playerRecentEvents(Snapshot(payload), 'fb_player');
      expect(activity, hasLength(3));
      expect(
        activity.where((entry) => entry.$1.id == 'fb_national_match'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'Match Center context shows only real summary, provider stats and events',
    (tester) async {
      await _pumpPlayer(
        tester,
        _payload(player: _rich),
        matchContext: PlayerProfileMatchContext(
          team: Entity({
            'id': 'fb_team',
            'name': 'Club Local',
            'country': 'Costa Rica',
          }),
          summary: const PlayerMatchSummary(
            rating: 8.4,
            minutes: 72,
            goals: 1,
            assists: 1,
            yellowCards: 1,
          ),
          statSections: const [
            (
              'Pases',
              [('Pases precisos', '21/25'), ('Ocasiones creadas', '3')],
            ),
            ('Defensa', [('Duelos', '6/9'), ('Recuperaciones', '4')]),
          ],
          events: const [
            LineupPlayerEvent('GOAL', 23),
            LineupPlayerEvent('ASSIST', 51),
            LineupPlayerEvent('YELLOW_CARD', 64),
            LineupPlayerEvent('SUB_OUT', 72, role: 'out'),
            LineupPlayerEvent('OWN_GOAL', 12),
          ],
        ),
      );

      expect(find.text('En este partido'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-current-match')),
        findsOneWidget,
      );
      for (final text in ['8.4', '72′']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      await _scrollSummaryTo(tester, 'Ocasiones creadas');
      for (final text in [
        'Pases precisos',
        '21/25',
        'Duelos',
        'Ocasiones creadas',
      ]) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      await _scrollSummaryTo(tester, 'EVENTOS');
      for (final type in [
        'GOAL',
        'ASSIST',
        'YELLOW_CARD',
        'SUB_OUT',
        'OWN_GOAL',
      ]) {
        expect(
          find.byKey(
            ValueKey(
              'player-current-event-$type-${switch (type) {
                'GOAL' => 23,
                'ASSIST' => 51,
                'YELLOW_CARD' => 64,
                'SUB_OUT' => 72,
                _ => 12,
              }}',
            ),
          ),
          findsOneWidget,
          reason: type,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty match context explains missing data without fake zeros', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      _payload(player: _rich),
      matchContext: const PlayerProfileMatchContext(
        team: null,
        summary: PlayerMatchSummary(),
        statSections: [],
        events: [],
      ),
      size: const Size(320, 640),
    );
    expect(find.text('En este partido'), findsOneWidget);
    expect(find.text('Sin datos individuales del partido'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'own goal is labelled for its scorer and never creates an assist',
    (tester) async {
      final payload = _payload(player: _rich);
      final events = ((payload['matches'] as List).first['events'] as List);
      (events.first as Map)['ownGoal'] = true;
      (events.last as Map)['ownGoal'] = true;
      final data = Snapshot(payload);
      expect(playerRecentEvents(data, 'fb_player'), hasLength(1));
      await _pumpPlayer(tester, payload);
      await _scrollSummaryTo(tester, 'Actividad reciente');
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(find.text('Autogol · 23′'), findsOneWidget);
      expect(find.text('Asistencia · 70′'), findsNothing);
      expect(find.text('Gol · 23′'), findsNothing);
    },
  );

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
          {'fromTeamName': 'Origen sin jugador', 'toTeamName': 'Club Local'},
        ],
      ),
    );
    await _openTab(tester, 'Noticias');
    expect(find.text('El delantero renueva'), findsOneWidget);
    await _openTab(tester, 'Transferencias');
    expect(find.text('Club Viejo'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
    expect(find.text('Otro Club'), findsNothing);
    expect(find.text('Origen sin jugador'), findsNothing);
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

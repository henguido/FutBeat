import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

const _longHome = 'Club Deportivo Asociación Muy Larga de Nombre Extenso FC';
const _longAway = 'Real Sociedad Deportiva Visitante con Nombre Larguísimo';

Map<String, dynamic> _payload({
  String status = 'VERIFIED',
  Map<String, dynamic>? score = const {'home': 2, 'away': 1},
  DateTime? start,
  int? minute,
  bool table = false,
  bool longNames = false,
  List<Map<String, dynamic>> events = const [],
  List<Map<String, dynamic>> statistics = const [],
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-20T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba'},
  ],
  'teams': [
    {'id': 'fb_home', 'name': longNames ? _longHome : 'Local FC'},
    {'id': 'fb_away', 'name': longNames ? _longAway : 'Visita FC'},
  ],
  'players': [
    {'id': 'fb_player_home_9', 'name': 'Goleador Local', 'teamId': 'fb_home'},
  ],
  'standings': table
      ? [
          {
            'competitionId': 'fb_comp',
            'rows': [
              {
                'teamId': 'fb_home',
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
        ]
      : [],
  'matches': [
    {
      'id': 'fb_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': (start ?? DateTime.utc(2026, 9, 20, 18)).toIso8601String(),
      'status': status,
      'score': ?score,
      'minute': ?minute,
      'events': events,
      'statistics': statistics,
    },
  ],
};

Map<String, dynamic> _detail({
  List<Map<String, dynamic>> incidents = const [],
  List<Map<String, dynamic>> statistics = const [],
  Map<String, dynamic> home = const {},
  Map<String, dynamic> away = const {},
}) => {
  'matchId': 'fb_match',
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'stadium': 'Estadio Nacional',
  'referee': 'Árbitro Central',
  'round': '7',
  'home': home,
  'away': away,
  'statistics': statistics,
  'incidents': incidents,
};

Future<void> _pumpMatch(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Map<String, dynamic>? detail,
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
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(Dio())),
      matchContextSnapshotProvider.overrideWith(
        (ref, id) async => Snapshot(payload),
      ),
      matchDetailProvider.overrideWith(
        (ref, id) => Stream.value(
          detail == null ? MatchDetail.empty(id) : MatchDetail(detail),
        ),
      ),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _tabLabels(WidgetTester tester) => [
  for (final tab in tester.widget<TabBar>(find.byType(TabBar)).tabs)
    (tab as Tab).text!,
];

void main() {
  testWidgets('upcoming match shows kickoff time instead of a score', (
    tester,
  ) async {
    final start = DateTime.now().toUtc().add(const Duration(days: 2));
    await _pumpMatch(
      tester,
      _payload(status: 'SCHEDULED', score: null, start: start),
    );
    expect(find.text('PROGRAMADO'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text(matchDateLabel(costaRicaTime(start))), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live match shows big score and visible minute', (tester) async {
    await _pumpMatch(
      tester,
      _payload(
        status: 'LIVE',
        minute: 63,
        start: DateTime.now().toUtc().subtract(const Duration(minutes: 70)),
      ),
    );
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('63′ · EN VIVO'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('final match shows result, stadium and match info', (
    tester,
  ) async {
    await _pumpMatch(tester, _payload(), detail: _detail());
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('FINALIZADO'), findsOneWidget);
    expect(find.text('Liga de Prueba · Jornada 7'), findsOneWidget);
    expect(find.text('Estadio Nacional'), findsWidgets);
    await tester.dragUntilVisible(
      find.text('Árbitro Central'),
      find.byType(CustomScrollView).first,
      const Offset(0, -200),
    );
    expect(find.text('Árbitro Central'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial score is labelled and never presented as scheduled', (
    tester,
  ) async {
    await _pumpMatch(
      tester,
      _payload(
        status: 'SCHEDULED',
        start: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
      ),
    );
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('MARCADOR PARCIAL'), findsOneWidget);
    expect(find.text('PROGRAMADO'), findsNothing);
  });

  for (final (status, label) in [
    ('HALFTIME', 'DESCANSO'),
    ('POSTPONED', 'APLAZADO'),
    ('SUSPENDED', 'SUSPENDIDO'),
    ('CANCELLED', 'CANCELADO'),
  ]) {
    testWidgets('$status uses a readable Spanish state', (tester) async {
      await _pumpMatch(tester, _payload(status: status, score: null));
      expect(find.text(label), findsOneWidget);
      expect(find.textContaining(status), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('timeline separates home and away without technical labels', (
    tester,
  ) async {
    await _pumpMatch(
      tester,
      _payload(
        events: [
          {'id': 'k', 'type': 'KICKOFF', 'minute': 0},
          {
            'id': 'g',
            'type': 'GOAL',
            'minute': 23,
            'teamId': 'fb_home',
            'playerId': 'fb_player_home_9',
          },
          {'id': 'h', 'type': 'HALFTIME', 'minute': 45},
        ],
      ),
      detail: _detail(
        incidents: [
          {
            'type': 'YELLOW_CARD',
            'minute': 38,
            'detail': 'Jugador Visitante',
            'side': 'away',
          },
          {
            'type': 'SUBSTITUTION',
            'minute': 60,
            'detail': 'Entra Uno',
            'team': 'home',
          },
          {'type': 'VAR', 'minute': 70, 'detail': 'Revisión', 'side': 'away'},
          {
            'type': 'MISSED_PENALTY',
            'minute': 80,
            'extraMinute': 2,
            'detail': 'Fallador',
            'side': 'home',
          },
        ],
      ),
    );
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Medio tiempo'), findsOneWidget);
    expect(find.byType(EventGlyph), findsNWidgets(5));
    expect(find.text('23′'), findsOneWidget);
    expect(find.text('80+2′'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(find.text('away'), findsNothing);
    expect(find.textContaining('· home'), findsNothing);

    final center = tester.getCenter(find.byType(MatchTimeline)).dx;
    expect(tester.getCenter(find.text('Goleador Local')).dx, lessThan(center));
    expect(tester.getCenter(find.text('Entra Uno')).dx, lessThan(center));
    expect(
      tester.getCenter(find.text('Jugador Visitante')).dx,
      greaterThan(center),
    );
    expect(tester.getCenter(find.text('Revisión')).dx, greaterThan(center));
    expect(tester.takeException(), isNull);
  });

  testWidgets('statistics render two-sided bars and Spanish labels', (
    tester,
  ) async {
    await _pumpMatch(
      tester,
      _payload(),
      detail: _detail(
        statistics: [
          {'label': 'Shots on Goal', 'home': 5, 'away': 2},
          {'label': 'Ball Possession', 'home': '58%', 'away': '42%'},
          {'label': 'Expected goals', 'home': '1.2', 'away': '—'},
        ],
      ),
    );
    await tester.tap(find.text('Estadísticas'));
    await tester.pumpAndSettle();
    expect(find.text('Posesión'), findsOneWidget);
    expect(find.text('Tiros a puerta'), findsOneWidget);
    expect(find.text('58%'), findsOneWidget);
    // Non-numeric side keeps its value but never gets an invented bar.
    expect(find.text('Goles esperados (xG)'), findsOneWidget);
    expect(find.byKey(const ValueKey('stat-bars')), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Posesión')).dy,
      lessThan(tester.getTopLeft(find.text('Tiros a puerta')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing statistics show a final empty state', (tester) async {
    await _pumpMatch(tester, _payload(), detail: _detail());
    await tester.tap(find.text('Estadísticas'));
    await tester.pumpAndSettle();
    expect(find.text('Sin estadísticas'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('lineup mixes existing photos and elegant fallbacks', (
    tester,
  ) async {
    await _pumpMatch(
      tester,
      _payload(),
      detail: _detail(
        home: {
          'formation': '4-3-3',
          'starters': [
            for (var i = 1; i <= 11; i++)
              {
                'id': 'h$i',
                'name': 'Jugador Local Número $i',
                'number': '$i',
                'lineupPosition': i,
                'captain': i == 4,
                'rating': i == 9 ? 8.1 : null,
                if (i == 9)
                  'media': {
                    'url': 'https://media.example.test/h9.png',
                    'verificationStatus': 'VERIFIED',
                  },
              },
          ],
          'substitutes': [
            {
              'id': 'h12',
              'name': 'Suplente Local',
              'number': '12',
              'position': 'Defender',
            },
          ],
          'coach': {'name': 'Entrenador Local'},
        },
        away: {
          'starters': [
            {'id': 'a1', 'name': 'Portero Visita', 'position': 'Goalkeeper'},
          ],
        },
      ),
    );
    await tester.ensureVisible(find.text('Alineación'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alineación'));
    await tester.pumpAndSettle();
    expect(find.text('4-3-3'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('8.1'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // Players without photo show initials, never a broken image or spinner.
    expect(find.text('JL'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.dragUntilVisible(
      find.text('Entrenador Local'),
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    expect(find.text('#12 · Defensa'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabs are stable: Tabla exists without standings (empty state)', (
    tester,
  ) async {
    await _pumpMatch(tester, _payload());
    expect(_tabLabels(tester), [
      'Previa',
      'Estadísticas',
      'Alineación',
      'Tabla',
      'Cara a cara',
    ]);
    await tester.ensureVisible(find.text('Tabla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tabla'));
    await tester.pumpAndSettle();
    expect(find.text('Sin tabla disponible'), findsOneWidget);
    expect(find.text('Clasificación'), findsNothing);
  });

  testWidgets('table tab appears and renders when standings exist', (
    tester,
  ) async {
    await _pumpMatch(tester, _payload(table: true));
    expect(_tabLabels(tester), [
      'Previa',
      'Estadísticas',
      'Alineación',
      'Tabla',
      'Cara a cara',
    ]);
    await tester.ensureVisible(find.text('Tabla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tabla'));
    await tester.pumpAndSettle();
    expect(find.text('Clasificación'), findsOneWidget);
    expect(find.text('Tabla no disponible'), findsNothing);
  });

  testWidgets('long names and two-digit scores fit a narrow phone', (
    tester,
  ) async {
    await _pumpMatch(
      tester,
      _payload(
        status: 'LIVE',
        minute: 90,
        longNames: true,
        score: {'home': 10, 'away': 12},
        start: DateTime.now().toUtc().subtract(const Duration(minutes: 95)),
        events: [
          {
            'id': 'g',
            'type': 'GOAL',
            'minute': 90,
            'extraMinute': 4,
            'teamId': 'fb_away',
          },
        ],
      ),
      size: const Size(320, 640),
    );
    expect(find.text('10 - 12'), findsOneWidget);
    expect(find.text(_longHome), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

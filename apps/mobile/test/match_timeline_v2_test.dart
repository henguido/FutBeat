import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

const _home = 'team_home';
const _away = 'team_away';

Json _event(
  String id,
  String type,
  int? minute, {
  int? extra,
  String? team,
  String? player,
  String? assist,
  bool ownGoal = false,
  bool penalty = false,
  Json? score,
  String? detail,
}) => {
  'id': id,
  'type': type,
  'minute': minute,
  'extraMinute': ?extra,
  'teamId': ?team,
  'playerId': ?player,
  'assistPlayerId': ?assist,
  if (ownGoal) 'ownGoal': true,
  if (penalty) 'penalty': true,
  'score': ?score,
  'detail': ?detail,
};

List<Json> _completeEvents() => [
  _event('ft', 'FULL_TIME', null),
  _event('pens', 'PENALTIES', null),
  _event('et', 'EXTRA_TIME', 90),
  _event('second', 'SECOND_HALF', 45),
  _event('half', 'HALFTIME', 45),
  _event('ko', 'KICKOFF', 0),
  _event(
    'goal',
    'GOAL',
    12,
    team: _home,
    player: 'player_goal',
    assist: 'player_assist',
    score: {'home': 1, 'away': 0},
  ),
  _event(
    'own',
    'GOAL',
    23,
    team: _away,
    player: 'player_own',
    ownGoal: true,
    score: {'home': 2, 'away': 0},
  ),
  _event(
    'pen',
    'GOAL',
    45,
    extra: 2,
    team: _away,
    player: 'player_penalty',
    penalty: true,
    score: {'home': 2, 'away': 1},
  ),
  _event('yellow', 'YELLOW_CARD', 55, team: _home, player: 'player_out'),
  _event(
    'second-yellow',
    'SECOND_YELLOW_CARD',
    57,
    team: _away,
    player: 'player_own',
  ),
  _event('red', 'RED_CARD', 59, team: _away, player: 'player_penalty'),
  _event(
    'sub',
    'SUBSTITUTION',
    68,
    team: _home,
    player: 'player_out',
    assist: 'player_in',
  ),
  _event('var', 'VAR', 70, team: _away, detail: 'Revisión confirmada'),
  _event(
    'missed',
    'MISSED_PENALTY',
    90,
    extra: 4,
    team: _home,
    player: 'player_out',
  ),
  _event('et-goal', 'GOAL', 105, team: _home, player: 'player_goal'),
];

Json _payload({required String status, required List<Json> events}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-07T12:00:00Z',
  'competitions': [
    {'id': 'competition', 'name': 'Liga de Prueba'},
  ],
  'teams': [
    {'id': _home, 'name': 'FutBeat Local'},
    {'id': _away, 'name': 'FutBeat Visitante'},
  ],
  'players': [
    {
      'id': 'player_goal',
      'name': 'Goleador de Nombre Extraordinariamente Largo',
    },
    {'id': 'player_assist', 'name': 'Asistente Real'},
    {'id': 'player_own', 'name': 'Autor del Autogol'},
    {'id': 'player_penalty', 'name': 'Especialista Penal'},
    {'id': 'player_out', 'name': 'Jugador que sale'},
    {'id': 'player_in', 'name': 'Jugador que entra'},
  ],
  'matches': [
    {
      'id': 'match',
      'competitionId': 'competition',
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': '2026-10-07T18:00:00Z',
      'status': status,
      'score': {'home': 3, 'away': 1},
      'events': events,
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
};

MatchDetail _detail([List<Json> incidents = const []]) => MatchDetail({
  ...MatchDetail.empty('match').json,
  'available': true,
  'pending': false,
  'incidents': incidents,
});

Future<void> _pumpTimeline(
  WidgetTester tester, {
  required List<Json> events,
  String status = 'VERIFIED',
  List<Json> incidents = const [],
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final data = Snapshot(_payload(status: status, events: events));
  final match = data.match('match')!;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: MatchTimeline(data, match, _detail(incidents)),
          ),
        ),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) =>
            Scaffold(body: Text('profile:${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(theme: futbeatTheme(), routerConfig: router),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('display helpers only use explicit structured evidence', () {
    expect(timelineDisplayType({'type': 'GOAL', 'ownGoal': true}), 'OWN_GOAL');
    expect(
      timelineDisplayType({'type': 'GOAL', 'penalty': true}),
      'PENALTY_GOAL',
    );
    expect(timelineDisplayType({'type': 'GOAL', 'detail': 'Penalty'}), 'GOAL');
    expect(
      timelineScoreAfter({
        'score': {'home': 2, 'away': 1},
      }),
      '2–1',
    );
    expect(
      timelineScoreAfter({
        'score': {'home': 2},
      }),
      isNull,
    );
  });

  test('explicit phases, added time and ET have football order', () {
    final match = Snapshot(
      _payload(status: 'VERIFIED', events: _completeEvents()),
    ).match('match')!;
    final ids = match.events.map((event) => event['id']).toList();
    expect(ids.indexOf('ko'), lessThan(ids.indexOf('goal')));
    expect(ids.indexOf('pen'), lessThan(ids.indexOf('half')));
    expect(ids.indexOf('half'), lessThan(ids.indexOf('second')));
    expect(ids.indexOf('second'), lessThan(ids.indexOf('yellow')));
    expect(ids.indexOf('missed'), lessThan(ids.indexOf('et')));
    expect(ids.indexOf('et'), lessThan(ids.indexOf('et-goal')));
    expect(ids.indexOf('et-goal'), lessThan(ids.indexOf('pens')));
    expect(ids.indexOf('pens'), lessThan(ids.indexOf('ft')));
  });

  testWidgets('complete timeline exposes structured football context', (
    tester,
  ) async {
    await _pumpTimeline(tester, events: _completeEvents());
    expect(find.text('Gol'), findsNWidgets(2));
    expect(find.text('Autogol'), findsOneWidget);
    expect(find.text('Gol · Penal'), findsOneWidget);
    expect(find.text('Asistencia: Asistente Real'), findsOneWidget);
    expect(find.text('1–0'), findsOneWidget);
    expect(find.text('45+2′'), findsOneWidget);
    expect(find.text('90+4′'), findsOneWidget);
    expect(find.text('Segunda amarilla'), findsOneWidget);
    expect(find.text('Revisión confirmada'), findsOneWidget);
    expect(find.text('↑ Jugador que entra'), findsOneWidget);
    expect(find.text('↓ Jugador que sale'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'canonical player names navigate; raw names do not invent routes',
    (tester) async {
      await _pumpTimeline(
        tester,
        events: [
          _event('goal', 'GOAL', 12, team: _home, player: 'player_goal'),
        ],
        incidents: const [
          {'type': 'YELLOW_CARD', 'minute': 20, 'playerName': 'Sin identidad'},
        ],
      );
      final rawPerson = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Sin identidad'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(rawPerson.onTap, isNull);
      await tester.tap(
        find.text('Goleador de Nombre Extraordinariamente Largo'),
      );
      await tester.pumpAndSettle();
      expect(find.text('profile:player_goal'), findsOneWidget);
    },
  );

  testWidgets('LIVE emphasizes only the latest real event', (tester) async {
    await _pumpTimeline(
      tester,
      status: 'LIVE',
      events: [
        _event('goal', 'GOAL', 12, team: _home, player: 'player_goal'),
        _event('yellow', 'YELLOW_CARD', 18, team: _away, player: 'player_own'),
      ],
    );
    expect(find.byKey(const ValueKey('timeline-latest-live')), findsOneWidget);
  });

  testWidgets('finished match with no events has a final empty state', (
    tester,
  ) async {
    await _pumpTimeline(tester, events: const []);
    expect(find.text('Sin eventos'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('long timeline has no overflow at ${width.toInt()} px', (
      tester,
    ) async {
      await _pumpTimeline(
        tester,
        events: _completeEvents(),
        size: Size(width, 844),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('same-minute distinct events survive; true duplicate is folded', () {
    final events = [
      _event('a', 'YELLOW_CARD', 30, team: _home, player: 'player_goal'),
      _event('b', 'YELLOW_CARD', 30, team: _home, player: 'player_assist'),
      _event('c', 'GOAL', 40, team: _home, player: 'player_goal'),
      _event('d', 'GOAL', 40, team: _home, player: 'player_goal'),
    ];
    final data = Snapshot(_payload(status: 'VERIFIED', events: events));
    final timeline = mergedMatchTimeline(data.match('match')!, _detail());
    expect(
      timeline.where((event) => event['type'] == 'YELLOW_CARD'),
      hasLength(2),
    );
    expect(timeline.where((event) => event['type'] == 'GOAL'), hasLength(1));
  });

  testWidgets('timeline golden: complete', (tester) async {
    await _pumpTimeline(
      tester,
      events: _completeEvents(),
      size: const Size(390, 1800),
    );
    await expectLater(
      find.byType(MatchTimeline),
      matchesGoldenFile('goldens/timeline_v2_complete.png'),
    );
  }, tags: 'golden');

  testWidgets('timeline golden: LIVE', (tester) async {
    await _pumpTimeline(
      tester,
      status: 'LIVE',
      events: _completeEvents(),
      size: const Size(390, 1800),
    );
    await expectLater(
      find.byType(MatchTimeline),
      matchesGoldenFile('goldens/timeline_v2_live.png'),
    );
  }, tags: 'golden');

  for (final state in <String, List<Json>>{
    'goal_assist': [_completeEvents()[6]],
    'own_goal': [_completeEvents()[7]],
    'cards_substitution': _completeEvents().sublist(9, 13),
    'empty': const [],
  }.entries) {
    testWidgets('timeline golden: ${state.key}', (tester) async {
      await _pumpTimeline(tester, events: state.value);
      await expectLater(
        find.byType(MatchTimeline),
        matchesGoldenFile('goldens/timeline_v2_${state.key}.png'),
      );
    }, tags: 'golden');
  }
}

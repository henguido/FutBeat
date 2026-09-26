import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// #99: scorers and minutes under the Match Center score, built only from the
// deduplicated timeline (#121). Names only when the provider sent them; a
// goal whose side is unknown is never placed on a side.

const _match = 'fb_match_sc';
const _home = 'fb_team_sc_home';
const _away = 'fb_team_sc_away';

Map<String, dynamic> _snapshotJson({
  String status = 'VERIFIED',
  Map<String, int>? score,
  List<Map<String, dynamic>> events = const [],
}) {
  final now = DateTime.now().toUtc();
  final kickoff = status == 'SCHEDULED'
      ? now.add(const Duration(days: 1))
      : now.subtract(const Duration(hours: 3));
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': 'fb_comp_sc', 'name': 'Liga Goleadores'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Goleadores'},
      {'id': _away, 'name': 'Visita Goleadores'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_sc',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': kickoff.toIso8601String(),
        'status': status,
        'season': '2026',
        'score': ?score,
        if (status == 'LIVE') ...{
          'minute': 60,
          'liveChangedAt': now.toIso8601String(),
        },
        'events': events,
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _detailJson(List<Map<String, dynamic>> incidents) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const <dynamic>[],
  'incidents': incidents,
  'videos': const <dynamic>[],
};

Map<String, dynamic> _goal(
  String side,
  int minute, {
  String? name,
  int? extra,
}) => {
  'type': 'GOAL',
  'minute': minute,
  'extraMinute': ?extra,
  'label': 'Gol',
  'side': side,
  'playerName': ?name,
};

({List<ScorerLine> home, List<ScorerLine> away}) _summary(
  Map<String, dynamic> snapshot,
  List<Map<String, dynamic>> incidents,
) {
  final data = Snapshot(snapshot);
  return matchScorerSummary(
    data.match(_match)!,
    MatchDetail(_detailJson(incidents)),
    data,
  );
}

List<String> _labels(List<ScorerLine> lines) =>
    lines.map((line) => line.label).toList();

// FT 4-3 with a brace and stoppage-time goals.
final _ft43 = [
  _goal('home', 35, name: 'M. Nasibov'),
  _goal('home', 44, name: 'M. Nasibov'),
  _goal('home', 45, extra: 2, name: 'I. Vagabov'),
  _goal('home', 70, name: 'K. Local'),
  _goal('away', 80, name: 'M. Ibragimov'),
  _goal('away', 90, extra: 1, name: 'I. Tutov'),
  _goal('away', 90, extra: 3, name: 'I. Gubzhokov'),
];

class _Server {
  _Server(this.snapshot, this.detail);
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> detail;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/v1/match-context') {
            handler.resolve(Response(requestOptions: options, data: snapshot));
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
          handler.resolve(Response(requestOptions: options, data: detail));
        },
      ),
    );
}

Future<ProviderContainer> _open(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  addTearDown(() => tester.runAsync(db.close));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatchScreen(id: _match)),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return container;
}

Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

void main() {
  group('matchScorerSummary', () {
    test('A. FT 4-3: names, brace grouped once, stoppage minutes, sides', () {
      final s = _summary(_snapshotJson(score: {'home': 4, 'away': 3}), _ft43);
      expect(_labels(s.home), [
        'M. Nasibov 35′, 44′',
        'I. Vagabov 45+2′',
        'K. Local 70′',
      ]);
      expect(_labels(s.away), [
        'M. Ibragimov 80′',
        'I. Tutov 90+1′',
        'I. Gubzhokov 90+3′',
      ]);
    });

    test('C. canonical GOAL + rich detail twin: one occurrence', () {
      final s = _summary(
        _snapshotJson(
          score: {'home': 1, 'away': 0},
          events: [
            {
              'id': 'fb_event_sc_1',
              'type': 'GOAL',
              'teamId': _home,
              'minute': 35,
            },
          ],
        ),
        [_goal('home', 35, name: 'M. Nasibov')],
      );
      expect(_labels(s.home), ['M. Nasibov 35′']);
      expect(s.away, isEmpty);
    });

    test('D. canonical-only goal without a name: "Gol 55′", no player '
        'invented; two anonymous goals never merge', () {
      final s = _summary(
        _snapshotJson(
          score: {'home': 2, 'away': 0},
          events: [
            for (final (id, minute) in [('a', 55), ('b', 70)])
              {
                'id': 'fb_event_sc_$id',
                'type': 'GOAL',
                'teamId': _home,
                'minute': minute,
                'score': minute == 55 ? '1 - 0' : '2 - 0',
              },
          ],
        ),
        const [],
      );
      expect(_labels(s.home), ['Gol 55′', 'Gol 70′']);
      expect(s.home.every((line) => line.name == null), isTrue);
    });

    test('D2. canonical goal with a known player identity shows that name', () {
      final json = _snapshotJson(
        score: {'home': 1, 'away': 0},
        events: [
          {
            'id': 'fb_event_sc_p',
            'type': 'GOAL',
            'teamId': _home,
            'playerId': 'fb_player_sc_9',
            'minute': 18,
          },
        ],
      );
      json['players'] = [
        {'id': 'fb_player_sc_9', 'name': 'C. Canónico'},
      ];
      expect(_labels(_summary(json, const []).home), ['C. Canónico 18′']);
    });

    test('E. no goals: empty summary', () {
      final s = _summary(
        _snapshotJson(score: {'home': 0, 'away': 0}),
        const [],
      );
      expect(s.home, isEmpty);
      expect(s.away, isEmpty);
    });

    test('G. a goal with no identifiable side is not placed on any side', () {
      final s = _summary(_snapshotJson(score: {'home': 1, 'away': 0}), [
        {
          'type': 'GOAL',
          'minute': 30,
          'label': 'Gol',
          'playerName': 'X. Nadie',
        },
      ]);
      expect(s.home, isEmpty);
      expect(s.away, isEmpty);
    });

    test('H. stoppage time keeps 45+2′ and 90+4′', () {
      final s = _summary(_snapshotJson(score: {'home': 1, 'away': 1}), [
        _goal('home', 45, extra: 2, name: 'A. Uno'),
        _goal('away', 90, extra: 4, name: 'B. Dos'),
      ]);
      expect(_labels(s.home), ['A. Uno 45+2′']);
      expect(_labels(s.away), ['B. Dos 90+4′']);
    });

    test('I. same name on both sides is never grouped together', () {
      final s = _summary(_snapshotJson(score: {'home': 1, 'away': 1}), [
        _goal('home', 10, name: 'J. Pérez'),
        _goal('away', 20, name: 'J. Pérez'),
      ]);
      expect(_labels(s.home), ['J. Pérez 10′']);
      expect(_labels(s.away), ['J. Pérez 20′']);
    });
  });

  group('Match Center header', () {
    testWidgets('A. FT shows grouped scorers under the score', (tester) async {
      final container = await _open(
        tester,
        _Server(
          _snapshotJson(score: {'home': 4, 'away': 3}),
          _detailJson(_ft43),
        ),
      );
      final header = find.byKey(const ValueKey('header-scorers'));
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.text('M. Nasibov 35′, 44′')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.textContaining('Nasibov')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('scorer-away-2')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('scorer-away-2'))).data,
        'I. Gubzhokov 90+3′',
      );
      await _close(tester, container);
    });

    testWidgets('B. LIVE shows a goal without waiting for FT', (tester) async {
      final container = await _open(
        tester,
        _Server(
          _snapshotJson(status: 'LIVE', score: {'home': 1, 'away': 0}),
          _detailJson([_goal('home', 12, name: 'L. Vivo')]),
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('scorer-home-0'))).data,
        'L. Vivo 12′',
      );
      await _close(tester, container);
    });

    testWidgets('E. 0-0 without goals: no scorers section', (tester) async {
      final container = await _open(
        tester,
        _Server(_snapshotJson(score: {'home': 0, 'away': 0}), _detailJson([])),
      );
      expect(find.byKey(const ValueKey('match-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('header-scorers')), findsNothing);
      await _close(tester, container);
    });

    testWidgets('F. SCHEDULED never shows scorers, even with a stray event', (
      tester,
    ) async {
      final container = await _open(
        tester,
        _Server(
          _snapshotJson(
            status: 'SCHEDULED',
            events: [
              {
                'id': 'fb_event_sc_x',
                'type': 'GOAL',
                'teamId': _home,
                'minute': 5,
              },
            ],
          ),
          _detailJson([_goal('home', 5, name: 'Z. Antes')]),
        ),
      );
      expect(find.byKey(const ValueKey('match-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('header-scorers')), findsNothing);
      await _close(tester, container);
    });
  });
}

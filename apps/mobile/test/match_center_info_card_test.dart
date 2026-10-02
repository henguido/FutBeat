import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_info_card.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// #99 "Información del partido" v2: only facts the app already has
// (competition + country, round/season, date and local time, venue,
// referee). Missing optional facts are hidden, never "—"/"N/D".

const _match = 'fb_match_ic';
const _home = 'fb_team_ic_home';
const _away = 'fb_team_ic_away';
const _longCompetition =
    'Campeonato Internacional de Clubes Campeones de la Confederación';
const _longVenue =
    'Estadio Metropolitano Municipal Doctor Ricardo Saprissa Aymá';
const _longReferee = 'Maximiliano Alejandro de la Santísima Trinidad Rodríguez';

Map<String, dynamic> _snapshot({
  String status = 'VERIFIED',
  String competition = 'Liga Info',
  String? country = 'Costa Rica',
  String? season = '2026',
  String? competitionSeason,
  String? venue,
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
      {
        'id': 'fb_comp_ic',
        'name': competition,
        'country': ?country,
        'season': ?competitionSeason,
      },
    ],
    'teams': [
      {'id': _home, 'name': 'Local Info'},
      {'id': _away, 'name': 'Visita Info'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_ic',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': kickoff.toIso8601String(),
        'status': status,
        'season': ?season,
        'venue': ?venue,
        if (status != 'SCHEDULED') 'score': {'home': 1, 'away': 0},
        'events': const <dynamic>[],
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _detail({
  String? round = '5',
  String? stadium = 'Estadio Info',
  String? referee = 'Árbitro Info',
  String? stage,
}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'round': round,
  'stadium': stadium,
  'referee': referee,
  'stage': ?stage,
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const <dynamic>[],
  'incidents': const <dynamic>[],
  'videos': const <dynamic>[],
};

List<MatchInfoItem> _items(
  Map<String, dynamic> snapshot,
  Map<String, dynamic> detail, {
  String venue = '',
}) {
  final data = Snapshot(snapshot);
  final match = data.match(_match)!;
  return matchInfoItems(
    match: match,
    competition: data.competition(match.competitionId)!,
    detail: MatchDetail(detail),
    venue: venue,
    localKickoffTime: '12:00',
  );
}

class _Server {
  _Server(this.snapshot, this.detail);
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> detail;
  int detailReads = 0;

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
  Map<String, dynamic>? detail,
  double width = 390,
}) async {
  final server = _Server(snapshot ?? _snapshot(), detail ?? _detail());
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container!,
      child: const MaterialApp(home: MatchScreen(id: _match)),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return server;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  _container?.dispose();
  _container = null;
}

final _card = find.byKey(const ValueKey('match-info-card'));

Future<void> _showCard(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _card,
    150,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _inCard(Finder finder) => find.descendant(of: _card, matching: finder);

void main() {
  group('round, phase and referee labels', () {
    test('a matchday number is a Jornada; a named round is localized', () {
      expect(matchRoundHeadline('4'), 'Jornada 4');
      expect(matchRoundHeadline('Quarter-finals'), 'Cuartos de final');
      expect(matchRoundHeadline('Semi-finals'), 'Semifinales');
      expect(matchRoundHeadline('Final'), 'Final');
      expect(
        matchRoundHeadline('Cuartos de final - Vuelta'),
        'Cuartos de final - Vuelta',
      );
      expect(matchRoundHeadline(' '), isNull);
      expect(matchRoundHeadline(null), isNull);
    });

    test('provider phases: generic labels translated, names kept', () {
      expect(matchPhaseLabel('Group Stage'), 'Fase de grupos');
      expect(matchPhaseLabel('Group 4'), 'Grupo 4');
      expect(matchPhaseLabel('Group b'), 'Grupo B');
      expect(matchPhaseLabel('Girone C'), 'Grupo C');
      expect(matchPhaseLabel('1/8-finals'), 'Octavos de final');
      expect(matchPhaseLabel('1/16-finals'), 'Dieciseisavos de final');
      expect(matchPhaseLabel('1/64-finals'), '1/64 de final');
      expect(
        matchPhaseLabel('Qualification - First Stage'),
        'Clasificación - Primera fase',
      );
      expect(matchPhaseLabel('Clausura'), 'Clausura');
      expect(
        matchPhaseLabel('Southern League Premier Central'),
        'Southern League Premier Central',
      );
    });

    test('a phase is hidden when it tells nothing new', () {
      expect(
        matchStageLabel(stage: 'Current', competitionName: 'Liga'),
        isNull,
      );
      expect(
        matchStageLabel(
          stage: 'premier league',
          competitionName: 'Premier League',
        ),
        isNull,
      );
      expect(
        matchStageLabel(
          stage: 'Quarter-finals',
          competitionName: 'Copa',
          round: 'Quarter-finals',
        ),
        isNull,
      );
      expect(matchStageLabel(stage: null, competitionName: 'Liga'), isNull);
      expect(
        matchStageLabel(stage: 'Clausura', competitionName: 'Liga', round: '5'),
        'Clausura',
      );
    });

    test('referee country moves to the secondary line', () {
      final split = splitReferee('Jesus Gil Manzano, Spain');
      expect(split.name, 'Jesus Gil Manzano');
      expect(split.country, 'Spain');
      expect(splitReferee('W. Lopez').country, isNull);
      expect(splitReferee('W. Lopez').name, 'W. Lopez');
      expect(splitReferee('Ana, 12').name, 'Ana, 12');
    });
  });

  group('matchInfoItems', () {
    test('phase item after the round; named round labelled Ronda', () {
      final items = _items(
        _snapshot(),
        _detail(round: 'Semi-finals', stage: 'Group Stage'),
        venue: 'Estadio Info',
      );
      expect(items.map((item) => item.id), [
        'competition',
        'date',
        'round',
        'stage',
        'venue',
        'referee',
      ]);
      final round = items.singleWhere((item) => item.id == 'round');
      expect(round.label, 'Ronda');
      expect(round.value, 'Semifinales');
      final stage = items.singleWhere((item) => item.id == 'stage');
      expect(stage.label, 'Fase');
      expect(stage.value, 'Fase de grupos');
    });

    test('"Current" phase and plain referee: no phase, no secondary', () {
      final items = _items(_snapshot(), _detail(stage: 'Current'));
      expect(items.any((item) => item.id == 'stage'), isFalse);
      final referee = items.singleWhere((item) => item.id == 'referee');
      expect(referee.secondary, isNull);
    });

    test('referee with nationality', () {
      final items = _items(
        _snapshot(),
        _detail(referee: 'Srdan Jovanovic, Serbia'),
      );
      final referee = items.singleWhere((item) => item.id == 'referee');
      expect(referee.value, 'Srdan Jovanovic');
      expect(referee.secondary, 'Serbia');
    });

    test('1-5. every real fact, in order, with secondary lines', () {
      final items = _items(_snapshot(), _detail(), venue: 'Estadio Info');
      expect(items.map((item) => item.id), [
        'competition',
        'date',
        'round',
        'venue',
        'referee',
      ]);
      expect(items[0].value, 'Liga Info');
      expect(items[0].secondary, 'Costa Rica');
      expect(items[1].secondary, '12:00');
      expect(items[2].value, '5');
      expect(items[2].secondary, 'Temporada 2026');
      expect(items[3].value, 'Estadio Info');
      expect(items[4].value, 'Árbitro Info');
    });

    test('6/7. only competition + date: no optional item, no placeholder', () {
      final items = _items(
        _snapshot(country: null, season: null),
        _detail(round: null, stadium: null, referee: null),
      );
      expect(items.map((item) => item.id), ['competition', 'date']);
      expect(items[0].secondary, isNull);
      for (final item in items) {
        for (final text in [item.value, item.secondary ?? '']) {
          expect(text, isNot(anyOf('—', 'N/D', 'No disponible')));
        }
      }
    });

    test('blank strings count as absent', () {
      final items = _items(
        _snapshot(country: '  ', season: ' '),
        _detail(round: ' ', stadium: '', referee: '  '),
        venue: '   ',
      );
      expect(items.map((item) => item.id), ['competition', 'date']);
    });

    test("the competition's current season never labels a match", () {
      final items = _items(
        _snapshot(season: null, competitionSeason: '2027'),
        _detail(),
      );
      expect(items.any((item) => item.id == 'season'), isFalse);
      final round = items.singleWhere((item) => item.id == 'round');
      expect(round.secondary, isNull);
    });

    test('season without round becomes its own item', () {
      final items = _items(_snapshot(season: '2025/26'), _detail(round: null));
      final season = items.singleWhere((item) => item.id == 'season');
      expect(season.value, '2025/26');
      expect(items.any((item) => item.id == 'round'), isFalse);
    });
  });

  group('card', () {
    testWidgets('11. before kickoff: every present fact is shown', (
      tester,
    ) async {
      await _open(tester, snapshot: _snapshot(status: 'SCHEDULED'));
      await _showCard(tester);
      expect(_inCard(find.text('Liga Info')), findsOneWidget);
      expect(_inCard(find.text('Costa Rica')), findsOneWidget);
      expect(_inCard(find.text('5')), findsOneWidget);
      expect(_inCard(find.text('Temporada 2026')), findsOneWidget);
      expect(_inCard(find.text('Estadio Info')), findsOneWidget);
      expect(_inCard(find.text('Árbitro Info')), findsOneWidget);
      expect(
        _inCard(find.byKey(const ValueKey('match-info-date'))),
        findsOneWidget,
      );
      await _close(tester);
    });

    testWidgets('12/13/14. after the final: same facts, same tab, no extra '
        'detail read', (tester) async {
      final server = await _open(tester);
      final controller = tester.widget<TabBar>(find.byType(TabBar)).controller!;
      final reads = server.detailReads;
      await _showCard(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      for (final text in [
        'Liga Info',
        'Costa Rica',
        'Estadio Info',
        'Árbitro Info',
      ]) {
        expect(_inCard(find.text(text)), findsOneWidget, reason: text);
      }
      expect(controller.index, 0);
      expect(server.detailReads, reads, reason: 'rendering reads nothing');
      await _close(tester);
    });

    testWidgets('6/7. competition + date only: a clean two-tile card', (
      tester,
    ) async {
      await _open(
        tester,
        snapshot: _snapshot(country: null, season: null),
        detail: _detail(round: null, stadium: null, referee: null),
      );
      await _showCard(tester);
      for (final id in ['round', 'season', 'venue', 'referee']) {
        expect(
          _inCard(find.byKey(ValueKey('match-info-$id'))),
          findsNothing,
          reason: id,
        );
      }
      expect(
        _inCard(find.byKey(const ValueKey('match-info-competition'))),
        findsOneWidget,
      );
      expect(
        _inCard(find.byKey(const ValueKey('match-info-date'))),
        findsOneWidget,
      );
      for (final placeholder in ['—', 'N/D', 'No disponible']) {
        expect(_inCard(find.text(placeholder)), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('phase and referee country shown when present', (tester) async {
      await _open(
        tester,
        detail: _detail(
          round: 'Final',
          stage: '1/8-finals',
          referee: 'Jesus Gil Manzano, Spain',
        ),
      );
      expect(find.text('Liga Info · Final'), findsOneWidget);
      expect(find.textContaining('Jornada'), findsNothing);
      await _showCard(tester);
      expect(
        _inCard(find.byKey(const ValueKey('match-info-stage'))),
        findsOneWidget,
      );
      expect(_inCard(find.text('Octavos de final')), findsOneWidget);
      expect(_inCard(find.text('Ronda')), findsOneWidget);
      expect(_inCard(find.text('Jesus Gil Manzano')), findsOneWidget);
      expect(_inCard(find.text('Spain')), findsOneWidget);
      await _close(tester);
    });

    testWidgets('no phase tile when the stage is absent or a placeholder', (
      tester,
    ) async {
      await _open(tester, detail: _detail(stage: 'Current'));
      await _showCard(tester);
      expect(
        _inCard(find.byKey(const ValueKey('match-info-stage'))),
        findsNothing,
      );
      expect(_inCard(find.text('Current')), findsNothing);
      expect(_inCard(find.text('Fase')), findsNothing);
      await _close(tester);
    });

    testWidgets('venue falls back to the match venue when detail has none', (
      tester,
    ) async {
      await _open(
        tester,
        snapshot: _snapshot(venue: 'Estadio Calendario'),
        detail: _detail(stadium: null),
      );
      await _showCard(tester);
      expect(_inCard(find.text('Estadio Calendario')), findsOneWidget);
      await _close(tester);
    });

    for (final width in [360.0, 390.0, 430.0]) {
      testWidgets('8/9/10. ${width.toInt()} px with very long names: no '
          'overflow', (tester) async {
        await _open(
          tester,
          width: width,
          snapshot: _snapshot(competition: _longCompetition),
          detail: _detail(
            round: 'Cuartos de final - Vuelta',
            stadium: _longVenue,
            referee: _longReferee,
          ),
        );
        await _showCard(tester);
        expect(_card, findsOneWidget);
        expect(tester.takeException(), isNull);
        await _close(tester);
      });
    }
  });
}

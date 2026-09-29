import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:go_router/go_router.dart';

class _Repository implements FootballRepository {
  _Repository(this.snapshot);
  final Snapshot snapshot;
  @override
  Future<Snapshot> load() async => snapshot;

  @override
  Future<Snapshot> loadDate(DateTime date) async => snapshot;

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

const _longHome = 'Club Deportivo Universitario Metropolitano de Occidente';
const _longAway = 'Asociación Deportiva Atlética Internacional Fronteriza';

Snapshot _snapshot() {
  final today = costaRicaNow();
  String startAt(int hour) => DateTime.utc(
    today.year,
    today.month,
    today.day,
    hour + 6,
  ).toIso8601String();
  Map<String, dynamic> match(
    String id,
    String comp,
    String home,
    String away,
    String status,
    int hour, {
    Map<String, dynamic>? score,
    int? minute,
    Map<String, dynamic>? latestEvent,
    bool played = false,
  }) => {
    'id': id,
    'competitionId': comp,
    'homeTeamId': home,
    'awayTeamId': away,
    'startTime': startAt(hour),
    'status': status,
    'minute': minute,
    'score': score,
    'latestEvent': ?latestEvent,
    if (played) 'hasPlayedEvidence': true,
    'events': <dynamic>[],
    'statistics': <dynamic>[],
  };

  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'coverage': {'partial': false},
    'freshness': {'stale': false},
    'competitions': [
      {
        'id': 'c_cr',
        'name': 'Liga Promerica',
        'country': 'Costa Rica',
        'countryCode': 'CR',
        'relevanceScore': 660,
        'competitionClass': 'domestic_league',
        'domesticTier': 1,
        'isPrimaryDomestic': true,
      },
      {
        'id': 'c_es',
        'name': 'LaLiga',
        'country': 'Spain',
        'countryCode': 'ES',
        'relevanceScore': 920,
        'isGlobalRelevant': true,
      },
    ],
    'teams': [
      {'id': 't_sap', 'name': 'Saprissa', 'country': 'Costa Rica'},
      {'id': 't_lda', 'name': 'Alajuelense', 'country': 'Costa Rica'},
      {'id': 't_her', 'name': 'Herediano', 'country': 'Costa Rica'},
      {'id': 't_car', 'name': 'Cartaginés', 'country': 'Costa Rica'},
      {'id': 't_bet', 'name': 'Real Betis', 'country': 'Spain'},
      {'id': 't_get', 'name': 'Getafe', 'country': 'Spain'},
      {'id': 't_long1', 'name': _longHome, 'country': 'Spain'},
      {'id': 't_long2', 'name': _longAway, 'country': 'Spain'},
    ],
    'players': <dynamic>[],
    'matches': [
      match(
        'm_cr_live',
        'c_cr',
        't_sap',
        't_lda',
        'LIVE',
        12,
        minute: 63,
        score: {'home': 1, 'away': 0},
        latestEvent: {'type': 'GOAL', 'minute': 64},
      ),
      match('m_cr_next', 'c_cr', 't_her', 't_car', 'SCHEDULED', 23),
      match('m_es_1', 'c_es', 't_bet', 't_get', 'SCHEDULED', 23),
      match(
        'm_es_long',
        'c_es',
        't_long1',
        't_long2',
        'LIVE',
        12,
        minute: 88,
        score: {'home': 12, 'away': 10},
        latestEvent: {'type': 'SUBSTITUTION', 'minute': 88},
      ),
      match('m_es_awaiting', 'c_es', 't_get', 't_bet', 'SCHEDULED', 0),
      match(
        'm_es_partial',
        'c_es',
        't_bet',
        't_long2',
        'SCHEDULED',
        0,
        score: {'home': 2, 'away': 1},
        played: true,
      ),
    ],
    'standings': <dynamic>[],
  });
}

Future<List<String>> _pump(
  WidgetTester tester, {
  Set<String> follows = const {},
  Size size = const Size(390, 3000),
  Snapshot? data,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final opened = <String>[];
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const MatchesScreen()),
      GoRoute(
        path: '/match/:id',
        builder: (_, state) {
          opened.add(state.pathParameters['id']!);
          return const Scaffold(body: Text('detalle'));
        },
      ),
      GoRoute(
        path: '/competition/:id',
        builder: (_, state) {
          opened.add('competition:${state.pathParameters['id']}');
          return const Scaffold(body: Text('competición'));
        },
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(_Repository(data ?? _snapshot())),
        liveMatchUpdatesProvider.overrideWith(
          (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
        ),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
        followsProvider.overrideWith((ref) => Stream.value(follows)),
        temporaryInterestsProvider.overrideWith(
          (ref) => Stream.value(<String>{}),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Finder _row(String matchId) =>
    find.byWidgetPredicate((w) => w is FeedMatchRow && w.match.id == matchId);

void main() {
  testWidgets('every match of the day is a row, once, without follows', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(FeedMatchRow), findsNWidgets(6));
    for (final id in [
      'm_cr_live',
      'm_cr_next',
      'm_es_1',
      'm_es_long',
      'm_es_awaiting',
      'm_es_partial',
    ]) {
      expect(_row(id), findsOneWidget, reason: id);
    }
    expect(find.text('Siguiendo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follows reorder without removing or duplicating', (
    tester,
  ) async {
    await _pump(tester, follows: {'team:t_bet'});
    expect(find.text('Siguiendo'), findsOneWidget);
    // Same total, followed matches appear once.
    expect(find.byType(FeedMatchRow), findsNWidgets(6));
    expect(_row('m_es_1'), findsOneWidget);
    expect(_row('m_es_partial'), findsOneWidget);
    expect(_row('m_es_awaiting'), findsOneWidget);
    // Followed rows sit above the first competition header.
    final followedY = tester.getTopLeft(_row('m_es_1')).dy;
    expect(
      followedY,
      lessThan(tester.getTopLeft(find.text('Liga Promerica')).dy),
    );
    // The unfollowed match of LaLiga stays under its competition.
    expect(_row('m_es_long'), findsOneWidget);
    // LaLiga keeps only its unfollowed match under the header.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('competition-count-c_es')))
          .data,
      '1',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse keeps header and count, expand restores rows', (
    tester,
  ) async {
    await _pump(tester);
    final count = find.byKey(const ValueKey('competition-count-c_cr'));
    expect(tester.widget<Text>(count).data, '2');
    expect(_row('m_cr_live'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('competition-toggle-c_cr')));
    await tester.pumpAndSettle();
    expect(_row('m_cr_live'), findsNothing);
    expect(_row('m_cr_next'), findsNothing);
    expect(find.text('Liga Promerica'), findsOneWidget);
    expect(tester.widget<Text>(count).data, '2');
    // Other competitions untouched.
    expect(_row('m_es_1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('competition-toggle-c_cr')));
    await tester.pumpAndSettle();
    expect(_row('m_cr_live'), findsOneWidget);
    expect(_row('m_cr_next'), findsOneWidget);
    expect(tester.widget<Text>(count).data, '2');
  });

  testWidgets('tapping the competition name opens it, chevron does not', (
    tester,
  ) async {
    final opened = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('competition-toggle-c_cr')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('competition-open-c_cr')));
    await tester.pumpAndSettle();
    expect(opened, ['competition:c_cr']);
  });

  testWidgets('live row shows minute, status and latest event', (tester) async {
    await _pump(tester);
    final live = _row('m_cr_live');
    expect(
      find.descendant(of: live, matching: find.text("63′ · En vivo")),
      findsOneWidget,
    );
    expect(
      find.descendant(of: live, matching: find.text('1 - 0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: live, matching: find.text('Último: 64′ · Gol')),
      findsOneWidget,
    );
  });

  // Kickoffs of the awaiting fixtures are 00:00 CR; the "past kickoff by more
  // than 15 minutes" precondition cannot hold in the first minutes of the day.
  final nearMidnight = costaRicaNow().hour == 0 && costaRicaNow().minute < 20;

  testWidgets(
    'awaiting matches show Por confirmar, never an upcoming kickoff',
    (tester) async {
      final data = _snapshot();
      final awaiting = data.matches.firstWhere((m) => m.id == 'm_es_awaiting');
      final partial = data.matches.firstWhere((m) => m.id == 'm_es_partial');
      expect(awaiting.isAwaitingUpdate, isTrue);
      expect(partial.showKickoff, isFalse);

      await _pump(tester, data: data);
      // Played evidence past kickoff: score + "Marcador parcial", no kickoff.
      final p = _row('m_es_partial');
      expect(
        find.descendant(of: p, matching: find.text('2 - 1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: p, matching: find.text('Marcador parcial')),
        findsOneWidget,
      );
      // No evidence: dash + "Por confirmar", no kickoff time, no "Programado".
      final a = _row('m_es_awaiting');
      expect(
        find.descendant(of: a, matching: find.text('Por confirmar')),
        findsOneWidget,
      );
      expect(find.descendant(of: a, matching: find.text('—')), findsOneWidget);
      expect(
        find.descendant(of: a, matching: find.text('Programado')),
        findsNothing,
      );
      final kickoff = MaterialLocalizations.of(tester.element(a))
          .formatTimeOfDay(TimeOfDay.fromDateTime(awaiting.startTime));
      expect(
        find.descendant(of: a, matching: find.text(kickoff)),
        findsNothing,
      );
    },
    skip: nearMidnight,
  );

  testWidgets('a directly followed match (match:<id>) is lifted once', (
    tester,
  ) async {
    await _pump(tester, follows: {'match:m_es_1'});
    expect(find.text('Siguiendo'), findsOneWidget);
    expect(find.byType(FeedMatchRow), findsNWidgets(6));
    expect(_row('m_es_1'), findsOneWidget);
    expect(
      tester.getTopLeft(_row('m_es_1')).dy,
      lessThan(tester.getTopLeft(find.text('Liga Promerica')).dy),
    );
    // LaLiga keeps its other three matches under its header.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('competition-count-c_es')))
          .data,
      '3',
    );
  });

  testWidgets(
    'collapsed header shows live marker; live filter ignores collapse',
    (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('competition-live-c_cr')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('competition-toggle-c_cr')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('competition-live-c_cr')))
            .data,
        '1 en vivo',
      );
      expect(_row('m_cr_live'), findsNothing);
      await tester.tap(find.text('En vivo'));
      await tester.pumpAndSettle();
      expect(_row('m_cr_live'), findsOneWidget);
      expect(find.byKey(const ValueKey('competition-live-c_cr')), findsNothing);
      // No toggle under the live filter, and collapse survives leaving it.
      expect(
        find.byKey(const ValueKey('competition-toggle-c_cr')),
        findsNothing,
      );
      await tester.tap(find.text('Todos'));
      await tester.pumpAndSettle();
      expect(_row('m_cr_live'), findsNothing);
      expect(
        find.byKey(const ValueKey('competition-live-c_cr')),
        findsOneWidget,
      );
    },
  );

  testWidgets('changing the date clears collapsed competitions', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('competition-toggle-c_cr')));
    await tester.pumpAndSettle();
    expect(_row('m_cr_live'), findsNothing);
    // Next day and back to today.
    await tester.fling(
      find.byKey(const ValueKey('matches-date-swipe')),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    await tester.fling(
      find.byKey(const ValueKey('matches-date-swipe')),
      const Offset(300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(_row('m_cr_live'), findsOneWidget);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('no overflow with long names at ${width.toInt()} px', (
      tester,
    ) async {
      await _pump(tester, size: Size(width, 3000), follows: {'team:t_long1'});
      expect(find.byType(FeedMatchRow), findsNWidgets(6));
      expect(tester.takeException(), isNull);
      for (final row in tester.widgetList<FeedMatchRow>(
        find.byType(FeedMatchRow),
      )) {
        final size = tester.getSize(_row(row.match.id));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, lessThanOrEqualTo(width));
      }
    });
  }

  testWidgets('large text does not overflow at 320 px', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 4000), follows: {'team:t_long1'});
    expect(tester.takeException(), isNull);
    for (final row in tester.widgetList<FeedMatchRow>(
      find.byType(FeedMatchRow),
    )) {
      expect(
        tester.getSize(_row(row.match.id)).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(find.text('Saprissa'), findsOneWidget);
    expect(find.text('Alajuelense'), findsOneWidget);
  });

  testWidgets('tapping a row opens /match/<id>', (tester) async {
    final opened = await _pump(tester);
    await tester.tap(_row('m_es_1'));
    await tester.pumpAndSettle();
    expect(opened, ['m_es_1']);
  });

  testWidgets('toggle exposes expanded state and rows have full labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, follows: {'team:t_sap'});
    final toggle = find.byKey(const ValueKey('competition-toggle-c_es'));
    expect(
      tester.getSemantics(toggle),
      matchesSemantics(
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
        hasExpandedState: true,
        isExpanded: true,
        label: 'Ocultar partidos de LaLiga',
      ),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(toggle),
      matchesSemantics(
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
        hasExpandedState: true,
        isExpanded: false,
        label: 'Mostrar partidos de LaLiga',
      ),
    );
    final live = tester.getSemantics(_row('m_cr_live'));
    expect(live.label, contains('Saprissa contra Alajuelense'));
    expect(live.label, contains('Liga Promerica'));
    expect(live.label, contains('Último: 64′ · Gol'));
    handle.dispose();
  });
}

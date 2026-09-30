import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:go_router/go_router.dart';

/// The app database with follows kept in memory: FollowButton ->
/// database.toggle -> followsProvider, the app's own path, without file I/O.
class _FollowsDb extends AppDatabase {
  _FollowsDb() : super(NativeDatabase.memory());
  final _set = <String>{};
  final changes = StreamController<Set<String>>.broadcast();
  final toggles = <String>[];

  @override
  Future<void> toggle(String type, String id) async {
    final key = '$type:$id';
    toggles.add(key);
    if (!_set.remove(key)) _set.add(key);
    changes.add({..._set});
  }

  @override
  Stream<Set<String>> watchFollows() async* {
    yield {..._set};
    yield* changes.stream;
  }
}

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
  AppDatabase? db,
  String? country,
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
            CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: country,
              bootstrapDismissed: true,
            ),
          ),
        ),
        // A real (in-memory) database: follows go through the app's own
        // mechanism; otherwise a fixed set.
        if (db != null) ...[
          databaseProvider.overrideWithValue(db),
          followsProvider.overrideWith((ref) => db.watchFollows()),
        ] else
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

Finder _row(String matchId) => find.byKey(ValueKey('match-card-$matchId'));

void main() {
  testWidgets('every match of the day is a row, once, without follows', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(MatchCard), findsNWidgets(6));
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
    expect(find.text('FAVORITOS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row star follows / unfollows the match without moving it '
      '(only favourite teams make "Favoritos"); the row tap still opens the '
      'match', (tester) async {
    final db = _FollowsDb();
    addTearDown(db.changes.close);
    final opened = await _pump(tester, db: db);
    final star = find.byKey(const ValueKey('feed-follow-m_es_long'));
    String tooltip() => tester
        .widget<IconButton>(
          find.descendant(of: star, matching: find.byType(IconButton)),
        )
        .tooltip!;
    expect(tooltip(), startsWith('Seguir '));
    expect(find.text('FAVORITOS'), findsNothing);
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'the star never opens the match');
    expect(db.toggles, ['match:m_es_long']);
    expect(find.text('FAVORITOS'), findsNothing);
    expect(find.byType(MatchCard), findsNWidgets(6), reason: 'reorders only');
    expect(_row('m_es_long'), findsOneWidget, reason: 'never duplicated');
    // Still under its own competition.
    expect(
      tester.getTopLeft(_row('m_es_long')).dy,
      greaterThan(tester.getTopLeft(find.text('LaLiga')).dy),
    );
    expect(tooltip(), startsWith('Dejar de seguir '));
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(find.text('FAVORITOS'), findsNothing);
    expect(find.byType(MatchCard), findsNWidgets(6));
    await tester.tap(find.text(_longHome).first);
    await tester.pumpAndSettle();
    expect(opened, ['m_es_long']);
  });

  testWidgets('row and star are separate accessible actions', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    final row = tester.getSemantics(
      find.byKey(const ValueKey('match-card-action-m_es_1')),
    );
    expect(row.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(row.label, isNot(contains('Seguir')));
    final star = tester.getSemantics(
      find.descendant(
        of: find.byKey(const ValueKey('feed-follow-m_es_1')),
        matching: find.byType(IconButton),
      ),
    );
    expect(star.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(star.tooltip, contains('contra'));
    handle.dispose();
  });

  testWidgets('follows reorder without removing or duplicating', (
    tester,
  ) async {
    await _pump(tester, follows: {'team:t_bet'});
    expect(find.text('FAVORITOS'), findsOneWidget);
    // Same total, followed matches appear once.
    expect(find.byType(MatchCard), findsNWidgets(6));
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
      find.descendant(of: live, matching: find.text("63′ · EN VIVO")),
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
    'awaiting matches show POR CONFIRMAR, never an upcoming kickoff',
    (tester) async {
      final data = _snapshot();
      final awaiting = data.matches.firstWhere((m) => m.id == 'm_es_awaiting');
      final partial = data.matches.firstWhere((m) => m.id == 'm_es_partial');
      expect(awaiting.isAwaitingUpdate, isTrue);
      expect(partial.showKickoff, isFalse);

      await _pump(tester, data: data);
      // Played evidence past kickoff: score + "MARCADOR PARCIAL", no kickoff.
      final p = _row('m_es_partial');
      expect(
        find.descendant(of: p, matching: find.text('2 - 1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: p, matching: find.text('MARCADOR PARCIAL')),
        findsOneWidget,
      );
      // No evidence: dash + "POR CONFIRMAR", no kickoff time, no "Programado".
      final a = _row('m_es_awaiting');
      expect(
        find.descendant(of: a, matching: find.text('POR CONFIRMAR')),
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

  testWidgets('a directly followed match (match:<id>) or league never makes '
      '"Favoritos": it stays in its competition, once', (tester) async {
    await _pump(tester, follows: {'match:m_es_1', 'competition:c_es'});
    expect(find.text('FAVORITOS'), findsNothing);
    expect(find.byType(MatchCard), findsNWidgets(6));
    expect(_row('m_es_1'), findsOneWidget);
    expect(
      tester.getTopLeft(_row('m_es_1')).dy,
      greaterThan(tester.getTopLeft(find.text('LaLiga')).dy),
    );
    // LaLiga keeps all its four matches under its header.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('competition-count-c_es')))
          .data,
      '4',
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
      expect(find.byType(MatchCard), findsNWidgets(6));
      expect(tester.takeException(), isNull);
      for (final row in tester.widgetList<MatchCard>(find.byType(MatchCard))) {
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
    for (final row in tester.widgetList<MatchCard>(find.byType(MatchCard))) {
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
    final live = tester.getSemantics(
      find.byKey(const ValueKey('match-card-action-m_cr_live')),
    );
    expect(live.label, contains('Saprissa contra Alajuelense'));
    expect(live.label, contains('1 - 0'));
    handle.dispose();
  });

  testWidgets('very long team names never stretch a card beyond three lines', (
    tester,
  ) async {
    await _pump(tester);
    final long = tester.getSize(_row('m_es_long')).height;
    final normal = tester.getSize(_row('m_cr_live')).height;
    // Same card layout (both live with a latest event): at most two extra
    // text lines, never the seven a 55-character name used to take.
    expect(long - normal, lessThan(60));
    final name = tester.widget<Text>(
      find.descendant(of: _row('m_es_long'), matching: find.text(_longHome)),
    );
    expect(name.maxLines, 3);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('day swipe: the list slides in (no duplicate list, nothing '
      'rebuilt under a new key) and settles in place', (tester) async {
    await _pump(tester);
    final swipe = find.byKey(const ValueKey('matches-date-swipe'));
    final list = find.descendant(
      of: swipe,
      matching: find.byType(CustomScrollView),
    );
    final before = tester.element(list);
    final restX = tester.getTopLeft(list).dx;

    await tester.fling(swipe, const Offset(-300, 0), 1200);
    await tester.pump(); // day changed, transition starts
    await tester.pump(const Duration(milliseconds: 60));
    expect(list, findsOneWidget, reason: 'one list during the transition');
    expect(
      tester.getTopLeft(list).dx,
      greaterThan(restX),
      reason: 'the next day comes in from the right',
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(list).dx, restX);
    expect(identical(tester.element(list), before), isTrue);

    await tester.fling(swipe, const Offset(300, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.getTopLeft(list).dx,
      lessThan(restX),
      reason: 'the previous day comes in from the left',
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(list).dx, restX);
    // Back on today: the same matches, once.
    expect(find.byType(MatchCard), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });

  // --- The selected country reorders, never hides -------------------------

  for (final (country, first, second) in [
    ('CR', 'Liga Promerica', 'LaLiga'),
    ('ES', 'LaLiga', 'Liga Promerica'),
    ('GB-ENG', 'LaLiga', 'Liga Promerica'),
  ]) {
    testWidgets('country $country: $first before $second, same matches once', (
      tester,
    ) async {
      await _pump(tester, country: country);
      expect(
        tester.getTopLeft(find.text(first)).dy,
        lessThan(tester.getTopLeft(find.text(second)).dy),
      );
      // Reordered only: every match of the day, exactly once.
      expect(find.byType(MatchCard), findsNWidgets(6));
      for (final id in [
        'm_cr_live',
        'm_cr_next',
        'm_es_1',
        'm_es_long',
        'm_es_awaiting',
        'm_es_partial',
      ]) {
        expect(_row(id), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('country $country: FAVORITOS stays on top and its matches '
        'are not repeated', (tester) async {
      await _pump(tester, country: country, follows: {'team:t_bet'});
      final favourites = tester.getTopLeft(find.text('FAVORITOS')).dy;
      expect(favourites, lessThan(tester.getTopLeft(find.text(first)).dy));
      expect(favourites, lessThan(tester.getTopLeft(find.text(second)).dy));
      expect(find.byType(MatchCard), findsNWidgets(6));
      for (final id in ['m_es_1', 'm_es_awaiting', 'm_es_partial']) {
        expect(_row(id), findsOneWidget);
        expect(
          tester.getTopLeft(_row(id)).dy,
          lessThan(tester.getTopLeft(find.text(first)).dy),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a followed league stays above the primary of the selected '
      'country', (tester) async {
    await _pump(tester, country: 'CR', follows: {'competition:c_es'});
    expect(find.text('FAVORITOS'), findsNothing);
    expect(
      tester.getTopLeft(find.text('LaLiga')).dy,
      lessThan(tester.getTopLeft(find.text('Liga Promerica')).dy),
    );
    expect(find.byType(MatchCard), findsNWidgets(6));
  });

  // --- One canonical fixture, exactly once -------------------------------

  test('dedupeFixtures: evidence levels, canonical identity only', () {
    List<String> ids(List<FootballMatch> list) =>
        dedupeFixtures(list).map((m) => m.id).toList();
    const final21 = {'home': 2, 'away': 1};
    // Same canonical id twice.
    expect(ids([_fixture('a', 'h', 'x'), _fixture('a', 'h', 'x')]), ['a']);
    // Same competition, teams and kickoff: one fixture. The finished twin
    // replaces the scheduled copy in place; the others keep their order.
    expect(
      ids([
        _fixture('z_first', 'q', 'r'),
        _fixture('sched', 'h', 'x'),
        _fixture('done', 'h', 'x', status: 'VERIFIED', score: final21),
        _fixture('z_last', 's', 't'),
      ]),
      ['z_first', 'done', 'z_last'],
    );
    // Live beats played evidence beats scheduled beats postponed.
    expect(
      ids([
        _fixture('p', 'h', 'x', status: 'POSTPONED'),
        _fixture('s', 'h', 'x'),
        _fixture('e', 'h', 'x', played: true),
        _fixture('l', 'h', 'x', status: 'LIVE'),
      ]),
      ['l'],
    );
    // Equal twins: deterministic (lower id), whatever the input order.
    expect(ids([_fixture('b', 'h', 'x'), _fixture('a', 'h', 'x')]), ['a']);
    expect(ids([_fixture('a', 'h', 'x'), _fixture('b', 'h', 'x')]), ['a']);
    // Kickoff corrected by up to 3 hours while at most one has evidence.
    expect(
      ids([_fixture('a', 'h', 'x'), _fixture('b', 'h', 'x', minute: 30)]),
      ['a'],
    );
    expect(
      ids([
        _fixture('ghost', 'h', 'x', hour: 20),
        _fixture('live', 'h', 'x', status: 'LIVE'),
      ]),
      ['live'],
    );
    // Both really played two hours apart (double-header): two games.
    expect(
      ids([
        _fixture('g1', 'h', 'x', status: 'VERIFIED', score: final21),
        _fixture('g2', 'h', 'x', status: 'VERIFIED', score: final21, hour: 20),
      ]),
      ['g1', 'g2'],
    );
    // A scheduled ghost 18 hours from its played twin is hidden; two
    // scheduled entities that far apart are two matches.
    expect(
      ids([
        _fixture('old', 'h', 'x', hour: 0),
        _fixture('real', 'h', 'x', status: 'VERIFIED', score: final21),
      ]),
      ['real'],
    );
    expect(ids([_fixture('a', 'h', 'x', hour: 0), _fixture('b', 'h', 'x')]), [
      'a',
      'b',
    ]);
    // Another competition (other squad of the same clubs, a friendly):
    // never merged, even at the same kickoff.
    expect(
      ids([_fixture('a', 'h', 'x'), _fixture('b', 'h', 'x', comp: 'other')]),
      ['a', 'b'],
    );
    // Two finished matches with different final scores are two games; the
    // same result twice at the same kickoff is one.
    expect(
      ids([
        _fixture('x', 'h', 'x', status: 'VERIFIED', score: final21),
        _fixture(
          'y',
          'h',
          'x',
          status: 'VERIFIED',
          score: {'home': 0, 'away': 3},
        ),
        _fixture('z', 'h', 'x', status: 'VERIFIED', score: final21),
      ]),
      ['x', 'y'],
    );
    // Return leg, another opponent and a team "against itself" stay apart.
    expect(
      ids([
        _fixture('a', 'h', 'x'),
        _fixture('rev', 'x', 'h'),
        _fixture('other', 'h', 'y'),
        _fixture('self1', 'h', 'h'),
        _fixture('self2', 'h', 'h'),
      ]),
      ['a', 'rev', 'other', 'self1', 'self2'],
    );
  });

  testWidgets('a fixture stored as two match entities renders exactly once', (
    tester,
  ) async {
    final data = _withMatches([
      // Same real match as m_es_1 (same competition and kickoff), finished.
      _twinOf(
        'm_es_1',
        twinId: 'm_es_1_twin',
        status: 'VERIFIED',
        score: {'home': 2, 'away': 1},
      ),
      // Same real match as m_cr_next, kickoff 20 minutes apart.
      _twinOf(
        'm_cr_next',
        twinId: 'm_cr_next_twin',
        shift: const Duration(minutes: 20),
      ),
    ]);
    await _pump(tester, data: data);
    expect(find.byType(MatchCard), findsNWidgets(6));
    expect(_row('m_es_1'), findsNothing);
    expect(_row('m_es_1_twin'), findsOneWidget);
    expect(
      _row('m_cr_next').evaluate().length +
          _row('m_cr_next_twin').evaluate().length,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same clubs in ANOTHER competition at the same time are two '
      'matches', (tester) async {
    final data = _withMatches([
      _twinOf('m_es_1', twinId: 'm_es_1_other', competitionId: 'c_cr'),
    ]);
    await _pump(tester, data: data);
    expect(find.byType(MatchCard), findsNWidgets(7));
    expect(_row('m_es_1'), findsOneWidget);
    expect(_row('m_es_1_other'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FAVORITOS: a followed league or match never creates the group', (
    tester,
  ) async {
    final data = _withMatches([_twinOf('m_es_1', twinId: 'm_es_1_twin')]);
    // A followed league and a followed match never create the group.
    await _pump(
      tester,
      data: data,
      follows: {'competition:c_es', 'match:m_cr_next'},
    );
    expect(find.text('FAVORITOS'), findsNothing);
    expect(find.byType(MatchCard), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('FAVORITOS: favourite-team matches first, once, nothing hidden '
      '(even with a duplicated entity)', (tester) async {
    final data = _withMatches([_twinOf('m_es_1', twinId: 'm_es_1_twin')]);
    await _pump(
      tester,
      data: data,
      follows: {'team:t_bet', 'competition:c_cr'},
    );
    expect(find.text('FAVORITOS'), findsOneWidget);
    expect(find.byType(MatchCard), findsNWidgets(6), reason: 'nothing hidden');
    // The favourite team's fixture appears once (one of the two entities).
    expect(
      _row('m_es_1').evaluate().length + _row('m_es_1_twin').evaluate().length,
      1,
    );
    final favouritesY = tester.getTopLeft(find.text('FAVORITOS')).dy;
    final firstCompetitionY = tester.getTopLeft(find.text('Liga Promerica')).dy;
    expect(favouritesY, lessThan(firstCompetitionY));
    // Every favourite-team match sits in the group, above every competition.
    for (final id in ['m_es_awaiting', 'm_es_partial']) {
      expect(tester.getTopLeft(_row(id)).dy, lessThan(firstCompetitionY));
    }
    // Matches of the followed LEAGUE without a favourite team stay below.
    expect(
      tester.getTopLeft(_row('m_cr_live')).dy,
      greaterThan(firstCompetitionY),
    );
    expect(tester.takeException(), isNull);
  });
}

/// [_snapshot] plus extra matches (same teams and competitions).
Snapshot _withMatches(List<Map<String, dynamic>> extra) {
  final base = _snapshot();
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'coverage': {'partial': false},
    'freshness': {'stale': false},
    'competitions': base.competitions.map((e) => e.json).toList(),
    'teams': base.teams.map((e) => e.json).toList(),
    'players': <dynamic>[],
    'matches': [...base.matches.map((m) => m.json), ...extra],
    'standings': <dynamic>[],
  });
}

/// A second match entity of the same real fixture as [id] in [_snapshot].
Map<String, dynamic> _twinOf(
  String id, {
  required String twinId,
  String? competitionId,
  String? status,
  Map<String, dynamic>? score,
  Duration shift = Duration.zero,
}) {
  final source = _snapshot().matches.firstWhere((m) => m.id == id).json;
  return {
    ...source,
    'id': twinId,
    'competitionId': competitionId ?? source['competitionId'],
    'status': status ?? source['status'],
    'score': score ?? source['score'],
    'startTime': DateTime.parse(source['startTime'] as String)
        .add(shift)
        .toIso8601String(),
  };
}

FootballMatch _fixture(
  String id,
  String home,
  String away, {
  String status = 'SCHEDULED',
  int hour = 18,
  int minute = 0,
  bool played = false,
  Map<String, int>? score,
  String comp = 'c',
}) => FootballMatch({
  'id': id,
  'competitionId': comp,
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': DateTime.utc(2026, 9, 20, hour, minute).toIso8601String(),
  'status': status,
  'score': score,
  if (played) 'hasPlayedEvidence': true,
  'events': <dynamic>[],
  'statistics': <dynamic>[],
});

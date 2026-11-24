import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/team_matches.dart';
import 'package:futbeat/features/entities/team_matches_tab.dart';

import 'mobile259_team_retarget_test.dart' show page;

class PendingPages extends ApiRepository {
  PendingPages(this.state, {this.history = false, this.hasMore = false})
    : super(Dio());
  final String state;
  final bool history;
  final bool hasMore;
  final calls = <String>[];
  Completer<TeamMatchesPage>? refresh;
  List<TeamMatchesPage>? resultPages;

  @override
  Future<TeamMatchesPage> loadTeamMatches(
    String id,
    String bucket, {
    String? cursor,
    int limit = teamMatchesPageSize,
    String? competitionId,
    String? season,
  }) async {
    calls.add('$bucket:${cursor ?? "first"}');
    if (bucket == 'results' && resultPages != null) {
      return resultPages!.removeAt(0);
    }
    if (bucket == 'results' && refresh != null) return refresh!.future;
    return TeamMatchesPage({
      ...page(id, results: false),
      'hasMore': hasMore && bucket == 'results',
      'nextCursor': hasMore && bucket == 'results' ? 'next' : null,
      'coverage': {
        'teamMatches': {
          'state': state,
          if (history && bucket == 'results') 'history': 'requested',
        },
      },
    });
  }
}

Future<void> open(WidgetTester tester, PendingPages api) async {
  final data = Snapshot(page('fb_team_a'));
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(api)],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverOverlapAbsorber(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
                sliver: const SliverToBoxAdapter(child: SizedBox(height: 1)),
              ),
            ],
            body: TeamMatchesTab(
              team: data.team('fb_team_a')!,
              data: data,
              matches: data.matches,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final finalState in ['NO_DATA', 'AVAILABLE']) {
    testWidgets(
      'R4 pending refresh keeps remote-only fixtures until $finalState',
      (tester) async {
        Json remote(int goals, String state) {
          final p = page('fb_team_a');
          final teams = p['teams'] as List;
          teams[1] = {'id': 'fb_remote_rival', 'name': 'Rival Remoto'};
          final match = (p['matches'] as List).single as Map;
          match['id'] = 'fb_match_remote';
          match['awayTeamId'] = 'fb_remote_rival';
          match['score'] = {'home': goals, 'away': 0};
          p['coverage'] = {
            'teamMatches': {'state': state},
          };
          return p;
        }

        TeamMatchesPage empty(String state) => TeamMatchesPage({
          ...page('fb_team_a', results: false),
          'coverage': {
            'teamMatches': {'state': state},
          },
        });
        final api = PendingPages('PENDING')
          ..resultPages = [
            TeamMatchesPage(remote(1, 'PENDING')),
            empty('PENDING'),
            finalState == 'NO_DATA'
                ? empty(finalState)
                : TeamMatchesPage(remote(3, finalState)),
          ];
        await open(tester, api);
        expect(find.text('Rival Remoto'), findsOneWidget);
        final button = find.byKey(
          const ValueKey('team-matches-refresh-results'),
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Rival Remoto'), findsOneWidget);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(
          find.text('Rival Remoto'),
          finalState == 'NO_DATA' ? findsNothing : findsOneWidget,
        );
        if (finalState == 'AVAILABLE') {
          expect(find.text('3 - 0'), findsOneWidget);
        }
        expect(find.text('Rival fb_team_a'), findsNothing);
      },
    );
  }
  testWidgets('R4 failed manual refresh retains fixtures and can retry', (
    tester,
  ) async {
    final api = PendingPages('PENDING');
    await open(tester, api);
    final button = find.byKey(const ValueKey('team-matches-refresh-results'));
    api.refresh = Completer<TeamMatchesPage>();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    api.refresh!.completeError(StateError('synthetic offline'));
    await tester.pumpAndSettle();
    expect(find.text('Rival fb_team_a'), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('Reintentar')),
      findsOneWidget,
    );
    api.refresh = Completer<TeamMatchesPage>();
    await tester.tap(button);
    await tester.pump();
    api.refresh!.complete(TeamMatchesPage(page('fb_team_a')));
    await tester.pumpAndSettle();
    expect(find.text('Rival fb_team_a'), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('R4 pending coverage preserves pagination as well as refresh', (
    tester,
  ) async {
    await open(tester, PendingPages('PENDING', hasMore: true));
    expect(
      find.byKey(const ValueKey('team-matches-more-results')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('team-matches-refresh-results')),
      findsOneWidget,
    );
  });
  for (final state in ['PENDING', 'STALE']) {
    testWidgets(
      'R4 $state page preserves known fixtures and manual refresh recovers',
      (tester) async {
        final api = PendingPages(state);
        await open(tester, api);
        expect(find.text('Rival fb_team_a'), findsOneWidget);
        expect(find.text('Cargando partidos'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pump(const Duration(minutes: 2));
        expect(api.calls, hasLength(3));
        api.refresh = Completer<TeamMatchesPage>();
        final button = find.byKey(
          const ValueKey('team-matches-refresh-results'),
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        expect(find.text('Rival fb_team_a'), findsOneWidget);
        expect(api.calls.where((c) => c.startsWith('results:')), [
          'results:first',
          'results:first',
        ]);
        final corrected = page('fb_team_a');
        (corrected['matches'] as List).single['score'] = {'home': 3, 'away': 0};
        api.refresh!.complete(TeamMatchesPage(corrected));
        await tester.pumpAndSettle();
        expect(find.text('3 - 0'), findsOneWidget);
        expect(button, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('R4 confirmed empty is authoritative over old profile fixtures', (
    tester,
  ) async {
    await open(tester, PendingPages('NO_DATA'));
    expect(find.text('Rival fb_team_a'), findsNothing);
    expect(find.text('Sin resultados'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('team-matches-refresh-results')),
      findsNothing,
    );
  });

  testWidgets(
    'R4 pending older history keeps known fixtures without indefinite loading',
    (tester) async {
      await open(tester, PendingPages('NO_DATA', history: true));
      expect(find.text('Rival fb_team_a'), findsOneWidget);
      expect(find.text('Cargando historial'), findsNothing);
      expect(
        find.byKey(const ValueKey('team-matches-refresh-results')),
        findsOneWidget,
      );
    },
  );
}

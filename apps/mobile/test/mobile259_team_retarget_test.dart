import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/team_matches.dart';
import 'package:futbeat/features/entities/team_matches_tab.dart';

Json page(String team, {bool results = true}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T20:00:00Z',
  'teams': [
    {'id': team, 'name': team},
    {'id': 'fb_rival_$team', 'name': 'Rival $team'},
  ],
  'competitions': [
    {'id': 'fb_comp_259', 'name': 'Liga controlada'},
  ],
  'players': <Json>[],
  'standings': <Json>[],
  'matches': results
      ? [
          {
            'id': 'fb_match_$team',
            'competitionId': 'fb_comp_259',
            'homeTeamId': team,
            'awayTeamId': 'fb_rival_$team',
            'startTime': '2026-10-01T20:00:00Z',
            'status': 'FINISHED',
            'score': {'home': 1, 'away': 0},
            'events': <Json>[],
            'statistics': <Json>[],
          },
        ]
      : <Json>[],
  'hasMore': false,
};

class _Pages extends ApiRepository {
  _Pages({this.holdFirst = false}) : super(Dio());
  final bool holdFirst;
  final oldAnswer = Completer<TeamMatchesPage>();
  final calls = <String>[];
  @override
  Future<TeamMatchesPage> loadTeamMatches(
    String id,
    String bucket, {
    String? cursor,
    int limit = teamMatchesPageSize,
    String? competitionId,
    String? season,
  }) async {
    calls.add('$id:$bucket');
    if (holdFirst && id == 'fb_team_a' && bucket == 'results') {
      return oldAnswer.future;
    }
    return TeamMatchesPage(page(id, results: bucket == 'results'));
  }
}

void main() {
  for (final held in [false, true]) {
    testWidgets(
      'team retarget discards ${held ? 'pending' : 'stored'} pages from previous identity',
      (tester) async {
        final api = _Pages(holdFirst: held);
        final container = ProviderContainer(
          overrides: [repositoryProvider.overrideWithValue(api)],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          container.dispose();
        });
        Future<void> open(String id) async {
          final data = Snapshot(page(id, results: false));
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
                        sliver: const SliverToBoxAdapter(
                          child: SizedBox(height: 1),
                        ),
                      ),
                    ],
                    body: TeamMatchesTab(
                      key: const ValueKey('same-route'),
                      team: data.team(id)!,
                      data: data,
                      matches: const [],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        }

        await open('fb_team_a');
        if (!held) expect(find.text('Rival fb_team_a'), findsOneWidget);
        await open('fb_team_b');
        if (held) {
          api.oldAnswer.complete(TeamMatchesPage(page('fb_team_a')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('Rival fb_team_a'), findsNothing);
        expect(find.text('Rival fb_team_b'), findsOneWidget);
        expect(
          api.calls.where((call) => call.startsWith('fb_team_b:')),
          hasLength(3),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

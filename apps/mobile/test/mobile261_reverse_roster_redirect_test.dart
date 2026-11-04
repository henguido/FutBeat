import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final scenario in [(false, false), (true, false), (false, true)]) {
    final (presentation, ambiguous) = scenario;
    testWidgets(
      'canonical timeline bridge respects explicit roster evidence $scenario',
      (tester) async {
        const alias = 'fb_player_alias261';
        const canonical = 'fb_player_canonical261';
        final data = Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': '2026-11-03T12:00:00Z',
          'teams': [
            {'id': 'fb_home261', 'name': 'Local'},
            {'id': 'fb_away261', 'name': 'Visita'},
          ],
          'competitions': [
            {'id': 'fb_comp261', 'name': 'Liga'},
          ],
          'players': [
            {'id': alias, 'name': 'Jugador de fixture'},
            {'id': canonical, 'name': 'Jugador de fixture'},
          ],
          'entityRedirects': {alias: canonical},
          'standings': [],
          if (presentation) '_futbeatDisplayRedirectIds': [alias],
          'matches': [
            {
              'id': 'fb_match261',
              'competitionId': 'fb_comp261',
              'homeTeamId': 'fb_home261',
              'awayTeamId': 'fb_away261',
              'startTime': '2026-11-03T10:00:00Z',
              'status': 'VERIFIED',
              'score': {'home': 1, 'away': 0},
              'events': [
                {
                  'id': 'fb_event261',
                  'type': 'GOAL',
                  'minute': 25,
                  'canonicalPlayerId': canonical,
                  'teamId': 'fb_home261',
                },
              ],
            },
          ],
        });
        final detail = MatchDetail({
          'matchId': 'fb_match261',
          'available': true,
          'home': {
            'starters': [
              {
                'id': 'provider9',
                'canonicalId': alias,
                'name': 'Jugador de fixture',
                'number': 9,
              },
            ],
          },
          'away': {
            'starters': [
              if (ambiguous)
                {
                  'id': 'provider12',
                  'canonicalId': canonical,
                  'name': 'Jugador de fixture',
                  'number': 12,
                },
            ],
          },
        });
        var routes = 0;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: MatchPlayerScope(
                  data: data,
                  detail: detail,
                  home: data.team('fb_home261')!,
                  away: data.team('fb_away261')!,
                  child: MatchTimeline(
                    data,
                    data.match('fb_match261')!,
                    detail,
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/player/:id',
              builder: (_, state) {
                routes++;
                return Scaffold(
                  body: Text('profile:${state.pathParameters['id']}'),
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Jugador de fixture'));
        await tester.pumpAndSettle();
        if (!presentation && !ambiguous) {
          expect(find.byKey(const ValueKey('player-sheet')), findsOneWidget);
          expect(routes, 0);
          await tester.tap(find.byKey(const ValueKey('player-sheet-profile')));
          await tester.pumpAndSettle();
          expect(find.text('profile:$canonical'), findsOneWidget);
          expect(routes, 1);
        } else {
          expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
          expect(find.text('profile:$canonical'), findsOneWidget);
          expect(routes, 1);
        }
      },
    );
  }
}

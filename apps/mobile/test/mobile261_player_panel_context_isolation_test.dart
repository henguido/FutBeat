import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'an open player panel keeps its original profile context after Match Center retarget',
    (tester) async {
      final fixture = jsonDecode(
        File('test/fixtures/match_detail_object_lineup.json')
            .readAsStringSync(),
      ) as Json;
      final detail = MatchDetail(fixture);
      final first = {...detail.homeStarters.last, 'image': null, 'media': null};
      final second = {
        ...detail.awayStarters.first,
        'image': null,
        'media': null,
      };
      final next = ValueNotifier(false);
      addTearDown(next.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => ValueListenableBuilder<bool>(
              valueListenable: next,
              builder: (_, moved, _) {
                final suffix = moved ? 'b' : 'a';
                return MatchPlayerScope(
                  detail: MatchDetail({
                    ...fixture,
                    'matchId': 'fb_match_fixture_$suffix',
                  }),
                  home: Entity({
                    'id': 'fb_home_$suffix',
                    'name': 'Local $suffix',
                  }),
                  away: Entity({
                    'id': 'fb_away_$suffix',
                    'name': 'Visita $suffix',
                  }),
                  child: Builder(
                    builder: (context) => Scaffold(
                      body: FilledButton(
                        key: const ValueKey('open-player-panel'),
                        onPressed: () => showMatchPlayerSheet(
                          context,
                          moved ? second : first,
                          moved ? 'away' : 'home',
                        ),
                        child: Text('Match Center $suffix'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          GoRoute(
            path: '/player/:id',
            builder: (_, state) {
              final context = state.extra! as PlayerProfileMatchContext;
              return Scaffold(
                body: Column(
                  children: [
                    Text('profile:${state.pathParameters['id']}'),
                    Text('team:${context.team!.id}'),
                  ],
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.byKey(const ValueKey('open-player-panel')));
      await tester.pumpAndSettle();
      next.value = true;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('player-sheet-name')))
            .data,
        first['name'],
      );
      await tester.tap(find.byKey(const ValueKey('player-sheet-profile')));
      await tester.pumpAndSettle();
      expect(find.text('profile:${first['canonicalId']}'), findsOneWidget);
      expect(find.text('team:fb_home_a'), findsOneWidget);
      expect(find.text('team:fb_away_b'), findsNothing);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Match Center b'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open-player-panel')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('player-sheet-name')))
            .data,
        second['name'],
      );
      await tester.tap(find.byKey(const ValueKey('player-sheet-profile')));
      await tester.pumpAndSettle();
      expect(find.text('profile:${second['canonicalId']}'), findsOneWidget);
      expect(find.text('team:fb_away_b'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/profile_context.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/competition_profile.dart';
import 'package:futbeat/features/entities/team_profile.dart';

import 'mobile259_team_retarget_test.dart' show page;

Snapshot profile(bool table) => Snapshot({
  ...page('fb_team_a', results: false),
  'standings': [
    if (table)
      {
        'competitionId': 'fb_comp_259',
        'rows': [
          {'teamId': 'fb_team_a', 'played': 1, 'points': 3},
        ],
      },
  ],
});

String selectedTab(WidgetTester tester) {
  final finder = find.byType(TabBar);
  final bar = tester.widget<TabBar>(finder);
  final controller =
      bar.controller ?? DefaultTabController.of(tester.element(finder));
  return (bar.tabs[controller.index] as Tab).text!;
}

void main() {
  for (final kind in ['team', 'competition']) {
    testWidgets(
      'R4 $kind keeps selected section when a table arrives or disappears',
      (tester) async {
        final value = ValueNotifier(profile(false));
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (o, h) => h.resolve(
                Response(
                  requestOptions: o,
                  data: page('fb_team_a', results: false),
                ),
              ),
            ),
          );
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            teamContextProvider.overrideWith((ref, request) async => null),
            followsProvider.overrideWith((ref) => Stream.value({})),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          value.dispose();
          container.dispose();
          dio.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: ValueListenableBuilder<Snapshot>(
                valueListenable: value,
                builder: (context, data, _) => kind == 'team'
                    ? TeamProfileView(
                        data: data,
                        team: data.teams.first,
                        competitions: data.competitions,
                        matches: data.matches,
                      )
                    : CompetitionProfileView(
                        data: data,
                        competition: data.competitions.single,
                        teams: data.teams,
                        matches: data.matches,
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Noticias').first);
        await tester.tap(find.text('Noticias').first);
        await tester.pumpAndSettle();
        expect(selectedTab(tester), 'Noticias');
        value.value = profile(true);
        await tester.pumpAndSettle();
        expect(find.text('Tabla'), findsOneWidget);
        expect(selectedTab(tester), 'Noticias');
        value.value = profile(false);
        await tester.pumpAndSettle();
        expect(selectedTab(tester), 'Noticias');
        value.value = profile(true);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Tabla').first);
        await tester.tap(find.text('Tabla').first);
        await tester.pumpAndSettle();
        value.value = profile(false);
        await tester.pumpAndSettle();
        expect(selectedTab(tester), 'Resumen');
        expect(tester.takeException(), isNull);
      },
    );
  }
}

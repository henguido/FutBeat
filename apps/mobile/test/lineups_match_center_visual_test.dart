import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('FutBeatRoboto')
      ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/roboto-bold.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('Visual review: complete Match Center lineups', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<Map<String, dynamic>> players(String prefix) => [
      for (var i = 1; i <= 11; i++)
        {
          'id': '${prefix}_$i',
          'canonicalId': 'fb_player_${prefix}_$i',
          'name': i == 7 ? 'Futbolista de Nombre Extenso' : 'Jugador $i',
          'number': i,
          'lineupPosition': i,
          'position': i == 1
              ? 'G'
              : i < 6
              ? 'D'
              : i < 9
              ? 'M'
              : 'F',
          if (i == 9) 'rating': 8.1,
        },
    ];
    final payload = {
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-10-27T20:00:00Z',
      'teams': [
        {'id': 'fb_home', 'name': 'Equipo Local'},
        {'id': 'fb_away', 'name': 'Equipo Visitante'},
      ],
      'players': <dynamic>[],
      'competitions': [
        {'id': 'fb_comp', 'name': 'Competici\u00f3n de prueba'},
      ],
      'matches': [
        {
          'id': 'fb_match',
          'competitionId': 'fb_comp',
          'homeTeamId': 'fb_home',
          'awayTeamId': 'fb_away',
          'startTime': '2026-10-27T20:00:00Z',
          'status': 'VERIFIED',
          'score': {'home': 1, 'away': 2},
          'events': <dynamic>[],
        },
      ],
      'standings': <dynamic>[],
    };
    final detail = MatchDetail({
      'matchId': 'fb_match',
      'available': true,
      'detailLevel': 'full',
      'home': {
        'formation': '4-3-3',
        'starters': players('home'),
        'substitutes': <dynamic>[],
        'coach': {'name': 'Entrenadora Local'},
      },
      'away': {
        'formation': '4-2-3-1',
        'starters': players('away'),
        'substitutes': <dynamic>[],
        'coach': {'name': 'Entrenador Visitante'},
      },
      'incidents': [
        {'type': 'GOAL', 'side': 'home', 'playerId': 'home_9', 'minute': 31},
        {
          'type': 'YELLOW_CARD',
          'side': 'away',
          'playerId': 'away_7',
          'minute': 56,
        },
      ],
      'statistics': <dynamic>[],
    });

    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async => db.customSelect('select 1').get());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(ApiRepository(Dio())),
        matchContextSnapshotProvider.overrideWith(
          (ref, id) => Stream.value(Snapshot(payload)),
        ),
        matchDetailProvider.overrideWith((ref, id) => Stream.value(detail)),
        followsProvider.overrideWith((ref) => Stream.value({})),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(db.close);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'FutBeatRoboto',
            ),
            primaryTextTheme: ThemeData.dark().primaryTextTheme.apply(
              fontFamily: 'FutBeatRoboto',
            ),
          ),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(bottom: 24),
              viewPadding: EdgeInsets.only(bottom: 24),
            ),
            child: Scaffold(
              body: MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
              bottomNavigationBar: SafeArea(
                top: false,
                child: NavigationBar(
                  selectedIndex: 1,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.sports_soccer_outlined),
                      label: 'Partidos',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.star_outline_rounded),
                      label: 'Favoritos',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search_rounded),
                      label: 'Explorar',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      label: 'Perfil',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('match-tab-lineup')));
    await tester.pumpAndSettle();

    final scroll = find.byKey(const PageStorageKey<String>('alineacion'));
    expect(scroll, findsOneWidget);
    final localCoach = find.byKey(const ValueKey('lineup-Local-coach'));
    expect(localCoach, findsOneWidget);
    expect(tester.getRect(localCoach).bottom, lessThan(740));
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/lineups_match_center_top.png'),
    );
    await tester.drag(scroll, const Offset(0, -520));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/lineups_match_center_home.png'),
    );
    await tester.drag(scroll, const Offset(0, -620));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/lineups_match_center_away.png'),
    );
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('lineup-Visitante-coach')),
      scroll,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    final awayCoach = find.byKey(const ValueKey('lineup-Visitante-coach'));
    expect(awayCoach, findsOneWidget);
    expect(tester.getRect(awayCoach).top, greaterThanOrEqualTo(0));
    expect(tester.getRect(awayCoach).bottom, lessThan(740));
    expect(find.text('DT · Entrenador Visitante'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: 'golden');
}

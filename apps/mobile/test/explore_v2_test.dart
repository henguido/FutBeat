import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

Map<String, dynamic> _payload({
  List<Map<String, dynamic>> competitions = const [],
  List<Map<String, dynamic>> teams = const [],
  List<Map<String, dynamic>> players = const [],
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-07T12:00:00Z',
  'competitions': competitions,
  'teams': teams,
  'players': players,
  'matches': <dynamic>[],
  'standings': <dynamic>[],
  'news': <dynamic>[],
  'transfers': <dynamic>[],
};

Snapshot _catalog() => Snapshot(
  _payload(
    competitions: [
      {'id': 'competition_cr', 'name': 'Primera División', 'country': 'CR'},
    ],
    teams: [
      {
        'id': 'team_sap',
        'name': 'Deportivo Saprissa',
        'country': 'CR',
        'competitionId': 'competition_cr',
      },
      {'id': 'team_lafc', 'name': 'Los Angeles FC', 'country': 'US'},
    ],
    players: [
      {
        'id': 'player_one',
        'name': 'Jugador con un nombre especialmente largo para probar diseño',
        'teamId': 'team_sap',
        'position': 'defender',
        'nationality': 'Costa Rica',
      },
    ],
  ),
);

Future<AppDatabase> _pump(
  WidgetTester tester, {
  required Snapshot discovery,
  Snapshot? search,
  Snapshot Function(String query)? searchFor,
  Set<String> follows = const {},
  String? focusType,
  List<Entity>? remotePlayers,
  bool liveFollows = false,
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final database = AppDatabase(NativeDatabase.memory());
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
        followsProvider.overrideWith(
          (ref) =>
              liveFollows ? database.watchFollows() : Stream.value(follows),
        ),
        exploreSnapshotProvider.overrideWith((ref) => Stream.value(discovery)),
        playerSuggestionsProvider.overrideWith(
          (ref, teamsKey) async => remotePlayers ?? discovery.players,
        ),
        searchSnapshotProvider.overrideWith(
          (ref, request) async =>
              searchFor?.call(request.query) ?? search ?? Snapshot(_payload()),
        ),
      ],
      child: MaterialApp(home: ExploreScreen(focusType: focusType)),
    ),
  );
  await tester.pumpAndSettle();
  return database;
}

void main() {
  test(
    'player suggestions reuse catalogue IDs and rank follows and country',
    () {
      final players = Snapshot(
        _payload(
          players: [
            {'id': 'player_other', 'name': 'Mismo Nombre', 'countryCode': 'US'},
            {'id': 'player_country', 'name': 'Jugador CR', 'countryCode': 'CR'},
            {
              'id': 'player_team',
              'name': 'Jugador Equipo',
              'teamId': 'team_sap',
            },
            {
              'id': 'player_same_name',
              'name': 'Mismo Nombre',
              'countryCode': 'US',
            },
          ],
        ),
      ).players;
      final result = suggestAvailablePlayers(
        remote: [players[2]],
        loaded: players,
        follows: const {'team:team_sap'},
        country: 'CR',
      );
      expect(result.map((player) => player.id), [
        'player_team',
        'player_country',
        'player_other',
        'player_same_name',
      ]);
    },
  );

  testWidgets(
    'player personalization uses loaded catalogue when remote suggestions fail',
    (tester) async {
      await _pump(
        tester,
        discovery: _catalog(),
        remotePlayers: const [],
        focusType: 'player',
      );
      expect(find.text('Encuentra jugadores'), findsOneWidget);
      expect(find.text('Jugadores sugeridos'), findsOneWidget);
      expect(find.text('Competiciones'), findsNothing);
      expect(find.text('Equipos sugeridos'), findsNothing);
      expect(
        find.byTooltip(
          'Seguir Jugador con un nombre especialmente largo para probar diseño',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a canonical player can be followed and unfollowed locally', (
    tester,
  ) async {
    final database = await _pump(
      tester,
      discovery: _catalog(),
      focusType: 'player',
      remotePlayers: const [],
      liveFollows: true,
    );
    final follow = find.byTooltip(
      'Seguir Jugador con un nombre especialmente largo para probar diseño',
    );
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => database.watchFollows().first), {
      'player:player_one',
    });
    final unfollow = find.byTooltip(
      'Dejar de seguir Jugador con un nombre especialmente largo para probar diseño',
    );
    await tester.tap(unfollow);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => database.watchFollows().first), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('discovery is separate and only uses real populated sections', (
    tester,
  ) async {
    await _pump(
      tester,
      discovery: _catalog(),
      follows: const {'team:team_sap'},
    );
    expect(
      find.byKey(const ValueKey('explore-discover-title')),
      findsOneWidget,
    );
    expect(find.text('Mis equipos'), findsOneWidget);
    expect(find.text('Equipos sugeridos'), findsOneWidget);
    expect(find.text('Jugadores sugeridos'), findsOneWidget);
    expect(find.text('Resultados para'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one character does not search and clear returns to discovery', (
    tester,
  ) async {
    await _pump(tester, discovery: _catalog(), search: _catalog());
    final field = find.byKey(const ValueKey('explore-search-field'));
    await tester.enterText(field, 's');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('explore-discover-title')),
      findsOneWidget,
    );
    await tester.enterText(field, 'saprissa');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('explore-results-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('explore-clear-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('explore-clear-search')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('explore-discover-title')),
      findsOneWidget,
    );
  });

  testWidgets('results expose real context and exact empty query', (
    tester,
  ) async {
    await _pump(
      tester,
      discovery: _catalog(),
      searchFor: (query) =>
          query == 'nadie' ? Snapshot(_payload()) : _catalog(),
    );
    await tester.enterText(
      find.byKey(const ValueKey('explore-search-field')),
      'jugador',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('Primera División'), findsWidgets);
    expect(find.textContaining('Defensa'), findsOneWidget);
    expect(find.textContaining('Costa Rica'), findsWidgets);
    expect(
      find.byTooltip(
        'Seguir Jugador con un nombre especialmente largo para probar diseño',
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('explore-search-field')),
      'nadie',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
      find.text('No encontramos resultados para “nadie”.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('long results fit ${width.toInt()}px without overflow', (
      tester,
    ) async {
      await _pump(tester, discovery: _catalog(), width: width);
      expect(tester.takeException(), isNull);
    });
  }
}

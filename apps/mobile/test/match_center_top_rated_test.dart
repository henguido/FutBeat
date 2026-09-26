import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Issue #99 "Jugador del partido" / "Mejores puntuados": surfaces real
// player ratings already present in match detail lineups. Never invents
// data: the section is entirely absent when no player has a rating.

const _match = 'fb_match_tr';
const _home = 'fb_team_tr_home';
const _away = 'fb_team_tr_away';

Map<String, dynamic> _context({String status = 'VERIFIED'}) {
  final now = DateTime.now().toUtc();
  final kickoff = status == 'SCHEDULED'
      ? now.add(const Duration(days: 1))
      : now.subtract(const Duration(days: 1));
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': 'fb_comp_tr', 'name': 'Liga Puntuados'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Puntuados'},
      {'id': _away, 'name': 'Visita Puntuados'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_tr',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': kickoff.toIso8601String(),
        'status': status,
        'season': '2026',
        if (status != 'SCHEDULED') 'score': {'home': 1, 'away': 0},
        'events': const <dynamic>[],
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _player(
  String name, {
  num? rating,
  String? canonicalId,
  String number = '9',
}) => {
  'id': 'ext-$name',
  'canonicalId': canonicalId,
  'name': name,
  'number': number,
  'position': 'Forward',
  'lineupPosition': 1,
  'rating': rating,
};

Map<String, dynamic> _detail({
  List<Map<String, dynamic>> homeStarters = const [],
  List<Map<String, dynamic>> awayStarters = const [],
  List<Map<String, dynamic>> homeSubstitutes = const [],
  List<Map<String, dynamic>> awaySubstitutes = const [],
}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'home': {
    'formation': '4-3-3',
    'starters': homeStarters,
    'substitutes': homeSubstitutes,
  },
  'away': {
    'formation': '4-3-3',
    'starters': awayStarters,
    'substitutes': awaySubstitutes,
  },
  'statistics': const <dynamic>[],
  'incidents': const <dynamic>[],
  'videos': const <dynamic>[],
};

class _Server {
  _Server(this.context, {this.detail});

  Map<String, dynamic> Function(int read) context;
  Map<String, dynamic> Function()? detail;
  int contextReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: context(contextReads++)),
            );
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
          handler.resolve(
            Response(requestOptions: options, data: (detail ?? _detail)()),
          );
        },
      ),
    );
}

Future<ProviderContainer> _open(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  addTearDown(() => tester.runAsync(db.close));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatchScreen(id: _match)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find.byType(Scrollable).last,
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('MatchDetail.topRated', () {
    Json p(String name, {num? rating, String? canonicalId}) =>
        _player(name, rating: rating, canonicalId: canonicalId);

    test('ordered by rating desc, then name asc, then side; skips missing '
        'or non-positive ratings', () {
      final detail = MatchDetail(
        _detail(
          homeStarters: [
            p('Beta', rating: 7.0),
            p('Alfa', rating: 8.5),
            p('SinNota'),
            p('Ceroe', rating: 0),
          ],
          awayStarters: [p('Delta', rating: 8.5), p('Gamma', rating: -1)],
        ),
      );
      final top = detail.topRated();
      expect(top.map((e) => e.player['name']), ['Alfa', 'Delta', 'Beta']);
      expect(top[0].side, 'home');
      expect(top[1].side, 'away');
    });

    test('dedupes by canonicalId, keeping the first occurrence', () {
      final detail = MatchDetail(
        _detail(
          homeStarters: [p('Dup', rating: 9.0, canonicalId: 'c1')],
          homeSubstitutes: [p('Dup', rating: 9.0, canonicalId: 'c1')],
        ),
      );
      expect(detail.topRated().length, 1);
    });

    test('dedupes by name+side when canonicalId is missing', () {
      final detail = MatchDetail(
        _detail(
          homeStarters: [p('SinId', rating: 6.0)],
          homeSubstitutes: [p('SinId', rating: 6.0)],
          awayStarters: [p('SinId', rating: 6.0)],
        ),
      );
      final top = detail.topRated(limit: 10);
      expect(top.length, 2);
    });

    test('limit caps the result', () {
      final detail = MatchDetail(
        _detail(
          homeStarters: [
            p('A', rating: 9),
            p('B', rating: 8),
            p('C', rating: 7),
            p('D', rating: 6),
          ],
        ),
      );
      expect(detail.topRated(limit: 3).length, 3);
    });

    test('playerOfTheMatch is null without a strict leader (tie)', () {
      final tie = MatchDetail(
        _detail(
          homeStarters: [p('A', rating: 9)],
          awayStarters: [p('B', rating: 9)],
        ),
      );
      expect(tie.playerOfTheMatch, isNull);

      final clear = MatchDetail(
        _detail(
          homeStarters: [p('A', rating: 9.1)],
          awayStarters: [p('B', rating: 9)],
        ),
      );
      expect(clear.playerOfTheMatch?.player['name'], 'A');
    });

    test(
      'playerOfTheMatch is the sole entry when only one player is rated',
      () {
        final detail = MatchDetail(
          _detail(homeStarters: [p('Unico', rating: 7.5)]),
        );
        expect(detail.playerOfTheMatch?.player['name'], 'Unico');
      },
    );

    test('empty when nothing is rated', () {
      final detail = MatchDetail(_detail(homeStarters: [p('SinNota')]));
      expect(detail.topRated(), isEmpty);
      expect(detail.playerOfTheMatch, isNull);
    });
  });

  testWidgets('finished match with ratings: "Jugador del partido" and the '
      'highest-rated name shown first', (tester) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'VERIFIED'),
        detail: () => _detail(
          homeStarters: [_player('Estrella', rating: 9.2, canonicalId: 'p1')],
          awayStarters: [
            _player('Segundo', rating: 7.4, canonicalId: 'p2'),
            _player('Tercero', rating: 6.8, canonicalId: 'p3'),
          ],
        ),
      ),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('top-rated-card')));
    expect(find.text('Jugador del partido'), findsOneWidget);
    expect(find.text('Mejores puntuados'), findsNothing);

    final card = find.byKey(const ValueKey('top-rated-card'));
    final names = tester
        .widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(names.indexOf('Estrella'), lessThan(names.indexOf('Segundo')));
    expect(names.indexOf('Estrella'), lessThan(names.indexOf('Tercero')));
    expect(find.byKey(const ValueKey('top-rated-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('top-rated-2')), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('tie at the top: no "Jugador del partido", shows "Mejores '
      'puntuados"', (tester) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'VERIFIED'),
        detail: () => _detail(
          homeStarters: [_player('Empate1', rating: 8.0, canonicalId: 'p1')],
          awayStarters: [_player('Empate2', rating: 8.0, canonicalId: 'p2')],
        ),
      ),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('top-rated-card')));
    expect(find.text('Mejores puntuados'), findsOneWidget);
    expect(find.text('Jugador del partido'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('no ratings: the top-rated section is entirely absent', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'VERIFIED'),
        detail: () =>
            _detail(homeStarters: [_player('SinNota', canonicalId: 'p1')]),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('top-rated-card')), findsNothing);
    expect(find.text('Jugador del partido'), findsNothing);
    expect(find.text('Mejores puntuados'), findsNothing);
    expect(find.text('Mejor puntuado'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('LIVE match: "Mejor puntuado" with a "Provisional" subtitle', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'LIVE'),
        detail: () => _detail(
          homeStarters: [_player('Lider', rating: 7.9, canonicalId: 'p1')],
        ),
      ),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('top-rated-card')));
    expect(find.text('Mejor puntuado'), findsOneWidget);
    expect(find.text('Provisional'), findsOneWidget);
    expect(find.text('Jugador del partido'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('scheduled match: the section is absent before kickoff', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'SCHEDULED'),
        detail: () => _detail(
          homeStarters: [_player('Futuro', rating: 8.0, canonicalId: 'p1')],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('top-rated-card')), findsNothing);
    await _close(tester, container);
  });
}

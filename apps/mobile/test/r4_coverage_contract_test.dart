import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'r3_match_center_regressions_test.dart' show fixture;

Json preview({String availability = 'AVAILABLE', int goals = 1}) => {
  'schemaVersion': 1,
  'matchId': 'fb_match',
  'teams': [
    {'id': 'fb_home', 'name': 'Local'},
    {'id': 'fb_away', 'name': 'Visitante'},
  ],
  'competitions': [],
  'h2h': {
    'state': 'available',
    'availability': availability,
    'meetings': [
      {
        'matchId': 'fb_match_previous',
        'homeTeamId': 'fb_home',
        'awayTeamId': 'fb_away',
        'competitionId': 'fb_comp',
        'startTime': '2026-10-01T18:00:00Z',
        'status': 'VERIFIED',
        'score': {'home': goals, 'away': 0},
      },
    ],
  },
};

Json rawSnapshot(Snapshot value) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': value.updatedAt.toIso8601String(),
  'teams': value.teams.map((e) => e.json).toList(),
  'players': value.players.map((e) => e.json).toList(),
  'competitions': value.competitions.map((e) => e.json).toList(),
  'matches': value.matches.map((e) => e.json).toList(),
  'standings': value.standings,
};

void main() {
  for (final corrupt in ['foreign', 'private']) {
    test('R4 stale H2H rejects $corrupt cached data', () async {
      final db = AppDatabase(NativeDatabase.memory());
      const key = 'public:match-preview:fb_match';
      await db.savePublicSnapshot(
        key,
        jsonEncode({
          ...preview(),
          if (corrupt == 'foreign') 'matchId': 'fb_match_other',
          if (corrupt == 'private') 'userId': 'synthetic_owner',
        }),
      );
      await (db.update(
        db.catalogSnapshots,
      )..where((r) => r.cacheKey.equals(key))).write(
        CatalogSnapshotsCompanion(
          savedAt: Value(
            DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
          ),
        ),
      );
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.reject(
              DioException(
                requestOptions: o,
                response: Response(requestOptions: o, statusCode: 503),
                type: DioExceptionType.badResponse,
              ),
            ),
          ),
        );
      try {
        await expectLater(
          ApiRepository(dio, db).loadMatchPreview('fb_match'),
          throwsA(isA<DioException>()),
        );
      } finally {
        dio.close();
        await db.close();
      }
    });
  }
  testWidgets(
    'R4 saved H2H preview keeps its provenance and navigation action',
    (tester) async {
      final data = fixture('VERIFIED');
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PreviewHeadToHeadSection(
                preview: AsyncValue.data(
                  MatchPreview(preview(availability: 'STALE')),
                ),
                data: data,
                match: data.matches.single,
                onOpen: () => opened++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('preview-h2h-stale-notice')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('preview-h2h-open')));
      expect(opened, 1);
    },
  );

  for (final status in [401, 403]) {
    test('public H2H fallback never hides HTTP $status', () async {
      final db = AppDatabase(NativeDatabase.memory());
      const key = 'public:match-preview:fb_match';
      await db.savePublicSnapshot(key, jsonEncode(preview()));
      await (db.update(
        db.catalogSnapshots,
      )..where((r) => r.cacheKey.equals(key))).write(
        CatalogSnapshotsCompanion(
          savedAt: Value(
            DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
          ),
        ),
      );
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.reject(
              DioException(
                requestOptions: o,
                response: Response(requestOptions: o, statusCode: status),
                type: DioExceptionType.badResponse,
              ),
            ),
          ),
        );
      try {
        await expectLater(
          ApiRepository(dio, db).loadMatchPreview('fb_match'),
          throwsA(isA<DioException>()),
        );
      } finally {
        dio.close();
        await db.close();
      }
    });
  }
  test(
    'H2H updates from PENDING to AVAILABLE through the existing read endpoint',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      var calls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              expect(o.path, '/v1/match-preview');
              calls++;
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  headers: Headers.fromMap({
                    'cache-control': ['public, max-age=30'],
                  }),
                  data: calls == 1
                      ? {
                          ...preview(),
                          'h2h': {'availability': 'PENDING', 'meetings': []},
                        }
                      : preview(goals: 2),
                ),
              );
            },
          ),
        );
      final repo = ApiRepository(dio, db);
      try {
        expect(
          (await repo.loadMatchPreview('fb_match')).h2hAvailability,
          'PENDING',
        );
        expect(
          await db.readPublicSnapshot('public:match-preview:fb_match'),
          isNull,
        );
        final next = await repo.loadMatchPreview('fb_match');
        expect(next.h2hAvailability, 'AVAILABLE');
        expect(next.h2hMeetings.single['score'], {'home': 2, 'away': 0});
        await repo.settleBackground();
        await repo.loadMatchPreview('fb_match');
        expect(calls, 2);
      } finally {
        await repo.settleBackground();
        dio.close();
        await db.close();
      }
    },
  );
  test('a cached H2H identity cannot hide a foreign live response', () async {
    final db = AppDatabase(NativeDatabase.memory());
    const key = 'public:match-preview:fb_match';
    await db.savePublicSnapshot(key, jsonEncode(preview()));
    await (db.update(
      db.catalogSnapshots,
    )..where((r) => r.cacheKey.equals(key))).write(
      CatalogSnapshotsCompanion(
        savedAt: Value(
          DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
        ),
      ),
    );
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {...preview(), 'matchId': 'fb_match_foreign'},
            ),
          ),
        ),
      );
    try {
      await expectLater(
        ApiRepository(dio, db).loadMatchPreview('fb_match'),
        throwsFormatException,
      );
    } finally {
      dio.close();
      await db.close();
    }
  });

  test(
    'only match-row ratings qualify; season stats never create a rating',
    () {
      final seasonOnly = <String, dynamic>{
        'id': 'fb_player',
        'name': 'Jugador',
        'stats': {'rating': 9.7},
        'seasonRating': 9.7,
      };
      expect(matchLineupRating(seasonOnly), isNull);
      expect(playerMatchSummary(seasonOnly, []).rating, isNull);
      final detail = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'home': {
          'starters': [
            seasonOnly,
            {'id': 'bad_inf', 'name': 'Incorrecto', 'rating': double.infinity},
            {'id': 'bad_11', 'name': 'Incorrecto', 'rating': 11},
            {'id': 'valid', 'name': 'Valor del partido', 'rating': '8.2'},
          ],
        },
        'away': {},
      });
      expect(detail.topRated().map((e) => e.player['id']), ['valid']);
      expect(detail.topRated().single.player['rating'], 8.2);
    },
  );

  for (final status in ['SCHEDULED', 'LIVE', 'VERIFIED']) {
    testWidgets(
      'settled empty lineup $status never invents players or keeps loading',
      (tester) async {
        final data = Snapshot({
          ...rawSnapshot(fixture(status)),
          'players': [
            {
              'id': 'fb_season_player',
              'name': 'Jugador histórico',
              'stats': {'rating': 9.7},
            },
          ],
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Lineups(
                data,
                data.matches.single,
                MatchDetail({
                  'matchId': 'fb_match',
                  'available': false,
                  'pending': true,
                  'coverage': {'lineups': 'PENDING'},
                  'home': {},
                  'away': {},
                }),
              ),
            ),
          ),
        );
        expect(
          find.text(
            status == 'SCHEDULED'
                ? 'Alineaciones aún no publicadas'
                : 'Alineaciones no disponibles para este partido',
          ),
          findsOneWidget,
        );
        expect(find.text('Cargando alineaciones…'), findsNothing);
        expect(find.text('Alineación probable'), findsNothing);
        expect(find.text('Jugador histórico'), findsNothing);
        expect(find.text('9.7'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );
  }

  testWidgets(
    'missing table settles; a stored backend table replaces it without guessing a season',
    (tester) async {
      var reads = 0;
      Widget page(Snapshot value) => MaterialApp(
        home: Scaffold(
          body: MatchStandingsTab(
            value,
            'fb_comp',
            refreshing: false,
            season: '2026',
            onRetry: () => reads++,
          ),
        ),
      );
      final missing = fixture('SCHEDULED');
      await tester.pumpWidget(page(missing));
      expect(
        find.text('Clasificación pendiente de actualización'),
        findsOneWidget,
      );
      await tester.tap(find.text('Actualizar'));
      await tester.pump();
      expect(reads, 1);
      final ready = Snapshot({
        ...rawSnapshot(missing),
        'standings': [
          {
            'competitionId': 'fb_comp',
            'season': '2026',
            'rows': [
              {'teamId': 'fb_home', 'position': 1, 'played': 2, 'points': 6},
              {'teamId': 'fb_away', 'position': 2, 'played': 2, 'points': 3},
            ],
          },
        ],
      });
      await tester.pumpWidget(page(ready));
      await tester.pumpAndSettle();
      expect(
        find.text('Clasificación pendiente de actualización'),
        findsNothing,
      );
      expect(find.text('Local'), findsWidgets);
      await tester.pumpWidget(
        page(
          Snapshot({
            ...rawSnapshot(ready),
            'standings': [
              {
                'competitionId': 'fb_comp',
                'season': '2025',
                'rows': [
                  {'teamId': 'fb_home', 'position': 1, 'points': 99},
                ],
              },
            ],
          }),
        ),
      );
      expect(find.text('99'), findsNothing);
    },
  );

  test('expired verified H2H survives 503 as stale, then accepts an updated backend response', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final old = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
    const key = 'public:match-preview:fb_match';
    await db.savePublicSnapshot(key, jsonEncode(preview()));
    await (db.update(db.catalogSnapshots)..where((r) => r.cacheKey.equals(key)))
        .write(CatalogSnapshotsCompanion(savedAt: Value(old)));
    var offline = true, requests = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            requests++;
            expect(o.path, '/v1/match-preview');
            expect(o.queryParameters, {'id': 'fb_match'});
            if (offline) {
              h.reject(
                DioException(
                  requestOptions: o,
                  response: Response(requestOptions: o, statusCode: 503),
                  type: DioExceptionType.badResponse,
                ),
              );
              return;
            }
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: preview(goals: 3),
              ),
            );
          },
        ),
      );
    final repo = ApiRepository(dio, db);
    try {
      final answers = await Future.wait([
        repo.loadMatchPreview('fb_match'),
        repo.loadMatchPreview('fb_match'),
      ]);
      expect(requests, 1);
      expect(answers.first.h2hAvailability, 'STALE');
      expect(answers.first.h2hMeetings.single['score'], {'home': 1, 'away': 0});
      expect(
        (await db.readPublicSnapshot(key))!.savedAt.millisecondsSinceEpoch ~/
            1000,
        old.millisecondsSinceEpoch ~/ 1000,
      );
      offline = false;
      final updated = await repo.loadMatchPreview('fb_match');
      expect(requests, 2);
      expect(updated.h2hAvailability, 'AVAILABLE');
      expect(updated.h2hMeetings.single['score'], {'home': 3, 'away': 0});
    } finally {
      dio.close();
      await db.close();
    }
  });

  testWidgets('stale verified H2H is labelled instead of appearing current', (
    tester,
  ) async {
    final data = fixture('VERIFIED');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HeadToHeadTab(
                preview: AsyncValue.data(
                  MatchPreview(preview(availability: 'STALE')),
                ),
                data: data,
                match: data.matches.single,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Historial guardado'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('h2h-match-fb_match_previous')),
      findsOneWidget,
    );
  });
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';

import 'r3_match_center_regressions_test.dart' show fixture;
import 'r4_coverage_contract_test.dart' show preview;

class PassiveH2hApi extends ApiRepository {
  PassiveH2hApi() : super(Dio());
  final requests = <bool>[];
  @override
  Future<H2hPage> loadMatchH2h(
    String id, {
    String scope = 'all',
    String? cursor,
    int limit = 20,
    bool extend = false,
  }) async {
    requests.add(extend);
    return H2hPage({
      'matchId': id,
      'meetings': [],
      'window': {'canExtend': true, 'extending': false},
    });
  }
}

void main() {
  testWidgets(
    'passive pending permits one request, settles without another offer or polling',
    (tester) async {
      final api = PassiveH2hApi();
      final data = fixture('SCHEDULED');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HeadToHeadTab(
                  preview: AsyncValue.data(
                    MatchPreview(
                      preview(availability: 'PENDING')
                        ..['h2h'] = {'availability': 'PENDING', 'meetings': []},
                    ),
                  ),
                  data: data,
                  match: data.matches.single,
                  onRetry: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Historial no disponible todavía'), findsOneWidget);
      expect(api.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('h2h-retry-pending')));
      await tester.pumpAndSettle();
      expect(api.requests, [true]);
      expect(find.byKey(const ValueKey('h2h-retry-pending')), findsNothing);
      expect(find.byKey(const ValueKey('h2h-extend')), findsNothing);
      expect(find.text('Historial no disponible todavía'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(minutes: 5));
      expect(api.requests, [true]);
      expect(
        find.text('Todavía no hay enfrentamientos recientes disponibles.'),
        findsNothing,
      );
    },
  );

  for (final days in [6, 8]) {
    test(
      'offline verified H2H respects seven-day retention ($days days)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        addTearDown(db.close);
        addTearDown(() => dio.close(force: true));
        const key = 'public:match-preview:fb_match';
        final savedAt = DateTime.now().toUtc().subtract(Duration(days: days));
        await db.savePublicSnapshot(key, jsonEncode(preview()));
        await (db.update(db.catalogSnapshots)
              ..where((r) => r.cacheKey.equals(key)))
            .write(CatalogSnapshotsCompanion(savedAt: Value(savedAt)));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.reject(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
              ),
            ),
          ),
        );
        final repository = ApiRepository(dio, db);
        if (days < 7) {
          final value = await repository.loadMatchPreview('fb_match');
          expect(value.h2hAvailability, 'STALE');
          expect(value.h2hMeetings, isNotEmpty);
          expect(
            (await db.readPublicSnapshot(key))!
                    .savedAt
                    .millisecondsSinceEpoch ~/
                1000,
            savedAt.millisecondsSinceEpoch ~/ 1000,
          );
        } else {
          await expectLater(
            repository.loadMatchPreview('fb_match'),
            throwsA(isA<DioException>()),
          );
        }
      },
    );
  }
}

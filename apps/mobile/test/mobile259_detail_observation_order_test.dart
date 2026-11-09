import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const matchId = 'fb_match_revision259';
Json detail(String? fetchedAt, {required bool cancelled}) => {
  'matchId': matchId,
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'fetchedAt': ?fetchedAt,
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': [
    {'label': 'shots', 'home': cancelled ? 2 : 3, 'away': 1},
  ],
  'incidents': cancelled
      ? <Json>[]
      : [
          {'id': 'goal259', 'type': 'GOAL', 'minute': 20, 'side': 'home'},
        ],
};

class _DelayedDetailRepository implements FootballRepository {
  _DelayedDetailRepository(this.next);
  final MatchDetail next;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => next;
  @override
  Future<Snapshot> load() async => throw UnimplementedError();
  @override
  Future<Snapshot> loadDate(DateTime date) => load();
}

void main() {
  test(
    'older stored detail cannot resurrect an annulled goal or old stats',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final repository = ApiRepository(dio, db);
      addTearDown(() async {
        await repository.settleBackground();
        dio.close(force: true);
        await db.close();
      });
      repository.persistMatchDetail(
        matchId,
        MatchDetail(detail('2026-11-03T20:20:00Z', cancelled: true)),
      );
      repository.persistMatchDetail(
        matchId,
        MatchDetail(detail('2026-11-03T20:10:00Z', cancelled: false)),
      );
      await repository.settleBackground();
      final saved = await repository.readStoredMatchDetail(matchId);
      expect(saved!.json['incidents'], isEmpty);
      expect((saved.json['statistics'] as List).single['home'], 2);
      expect(saved.fetchedAt, '2026-11-03T20:20:00Z');
    },
  );

  test(
    'reopening Match Center rejects older observations in memory too',
    () async {
      final current = MatchDetail(
        detail('2026-11-03T20:20:00Z', cancelled: true),
      );
      final older = MatchDetail(
        detail('2026-11-03T20:10:00Z', cancelled: false),
      );
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(_DelayedDetailRepository(older)),
        ],
      );
      addTearDown(container.dispose);
      container.read(matchDetailMemoryProvider)[matchId] = current;
      final revalidated = Completer<void>();
      var observations = 0;
      final subscription = container.listen(
        matchDetailProvider(matchId),
        (_, next) {
          if (next.asData != null && ++observations == 2) {
            revalidated.complete();
          }
        },
      );
      addTearDown(subscription.close);
      await revalidated.future.timeout(const Duration(seconds: 2));
      final rendered = container
          .read(matchDetailProvider(matchId))
          .asData!
          .value;
      expect(rendered.json['incidents'], isEmpty);
      expect(rendered.fetchedAt, current.fetchedAt);
      expect(
        container.read(matchDetailMemoryProvider)[matchId]!.json['incidents'],
        isEmpty,
      );
    },
  );

  for (final stamp in [
    '2026-11-03T20:20:00Z',
    '2026-11-03T20:21:00Z',
    null,
    'invalid',
  ]) {
    test(
      'authoritative correction remains accepted with timestamp $stamp',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final repository = ApiRepository(dio, db);
        addTearDown(() async {
          await repository.settleBackground();
          dio.close(force: true);
          await db.close();
        });
        repository.persistMatchDetail(
          matchId,
          MatchDetail(detail('2026-11-03T20:20:00Z', cancelled: false)),
        );
        repository.persistMatchDetail(
          matchId,
          MatchDetail(detail(stamp, cancelled: true)),
        );
        await repository.settleBackground();
        final saved = await repository.readStoredMatchDetail(matchId);
        expect(saved!.json['incidents'], isEmpty);
        expect((saved.json['statistics'] as List).single['home'], 2);
      },
    );
  }
}

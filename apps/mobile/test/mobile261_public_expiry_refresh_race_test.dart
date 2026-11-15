import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

const _key = 'public:match-detail:fb_match_expiry_fixture';

class _HoldExpiredRead extends QueryInterceptor {
  bool armed = false;
  final selected = Completer<void>();
  final release = Completer<void>();
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    if (armed && args.length == 1 && args.single == _key) {
      armed = false;
      selected.complete();
      await release.future;
    }
    return rows;
  }
}

void main() {
  for (final refresh in [false, true]) {
    test(
      'expired read cleanup preserves concurrent refresh=$refresh',
      () async {
        final gate = _HoldExpiredRead();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
        addTearDown(() async {
          if (!gate.release.isCompleted) gate.release.complete();
          await db.close();
        });
        // Establish the normal daily prune timestamp, then model a row that
        // expires between bulk sweeps. Only readPublicSnapshot's per-key
        // expiry cleanup should act in this race.
        await db.readPublicSnapshot('public:initial-prune');
        await db
            .into(db.catalogSnapshots)
            .insert(
              CatalogSnapshotsCompanion.insert(
                cacheKey: _key,
                payload: '{"version":1}',
                savedAt: DateTime.now().toUtc().subtract(
                  publicSnapshotRetention + const Duration(days: 1),
                ),
              ),
            );
        gate.armed = true;
        final reading = db.readPublicSnapshot(_key);
        await gate.selected.future.timeout(const Duration(seconds: 5));
        if (refresh) {
          await db.savePublicSnapshot(_key, '{"version":2}');
        }
        gate.release.complete();
        expect(
          await reading,
          isNull,
          reason: 'the observed expired payload must not be returned',
        );
        final current = await db.readCatalogEntry(_key);
        if (refresh) {
          expect(
            current?.payload,
            '{"version":2}',
            reason: 'cleanup must match the expired version, not merely its reused key',
          );
        } else {
          expect(
            current,
            isNull,
            reason: 'the expired version still needs cleanup',
          );
        }
      },
    );
  }
}

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

class _HoldEvictionSelection extends QueryInterceptor {
  final second = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  bool armed = false;
  String? lastInsertedKey;
  final selected = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await executor.runInsert(statement, [
      for (final arg in args) arg is int ? second : arg,
    ]);
    if (args.isNotEmpty && args.first is String)
      lastInsertedKey = args.first as String;
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    if (armed && statement.toUpperCase().contains('OFFSET')) {
      armed = false;
      selected.complete();
      await release.future;
    }
    return rows;
  }
}

void main() {
  for (final partition in ['public', 'catalog', 'calendar']) {
    test(
      'concurrent $partition cache writes retain a bounded newest set',
      () async {
        final gate = _HoldEvictionSelection();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
        addTearDown(db.close);
        final cap = switch (partition) {
          'public' => maxPublicSnapshots,
          'catalog' => maxCatalogSnapshots,
          _ => 64,
        };
        Future<void> save(int index) => switch (partition) {
          'public' => db.savePublicSnapshot(
            'public:match-detail:fb_match_$index',
            '{"ok":true}',
          ),
          'catalog' => db.saveCatalogSnapshot(
            'explore:country:$index',
            '{"ok":true}',
          ),
          _ => db.saveCalendarSnapshot(
            DateTime.utc(
              2026,
              9,
              1,
            ).add(Duration(days: index)).toIso8601String().substring(0, 10),
            '{}',
          ),
        };
        await Future.wait([for (var i = 0; i < cap * 3; i++) save(i)]);
        if (partition == 'calendar') {
          final rows = await db.select(db.calendarSnapshots).get();
          expect(rows, hasLength(cap));
          expect(
            rows.map((row) => row.calendarDate),
            contains(gate.lastInsertedKey),
          );
        } else {
          final rows = await db.select(db.catalogSnapshots).get();
          expect(rows, hasLength(cap));
          expect(
            rows.map((row) => row.cacheKey),
            contains(gate.lastInsertedKey),
          );
        }
      },
    );
  }
  for (final partition in ['public', 'catalog', 'calendar']) {
    test(
      'old $partition eviction cannot delete a newly refreshed row',
      () async {
        final gate = _HoldEvictionSelection();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
        addTearDown(() async {
          if (!gate.release.isCompleted) gate.release.complete();
          await db.close();
        });
        final cap = switch (partition) {
          'public' => maxPublicSnapshots,
          'catalog' => maxCatalogSnapshots,
          _ => 64,
        };
        String key(int i) => switch (partition) {
          'public' => 'public:match-detail:fb_match_$i',
          'catalog' => 'explore:country:$i',
          _ => DateTime.utc(
            2026,
            9,
            1,
          ).add(Duration(days: i)).toIso8601String().substring(0, 10),
        };
        Future<void> write(int i, String payload) => switch (partition) {
          'public' => db.savePublicSnapshot(key(i), payload),
          'catalog' => db.saveCatalogSnapshot(key(i), payload),
          _ => db.saveCalendarSnapshot(key(i), payload),
        };
        Future<String?> read(int i) async => switch (partition) {
          'public' => (await db.readPublicSnapshot(key(i)))?.payload,
          'catalog' => (await db.readCatalogEntry(key(i)))?.payload,
          _ => await db.readCalendarSnapshot(key(i)),
        };
        for (var i = 0; i < cap; i++) {
          await write(i, '{"revision":1}');
        }
        gate.armed = true;
        final olderPrune = write(cap, '{"revision":2}');
        await gate.selected.future.timeout(const Duration(seconds: 5));
        final refreshed = Completer<void>();
        final newerWrite = write(0, '{"revision":3}').then((_) {
          refreshed.complete();
        });
        // A transaction fix may legitimately queue this writer. Drain native
        // SQLite completion turns, ending early on its actual completion event.
        for (var turn = 0; turn < 32 && !refreshed.isCompleted; turn++) {
          await Future<void>.delayed(Duration.zero);
        }
        gate.release.complete();
        await olderPrune;
        await newerWrite;
        expect(
          await read(0),
          '{"revision":3}',
          reason: 'eviction selected an old row, not the new response saved under that key',
        );
        expect(await read(cap), '{"revision":2}');
        final count = partition == 'calendar'
            ? (await db.select(db.calendarSnapshots).get()).length
            : (await (db.select(db.catalogSnapshots)..where(
                        (row) => partition == 'public'
                            ? row.cacheKey.like('public:%')
                            : row.cacheKey.like('public:%').not(),
                      ))
                      .get())
                  .length;
        expect(count, cap);
      },
    );
  }
}

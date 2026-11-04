import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

// SQLite stores these DateTime columns as integer seconds. Force the valid
// same-second case without depending on host speed or a wall-clock boundary.
class _SameSecond extends QueryInterceptor {
  final second = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('catalog_snapshots') ||
        statement.contains('calendar_snapshots')) {
      return executor.runInsert(statement, [
        for (final arg in args) arg is int ? second : arg,
      ]);
    }
    return executor.runInsert(statement, args);
  }
}

void main() {
  for (final partition in ['public', 'catalog', 'calendar']) {
    test('newest $partition snapshot survives same-second capacity eviction', () async {
      final db = AppDatabase(
        NativeDatabase.memory().interceptWith(_SameSecond()),
      );
      addTearDown(db.close);
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
      await write(cap, '{"revision":2}');
      expect(
        await read(cap),
        '{"revision":2}',
        reason: 'a just-saved response cannot be its own eviction victim',
      );
      expect(
        await read(0),
        isNull,
        reason: 'the oldest equal-second row should leave first',
      );
      // Refreshing an existing row must also move it ahead of tied entries,
      // not retain its old insertion position then disappear on the next save.
      await write(1, '{"revision":3}');
      await write(cap + 1, '{"revision":4}');
      expect(await read(1), '{"revision":3}');
      expect(await read(cap + 1), '{"revision":4}');
      expect(await read(2), isNull);
    });
  }
}

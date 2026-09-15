import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
part 'database.g.dart';

class Follows extends Table {
  TextColumn get entityId => text()();
  TextColumn get entityType => text()();
  @override
  Set<Column> get primaryKey => {entityId, entityType};
}

@DriftDatabase(tables: [Follows])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'futbeat'));
  @override
  int get schemaVersion => 1;
  Stream<Set<String>> watchFollows() => select(follows)
      .watch()
      .map((rows) => rows.map((r) => '${r.entityType}:${r.entityId}').toSet());
  Future<void> toggle(String type, String id) => transaction(() async {
    final query = select(follows)
      ..where((f) => f.entityType.equals(type) & f.entityId.equals(id));
    if (await query.getSingleOrNull() == null) {
      await into(follows)
          .insert(FollowsCompanion.insert(entityId: id, entityType: type));
    } else {
      await (delete(
        follows,
      )..where((f) => f.entityType.equals(type) & f.entityId.equals(id))).go();
    }
  });
}

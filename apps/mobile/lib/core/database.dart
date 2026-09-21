import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
part 'database.g.dart';

class Follows extends Table {
  TextColumn get entityId => text()();
  TextColumn get entityType => text()();
  @override
  Set<Column> get primaryKey => {entityId, entityType};
}

class Preferences extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get detectedCountry => text().nullable()();
  TextColumn get selectedCountry => text().nullable()();
  BoolColumn get bootstrapDismissed =>
      boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

class TemporaryInterests extends Table {
  TextColumn get entityId => text()();
  TextColumn get entityType => text()();
  DateTimeColumn get expiresAt => dateTime()();
  @override
  Set<Column> get primaryKey => {entityId, entityType};
}

class CalendarSnapshots extends Table {
  TextColumn get calendarDate => text()();
  TextColumn get payload => text()();
  DateTimeColumn get savedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {calendarDate};
}

@DriftDatabase(
  tables: [Follows, Preferences, TemporaryInterests, CalendarSnapshots],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'futbeat'));
  @override
  int get schemaVersion => 3;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(preferences);
        await m.createTable(temporaryInterests);
      }
      if (from < 3) await m.createTable(calendarSnapshots);
    },
  );
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
  Stream<CountryPreference> watchPreference() =>
      (select(
        preferences,
      )..where((p) => p.id.equals(1))).watchSingleOrNull().map(
        (row) => CountryPreference(
          detectedCountry: row?.detectedCountry,
          selectedCountry: row?.selectedCountry,
          bootstrapDismissed: row?.bootstrapDismissed ?? false,
        ),
      );
  Future<void> savePreference({
    String? detectedCountry,
    String? selectedCountry,
    bool? bootstrapDismissed,
  }) async {
    final old = await (select(
      preferences,
    )..where((p) => p.id.equals(1))).getSingleOrNull();
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        id: const Value(1),
        detectedCountry: Value(detectedCountry ?? old?.detectedCountry),
        selectedCountry: Value(selectedCountry),
        bootstrapDismissed: Value(
          bootstrapDismissed ?? old?.bootstrapDismissed ?? false,
        ),
      ),
    );
  }

  Future<void> touchInterest(
    String type,
    String id, {
    Duration ttl = const Duration(minutes: 30),
  }) => into(temporaryInterests).insertOnConflictUpdate(
    TemporaryInterestsCompanion.insert(
      entityId: id,
      entityType: type,
      expiresAt: DateTime.now().add(ttl),
    ),
  );
  Stream<Set<String>> watchTemporaryInterests() {
    final query = select(temporaryInterests)
      ..where((row) => row.expiresAt.isBiggerThanValue(DateTime.now()));
    return query.watch().map(
      (rows) => rows.map((r) => '${r.entityType}:${r.entityId}').toSet(),
    );
  }

  Future<String?> readCalendarSnapshot(String date) async => (await (select(
    calendarSnapshots,
  )..where((row) => row.calendarDate.equals(date))).getSingleOrNull())?.payload;

  Future<void> saveCalendarSnapshot(String date, String payload) async {
    await into(calendarSnapshots).insertOnConflictUpdate(
      CalendarSnapshotsCompanion.insert(
        calendarDate: date,
        payload: payload,
        savedAt: DateTime.now().toUtc(),
      ),
    );
    final old =
        await (select(calendarSnapshots)
              ..orderBy([(row) => OrderingTerm.desc(row.savedAt)])
              ..limit(100, offset: 64))
            .get();
    if (old.isNotEmpty) {
      await (delete(calendarSnapshots)..where(
            (row) => row.calendarDate.isIn(
              old.map((item) => item.calendarDate).toList(),
            ),
          ))
          .go();
    }
  }
}

class CountryPreference {
  const CountryPreference({
    required this.detectedCountry,
    required this.selectedCountry,
    required this.bootstrapDismissed,
  });
  final String? detectedCountry;
  final String? selectedCountry;
  final bool bootstrapDismissed;
  String? get effectiveCountry => selectedCountry ?? detectedCountry;
}

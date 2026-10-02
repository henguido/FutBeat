import 'dart:convert';

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
  TextColumn get competitionOrderMode =>
      text().withDefault(const Constant('automatic'))();
  TextColumn get competitionOrderPreference =>
      text().withDefault(const Constant('country_first'))();
  TextColumn get pinnedCompetitionIds =>
      text().withDefault(const Constant('[]'))();
  DateTimeColumn get competitionOrderUpdatedAt => dateTime().nullable()();
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

/// Last answer of a public catalog read (Explorar suggestions), so the
/// screen paints at once on the next app start while it revalidates. Public,
/// non-personal data; bounded to a handful of keys.
class CatalogSnapshots extends Table {
  TextColumn get cacheKey => text()();
  TextColumn get payload => text()();
  DateTimeColumn get savedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {cacheKey};
}

@DriftDatabase(
  tables: [
    Follows,
    Preferences,
    TemporaryInterests,
    CalendarSnapshots,
    CatalogSnapshots,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'futbeat'));
  @override
  int get schemaVersion => 5;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(preferences);
        await m.createTable(temporaryInterests);
      }
      if (from < 3) await m.createTable(calendarSnapshots);
      if (from < 5) await m.createTable(catalogSnapshots);
      if (from >= 2 && from < 4) {
        await m.addColumn(preferences, preferences.competitionOrderMode);
        await m.addColumn(preferences, preferences.competitionOrderPreference);
        await m.addColumn(preferences, preferences.pinnedCompetitionIds);
        await m.addColumn(preferences, preferences.competitionOrderUpdatedAt);
        await customStatement(
          'UPDATE preferences SET competition_order_updated_at = '
          "CAST(strftime('%s', 'now') AS INTEGER) "
          'WHERE competition_order_updated_at IS NULL',
        );
      }
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

  /// Toggle of one identity stored under several ids (canonical + aliases):
  /// when any of [canonicalId] / [aliasIds] is followed, all of them are
  /// removed; otherwise [canonicalId] is followed.
  Future<void> toggleAny(
    String type,
    String canonicalId,
    Set<String> aliasIds,
  ) => transaction(() async {
    final ids = {canonicalId, ...aliasIds};
    final existing = await (select(
      follows,
    )..where((f) => f.entityType.equals(type) & f.entityId.isIn(ids))).get();
    if (existing.isEmpty) {
      await into(follows).insert(
        FollowsCompanion.insert(entityId: canonicalId, entityType: type),
      );
    } else {
      await (delete(
        follows,
      )..where((f) => f.entityType.equals(type) & f.entityId.isIn(ids))).go();
    }
  });

  /// Inserts `type:id` follow keys, ignoring ones already present. Unlike
  /// [toggle] it never removes anything, so it is safe for merges.
  Future<void> addFollows(Iterable<String> keys) async {
    final rows = <FollowsCompanion>[];
    for (final key in keys) {
      final separator = key.indexOf(':');
      if (separator <= 0 || separator == key.length - 1) continue;
      rows.add(
        FollowsCompanion.insert(
          entityType: key.substring(0, separator),
          entityId: key.substring(separator + 1),
        ),
      );
    }
    if (rows.isEmpty) return;
    await batch(
      (b) => b.insertAll(follows, rows, mode: InsertMode.insertOrIgnore),
    );
  }

  /// Removes `type:id` follow keys (another account's leftovers).
  Future<void> removeFollows(Iterable<String> keys) => transaction(() async {
    for (final key in keys) {
      final separator = key.indexOf(':');
      if (separator <= 0 || separator == key.length - 1) continue;
      final type = key.substring(0, separator);
      final id = key.substring(separator + 1);
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
          competitionOrderMode:
              row?.competitionOrderMode ?? CompetitionOrderMode.automatic,
          competitionOrderPreference:
              row?.competitionOrderPreference ??
              CompetitionOrderPreference.countryFirst,
          pinnedCompetitionIds: _decodeIds(row?.pinnedCompetitionIds),
          competitionOrderUpdatedAt: row?.competitionOrderUpdatedAt,
        ),
      );
  Future<void> savePreference({
    String? detectedCountry,
    String? selectedCountry,
    bool? bootstrapDismissed,
    String? competitionOrderMode,
    String? competitionOrderPreference,
    List<String>? pinnedCompetitionIds,
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
        competitionOrderMode: Value(
          competitionOrderMode ??
              old?.competitionOrderMode ??
              CompetitionOrderMode.automatic,
        ),
        competitionOrderPreference: Value(
          competitionOrderPreference ??
              old?.competitionOrderPreference ??
              CompetitionOrderPreference.countryFirst,
        ),
        pinnedCompetitionIds: Value(
          pinnedCompetitionIds == null
              ? old?.pinnedCompetitionIds ?? '[]'
              : jsonEncode(pinnedCompetitionIds.toSet().toList()),
        ),
        competitionOrderUpdatedAt: Value(
          competitionOrderMode != null ||
                  competitionOrderPreference != null ||
                  pinnedCompetitionIds != null
              ? DateTime.now().toUtc()
              : old?.competitionOrderUpdatedAt ?? DateTime.now().toUtc(),
        ),
      ),
    );
  }

  Future<void> markBootstrapDismissed() async {
    final updateGate = update(preferences)..where((p) => p.id.equals(1));
    if (await updateGate.write(
          const PreferencesCompanion(bootstrapDismissed: Value(true)),
        ) ==
        0) {
      await into(preferences).insert(
        PreferencesCompanion.insert(
          id: const Value(1),
          bootstrapDismissed: const Value(true),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      await updateGate.write(
        const PreferencesCompanion(bootstrapDismissed: Value(true)),
      );
    }
  }

  Future<void> saveDetectedCountry(String? detectedCountry) async {
    await into(preferences).insert(
      PreferencesCompanion.insert(
        id: const Value(1),
        detectedCountry: Value(detectedCountry),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    await (update(preferences)..where((p) => p.id.equals(1))).write(
      PreferencesCompanion(detectedCountry: Value(detectedCountry)),
    );
  }

  Future<void> saveSelectedCountry(String? selectedCountry) async {
    await into(preferences).insert(
      PreferencesCompanion.insert(
        id: const Value(1),
        selectedCountry: Value(selectedCountry),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    await (update(preferences)..where((p) => p.id.equals(1))).write(
      PreferencesCompanion(selectedCountry: Value(selectedCountry)),
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

  Future<CalendarSnapshot?> readCalendarEntry(String date) => (select(
    calendarSnapshots,
  )..where((row) => row.calendarDate.equals(date))).getSingleOrNull();

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

  Future<CatalogSnapshot?> readCatalogEntry(String key) => (select(
    catalogSnapshots,
  )..where((row) => row.cacheKey.equals(key))).getSingleOrNull();

  Future<void> saveCatalogSnapshot(String key, String payload) async {
    await into(catalogSnapshots).insertOnConflictUpdate(
      CatalogSnapshotsCompanion.insert(
        cacheKey: key,
        payload: payload,
        savedAt: DateTime.now().toUtc(),
      ),
    );
    final old =
        await (select(catalogSnapshots)
              ..orderBy([(row) => OrderingTerm.desc(row.savedAt)])
              ..limit(100, offset: maxCatalogSnapshots))
            .get();
    if (old.isNotEmpty) {
      await (delete(catalogSnapshots)..where(
            (row) => row.cacheKey.isIn(old.map((item) => item.cacheKey)),
          ))
          .go();
    }
  }
}

/// Stored catalog answers kept on the device (global + recent countries).
const maxCatalogSnapshots = 8;

class CountryPreference {
  const CountryPreference({
    required this.detectedCountry,
    required this.selectedCountry,
    required this.bootstrapDismissed,
    this.competitionOrderMode = CompetitionOrderMode.automatic,
    this.competitionOrderPreference = CompetitionOrderPreference.countryFirst,
    this.pinnedCompetitionIds = const <String>[],
    this.competitionOrderUpdatedAt,
  });
  final String? detectedCountry;
  final String? selectedCountry;
  final bool bootstrapDismissed;
  final String competitionOrderMode;
  final String competitionOrderPreference;
  final List<String> pinnedCompetitionIds;
  final DateTime? competitionOrderUpdatedAt;
  String? get effectiveCountry => selectedCountry ?? detectedCountry;
}

abstract final class CompetitionOrderMode {
  static const automatic = 'automatic';
  static const personalized = 'personalized';
}

abstract final class CompetitionOrderPreference {
  static const globalFirst = 'global_first';
  static const countryFirst = 'country_first';
}

List<String> _decodeIds(String? raw) {
  try {
    return (jsonDecode(raw ?? '[]') as List)
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
  } catch (_) {
    return const <String>[];
  }
}

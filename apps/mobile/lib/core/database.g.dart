// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $FollowsTable extends Follows with TableInfo<$FollowsTable, Follow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FollowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [entityId, entityType];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'follows';
  @override
  VerificationContext validateIntegrity(
    Insertable<Follow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entityId, entityType};
  @override
  Follow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Follow(
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
    );
  }

  @override
  $FollowsTable createAlias(String alias) {
    return $FollowsTable(attachedDatabase, alias);
  }
}

class Follow extends DataClass implements Insertable<Follow> {
  final String entityId;
  final String entityType;
  const Follow({required this.entityId, required this.entityType});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity_id'] = Variable<String>(entityId);
    map['entity_type'] = Variable<String>(entityType);
    return map;
  }

  FollowsCompanion toCompanion(bool nullToAbsent) {
    return FollowsCompanion(
      entityId: Value(entityId),
      entityType: Value(entityType),
    );
  }

  factory Follow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Follow(
      entityId: serializer.fromJson<String>(json['entityId']),
      entityType: serializer.fromJson<String>(json['entityType']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entityId': serializer.toJson<String>(entityId),
      'entityType': serializer.toJson<String>(entityType),
    };
  }

  Follow copyWith({String? entityId, String? entityType}) => Follow(
    entityId: entityId ?? this.entityId,
    entityType: entityType ?? this.entityType,
  );
  Follow copyWithCompanion(FollowsCompanion data) {
    return Follow(
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Follow(')
          ..write('entityId: $entityId, ')
          ..write('entityType: $entityType')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entityId, entityType);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Follow &&
          other.entityId == this.entityId &&
          other.entityType == this.entityType);
}

class FollowsCompanion extends UpdateCompanion<Follow> {
  final Value<String> entityId;
  final Value<String> entityType;
  final Value<int> rowid;
  const FollowsCompanion({
    this.entityId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FollowsCompanion.insert({
    required String entityId,
    required String entityType,
    this.rowid = const Value.absent(),
  }) : entityId = Value(entityId),
       entityType = Value(entityType);
  static Insertable<Follow> custom({
    Expression<String>? entityId,
    Expression<String>? entityType,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entityId != null) 'entity_id': entityId,
      if (entityType != null) 'entity_type': entityType,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FollowsCompanion copyWith({
    Value<String>? entityId,
    Value<String>? entityType,
    Value<int>? rowid,
  }) {
    return FollowsCompanion(
      entityId: entityId ?? this.entityId,
      entityType: entityType ?? this.entityType,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FollowsCompanion(')
          ..write('entityId: $entityId, ')
          ..write('entityType: $entityType, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PreferencesTable extends Preferences
    with TableInfo<$PreferencesTable, Preference> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _detectedCountryMeta = const VerificationMeta(
    'detectedCountry',
  );
  @override
  late final GeneratedColumn<String> detectedCountry = GeneratedColumn<String>(
    'detected_country',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _selectedCountryMeta = const VerificationMeta(
    'selectedCountry',
  );
  @override
  late final GeneratedColumn<String> selectedCountry = GeneratedColumn<String>(
    'selected_country',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bootstrapDismissedMeta =
      const VerificationMeta('bootstrapDismissed');
  @override
  late final GeneratedColumn<bool> bootstrapDismissed = GeneratedColumn<bool>(
    'bootstrap_dismissed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("bootstrap_dismissed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    detectedCountry,
    selectedCountry,
    bootstrapDismissed,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'preferences';
  @override
  VerificationContext validateIntegrity(
    Insertable<Preference> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('detected_country')) {
      context.handle(
        _detectedCountryMeta,
        detectedCountry.isAcceptableOrUnknown(
          data['detected_country']!,
          _detectedCountryMeta,
        ),
      );
    }
    if (data.containsKey('selected_country')) {
      context.handle(
        _selectedCountryMeta,
        selectedCountry.isAcceptableOrUnknown(
          data['selected_country']!,
          _selectedCountryMeta,
        ),
      );
    }
    if (data.containsKey('bootstrap_dismissed')) {
      context.handle(
        _bootstrapDismissedMeta,
        bootstrapDismissed.isAcceptableOrUnknown(
          data['bootstrap_dismissed']!,
          _bootstrapDismissedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Preference map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Preference(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      detectedCountry: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}detected_country'],
      ),
      selectedCountry: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}selected_country'],
      ),
      bootstrapDismissed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}bootstrap_dismissed'],
      )!,
    );
  }

  @override
  $PreferencesTable createAlias(String alias) {
    return $PreferencesTable(attachedDatabase, alias);
  }
}

class Preference extends DataClass implements Insertable<Preference> {
  final int id;
  final String? detectedCountry;
  final String? selectedCountry;
  final bool bootstrapDismissed;
  const Preference({
    required this.id,
    this.detectedCountry,
    this.selectedCountry,
    required this.bootstrapDismissed,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || detectedCountry != null) {
      map['detected_country'] = Variable<String>(detectedCountry);
    }
    if (!nullToAbsent || selectedCountry != null) {
      map['selected_country'] = Variable<String>(selectedCountry);
    }
    map['bootstrap_dismissed'] = Variable<bool>(bootstrapDismissed);
    return map;
  }

  PreferencesCompanion toCompanion(bool nullToAbsent) {
    return PreferencesCompanion(
      id: Value(id),
      detectedCountry: detectedCountry == null && nullToAbsent
          ? const Value.absent()
          : Value(detectedCountry),
      selectedCountry: selectedCountry == null && nullToAbsent
          ? const Value.absent()
          : Value(selectedCountry),
      bootstrapDismissed: Value(bootstrapDismissed),
    );
  }

  factory Preference.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Preference(
      id: serializer.fromJson<int>(json['id']),
      detectedCountry: serializer.fromJson<String?>(json['detectedCountry']),
      selectedCountry: serializer.fromJson<String?>(json['selectedCountry']),
      bootstrapDismissed: serializer.fromJson<bool>(json['bootstrapDismissed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'detectedCountry': serializer.toJson<String?>(detectedCountry),
      'selectedCountry': serializer.toJson<String?>(selectedCountry),
      'bootstrapDismissed': serializer.toJson<bool>(bootstrapDismissed),
    };
  }

  Preference copyWith({
    int? id,
    Value<String?> detectedCountry = const Value.absent(),
    Value<String?> selectedCountry = const Value.absent(),
    bool? bootstrapDismissed,
  }) => Preference(
    id: id ?? this.id,
    detectedCountry: detectedCountry.present
        ? detectedCountry.value
        : this.detectedCountry,
    selectedCountry: selectedCountry.present
        ? selectedCountry.value
        : this.selectedCountry,
    bootstrapDismissed: bootstrapDismissed ?? this.bootstrapDismissed,
  );
  Preference copyWithCompanion(PreferencesCompanion data) {
    return Preference(
      id: data.id.present ? data.id.value : this.id,
      detectedCountry: data.detectedCountry.present
          ? data.detectedCountry.value
          : this.detectedCountry,
      selectedCountry: data.selectedCountry.present
          ? data.selectedCountry.value
          : this.selectedCountry,
      bootstrapDismissed: data.bootstrapDismissed.present
          ? data.bootstrapDismissed.value
          : this.bootstrapDismissed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Preference(')
          ..write('id: $id, ')
          ..write('detectedCountry: $detectedCountry, ')
          ..write('selectedCountry: $selectedCountry, ')
          ..write('bootstrapDismissed: $bootstrapDismissed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, detectedCountry, selectedCountry, bootstrapDismissed);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Preference &&
          other.id == this.id &&
          other.detectedCountry == this.detectedCountry &&
          other.selectedCountry == this.selectedCountry &&
          other.bootstrapDismissed == this.bootstrapDismissed);
}

class PreferencesCompanion extends UpdateCompanion<Preference> {
  final Value<int> id;
  final Value<String?> detectedCountry;
  final Value<String?> selectedCountry;
  final Value<bool> bootstrapDismissed;
  const PreferencesCompanion({
    this.id = const Value.absent(),
    this.detectedCountry = const Value.absent(),
    this.selectedCountry = const Value.absent(),
    this.bootstrapDismissed = const Value.absent(),
  });
  PreferencesCompanion.insert({
    this.id = const Value.absent(),
    this.detectedCountry = const Value.absent(),
    this.selectedCountry = const Value.absent(),
    this.bootstrapDismissed = const Value.absent(),
  });
  static Insertable<Preference> custom({
    Expression<int>? id,
    Expression<String>? detectedCountry,
    Expression<String>? selectedCountry,
    Expression<bool>? bootstrapDismissed,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (detectedCountry != null) 'detected_country': detectedCountry,
      if (selectedCountry != null) 'selected_country': selectedCountry,
      if (bootstrapDismissed != null) 'bootstrap_dismissed': bootstrapDismissed,
    });
  }

  PreferencesCompanion copyWith({
    Value<int>? id,
    Value<String?>? detectedCountry,
    Value<String?>? selectedCountry,
    Value<bool>? bootstrapDismissed,
  }) {
    return PreferencesCompanion(
      id: id ?? this.id,
      detectedCountry: detectedCountry ?? this.detectedCountry,
      selectedCountry: selectedCountry ?? this.selectedCountry,
      bootstrapDismissed: bootstrapDismissed ?? this.bootstrapDismissed,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (detectedCountry.present) {
      map['detected_country'] = Variable<String>(detectedCountry.value);
    }
    if (selectedCountry.present) {
      map['selected_country'] = Variable<String>(selectedCountry.value);
    }
    if (bootstrapDismissed.present) {
      map['bootstrap_dismissed'] = Variable<bool>(bootstrapDismissed.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferencesCompanion(')
          ..write('id: $id, ')
          ..write('detectedCountry: $detectedCountry, ')
          ..write('selectedCountry: $selectedCountry, ')
          ..write('bootstrapDismissed: $bootstrapDismissed')
          ..write(')'))
        .toString();
  }
}

class $TemporaryInterestsTable extends TemporaryInterests
    with TableInfo<$TemporaryInterestsTable, TemporaryInterest> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TemporaryInterestsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [entityId, entityType, expiresAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'temporary_interests';
  @override
  VerificationContext validateIntegrity(
    Insertable<TemporaryInterest> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entityId, entityType};
  @override
  TemporaryInterest map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TemporaryInterest(
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
    );
  }

  @override
  $TemporaryInterestsTable createAlias(String alias) {
    return $TemporaryInterestsTable(attachedDatabase, alias);
  }
}

class TemporaryInterest extends DataClass
    implements Insertable<TemporaryInterest> {
  final String entityId;
  final String entityType;
  final DateTime expiresAt;
  const TemporaryInterest({
    required this.entityId,
    required this.entityType,
    required this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity_id'] = Variable<String>(entityId);
    map['entity_type'] = Variable<String>(entityType);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    return map;
  }

  TemporaryInterestsCompanion toCompanion(bool nullToAbsent) {
    return TemporaryInterestsCompanion(
      entityId: Value(entityId),
      entityType: Value(entityType),
      expiresAt: Value(expiresAt),
    );
  }

  factory TemporaryInterest.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TemporaryInterest(
      entityId: serializer.fromJson<String>(json['entityId']),
      entityType: serializer.fromJson<String>(json['entityType']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entityId': serializer.toJson<String>(entityId),
      'entityType': serializer.toJson<String>(entityType),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
    };
  }

  TemporaryInterest copyWith({
    String? entityId,
    String? entityType,
    DateTime? expiresAt,
  }) => TemporaryInterest(
    entityId: entityId ?? this.entityId,
    entityType: entityType ?? this.entityType,
    expiresAt: expiresAt ?? this.expiresAt,
  );
  TemporaryInterest copyWithCompanion(TemporaryInterestsCompanion data) {
    return TemporaryInterest(
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TemporaryInterest(')
          ..write('entityId: $entityId, ')
          ..write('entityType: $entityType, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entityId, entityType, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TemporaryInterest &&
          other.entityId == this.entityId &&
          other.entityType == this.entityType &&
          other.expiresAt == this.expiresAt);
}

class TemporaryInterestsCompanion extends UpdateCompanion<TemporaryInterest> {
  final Value<String> entityId;
  final Value<String> entityType;
  final Value<DateTime> expiresAt;
  final Value<int> rowid;
  const TemporaryInterestsCompanion({
    this.entityId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TemporaryInterestsCompanion.insert({
    required String entityId,
    required String entityType,
    required DateTime expiresAt,
    this.rowid = const Value.absent(),
  }) : entityId = Value(entityId),
       entityType = Value(entityType),
       expiresAt = Value(expiresAt);
  static Insertable<TemporaryInterest> custom({
    Expression<String>? entityId,
    Expression<String>? entityType,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entityId != null) 'entity_id': entityId,
      if (entityType != null) 'entity_type': entityType,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TemporaryInterestsCompanion copyWith({
    Value<String>? entityId,
    Value<String>? entityType,
    Value<DateTime>? expiresAt,
    Value<int>? rowid,
  }) {
    return TemporaryInterestsCompanion(
      entityId: entityId ?? this.entityId,
      entityType: entityType ?? this.entityType,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TemporaryInterestsCompanion(')
          ..write('entityId: $entityId, ')
          ..write('entityType: $entityType, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarSnapshotsTable extends CalendarSnapshots
    with TableInfo<$CalendarSnapshotsTable, CalendarSnapshot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarSnapshotsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _calendarDateMeta = const VerificationMeta(
    'calendarDate',
  );
  @override
  late final GeneratedColumn<String> calendarDate = GeneratedColumn<String>(
    'calendar_date',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedAtMeta = const VerificationMeta(
    'savedAt',
  );
  @override
  late final GeneratedColumn<DateTime> savedAt = GeneratedColumn<DateTime>(
    'saved_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [calendarDate, payload, savedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_snapshots';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarSnapshot> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('calendar_date')) {
      context.handle(
        _calendarDateMeta,
        calendarDate.isAcceptableOrUnknown(
          data['calendar_date']!,
          _calendarDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_calendarDateMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('saved_at')) {
      context.handle(
        _savedAtMeta,
        savedAt.isAcceptableOrUnknown(data['saved_at']!, _savedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_savedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {calendarDate};
  @override
  CalendarSnapshot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarSnapshot(
      calendarDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}calendar_date'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      savedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}saved_at'],
      )!,
    );
  }

  @override
  $CalendarSnapshotsTable createAlias(String alias) {
    return $CalendarSnapshotsTable(attachedDatabase, alias);
  }
}

class CalendarSnapshot extends DataClass
    implements Insertable<CalendarSnapshot> {
  final String calendarDate;
  final String payload;
  final DateTime savedAt;
  const CalendarSnapshot({
    required this.calendarDate,
    required this.payload,
    required this.savedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['calendar_date'] = Variable<String>(calendarDate);
    map['payload'] = Variable<String>(payload);
    map['saved_at'] = Variable<DateTime>(savedAt);
    return map;
  }

  CalendarSnapshotsCompanion toCompanion(bool nullToAbsent) {
    return CalendarSnapshotsCompanion(
      calendarDate: Value(calendarDate),
      payload: Value(payload),
      savedAt: Value(savedAt),
    );
  }

  factory CalendarSnapshot.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarSnapshot(
      calendarDate: serializer.fromJson<String>(json['calendarDate']),
      payload: serializer.fromJson<String>(json['payload']),
      savedAt: serializer.fromJson<DateTime>(json['savedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'calendarDate': serializer.toJson<String>(calendarDate),
      'payload': serializer.toJson<String>(payload),
      'savedAt': serializer.toJson<DateTime>(savedAt),
    };
  }

  CalendarSnapshot copyWith({
    String? calendarDate,
    String? payload,
    DateTime? savedAt,
  }) => CalendarSnapshot(
    calendarDate: calendarDate ?? this.calendarDate,
    payload: payload ?? this.payload,
    savedAt: savedAt ?? this.savedAt,
  );
  CalendarSnapshot copyWithCompanion(CalendarSnapshotsCompanion data) {
    return CalendarSnapshot(
      calendarDate: data.calendarDate.present
          ? data.calendarDate.value
          : this.calendarDate,
      payload: data.payload.present ? data.payload.value : this.payload,
      savedAt: data.savedAt.present ? data.savedAt.value : this.savedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarSnapshot(')
          ..write('calendarDate: $calendarDate, ')
          ..write('payload: $payload, ')
          ..write('savedAt: $savedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(calendarDate, payload, savedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarSnapshot &&
          other.calendarDate == this.calendarDate &&
          other.payload == this.payload &&
          other.savedAt == this.savedAt);
}

class CalendarSnapshotsCompanion extends UpdateCompanion<CalendarSnapshot> {
  final Value<String> calendarDate;
  final Value<String> payload;
  final Value<DateTime> savedAt;
  final Value<int> rowid;
  const CalendarSnapshotsCompanion({
    this.calendarDate = const Value.absent(),
    this.payload = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarSnapshotsCompanion.insert({
    required String calendarDate,
    required String payload,
    required DateTime savedAt,
    this.rowid = const Value.absent(),
  }) : calendarDate = Value(calendarDate),
       payload = Value(payload),
       savedAt = Value(savedAt);
  static Insertable<CalendarSnapshot> custom({
    Expression<String>? calendarDate,
    Expression<String>? payload,
    Expression<DateTime>? savedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (calendarDate != null) 'calendar_date': calendarDate,
      if (payload != null) 'payload': payload,
      if (savedAt != null) 'saved_at': savedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarSnapshotsCompanion copyWith({
    Value<String>? calendarDate,
    Value<String>? payload,
    Value<DateTime>? savedAt,
    Value<int>? rowid,
  }) {
    return CalendarSnapshotsCompanion(
      calendarDate: calendarDate ?? this.calendarDate,
      payload: payload ?? this.payload,
      savedAt: savedAt ?? this.savedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (calendarDate.present) {
      map['calendar_date'] = Variable<String>(calendarDate.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (savedAt.present) {
      map['saved_at'] = Variable<DateTime>(savedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarSnapshotsCompanion(')
          ..write('calendarDate: $calendarDate, ')
          ..write('payload: $payload, ')
          ..write('savedAt: $savedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $FollowsTable follows = $FollowsTable(this);
  late final $PreferencesTable preferences = $PreferencesTable(this);
  late final $TemporaryInterestsTable temporaryInterests =
      $TemporaryInterestsTable(this);
  late final $CalendarSnapshotsTable calendarSnapshots =
      $CalendarSnapshotsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    follows,
    preferences,
    temporaryInterests,
    calendarSnapshots,
  ];
}

typedef $$FollowsTableCreateCompanionBuilder = FollowsCompanion Function({
  required String entityId,
  required String entityType,
  Value<int> rowid,
});
typedef $$FollowsTableUpdateCompanionBuilder = FollowsCompanion Function({
  Value<String> entityId,
  Value<String> entityType,
  Value<int> rowid,
});

class $$FollowsTableFilterComposer
    extends Composer<_$AppDatabase, $FollowsTable> {
  $$FollowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FollowsTableOrderingComposer
    extends Composer<_$AppDatabase, $FollowsTable> {
  $$FollowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FollowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $FollowsTable> {
  $$FollowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );
}

class $$FollowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FollowsTable,
          Follow,
          $$FollowsTableFilterComposer,
          $$FollowsTableOrderingComposer,
          $$FollowsTableAnnotationComposer,
          $$FollowsTableCreateCompanionBuilder,
          $$FollowsTableUpdateCompanionBuilder,
          (Follow, BaseReferences<_$AppDatabase, $FollowsTable, Follow>),
          Follow,
          PrefetchHooks Function()
        > {
  $$FollowsTableTableManager(_$AppDatabase db, $FollowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FollowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FollowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FollowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> entityId = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FollowsCompanion(
                entityId: entityId,
                entityType: entityType,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String entityId,
                required String entityType,
                Value<int> rowid = const Value.absent(),
              }) => FollowsCompanion.insert(
                entityId: entityId,
                entityType: entityType,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FollowsTable, Follow>(table),
                  BaseReferences<_$AppDatabase, $FollowsTable, Follow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FollowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FollowsTable,
      Follow,
      $$FollowsTableFilterComposer,
      $$FollowsTableOrderingComposer,
      $$FollowsTableAnnotationComposer,
      $$FollowsTableCreateCompanionBuilder,
      $$FollowsTableUpdateCompanionBuilder,
      (Follow, BaseReferences<_$AppDatabase, $FollowsTable, Follow>),
      Follow,
      PrefetchHooks Function()
    >;
typedef $$PreferencesTableCreateCompanionBuilder =
    PreferencesCompanion Function({
      Value<int> id,
      Value<String?> detectedCountry,
      Value<String?> selectedCountry,
      Value<bool> bootstrapDismissed,
    });
typedef $$PreferencesTableUpdateCompanionBuilder =
    PreferencesCompanion Function({
      Value<int> id,
      Value<String?> detectedCountry,
      Value<String?> selectedCountry,
      Value<bool> bootstrapDismissed,
    });

class $$PreferencesTableFilterComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get detectedCountry => $composableBuilder(
    column: $table.detectedCountry,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get selectedCountry => $composableBuilder(
    column: $table.selectedCountry,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get bootstrapDismissed => $composableBuilder(
    column: $table.bootstrapDismissed,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PreferencesTableOrderingComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get detectedCountry => $composableBuilder(
    column: $table.detectedCountry,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get selectedCountry => $composableBuilder(
    column: $table.selectedCountry,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get bootstrapDismissed => $composableBuilder(
    column: $table.bootstrapDismissed,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PreferencesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get detectedCountry => $composableBuilder(
    column: $table.detectedCountry,
    builder: (column) => column,
  );

  GeneratedColumn<String> get selectedCountry => $composableBuilder(
    column: $table.selectedCountry,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get bootstrapDismissed => $composableBuilder(
    column: $table.bootstrapDismissed,
    builder: (column) => column,
  );
}

class $$PreferencesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PreferencesTable,
          Preference,
          $$PreferencesTableFilterComposer,
          $$PreferencesTableOrderingComposer,
          $$PreferencesTableAnnotationComposer,
          $$PreferencesTableCreateCompanionBuilder,
          $$PreferencesTableUpdateCompanionBuilder,
          (
            Preference,
            BaseReferences<_$AppDatabase, $PreferencesTable, Preference>,
          ),
          Preference,
          PrefetchHooks Function()
        > {
  $$PreferencesTableTableManager(_$AppDatabase db, $PreferencesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> detectedCountry = const Value.absent(),
                Value<String?> selectedCountry = const Value.absent(),
                Value<bool> bootstrapDismissed = const Value.absent(),
              }) => PreferencesCompanion(
                id: id,
                detectedCountry: detectedCountry,
                selectedCountry: selectedCountry,
                bootstrapDismissed: bootstrapDismissed,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> detectedCountry = const Value.absent(),
                Value<String?> selectedCountry = const Value.absent(),
                Value<bool> bootstrapDismissed = const Value.absent(),
              }) => PreferencesCompanion.insert(
                id: id,
                detectedCountry: detectedCountry,
                selectedCountry: selectedCountry,
                bootstrapDismissed: bootstrapDismissed,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PreferencesTable, Preference>(table),
                  BaseReferences<_$AppDatabase, $PreferencesTable, Preference>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PreferencesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PreferencesTable,
      Preference,
      $$PreferencesTableFilterComposer,
      $$PreferencesTableOrderingComposer,
      $$PreferencesTableAnnotationComposer,
      $$PreferencesTableCreateCompanionBuilder,
      $$PreferencesTableUpdateCompanionBuilder,
      (
        Preference,
        BaseReferences<_$AppDatabase, $PreferencesTable, Preference>,
      ),
      Preference,
      PrefetchHooks Function()
    >;
typedef $$TemporaryInterestsTableCreateCompanionBuilder =
    TemporaryInterestsCompanion Function({
      required String entityId,
      required String entityType,
      required DateTime expiresAt,
      Value<int> rowid,
    });
typedef $$TemporaryInterestsTableUpdateCompanionBuilder =
    TemporaryInterestsCompanion Function({
      Value<String> entityId,
      Value<String> entityType,
      Value<DateTime> expiresAt,
      Value<int> rowid,
    });

class $$TemporaryInterestsTableFilterComposer
    extends Composer<_$AppDatabase, $TemporaryInterestsTable> {
  $$TemporaryInterestsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TemporaryInterestsTableOrderingComposer
    extends Composer<_$AppDatabase, $TemporaryInterestsTable> {
  $$TemporaryInterestsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TemporaryInterestsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TemporaryInterestsTable> {
  $$TemporaryInterestsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$TemporaryInterestsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TemporaryInterestsTable,
          TemporaryInterest,
          $$TemporaryInterestsTableFilterComposer,
          $$TemporaryInterestsTableOrderingComposer,
          $$TemporaryInterestsTableAnnotationComposer,
          $$TemporaryInterestsTableCreateCompanionBuilder,
          $$TemporaryInterestsTableUpdateCompanionBuilder,
          (
            TemporaryInterest,
            BaseReferences<
              _$AppDatabase,
              $TemporaryInterestsTable,
              TemporaryInterest
            >,
          ),
          TemporaryInterest,
          PrefetchHooks Function()
        > {
  $$TemporaryInterestsTableTableManager(
    _$AppDatabase db,
    $TemporaryInterestsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TemporaryInterestsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TemporaryInterestsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TemporaryInterestsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> entityId = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TemporaryInterestsCompanion(
                entityId: entityId,
                entityType: entityType,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String entityId,
                required String entityType,
                required DateTime expiresAt,
                Value<int> rowid = const Value.absent(),
              }) => TemporaryInterestsCompanion.insert(
                entityId: entityId,
                entityType: entityType,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TemporaryInterestsTable, TemporaryInterest>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $TemporaryInterestsTable,
                    TemporaryInterest
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TemporaryInterestsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TemporaryInterestsTable,
      TemporaryInterest,
      $$TemporaryInterestsTableFilterComposer,
      $$TemporaryInterestsTableOrderingComposer,
      $$TemporaryInterestsTableAnnotationComposer,
      $$TemporaryInterestsTableCreateCompanionBuilder,
      $$TemporaryInterestsTableUpdateCompanionBuilder,
      (
        TemporaryInterest,
        BaseReferences<
          _$AppDatabase,
          $TemporaryInterestsTable,
          TemporaryInterest
        >,
      ),
      TemporaryInterest,
      PrefetchHooks Function()
    >;
typedef $$CalendarSnapshotsTableCreateCompanionBuilder =
    CalendarSnapshotsCompanion Function({
      required String calendarDate,
      required String payload,
      required DateTime savedAt,
      Value<int> rowid,
    });
typedef $$CalendarSnapshotsTableUpdateCompanionBuilder =
    CalendarSnapshotsCompanion Function({
      Value<String> calendarDate,
      Value<String> payload,
      Value<DateTime> savedAt,
      Value<int> rowid,
    });

class $$CalendarSnapshotsTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarSnapshotsTable> {
  $$CalendarSnapshotsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get calendarDate => $composableBuilder(
    column: $table.calendarDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalendarSnapshotsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarSnapshotsTable> {
  $$CalendarSnapshotsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get calendarDate => $composableBuilder(
    column: $table.calendarDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalendarSnapshotsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarSnapshotsTable> {
  $$CalendarSnapshotsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get calendarDate => $composableBuilder(
    column: $table.calendarDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<DateTime> get savedAt =>
      $composableBuilder(column: $table.savedAt, builder: (column) => column);
}

class $$CalendarSnapshotsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarSnapshotsTable,
          CalendarSnapshot,
          $$CalendarSnapshotsTableFilterComposer,
          $$CalendarSnapshotsTableOrderingComposer,
          $$CalendarSnapshotsTableAnnotationComposer,
          $$CalendarSnapshotsTableCreateCompanionBuilder,
          $$CalendarSnapshotsTableUpdateCompanionBuilder,
          (
            CalendarSnapshot,
            BaseReferences<
              _$AppDatabase,
              $CalendarSnapshotsTable,
              CalendarSnapshot
            >,
          ),
          CalendarSnapshot,
          PrefetchHooks Function()
        > {
  $$CalendarSnapshotsTableTableManager(
    _$AppDatabase db,
    $CalendarSnapshotsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarSnapshotsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarSnapshotsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CalendarSnapshotsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> calendarDate = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<DateTime> savedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarSnapshotsCompanion(
                calendarDate: calendarDate,
                payload: payload,
                savedAt: savedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String calendarDate,
                required String payload,
                required DateTime savedAt,
                Value<int> rowid = const Value.absent(),
              }) => CalendarSnapshotsCompanion.insert(
                calendarDate: calendarDate,
                payload: payload,
                savedAt: savedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CalendarSnapshotsTable, CalendarSnapshot>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $CalendarSnapshotsTable,
                    CalendarSnapshot
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalendarSnapshotsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarSnapshotsTable,
      CalendarSnapshot,
      $$CalendarSnapshotsTableFilterComposer,
      $$CalendarSnapshotsTableOrderingComposer,
      $$CalendarSnapshotsTableAnnotationComposer,
      $$CalendarSnapshotsTableCreateCompanionBuilder,
      $$CalendarSnapshotsTableUpdateCompanionBuilder,
      (
        CalendarSnapshot,
        BaseReferences<
          _$AppDatabase,
          $CalendarSnapshotsTable,
          CalendarSnapshot
        >,
      ),
      CalendarSnapshot,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$FollowsTableTableManager get follows =>
      $$FollowsTableTableManager(_db, _db.follows);
  $$PreferencesTableTableManager get preferences =>
      $$PreferencesTableTableManager(_db, _db.preferences);
  $$TemporaryInterestsTableTableManager get temporaryInterests =>
      $$TemporaryInterestsTableTableManager(_db, _db.temporaryInterests);
  $$CalendarSnapshotsTableTableManager get calendarSnapshots =>
      $$CalendarSnapshotsTableTableManager(_db, _db.calendarSnapshots);
}

typedef Json = Map<String, dynamic>;

String? safePlayerImage(dynamic value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri.toString()
      : null;
}

String? playerImage(Json player) {
  final media = player['media'];
  final canonical = media is Map && media['verificationStatus'] == 'VERIFIED'
      ? safePlayerImage(media['url'])
      : null;
  return canonical ?? safePlayerImage(player['image']);
}

// Costa Rica uses UTC-06:00 year-round and does not observe daylight saving.
DateTime costaRicaTime(DateTime instant) =>
    instant.toUtc().subtract(const Duration(hours: 6));

DateTime costaRicaNow() => costaRicaTime(DateTime.now());

String eventMinuteLabel(Json event) {
  final minute = event['minute'];
  if (minute is! int) return '—';
  final extra = event['extraMinute'];
  return extra is int && extra > 0 ? '$minute+$extra′' : '$minute′';
}

int _eventTypeOrder(String type) => switch (type) {
  'KICKOFF' => 0,
  'GOAL' => 1,
  'MISSED_PENALTY' => 2,
  'YELLOW_CARD' => 3,
  'RED_CARD' => 4,
  'SUBSTITUTION' => 5,
  'VAR' => 6,
  'HALFTIME' => 7,
  'FULL_TIME' => 8,
  _ => 9,
};

class Entity {
  Entity(this.json);
  final Json json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get country => json['country'] as String? ?? '';
  String? get imageUrl {
    final media = json['media'] as Json?;
    if (media == null || media['verificationStatus'] != 'VERIFIED') return null;
    return safePlayerImage(media['url']);
  }

  String get initials {
    final short = (json['shortName'] as String?)?.trim();
    if (short != null && short.isNotEmpty) return short;
    final result = name
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0])
        .join();
    return result.isEmpty ? '·' : result;
  }

  bool matches(String query) => [
    name,
    json['shortName'] ?? '',
    country,
    ...?json['aliases'] as List?,
  ].join(' ').toLowerCase().contains(query.trim().toLowerCase());
}

class LiveMatchUpdate {
  const LiveMatchUpdate({
    required this.matchId,
    required this.provider,
    required this.externalMatchId,
    required this.status,
    required this.minute,
    required this.homeScore,
    required this.awayScore,
    required this.revision,
    required this.eventCount,
    required this.changedAt,
    this.events = const [],
  });

  factory LiveMatchUpdate.fromJson(Json json) => LiveMatchUpdate(
    matchId: json['match_id'] as String,
    provider: json['provider'] as String,
    externalMatchId: json['external_match_id'] as String,
    status: json['status'] as String,
    minute: json['minute'] as int?,
    homeScore: json['home_score'] as int?,
    awayScore: json['away_score'] as int?,
    revision: (json['revision'] as num).toInt(),
    eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
    changedAt: DateTime.parse(json['changed_at'] as String),
    events: (json['latest_events'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
  );

  final String matchId, provider, externalMatchId, status;
  final int? minute, homeScore, awayScore;
  final int revision, eventCount;
  final DateTime changedAt;
  final List<Json> events;

  Json applyTo(Json match) {
    if (match['id'] != matchId) return match;

    const terminalStatuses = {
      'FINISHED_PENDING_VERIFICATION',
      'VERIFIED',
      'POSTPONED',
      'ABANDONED',
      'CANCELLED',
    };
    final canonicalStatus = match['status'] as String?;
    final provenance = match['provenance'];
    final canonicalAt = provenance is Map
        ? DateTime.tryParse(provenance['receivedAt'] as String? ?? '')
        : null;
    if (terminalStatuses.contains(canonicalStatus) &&
        canonicalAt != null &&
        !canonicalAt.isBefore(changedAt)) {
      return match;
    }

    final previousAt = DateTime.tryParse(
      match['liveChangedAt'] as String? ?? '',
    );
    if (previousAt != null && changedAt.isBefore(previousAt)) return match;
    if (match['liveProvider'] == provider &&
        (match['liveRevision'] as int? ?? 0) > revision) {
      return match;
    }
    final merged = <String, Json>{};
    for (final event in [
      ...(match['events'] as List? ?? []).cast<Json>(),
      ...events,
    ]) {
      final id = event['id'];
      if (id is! String) continue;
      if (event['matchId'] != null && event['matchId'] != matchId) continue;
      if (event['teamId'] != null &&
          ![
            match['homeTeamId'],
            match['awayTeamId'],
          ].contains(event['teamId'])) {
        continue;
      }
      merged[id] = event;
    }
    final result = Json.of(match)
      ..['events'] = merged.values.toList()
      ..['status'] = status
      ..['minute'] = minute
      ..['liveRevision'] = revision
      ..['liveProvider'] = provider
      ..['liveChangedAt'] = changedAt.toIso8601String();
    if (homeScore != null && awayScore != null) {
      result['score'] = {'home': homeScore, 'away': awayScore};
    }
    return result;
  }
}

class MatchDetail {
  MatchDetail(this.json);

  factory MatchDetail.waiting(String matchId) =>
      MatchDetail({...MatchDetail.empty(matchId).json, 'pending': true});

  factory MatchDetail.empty(String matchId) => MatchDetail({
    'matchId': matchId,
    'available': false,
    'pending': false,
    'detailLevel': 'none',
    'home': <String, dynamic>{},
    'away': <String, dynamic>{},
    'statistics': <dynamic>[],
    'incidents': <dynamic>[],
    'videos': <dynamic>[],
  });

  final Json json;

  String get matchId => json['matchId'] as String? ?? '';
  bool get available => json['available'] == true;
  bool get pending => json['pending'] == true;
  String get detailLevel => json['detailLevel'] as String? ?? 'none';
  String? get fetchedAt => json['fetchedAt'] as String?;
  String? get referee => _optional(json['referee']);
  String? get stadium => _optional(json['stadium']);
  String? get round => _optional(json['round']);
  Json? get coverage => _nullableMap(json['coverage']);
  bool get lineupEnrichmentPending =>
      coverage?['lineupEnrichmentPending'] == true;

  /// Server section state: available | pending | unavailable | missing, or
  /// null for older servers (then the global [pending] flag applies).
  String? sectionState(String section) {
    final value = coverage?[section];
    return value is String ? value : null;
  }

  /// A section is only pending while the detail as a whole is: once the
  /// bounded refresh ends (pending=false) nothing keeps spinning.
  bool _sectionPending(String section) {
    final state = sectionState(section);
    return pending && (state == null || state == 'pending');
  }

  bool get lineupPending => _sectionPending('lineup');
  bool get statisticsPending => _sectionPending('statistics');

  Json get home => _map(json['home']);
  Json get away => _map(json['away']);

  String? get homeFormation => _optional(home['formation']);
  String? get awayFormation => _optional(away['formation']);

  List<Json> get homeStarters => _maps(home['starters']);
  List<Json> get awayStarters => _maps(away['starters']);
  List<Json> get homeSubstitutes => _maps(home['substitutes']);
  List<Json> get awaySubstitutes => _maps(away['substitutes']);
  Json? get homeCoach => _nullableMap(home['coach']);
  Json? get awayCoach => _nullableMap(away['coach']);
  List<Json> get statistics => _maps(json['statistics']);
  List<Json> get incidents => _maps(json['incidents']);
  List<Json> get videos => _maps(json['videos']);

  static String? _optional(dynamic value) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? null : result;
  }

  static Json _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static Json? _nullableMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static List<Json> _maps(dynamic value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : <Json>[];
}

class FootballMatch {
  FootballMatch(this.json);
  final Json json;
  String get id => json['id'] as String;
  String get competitionId => json['competitionId'] as String;
  String get homeId => json['homeTeamId'] as String;
  String get awayId => json['awayTeamId'] as String;
  DateTime get startTime =>
      costaRicaTime(DateTime.parse(json['startTime'] as String));
  String get status => json['status'] as String;
  bool get isLive =>
      ['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES'].contains(status);
  bool get isFinished =>
      ['FINISHED_PENDING_VERIFICATION', 'VERIFIED'].contains(status);
  bool get isAwaitingUpdate =>
      ['DISCOVERED', 'SCHEDULED', 'PRE_MATCH'].contains(status) &&
      costaRicaNow().isAfter(startTime.add(const Duration(minutes: 15)));

  bool get isScheduled =>
      ['DISCOVERED', 'SCHEDULED', 'PRE_MATCH'].contains(status);
  bool get isUpcoming => isScheduled && !isAwaitingUpdate;
  bool get hasPlayedEvidence =>
      json['hasPlayedEvidence'] == true ||
      json['score'] != null ||
      events.isNotEmpty;
  bool get showKickoff =>
      isScheduled && !(isAwaitingUpdate && hasPlayedEvidence);
  String get score => json['score'] == null
      ? '—'
      : '${json['score']['home']} - ${json['score']['away']}';
  DateTime? get liveChangedAt =>
      DateTime.tryParse(json['liveChangedAt'] as String? ?? '');

  bool get liveDataStale {
    final changedAt = liveChangedAt;
    if (!isLive || changedAt == null) return false;
    return DateTime.now().toUtc().difference(changedAt.toUtc()) >
        const Duration(minutes: 15);
  }

  String get statusLabel {
    if (isAwaitingUpdate && hasPlayedEvidence) {
      return json['score'] != null ? 'Marcador parcial' : '';
    }
    return switch (status) {
      'LIVE' => "${json['minute'] ?? '—'}′ · En vivo",
      'HALFTIME' => 'Descanso',
      'EXTRA_TIME' => 'Prórroga',
      'PENALTIES' => 'Penales',
      'VERIFIED' || 'FINISHED_PENDING_VERIFICATION' => 'Finalizado',
      'POSTPONED' => 'Aplazado',
      'SUSPENDED' => 'Suspendido',
      'ABANDONED' => 'Abandonado',
      'CANCELLED' => 'Cancelado',
      'DISCOVERED' || 'SCHEDULED' || 'PRE_MATCH' => 'Programado',
      _ => 'Estado no disponible',
    };
  }

  List<Json> get events {
    final items = (json['events'] as List? ?? const []).cast<Json>().toList();
    items.sort((a, b) {
      final byMinute = (a['minute'] as int? ?? -1).compareTo(
        b['minute'] as int? ?? -1,
      );
      if (byMinute != 0) return byMinute;
      final byExtra = (a['extraMinute'] as int? ?? 0).compareTo(
        b['extraMinute'] as int? ?? 0,
      );
      if (byExtra != 0) return byExtra;
      final byType = _eventTypeOrder(a['type'] as String? ?? '')
          .compareTo(_eventTypeOrder(b['type'] as String? ?? ''));
      if (byType != 0) return byType;
      return (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? '');
    });
    return items;
  }

  Json? get latestEvent {
    if (json['latestEvent'] is Map) {
      return Map<String, dynamic>.from(json['latestEvent'] as Map);
    }
    final timeline = events;
    return timeline.isEmpty ? null : timeline.last;
  }

  // Tolerates a non-list or malformed rows instead of failing the snapshot.
  List<Json> get statistics => MatchDetail._maps(json['statistics']);
}

List<Json> mergedMatchTimeline(FootballMatch match, MatchDetail detail) {
  final detailed = <Json>[
    for (var i = 0; i < detail.incidents.length; i++)
      {
        'id':
            'detail_${detail.incidents[i]['type'] ?? 'OTHER'}_'
            '${detail.incidents[i]['minute'] ?? 'na'}_$i',
        'type': detail.incidents[i]['type'] ?? 'OTHER',
        'minute': detail.incidents[i]['minute'],
        if (detail.incidents[i]['extraMinute'] != null)
          'extraMinute': detail.incidents[i]['extraMinute'],
        if (detail.incidents[i]['label'] != null)
          'label': detail.incidents[i]['label'],
        if (detail.incidents[i]['detail'] != null)
          'detail': detail.incidents[i]['detail'],
        if (detail.incidents[i]['team'] != null)
          'team': detail.incidents[i]['team'],
        if (detail.incidents[i]['side'] != null)
          'side': detail.incidents[i]['side'],
        'detailSource': true,
      },
  ];

  final detailedMoments = {
    for (final event in detailed)
      '${event['type']}|${event['minute'] ?? -1}|${event['extraMinute'] ?? 0}',
  };

  final merged = <Json>[
    for (final event in match.events)
      if (!detailedMoments.contains(
            '${event['type']}|${event['minute'] ?? -1}|${event['extraMinute'] ?? 0}',
          ) ||
          {'KICKOFF', 'HALFTIME', 'FULL_TIME'}.contains(event['type']))
        event,
    ...detailed,
  ];

  merged.sort((a, b) {
    final byMinute = (a['minute'] as int? ?? -1).compareTo(
      b['minute'] as int? ?? -1,
    );
    if (byMinute != 0) return byMinute;
    final byExtra = (a['extraMinute'] as int? ?? 0).compareTo(
      b['extraMinute'] as int? ?? 0,
    );
    if (byExtra != 0) return byExtra;
    final byType = _eventTypeOrder(a['type'] as String? ?? '')
        .compareTo(_eventTypeOrder(b['type'] as String? ?? ''));
    if (byType != 0) return byType;
    return (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? '');
  });
  return merged;
}

class Snapshot {
  Snapshot(Json json)
    : demo = json['demo'] as bool,
      coverage = json['coverage'] as Json?,
      stale = (json['freshness'] as Json?)?['stale'] == true,
      revalidating = (json['freshness'] as Json?)?['revalidating'] == true,
      updatedAt = DateTime.parse(json['updatedAt'] as String),
      entityRedirects = (json['entityRedirects'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      teams = (json['teams'] as List).map((e) => Entity(e as Json)).toList(),
      players = (json['players'] as List)
          .map((e) => Entity(e as Json))
          .toList(),
      competitions = (json['competitions'] as List)
          .map((e) => Entity(e as Json))
          .toList(),
      matches = (json['matches'] as List)
          .map((e) => FootballMatch(e as Json))
          .toList(),
      standings = (json['standings'] as List).cast<Json>(),
      news = (json['news'] as List? ?? const []).cast<Json>(),
      transfers = (json['transfers'] as List? ?? const []).cast<Json>() {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Versión de datos incompatible');
    }

    _teamsById = {for (final entity in teams) entity.id: entity};
    _playersById = {for (final entity in players) entity.id: entity};
    _competitionsById = {for (final entity in competitions) entity.id: entity};
    // A match whose team/competition is missing cannot be rendered. Drop only
    // that match instead of failing the whole feed or profile.
    matches.removeWhere(
      (match) =>
          team(match.homeId) == null ||
          team(match.awayId) == null ||
          competition(match.competitionId) == null,
    );
    _matchesById = {for (final match in matches) match.id: match};
  }
  final bool demo;
  final Json? coverage;

  /// The server launched a remote player discovery for this search; results
  /// may grow shortly (bounded client retries).
  bool get pendingRemote => coverage?['pendingRemote'] == true;

  /// The server is still materializing this calendar day (no data yet).
  bool get calendarPending => coverage?['pending'] == true;
  int get calendarRetryAfterSeconds =>
      ((coverage?['retryAfterSeconds'] as num?)?.toInt() ?? 3).clamp(1, 30);

  /// The server is hydrating this profile; a refresh shortly shows more data.
  bool get enrichmentPending => coverage?['enrichmentPending'] == true;

  /// Match Center: the exact competition+season table is being fetched.
  bool get standingsPending => coverage?['standingsPending'] == true;
  final bool stale;
  final bool revalidating;
  final DateTime updatedAt;
  final Map<String, String> entityRedirects;
  final List<Entity> teams, players, competitions;
  final List<FootballMatch> matches;
  final List<Json> standings, news, transfers;

  late final Map<String, Entity> _teamsById;
  late final Map<String, Entity> _playersById;
  late final Map<String, Entity> _competitionsById;
  late final Map<String, FootballMatch> _matchesById;

  String resolveEntityId(String id) {
    var current = id;
    final seen = <String>{};
    for (var i = 0; i < 8 && seen.add(current); i++) {
      final next = entityRedirects[current];
      if (next == null || next.isEmpty || next == current) break;
      current = next;
    }
    return current;
  }

  Snapshot forMatch(String id) {
    final target = match(id);
    if (target == null) return this;

    final matchStandings = standings
        .where((table) => table['competitionId'] == target.competitionId)
        .toList();
    final teamIds = <String>{target.homeId, target.awayId};
    for (final table in matchStandings) {
      for (final row in (table['rows'] as List? ?? const <dynamic>[])) {
        if (row is! Map) continue;
        final teamId = row['teamId']?.toString();
        if (teamId != null && teamId.isNotEmpty) teamIds.add(teamId);
      }
    }

    final playerIds = <String>{};
    for (final event in target.events) {
      final playerId = event['playerId']?.toString();
      if (playerId != null && playerId.isNotEmpty) playerIds.add(playerId);
    }

    final contextTeams = [
      for (final team in teams)
        if (teamIds.contains(team.id)) team.json,
    ];
    final contextPlayers = [
      for (final player in players)
        if (playerIds.contains(player.id) ||
            teamIds.contains(player.json['teamId']?.toString()))
          player.json,
    ];
    final competitionEntity = competition(target.competitionId);

    return Snapshot({
      'schemaVersion': 1,
      'demo': demo,
      'coverage': coverage,
      'freshness': {'stale': stale},
      'updatedAt': updatedAt.toIso8601String(),
      'entityRedirects': entityRedirects,
      'teams': contextTeams,
      'players': contextPlayers,
      'competitions': [if (competitionEntity != null) competitionEntity.json],
      'matches': [target.json],
      'standings': matchStandings,
      'news': const <dynamic>[],
      'transfers': const <dynamic>[],
    });
  }

  Snapshot asStale() {
    return withFreshness(stale: true);
  }

  Snapshot withFreshness({bool stale = false, bool revalidating = false}) {
    return Snapshot({
      'schemaVersion': 1,
      'demo': demo,
      'coverage': coverage,
      'freshness': {'stale': stale, 'revalidating': revalidating},
      'updatedAt': updatedAt.toIso8601String(),
      'entityRedirects': entityRedirects,
      'teams': teams.map((entity) => entity.json).toList(),
      'players': players.map((entity) => entity.json).toList(),
      'competitions': competitions.map((entity) => entity.json).toList(),
      'matches': matches.map((match) => match.json).toList(),
      'standings': standings,
      'news': news,
      'transfers': transfers,
    });
  }

  Snapshot withLiveUpdates(Map<String, LiveMatchUpdate> updates) {
    if (demo || updates.isEmpty) return this;
    var changed = false;
    final mergedMatches = matches.map((match) {
      final update = updates[match.id];
      if (update == null) return match.json;
      final merged = update.applyTo(match.json);
      if (!identical(merged, match.json)) changed = true;
      return merged;
    }).toList();
    if (!changed) return this;
    return Snapshot({
      'schemaVersion': 1,
      'demo': demo,
      'coverage': coverage,
      'freshness': {'stale': stale, 'revalidating': revalidating},
      'updatedAt': updatedAt.toIso8601String(),
      'entityRedirects': entityRedirects,
      'teams': teams.map((entity) => entity.json).toList(),
      'players': players.map((entity) => entity.json).toList(),
      'competitions': competitions.map((entity) => entity.json).toList(),
      'matches': mergedMatches,
      'standings': standings,
      'news': news,
      'transfers': transfers,
    });
  }

  Entity? team(String id) => _teamsById[id];
  Entity? player(String id) => _playersById[id];
  Entity? competition(String id) => _competitionsById[id];
  FootballMatch? match(String id) => _matchesById[id];
  List<FootballMatch> onDate(DateTime date, String filter) =>
      matches
          .where(
            (m) =>
                m.startTime.year == date.year &&
                m.startTime.month == date.month &&
                m.startTime.day == date.day &&
                switch (filter) {
                  'En vivo' => m.isLive,
                  'Próximos' => m.isUpcoming,
                  'Finalizados' => m.isFinished,
                  _ => true,
                },
          )
          .toList()
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
}

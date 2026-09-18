typedef Json = Map<String, dynamic>;

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
    return media['url'] as String?;
  }

  String get initials =>
      json['shortName'] as String? ??
      name.split(' ').take(2).map((s) => s[0]).join();
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
  bool get isUpcoming =>
      ['DISCOVERED', 'SCHEDULED', 'PRE_MATCH'].contains(status);
  String get score => json['score'] == null
      ? '—'
      : '${json['score']['home']} - ${json['score']['away']}';
  String get statusLabel => switch (status) {
    'LIVE' => "${json['minute'] ?? '—'}′ · En vivo",
    'HALFTIME' => 'Descanso',
    'EXTRA_TIME' => 'Prórroga',
    'PENALTIES' => 'Penales',
    'VERIFIED' => 'Finalizado',
    'FINISHED_PENDING_VERIFICATION' => 'Final · por verificar',
    'POSTPONED' => 'Aplazado',
    'SUSPENDED' => 'Suspendido',
    'ABANDONED' => 'Abandonado',
    'CANCELLED' => 'Cancelado',
    _ => 'Próximo',
  };
  List<Json> get events {
    final items = (json['events'] as List).cast<Json>().toList();
    items.sort((a, b) {
      final byMinute = (a['minute'] as int? ?? -1).compareTo(
        b['minute'] as int? ?? -1,
      );
      if (byMinute != 0) return byMinute;
      final byExtra = (a['extraMinute'] as int? ?? 0).compareTo(
        b['extraMinute'] as int? ?? 0,
      );
      if (byExtra != 0) return byExtra;
      final byType = _eventTypeOrder(
        a['type'] as String? ?? '',
      ).compareTo(_eventTypeOrder(b['type'] as String? ?? ''));
      if (byType != 0) return byType;
      return (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? '');
    });
    return items;
  }

  Json? get latestEvent {
    final timeline = events;
    return timeline.isEmpty ? null : timeline.last;
  }

  List<Json> get statistics => (json['statistics'] as List).cast<Json>();
}

class Snapshot {
  Snapshot(Json json)
    : demo = json['demo'] as bool,
      coverage = json['coverage'] as Json?,
      stale = (json['freshness'] as Json?)?['stale'] == true,
      updatedAt = DateTime.parse(json['updatedAt'] as String),
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
      standings = (json['standings'] as List).cast<Json>() {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Versión de datos incompatible');
    }
    for (final match in matches) {
      if (team(match.homeId) == null ||
          team(match.awayId) == null ||
          competition(match.competitionId) == null) {
        throw const FormatException('Referencia de partido inválida');
      }
    }
  }
  final bool demo;
  final Json? coverage;
  final bool stale;
  final DateTime updatedAt;
  final List<Entity> teams, players, competitions;
  final List<FootballMatch> matches;
  final List<Json> standings;

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
      'freshness': {'stale': false},
      'updatedAt': updatedAt.toIso8601String(),
      'teams': teams.map((entity) => entity.json).toList(),
      'players': players.map((entity) => entity.json).toList(),
      'competitions': competitions.map((entity) => entity.json).toList(),
      'matches': mergedMatches,
      'standings': standings,
    });
  }

  Entity? team(String id) => teams.where((e) => e.id == id).firstOrNull;
  Entity? player(String id) => players.where((e) => e.id == id).firstOrNull;
  Entity? competition(String id) =>
      competitions.where((e) => e.id == id).firstOrNull;
  FootballMatch? match(String id) =>
      matches.where((e) => e.id == id).firstOrNull;
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

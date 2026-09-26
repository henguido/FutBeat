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

// Football phase of an event: kickoff, first half (incl. 45+x), halftime,
// the rest of the match, events without a minute, full time. A missing
// minute never moves a phase marker (FULL_TIME often has none).
int _timelinePhase(Json event) {
  final minute = event['minute'];
  return switch (event['type']) {
    'KICKOFF' => 0,
    'HALFTIME' => 2,
    'FULL_TIME' => 5,
    _ when minute is! int => 4,
    _ when minute <= 45 => 1,
    _ => 3,
  };
}

/// Football order: KICKOFF, first half by minute + added time, HALFTIME,
/// second half / extra time, FULL_TIME last. Provider minutes are never
/// rewritten; this is only a sort key.
int compareTimelineEvents(Json a, Json b) {
  final byPhase = _timelinePhase(a).compareTo(_timelinePhase(b));
  if (byPhase != 0) return byPhase;
  final byMinute = (a['minute'] as int? ?? 0).compareTo(
    b['minute'] as int? ?? 0,
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
}

const _phaseEvents = {'KICKOFF', 'HALFTIME', 'FULL_TIME'};
const _technicalEventCopy = 'Marcador actualizado';

bool _isSynthetic(Json event) => event['synthetic'] == true;

/// Removes internal copy: a provisional score-change goal renders as a
/// plain goal, never as "Marcador actualizado".
Json _presentable(Json event) {
  if (!_isSynthetic(event) && event['detail'] != _technicalEventCopy) {
    return event;
  }
  return Json.of(event)..remove('detail');
}

String? _eventSide(Json event, FootballMatch match) {
  final teamId = event['teamId']?.toString();
  if (teamId != null && teamId.isNotEmpty) {
    if (teamId == match.homeId) return 'home';
    if (teamId == match.awayId) return 'away';
  }
  for (final key in ['side', 'team']) {
    final raw = event[key]?.toString().trim().toLowerCase() ?? '';
    if (raw == 'home') return 'home';
    if (raw == 'away') return 'away';
  }
  return null;
}

String? _upstreamKey(Json event) {
  final key = (event['providerEventId'] ?? event['providerEventKey'])
      ?.toString()
      .trim();
  if (key == null || key.isEmpty) return null;
  // Detail rows come from GOAL; only GOAL (or unlabeled) keys are comparable.
  final provider = event['provider']?.toString();
  return provider == null || provider == 'goal_api' ? key : '$provider:$key';
}

int? _absoluteMinute(Json event) {
  final minute = event['minute'];
  if (minute is! int) return null;
  final extra = event['extraMinute'];
  return minute + (extra is int ? extra : 0);
}

bool _minutesCompatible(Json a, Json b) {
  final minute = a['minute'];
  if (minute is! int || minute != b['minute']) return false;
  final ea = a['extraMinute'], eb = b['extraMinute'];
  return ea is! int || eb is! int || ea == eb;
}

/// Same logical occurrence between two rich (non-synthetic) events.
/// [sameIdSpace] is false when comparing detail rows (provider ids) with
/// canonical events (canonical ids): player ids are then not comparable.
bool _sameRichEvent(
  Json a,
  Json b,
  FootballMatch match, {
  required bool sameIdSpace,
}) {
  if (a['type'] != b['type']) return false;
  if (a['id'] != null && a['id'] == b['id']) return true;
  if (_phaseEvents.contains(a['type'])) return false;
  final ka = _upstreamKey(a), kb = _upstreamKey(b);
  if (ka != null && kb != null) {
    if (ka == kb) return true;
    // Two upstream row ids are two occurrences; composed keys are weak.
    if (!ka.contains(':') && !kb.contains(':')) return false;
  }
  final sideA = _eventSide(a, match), sideB = _eventSide(b, match);
  if (sideA != null && sideB != null && sideA != sideB) return false;
  if (!sameIdSpace) {
    // A detail row and a canonical event are two presentations of the same
    // GOAL feed; the caller pairs them one-to-one, so this never folds two
    // events of one source together (player ids are not comparable here).
    return _minutesCompatible(a, b);
  }
  // Canonical vs canonical, conservatively (same rules as the backend):
  // type + team + minute alone never merges two real events.
  if (sideA == null || sideB == null) return false;
  final pa = a['playerId'], pb = b['playerId'];
  if (pa != null && pb != null && pa != pb) return false;
  if (a['type'] == 'SUBSTITUTION') {
    final ia = a['assistPlayerId'], ib = b['assistPlayerId'];
    if (ia != null && ib != null && ia != ib) return false;
  }
  final sa = _scoreAfter(a), sb = _scoreAfter(b);
  if (sa != null && sb != null && sa != sb) return false;
  if (pa != null && pb != null) {
    final va = _absoluteMinute(a), vb = _absoluteMinute(b);
    return _minutesCompatible(a, b) ||
        (va != null && vb != null && (va - vb).abs() <= 1);
  }
  // Without player identity on a side: only the same score after the event.
  return sa != null && sa == sb && _minutesCompatible(a, b);
}

String? _scoreAfter(Json event) {
  final score = event['score'];
  if (score is! Map) return null;
  final home = score['home'], away = score['away'];
  return home is int && away is int ? '$home-$away' : null;
}

/// Folds each synthetic GOAL into at most one rich GOAL of the same side:
/// the one whose ordinal among that side's rich goals equals the
/// synthetic's score-after-goal, within 3 minutes (closest wins).
List<Json> _foldSyntheticGoals(
  List<Json> rich,
  List<Json> synthetic,
  FootballMatch match,
) {
  final ordinal = <Json, int>{};
  for (final side in ['home', 'away']) {
    final goals =
        rich
            .where((e) => e['type'] == 'GOAL' && _eventSide(e, match) == side)
            .toList()
          ..sort(compareTimelineEvents);
    for (var i = 0; i < goals.length; i++) {
      ordinal[goals[i]] = i + 1;
    }
  }
  final absorbed = <Json>{};
  final remaining = <Json>[];
  for (final event in [...synthetic]..sort(compareTimelineEvents)) {
    final side = _eventSide(event, match);
    final score = event['score'];
    final teamGoals = score is Map && side != null ? score[side] : null;
    Json? best;
    int? bestDistance;
    for (final candidate in rich) {
      if (candidate['type'] != 'GOAL' ||
          side == null ||
          _eventSide(candidate, match) != side ||
          absorbed.contains(candidate)) {
        continue;
      }
      if (teamGoals is int && ordinal[candidate] != teamGoals) continue;
      final a = _absoluteMinute(candidate), b = _absoluteMinute(event);
      final distance = a == null || b == null ? null : (a - b).abs();
      if (!_minutesCompatible(candidate, event) &&
          !(distance != null && distance <= 3) &&
          !(distance == null && teamGoals is int)) {
        continue;
      }
      if (best == null || (distance ?? 99) < (bestDistance ?? 99)) {
        best = candidate;
        bestDistance = distance ?? 99;
      }
    }
    if (best == null) {
      remaining.add(event);
    } else {
      absorbed.add(best);
    }
  }
  return remaining;
}

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
    this.receivedAt,
  });

  /// [receivedAt] is the device time the row arrived (realtime), or the
  /// device-clock equivalent of its server-side age (REST bootstrap, see
  /// [bootstrapReceivedAt]). Never defaulted to "now": an old row fetched
  /// later must not look fresh.
  factory LiveMatchUpdate.fromJson(Json json, {DateTime? receivedAt}) =>
      LiveMatchUpdate(
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
        receivedAt: receivedAt,
      );

  /// Device-clock receipt time for a row fetched by REST: its age on the
  /// server at fetch time (server `Date` minus the row's last server update)
  /// moved onto the device clock, so device/server skew never matters.
  /// Without a server time the row counts as already stale: a LIVE REST row
  /// waits for a real realtime frame instead of comparing device and server
  /// clocks (terminal rows are never subject to staleness).
  static DateTime bootstrapReceivedAt(
    Json row, {
    required DateTime deviceNow,
    DateTime? serverNow,
  }) {
    if (serverNow == null) {
      return deviceNow.toUtc().subtract(
        staleAfter + const Duration(seconds: 1),
      );
    }
    final observed =
        DateTime.tryParse(row['updated_at'] as String? ?? '') ??
        DateTime.parse(row['changed_at'] as String);
    final age = serverNow.toUtc().difference(observed.toUtc());
    return deviceNow.toUtc().subtract(age.isNegative ? Duration.zero : age);
  }

  final String matchId, provider, externalMatchId, status;
  final int? minute, homeScore, awayScore;
  final int revision, eventCount;
  final DateTime changedAt;
  final List<Json> events;

  /// Device time this row was received (see [LiveMatchUpdate.fromJson]).
  /// Staleness is measured on the device clock only.
  final DateTime? receivedAt;

  /// Same window as the server failsafe: a LIVE row this silent is not live.
  static const staleAfter = Duration(minutes: 15);

  Json applyTo(Json match, {DateTime? now}) {
    if (match['id'] != matchId) return match;

    const terminalStatuses = {
      'FINISHED_PENDING_VERIFICATION',
      'VERIFIED',
      'POSTPONED',
      'ABANDONED',
      'CANCELLED',
    };
    // A terminal snapshot is absorbing (#120): realtime is an overlay and can
    // never downgrade or rewrite it, however late its changedAt. Corrections
    // after the final arrive as a new canonical snapshot, not through here.
    if (terminalStatuses.contains(match['status'] as String?)) return match;
    // #120: a silent LIVE overlay (missed DELETE, failed refresh) must not
    // keep a match "EN VIVO"; terminal overlays always apply.
    const liveStatuses = {'LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES'};
    if (liveStatuses.contains(status) &&
        (now ?? DateTime.now()).toUtc().difference(
              (receivedAt ?? changedAt).toUtc(),
            ) >
            staleAfter) {
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

  /// Something persisted is displayable (score, events, metadata, a partial
  /// provider observation...). It does NOT mean the detail is complete.
  bool get available => json['available'] == true;
  bool get pending => json['pending'] == true;

  /// Server-side answer to "would registering demand still help?" (fetchable,
  /// needed, nothing queued or in flight). Never inferred on the phone.
  bool get hydrationNeeded => json['hydrationNeeded'] == true;
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

  /// #99 "Jugador del partido" / "Mejores puntuados": every player from the
  /// four lineup lists whose rating is a real, positive number, deduplicated
  /// by canonical id (falling back to name+side) and sorted deterministically
  /// (rating desc, then name asc, then side asc). Never invents a rating.
  List<({Json player, String side})> topRated({int limit = 3}) {
    final entries =
        <({Json player, String side})>[
          for (final player in homeStarters) (player: player, side: 'home'),
          for (final player in homeSubstitutes) (player: player, side: 'home'),
          for (final player in awayStarters) (player: player, side: 'away'),
          for (final player in awaySubstitutes) (player: player, side: 'away'),
        ].where((entry) {
          final rating = entry.player['rating'];
          return rating is num && rating > 0;
        }).toList();

    final seen = <String>{};
    final deduped = <({Json player, String side})>[];
    for (final entry in entries) {
      final canonicalId = entry.player['canonicalId']?.toString();
      final key = canonicalId != null && canonicalId.isNotEmpty
          ? 'id:$canonicalId'
          : 'name:${entry.player['name']}|${entry.side}';
      if (seen.add(key)) deduped.add(entry);
    }

    deduped.sort((a, b) {
      final ratingA = (a.player['rating'] as num).toDouble();
      final ratingB = (b.player['rating'] as num).toDouble();
      if (ratingA != ratingB) return ratingB.compareTo(ratingA);
      final nameA = a.player['name']?.toString() ?? '';
      final nameB = b.player['name']?.toString() ?? '';
      final nameCompare = nameA.compareTo(nameB);
      if (nameCompare != 0) return nameCompare;
      return a.side.compareTo(b.side);
    });

    return deduped.take(limit).toList();
  }

  /// The single standout, only when their rating strictly beats the runner
  /// up's; a tie at the top means no individual player of the match.
  ({Json player, String side})? get playerOfTheMatch {
    final top = topRated(limit: 2);
    if (top.isEmpty) return null;
    if (top.length == 1) return top.first;
    final first = (top.first.player['rating'] as num).toDouble();
    final second = (top[1].player['rating'] as num).toDouble();
    return first > second ? top.first : null;
  }

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
    final items = (json['events'] as List? ?? const [])
        .cast<Json>()
        .map(_presentable)
        .toList();
    items.sort(compareTimelineEvents);
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

/// Match Center timeline: canonical events (already deduplicated by the
/// backend) merged with Match Detail incidents. Final presentation guard,
/// not the authority: detail rows win over their canonical twin (same
/// upstream id, or same type/side/minute), synthetic goals fold into the
/// rich goal they stand for, and two rich events with different players
/// are never collapsed.
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
        if (detail.incidents[i]['providerEventId'] != null)
          'providerEventId': detail.incidents[i]['providerEventId'],
        // Structured provider names/ids (#99), never inferred.
        for (final key in const [
          'playerName',
          'assistName',
          'playerId',
          'assistPlayerId',
        ])
          if (detail.incidents[i][key] != null) key: detail.incidents[i][key],
        'detailSource': true,
      },
  ];

  final phases = <Json>[];
  final synthetic = <Json>[];
  final canonical = <Json>[];
  // Strongest canonical evidence first: identified player, then minute.
  final ordered = [...match.events]
    ..sort((a, b) {
      final byPlayer = (a['playerId'] == null ? 1 : 0).compareTo(
        b['playerId'] == null ? 1 : 0,
      );
      return byPlayer != 0 ? byPlayer : compareTimelineEvents(a, b);
    });
  for (final event in ordered) {
    if (_phaseEvents.contains(event['type'])) {
      if (!phases.any((e) => e['type'] == event['type'])) phases.add(event);
    } else if (_isSynthetic(event)) {
      synthetic.add(event);
    } else if (!canonical.any(
      (kept) => _sameRichEvent(kept, event, match, sameIdSpace: true),
    )) {
      canonical.add(event);
    }
  }

  // Each detail row replaces at most one canonical twin (one-to-one).
  final replaced = <Json>{};
  for (final row in detailed) {
    for (final event in canonical) {
      if (!replaced.contains(event) &&
          _sameRichEvent(row, event, match, sameIdSpace: false)) {
        replaced.add(event);
        break;
      }
    }
  }
  final rich = [
    ...canonical.where((event) => !replaced.contains(event)),
    ...detailed,
  ];

  final merged = <Json>[
    ...phases,
    ...rich,
    ..._foldSyntheticGoals(rich, synthetic, match).map(_presentable),
  ]..sort(compareTimelineEvents);
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

  /// Match Center: server-side table state for the exact competition+season,
  /// one of available | pending | unavailable | missing (null when unknown).
  String? get standingsState => coverage?['standings'] as String?;

  /// Match Center: the exact table shown is older than its freshness window.
  bool get standingsStale => coverage?['standingsStale'] == true;
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

  Snapshot withLiveUpdates(
    Map<String, LiveMatchUpdate> updates, {
    DateTime? now,
  }) {
    if (demo || updates.isEmpty) return this;
    var changed = false;
    final mergedMatches = matches.map((match) {
      final update = updates[match.id];
      if (update == null) return match.json;
      final merged = update.applyTo(match.json, now: now);
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

/// Result of a finished match from one team's perspective.
enum TeamResult { win, draw, loss }

/// WIN/DRAW/LOSS for [teamId] in a compact match (`homeTeamId`,
/// `awayTeamId`, `score.home/away`), by canonical id only. Null without a
/// complete score or when the team did not play it: never a guessed result.
TeamResult? teamMatchResult(Json match, String teamId) {
  final score = match['score'];
  if (score is! Map) return null;
  final home = score['home'];
  final away = score['away'];
  if (home is! num || away is! num) return null;
  final (own, other) = match['homeTeamId'] == teamId
      ? (home, away)
      : match['awayTeamId'] == teamId
      ? (away, home)
      : (null, null);
  if (own == null || other == null) return null;
  return own > other
      ? TeamResult.win
      : own == other
      ? TeamResult.draw
      : TeamResult.loss;
}

/// Recent form + head-to-head of one match (`/v1/match-preview`), separate
/// from the match context and from [MatchDetail]. States are `available`,
/// `partial` (form only) or `none`: nothing here is ever "pending".
class MatchPreview {
  MatchPreview(this.json) {
    for (final item in _list('matches')) {
      final id = item['matchId'];
      if (id is String) _matches[id] = item;
    }
    for (final item in _list('teams')) {
      final id = item['id'];
      if (id is String && item['name'] is String) _teams[id] = Entity(item);
    }
    for (final item in _list('competitions')) {
      final id = item['id'];
      if (id is String && item['name'] is String) _competitions[id] = item;
    }
  }

  factory MatchPreview.empty(String matchId) =>
      MatchPreview({'schemaVersion': 1, 'matchId': matchId});

  final Json json;
  final Map<String, Json> _matches = {};
  final Map<String, Entity> _teams = {};
  final Map<String, Json> _competitions = {};

  List<Json> _list(String key) => [
    for (final item in json[key] as List? ?? const [])
      if (item is Map) Map<String, dynamic>.from(item),
  ];

  Json _section(String path) {
    Object? node = json;
    for (final key in path.split('.')) {
      node = node is Map ? node[key] : null;
    }
    return node is Map ? Map<String, dynamic>.from(node) : <String, dynamic>{};
  }

  List<Json> _matchesOf(Json section) => [
    for (final id in section['matchIds'] as List? ?? const [])
      if (_matches[id] != null) _matches[id]!,
  ];

  /// `home` or `away` side of the selected match.
  String formState(String side) =>
      _section('form.$side')['state'] as String? ?? 'none';

  /// Newest first, as served.
  List<Json> formMatches(String side) => _matchesOf(_section('form.$side'));

  String get h2hState => _section('h2h')['state'] as String? ?? 'none';

  /// Newest first, at most 5.
  List<Json> get h2hMatches => _matchesOf(_section('h2h'));

  Entity? team(String? id) => id == null ? null : _teams[id];
  String? competitionName(String? id) =>
      id == null ? null : _competitions[id]?['name'] as String?;
}

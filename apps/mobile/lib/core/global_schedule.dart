import 'package:dio/dio.dart';

import 'models.dart';

class GlobalScheduleClient {
  GlobalScheduleClient(this.primary, this.fallback);

  final Dio primary;
  final Dio fallback;

  Future<List<Json>> loadDates(Iterable<DateTime> dates) async {
    final events = <Json>[];
    Object? lastError;
    var successfulDates = 0;

    for (final date in dates) {
      try {
        events.addAll(await _loadDate(primary, date));
        successfulDates++;
      } catch (error) {
        lastError = error;
        try {
          events.addAll(await _loadDate(fallback, date));
          successfulDates++;
        } catch (fallbackError) {
          lastError = fallbackError;
        }
      }
    }

    if (successfulDates == 0) {
      throw StateError('Global schedule unavailable: $lastError');
    }
    return events;
  }

  Future<List<Json>> _loadDate(Dio dio, DateTime date) async {
    final day =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final response = await dio.get<Json>('/sport/football/scheduled-events/$day');
    final raw = response.data?['events'];
    if (raw is! List) {
      throw const FormatException('Global schedule returned invalid events');
    }
    return raw
        .whereType<Map>()
        .map((event) => Map<String, dynamic>.from(event))
        .toList();
  }
}

class GlobalScheduleRepository implements FootballRepository {
  GlobalScheduleRepository(this.base, this.schedule);

  final FootballRepository base;
  final GlobalScheduleClient schedule;

  @override
  Future<Snapshot> load() async {
    final baseSnapshot = await base.load();
    final today = DateUtilsOnly.dateOnly(costaRicaNow());
    final dates = [
      today.subtract(const Duration(days: 1)),
      today,
      today.add(const Duration(days: 1)),
    ];

    try {
      final events = await schedule.loadDates(dates);
      if (events.isEmpty) return baseSnapshot;
      return mergeGlobalSchedule(
        baseSnapshot,
        events,
        DateTime.now().toUtc(),
      );
    } catch (_) {
      // The global feed is a beta fallback. The canonical FutBeat snapshot
      // remains usable if the upstream endpoint is unavailable or rate-limited.
      return baseSnapshot;
    }
  }
}

/// Tiny date helper kept independent from Flutter's DateUtils so this merger
/// can be unit-tested without widget bindings.
abstract final class DateUtilsOnly {
  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

Snapshot mergeGlobalSchedule(
  Snapshot base,
  List<Json> events,
  DateTime receivedAt,
) {
  final competitions = <String, Json>{
    for (final entity in base.competitions) entity.id: Json.of(entity.json),
  };
  final teams = <String, Json>{
    for (final entity in base.teams) entity.id: Json.of(entity.json),
  };
  final matches = <String, Json>{
    for (final match in base.matches) match.id: Json.of(match.json),
  };

  final teamIndex = _UniqueIdentityIndex(base.teams);
  final competitionIndex = _UniqueIdentityIndex(base.competitions);

  String resolveTeam(Json team, String fallbackCountry, String competitionId) {
    final providerId = _providerId(team['id']);
    final name = _requiredName(team['name'], 'team');
    final country =
        _nestedString(team, const ['country', 'name']) ?? fallbackCountry;
    final shortName = (team['nameCode'] ?? team['shortName'])?.toString() ?? '';

    final canonical =
        teamIndex.find(name, country, shortName: shortName) ??
        'sofa_team_$providerId';

    final candidate = <String, dynamic>{
      'id': canonical,
      'name': name,
      'shortName': shortName,
      'country': country,
      'competitionId': competitionId,
      'aliases': <String>[],
      'media': _providerMedia(
        'https://img.sofascore.com/api/v1/team/$providerId/image',
        receivedAt,
        'TEAM_LOGO',
      ),
    };

    final existing = teams[canonical];
    if (existing == null) {
      teams[canonical] = candidate;
    } else {
      teams[canonical] = _enrichEntity(existing, candidate);
    }
    return canonical;
  }

  String resolveCompetition(Json tournament) {
    final uniqueTournament = _json(tournament['uniqueTournament']);
    final source = uniqueTournament ?? tournament;
    final providerId = _providerId(source['id']);
    final name = _requiredName(source['name'] ?? tournament['name'], 'competition');
    final category = _json(tournament['category']);
    final country = (category?['name'] ?? '').toString();

    final canonical =
        competitionIndex.find(name, country) ?? 'sofa_comp_$providerId';

    final candidate = <String, dynamic>{
      'id': canonical,
      'name': name,
      'country': country,
      'season': '',
      'media': uniqueTournament == null
          ? null
          : _providerMedia(
              'https://img.sofascore.com/api/v1/unique-tournament/$providerId/image',
              receivedAt,
              'COMPETITION_LOGO',
            ),
    };
    final existing = competitions[canonical];
    if (existing == null) {
      competitions[canonical] = candidate;
    } else {
      competitions[canonical] = _enrichEntity(existing, candidate);
    }
    return canonical;
  }

  final existingFixtureKeys = <String, String>{};
  for (final match in base.matches) {
    existingFixtureKeys[_fixtureKey(match.homeId, match.awayId, match.startTime)] =
        match.id;
  }

  for (final event in events) {
    final eventId = _providerId(event['id']);
    final tournament = _json(event['tournament']);
    final home = _json(event['homeTeam']);
    final away = _json(event['awayTeam']);
    final timestamp = event['startTimestamp'];

    if (tournament == null ||
        home == null ||
        away == null ||
        timestamp is! num) {
      continue;
    }

    final competitionId = resolveCompetition(tournament);
    final category = _json(tournament['category']);
    final fallbackCountry = (category?['name'] ?? '').toString();
    final homeId = resolveTeam(home, fallbackCountry, competitionId);
    final awayId = resolveTeam(away, fallbackCountry, competitionId);
    final startUtc = DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt() * 1000,
      isUtc: true,
    );
    final localStart = costaRicaTime(startUtc);
    final duplicateKey = _fixtureKey(homeId, awayId, localStart);
    if (existingFixtureKeys.containsKey(duplicateKey)) {
      continue;
    }

    final status = _status(event);
    final homeScore = _score(_json(event['homeScore']));
    final awayScore = _score(_json(event['awayScore']));
    final score = homeScore != null && awayScore != null
        ? {'home': homeScore, 'away': awayScore}
        : null;

    final id = 'sofa_match_$eventId';
    matches[id] = {
      'id': id,
      'competitionId': competitionId,
      'season': '',
      'homeTeamId': homeId,
      'awayTeamId': awayId,
      'startTime': startUtc.toIso8601String(),
      'status': status,
      'score': score,
      'minute': null,
      'venue': _venue(event),
      'events': <dynamic>[],
      'statistics': <dynamic>[],
      'provenance': {
        'source': 'SofaScore',
        'externalId': eventId,
        'receivedAt': receivedAt.toIso8601String(),
        'verificationStatus': 'PROVISIONAL',
      },
    };
    existingFixtureKeys[duplicateKey] = id;
  }

  final sources = <String>{
    ...?((base.coverage?['sources'] as List?)?.map((item) => item.toString())),
    if (base.coverage?['source'] != null) base.coverage!['source'].toString(),
    'SofaScore',
  };

  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': receivedAt.toIso8601String(),
    'coverage': {
      'source': 'FutBeat Global Beta',
      'partial': true,
      'live': base.coverage?['live'] == true,
      'developmentOnly': true,
      'description':
          'Calendario global dinámico por fecha; los favoritos solo cambian el orden.',
      'sources': sources.toList(),
    },
    'freshness': {'stale': false},
    'competitions': competitions.values.toList(),
    'teams': teams.values.toList(),
    'players': base.players.map((entity) => entity.json).toList(),
    'matches': matches.values.toList(),
    'standings': base.standings,
  });
}

Json? _json(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

String _providerId(Object? value) {
  final id = value?.toString().trim() ?? '';
  if (id.isEmpty || !RegExp(r'^\d+$').hasMatch(id)) {
    throw const FormatException('Invalid global provider id');
  }
  return id;
}

String _requiredName(Object? value, String kind) {
  final name = value?.toString().trim() ?? '';
  if (name.isEmpty) throw FormatException('Missing global $kind name');
  return name;
}

String? _nestedString(Json value, List<String> path) {
  Object? current = value;
  for (final key in path) {
    final map = _json(current);
    if (map == null) return null;
    current = map[key];
  }
  final result = current?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

Json _providerMedia(
  String url,
  DateTime receivedAt,
  String kind,
) =>
    {
      'url': url,
      'kind': kind,
      'source': 'SofaScore',
      'receivedAt': receivedAt.toIso8601String(),
      'verificationStatus': 'VERIFIED',
      'rightsStatus': 'REVIEW_REQUIRED',
      'usageScope': 'DEVELOPMENT_ONLY',
    };

Json _enrichEntity(Json existing, Json candidate) {
  final result = Json.of(existing);
  if ((result['media'] == null) && candidate['media'] != null) {
    result['media'] = candidate['media'];
  }
  final existingAliases = (result['aliases'] as List? ?? [])
      .map((item) => item.toString())
      .toSet();
  final candidateName = candidate['name']?.toString();
  if (candidateName != null &&
      candidateName.isNotEmpty &&
      candidateName != result['name']) {
    existingAliases.add(candidateName);
  }
  result['aliases'] = existingAliases.toList();
  return result;
}

String _status(Json event) {
  final status = _json(event['status']);
  final type = (status?['type'] ?? '').toString().toLowerCase();
  final description = (status?['description'] ?? '').toString().toLowerCase();

  if (type == 'inprogress') {
    if (description.contains('half') || description.contains('interval')) {
      return 'HALFTIME';
    }
    return 'LIVE';
  }
  return switch (type) {
    'finished' => 'VERIFIED',
    'postponed' => 'POSTPONED',
    'canceled' || 'cancelled' => 'CANCELLED',
    'suspended' => 'SUSPENDED',
    _ => 'SCHEDULED',
  };
}

int? _score(Json? score) {
  final value = score?['current'];
  return value is num ? value.toInt() : null;
}

String _venue(Json event) {
  final venue = _json(event['venue']);
  if (venue == null) return '';
  final stadium = _json(venue['stadium']);
  return (stadium?['name'] ?? venue['name'] ?? '').toString();
}

String _fixtureKey(String home, String away, DateTime localStart) {
  final bucket = localStart.millisecondsSinceEpoch ~/ const Duration(minutes: 5).inMilliseconds;
  return '$home|$away|$bucket';
}

String _identity(String value) {
  var normalized = value.trim().toLowerCase();
  const replacements = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
  };
  replacements.forEach((from, to) {
    normalized = normalized.replaceAll(from, to);
  });
  return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

class _UniqueIdentityIndex {
  _UniqueIdentityIndex(List<Entity> entities) {
    for (final entity in entities) {
      final names = <String>{
        entity.name,
        if ((entity.json['shortName'] ?? '').toString().trim().isNotEmpty)
          entity.json['shortName'].toString(),
        ...?((entity.json['aliases'] as List?)?.map((item) => item.toString())),
      };
      for (final name in names) {
        _add(_key(name, entity.country), entity.id);
        _add(_identity(name), entity.id);
      }
    }
  }

  final Map<String, Set<String>> _ids = {};

  void _add(String key, String id) {
    if (key.isEmpty) return;
    (_ids[key] ??= <String>{}).add(id);
  }

  String? find(String name, String country, {String shortName = ''}) {
    for (final key in [
      _key(name, country),
      if (shortName.trim().isNotEmpty) _key(shortName, country),
      _identity(name),
      if (shortName.trim().isNotEmpty) _identity(shortName),
    ]) {
      final values = _ids[key];
      if (values != null && values.length == 1) return values.single;
    }
    return null;
  }

  String _key(String name, String country) =>
      '${_identity(name)}|${_identity(country)}';
}

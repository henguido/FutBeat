import 'models.dart';

String _fold(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('á', 'a')
    .replaceAll('é', 'e')
    .replaceAll('í', 'i')
    .replaceAll('ó', 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ü', 'u')
    .replaceAll('ñ', 'n');

bool entityMatchesCountry(Entity entity, String? countryCode) {
  final code = countryCode?.trim().toUpperCase();
  if (code == null || code.isEmpty) return false;
  final canonicalCode = entity.json['countryCode']?.toString().toUpperCase();
  if (canonicalCode != null && canonicalCode.isNotEmpty) {
    return canonicalCode == code ||
        (code == 'GB' && canonicalCode.startsWith('GB-'));
  }
  return entity.country.trim().toUpperCase() == code;
}

int competitionImportance(Entity competition) {
  final supplied = competition.json['relevanceScore'];
  if (supplied is num) {
    return supplied.round().clamp(0, 1000).toInt();
  }
  // Older cached snapshots may not have canonical relevance yet. Keep their
  // order deterministic without rebuilding the editorial catalogue in Flutter.
  return 100;
}

enum CompetitionFeedCategory {
  pinned,
  domesticPrimary,
  globalRelevance,
  domesticSecondary,
  other,
}

bool isPrimaryDomesticCompetition(Entity competition) =>
    competition.json['isPrimaryDomestic'] == true ||
    competition.json['domesticTier'] == 1;

CompetitionFeedCategory competitionFeedCategory(
  Entity competition, {
  required Set<String> follows,
  String? userCountry,
}) {
  if (follows.contains('competition:${competition.id}')) {
    return CompetitionFeedCategory.pinned;
  }
  final domestic = entityMatchesCountry(competition, userCountry);
  if (domestic && isPrimaryDomesticCompetition(competition)) {
    return CompetitionFeedCategory.domesticPrimary;
  }
  if (competition.json['isGlobalRelevant'] == true) {
    return CompetitionFeedCategory.globalRelevance;
  }
  if (domestic) return CompetitionFeedCategory.domesticSecondary;
  return CompetitionFeedCategory.other;
}

int _queryScore(Entity entity, String query) {
  final q = _fold(query);
  if (q.isEmpty) return 0;

  final name = _fold(entity.name);
  final shortName = _fold(entity.json['shortName']?.toString() ?? '');
  final aliases = (entity.json['aliases'] as List? ?? const <dynamic>[])
      .map((value) => _fold(value.toString()))
      .where((value) => value.isNotEmpty)
      .toList();

  if (name == q || shortName == q || aliases.contains(q)) return 1000;
  if (name.startsWith(q) || shortName.startsWith(q)) return 820;
  if (aliases.any((value) => value.startsWith(q))) return 790;
  if (name.contains(q) || shortName.contains(q)) return 620;
  if (aliases.any((value) => value.contains(q))) return 600;
  if (_fold(entity.country).contains(q)) return 320;
  return -1;
}

Entity? _contextCompetition(Snapshot data, Entity entity, String type) {
  if (type == 'competition') return entity;
  if (type == 'team') {
    final id = entity.json['competitionId']?.toString();
    return id == null ? null : data.competition(id);
  }
  if (type == 'player') {
    final teamId = entity.json['teamId']?.toString();
    final team = teamId == null ? null : data.team(teamId);
    final competitionId = team?.json['competitionId']?.toString();
    return competitionId == null ? null : data.competition(competitionId);
  }
  return null;
}

List<Entity> rankSearchEntities({
  required Snapshot data,
  required Iterable<Entity> entities,
  required String type,
  required String query,
  required Set<String> follows,
  String? userCountry,
  int? limit,
}) {
  final trimmed = query.trim();
  final scored = <(Entity, int)>[];

  for (final entity in entities) {
    final queryScore = _queryScore(entity, trimmed);
    if (trimmed.isNotEmpty && queryScore < 0) continue;

    var score = queryScore * 100;
    if (follows.contains('$type:${entity.id}')) score += 6000;
    if (entityMatchesCountry(entity, userCountry)) {
      score += trimmed.isEmpty ? 2200 : 1500;
    }

    final competition = _contextCompetition(data, entity, type);
    if (competition != null) {
      final importance = competitionImportance(competition);
      score += type == 'competition' ? importance : importance ~/ 2;
    }

    scored.add((entity, score));
  }

  scored.sort((left, right) {
    final byScore = right.$2.compareTo(left.$2);
    if (byScore != 0) return byScore;
    final byName = left.$1.name.toLowerCase().compareTo(
      right.$1.name.toLowerCase(),
    );
    return byName != 0 ? byName : left.$1.id.compareTo(right.$1.id);
  });

  final values = scored.map((entry) => entry.$1).toList();
  if (limit == null || values.length <= limit) return values;
  return values.take(limit).toList();
}

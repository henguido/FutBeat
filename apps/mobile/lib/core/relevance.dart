import 'countries.dart';
import 'models.dart';

/// Visible Spanish country/region label of an entity, or null (never a raw
/// provider code). See [countryLabel].
String? entityCountryLabel(Entity entity) =>
    countryLabel(entity.json['countryCode']?.toString(), entity.country);

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

/// Position of a [CompetitionFeedCategory] in the Partidos order (pins of the
/// personalized mode come before, as rank 0).
int competitionFeedRank(CompetitionFeedCategory category) => switch (category) {
  CompetitionFeedCategory.pinned => 1,
  CompetitionFeedCategory.domesticPrimary => 2,
  CompetitionFeedCategory.globalRelevance => 3,
  CompetitionFeedCategory.domesticSecondary => 4,
  CompetitionFeedCategory.other => 5,
};

/// The single country-aware competition order shared by the Partidos feed and
/// the onboarding suggestions: [pins] (id -> position) first, then
/// [competitionFeedRank]; inside a group editorial relevance, name, id.
List<Entity> sortCompetitionsByFeedPriority(
  Iterable<Entity> competitions, {
  required Set<String> follows,
  String? userCountry,
  Map<String, int> pins = const <String, int>{},
}) {
  // Decorate once: the comparator never re-reads the editorial fields.
  final decorated = [
    for (final competition in competitions)
      (
        competition: competition,
        rank: pins.containsKey(competition.id)
            ? 0
            : competitionFeedRank(
                competitionFeedCategory(
                  competition,
                  follows: follows,
                  userCountry: userCountry,
                ),
              ),
        relevance: competitionImportance(competition),
        name: competition.name.toLowerCase(),
      ),
  ];
  decorated.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    if (a.rank == 0) {
      return pins[a.competition.id]!.compareTo(pins[b.competition.id]!);
    }
    final byRelevance = b.relevance.compareTo(a.relevance);
    if (byRelevance != 0) return byRelevance;
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.competition.id.compareTo(b.competition.id);
  });
  return [for (final item in decorated) item.competition];
}

/// Team suggestions for a country, in the same spirit as the feed order:
///   1. the country's national team;
///   2. clubs of the country's primary domestic competition;
///   3. other teams of the country;
///   4. teams of globally relevant competitions;
///   5. everything else.
/// [competitions] resolves a team's `competitionId` (the catalog it came
/// with). Inside a group the incoming order is kept (the server already
/// orders by activity and relevance), so this only lifts local entries and
/// never drops one.
List<Entity> rankCountryTeams(
  Iterable<Entity> teams, {
  required String? userCountry,
  Entity? Function(String id)? competitions,
}) {
  final decorated = <(Entity, int, int)>[];
  var index = 0;
  for (final team in teams) {
    final competitionId = team.json['competitionId']?.toString();
    final competition = competitionId == null
        ? null
        : competitions?.call(competitionId);
    final local = entityMatchesCountry(team, userCountry);
    final national = team.json['isNationalTeam'] == true;
    final int group;
    if (local && national) {
      group = 1;
    } else if (local &&
        (team.json['isPrimaryDomesticClub'] == true ||
            (competition != null &&
                entityMatchesCountry(competition, userCountry) &&
                isPrimaryDomesticCompetition(competition)))) {
      group = 2;
    } else if (local) {
      group = 3;
    } else if (competition?.json['isGlobalRelevant'] == true ||
        team.json['isGlobalRelevant'] == true) {
      group = 4;
    } else {
      group = 5;
    }
    decorated.add((team, group, index++));
  }
  decorated.sort((a, b) {
    final byGroup = a.$2.compareTo(b.$2);
    return byGroup != 0 ? byGroup : a.$3.compareTo(b.$3);
  });
  return [for (final item in decorated) item.$1];
}

int _queryScore(Entity entity, String query) {
  final q = _fold(query);
  if (q.isEmpty) return 0;

  final name = _fold(entity.name);
  final shortName = _fold(entity.json['shortName']?.toString() ?? '');
  final aliases =
      [
            ...(entity.json['aliases'] as List? ?? const <dynamic>[]),
            // A national team is also found by its visible (Spanish) name.
            if (entity.displayName != entity.name) entity.displayName,
          ]
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
    final byName = left.$1.displayName.toLowerCase().compareTo(
      right.$1.displayName.toLowerCase(),
    );
    return byName != 0 ? byName : left.$1.id.compareTo(right.$1.id);
  });

  final values = scored.map((entry) => entry.$1).toList();
  if (limit == null || values.length <= limit) return values;
  return values.take(limit).toList();
}

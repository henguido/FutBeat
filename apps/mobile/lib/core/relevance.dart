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

const _countryAliases = <String, List<String>>{
  'CR': ['costa rica'],
  'MX': ['mexico'],
  'AR': ['argentina'],
  'BR': ['brazil', 'brasil'],
  'ES': ['spain', 'espana'],
  'US': ['united states', 'usa', 'estados unidos'],
  'GB': [
    'england',
    'scotland',
    'wales',
    'northern ireland',
    'united kingdom',
    'great britain',
  ],
  'DE': ['germany', 'alemania'],
  'IT': ['italy', 'italia'],
  'FR': ['france', 'francia'],
  'PT': ['portugal'],
  'NL': ['netherlands', 'holanda'],
};

bool entityMatchesCountry(Entity entity, String? countryCode) {
  final code = countryCode?.trim().toUpperCase();
  if (code == null || code.isEmpty) return false;
  final country = _fold(entity.country);
  if (country == _fold(code)) return true;
  return (_countryAliases[code] ?? const <String>[])
      .map(_fold)
      .contains(country);
}

bool _containsAny(String value, Iterable<String> patterns) =>
    patterns.any((pattern) => value.contains(pattern));

int competitionImportance(Entity competition) {
  final supplied = competition.json['relevanceScore'];
  if (supplied is num) {
    return supplied.round().clamp(0, 1000).toInt();
  }

  final name = _fold(competition.name);
  final country = _fold(competition.country);

  if (_containsAny(name, ['club world cup', 'fifa world cup'])) return 1000;
  if (name.contains('uefa champions league')) return 970;
  if (name.contains('copa libertadores')) return 950;
  if (country == 'england' && name == 'premier league') return 930;
  if (country == 'spain' && _containsAny(name, ['laliga', 'la liga'])) {
    return 920;
  }
  if (country == 'italy' && name == 'serie a') return 910;
  if (country == 'germany' && name == 'bundesliga') return 900;
  if (country == 'france' && name == 'ligue 1') return 890;
  if (name.contains('uefa europa league')) return 880;
  if (name.contains('copa sudamericana')) return 860;
  if (name.contains('uefa conference league')) return 830;
  if (_containsAny(name, ['brasileirao', 'brasileirão'])) return 820;
  if (country == 'argentina' &&
      _containsAny(name, ['liga profesional', 'primera division'])) {
    return 810;
  }
  if (country == 'mexico' && _containsAny(name, ['liga mx', 'liga bbva'])) {
    return 800;
  }
  if (country == 'portugal' && name.contains('primeira liga')) return 790;
  if (country == 'netherlands' && name.contains('eredivisie')) return 780;
  if (_containsAny(name, ['major league soccer', 'mls'])) return 770;
  if (_containsAny(name, [
    'concacaf champions cup',
    'concacaf champions league',
  ])) {
    return 760;
  }
  if (_containsAny(name, ['copa del rey', 'fa cup'])) return 750;
  if (_containsAny(name, ['coppa italia', 'dfb pokal'])) return 730;
  if (name.contains('central american cup')) return 700;
  if (country == 'costa rica' &&
      _containsAny(name, ['liga promerica', 'primera division'])) {
    return 660;
  }

  if (_containsAny(name, ['friendly', 'amistoso'])) return 40;
  if (_containsAny(name, ['premier league', 'primera division', 'serie a'])) {
    return 480;
  }
  if (_containsAny(name, ['cup', 'copa', 'league', 'liga'])) return 260;
  return 100;
}

int competitionFeedScore(
  Entity competition, {
  required Set<String> follows,
  required Set<String> temporaryInterests,
  String? userCountry,
}) {
  var score = competitionImportance(competition) * 10;
  // Keep the groups strict: explicit follows, selected country, relevance.
  // The largest relevance contribution is 10,000, so this bonus always makes
  // the selected country visibly move without filtering any competition.
  if (entityMatchesCountry(competition, userCountry)) score += 20000;
  if (temporaryInterests.contains('competition:${competition.id}')) {
    score += 90000;
  }
  if (follows.contains('competition:${competition.id}')) score += 100000;
  return score;
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

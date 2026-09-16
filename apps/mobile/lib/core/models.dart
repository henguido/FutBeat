typedef Json = Map<String, dynamic>;

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

class FootballMatch {
  FootballMatch(this.json);
  final Json json;
  String get id => json['id'] as String;
  String get competitionId => json['competitionId'] as String;
  String get homeId => json['homeTeamId'] as String;
  String get awayId => json['awayTeamId'] as String;
  DateTime get startTime =>
      DateTime.parse(json['startTime'] as String).toLocal();
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
  List<Json> get events =>
      (json['events'] as List).cast<Json>().toList()
        ..sort((a, b) => (a['minute'] as int).compareTo(b['minute'] as int));
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

import 'models.dart';

bool lastLineupsEligible(FootballMatch match) => const {
  'SCHEDULED',
  'TIMED',
  'POSTPONED',
  'NOT_STARTED',
}.contains(match.status);
bool hasCurrentLineup(MatchDetail detail) =>
    detail.sectionState('lineup') == 'available' ||
    detail.homeStarters.isNotEmpty ||
    detail.awayStarters.isNotEmpty ||
    detail.homeSubstitutes.isNotEmpty ||
    detail.awaySubstitutes.isNotEmpty;

class LastConfirmedLineups {
  const LastConfirmedLineups(this.json, {this.offline = false});
  factory LastConfirmedLineups.parse(
    Json raw,
    String requestedId, {
    bool offline = false,
  }) {
    if (raw['schemaVersion'] != 1 ||
        raw['matchId'] != requestedId ||
        raw['eligible'] is! bool ||
        raw['isPrediction'] == true ||
        (raw['eligible'] == true && raw['kind'] != 'LAST_CONFIRMED')) {
      throw const FormatException('Invalid last confirmed lineups contract');
    }
    return LastConfirmedLineups(raw, offline: offline);
  }
  final Json json;
  final bool offline;

  /// Metadata supplied by the same stored read; no extra acquisition or resolver.
  Entity? entity(String collection, String id) {
    final rows = json[collection];
    if (rows is! List) return null;
    for (final row in rows) {
      if (row is Map &&
          row['id'] == id &&
          row['name'] is String &&
          (row['name'] as String).trim().isNotEmpty) {
        return Entity(Map<String, dynamic>.from(row));
      }
    }
    return null;
  }

  HistoricalLineupSide? side(String side, FootballMatch target, Snapshot data) {
    if (!const {'home', 'away'}.contains(side) ||
        !lastLineupsEligible(target) ||
        json['eligible'] != true ||
        json['matchId'] != target.id) {
      return null;
    }
    final value = json[side];
    if (value is! Map) return null;
    final teamId = side == 'home' ? target.homeId : target.awayId;
    if (value['kind'] != 'LAST_CONFIRMED' ||
        value['teamId'] is! String ||
        data.resolveEntityId(value['teamId'] as String) !=
            data.resolveEntityId(teamId)) {
      return null;
    }
    final source = value['sourceMatch'];
    if (source is! Map ||
        source['matchId'] is! String ||
        (source['matchId'] as String).isEmpty ||
        source['matchId'] == target.id ||
        source['competitionId'] is! String ||
        (source['competitionId'] as String).isEmpty ||
        source['opponentTeamId'] is! String ||
        (source['opponentTeamId'] as String).isEmpty ||
        !const {'home', 'away'}.contains(source['side'])) {
      return null;
    }
    if (data.resolveEntityId(source['opponentTeamId'] as String) ==
        data.resolveEntityId(teamId)) {
      return null;
    }
    final rawDate = source['startTime'];
    if (rawDate is! String ||
        !RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(rawDate)) {
      return null;
    }
    final kickoff = DateTime.tryParse(rawDate)?.toUtc();
    if (kickoff == null ||
        !kickoff.isBefore(target.startTime) ||
        !kickoff.isAfter(target.startTime.subtract(const Duration(days: 45)))) {
      return null;
    }
    final starters = <Json>[], bench = <Json>[];
    if (value['lineups'] is! List) return null;
    final identities = <String>{};
    for (final row in value['lineups'] as List) {
      if (row is! Map || row['team'] != side) return null;
      final type = row['type']?.toString().toLowerCase() ?? '';
      if (!type.startsWith('start') && !type.startsWith('sub')) continue;
      final nested = row['player'] is Map ? row['player'] as Map : const {};
      final name = row['lineupPlayer'] is String
          ? row['lineupPlayer']
          : row['playerName'] ?? nested['name'];
      if (name is! String || name.trim().isEmpty) return null;
      final rawKey = row['playerKey'] ?? row['playerId'] ?? nested['id'];
      final key =
          unknownLineupProviderKey(rawKey) ||
              (rawKey?.toString().trim().isEmpty ?? true)
          ? null
          : rawKey;
      final canonical =
          hasUnknownLineupIdentity(Map<String, dynamic>.from(row)) ||
              unknownLineupProviderKey(nested['id'])
          ? null
          : row['canonicalPlayerId'] ?? row['playerId'];
      final identity = canonical is String && canonical.startsWith('fb_player_')
          ? data.resolveEntityId(canonical)
          : key;
      if (identity != null && !identities.add(identity.toString())) return null;
      final player = <String, dynamic>{
        'name': name.trim(),
        if (key is String) 'playerKey': key,
        if (canonical is String && canonical.startsWith('fb_player_'))
          'id': data.resolveEntityId(canonical),
        if (row['lineupNumber'] != null || row['shirtNumber'] != null)
          'number': row['lineupNumber'] ?? row['shirtNumber'],
        if (row['position'] is String) 'position': row['position'],
      };
      (type.startsWith('start') ? starters : bench).add(player);
    }
    if (starters.length < 7 || starters.length > 11) return null;
    final formation = value['formation'];
    return HistoricalLineupSide(
      teamId: teamId,
      matchId: source['matchId'] as String,
      kickoff: kickoff,
      competitionId: source['competitionId'] as String,
      opponentId: source['opponentTeamId'] as String,
      starters: starters,
      bench: bench,
      formation:
          value['formationConfirmed'] == true &&
              formation is String &&
              RegExp(r'^\d(?:-\d){1,4}$').hasMatch(formation)
          ? formation
          : null,
    );
  }
}

class HistoricalLineupSide {
  const HistoricalLineupSide({
    required this.teamId,
    required this.matchId,
    required this.kickoff,
    required this.competitionId,
    required this.opponentId,
    required this.starters,
    required this.bench,
    this.formation,
  });
  final String teamId, matchId, competitionId, opponentId;
  final DateTime kickoff;
  final List<Json> starters, bench;
  final String? formation;
}

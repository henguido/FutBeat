/// A reversible *presentation* decision. The two provider/canonical records
/// remain independent; this registry does not write redirects or merge data.
/// Add an entry only after individual evidence review. Removing it restores
/// both visible records in the next app version.
class PlayerDisplayAlias {
  const PlayerDisplayAlias({
    required this.teamId,
    required this.aliasId,
    required this.visibleId,
    required this.aliasName,
    required this.visibleName,
    required this.shirt,
    required this.visibleDob,
    required this.evidence,
  });

  final String teamId, aliasId, visibleId, aliasName, visibleName, visibleDob;
  final int shirt;
  final String evidence;
}

/// Adjudications are data, never conditional branches by player name or ID.
/// All other name-subset candidates remain two visible people.
const adjudicatedPlayerDisplayAliases = <PlayerDisplayAlias>[
  PlayerDisplayAlias(
    teamId: 'fb_team_7d7cf628b4cb43e3a30cfade12eb0cf6',
    aliasId: 'fb_player_a7a7c8d3a8474ef68c968dca80d2e975',
    visibleId: 'fb_player_333ccb5b7044465497e7888298dc7f87',
    aliasName: 'Waston Kendall',
    visibleName: 'Jamaal Waston Manley Kendall',
    shirt: 4,
    visibleDob: '1988-01-01',
    evidence:
        '#191: same GOAL squad response/shirt; official Saprissa and '
        'CONCACAF rosters corroborate Kendall Waston #4 and DOB',
  ),
  PlayerDisplayAlias(
    teamId: 'fb_team_3b8b2297604342438483d4d413ac4d19',
    aliasId: 'fb_player_57babfbf15f049af900b7316bad49471',
    visibleId: 'fb_player_acca8c458fc64beaa46d01ad4e8650aa',
    aliasName: 'Rodrigo Vera',
    visibleName: 'Rodrigo Vera Oscar',
    shirt: 30,
    visibleDob: '2007-12-14',
    evidence:
        '2026-10-03 audit: same GOAL squad response, shirt 30, '
        'compatible names and exact DOB on both records',
  ),
];

PlayerDisplayAlias? adjudicationForAlias(String id) {
  for (final decision in adjudicatedPlayerDisplayAliases) {
    if (decision.aliasId == id) return decision;
  }
  return null;
}

int? _shirt(Object? value) {
  final parsed = value is num
      ? (value == value.roundToDouble() ? value.toInt() : null)
      : int.tryParse(value?.toString().trim() ?? '');
  return parsed != null && parsed > 0 && parsed < 100 ? parsed : null;
}

bool _validAlias(PlayerDisplayAlias decision, Map<String, dynamic> player) {
  final dob = player['dateOfBirth']?.toString().trim() ?? '';
  return player['id'] == decision.aliasId &&
      player['teamId'] == decision.teamId &&
      player['name'] == decision.aliasName &&
      _shirt(player['shirtNumber'] ?? player['number']) == decision.shirt &&
      player['media'] == null &&
      (dob.isEmpty || dob == decision.visibleDob);
}

bool _validVisible(PlayerDisplayAlias decision, Map<String, dynamic> player) {
  return player['id'] == decision.visibleId &&
      player['teamId'] == decision.teamId &&
      player['name'] == decision.visibleName &&
      _shirt(player['shirtNumber'] ?? player['number']) == decision.shirt &&
      player['dateOfBirth'] == decision.visibleDob;
}

bool adjudicatedAliasMatches(
  PlayerDisplayAlias decision,
  Map<String, dynamic> player,
) => _validAlias(decision, player);

bool adjudicatedVisibleMatches(
  PlayerDisplayAlias decision,
  Map<String, dynamic> player,
) => _validVisible(decision, player);

bool adjudicatedPairCompatible(
  Map<String, dynamic> alias,
  Map<String, dynamic> visible,
) {
  for (final field in const ['country', 'position']) {
    final left = alias[field]?.toString().trim().toLowerCase() ?? '';
    final right = visible[field]?.toString().trim().toLowerCase() ?? '';
    if (left.isNotEmpty && right.isNotEmpty && left != right) return false;
  }
  return true;
}

/// Returns only individually adjudicated, still-valid mappings. A conflicting
/// DOB, wrong team/shirt/name, or a changed target fails open to two records.
Map<String, String> visiblePlayerAliases(
  Iterable<Map<String, dynamic>> players, {
  bool includeStandalone = true,
}) {
  final byId = {for (final player in players) player['id']?.toString(): player};
  final result = <String, String>{};
  for (final decision in adjudicatedPlayerDisplayAliases) {
    final alias = byId[decision.aliasId];
    final visible = byId[decision.visibleId];
    if (alias == null || !_validAlias(decision, alias)) continue;
    if (!includeStandalone && visible == null) continue;
    if (visible != null && !_validVisible(decision, visible)) continue;
    if (visible != null && !adjudicatedPairCompatible(alias, visible)) continue;
    result[decision.aliasId] = decision.visibleId;
  }
  return result;
}

/// One visible row per adjudicated identity, including alias-only search and
/// favorites responses. An alias-only row keeps its own missing fields (never
/// invents DOB/photo), but uses the adjudicated display name and navigation ID.
List<Map<String, dynamic>> presentPlayers(
  Iterable<Map<String, dynamic>> players, {
  bool includeStandalone = true,
}) {
  final rows = players.toList();
  final aliases = visiblePlayerAliases(
    rows,
    includeStandalone: includeStandalone,
  );
  final realIds = {for (final row in rows) row['id']?.toString()};
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final row in rows) {
    final id = row['id']?.toString() ?? '';
    final visibleId = aliases[id] ?? id;
    if (aliases.containsKey(id) && realIds.contains(visibleId)) {
      // Let the actual rich/selected record win regardless of input order.
      continue;
    }
    if (!seen.add(visibleId)) continue;
    if (aliases.containsKey(id)) {
      final decision = adjudicationForAlias(id)!;
      result.add({...row, 'id': visibleId, 'name': decision.visibleName});
    } else {
      result.add(row);
    }
  }
  return result;
}

/// Normalizes every cloud snapshot at its model boundary. This is shared by
/// Plantilla, profile, Explore/search, favorites, and match context. Provider
/// rows and stored follow keys are untouched; redirects are presentation-only.
Map<String, dynamic> presentPlayerSnapshot(Map<String, dynamic> snapshot) {
  final raw = snapshot['players'];
  if (raw is! List) return snapshot;
  if (raw.any((row) => row is! Map)) return snapshot;
  final players = raw
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  final aliases = visiblePlayerAliases(players);
  if (aliases.isEmpty) return snapshot;
  final shown = presentPlayers(players);
  final originalRedirects = snapshot['entityRedirects'];
  final redirects = <String, dynamic>{
    if (originalRedirects is Map) ...originalRedirects.cast<String, dynamic>(),
    ...aliases,
  };
  final coverage = snapshot['coverage'];
  final nextCoverage = coverage is Map
      ? Map<String, dynamic>.from(coverage)
      : null;
  final squad = nextCoverage?['squad'];
  final removed = players.length - shown.length;
  if (squad is Map && removed > 0) {
    final count = squad['playerCount'];
    if (count is num && count >= removed) {
      nextCoverage!['squad'] = {
        ...squad.cast<String, dynamic>(),
        'playerCount': count.toInt() - removed,
      };
    }
  }
  final matches = snapshot['matches'];
  final shownMatches = matches is List
      ? [
          for (final match in matches)
            if (match is Map && match['events'] is List)
              {
                ...Map<String, dynamic>.from(match),
                'events': [
                  for (final event in match['events'] as List)
                    if (event is Map)
                      {
                        ...Map<String, dynamic>.from(event),
                        for (final field in const [
                          'playerId',
                          'assistPlayerId',
                          'canonicalPlayerId',
                        ])
                          if (aliases.containsKey(event[field]?.toString()))
                            field: aliases[event[field].toString()],
                      }
                    else
                      event,
                ],
              }
            else
              match,
        ]
      : null;
  return {
    ...snapshot,
    'players': shown,
    'entityRedirects': redirects,
    'coverage': ?nextCoverage,
    'matches': ?shownMatches,
  };
}

/// A lineup row may carry a GOAL player ID independently of a squad snapshot.
/// Its individually adjudicated ID is enough to show one navigable identity;
/// a conflicting observed name/number keeps the original row visible.
Map<String, dynamic> presentLineupPlayer(Map<String, dynamic> row) {
  final id = row['canonicalId']?.toString() ?? '';
  final decision = adjudicationForAlias(id);
  if (decision == null) return row;
  final name = row['name']?.toString().trim() ?? '';
  final number = _shirt(row['number'] ?? row['shirtNumber']);
  if (name.isNotEmpty &&
      !_sameNameTokens(name, decision.aliasName) &&
      !_sameNameTokens(name, decision.visibleName)) {
    return row;
  }
  if (number != null && number != decision.shirt) return row;
  return {
    ...row,
    'canonicalId': decision.visibleId,
    'name': decision.visibleName,
  };
}

bool _sameNameTokens(String left, String right) {
  List<String> tokens(String value) =>
      value
          .toLowerCase()
          .split(RegExp(r'[^a-zà-ÿ]+'))
          .where((token) => token.isNotEmpty)
          .toList()
        ..sort();
  final a = tokens(left), b = tokens(right);
  return a.length == b.length &&
      List.generate(
        a.length,
        (index) => a[index] == b[index],
      ).every((matches) => matches);
}

/// Match details have no squad list, so only explicit adjudications are used.
Map<String, dynamic> presentPlayerMatchDetail(Map<String, dynamic> detail) {
  var changed = false;
  final adjudicatedTargets = {
    for (final decision in adjudicatedPlayerDisplayAliases) decision.visibleId,
  };
  Map<String, dynamic> side(Object? input) {
    if (input is! Map) return <String, dynamic>{};
    final result = Map<String, dynamic>.from(input);
    final originalIds = <String>{
      for (final key in const ['starters', 'substitutes'])
        for (final row in result[key] is List ? result[key] as List : const [])
          if (row is Map && row['canonicalId'] != null)
            row['canonicalId'].toString(),
    };
    final shownIds = <String>{};
    for (final key in const ['starters', 'substitutes']) {
      final rows = result[key];
      if (rows is! List) continue;
      final shown = <dynamic>[];
      for (final row in rows) {
        if (row is! Map) {
          shown.add(row);
          continue;
        }
        final presented = presentLineupPlayer(Map<String, dynamic>.from(row));
        final id = presented['canonicalId']?.toString();
        if (id != null &&
            id != row['canonicalId']?.toString() &&
            originalIds.contains(id)) {
          continue; // the actual target row wins, regardless of list order
        }
        if (id != null &&
            adjudicatedTargets.contains(id) &&
            !shownIds.add(id)) {
          continue;
        }
        shown.add(presented);
      }
      result[key] = shown;
      changed = true;
    }
    return result;
  }

  final home = side(detail['home']);
  final away = side(detail['away']);
  return changed ? {...detail, 'home': home, 'away': away} : detail;
}

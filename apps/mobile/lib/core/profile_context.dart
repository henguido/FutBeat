import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'providers.dart';

/// Same rules as the server's `normalize_season`: '2025/26', '2025-26' and
/// '2025_2026' -> '2025-2026'; '2026' stays; anything else lowercased with
/// collapsed spaces; empty -> null.
String? normalizeSeasonKey(String? value) {
  final raw = (value ?? '').trim().toLowerCase();
  if (raw.isEmpty) return null;
  final range = RegExp(r'^(\d{4})\s*[/\-_]\s*(\d{2}|\d{4})$').firstMatch(raw);
  if (range != null) {
    final first = int.parse(range[1]!);
    final tail = range[2]!;
    var second = tail.length == 2
        ? (first ~/ 100) * 100 + int.parse(tail)
        : int.parse(tail);
    if (second < first) second += 100;
    return '$first-$second';
  }
  return raw.replaceAll(RegExp(r'\s+'), ' ');
}

/// Server value for "the option without season" (never a real key).
const noSeason = '-';

/// Display label of a season key: '2025-2026' -> '2025/26'.
String seasonLabel(String? key) {
  if (key == null) return '';
  final range = RegExp(r'^(\d{4})-(\d{4})$').firstMatch(key);
  if (range == null) return key;
  return '${range[1]}/${range[2]!.substring(2)}';
}

/// One real (competition, season) combination of a team (#161).
class ProfileContextOption {
  ProfileContextOption(Json json)
    : competitionId = json['competitionId'] as String,
      competitionName = json['competitionName'] as String? ?? '',
      seasonKey = json['seasonKey'] as String?,
      matchCount = (json['matchCount'] as num?)?.toInt() ?? 0,
      hasStandings = json['hasStandings'] == true,
      currentSeason = json['currentSeason'] == true;

  final String competitionId;
  final String competitionName;

  /// Null when the team's matches of this competition carry no season.
  final String? seasonKey;
  final int matchCount;
  final bool hasStandings;

  /// The competition's current season (its table may still be only cached).
  final bool currentSeason;

  /// Season as sent to the server: '-' asks for the seasonless option.
  String get seasonParam => seasonKey ?? noSeason;

  String get key => '$competitionId|${seasonKey ?? ''}';
  String get label => [
    competitionName,
    if (seasonKey != null) seasonLabel(seasonKey),
  ].join(' ');
}

/// `/v1/team-context`: the team's options, the selected one and its exact
/// table.
class TeamContext {
  TeamContext(Json json)
    : teamId = json['teamId'] as String,
      options = [
        for (final item in json['options'] as List? ?? const [])
          if (item is Map)
            ProfileContextOption(Map<String, dynamic>.from(item)),
      ],
      standings = [
        for (final item in json['standings'] as List? ?? const [])
          if (item is Map) Map<String, dynamic>.from(item),
      ],
      teams = [
        for (final item in json['teams'] as List? ?? const [])
          if (item is Map) Map<String, dynamic>.from(item),
      ],
      _selected = json['selected'] is Map
          ? Map<String, dynamic>.from(json['selected'] as Map)
          : null {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Versión de datos incompatible');
    }
  }

  final String teamId;
  final List<ProfileContextOption> options;
  final List<Json> standings;
  final List<Json> teams;
  final Json? _selected;

  ProfileContextOption? get selected {
    final selected = _selected;
    if (selected == null) return null;
    return options
        .where(
          (o) =>
              o.competitionId == selected['competitionId'] &&
              o.seasonKey == selected['seasonKey'],
        )
        .firstOrNull;
  }

  /// [data] with this context's exact table (and its row teams) in place of
  /// the profile's standings, for the shared table widget.
  Snapshot tableSnapshot(Snapshot data) => Snapshot({
    'schemaVersion': 1,
    'demo': data.demo,
    'updatedAt': data.updatedAt.toIso8601String(),
    'teams': {
      for (final team in data.teams) team.id: team.json,
      for (final team in teams)
        if (team['id'] is String) team['id'] as String: team,
    }.values.toList(),
    'players': const <dynamic>[],
    'competitions': [for (final c in data.competitions) c.json],
    'matches': const <dynamic>[],
    'standings': standings,
  });
}

/// What the profile asks for: a team plus, optionally, a competition and a
/// season (null = the server's deterministic default).
typedef ProfileContextRequest = ({
  String teamId,
  String? competitionId,
  String? season,
});

/// Invalidated whenever a team profile opens (EntityScreen): a failed read
/// is retried on the next open and options never freeze for the session.
final teamContextProvider =
    FutureProvider.family<TeamContext?, ProfileContextRequest>((
      ref,
      request,
    ) async {
      final repository = ref.watch(repositoryProvider);
      if (repository is! ApiRepository) return null;
      return repository.loadTeamContext(
        request.teamId,
        competitionId: request.competitionId,
        season: request.season,
      );
    }, retry: (_, _) => null);

/// The user's choice per team, kept for the session (switching tabs or
/// reopening the profile keeps it).
class ProfileContextSelection
    extends Notifier<Map<String, ({String competitionId, String? season})>> {
  @override
  Map<String, ({String competitionId, String? season})> build() => const {};

  void select(String teamId, ProfileContextOption option) => state = {
    ...state,
    teamId: (competitionId: option.competitionId, season: option.seasonParam),
  };
}

/// Last context shown per team: kept while the next one loads, so a switch
/// never drops the selector, the Tabla tab or the Partidos filter.
class LastTeamContexts extends Notifier<Map<String, TeamContext>> {
  @override
  Map<String, TeamContext> build() => const {};

  void remember(TeamContext context) =>
      state = {...state, context.teamId: context};
}

final lastTeamContextProvider =
    NotifierProvider<LastTeamContexts, Map<String, TeamContext>>(
      LastTeamContexts.new,
    );

final profileContextSelectionProvider =
    NotifierProvider<
      ProfileContextSelection,
      Map<String, ({String competitionId, String? season})>
    >(ProfileContextSelection.new);

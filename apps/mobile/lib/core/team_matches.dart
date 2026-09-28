import 'models.dart';

/// Matches per page of the team profile "Partidos" tab.
const teamMatchesPageSize = 20;

/// Team profile buckets, classified by the effective status (same rules as
/// the server's team matches read model).
enum TeamMatchesBucket {
  /// In play, earliest kickoff first.
  live('live'),

  /// Not started yet (future kickoff, or inside the start grace window),
  /// next kickoff first.
  upcoming('upcoming'),

  /// Everything else (finished, postponed, cancelled, a past kickoff still
  /// awaiting verification…), latest first.
  results('results');

  const TeamMatchesBucket(this.wire);
  final String wire;

  bool accepts(FootballMatch match) => switch (this) {
    live => match.isLive,
    upcoming => match.isUpcoming,
    results => !match.isLive && !match.isUpcoming,
  };
}

/// One page of `/v1/team-matches`: a regular snapshot (matches plus the teams
/// and competitions they reference) and its keyset cursor.
class TeamMatchesPage {
  TeamMatchesPage(Json json)
    : data = Snapshot(json),
      hasMore = json['hasMore'] == true,
      nextCursor = json['nextCursor'] as String?;

  final Snapshot data;
  final bool hasMore;
  final String? nextCursor;
}

/// A match with the snapshot that can render it (its teams/competition).
typedef ProfileMatch = ({FootballMatch match, Snapshot data});

/// [matches] of one bucket, in display order, each id once.
List<ProfileMatch> orderedProfileMatches(
  TeamMatchesBucket bucket,
  Iterable<ProfileMatch> matches,
) {
  final byId = <String, ProfileMatch>{};
  for (final item in matches) {
    if (bucket.accepts(item.match)) byId.putIfAbsent(item.match.id, () => item);
  }
  final list = byId.values.toList()
    ..sort((a, b) {
      final byTime = a.match.startTime.compareTo(b.match.startTime);
      final ordered = byTime != 0 ? byTime : a.match.id.compareTo(b.match.id);
      return bucket == TeamMatchesBucket.results ? -ordered : ordered;
    });
  return list;
}

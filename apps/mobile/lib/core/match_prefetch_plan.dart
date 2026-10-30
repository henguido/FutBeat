import 'models.dart';
import 'relevance.dart';

/// A bounded list of canonical match IDs to warm while the app is visible.
/// Planning never performs a request. The caller owns lifecycle cancellation.
class MatchPrefetchPlan {
  const MatchPrefetchPlan._(this.matchIds);

  final List<String> matchIds;

  static MatchPrefetchPlan build({
    required Iterable<FootballMatch> matches,
    required Set<String> follows,
    required String? selectedCountry,
    required Map<String, Entity> competitions,
    String? openMatchId,
    Set<String> highlightedMatchIds = const {},
    int maxMatches = 8,
  }) {
    if (maxMatches <= 0) return const MatchPrefetchPlan._([]);
    final byId = <String, FootballMatch>{};
    for (final match in matches) {
      if (match.id.isNotEmpty) byId[match.id] = match;
    }
    int rank(FootballMatch match) {
      if (match.id == openMatchId) return 0;
      if (follows.contains('team:${match.homeId}') ||
          follows.contains('team:${match.awayId}'))
        return 1;
      if (follows.contains('competition:${match.competitionId}')) return 2;
      final competition = competitions[match.competitionId];
      if (competition != null &&
          entityMatchesCountry(competition, selectedCountry)) {
        return 3;
      }
      if (highlightedMatchIds.contains(match.id)) return 4;
      return 5;
    }

    final sorted = byId.values.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final byTime = a.startTime.compareTo(b.startTime);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return MatchPrefetchPlan._([
      for (final match in sorted.take(maxMatches)) match.id,
    ]);
  }
}

/// Runs a plan with a strict per-run request budget. Checking [isActive]
/// before every item lets the screen stop warming on background or disposal.
/// A failed item does not retry here or consume a second request.
Future<int> runMatchPrefetch(
  MatchPrefetchPlan plan, {
  required Future<void> Function(String matchId) fetch,
  required bool Function() isActive,
  int maxRequests = 8,
}) async {
  var attempted = 0;
  for (final matchId in plan.matchIds) {
    if (!isActive() || attempted >= maxRequests) break;
    attempted++;
    try {
      await fetch(matchId);
    } catch (_) {
      // Warming is best effort. The visible Match Center handles its error.
    }
  }
  return attempted;
}

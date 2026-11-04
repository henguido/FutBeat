enum LineupStatus { unknown, predicted, provisional, confirmed }

enum LineupHomeAway { home, away }

class LineupHistoryPlayer {
  const LineupHistoryPlayer({
    this.id,
    required this.name,
    this.shirtNumber,
    this.position,
    this.minutes,
    this.rating,
  });

  final String? id;
  final String name;
  final int? shirtNumber;
  final String? position;
  final int? minutes;
  final double? rating;
}

class LineupHistoryTeam {
  const LineupHistoryTeam({required this.id, required this.name});

  final String id;
  final String name;
}

class LineupHistorySubstitution {
  const LineupHistorySubstitution({
    required this.playerOut,
    required this.playerIn,
    this.minute,
  });

  final LineupHistoryPlayer playerOut;
  final LineupHistoryPlayer playerIn;
  final int? minute;
}

class LineupHistoryEntry {
  const LineupHistoryEntry({
    required this.matchId,
    required this.teamId,
    required this.kickoff,
    required this.competition,
    required this.opponent,
    required this.homeAway,
    this.result,
    this.formation,
    this.starters = const [],
    this.bench = const [],
    this.coach,
    this.captainPlayerId,
    this.substitutions = const [],
    this.lineupStatus = LineupStatus.unknown,
  });

  final String matchId;
  final String teamId;
  final DateTime kickoff;
  final String competition;
  final LineupHistoryTeam opponent;
  final LineupHomeAway homeAway;
  final String? result;
  final String? formation;
  final List<LineupHistoryPlayer> starters;
  final List<LineupHistoryPlayer> bench;
  final String? coach;
  final String? captainPlayerId;
  final List<LineupHistorySubstitution> substitutions;
  final LineupStatus lineupStatus;

  LineupHistoryPlayer? get captain {
    final id = captainPlayerId;
    if (id == null || id.isEmpty) return null;
    for (final player in [...starters, ...bench]) {
      if (player.id == id) return player;
    }
    return null;
  }
}

abstract interface class LineupHistoryAdapter<T> {
  List<LineupHistoryEntry> normalize(Iterable<T> source);
}

class LineupPlayerFrequency {
  const LineupPlayerFrequency({
    required this.player,
    required this.appearances,
    required this.starts,
    required this.consideredMatches,
  });

  final LineupHistoryPlayer player;
  final int appearances;
  final int starts;
  final int consideredMatches;

  double get startingPercentage =>
      consideredMatches == 0 ? 0 : starts * 100 / consideredMatches;
}

class LineupHistorySummary {
  const LineupHistorySummary({
    required this.consideredMatches,
    required this.playerFrequencies,
    this.mostUsedFormation,
    this.latestCoach,
    this.frequentCaptain,
  });

  final int consideredMatches;
  final String? mostUsedFormation;
  final List<LineupPlayerFrequency> playerFrequencies;
  final String? latestCoach;
  final LineupHistoryPlayer? frequentCaptain;
}

class LineupHistorySummarizer {
  const LineupHistorySummarizer._();

  static LineupHistorySummary summarize(
    Iterable<LineupHistoryEntry> source, {
    int limit = 5,
    int minimumFormationSamples = 1,
  }) {
    final entries = source.toList()
      ..sort((a, b) => b.kickoff.compareTo(a.kickoff));
    final considered = entries.take(limit < 0 ? 0 : limit).toList();
    final formations = <String, int>{};
    final players =
        <String, ({LineupHistoryPlayer player, int starts, int appearances})>{};
    final captains = <String, ({LineupHistoryPlayer player, int count})>{};

    String keyOf(LineupHistoryPlayer player) {
      final id = player.id?.trim();
      return id != null && id.isNotEmpty
          ? 'id:$id'
          : 'name:${player.name.trim().toLowerCase()}';
    }

    for (final entry in considered) {
      final formation = entry.formation?.trim();
      if (formation != null && formation.isNotEmpty) {
        formations.update(formation, (count) => count + 1, ifAbsent: () => 1);
      }
      final seen = <String>{};
      for (final player in entry.starters) {
        if (player.name.trim().isEmpty) continue;
        final key = keyOf(player);
        if (!seen.add(key)) continue;
        final old = players[key];
        players[key] = (
          player: old?.player ?? player,
          starts: (old?.starts ?? 0) + 1,
          appearances: (old?.appearances ?? 0) + 1,
        );
      }
      for (final player in entry.bench) {
        if (player.name.trim().isEmpty) continue;
        final key = keyOf(player);
        if (!seen.add(key)) continue;
        final old = players[key];
        players[key] = (
          player: old?.player ?? player,
          starts: old?.starts ?? 0,
          appearances: (old?.appearances ?? 0) + 1,
        );
      }
      final captain = entry.captain;
      if (captain != null) {
        final key = keyOf(captain);
        final old = captains[key];
        captains[key] = (player: captain, count: (old?.count ?? 0) + 1);
      }
    }

    String? mostUsedFormation;
    if (formations.isNotEmpty) {
      final ordered = formations.entries.toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
      if (ordered.first.value >= minimumFormationSamples &&
          (ordered.length == 1 || ordered.first.value > ordered[1].value)) {
        mostUsedFormation = ordered.first.key;
      }
    }

    final frequencies =
        [
          for (final value in players.values)
            LineupPlayerFrequency(
              player: value.player,
              appearances: value.appearances,
              starts: value.starts,
              consideredMatches: considered.length,
            ),
        ]..sort((a, b) {
          final byStarts = b.starts.compareTo(a.starts);
          if (byStarts != 0) return byStarts;
          final byAppearances = b.appearances.compareTo(a.appearances);
          if (byAppearances != 0) return byAppearances;
          return a.player.name.compareTo(b.player.name);
        });
    final captainList = captains.values.toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.player.name.compareTo(b.player.name);
      });

    return LineupHistorySummary(
      consideredMatches: considered.length,
      mostUsedFormation: mostUsedFormation,
      playerFrequencies: frequencies,
      latestCoach: considered
          .map((entry) => entry.coach?.trim())
          .whereType<String>()
          .where((name) => name.isNotEmpty)
          .firstOrNull,
      frequentCaptain: captainList.isEmpty ? null : captainList.first.player,
    );
  }
}

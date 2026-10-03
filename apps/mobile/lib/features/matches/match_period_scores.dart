import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/theme.dart';

/// A finished match's verified period goals. Absence is handled by the parent:
/// no empty card or invented score is rendered.
class MatchPeriodScoresCard extends StatelessWidget {
  const MatchPeriodScoresCard({super.key, required this.scores});

  final MatchPeriodScores scores;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, MatchPeriodScore)>[
      if (scores.halfTime case final score?) ('Descanso', score),
      ("90'", scores.fullTime),
      if (scores.extraTime case final score?) ('Prórroga (goles)', score),
      if (scores.penalties case final score?) ('Penales', score),
    ];
    return Container(
      key: const ValueKey('match-period-scores'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2B373D)),
      ),
      child: Column(
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row.$1,
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ),
                  Text(
                    row.$2.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

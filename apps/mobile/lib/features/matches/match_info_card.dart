import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'match_screen.dart' show matchDateLabel;

/// One real fact of the "Información del partido" card. Optional facts are
/// simply absent (never "—", "N/D" or "No disponible").
class MatchInfoItem {
  const MatchInfoItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.value,
    this.secondary,
  });

  final String id;
  final IconData icon;
  final String label;
  final String value;
  final String? secondary;
}

String? _present(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// #99 Match info facts from data the app already has (no request): the
/// competition (with its country), round and season, kickoff date and local
/// time, venue and referee. Missing optional facts produce no item.
List<MatchInfoItem> matchInfoItems({
  required FootballMatch match,
  required Entity competition,
  required MatchDetail detail,
  required String venue,
  required String localKickoffTime,
}) {
  // Localized label; a provider code (`intl`, `eurocups`) is never shown.
  final country = _present(competition.country) == null
      ? null
      : entityCountryLabel(competition);
  final round = _present(detail.round);
  // The match's own season only: the competition entity carries its
  // *current* season, which around a rollover is not this match's season.
  final season = _present(match.json['season']);
  final stadium = _present(venue);
  final referee = _present(detail.referee);
  return [
    MatchInfoItem(
      id: 'competition',
      icon: Icons.emoji_events_outlined,
      label: 'Competición',
      value: competition.name,
      secondary: country,
    ),
    MatchInfoItem(
      id: 'date',
      icon: Icons.calendar_today_rounded,
      label: 'Fecha',
      value: matchDateLabel(match.startTime),
      secondary: localKickoffTime,
    ),
    if (round != null)
      MatchInfoItem(
        id: 'round',
        icon: Icons.format_list_numbered_rounded,
        label: 'Jornada',
        value: round,
        secondary: season == null ? null : 'Temporada $season',
      )
    else if (season != null)
      MatchInfoItem(
        id: 'season',
        icon: Icons.format_list_numbered_rounded,
        label: 'Temporada',
        value: season,
      ),
    if (stadium != null)
      MatchInfoItem(
        id: 'venue',
        icon: Icons.stadium_outlined,
        label: 'Estadio',
        value: stadium,
      ),
    if (referee != null)
      MatchInfoItem(
        id: 'referee',
        icon: Icons.sports_rounded,
        label: 'Árbitro',
        value: referee,
      ),
  ];
}

const _tileBorder = Color(0xFF2B373D);

class MatchInfoCard extends StatelessWidget {
  const MatchInfoCard({
    required this.match,
    required this.competition,
    required this.detail,
    required this.venue,
    super.key,
  });

  final FootballMatch match;
  final Entity competition;
  final MatchDetail detail;
  final String venue;

  /// Below this width the tiles stack in one column.
  static const _twoColumnMinWidth = 300.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final items = matchInfoItems(
      match: match,
      competition: competition,
      detail: detail,
      venue: venue,
      localKickoffTime: localTime(context, match.startTime),
    );
    final lead = items.first;
    final rest = items.skip(1).toList();
    return Card(
      key: const ValueKey('match-info-card'),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= _twoColumnMinWidth;
            // Pairs share one row of equal height; an odd last tile (or a
            // narrow screen) takes the whole row, so there is never a hole.
            final rows = <List<MatchInfoItem>>[
              for (var i = 0; i < rest.length; i += twoColumns ? 2 : 1)
                rest.sublist(
                  i,
                  twoColumns ? (i + 2).clamp(0, rest.length) : i + 1,
                ),
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MatchInfoTile(lead, prominent: true),
                for (final row in rows) ...[
                  const SizedBox(height: _gap),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < row.length; i++) ...[
                          if (i > 0) const SizedBox(width: _gap),
                          Expanded(child: _MatchInfoTile(row[i])),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MatchInfoTile extends StatelessWidget {
  const _MatchInfoTile(this.item, {this.prominent = false});

  final MatchInfoItem item;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('match-info-${item.id}'),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: prominent ? .06 : .035),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _tileBorder),
    ),
    child: Row(
      children: [
        Container(
          width: prominent ? 36 : 30,
          height: prominent ? 36 : 30,
          decoration: BoxDecoration(
            color: (prominent ? lime : Colors.white).withValues(alpha: .1),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            item.icon,
            size: prominent ? 19 : 16,
            color: prominent ? lime : muted,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: prominent ? 15 : 13,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              if (item.secondary != null) ...[
                const SizedBox(height: 2),
                Text(
                  item.secondary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

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

/// Spanish names of the provider's generic round / phase labels (GOAL
/// `matchRound` / `stageName`, English). Proper names (Clausura, Bayern,
/// Southern League...) are not in here and are shown as sent.
const Map<String, String> _phaseNames = {
  'group stage': 'Fase de grupos',
  'regular season': 'Temporada regular',
  'qualification': 'Clasificación',
  'league phase': 'Fase de liga',
  'league stage': 'Fase de liga',
  'knockout stage': 'Fase eliminatoria',
  'play-offs': 'Playoffs',
  'playoffs': 'Playoffs',
  'round of 16': 'Octavos de final',
  'quarter-finals': 'Cuartos de final',
  'quarter-final': 'Cuartos de final',
  'semi-finals': 'Semifinales',
  'semi-final': 'Semifinal',
  'final': 'Final',
  '3rd place': 'Tercer puesto',
  'third place': 'Tercer puesto',
  'first stage': 'Primera fase',
  'second stage': 'Segunda fase',
  'third stage': 'Tercera fase',
  'promotion group': 'Grupo de ascenso',
  'relegation group': 'Grupo de descenso',
  'championship group': 'Grupo por el título',
  'placement group': 'Grupo de posiciones',
  'friendly international': 'Amistoso internacional',
  'club friendly': 'Amistoso de clubes',
  'north': 'Norte',
  'south': 'Sur',
  'east': 'Este',
  'west': 'Oeste',
  'northeast': 'Noreste',
  'northwest': 'Noroeste',
  'southeast': 'Sureste',
  'southwest': 'Suroeste',
  'central': 'Centro',
};

const Map<int, String> _fractionFinals = {
  8: 'Octavos de final',
  16: 'Dieciseisavos de final',
  32: 'Treintaidosavos de final',
};

String _phasePart(String part) {
  final key = part.trim().toLowerCase();
  final known = _phaseNames[key];
  if (known != null) return known;
  final group = RegExp(
    r'^(?:group|girone)\s+([a-z]|\d+|[ivx]+)$',
    caseSensitive: false,
  ).firstMatch(part.trim());
  if (group != null) return 'Grupo ${group.group(1)!.toUpperCase()}';
  final fraction = RegExp(r'^1/(\d+)[- ]finals?$').firstMatch(key);
  if (fraction != null) {
    final n = int.parse(fraction.group(1)!);
    return _fractionFinals[n] ?? '1/$n de final';
  }
  return part.trim();
}

/// Visible Spanish label of a provider round or phase, or null when absent.
/// Composite labels ("Qualification - First Stage") are translated part by
/// part; anything unknown is kept exactly as the provider sent it.
String? matchPhaseLabel(String? raw) {
  final text = _present(raw);
  if (text == null) return null;
  return text.split(' - ').map(_phasePart).join(' - ');
}

/// A matchday number ("4") reads "Jornada 4"; any other provider round is a
/// named round ("Quarter-finals" -> "Cuartos de final"), never "Jornada
/// Quarter-finals".
bool isMatchdayRound(String? round) =>
    round != null && RegExp(r'^\d+$').hasMatch(round.trim());

/// Hero line text of a round ("Jornada 4", "Cuartos de final"), or null.
String? matchRoundHeadline(String? round) {
  final text = _present(round);
  if (text == null) return null;
  return isMatchdayRound(text) ? 'Jornada $text' : matchPhaseLabel(text);
}

String _fold(String value) => value
    .toLowerCase()
    .replaceAll(RegExp('[áàä]'), 'a')
    .replaceAll(RegExp('[éèë]'), 'e')
    .replaceAll(RegExp('[íìï]'), 'i')
    .replaceAll(RegExp('[óòö]'), 'o')
    .replaceAll(RegExp('[úùü]'), 'u')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The match's competition phase, only when it tells something: the
/// provider's "Current" placeholder, a phase equal to the competition name
/// or to the round already shown are hidden.
String? matchStageLabel({
  required String? stage,
  required String competitionName,
  String? round,
}) {
  final text = _present(stage);
  if (text == null || _fold(text) == 'current') return null;
  final label = matchPhaseLabel(text)!;
  if (_fold(text) == _fold(competitionName) ||
      _fold(label) == _fold(competitionName)) {
    return null;
  }
  final roundLabel = matchPhaseLabel(round);
  if (roundLabel != null && _fold(roundLabel) == _fold(label)) return null;
  return label;
}

/// GOAL sends the referee as "Name" or "Name, Country". The country moves to
/// the secondary line when it reads as one; otherwise the text is kept whole.
({String name, String? country}) splitReferee(String referee) {
  final comma = referee.lastIndexOf(',');
  if (comma <= 0) return (name: referee, country: null);
  final name = referee.substring(0, comma).trim();
  final country = referee.substring(comma + 1).trim();
  final looksLikeCountry = RegExp(
    r"^[A-ZÀ-Ý][\p{L} .'’()-]*$",
    unicode: true,
  ).hasMatch(country);
  if (name.isEmpty || !looksLikeCountry) {
    return (name: referee, country: null);
  }
  return (name: name, country: country);
}

/// #99 Match info facts from data the app already has (no request): the
/// competition (with its country), round and season, kickoff date and local
/// time, competition phase, venue and referee. Missing optional facts produce
/// no item.
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
  final stage = matchStageLabel(
    stage: detail.stage,
    competitionName: competition.name,
    round: round,
  );
  final stadium = _present(venue);
  final rawReferee = _present(detail.referee);
  final referee = rawReferee == null ? null : splitReferee(rawReferee);
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
        label: isMatchdayRound(round) ? 'Jornada' : 'Ronda',
        value: isMatchdayRound(round) ? round : matchPhaseLabel(round)!,
        secondary: season == null ? null : 'Temporada $season',
      )
    else if (season != null)
      MatchInfoItem(
        id: 'season',
        icon: Icons.format_list_numbered_rounded,
        label: 'Temporada',
        value: season,
      ),
    if (stage != null)
      MatchInfoItem(
        id: 'stage',
        icon: Icons.account_tree_outlined,
        label: 'Fase',
        value: stage,
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
        value: referee.name,
        secondary: referee.country,
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

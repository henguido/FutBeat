import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
    required this.group,
    this.secondary,
  });

  final String id;
  final IconData icon;
  final String label;
  final String value;
  final MatchInfoGroup group;
  final String? secondary;
}

enum MatchInfoGroup { match, venue, officials, conditions }

String matchInfoGroupLabel(MatchInfoGroup group) => switch (group) {
  MatchInfoGroup.match => 'Partido',
  MatchInfoGroup.venue => 'Sede',
  MatchInfoGroup.officials => 'Oficiales',
  MatchInfoGroup.conditions => 'Transmisión y condiciones',
};

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
      group: MatchInfoGroup.match,
      secondary: country,
    ),
    MatchInfoItem(
      id: 'date',
      icon: Icons.calendar_today_rounded,
      label: 'Fecha',
      value: matchDateLabel(match.startTime),
      group: MatchInfoGroup.match,
      secondary: localKickoffTime,
    ),
    if (round != null)
      MatchInfoItem(
        id: 'round',
        icon: Icons.format_list_numbered_rounded,
        label: isMatchdayRound(round) ? 'Jornada' : 'Ronda',
        value: isMatchdayRound(round) ? round : matchPhaseLabel(round)!,
        group: MatchInfoGroup.match,
        secondary: season == null ? null : 'Temporada $season',
      )
    else if (season != null)
      MatchInfoItem(
        id: 'season',
        icon: Icons.format_list_numbered_rounded,
        label: 'Temporada',
        value: season,
        group: MatchInfoGroup.match,
      ),
    if (stage != null)
      MatchInfoItem(
        id: 'stage',
        icon: Icons.account_tree_outlined,
        label: 'Fase',
        value: stage,
        group: MatchInfoGroup.match,
      ),
    if (stadium != null)
      MatchInfoItem(
        id: 'venue',
        icon: Icons.stadium_outlined,
        label: 'Estadio',
        value: stadium,
        group: MatchInfoGroup.venue,
      ),
    if (referee != null)
      MatchInfoItem(
        id: 'referee',
        icon: Icons.sports_rounded,
        label: 'Árbitro',
        value: referee.name,
        group: MatchInfoGroup.officials,
        secondary: referee.country,
      ),
  ];
}

const _tileBorder = Color(0xFF2B373D);

class MatchInfoCard extends StatefulWidget {
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
  State<MatchInfoCard> createState() => _MatchInfoCardState();
}

class _MatchInfoCardState extends State<MatchInfoCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final items = matchInfoItems(
      match: widget.match,
      competition: widget.competition,
      detail: widget.detail,
      venue: widget.venue,
      localKickoffTime: localTime(context, widget.match.startTime),
    );
    // Phase and round are already compactly visible in Hero V3. In a long
    // card they are the first details collapsed; date, venue and officials
    // remain visible. Nothing is discarded and short cards never collapse.
    final canCollapse = items.length > 5;
    final visible = !canCollapse || _expanded
        ? items
        : items
              .where((item) => item.id != 'round' && item.id != 'stage')
              .toList(growable: false);
    return Card(
      key: const ValueKey('match-info-card'),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns =
                constraints.maxWidth >= MatchInfoCard._twoColumnMinWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in MatchInfoGroup.values)
                  if (visible.any((item) => item.group == group)) ...[
                    _MatchInfoGroupSection(
                      group: group,
                      items: visible
                          .where((item) => item.group == group)
                          .toList(growable: false),
                      twoColumns: twoColumns,
                      competitionId: widget.competition.id,
                    ),
                    if (group != visible.last.group)
                      const SizedBox(height: MatchInfoCard._gap),
                  ],
                if (canCollapse) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('match-info-toggle'),
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                      ),
                      label: Text(_expanded ? 'Ver menos' : 'Ver más'),
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

class _MatchInfoGroupSection extends StatelessWidget {
  const _MatchInfoGroupSection({
    required this.group,
    required this.items,
    required this.twoColumns,
    required this.competitionId,
  });

  final MatchInfoGroup group;
  final List<MatchInfoItem> items;
  final bool twoColumns;
  final String competitionId;

  @override
  Widget build(BuildContext context) {
    final rows = <List<MatchInfoItem>>[
      for (var i = 0; i < items.length; i += twoColumns ? 2 : 1)
        items.sublist(i, twoColumns ? (i + 2).clamp(0, items.length) : i + 1),
    ];
    return Semantics(
      container: true,
      label: matchInfoGroupLabel(group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
            child: Text(
              matchInfoGroupLabel(group).toUpperCase(),
              style: const TextStyle(
                color: muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: .7,
              ),
            ),
          ),
          for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
            if (rowIndex > 0) const SizedBox(height: MatchInfoCard._gap),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows[rowIndex].length; i++) ...[
                    if (i > 0) const SizedBox(width: MatchInfoCard._gap),
                    Expanded(
                      child: _MatchInfoTile(
                        rows[rowIndex][i],
                        prominent: rows[rowIndex][i].id == 'competition',
                        onTap: rows[rowIndex][i].id == 'competition'
                            ? () => context.push('/competition/$competitionId')
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MatchInfoTile extends StatelessWidget {
  const _MatchInfoTile(this.item, {this.prominent = false, this.onTap});

  final MatchInfoItem item;
  final bool prominent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = item.secondary;
    final content = Container(
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
                if (secondary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    secondary,
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
    return Semantics(
      key: ValueKey('match-info-${item.id}'),
      button: onTap != null,
      label:
          '${item.label}: ${item.value}'
          '${secondary == null ? '' : '. $secondary'}.',
      excludeSemantics: true,
      child: onTap == null
          ? content
          : InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: content,
            ),
    );
  }
}

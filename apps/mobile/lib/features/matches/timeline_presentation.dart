import '../../core/models.dart';

/// Removes only text already represented by structured fields of this same
/// occurrence. It never resolves identities or guesses aliases from names.
List<String> timelineMetadata({
  required Json event,
  required String typeLabel,
  required String title,
  String? playerName,
  String? assistName,
  String? score,
  String? teamName,
}) {
  String clean(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');
  final represented = <String>{clean(title), clean(typeLabel)};
  // Both names refer to the same already-paired occurrence, not a name match
  // between people. Provider abbreviations must not repeat the canonical name.
  if (playerName != null) {
    represented.add(clean(playerName));
    final raw = event['playerName'];
    if (raw is String && raw.trim().isNotEmpty) represented.add(clean(raw));
  }
  if (assistName != null) {
    for (final name in [assistName, event['assistName']]) {
      if (name is String && name.trim().isNotEmpty) {
        represented.add(clean('Asistencia: $name'));
      }
    }
  }
  String? scoreKey(String text) => RegExp(r'^\d+\s*[-–:]\s*\d+$').hasMatch(text)
      ? text.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp('[-–:]'), '-')
      : null;
  final result = <String>[];
  if (title != typeLabel) result.add(typeLabel);
  for (final raw in (event['detail']?.toString() ?? '').split(' · ')) {
    final part = clean(raw);
    if (part.isEmpty || represented.contains(part)) continue;
    final detailScore = scoreKey(part);
    // An explicit score (or a correction clearing it) supersedes an old
    // standalone score in the provider's free text for this occurrence.
    if (detailScore != null &&
        ((event.containsKey('score') &&
                (event['score'] == null || score != null)) ||
            (score != null && detailScore == scoreKey(score)))) {
      continue;
    }
    if (!result.contains(part)) result.add(part);
  }
  if (teamName != null && !result.contains(teamName)) result.add(teamName);
  return result;
}

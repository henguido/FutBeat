import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Host rasterization differs even with the same Flutter SDK and bundled fonts.
// Only reviewed Linux renders use a separate baseline.
// All comparisons still use Flutter's exact, default pixel comparator.
const linuxGoldenNames = <String>{
  'matches',
  'match',
  'competition',
  'team',
  'explore',
  'player',
  'favorites_hub_competitions',
  'favorites_hub_empty',
  'favorites_hub_mixed',
  'favorites_hub_players',
  'favorites_hub_teams',
  'lineups_match_center_away',
  'lineups_match_center_home',
  'lineups_match_center_top',
  'lineups_polish_away_viewport',
  'lineups_polish_home_viewport',
  'lineups_polish_synthetic',
  'standings_match_context',
  'timeline_v2_cards_substitution',
  'timeline_v2_complete',
  'timeline_v2_empty',
  'timeline_v2_goal_assist',
  'timeline_v2_live',
  'timeline_v2_own_goal',
};

String platformGoldenPath(String key, {String? platform}) {
  if ((platform ?? Platform.operatingSystem) == 'linux') {
    for (final name in linuxGoldenNames) {
      if (key == 'goldens/$name.png') return 'goldens/linux/$name.png';
    }
  }
  // No missing-reference fallback and no opt-out for new/unknown goldens.
  return key;
}

Matcher matchesPlatformGolden(String key, {int? version}) =>
    matchesGoldenFile(platformGoldenPath(key), version: version);

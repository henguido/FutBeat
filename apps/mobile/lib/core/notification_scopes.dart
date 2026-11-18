/// N1's effective server matrix. No client defaults invent provider coverage.
class NotificationScopeChoice {
  const NotificationScopeChoice(this.enabled, this.explicit, this.coverage);
  final bool enabled;
  final bool? explicit;
  final String coverage;
}

class NotificationScopes {
  const NotificationScopes(this.scopes);
  final Map<String, Map<String, NotificationScopeChoice>> scopes;

  factory NotificationScopes.fromJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['scopes'] is! Map) {
      throw const FormatException('Invalid notification scopes');
    }
    final result = <String, Map<String, NotificationScopeChoice>>{};
    for (final scope in notificationScopeKinds.keys) {
      final entries = (value['scopes'] as Map)[scope];
      if (entries is! Map) throw const FormatException('Missing scope');
      result[scope] = {};
      for (final kind in notificationScopeKinds[scope]!) {
        final choice = entries[kind];
        if (choice == null) continue;
        if (choice is! Map ||
            choice['enabled'] is! bool ||
            (choice['explicit'] != null && choice['explicit'] is! bool) ||
            !const {
              'available',
              'partial',
              'rare',
            }.contains(choice['coverage'])) {
          throw const FormatException('Invalid scope choice');
        }
        result[scope]![kind] = NotificationScopeChoice(
          choice['enabled'] as bool,
          choice['explicit'] as bool?,
          choice['coverage'] as String,
        );
      }
    }
    return NotificationScopes(result);
  }
}

const notificationScopesEnabled = bool.fromEnvironment(
  'FUTBEAT_NOTIFICATION_SCOPES_ENABLED',
);

// Exact pairs accepted by Claude's N1 catalog. Not per-entity overrides:
// choices apply independently to each following type, as defined by N1.
const notificationScopeKinds = {
  'player': [
    'starter',
    'bench',
    'goal',
    'penalty_goal',
    'assist',
    'sub_in',
    'sub_out',
    'yellow_card',
    'red_card',
    'penalty_missed',
    'goal_annulled',
  ],
  'team': [
    'kickoff',
    'halftime',
    'final',
    'goal_for',
    'goal_against',
    'red_card',
    'penalty_missed',
    'goal_annulled',
  ],
  'match': [
    'kickoff',
    'halftime',
    'final',
    'goal',
    'red_card',
    'penalty_missed',
    'goal_annulled',
    'yellow_card',
    'substitution',
  ],
};

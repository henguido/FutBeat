import 'package:flutter/material.dart';

import '../../core/push.dart';

enum NotificationOptionGroup { matches, followedEntities, other }

/// One switch in Perfil → Notificaciones and in the onboarding alerts step.
class NotificationOption {
  const NotificationOption({
    required this.title,
    required this.icon,
    required this.group,
    required this.serverKey,
    required this.value,
    required this.update,
  });

  final String title;
  final IconData icon;
  final NotificationOptionGroup group;

  /// Server preference key the switch writes (see [UserProfileSettings]).
  final String serverKey;
  final bool Function(UserProfileSettings) value;
  final UserProfileSettings Function(UserProfileSettings, bool) update;
}

/// The approved alert types, in display order.
final notificationOptions = <NotificationOption>[
  NotificationOption(
    title: 'Avísame al iniciar el partido',
    icon: Icons.play_circle_outline,
    group: NotificationOptionGroup.matches,
    serverKey: 'notify_kickoff',
    value: (s) => s.notifyKickoff,
    update: (s, v) => s.copyWith(notifyKickoff: v),
  ),
  NotificationOption(
    title: 'Avísame cuando haya un gol',
    icon: Icons.sports_soccer,
    group: NotificationOptionGroup.matches,
    serverKey: 'notify_goals',
    value: (s) => s.notifyGoals,
    update: (s, v) => s.copyWith(notifyGoals: v),
  ),
  NotificationOption(
    title: 'Avísame si corrigen o anulan un gol',
    icon: Icons.undo,
    group: NotificationOptionGroup.matches,
    serverKey: 'notify_goal_annulled',
    value: (s) => s.notifyGoalAnnulled,
    update: (s, v) => s.copyWith(notifyGoalAnnulled: v),
  ),
  NotificationOption(
    title: 'Avísame cuando haya una tarjeta roja',
    icon: Icons.style_outlined,
    group: NotificationOptionGroup.matches,
    serverKey: 'notify_red_cards',
    value: (s) => s.notifyRedCards,
    update: (s, v) => s.copyWith(notifyRedCards: v),
  ),
  NotificationOption(
    title: 'Avísame al terminar el partido',
    icon: Icons.flag_outlined,
    group: NotificationOptionGroup.matches,
    serverKey: 'notify_final',
    value: (s) => s.notifyFinal,
    update: (s, v) => s.copyWith(notifyFinal: v),
  ),
  NotificationOption(
    title: 'Jugador seguido en la alineación titular',
    icon: Icons.groups_outlined,
    group: NotificationOptionGroup.followedEntities,
    serverKey: 'notify_player_starter',
    value: (s) => s.notifyPlayerStarter,
    update: (s, v) => s.copyWith(notifyPlayerStarter: v),
  ),
  NotificationOption(
    title: 'Jugador seguido en el banquillo',
    icon: Icons.event_seat_outlined,
    group: NotificationOptionGroup.followedEntities,
    serverKey: 'notify_player_bench',
    value: (s) => s.notifyPlayerBench,
    update: (s, v) => s.copyWith(notifyPlayerBench: v),
  ),
  NotificationOption(
    title: 'Jugador seguido entra al campo',
    icon: Icons.arrow_circle_up_outlined,
    group: NotificationOptionGroup.followedEntities,
    serverKey: 'notify_player_sub_in',
    value: (s) => s.notifyPlayerSubIn,
    update: (s, v) => s.copyWith(notifyPlayerSubIn: v),
  ),
  NotificationOption(
    title: 'Jugador seguido sale del campo',
    icon: Icons.arrow_circle_down_outlined,
    group: NotificationOptionGroup.followedEntities,
    serverKey: 'notify_player_sub_out',
    value: (s) => s.notifyPlayerSubOut,
    update: (s, v) => s.copyWith(notifyPlayerSubOut: v),
  ),
  NotificationOption(
    title: 'Noticias de tus seguidos',
    icon: Icons.article_outlined,
    group: NotificationOptionGroup.other,
    serverKey: 'notify_news',
    value: (s) => s.notifyNews,
    update: (s, v) => s.copyWith(notifyNews: v),
  ),
  NotificationOption(
    title: 'Transferencias de tus seguidos',
    icon: Icons.swap_horiz,
    group: NotificationOptionGroup.other,
    serverKey: 'notify_transfers',
    value: (s) => s.notifyTransfers,
    update: (s, v) => s.copyWith(notifyTransfers: v),
  ),
];

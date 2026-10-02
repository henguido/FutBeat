import 'package:flutter/material.dart';

import '../../core/push.dart';

/// One switch in Perfil → Notificaciones and in the onboarding alerts step.
class NotificationOption {
  const NotificationOption({
    required this.title,
    required this.icon,
    required this.serverKey,
    required this.value,
    required this.update,
  });

  final String title;
  final IconData icon;

  /// Server preference key the switch writes (see [UserProfileSettings]).
  final String serverKey;
  final bool Function(UserProfileSettings) value;
  final UserProfileSettings Function(UserProfileSettings, bool) update;
}

/// The approved alert types, in display order.
final notificationOptions = <NotificationOption>[
  NotificationOption(
    title: 'Inicio de partido',
    icon: Icons.play_circle_outline,
    serverKey: 'notify_kickoff',
    value: (s) => s.notifyKickoff,
    update: (s, v) => s.copyWith(notifyKickoff: v),
  ),
  NotificationOption(
    title: 'Gol',
    icon: Icons.sports_soccer,
    serverKey: 'notify_goals',
    value: (s) => s.notifyGoals,
    update: (s, v) => s.copyWith(notifyGoals: v),
  ),
  NotificationOption(
    title: 'Gol anulado/corregido',
    icon: Icons.undo,
    serverKey: 'notify_goal_annulled',
    value: (s) => s.notifyGoalAnnulled,
    update: (s, v) => s.copyWith(notifyGoalAnnulled: v),
  ),
  NotificationOption(
    title: 'Tarjeta roja',
    icon: Icons.style_outlined,
    serverKey: 'notify_red_cards',
    value: (s) => s.notifyRedCards,
    update: (s, v) => s.copyWith(notifyRedCards: v),
  ),
  NotificationOption(
    title: 'Resultado final',
    icon: Icons.flag_outlined,
    serverKey: 'notify_final',
    value: (s) => s.notifyFinal,
    update: (s, v) => s.copyWith(notifyFinal: v),
  ),
  NotificationOption(
    title: 'Jugador favorito titular',
    icon: Icons.groups_outlined,
    serverKey: 'notify_player_starter',
    value: (s) => s.notifyPlayerStarter,
    update: (s, v) => s.copyWith(notifyPlayerStarter: v),
  ),
  NotificationOption(
    title: 'Jugador favorito en el banquillo',
    icon: Icons.event_seat_outlined,
    serverKey: 'notify_player_bench',
    value: (s) => s.notifyPlayerBench,
    update: (s, v) => s.copyWith(notifyPlayerBench: v),
  ),
  NotificationOption(
    title: 'Entra al campo',
    icon: Icons.arrow_circle_up_outlined,
    serverKey: 'notify_player_sub_in',
    value: (s) => s.notifyPlayerSubIn,
    update: (s, v) => s.copyWith(notifyPlayerSubIn: v),
  ),
  NotificationOption(
    title: 'Sale del campo',
    icon: Icons.arrow_circle_down_outlined,
    serverKey: 'notify_player_sub_out',
    value: (s) => s.notifyPlayerSubOut,
    update: (s, v) => s.copyWith(notifyPlayerSubOut: v),
  ),
  NotificationOption(
    title: 'Noticias',
    icon: Icons.article_outlined,
    serverKey: 'notify_news',
    value: (s) => s.notifyNews,
    update: (s, v) => s.copyWith(notifyNews: v),
  ),
  NotificationOption(
    title: 'Transferencias',
    icon: Icons.swap_horiz,
    serverKey: 'notify_transfers',
    value: (s) => s.notifyTransfers,
    update: (s, v) => s.copyWith(notifyTransfers: v),
  ),
];

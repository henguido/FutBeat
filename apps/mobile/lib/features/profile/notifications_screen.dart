import 'package:flutter/widgets.dart';

import 'notifications_screen_v2.dart';

/// Compatibility entry point for callers that still import the original
/// screen name. The profile route and legacy references share the V2 UX.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) => const NotificationsScreenV2();
}

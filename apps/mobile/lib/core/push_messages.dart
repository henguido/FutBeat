import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'push.dart';
import 'theme.dart';

/// A push as the app sees it, independent of Firebase.
class PushMessage {
  const PushMessage({this.title, this.body, this.data = const {}});

  factory PushMessage.fromRemote(RemoteMessage message) => PushMessage(
    title: message.notification?.title ?? message.data['title']?.toString(),
    body: message.notification?.body ?? message.data['body']?.toString(),
    data: Map<String, dynamic>.from(message.data),
  );

  final String? title;
  final String? body;
  final Map<String, dynamic> data;

  /// Screen this push opens, or null when it has no target.
  String? get route => pushRouteFor(data);
}

/// `data.matchId` → match, else `data.playerId` → player, else
/// `data.teamId` → team, news → News. Ids are path segments, so they are encoded.
String? pushRouteFor(Map<String, dynamic> data) {
  String? id(String key) {
    final value = data[key]?.toString().trim();
    return value == null || value.isEmpty ? null : Uri.encodeComponent(value);
  }

  final match = id('matchId');
  if (match != null) return '/match/$match';
  final player = id('playerId');
  if (player != null) return '/player/$player';
  final team = id('teamId');
  if (team != null) return '/team/$team';
  if (data['type']?.toString().toUpperCase() == 'NEWS') return '/news';
  return null;
}

abstract interface class PushMessageSource {
  /// Pushes received while the app is in the foreground.
  Stream<PushMessage> get foreground;

  /// Pushes tapped while the app was in the background.
  Stream<PushMessage> get opened;

  /// The push that launched the app from a terminated state, if any.
  Future<PushMessage?> initial();
}

class FirebasePushMessages implements PushMessageSource {
  @override
  Stream<PushMessage> get foreground async* {
    await ensureFirebase();
    yield* FirebaseMessaging.onMessage.map(PushMessage.fromRemote);
  }

  @override
  Stream<PushMessage> get opened async* {
    await ensureFirebase();
    yield* FirebaseMessaging.onMessageOpenedApp.map(PushMessage.fromRemote);
  }

  @override
  Future<PushMessage?> initial() async {
    await ensureFirebase();
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message == null ? null : PushMessage.fromRemote(message);
  }
}

/// Android channel the server targets (`android.notification.channel_id`).
const matchAlertsChannelId = 'futbeat_match_alerts';
const notificationsMethodChannel = MethodChannel('futbeat/notifications');

/// Creates the high-importance "Partidos" channel on Android 8+ (handled by
/// MainActivity). Does nothing unless push is configured and on Android;
/// never throws.
Future<bool> ensureAndroidNotificationChannel({
  bool configured = PushService.configured,
  bool? android,
  MethodChannel channel = notificationsMethodChannel,
}) async {
  if (!configured || !(android ?? Platform.isAndroid)) return false;
  try {
    final created = await channel.invokeMethod<bool>(
      'createNotificationChannel',
      {
        'id': matchAlertsChannelId,
        'name': 'Partidos',
        'description': 'Alertas de partidos y jugadores',
      },
    );
    return created ?? false;
  } catch (_) {
    return false;
  }
}

/// Null unless push is configured for this build: nothing touches Firebase
/// in builds without the push flags.
final pushMessageSourceProvider = Provider<PushMessageSource?>(
  (ref) => PushService.configured ? FirebasePushMessages() : null,
);

/// Shows foreground pushes as an in-app banner and routes tapped pushes to
/// their match, player or team screen.
class PushMessageRouter {
  PushMessageRouter({
    required this.source,
    required this.router,
    required this.messenger,
  });

  final PushMessageSource source;
  final GoRouter router;
  final GlobalKey<ScaffoldMessengerState> messenger;

  final _subscriptions = <StreamSubscription<PushMessage>>[];
  String? _pending;
  bool _started = false;

  /// Routes before the app shell (startup gate, onboarding) would replace a
  /// pushed screen, so a tap waits until the user reaches the shell.
  static bool _blocking(String path) =>
      path == '/start' || path.startsWith('/onboarding');

  void start() {
    if (_started) return;
    _started = true;
    router.routerDelegate.addListener(_flush);
    _subscriptions
      ..add(source.foreground.listen(showBanner, onError: (_) {}))
      ..add(source.opened.listen(open, onError: (_) {}));
    unawaited(
      source.initial().then((message) {
        if (message != null) open(message);
      }, onError: (_) {}),
    );
  }

  String get _location => router.routerDelegate.currentConfiguration.uri.path;

  void open(PushMessage message) {
    final route = message.route;
    if (route == null) return;
    _pending = route;
    _flush();
  }

  void _flush() {
    final route = _pending;
    if (route == null) return;
    final location = _location;
    if (location.isEmpty || _blocking(location)) return;
    _pending = null;
    if (location == route) return;
    router.push(route);
  }

  void showBanner(PushMessage message) {
    final state = messenger.currentState;
    final title = message.title?.trim() ?? '';
    final body = message.body?.trim() ?? '';
    if (state == null || (title.isEmpty && body.isEmpty)) return;
    final route = message.route;
    state
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('push-banner'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          backgroundColor: panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF2B373D)),
          ),
          content: Row(
            children: [
              const Icon(Icons.notifications_active, color: lime),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    if (body.isNotEmpty)
                      Text(
                        body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
          action: route == null
              ? null
              : SnackBarAction(
                  label: 'Ver',
                  textColor: lime,
                  onPressed: () => open(message),
                ),
        ),
      );
  }

  void dispose() {
    router.routerDelegate.removeListener(_flush);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}

/// True when [next] adds a follow to an already loaded [previous] set.
bool followAdded(Set<String>? previous, Set<String>? next) =>
    previous != null &&
    next != null &&
    next.length > previous.length &&
    !previous.containsAll(next);

/// Offers to enable notifications on this device when
/// [PushService.shouldPromptForNotifications] allows it (push configured,
/// signed in, not enabled, not offered in the last week). Dismissible.
Future<void> maybeOfferNotifications(
  BuildContext context,
  PushService service,
) async {
  if (!await service.shouldPromptForNotifications()) return;
  if (!context.mounted) return;
  await service.markNotificationPromptShown();
  if (!context.mounted) return;
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.notifications_active, color: lime, size: 36),
              const SizedBox(height: 12),
              const Text(
                'Activa las notificaciones',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              const Text(
                'Te avisamos de goles, resultados y alineaciones de lo que sigues. '
                'Puedes elegir los tipos en Perfil → Notificaciones.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Activar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Ahora no'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (accepted != true) return;
  String text;
  try {
    await service.enable();
    text = 'Notificaciones activadas.';
  } catch (_) {
    text = 'No se pudieron activar las notificaciones.';
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }
}

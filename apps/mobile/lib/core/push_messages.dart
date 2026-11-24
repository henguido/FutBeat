import 'dart:async';
import 'dart:convert';
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
  const PushMessage({
    this.title,
    this.body,
    this.data = const {},
    this.deliveryId,
  });

  factory PushMessage.fromRemote(RemoteMessage message) => PushMessage(
    title: message.notification?.title ?? message.data['title']?.toString(),
    body: message.notification?.body ?? message.data['body']?.toString(),
    data: Map<String, dynamic>.from(message.data),
    deliveryId: message.messageId,
  );

  final String? title;
  final String? body;
  final Map<String, dynamic> data;
  final String? deliveryId;

  /// Optional server metadata, never a client-side recipient decision.
  /// FCM carries structured values as JSON strings. Older payloads remain valid.
  Set<String>? get scopes {
    final value = _structured('scopes');
    if (value is! List ||
        value.any(
          (entry) => !const {'player', 'team', 'match'}.contains(entry),
        )) {
      return null;
    }
    return Set<String>.unmodifiable(value.cast<String>());
  }

  Map<String, String>? get scopeKinds {
    final value = _structured('scopeKinds');
    if (value is! Map) return null;
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (!const {'player', 'team', 'match'}.contains(entry.key) ||
          _identifier(entry.value) == null) {
        return null;
      }
      result[entry.key as String] = _identifier(entry.value)!;
    }
    return Map.unmodifiable(result);
  }

  /// Unknown is distinct from false; message wording is never evidence.
  bool? get penalty => switch (data['penalty']) {
    true || 'true' => true,
    false || 'false' => false,
    _ => null,
  };

  String? get playerRole {
    final value = data['playerRole'];
    return const {'primary', 'assist', 'starter', 'bench'}.contains(value)
        ? value as String
        : null;
  }

  /// A player ID alone (including in a legacy team alert) is not personal scope.
  String? get personalPlayerId =>
      scopes?.contains('player') == true ? _identifier(data['playerId']) : null;

  Object? _structured(String key) {
    final value = data[key];
    if (value is! String) return value;
    if (value.length > 4096) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  static String? _identifier(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    return value.isEmpty ||
            value == '.' ||
            value == '..' ||
            value.length > 200 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
        ? null
        : value;
  }

  /// Server outbox identity wins over a transport retry's new FCM message ID.
  /// Never infer identity from text, player names or the match alone: a goal
  /// correction and a new goal must remain separate notifications.
  String? get deduplicationId {
    final notification = _identifier(data['notificationId']);
    if (notification != null) return notification;
    final event = _identifier(data['eventId']);
    // A cancellation of a goal must not disappear behind the original goal.
    if (event != null) {
      return 'event:$event:${_identifier(data['type']) ?? 'unknown'}';
    }
    return _identifier(deliveryId);
  }

  /// Screen this push opens, or null when it has no target.
  String? get route => pushRouteFor(data);
}

/// `data.matchId` → match, else `data.playerId` → player, else
/// `data.teamId` → team, news → News. Ids are path segments, so they are encoded.
String? pushRouteFor(Map<String, dynamic> data) {
  String? id(String key) {
    final raw = data[key];
    if (raw is! String) return null;
    final value = raw.trim();
    // A target is an identifier, never an arbitrary object or URI dot segment.
    // Preserve older IDs (including encoded separators) without guessing IDs
    // from a player's name or another entity in the payload.
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return null;
    }
    return Uri.encodeComponent(value);
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
  bool _disposed = false;
  final Set<String> _shown = {};
  final Set<String> _opened = {};

  // Bounded per router lifetime. Separate channels let a banner be tapped
  // once, even though that delivery has already been shown in the foreground.
  bool _remember(PushMessage message, Set<String> seen) {
    final id = message.deduplicationId;
    if (id == null) return true; // Legacy messages have no provable identity.
    if (!seen.add(id)) return false;
    if (seen.length > 128) seen.remove(seen.first);
    return true;
  }

  /// Routes before the app shell (startup gate, onboarding) would replace a
  /// pushed screen, so a tap waits until the user reaches the shell.
  static bool _blocking(String path) =>
      path == '/start' || path.startsWith('/onboarding');

  void start() {
    if (_started || _disposed) return;
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
    if (_disposed) return;
    final route = message.route;
    if (route == null) return;
    if (!_remember(message, _opened)) return;
    _pending = route;
    _flush();
  }

  void _flush() {
    if (_disposed) return;
    final route = _pending;
    if (route == null) return;
    final location = _location;
    if (location.isEmpty || _blocking(location)) return;
    _pending = null;
    if (location == route) return;
    router.push(route);
  }

  void showBanner(PushMessage message) {
    if (_disposed) return;
    final state = messenger.currentState;
    final title = message.title?.trim() ?? '';
    final body = message.body?.trim() ?? '';
    if (state == null || (title.isEmpty && body.isEmpty)) return;
    if (!_remember(message, _shown)) return;
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
    if (_disposed) return;
    _disposed = true;
    _pending = null;
    router.routerDelegate.removeListener(_flush);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _shown.clear();
    _opened.clear();
  }
}

/// True when [next] adds a follow to an already loaded [previous] set.
/// A follow the user added here: new keys that did not arrive from an
/// account sync ([synced], see [PushService.syncedFollows]).
bool followAdded(
  Set<String>? previous,
  Set<String>? next, {
  Set<String> synced = const {},
}) =>
    previous != null &&
    next != null &&
    next.difference(previous).difference(synced).isNotEmpty;

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

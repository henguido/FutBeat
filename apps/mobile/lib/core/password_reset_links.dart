import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'push.dart';

/// Password-reset links from Android (the App Link or the web fallback's
/// com.futbeat.futbeat://password-reset), redeemed only once navigation is
/// ready.
///
/// A cold start delivers the initial link while the app is still on /start
/// (StartupGate), or before the router has a Navigator. Redeeming it then
/// spent the one-time token and lost the new-password screen: with no
/// Navigator the screen was never pushed, and a screen pushed over /start was
/// removed by StartupGate's go(). A link now waits until the router has left
/// /start, is redeemed with the Navigator of that moment, one at a time, and
/// the same link is handled once per process (Android can deliver it again,
/// e.g. when the activity is recreated).
class PasswordResetLinkQueue {
  PasswordResetLinkQueue({required this.router, required this.handle});

  final GoRouter router;

  /// Redeems [link] and opens the new-password screen on [navigator];
  /// completes when that screen closes.
  final Future<void> Function(Uri link, NavigatorState navigator) handle;

  final _pending = <Uri>[];
  final _seen = <String>{};
  bool _busy = false;
  bool _listening = false;
  bool _frameScheduled = false;
  bool _disposed = false;

  /// Only /start replaces the stack on its own (StartupGate's go()).
  /// Onboarding is not blocking: a fresh install asks for the reset link
  /// from the onboarding account step.
  static bool _blocking(String path) => path.isEmpty || path == '/start';

  void add(Uri link) {
    if (_disposed || !PushService.isPasswordResetLink(link)) return;
    if (!_seen.add(link.toString())) return;
    _pending.add(link);
    if (!_listening) {
      _listening = true;
      router.routerDelegate.addListener(_flush);
    }
    _flush();
  }

  String get _location {
    try {
      return router.routerDelegate.currentConfiguration.uri.path;
    } catch (_) {
      return '';
    }
  }

  /// Runs after the next frame: the router notifies a route change before
  /// its Navigator rebuilds, and a screen pushed then would sit on the page
  /// being replaced (and go with it). It also covers a Navigator that is not
  /// mounted yet, which the router does not notify.
  void _flush() {
    if (_disposed || _busy || _pending.isEmpty || _frameScheduled) return;
    _frameScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _frameScheduled = false;
        _run();
      })
      ..scheduleFrame();
  }

  void _run() {
    if (_disposed || _busy || _pending.isEmpty) return;
    final navigator = router.routerDelegate.navigatorKey.currentState;
    if (navigator == null) {
      _flush();
      return;
    }
    if (_blocking(_location)) return; // The next route change flushes.
    final link = _pending.removeAt(0);
    _busy = true;
    unawaited(
      Future.sync(() => handle(link, navigator))
          .catchError((Object _) {})
          .whenComplete(() {
            _busy = false;
            _flush();
          }),
    );
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    if (_listening) router.routerDelegate.removeListener(_flush);
  }
}

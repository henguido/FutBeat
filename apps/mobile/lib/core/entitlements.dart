import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'providers.dart';
import 'push.dart';

/// FutBeat plans. Every feature the app has today is FREE; PREMIUM only
/// removes ads and unlocks future advanced features.
enum Plan { free, premium }

/// Everything the UI may gate. UI code asks [Entitlements.allows]; it never
/// checks the plan itself.
enum Feature {
  allMatches,
  favorites,
  live,
  matchCenter,
  lineups,
  importantAlerts,
  playerAlerts,

  /// No ads (PREMIUM).
  adFree,

  /// Future advanced features (PREMIUM).
  advanced,
}

const _freeFeatures = {
  Feature.allMatches,
  Feature.favorites,
  Feature.live,
  Feature.matchCenter,
  Feature.lineups,
  Feature.importantAlerts,
  Feature.playerAlerts,
};

/// Where the current entitlement came from.
enum EntitlementOrigin {
  /// Nothing known yet: FREE.
  none,

  /// Last verified grant stored on this device for this account.
  cache,

  /// Just verified by the entitlement source (store / server).
  verified,
}

/// A verified plan for one account (or the guest on this device).
class EntitlementGrant {
  const EntitlementGrant({
    required this.plan,
    required this.verifiedAt,
    this.expiresAt,
    this.productId,
  });

  final Plan plan;
  final DateTime verifiedAt;

  /// End of the paid period; null = no expiry (one-time purchase).
  final DateTime? expiresAt;
  final String? productId;

  Map<String, Object?> toJson() => {
    'plan': plan.name,
    'verifiedAt': verifiedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'productId': productId,
  };

  static EntitlementGrant? fromJson(Object? json) {
    if (json is! Map) return null;
    final plan = Plan.values.where((p) => p.name == json['plan']).firstOrNull;
    final verifiedAt = DateTime.tryParse('${json['verifiedAt']}');
    if (plan == null || verifiedAt == null) return null;
    final rawExpiry = json['expiresAt'];
    final expiresAt = rawExpiry == null
        ? null
        : DateTime.tryParse('$rawExpiry');
    if (rawExpiry != null && expiresAt == null) return null;
    final productId = json['productId'];
    return EntitlementGrant(
      plan: plan,
      verifiedAt: verifiedAt,
      expiresAt: expiresAt,
      productId: productId is String ? productId : null,
    );
  }
}

/// The single source of truth the UI reads.
class Entitlements {
  const Entitlements({
    required this.accountKey,
    this.plan = Plan.free,
    this.origin = EntitlementOrigin.none,
    this.expiresAt,
  });

  /// [entitlementAccountKey] of the account this belongs to.
  final String accountKey;
  final Plan plan;
  final EntitlementOrigin origin;
  final DateTime? expiresAt;

  bool get isPremium => plan == Plan.premium;
  bool allows(Feature feature) =>
      plan == Plan.premium || _freeFeatures.contains(feature);
  bool get showsAds => !allows(Feature.adFree);
}

/// Storage key owner: one entitlement per FutBeat account, plus the guest
/// on this device. An account's plan never applies to another account.
String entitlementAccountKey(String? accountId) =>
    accountId == null ? 'guest' : 'account:$accountId';

/// Offline tolerance after a paid period ends (the store also retries
/// renewals for a few days before cancelling).
const entitlementGracePeriod = Duration(days: 3);

/// Whether a cached grant still counts at [now].
bool grantActive(EntitlementGrant grant, DateTime now) {
  if (grant.plan == Plan.free) return false;
  final expiresAt = grant.expiresAt;
  return expiresAt == null ||
      now.isBefore(expiresAt.add(entitlementGracePeriod));
}

/// Answer of an [EntitlementSource].
class EntitlementCheck {
  const EntitlementCheck.unavailable() : available = false, grant = null;

  /// [grant] null = the source confirmed there is no active purchase.
  const EntitlementCheck.answered(this.grant) : available = true;

  /// False when the source could not answer (offline, not wired yet): the
  /// cached grant is kept.
  final bool available;
  final EntitlementGrant? grant;
}

/// Verifies purchases (Google Play Billing + server verification later).
abstract interface class EntitlementSource {
  Future<EntitlementCheck> check(String? accountId);

  /// "Restore purchases": re-reads the store's purchases for this user.
  Future<EntitlementCheck> restore(String? accountId);
}

/// Until billing exists nothing is verified: everyone keeps FREE (or the
/// last cached grant).
class UnavailableEntitlementSource implements EntitlementSource {
  const UnavailableEntitlementSource();

  @override
  Future<EntitlementCheck> check(String? accountId) async =>
      const EntitlementCheck.unavailable();

  @override
  Future<EntitlementCheck> restore(String? accountId) async =>
      const EntitlementCheck.unavailable();
}

abstract interface class EntitlementStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureEntitlementStore implements EntitlementStore {
  const SecureEntitlementStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

String entitlementStorageKey(String accountKey) =>
    'futbeat.entitlement.$accountKey';

final entitlementSourceProvider = Provider<EntitlementSource>(
  (ref) => const UnavailableEntitlementSource(),
);

final entitlementStoreProvider = Provider<EntitlementStore>(
  (ref) => const SecureEntitlementStore(),
);

final entitlementClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Signed-in account id (null = guest), following sign-in / sign-out.
///
/// Subscribes to [PushService.accountChanges] before taking the snapshot,
/// so a change landing right after it is never lost.
final currentAccountProvider = StreamProvider<String?>((ref) {
  if (!ref.watch(liveRealtimeConfigProvider).isConfigured) {
    return Stream.value(null);
  }
  final service = ref.watch(pushServiceProvider);
  final accounts = StreamController<String?>();
  final changes = service.accountChanges.listen(accounts.add);
  accounts.add(service.accountId);
  ref.onDispose(() {
    unawaited(changes.cancel());
    unawaited(accounts.close());
  });
  return accounts.stream;
});

final entitlementsProvider =
    NotifierProvider<EntitlementsController, Entitlements>(
      EntitlementsController.new,
    );

class EntitlementsController extends Notifier<Entitlements> {
  String? _accountId;

  /// Bumped by every verification request and every applied answer: an
  /// answer is only applied while its ticket is still the latest.
  int _ticket = 0;
  Future<void> _applying = Future.value();
  Timer? _expiry;

  @override
  Entitlements build() {
    _accountId = ref.watch(currentAccountProvider).value;
    final key = entitlementAccountKey(_accountId);
    ref.onDispose(() {
      _expiry?.cancel();
      _expiry = null;
    });
    unawaited(_loadCache(key));
    return Entitlements(accountKey: key);
  }

  EntitlementStore get _store => ref.read(entitlementStoreProvider);
  DateTime _now() => ref.read(entitlementClockProvider)();

  bool _current(String key) => ref.mounted && state.accountKey == key;

  /// Sets the state and arms the end of its grace period.
  void _set(Entitlements next) {
    state = next;
    _expiry?.cancel();
    _expiry = null;
    final expiresAt = next.expiresAt;
    if (!next.isPremium || expiresAt == null) return;
    final remaining = expiresAt.add(entitlementGracePeriod).difference(_now());
    if (remaining <= Duration.zero) {
      _expireIfDue();
    } else {
      _expiry = Timer(remaining, _expireIfDue);
    }
  }

  /// PREMIUM whose paid period plus grace has ended becomes FREE, unless a
  /// newer verification renews it.
  void _expireIfDue() {
    if (!ref.mounted) return;
    final expiresAt = state.expiresAt;
    if (!state.isPremium || expiresAt == null) return;
    if (_now().isBefore(expiresAt.add(entitlementGracePeriod))) {
      _set(state); // Fired early (clock change): re-arm.
      return;
    }
    final key = state.accountKey;
    _set(Entitlements(accountKey: key));
    unawaited(
      _store.delete(entitlementStorageKey(key)).catchError((Object _) {}),
    );
  }

  Future<void> _loadCache(String key) async {
    EntitlementGrant? grant;
    try {
      final raw = await _store.read(entitlementStorageKey(key));
      grant = raw == null ? null : EntitlementGrant.fromJson(jsonDecode(raw));
    } catch (_) {
      grant = null;
    }
    if (!_current(key) || state.origin == EntitlementOrigin.verified) return;
    if (grant != null && grantActive(grant, _now())) {
      _set(
        Entitlements(
          accountKey: key,
          plan: grant.plan,
          origin: EntitlementOrigin.cache,
          expiresAt: grant.expiresAt,
        ),
      );
    }
  }

  /// Re-verifies with the entitlement source (app start, resume).
  Future<void> refresh() =>
      _verify((source, accountId) => source.check(accountId));

  /// "Restaurar compras".
  Future<void> restore() =>
      _verify((source, accountId) => source.restore(accountId));

  Future<void> _verify(
    Future<EntitlementCheck> Function(EntitlementSource, String?) ask,
  ) async {
    final key = state.accountKey;
    final accountId = _accountId;
    final ticket = ++_ticket;
    EntitlementCheck? check;
    try {
      check = await ask(ref.read(entitlementSourceProvider), accountId);
    } catch (_) {
      check = null; // Offline or store error: keep what is still valid.
    }
    if (ticket != _ticket || !_current(key)) return;
    if (check == null || !check.available) {
      _expireIfDue();
      return;
    }
    await _apply(check.grant, key, ticket);
  }

  /// Records a verified answer for the current account. null = verified
  /// FREE: any cached PREMIUM is dropped. Supersedes pending verifications.
  Future<void> apply(EntitlementGrant? grant) =>
      _apply(grant, state.accountKey, ++_ticket);

  /// Answers are written one at a time, and only while [ticket] is the
  /// latest, so an older answer can never replace a newer one.
  Future<void> _apply(EntitlementGrant? grant, String key, int ticket) {
    final run = _applying.then((_) async {
      if (ticket != _ticket) return;
      final active = grant != null && grantActive(grant, _now());
      try {
        if (active) {
          await _store.write(
            entitlementStorageKey(key),
            jsonEncode(grant.toJson()),
          );
        } else {
          await _store.delete(entitlementStorageKey(key));
        }
      } catch (_) {
        // The in-memory answer still applies for this session.
      }
      if (ticket != _ticket || !_current(key)) return;
      _set(
        Entitlements(
          accountKey: key,
          plan: active ? grant.plan : Plan.free,
          origin: EntitlementOrigin.verified,
          expiresAt: active ? grant.expiresAt : null,
        ),
      );
    });
    _applying = run.catchError((Object _) {});
    return run;
  }
}

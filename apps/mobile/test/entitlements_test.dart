import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/entitlements.dart';

class _MemoryStore implements EntitlementStore {
  final values = <String, String>{};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Source implements EntitlementSource {
  EntitlementCheck answer = const EntitlementCheck.unavailable();
  Object? error;
  final asked = <String?>[];
  final restored = <String?>[];

  @override
  Future<EntitlementCheck> check(String? accountId) async {
    asked.add(accountId);
    if (error != null) throw error!;
    return answer;
  }

  @override
  Future<EntitlementCheck> restore(String? accountId) async {
    restored.add(accountId);
    if (error != null) throw error!;
    return answer;
  }
}

final _now = DateTime.utc(2026, 10, 4, 12);

EntitlementGrant _premium({DateTime? expiresAt}) => EntitlementGrant(
  plan: Plan.premium,
  verifiedAt: _now.subtract(const Duration(days: 1)),
  expiresAt: expiresAt,
  productId: 'futbeat_premium_monthly',
);

({
  ProviderContainer container,
  _MemoryStore store,
  _Source source,
  StreamController<String?> accounts,
})
_setup({Map<String, String> stored = const {}, DateTime? now}) {
  final store = _MemoryStore()..values.addAll(stored);
  final source = _Source();
  final accounts = StreamController<String?>();
  final container = ProviderContainer(
    overrides: [
      currentAccountProvider.overrideWith((ref) => accounts.stream),
      entitlementStoreProvider.overrideWithValue(store),
      entitlementSourceProvider.overrideWithValue(source),
      entitlementClockProvider.overrideWithValue(() => now ?? _now),
    ],
  );
  final keepAlive = container.listen(entitlementsProvider, (_, _) {});
  addTearDown(() {
    keepAlive.close();
    container.dispose();
    accounts.close();
  });
  return (
    container: container,
    store: store,
    source: source,
    accounts: accounts,
  );
}

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _cached(EntitlementGrant grant) => jsonEncode(grant.toJson());

void main() {
  test('FREE keeps every current feature and shows ads; PREMIUM only adds', () {
    const free = Entitlements(accountKey: 'guest');
    for (final feature in [
      Feature.allMatches,
      Feature.favorites,
      Feature.live,
      Feature.matchCenter,
      Feature.lineups,
      Feature.importantAlerts,
      Feature.playerAlerts,
    ]) {
      expect(free.allows(feature), isTrue, reason: '$feature');
    }
    expect(free.allows(Feature.adFree), isFalse);
    expect(free.allows(Feature.advanced), isFalse);
    expect(free.showsAds, isTrue);

    const premium = Entitlements(accountKey: 'guest', plan: Plan.premium);
    expect(Feature.values.every(premium.allows), isTrue);
    expect(premium.showsAds, isFalse);
  });

  test(
    'default: guest is FREE and nothing is verified without billing',
    () async {
      final s = _setup();
      s.accounts.add(null);
      await _pump();
      final state = s.container.read(entitlementsProvider);
      expect(state.accountKey, 'guest');
      expect(state.plan, Plan.free);
      expect(state.origin, EntitlementOrigin.none);

      await s.container.read(entitlementsProvider.notifier).refresh();
      expect(s.source.asked, [null]);
      expect(s.container.read(entitlementsProvider).plan, Plan.free);
    },
  );

  test(
    'a cached grant works offline per account and never leaks to another',
    () async {
      final s = _setup(
        stored: {
          entitlementStorageKey('account:user-a'): _cached(
            _premium(expiresAt: _now.add(const Duration(days: 20))),
          ),
        },
      );
      s.accounts.add('user-a');
      await _pump();
      var state = s.container.read(entitlementsProvider);
      expect(state.accountKey, 'account:user-a');
      expect(state.isPremium, isTrue);
      expect(state.origin, EntitlementOrigin.cache);
      expect(state.showsAds, isFalse);

      // Source offline: the cache stays.
      s.source.error = StateError('offline');
      await s.container.read(entitlementsProvider.notifier).refresh();
      expect(s.container.read(entitlementsProvider).isPremium, isTrue);

      s.accounts.add('user-b');
      await _pump();
      state = s.container.read(entitlementsProvider);
      expect(state.accountKey, 'account:user-b');
      expect(state.plan, Plan.free);

      s.accounts.add(null);
      await _pump();
      expect(s.container.read(entitlementsProvider).plan, Plan.free);

      s.accounts.add('user-a');
      await _pump();
      expect(s.container.read(entitlementsProvider).isPremium, isTrue);
    },
  );

  test('an expired grant only lasts the grace period', () async {
    final expiry = _now.subtract(const Duration(days: 2));
    final stored = {
      entitlementStorageKey('guest'): _cached(_premium(expiresAt: expiry)),
    };

    final inGrace = _setup(stored: stored);
    inGrace.accounts.add(null);
    await _pump();
    expect(inGrace.container.read(entitlementsProvider).isPremium, isTrue);

    final late = _setup(
      stored: stored,
      now: expiry.add(const Duration(days: 4)),
    );
    late.accounts.add(null);
    await _pump();
    expect(late.container.read(entitlementsProvider).plan, Plan.free);
  });

  test('a verified answer replaces the cache both ways', () async {
    final s = _setup();
    s.accounts.add('user-a');
    await _pump();
    final controller = s.container.read(entitlementsProvider.notifier);

    s.source.answer = EntitlementCheck.answered(
      _premium(expiresAt: _now.add(const Duration(days: 30))),
    );
    await controller.restore();
    expect(s.source.restored, ['user-a']);
    var state = s.container.read(entitlementsProvider);
    expect(state.isPremium, isTrue);
    expect(state.origin, EntitlementOrigin.verified);
    expect(s.store.values.keys, [entitlementStorageKey('account:user-a')]);

    // Verified "no purchase" (cancelled): back to FREE, cache dropped.
    s.source.answer = const EntitlementCheck.answered(null);
    await controller.refresh();
    state = s.container.read(entitlementsProvider);
    expect(state.plan, Plan.free);
    expect(state.origin, EntitlementOrigin.verified);
    expect(s.store.values, isEmpty);
  });

  test('unreadable storage falls back to FREE', () async {
    final s = _setup(
      stored: {entitlementStorageKey('guest'): _cached(_premium())},
    );
    s.store.failReads = true;
    s.accounts.add(null);
    await _pump();
    expect(s.container.read(entitlementsProvider).plan, Plan.free);

    final corrupt = _setup(
      stored: {entitlementStorageKey('guest'): '{"plan":"gold"}'},
    );
    corrupt.accounts.add(null);
    await _pump();
    expect(corrupt.container.read(entitlementsProvider).plan, Plan.free);
  });

  test('a late answer for a previous account is ignored', () async {
    final s = _setup();
    s.accounts.add('user-a');
    await _pump();
    final controller = s.container.read(entitlementsProvider.notifier);
    s.source.answer = EntitlementCheck.answered(_premium());
    final pending = controller.refresh();
    s.accounts.add('user-b');
    await pending;
    await _pump();
    final state = s.container.read(entitlementsProvider);
    expect(state.accountKey, 'account:user-b');
    expect(state.plan, Plan.free);
  });
}

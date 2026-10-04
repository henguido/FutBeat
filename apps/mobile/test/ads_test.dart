import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/ads.dart';
import 'package:futbeat/core/entitlements.dart';

class _MemoryStore implements EntitlementStore {
  final values = <String, String>{};

  /// When set, reads wait for it (a slow secure storage at startup).
  Completer<void>? readGate;

  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Source implements EntitlementSource {
  EntitlementCheck answer = const EntitlementCheck.unavailable();

  @override
  Future<EntitlementCheck> check(String? accountId) async => answer;

  @override
  Future<EntitlementCheck> restore(String? accountId) async => answer;
}

class _FakeAd implements LoadedAd {
  bool disposed = false;

  @override
  Size get size => const Size(320, 50);

  @override
  Widget widget() => const ColoredBox(
    key: ValueKey('fake-ad'),
    color: Colors.amber,
    child: SizedBox.expand(),
  );

  @override
  void dispose() => disposed = true;
}

class _Loader implements AdLoader {
  final requests = <({String unitId, bool personalized})>[];
  final loaded = <_FakeAd>[];
  bool noFill = false;
  bool throws = false;

  @override
  Future<LoadedAd?> loadBanner(
    String unitId, {
    required bool personalized,
  }) async {
    requests.add((unitId: unitId, personalized: personalized));
    if (throws) throw StateError('AdMob crashed');
    if (noFill) return null;
    final ad = _FakeAd();
    loaded.add(ad);
    return ad;
  }
}

final _premium = EntitlementGrant(
  plan: Plan.premium,
  verifiedAt: DateTime.now(),
  expiresAt: DateTime.now().add(const Duration(days: 30)),
  productId: 'test_premium_monthly',
);

class _Harness {
  final loader = _Loader();
  final store = _MemoryStore();
  final source = _Source();
  final accounts = StreamController<String?>();
  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    AdsConfig config = const AdsConfig(matchesFeedUnitId: 'test-feed-unit'),
  }) async {
    // Never awaited: unlistened when ads are off.
    addTearDown(() => unawaited(accounts.close()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAccountProvider.overrideWith((ref) => accounts.stream),
          entitlementStoreProvider.overrideWithValue(store),
          entitlementSourceProvider.overrideWithValue(source),
          adsConfigProvider.overrideWithValue(config),
          adLoaderProvider.overrideWithValue(loader),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Text('Antes'),
                AdSlot(AdPlacement.matchesFeed),
                Text('Después'),
              ],
            ),
          ),
        ),
      ),
    );
    container = ProviderScope.containerOf(tester.element(find.text('Antes')));
  }

  Future<void> account(WidgetTester tester, String? id) async {
    accounts.add(id);
    await tester.pumpAndSettle();
  }
}

String _cached(EntitlementGrant grant) => jsonEncode(grant.toJson());

void main() {
  testWidgets('FREE with ads configured requests one non-personalized ad', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await h.account(tester, null);

    expect(h.loader.requests, [
      (unitId: 'test-feed-unit', personalized: false),
    ]);
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(h.loader.requests, hasLength(1));
  });

  testWidgets('PREMIUM never requests an ad, even while its cache loads', (
    tester,
  ) async {
    final h = _Harness();
    h.store.values[entitlementStorageKey('account:user-a')] = _cached(_premium);
    h.store.readGate = Completer<void>();
    await h.pump(tester);
    await h.account(tester, 'user-a');
    // Account known, plan not yet: still no request.
    expect(h.loader.requests, isEmpty);

    h.store.readGate!.complete();
    await tester.pumpAndSettle();
    expect(h.container.read(entitlementsProvider).isPremium, isTrue);
    expect(h.loader.requests, isEmpty);
    expect(find.byKey(const ValueKey('fake-ad')), findsNothing);
  });

  testWidgets('no request while the account is still resolving', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pumpAndSettle();
    expect(h.loader.requests, isEmpty);
  });

  testWidgets('upgrade to PREMIUM removes the ad at once', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.account(tester, null);
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);

    await h.container.read(entitlementsProvider.notifier).apply(_premium);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-ad')), findsNothing);
    expect(h.loader.loaded.single.disposed, isTrue);
    expect(h.loader.requests, hasLength(1));
  });

  testWidgets('restored PREMIUM removes the ad; back to FREE may show one', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await h.account(tester, 'user-a');
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);

    h.source.answer = EntitlementCheck.answered(_premium);
    await h.container.read(entitlementsProvider.notifier).restore();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-ad')), findsNothing);
    expect(h.loader.loaded.first.disposed, isTrue);

    // Subscription gone: FREE again, ads may return.
    h.source.answer = const EntitlementCheck.answered(null);
    await h.container.read(entitlementsProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);
    expect(h.loader.requests, hasLength(2));
  });

  testWidgets('no ad configuration: no request, nothing shown', (tester) async {
    final h = _Harness();
    await h.pump(tester, config: const AdsConfig());
    await h.account(tester, null);
    expect(h.loader.requests, isEmpty);
    expect(find.text('Antes'), findsOneWidget);
    expect(find.text('Después'), findsOneWidget);
  });

  testWidgets(
    'an AdMob failure or no fill leaves the UI intact, no retry loop',
    (tester) async {
      for (final failure in ['noFill', 'throws']) {
        final h = _Harness();
        h.loader.noFill = failure == 'noFill';
        h.loader.throws = failure == 'throws';
        await h.pump(tester);
        await h.account(tester, null);
        expect(h.loader.requests, hasLength(1), reason: failure);
        expect(find.byKey(const ValueKey('fake-ad')), findsNothing);
        expect(find.text('Antes'), findsOneWidget);
        expect(find.text('Después'), findsOneWidget);
        // Nothing reserved: the two texts stay together.
        expect(
          tester.getTopLeft(find.text('Después')).dy -
              tester.getBottomLeft(find.text('Antes')).dy,
          lessThan(1),
          reason: failure,
        );
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('account changes follow each account\'s own plan', (
    tester,
  ) async {
    final h = _Harness();
    h.store.values[entitlementStorageKey('account:user-a')] = _cached(_premium);
    await h.pump(tester);
    await h.account(tester, null); // guest: FREE
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);

    await h.account(tester, 'user-a'); // PREMIUM account
    expect(find.byKey(const ValueKey('fake-ad')), findsNothing);
    expect(h.loader.loaded.single.disposed, isTrue);
    expect(h.loader.requests, hasLength(1));

    await h.account(tester, 'user-b'); // FREE account
    expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);
    expect(h.loader.requests, hasLength(2));
  });

  test('ads are off by default: no units without build configuration', () {
    expect(const AdsConfig().configured, isFalse);
    expect(const AdsConfig().unitFor(AdPlacement.matchesFeed), isNull);
    // Test environment (not Android, no dart-define): nothing configured.
    expect(AdsConfig.fromEnvironment().configured, isFalse);
  });
}

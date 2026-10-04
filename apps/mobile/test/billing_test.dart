import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/billing.dart';
import 'package:futbeat/core/entitlements.dart';
import 'package:futbeat/features/profile/premium_card.dart';

// Test-only placeholders: the real Play product ids are not defined yet.
const _monthly = 'test_premium_monthly';
const _yearly = 'test_premium_yearly';

class _MemoryStore implements EntitlementStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Gateway implements BillingGateway {
  bool isAvailable = true;
  bool ownedFails = false;
  final ownedList = <OwnedPurchase>[];
  final ownedGates = <Completer<List<OwnedPurchase>>>[];
  final _events = StreamController<List<PurchaseEvent>>.broadcast();
  final completed = <String>[];
  final bought = <({String productId, String accountTag})>[];

  /// What Play does after the purchase sheet opens.
  void Function(PremiumOffer offer, String accountTag)? onBuy;

  void emit(List<PurchaseEvent> events) => _events.add(events);

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<List<PremiumOffer>> offers(Set<String> productIds) async => [
    for (final id in productIds)
      PremiumOffer(
        productId: id,
        period: id == _yearly ? PremiumPeriod.yearly : PremiumPeriod.monthly,
        price: id == _yearly ? r'$19.99' : r'$2.99',
      ),
  ];

  @override
  Future<List<OwnedPurchase>> owned() async {
    if (ownedGates.isNotEmpty) return ownedGates.removeAt(0).future;
    if (ownedFails) throw const BillingUnavailable();
    return List.of(ownedList);
  }

  @override
  Future<bool> buy(PremiumOffer offer, {required String accountTag}) async {
    bought.add((productId: offer.productId, accountTag: accountTag));
    final reaction = onBuy;
    if (reaction != null) scheduleMicrotask(() => reaction(offer, accountTag));
    return true;
  }

  @override
  Stream<List<PurchaseEvent>> get events => _events.stream;

  @override
  Future<void> complete(PurchaseEvent event) async =>
      completed.add(event.productId);
}

final _now = DateTime.utc(2026, 10, 4, 12);

class _Harness {
  _Harness({Map<String, String> stored = const {}}) {
    store.values.addAll(stored);
    container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith((ref) => accounts.stream),
        billingGatewayProvider.overrideWithValue(gateway),
        premiumProductsProvider.overrideWithValue(const {_monthly, _yearly}),
        entitlementStoreProvider.overrideWithValue(store),
        entitlementClockProvider.overrideWithValue(() => now),
      ],
    );
    final plan = container.listen(entitlementsProvider, (_, _) {});
    final billing = container.listen(premiumBillingProvider, (_, _) {});
    addTearDown(() {
      plan.close();
      billing.close();
      container.dispose();
      accounts.close();
    });
  }

  final gateway = _Gateway();
  final store = _MemoryStore();
  final accounts = StreamController<String?>();
  late final ProviderContainer container;
  DateTime now = _now;

  Entitlements get plan => container.read(entitlementsProvider);
  PremiumBillingController get billing =>
      container.read(premiumBillingProvider.notifier);

  Future<void> signIn(String? accountId) async {
    accounts.add(accountId);
    await pump();
  }

  OwnedPurchase owned(String? accountId, {String productId = _monthly}) =>
      OwnedPurchase(
        productId: productId,
        purchased: true,
        accountTag: billingAccountTag(entitlementAccountKey(accountId)),
      );
}

Future<void> pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

PremiumOffer _offer(String id) => PremiumOffer(
  productId: id,
  period: id == _yearly ? PremiumPeriod.yearly : PremiumPeriod.monthly,
  price: r'$2.99',
);

void main() {
  test('product ids are configuration only: none set means billing off', () {
    // No --dart-define in tests: nothing invented, nothing enabled.
    expect(PremiumProducts.configured, isEmpty);
    expect(billingAccountTag('guest'), hasLength(64));
    expect(billingAccountTag('guest'), isNot(billingAccountTag('account:a')));
    expect(billingAccountTag('account:a'), isNot(contains('account')));
  });

  test('successful purchase: acknowledged, then Premium from Play', () async {
    final h = _Harness();
    await h.signIn('user-a');
    expect(h.plan.plan, Plan.free);

    h.gateway.onBuy = (offer, tag) {
      h.gateway.ownedList.add(
        OwnedPurchase(
          productId: offer.productId,
          purchased: true,
          accountTag: tag,
        ),
      );
      h.gateway.emit([
        PurchaseEvent(
          productId: offer.productId,
          outcome: PurchaseOutcome.purchased,
          needsCompletion: true,
        ),
      ]);
    };
    final result = await h.billing.buy(_offer(_yearly));

    expect(result, PremiumActionResult.premium);
    expect(h.gateway.completed, [_yearly]);
    expect(
      h.gateway.bought.single.accountTag,
      billingAccountTag('account:user-a'),
    );
    expect(h.plan.isPremium, isTrue);
    expect(h.plan.showsAds, isFalse);
    expect(h.plan.origin, EntitlementOrigin.verified);
    expect(h.plan.expiresAt, _now.add(billingLease));
    expect(h.container.read(premiumBillingProvider).busy, isFalse);
  });

  test('cancelled purchase keeps FREE without breaking the flow', () async {
    final h = _Harness();
    await h.signIn(null);
    h.gateway.onBuy = (offer, _) => h.gateway.emit([
      PurchaseEvent(
        productId: offer.productId,
        outcome: PurchaseOutcome.cancelled,
      ),
    ]);

    expect(
      await h.billing.buy(_offer(_monthly)),
      PremiumActionResult.cancelled,
    );
    expect(h.plan.plan, Plan.free);
    expect(h.gateway.completed, isEmpty);
    expect(h.container.read(premiumBillingProvider).busy, isFalse);

    // A pending payment is reported, not granted.
    h.gateway.onBuy = (offer, _) => h.gateway.emit([
      PurchaseEvent(
        productId: offer.productId,
        outcome: PurchaseOutcome.pending,
      ),
    ]);
    expect(await h.billing.buy(_offer(_monthly)), PremiumActionResult.pending);
    expect(h.container.read(premiumBillingProvider).pending, isTrue);
    expect(h.plan.plan, Plan.free);
  });

  test('existing purchases on start and restore', () async {
    final h = _Harness();
    h.gateway.ownedList.add(h.owned('user-a'));
    await h.signIn('user-a');
    // Queried at start: already Premium.
    expect(h.plan.isPremium, isTrue);

    final other = _Harness();
    await other.signIn('user-a');
    expect(await other.billing.restore(), PremiumActionResult.nothingToRestore);
    other.gateway.ownedList.add(other.owned('user-a'));
    expect(await other.billing.restore(), PremiumActionResult.premium);
    expect(other.plan.isPremium, isTrue);
  });

  test(
    'cancellation / expiry: Play no longer lists it on resume → FREE',
    () async {
      final h = _Harness();
      h.gateway.ownedList.add(h.owned('user-a'));
      await h.signIn('user-a');
      expect(h.plan.isPremium, isTrue);
      expect(h.store.values, isNotEmpty);

      h.gateway.ownedList.clear(); // period ended
      await h.billing.onResume();
      expect(h.plan.plan, Plan.free);
      expect(h.store.values, isEmpty);
    },
  );

  test(
    'billing unavailable: keeps the valid cache, actions report it',
    () async {
      final cached = EntitlementGrant(
        plan: Plan.premium,
        verifiedAt: _now,
        expiresAt: _now.add(billingLease),
        productId: _monthly,
      );
      final h = _Harness(
        stored: {
          entitlementStorageKey('account:user-a'):
              '{"plan":"premium",'
              '"verifiedAt":"${cached.verifiedAt.toIso8601String()}",'
              '"expiresAt":"${cached.expiresAt!.toIso8601String()}",'
              '"productId":"$_monthly"}',
        },
      );
      h.gateway.ownedFails = true; // Play disconnected / error
      await h.signIn('user-a');
      expect(h.plan.isPremium, isTrue);
      expect(h.plan.origin, EntitlementOrigin.cache);

      h.gateway.isAvailable = false;
      expect(await h.billing.restore(), PremiumActionResult.unavailable);
      await expectLater(h.billing.offers(), throwsA(isA<BillingUnavailable>()));
      expect(h.plan.isPremium, isTrue);

      // Past the lease + grace with Play still away: FREE.
      h.now = _now.add(
        billingLease + entitlementGracePeriod + const Duration(minutes: 1),
      );
      await h.billing.onResume();
      expect(h.plan.plan, Plan.free);
    },
  );

  test('a late Play answer never overwrites a newer one', () async {
    final h = _Harness();
    await h.signIn('user-a');
    final older = Completer<List<OwnedPurchase>>();
    final newer = Completer<List<OwnedPurchase>>();
    h.gateway.ownedGates.addAll([older, newer]);

    final resume = h.billing.onResume(); // before the purchase
    final restore = h.billing.restore(); // after it
    await pump();
    newer.complete([h.owned('user-a')]);
    expect(await restore, PremiumActionResult.premium);
    older.complete(const []);
    await resume;
    await pump();
    expect(h.plan.isPremium, isTrue);
  });

  test(
    'account change never leaks Premium; guest purchase stays guest',
    () async {
      final h = _Harness();
      h.gateway.ownedList.add(h.owned(null)); // bought as guest
      await h.signIn(null);
      expect(h.plan.isPremium, isTrue);

      await h.signIn('user-a');
      expect(h.plan.accountKey, 'account:user-a');
      expect(h.plan.plan, Plan.free); // not transferred automatically (P2)

      h.gateway.ownedList.add(h.owned('user-a'));
      await h.billing.onResume();
      expect(h.plan.isPremium, isTrue);

      await h.signIn('user-b');
      expect(h.plan.plan, Plan.free);
      await h.signIn(null);
      expect(h.plan.isPremium, isTrue);
    },
  );

  testWidgets('profile card: plan, Hazte Premium and Restaurar compras', (
    tester,
  ) async {
    final gateway = _Gateway();
    final accounts = StreamController<String?>();
    addTearDown(accounts.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAccountProvider.overrideWith((ref) => accounts.stream),
          billingGatewayProvider.overrideWithValue(gateway),
          premiumProductsProvider.overrideWithValue(const {_monthly, _yearly}),
          entitlementStoreProvider.overrideWithValue(_MemoryStore()),
        ],
        child: const MaterialApp(home: Scaffold(body: PremiumCard())),
      ),
    );
    accounts.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Gratis'), findsOneWidget);
    expect(find.text('Hazte Premium'), findsOneWidget);

    await tester.tap(find.text('Restaurar compras'));
    await tester.pumpAndSettle();
    expect(find.text('No hay compras para restaurar.'), findsOneWidget);
    // Let that message expire so the next one is shown.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    gateway.onBuy = (offer, tag) {
      gateway.ownedList.add(
        OwnedPurchase(
          productId: offer.productId,
          purchased: true,
          accountTag: tag,
        ),
      );
      gateway.emit([
        PurchaseEvent(
          productId: offer.productId,
          outcome: PurchaseOutcome.purchased,
        ),
      ]);
    };
    await tester.tap(find.text('Hazte Premium'));
    await tester.pumpAndSettle();
    expect(find.text('Mensual'), findsOneWidget);
    expect(find.text('Anual'), findsOneWidget);
    await tester.tap(find.text('Anual'));
    await tester.pumpAndSettle();
    expect(find.text('Premium'), findsOneWidget);
    expect(find.text('Premium activo.'), findsOneWidget);
    expect(find.text('Hazte Premium'), findsNothing);
  });

  testWidgets('profile card without billing shows the plan only', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAccountProvider.overrideWith((ref) => Stream.value(null)),
          entitlementStoreProvider.overrideWithValue(_MemoryStore()),
        ],
        child: const MaterialApp(home: Scaffold(body: PremiumCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gratis'), findsOneWidget);
    expect(find.text('Hazte Premium'), findsNothing);
    expect(find.text('Restaurar compras'), findsNothing);
  });
}

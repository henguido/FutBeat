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
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    if (failReads) throw StateError('secure storage unavailable');
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

class _Consent implements AdsConsent {
  _Consent(this.decision);

  /// null = the consent platform never answers.
  final AdsConsentDecision? decision;

  @override
  Future<AdsConsentDecision> resolve() => decision == null
      ? Completer<AdsConsentDecision>().future
      : Future.value(decision);
}

const _allowed = AdsConsentDecision(canRequestAds: true, personalized: false);

class _Harness {
  final loader = _Loader();
  final store = _MemoryStore();
  final source = _Source();
  final accounts = StreamController<String?>();
  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    AdsConfig config = const AdsConfig(matchesFeedUnitId: 'test-feed-unit'),
    // A real unit needs consent: allowed unless a test says otherwise.
    AdsConsent? consent = const _AllowedConsent(),
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
          if (consent != null) adsConsentProvider.overrideWithValue(consent),
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

class _AllowedConsent implements AdsConsent {
  const _AllowedConsent();

  @override
  Future<AdsConsentDecision> resolve() async => _allowed;
}

class _FakeBanner implements PlatformBanner {
  _FakeBanner(this.onLoaded, this.onFailed);

  final void Function() onLoaded;
  final void Function() onFailed;
  int disposed = 0;

  @override
  Size get size => const Size(320, 50);

  @override
  Future<void> load() async {}

  @override
  Future<void> dispose() async => disposed++;

  @override
  Widget widget() => const SizedBox(key: ValueKey('platform-banner'));
}

({GoogleAdLoader loader, List<_FakeBanner> banners}) _googleLoader() {
  final banners = <_FakeBanner>[];
  final loader = GoogleAdLoader(
    initialize: () async {},
    timeout: const Duration(milliseconds: 40),
    createBanner:
        (
          unitId, {
          required personalized,
          required onLoaded,
          required onFailed,
        }) {
          final banner = _FakeBanner(onLoaded, onFailed);
          banners.add(banner);
          return banner;
        },
  );
  return (loader: loader, banners: banners);
}

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

  group('consent', () {
    testWidgets('real unit + consent unresolved (default): no request', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester, consent: null); // production default
      await h.account(tester, null);
      expect(h.loader.requests, isEmpty);
    });

    testWidgets('real unit + consent pending forever: no request', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester, consent: _Consent(null));
      await h.account(tester, null);
      expect(h.loader.requests, isEmpty);
    });

    testWidgets('real unit + consent denied: no request', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        consent: _Consent(
          const AdsConsentDecision(canRequestAds: false, personalized: false),
        ),
      );
      await h.account(tester, null);
      expect(h.loader.requests, isEmpty);
    });

    testWidgets('real unit + consent allowed: request as allowed', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(
        tester,
        consent: _Consent(
          const AdsConsentDecision(canRequestAds: true, personalized: true),
        ),
      );
      await h.account(tester, null);
      expect(h.loader.requests, [
        (unitId: 'test-feed-unit', personalized: true),
      ]);
    });

    testWidgets(
      'Google test ads still work for QA without production consent',
      (tester) async {
        final h = _Harness();
        await h.pump(
          tester,
          config: const AdsConfig(
            matchesFeedUnitId: admobTestBannerUnitId,
            testAdsBuild: true,
          ),
          consent: null,
        );
        await h.account(tester, null);
        expect(h.loader.requests, [
          (unitId: admobTestBannerUnitId, personalized: false),
        ]);
        expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);
      },
    );
  });

  group('entitlement storage failures fail closed', () {
    testWidgets('storage throws: no ad until a verified FREE', (tester) async {
      final h = _Harness();
      h.store.failReads = true;
      await h.pump(tester);
      await h.account(tester, null);
      expect(h.container.read(entitlementsProvider).settled, isFalse);
      expect(h.loader.requests, isEmpty);

      h.source.answer = const EntitlementCheck.answered(null);
      await h.container.read(entitlementsProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(h.container.read(entitlementsProvider).settled, isTrue);
      expect(h.loader.requests, hasLength(1));
    });

    testWidgets('malformed cache: no ad until a verified FREE', (tester) async {
      final h = _Harness();
      h.store.values[entitlementStorageKey('guest')] = '{"plan":"gold"}';
      await h.pump(tester);
      await h.account(tester, null);
      expect(h.container.read(entitlementsProvider).settled, isFalse);
      expect(h.loader.requests, isEmpty);

      h.source.answer = const EntitlementCheck.answered(null);
      await h.container.read(entitlementsProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(h.loader.requests, hasLength(1));
      expect(find.byKey(const ValueKey('fake-ad')), findsOneWidget);
    });
  });

  group('GoogleAdLoader', () {
    test(
      'timeout disposes the banner exactly once; a late load is ignored',
      () async {
        final g = _googleLoader();
        final ad = await g.loader.loadBanner('unit', personalized: false);
        expect(ad, isNull);
        expect(g.banners.single.disposed, 1);

        g.banners.single.onLoaded(); // AdMob answers after the timeout
        await Future<void>.delayed(Duration.zero);
        expect(g.banners.single.disposed, 1);
      },
    );

    test('failed load disposes once; a loaded banner disposes once', () async {
      final g = _googleLoader();
      final failed = g.loader.loadBanner('unit', personalized: false);
      await Future<void>.delayed(Duration.zero);
      g.banners.last.onFailed();
      expect(await failed, isNull);
      expect(g.banners.last.disposed, 1);

      final loading = g.loader.loadBanner('unit', personalized: false);
      await Future<void>.delayed(Duration.zero);
      g.banners.last.onLoaded();
      final ad = await loading;
      expect(ad, isNotNull);
      expect(g.banners.last.disposed, 0);
      // Past the timeout nothing else happens to a delivered banner.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(g.banners.last.disposed, 0);
      ad!
        ..dispose()
        ..dispose();
      expect(g.banners.last.disposed, 1);
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'qa_development.dart';
import 'premium_qa_transport.dart';
import 'entitlements.dart';

/// Google Play product ids of FutBeat Premium. Set at build time
/// (`--dart-define`); they are not final yet, so there is no default. With
/// none configured, billing is off and everyone stays FREE.
class PremiumProducts {
  static const productId = 'futbeat_premium';
  static const basePlans = {
    'monthly': PremiumPeriod.monthly,
    'yearly': PremiumPeriod.yearly,
  };
  static const monthly = String.fromEnvironment('FUTBEAT_PREMIUM_MONTHLY_ID');
  static const yearly = String.fromEnvironment('FUTBEAT_PREMIUM_YEARLY_ID');

  static Set<String> get configured => {
    if (premiumPlayQaEnabled) productId,
    for (final id in [monthly, yearly])
      if (id.isNotEmpty) id,
  };
}

/// How long one client-side check of an active Play subscription counts
/// before it must be re-checked (start, resume, restore). Plus
/// [entitlementGracePeriod], this bounds offline Premium.
const billingLease = Duration(days: 3);

/// Play `obfuscatedAccountId` for a FutBeat account key: a one-way hash, so
/// no FutBeat id reaches Google. A purchase only counts for the account (or
/// the guest of the device) that bought it: a guest purchase is NOT moved to
/// an account automatically (product decision pending, P2).
String billingAccountTag(String accountKey) =>
    sha256.convert(utf8.encode('futbeat:$accountKey')).toString();

enum PremiumPeriod { monthly, yearly }

/// A purchasable Premium plan as the store prices it.
class PremiumOffer {
  const PremiumOffer({
    required this.productId,
    required this.period,
    required this.price,
    this.handle,
  });

  final String productId;
  final PremiumPeriod period;
  final String price;

  /// Store object needed to launch the purchase.
  final Object? handle;
}

/// A purchase the store still holds for this Google account.
class OwnedPurchase {
  const OwnedPurchase({
    required this.productId,
    required this.purchased,
    this.accountTag,
    this.token,
    this.needsCompletion = false,
    this.handle,
  });

  final String productId;

  /// False while the payment is pending.
  final bool purchased;
  final String? accountTag;

  /// Play purchase token: identifies the purchase across queries/events.
  final String? token;

  /// Never acknowledged (e.g. the app died before the purchase callback):
  /// Play refunds it unless it is acknowledged.
  final bool needsCompletion;

  /// Store object needed to acknowledge it.
  final Object? handle;
}

enum PurchaseOutcome { purchased, pending, cancelled, failed, unavailable }

class PurchaseEvent {
  const PurchaseEvent({
    required this.productId,
    required this.outcome,
    this.needsCompletion = false,
    this.token,
    this.handle,
  });

  final String productId;
  final PurchaseOutcome outcome;
  final String? token;

  /// The purchase must be acknowledged (Play refunds it otherwise).
  final bool needsCompletion;
  final Object? handle;
}

class BillingUnavailable implements Exception {
  const BillingUnavailable();
}

/// The store, behind an interface so tests never touch Google Play.
abstract interface class BillingGateway {
  Future<bool> available();
  Future<List<PremiumOffer>> offers(Set<String> productIds);

  /// Active purchases; throws [BillingUnavailable] when Play cannot answer.
  Future<List<OwnedPurchase>> owned();

  /// Opens the Play purchase sheet; the result arrives on [events].
  Future<bool> buy(
    PremiumOffer offer, {
    required String accountTag,
    OwnedPurchase? replacing,
  });
  Stream<List<PurchaseEvent>> get events;

  /// Acknowledges a purchase ([OwnedPurchase.handle] /
  /// [PurchaseEvent.handle]); throws when Play did not confirm it.
  Future<void> acknowledge(Object handle);
}

/// The single place purchases are acknowledged, shared by the purchase
/// stream and recovered purchases: each token at most once per process,
/// concurrent requests share one call.
class PurchaseAcknowledger {
  PurchaseAcknowledger(this.gateway);

  final BillingGateway gateway;
  final _done = <String>{};
  final _inFlight = <String, Future<bool>>{};

  Future<bool> acknowledge(String key, Object? handle) {
    if (_done.contains(key)) return Future.value(true);
    if (handle == null) return Future.value(false);
    return _inFlight[key] ??= _run(key, handle);
  }

  Future<bool> _run(String key, Object handle) async {
    try {
      await gateway.acknowledge(handle);
      _done.add(key);
      return true;
    } catch (_) {
      return false;
    } finally {
      unawaited(_inFlight.remove(key));
    }
  }
}

/// Google Play Billing through `in_app_purchase`. The plugin keeps the
/// BillingClient connected and reconnects it on demand.
class PlayBillingGateway implements BillingGateway {
  PlayBillingGateway([InAppPurchase? store])
    : _store = store ?? InAppPurchase.instance;

  final InAppPurchase _store;

  @override
  Future<bool> available() async {
    try {
      return await _store.isAvailable();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<PremiumOffer>> offers(Set<String> productIds) async {
    final response = await _store.queryProductDetails(productIds);
    if (response.error != null) throw const BillingUnavailable();
    if (premiumPlayQaEnabled) {
      return selectPremiumBasePlans(response.productDetails);
    }
    final byProduct = <String, ProductDetails>{};
    for (final details in response.productDetails) {
      // One entry per subscription offer: keep the first (base plan).
      byProduct.putIfAbsent(details.id, () => details);
    }
    return [
      for (final details in byProduct.values)
        PremiumOffer(
          productId: details.id,
          period: details.id == PremiumProducts.yearly
              ? PremiumPeriod.yearly
              : PremiumPeriod.monthly,
          price: details.price,
          handle: details,
        ),
    ];
  }

  @override
  Future<List<OwnedPurchase>> owned() async {
    final addition = _store
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final response = await addition.queryPastPurchases();
    if (response.error != null) throw const BillingUnavailable();
    return [
      for (final purchase in response.pastPurchases)
        OwnedPurchase(
          productId: purchase.productID,
          purchased:
              purchase.billingClientPurchase.purchaseState ==
              PurchaseStateWrapper.purchased,
          accountTag: purchase.billingClientPurchase.obfuscatedAccountId,
          token: purchase.billingClientPurchase.purchaseToken,
          needsCompletion: !purchase.billingClientPurchase.isAcknowledged,
          handle: purchase,
        ),
    ];
  }

  @override
  Future<bool> buy(
    PremiumOffer offer, {
    required String accountTag,
    OwnedPurchase? replacing,
  }) {
    final details = offer.handle! as ProductDetails;
    final previous = replacing?.handle;
    if (replacing != null &&
        (!premiumPlayQaEnabled ||
            replacing.productId != offer.productId ||
            replacing.accountTag != accountTag ||
            !replacing.purchased ||
            replacing.needsCompletion ||
            previous is! GooglePlayPurchaseDetails ||
            replacing.token != previous.billingClientPurchase.purchaseToken ||
            previous.billingClientPurchase.obfuscatedAccountId != accountTag ||
            previous.billingClientPurchase.packageName !=
                'com.futbeat.futbeat' ||
            details is! GooglePlayProductDetails ||
            details.id != offer.productId ||
            details.offerToken == null)) {
      throw const BillingUnavailable();
    }
    return _store.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: details,
        applicationUserName: accountTag,
        offerToken: details is GooglePlayProductDetails
            ? details.offerToken
            : null,
        changeSubscriptionParam: previous is GooglePlayPurchaseDetails
            ? ChangeSubscriptionParam(
                oldPurchaseDetails: previous,
                replacementMode: ReplacementMode.chargeFullPrice,
              )
            : null,
      ),
    );
  }

  @override
  Stream<List<PurchaseEvent>> get events => _store.purchaseStream.map(
    (purchases) => [
      for (final purchase in purchases)
        PurchaseEvent(
          productId: purchase.productID,
          outcome: switch (purchase.status) {
            PurchaseStatus.purchased ||
            PurchaseStatus.restored => PurchaseOutcome.purchased,
            PurchaseStatus.pending => PurchaseOutcome.pending,
            PurchaseStatus.canceled => PurchaseOutcome.cancelled,
            PurchaseStatus.error => PurchaseOutcome.failed,
          },
          needsCompletion: purchase.pendingCompletePurchase,
          token: purchase.verificationData.serverVerificationData,
          handle: purchase,
        ),
    ],
  );

  @override
  Future<void> acknowledge(Object handle) async {
    final purchase = handle as PurchaseDetails;
    final platform = InAppPurchasePlatform.instance;
    if (platform is InAppPurchaseAndroidPlatform) {
      // The app-facing completePurchase drops the result: check it here.
      final result = await platform.completePurchase(purchase);
      if (result.responseCode != BillingResponse.ok) {
        throw const BillingUnavailable();
      }
      return;
    }
    await _store.completePurchase(purchase);
  }
}

List<PremiumOffer> selectPremiumBasePlans(Iterable<ProductDetails> products) {
  final offers = <PremiumPeriod, PremiumOffer>{};
  for (final details in products.whereType<GooglePlayProductDetails>()) {
    if (details.id != PremiumProducts.productId) continue;
    final index = details.subscriptionIndex;
    final plans = details.productDetails.subscriptionOfferDetails;
    if (index == null || plans == null || index < 0 || index >= plans.length) {
      continue;
    }
    final plan = plans[index];
    final period = PremiumProducts.basePlans[plan.basePlanId];
    if (period == null || plan.offerId != null) continue;
    offers.putIfAbsent(
      period,
      () => PremiumOffer(
        productId: details.id,
        period: period,
        price: details.price,
        handle: details,
      ),
    );
  }
  return [for (final period in PremiumPeriod.values) ?offers[period]];
}

/// Premium is whatever Play reports for THIS account right now: an active
/// purchase tagged with the account → PREMIUM for [billingLease]; none →
/// verified FREE (cancelled periods end, expired subscriptions are gone);
/// no answer → unavailable (the cache and its grace decide).
class PlayBillingEntitlementSource implements EntitlementSource {
  PlayBillingEntitlementSource(
    this.gateway, {
    PurchaseAcknowledger? acknowledger,
    Set<String>? products,
    DateTime Function()? clock,
  }) : acknowledger = acknowledger ?? PurchaseAcknowledger(gateway),
       products = products ?? PremiumProducts.configured,
       clock = clock ?? DateTime.now;

  final BillingGateway gateway;
  final PurchaseAcknowledger acknowledger;
  final Set<String> products;
  final DateTime Function() clock;

  @override
  Future<EntitlementCheck> check(String? accountId) async {
    if (products.isEmpty || !await gateway.available()) {
      return const EntitlementCheck.unavailable();
    }
    final List<OwnedPurchase> owned;
    try {
      owned = await gateway.owned();
    } catch (_) {
      return const EntitlementCheck.unavailable();
    }
    final tag = billingAccountTag(entitlementAccountKey(accountId));
    final premium = owned.where(
      (p) => p.purchased && products.contains(p.productId),
    );
    // Recovered, never-acknowledged purchases are acknowledged before they
    // count (any account's, so none is refunded). If this account's one
    // cannot be acknowledged now, Premium stays unverified and is retried.
    for (final purchase in premium.where((p) => p.needsCompletion)) {
      final done = await acknowledger.acknowledge(
        purchase.token ?? '${purchase.productId}:${purchase.accountTag}',
        purchase.handle,
      );
      if (!done && purchase.accountTag == tag) {
        return const EntitlementCheck.unavailable();
      }
    }
    final active = premium.where((p) => p.accountTag == tag);
    if (active.isEmpty) return const EntitlementCheck.answered(null);
    final now = clock();
    return EntitlementCheck.answered(
      EntitlementGrant(
        plan: Plan.premium,
        verifiedAt: now,
        expiresAt: now.add(billingLease),
        productId: active.first.productId,
      ),
    );
  }

  @override
  Future<EntitlementCheck> restore(String? accountId) => check(accountId);
}

/// Store gateway, or null when billing is off (not Android or no product
/// ids configured).
final billingGatewayProvider = Provider<BillingGateway?>((ref) {
  if (isolatedPreview ||
      !Platform.isAndroid ||
      PremiumProducts.configured.isEmpty) {
    return null;
  }
  return PlayBillingGateway();
});

final premiumProductsProvider = Provider<Set<String>>(
  (ref) => PremiumProducts.configured,
);

final purchaseAcknowledgerProvider = Provider<PurchaseAcknowledger?>((ref) {
  final gateway = ref.watch(billingGatewayProvider);
  return gateway == null ? null : PurchaseAcknowledger(gateway);
});

/// UI-facing billing state; the plan itself is [entitlementsProvider].
class PremiumBillingState {
  const PremiumBillingState({this.busy = false, this.pending = false});

  final bool busy;

  /// A payment is waiting for confirmation (e.g. cash / bank transfer).
  final bool pending;
}

enum PremiumActionResult {
  premium,
  pending,
  cancelled,
  failed,
  unavailable,
  nothingToRestore,
  purchaseRejected,
  temporarilyUnavailable,
}

PremiumActionResult? premiumVerificationFailure(EntitlementCheck? check) =>
    switch (check?.failure) {
      EntitlementFailure.purchaseRejected =>
        PremiumActionResult.purchaseRejected,
      EntitlementFailure.temporarilyUnavailable =>
        PremiumActionResult.temporarilyUnavailable,
      null => null,
    };

final premiumBillingProvider =
    NotifierProvider<PremiumBillingController, PremiumBillingState>(
      PremiumBillingController.new,
    );

/// Purchases and restores. It never sets the plan: every store result goes
/// back through [EntitlementsController.refresh], the only source of truth.
class PremiumBillingController extends Notifier<PremiumBillingState> {
  final _waiting = <String, Completer<PurchaseOutcome>>{};
  PremiumActionResult? _purchaseFailure;

  BillingGateway? get _gateway => ref.read(billingGatewayProvider);
  bool get enabled =>
      _gateway != null && ref.read(premiumProductsProvider).isNotEmpty;

  @override
  PremiumBillingState build() {
    final gateway = ref.watch(billingGatewayProvider);
    if (gateway != null) {
      final events = gateway.events.listen(_onEvents, onError: (Object _) {});
      ref.onDispose(events.cancel);
      // Existing purchases on start and on every account change.
      ref.listen(
        currentAccountProvider,
        (_, _) => unawaited(_refresh()),
        fireImmediately: true,
      );
    }
    ref.onDispose(() {
      for (final waiting in _waiting.values) {
        if (!waiting.isCompleted) waiting.complete(PurchaseOutcome.failed);
      }
      _waiting.clear();
    });
    return const PremiumBillingState();
  }

  Future<void> _refresh() => ref.read(entitlementsProvider.notifier).refresh();

  /// App resumed: Play may have renewed, cancelled or expired the plan.
  Future<void> onResume() async {
    if (premiumPlayQaEnabled) ref.invalidate(premiumPurchasesAllowedProvider);
    if (enabled) await _refresh();
  }

  Future<void> _onEvents(List<PurchaseEvent> events) async {
    final premium = ref.read(premiumProductsProvider);
    var changed = false;
    for (final event in events) {
      if (!premium.contains(event.productId)) continue;
      final source = ref.read(entitlementSourceProvider);
      // Disabled commercial verification must not acknowledge a purchase
      // received from the store before server persistence is available.
      if (source is UnavailableEntitlementSource) continue;
      var serverVerified = false;
      if (source is PremiumQaEntitlementSource &&
          event.outcome == PurchaseOutcome.purchased) {
        final owner = ref.read(currentAccountProvider).asData?.value;
        if (owner != null && event.token?.isNotEmpty == true) {
          final result = await source.verify(owner, event.token!);
          if (ref.mounted &&
              ref.read(currentAccountProvider).asData?.value == owner) {
            serverVerified = result.available;
            if (_waiting.containsKey(event.productId)) {
              _purchaseFailure =
                  premiumVerificationFailure(result) ??
                  (result.available ? null : PremiumActionResult.unavailable);
            }
          }
          if (ref.mounted &&
              ref.read(currentAccountProvider).asData?.value == owner &&
              result.available) {
            await ref.read(entitlementsProvider.notifier).apply(result.grant);
          }
        }
      }
      if (source is! PremiumQaEntitlementSource &&
          event.outcome == PurchaseOutcome.purchased &&
          event.needsCompletion) {
        // A failure is retried by the next check (start, resume, restore).
        await ref
            .read(purchaseAcknowledgerProvider)
            ?.acknowledge(
              event.token ?? '${event.productId}:event',
              event.handle,
            );
      }
      if (!ref.mounted) return;
      if (event.outcome == PurchaseOutcome.purchased &&
          (source is! PremiumQaEntitlementSource || serverVerified)) {
        changed = true;
      }
      state = PremiumBillingState(
        busy: state.busy,
        pending: event.outcome == PurchaseOutcome.pending,
      );
      final waiting = _waiting.remove(event.productId);
      if (waiting != null && !waiting.isCompleted) {
        waiting.complete(event.outcome);
      }
    }
    if (changed && ref.mounted) await _refresh();
  }

  Future<List<PremiumOffer>> offers() async {
    final gateway = _gateway;
    if (gateway == null || !await gateway.available()) {
      throw const BillingUnavailable();
    }
    final offers = await gateway.offers(ref.read(premiumProductsProvider));
    if (ref.read(entitlementsProvider).isPremium &&
        ref.read(entitlementSourceProvider) is PremiumQaEntitlementSource) {
      final owner = ref.read(currentAccountProvider).asData?.value;
      final transport = owner == null
          ? null
          : ref.read(premiumQaTransportFactoryProvider)(owner);
      if (transport == null ||
          !(await transport.read()).available ||
          !transport.purchasesEnabled ||
          transport.activeBasePlanId == null ||
          ref.read(currentAccountProvider).asData?.value != owner) {
        throw const BillingUnavailable();
      }
      offers.removeWhere(
        (offer) =>
            PremiumProducts.basePlans[transport.activeBasePlanId] ==
            offer.period,
      );
    }
    return offers..sort((a, b) => a.period.index.compareTo(b.period.index));
  }

  /// "Hazte Premium" for [offer]. Resolves once Play answers. Refused
  /// while the signed-in account is still being restored, so a purchase is
  /// never tagged as guest by mistake.
  Future<PremiumActionResult> buy(PremiumOffer offer) async {
    final gateway = _gateway;
    final plan = ref.read(entitlementsProvider);
    if (gateway == null ||
        ref.read(entitlementSourceProvider) is UnavailableEntitlementSource ||
        state.busy ||
        !plan.accountResolved) {
      return PremiumActionResult.unavailable;
    }
    state = PremiumBillingState(busy: true, pending: state.pending);
    _purchaseFailure = null;
    final waiting = Completer<PurchaseOutcome>();
    _waiting[offer.productId] = waiting;
    try {
      OwnedPurchase? replacing;
      if (ref.read(entitlementSourceProvider) is PremiumQaEntitlementSource) {
        final owner = ref.read(currentAccountProvider).asData?.value;
        final transport = owner == null
            ? null
            : ref.read(premiumQaTransportFactoryProvider)(owner);
        if (transport == null ||
            !(await transport.read()).available ||
            !transport.purchasesEnabled ||
            !ref.mounted ||
            ref.read(entitlementsProvider).accountKey != plan.accountKey) {
          _waiting.remove(offer.productId);
          return PremiumActionResult.unavailable;
        }
        if (plan.isPremium) {
          if (PremiumProducts.basePlans[transport.activeBasePlanId] == null ||
              PremiumProducts.basePlans[transport.activeBasePlanId] ==
                  offer.period) {
            return PremiumActionResult.unavailable;
          }
          final tag = billingAccountTag(plan.accountKey);
          final candidates = (await gateway.owned())
              .where((p) => p.productId == offer.productId && p.purchased)
              .toList();
          if (candidates.length != 1 ||
              candidates.single.accountTag != tag ||
              candidates.single.needsCompletion ||
              candidates.single.token?.isNotEmpty != true ||
              candidates.single.handle == null ||
              !ref.mounted ||
              ref.read(entitlementsProvider).accountKey != plan.accountKey) {
            return PremiumActionResult.unavailable;
          }
          replacing = candidates.single;
        }
      }
      final tag = billingAccountTag(plan.accountKey);
      if (!await gateway.buy(offer, accountTag: tag, replacing: replacing)) {
        _waiting.remove(offer.productId);
        return PremiumActionResult.failed;
      }
      // Play always answers; the bound only protects a lost callback.
      final outcome = await waiting.future.timeout(
        const Duration(minutes: 15),
        onTimeout: () => PurchaseOutcome.failed,
      );
      if (!ref.mounted ||
          ref.read(entitlementsProvider).accountKey != plan.accountKey) {
        return PremiumActionResult.unavailable;
      }
      return switch (outcome) {
        PurchaseOutcome.purchased => await _afterVerification(),
        PurchaseOutcome.pending => PremiumActionResult.pending,
        PurchaseOutcome.cancelled => PremiumActionResult.cancelled,
        PurchaseOutcome.unavailable => PremiumActionResult.unavailable,
        PurchaseOutcome.failed => PremiumActionResult.failed,
      };
    } catch (_) {
      _waiting.remove(offer.productId);
      return PremiumActionResult.failed;
    } finally {
      if (identical(_waiting[offer.productId], waiting)) {
        _waiting.remove(offer.productId);
      }
      if (ref.mounted) {
        if (premiumPlayQaEnabled) {
          ref.invalidate(premiumPurchasesAllowedProvider);
        }
        state = PremiumBillingState(pending: state.pending);
      }
    }
  }

  /// A7 probes the existing G1 verify route. Restore deliberately keeps its
  /// aggregate 200 semantics when Publisher is temporarily unavailable.
  Future<PremiumActionResult> verifyQaPurchase() async {
    final gateway = _gateway;
    final source = ref.read(entitlementSourceProvider);
    final plan = ref.read(entitlementsProvider);
    if (!premiumPlayQaEnabled ||
        gateway == null ||
        source is! PremiumQaEntitlementSource ||
        state.busy ||
        !plan.accountResolved ||
        !plan.isPremium) {
      return PremiumActionResult.unavailable;
    }
    final owner = ref.read(currentAccountProvider).asData?.value;
    if (owner == null) return PremiumActionResult.unavailable;
    state = PremiumBillingState(busy: true, pending: state.pending);
    bool current() =>
        ref.mounted &&
        ref.read(currentAccountProvider).asData?.value == owner &&
        ref.read(entitlementsProvider).accountKey == plan.accountKey;
    try {
      if (!await gateway.available() || !current()) {
        return PremiumActionResult.unavailable;
      }
      final products = ref.read(premiumProductsProvider);
      final purchases = (await gateway.owned())
          .where(
            (p) =>
                p.purchased &&
                products.contains(p.productId) &&
                p.accountTag == billingAccountTag(plan.accountKey) &&
                !p.needsCompletion &&
                p.token?.isNotEmpty == true,
          )
          .toList();
      if (!current() || purchases.length != 1) {
        return PremiumActionResult.unavailable;
      }
      final answer = await source.verify(owner, purchases.single.token!);
      if (!current()) return PremiumActionResult.unavailable;
      final failure = premiumVerificationFailure(answer);
      if (failure != null) return failure;
      if (!answer.available) return PremiumActionResult.unavailable;
      await ref.read(entitlementsProvider.notifier).apply(answer.grant);
      if (!current()) return PremiumActionResult.unavailable;
      return ref.read(entitlementsProvider).isPremium
          ? PremiumActionResult.premium
          : PremiumActionResult.nothingToRestore;
    } catch (_) {
      return PremiumActionResult.unavailable;
    } finally {
      if (ref.mounted) state = PremiumBillingState(pending: state.pending);
    }
  }

  /// "Restaurar compras".
  Future<PremiumActionResult> restore() async {
    if (!enabled ||
        state.busy ||
        !ref.read(entitlementsProvider).accountResolved) {
      return PremiumActionResult.unavailable;
    }
    state = PremiumBillingState(busy: true, pending: state.pending);
    try {
      final gateway = _gateway!;
      if (!await gateway.available()) return PremiumActionResult.unavailable;
      await ref.read(entitlementsProvider.notifier).restore();
      if (!ref.mounted) return PremiumActionResult.failed;
      final failure = premiumVerificationFailure(
        ref.read(entitlementsProvider.notifier).lastCheck,
      );
      if (failure != null) return failure;
      final current = ref.read(entitlementsProvider);
      if (current.isPremium) return PremiumActionResult.premium;
      return current.origin == EntitlementOrigin.verified
          ? PremiumActionResult.nothingToRestore
          : PremiumActionResult.unavailable;
    } finally {
      if (ref.mounted) {
        state = PremiumBillingState(pending: state.pending);
      }
    }
  }

  Future<PremiumActionResult> _afterVerification() async {
    if (_purchaseFailure != null) return _purchaseFailure!;
    await _refresh();
    if (!ref.mounted) return PremiumActionResult.failed;
    final failure = premiumVerificationFailure(
      ref.read(entitlementsProvider.notifier).lastCheck,
    );
    if (failure != null) return failure;
    return ref.read(entitlementsProvider).isPremium
        ? PremiumActionResult.premium
        : PremiumActionResult.failed;
  }
}

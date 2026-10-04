import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'entitlements.dart';

/// Google Play product ids of FutBeat Premium. Set at build time
/// (`--dart-define`); they are not final yet, so there is no default. With
/// none configured, billing is off and everyone stays FREE.
class PremiumProducts {
  static const monthly = String.fromEnvironment('FUTBEAT_PREMIUM_MONTHLY_ID');
  static const yearly = String.fromEnvironment('FUTBEAT_PREMIUM_YEARLY_ID');

  static Set<String> get configured => {
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
  Future<bool> buy(PremiumOffer offer, {required String accountTag});
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
  Future<bool> buy(PremiumOffer offer, {required String accountTag}) {
    final details = offer.handle! as ProductDetails;
    return _store.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: details,
        applicationUserName: accountTag,
        offerToken: details is GooglePlayProductDetails
            ? details.offerToken
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
  if (!Platform.isAndroid || PremiumProducts.configured.isEmpty) return null;
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
}

final premiumBillingProvider =
    NotifierProvider<PremiumBillingController, PremiumBillingState>(
      PremiumBillingController.new,
    );

/// Purchases and restores. It never sets the plan: every store result goes
/// back through [EntitlementsController.refresh], the only source of truth.
class PremiumBillingController extends Notifier<PremiumBillingState> {
  final _waiting = <String, Completer<PurchaseOutcome>>{};

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
    if (enabled) await _refresh();
  }

  Future<void> _onEvents(List<PurchaseEvent> events) async {
    final premium = ref.read(premiumProductsProvider);
    var changed = false;
    for (final event in events) {
      if (!premium.contains(event.productId)) continue;
      if (event.needsCompletion) {
        // A failure is retried by the next check (start, resume, restore).
        await ref
            .read(purchaseAcknowledgerProvider)
            ?.acknowledge(
              event.token ?? '${event.productId}:event',
              event.handle,
            );
      }
      if (!ref.mounted) return;
      if (event.outcome == PurchaseOutcome.purchased) changed = true;
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
    return offers..sort((a, b) => a.period.index.compareTo(b.period.index));
  }

  /// "Hazte Premium" for [offer]. Resolves once Play answers. Refused
  /// while the signed-in account is still being restored, so a purchase is
  /// never tagged as guest by mistake.
  Future<PremiumActionResult> buy(PremiumOffer offer) async {
    final gateway = _gateway;
    final plan = ref.read(entitlementsProvider);
    if (gateway == null || state.busy || !plan.accountResolved) {
      return PremiumActionResult.unavailable;
    }
    state = PremiumBillingState(busy: true, pending: state.pending);
    final waiting = Completer<PurchaseOutcome>();
    _waiting[offer.productId] = waiting;
    try {
      final tag = billingAccountTag(plan.accountKey);
      if (!await gateway.buy(offer, accountTag: tag)) {
        _waiting.remove(offer.productId);
        return PremiumActionResult.failed;
      }
      // Play always answers; the bound only protects a lost callback.
      final outcome = await waiting.future.timeout(
        const Duration(minutes: 15),
        onTimeout: () => PurchaseOutcome.failed,
      );
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
      if (ref.mounted) {
        state = PremiumBillingState(pending: state.pending);
      }
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
    await _refresh();
    if (!ref.mounted) return PremiumActionResult.failed;
    return ref.read(entitlementsProvider).isPremium
        ? PremiumActionResult.premium
        : PremiumActionResult.failed;
  }
}

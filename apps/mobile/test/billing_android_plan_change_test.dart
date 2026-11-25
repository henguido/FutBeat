import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:futbeat/core/billing.dart';
import 'package:futbeat/core/premium_qa_transport.dart';

class StoreSpy implements InAppPurchase {
  GooglePlayPurchaseParam? launched;
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    launched = purchaseParam as GooglePlayPurchaseParam;
    return true;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Android sends the old purchase and exact annual offer without granting or acknowledging', () async {
    final store = StoreSpy();
    final details = GooglePlayProductDetails.fromProductDetails(
      const ProductDetailsWrapper(description: '', name: 'Premium', title: 'Premium',
        productId: 'futbeat_premium', productType: ProductType.subs,
        subscriptionOfferDetails: [SubscriptionOfferDetailsWrapper(
          basePlanId: 'yearly', offerIdToken: 'synthetic-yearly-offer', offerTags: [],
          pricingPhases: [PricingPhaseWrapper(billingCycleCount: 0, billingPeriod: 'P1Y',
            formattedPrice: 'CRC fixture', priceAmountMicros: 1, priceCurrencyCode: 'CRC',
            recurrenceMode: RecurrenceMode.infiniteRecurring)],
        )]),
    ).single;
    final old = GooglePlayPurchaseDetails.fromPurchase(const PurchaseWrapper(
      orderId: 'synthetic-order', packageName: 'com.futbeat.futbeat', purchaseTime: 1,
      purchaseToken: 'synthetic-old-token', signature: '', products: ['futbeat_premium'],
      isAutoRenewing: true, originalJson: '{}', isAcknowledged: true,
      purchaseState: PurchaseStateWrapper.purchased, obfuscatedAccountId: 'owner-tag',
    )).single;
    final owned = OwnedPurchase(productId: 'futbeat_premium', purchased: true,
      accountTag: 'owner-tag', token: 'synthetic-old-token', handle: old);
    final offer = PremiumOffer(productId: 'futbeat_premium', period: PremiumPeriod.yearly,
      price: 'CRC fixture', handle: details);
    final gateway = PlayBillingGateway(store);
    if (!premiumServerEnabled) {
      expect(() => gateway.buy(offer, accountTag: 'owner-tag', replacing: owned),
        throwsA(isA<BillingUnavailable>()));
      expect(store.launched, null);
      return;
    }
    expect(await gateway.buy(offer, accountTag: 'owner-tag', replacing: owned), true);
    expect(store.launched!.offerToken, 'synthetic-yearly-offer');
    expect(store.launched!.applicationUserName, 'owner-tag');
    expect(store.launched!.changeSubscriptionParam!.oldPurchaseDetails, same(old));
    expect(store.launched!.changeSubscriptionParam!.replacementMode, ReplacementMode.chargeFullPrice);
    store.launched = null;
    expect(() => gateway.buy(offer, accountTag: 'foreign-tag', replacing: owned),
      throwsA(isA<BillingUnavailable>()));
    expect(store.launched, null);
  });
}

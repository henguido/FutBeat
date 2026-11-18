import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/billing.dart';
import 'package:futbeat/core/entitlements.dart';
import 'package:futbeat/core/premium_qa_transport.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

class _RestoreGateway implements BillingGateway {
  _RestoreGateway(this.purchases);
  final List<OwnedPurchase> purchases;

  @override
  Future<bool> available() async => true;

  @override
  Future<List<OwnedPurchase>> owned() async => purchases;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'one Play product exposes both base plans with their localized prices',
    () {
      SubscriptionOfferDetailsWrapper plan(
        String id,
        String price, {
        String? offer,
      }) => SubscriptionOfferDetailsWrapper(
        basePlanId: id,
        offerId: offer,
        offerTags: const [],
        offerIdToken: '$id-$offer',
        pricingPhases: [
          PricingPhaseWrapper(
            billingCycleCount: 0,
            billingPeriod: id == 'yearly' ? 'P1Y' : 'P1M',
            formattedPrice: price,
            priceAmountMicros: 1,
            priceCurrencyCode: 'CRC',
            recurrenceMode: RecurrenceMode.infiniteRecurring,
          ),
        ],
      );
      final details = GooglePlayProductDetails.fromProductDetails(
        ProductDetailsWrapper(
          description: '',
          name: 'Premium',
          title: 'Premium',
          productId: PremiumProducts.productId,
          productType: ProductType.subs,
          subscriptionOfferDetails: [
            plan('monthly', 'promo', offer: 'fixture'),
            plan('yearly', 'CRC yearly fixture'),
            plan('monthly', 'CRC monthly fixture'),
            plan('unrecognized', 'unused'),
          ],
        ),
      );
      final offers = selectPremiumBasePlans(details);
      expect(offers.map((offer) => offer.period), PremiumPeriod.values);
      expect(offers.map((offer) => offer.price), [
        'CRC monthly fixture',
        'CRC yearly fixture',
      ]);
      expect(
        (offers.first.handle as GooglePlayProductDetails).subscriptionIndex,
        2,
      );
    },
  );
  test(
    'restore verifies only distinct purchased tokens for the bound account',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <Object?>[];
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer session-a');
        if (request.method == 'POST') {
          seen.add(jsonDecode(await utf8.decoder.bind(request).join()));
        }
        request.response.write('{"status":"inactive"}');
        await request.response.close();
      });
      final transport = PremiumQaTransport(
        Uri.parse('http://127.0.0.1:${server.port}'),
        () async => 'session-a',
      );
      final tag = billingAccountTag(entitlementAccountKey('a'));
      final purchase = OwnedPurchase(
        productId: 'fixture',
        purchased: true,
        accountTag: tag,
        token: 'owned',
        needsCompletion: true,
      );
      final source = PremiumQaEntitlementSource(
        _RestoreGateway([
          purchase,
          purchase,
          OwnedPurchase(
            productId: 'fixture',
            purchased: false,
            accountTag: tag,
            token: 'pending',
          ),
          const OwnedPurchase(
            productId: 'fixture',
            purchased: true,
            accountTag: 'other',
            token: 'other',
          ),
        ]),
        (account) => account == 'a' ? transport : null,
        {'fixture'},
      );
      final restored = await source.restore('a');
      expect(restored.available, isTrue);
      expect(restored.grant, isNull);
      expect(seen, [
        {
          'tokens': ['owned'],
        },
      ]);
      expect((await source.check('b')).available, isFalse);
    },
  );
  test(
    'local transport submits only the token and reads a bounded right',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final expiry = DateTime.now().toUtc().add(const Duration(days: 1));
      final seen = <String>[];
      server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          'Bearer fixture-session',
        );
        seen.add(request.uri.path);
        if (request.method == 'POST') {
          expect(jsonDecode(await utf8.decoder.bind(request).join()), {
            'token': 'fixture-purchase',
          });
          request.response.write(
            jsonEncode({
              'status': 'active',
              'expiresAt': expiry.toIso8601String(),
            }),
          );
        } else {
          request.response.write('{"status":"inactive"}');
        }
        await request.response.close();
      });
      final transport = PremiumQaTransport(
        Uri.parse('http://127.0.0.1:${server.port}'),
        () async => 'fixture-session',
      );
      final grant = await transport.verify('fixture-purchase');
      expect(grant.grant?.plan, Plan.premium);
      expect(grant.grant?.expiresAt, expiry);
      final revoked = await transport.read();
      expect(revoked.available, isTrue);
      expect(revoked.grant, isNull);
      expect(seen, ['/premium/verify', '/premium']);
    },
  );

  test(
    'external QA endpoint and missing session cannot grant access',
    () async {
      expect(
        () => PremiumQaTransport(
          Uri.parse('https://example.test'),
          () async => '',
        ),
        throwsArgumentError,
      );
      final transport = PremiumQaTransport(
        Uri.parse('http://127.0.0.1:1'),
        () async => null,
      );
      expect((await transport.read()).available, isFalse);
    },
  );
}

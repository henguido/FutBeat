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
  bool isAvailable = true;
  int ownedCalls = 0;

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<List<OwnedPurchase>> owned() async {
    ownedCalls++;
    return purchases;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('startup recovers lost callback once; concurrent checks share restore and failures retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final submitted = <Object>[];
    var unavailable = true;
    server.listen((r) async {
      if (r.method == 'POST') {
        submitted.add(jsonDecode(await utf8.decoder.bind(r).join()));
      }
      r.response.statusCode = unavailable ? 503 : 200;
      r.response.write('{"status":"inactive"}');
      await r.response.close();
    });
    final gateway = _RestoreGateway([
      OwnedPurchase(
        productId: 'fixture',
        purchased: true,
        accountTag: billingAccountTag(entitlementAccountKey('a')),
        token: 'recovered',
        needsCompletion: true,
      ),
    ]);
    final transport = PremiumQaTransport(
      Uri.parse('http://127.0.0.1:${server.port}'),
      () async => 'synthetic',
    );
    final source = PremiumQaEntitlementSource(
      gateway,
      (a) => a == 'a' ? transport : null,
      {'fixture'},
    );
    final first = await Future.wait([source.check('a'), source.check('a')]);
    expect(first.every((r) => !r.available), true);
    expect(gateway.ownedCalls, 1);
    unavailable = false;
    expect((await source.check('a')).available, true);
    expect(gateway.ownedCalls, 2);
    expect(submitted, [
      {
        'tokens': ['recovered'],
      },
      {
        'tokens': ['recovered'],
      },
    ]);
    await source.check('a');
    expect(gateway.ownedCalls, 2); // resume reads, no Publisher work per resume
    expect((await source.check('b')).available, false);
  });

  test('Play unavailable at startup does not consume later recovery', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var restores = 0;
    server.listen((r) async {
      if (r.method == 'POST') {
        restores++;
        await r.drain<void>();
      }
      r.response.write('{"status":"inactive"}');
      await r.response.close();
    });
    final gateway = _RestoreGateway([
      const OwnedPurchase(
        productId: 'fixture', purchased: true, accountTag: 'store-tag',
        token: 'recoverable',
      ),
    ])..isAvailable = false;
    final transport = PremiumQaTransport(
      Uri.parse('http://127.0.0.1:${server.port}'),
      () async => 'synthetic',
    );
    final source = PremiumQaEntitlementSource(gateway, (_) => transport, {
      'fixture',
    });
    await source.check('a');
    expect(restores, 0);
    gateway.isAvailable = true;
    await source.check('a');
    expect(restores, 1);
    await source.check('a');
    expect(restores, 1);
  });
  test('empty Play inventory reads the server instead of posting invalid empty restore', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    server.listen((r) async {
      methods.add(r.method);
      r.response.write('{"status":"inactive"}');
      await r.response.close();
    });
    final transport = PremiumQaTransport(
      Uri.parse('http://127.0.0.1:${server.port}'), () async => 'synthetic',
    );
    final source = PremiumQaEntitlementSource(_RestoreGateway([]), (_) => transport, {'fixture'});
    expect((await source.restore('a')).available, true);
    expect(methods, ['GET']);
  });
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
    'restore delegates ownership of distinct purchased tokens to the server',
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
          'tokens': ['owned', 'other'],
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

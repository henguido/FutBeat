import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/billing.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entitlements.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/premium_qa_transport.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/premium_card.dart';

import 'support/install_secure_storage.dart';

class _NoToken implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _Store implements BillingGateway {
  @override
  Stream<List<PurchaseEvent>> get events => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PremiumFixture extends EntitlementsController {
  @override
  Entitlements build() => const Entitlements(
    accountKey: 'account:fixture',
    plan: Plan.premium,
    settled: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'P10 opts into the existing server source, never a local store grant',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final service = PushService(
        LiveRealtimeConfig.fromEnvironment(),
        db,
        _NoToken(),
        dio: dio,
        secureStorage: InstallSecureStorage(),
        userSessionAccess: true,
        pushConfigured: false,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pushServiceProvider.overrideWithValue(service),
          billingGatewayProvider.overrideWithValue(_Store()),
          currentAccountProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        service.dispose();
        await service.pending;
        dio.close(force: true);
        await db.close();
      });
      expect(premiumPlayQaEnabled, isFalse);
      expect(PremiumProducts.configured, {'futbeat_premium'});
      expect(
        container.read(entitlementSourceProvider),
        isA<PremiumQaEntitlementSource>(),
      );
      final transport = container.read(premiumQaTransportFactoryProvider)(
        'fixture-account',
      );
      expect(transport, isNotNull);
      expect(
        transport!.origin.toString(),
        'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-billing',
      );
      // No matching authenticated session: no HTTP request, purchase or grant.
      expect((await transport.read()).available, isFalse);
      expect(transport.purchasesEnabled, isFalse);
      expect(
        await container.read(premiumPurchasesAllowedProvider.future),
        isFalse,
      );
    },
    skip: !premiumProductionServerEnabled,
  );
  testWidgets('production opt-in does not expose the QA verification control', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          entitlementsProvider.overrideWith(_PremiumFixture.new),
          billingGatewayProvider.overrideWithValue(_Store()),
          entitlementSourceProvider.overrideWithValue(
            const UnavailableEntitlementSource(),
          ),
          currentAccountProvider.overrideWith((ref) => Stream.value('fixture')),
          premiumPurchasesAllowedProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: Scaffold(body: PremiumCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Premium'), findsOneWidget);
    expect(find.byKey(const ValueKey('premium-qa-verify')), findsNothing);
    expect(find.text('Verificar compra QA'), findsNothing);
  }, skip: !premiumProductionServerEnabled);
}

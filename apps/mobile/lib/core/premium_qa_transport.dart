import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'billing.dart';
import 'entitlements.dart';
import 'push.dart';

const premiumPlayQaEnabled =
    kDebugMode && bool.fromEnvironment('FUTBEAT_PREMIUM_PLAY_QA');

final premiumPurchasesAllowedProvider = FutureProvider<bool>((ref) async {
  if (!premiumPlayQaEnabled) return true;
  final owner = ref.watch(currentAccountProvider).asData?.value;
  if (owner == null) return false;
  final transport = ref.watch(premiumQaTransportFactoryProvider)(owner);
  if (transport == null) return false;
  return (await transport.read()).available && transport.purchasesEnabled;
});

final premiumQaTransportFactoryProvider =
    Provider<PremiumQaTransport? Function(String)>((ref) {
      final service = ref.watch(pushServiceProvider);
      const base = String.fromEnvironment('BILLING_BASE');
      return (accountId) {
        if (!premiumPlayQaEnabled || base.isEmpty) return null;
        final origin = Uri.tryParse(base);
        if (origin == null ||
            origin.host != 'wctxcnqcblgewaznxrqh.supabase.co' ||
            origin.host != Uri.parse(service.config.supabaseUrl).host) {
          return null;
        }
        return PremiumQaTransport.https(origin, () async {
          if (service.accountId != accountId || service.isAnonymous) {
            return null;
          }
          final session = await service.apiSession();
          return service.accountId == accountId && !service.isAnonymous
              ? session?.accessToken
              : null;
        });
      };
    });

/// Bridges purchases and restores to the QA server. Store records supply
/// tokens only. They never produce grants or trigger a device-side ack.
class PremiumQaEntitlementSource implements EntitlementSource {
  PremiumQaEntitlementSource(
    this.gateway,
    this.transportForAccount,
    Set<String> products,
  ) : products = Set.unmodifiable(products);

  final BillingGateway gateway;
  final PremiumQaTransport? Function(String accountId) transportForAccount;
  final Set<String> products;

  @override
  Future<EntitlementCheck> check(String? accountId) async => accountId == null
      ? const EntitlementCheck.unavailable()
      : await transportForAccount(accountId)?.read() ??
            const EntitlementCheck.unavailable();
  Future<EntitlementCheck> verify(String accountId, String token) async =>
      await transportForAccount(accountId)?.verify(token) ??
      const EntitlementCheck.unavailable();

  @override
  Future<EntitlementCheck> restore(String? accountId) async {
    if (accountId == null || accountId.isEmpty || products.isEmpty) {
      return const EntitlementCheck.unavailable();
    }
    final transport = transportForAccount(accountId);
    if (transport == null) return const EntitlementCheck.unavailable();
    try {
      if (!await gateway.available()) return await transport.read();
      final tag = billingAccountTag(entitlementAccountKey(accountId));
      final tokens = {
        for (final purchase in await gateway.owned())
          if (purchase.purchased &&
              purchase.accountTag == tag &&
              products.contains(purchase.productId) &&
              purchase.token != null &&
              purchase.token!.isNotEmpty)
            purchase.token!,
      };
      if (tokens.length > 10) return const EntitlementCheck.unavailable();
      return await transport.restore(tokens.toList());
    } catch (_) {
      return const EntitlementCheck.unavailable();
    }
  }
}

/// Local QA only. Android can reach the host through adb reverse.
/// The bearer is a QA session credential, separate from production auth.
class PremiumQaTransport {
  PremiumQaTransport(this.origin, this.sessionBearer)
    : _readPath = '/premium',
      _isQa = true {
    if (!kDebugMode ||
        origin.scheme != 'http' ||
        origin.host != '127.0.0.1' ||
        !origin.hasPort ||
        origin.userInfo.isNotEmpty) {
      throw ArgumentError('Premium QA requires a local non-release endpoint');
    }
  }

  /// An authenticated HTTPS transport for staging integration. Release
  /// has no provider wiring until the server and endpoint are approved.
  PremiumQaTransport.https(
    this.origin,
    this.sessionBearer, {
    HttpClient Function()? clientFactory,
  }) : _readPath = '/billing/v1/entitlement',
       _isQa = false {
    _clientFactory = clientFactory ?? HttpClient.new;
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty &&
            origin.path != '/' &&
            origin.path != '/functions/v1/futbeat-billing') ||
        origin.host == 'localhost' ||
        InternetAddress.tryParse(origin.host) != null) {
      throw ArgumentError('Billing requires an HTTPS service origin');
    }
  }

  final Uri origin;
  final Future<String?> Function() sessionBearer;
  final String _readPath;
  final bool _isQa;
  HttpClient Function() _clientFactory = HttpClient.new;

  Future<EntitlementCheck> read() => _request();

  Future<EntitlementCheck> verify(String purchaseToken) =>
      _request(purchaseToken: purchaseToken);

  bool purchasesEnabled = false;
  Future<EntitlementCheck> restore(List<String> tokens) =>
      _request(tokens: tokens);
  Future<EntitlementCheck> _request({
    String? purchaseToken,
    List<String>? tokens,
  }) async {
    final client = _clientFactory();
    try {
      purchasesEnabled = false;
      final bearer = await sessionBearer();
      if (bearer == null || bearer.isEmpty) {
        if (premiumPlayQaEnabled) {
          debugPrint('BillingQA verifier session unavailable');
        }
        return const EntitlementCheck.unavailable();
      }
      return await _exchange(
        client,
        bearer,
        purchaseToken,
        tokens,
      ).timeout(const Duration(seconds: 10));
    } catch (error) {
      if (premiumPlayQaEnabled) {
        debugPrint('BillingQA verifier exception=${error.runtimeType}');
      }
      return const EntitlementCheck.unavailable();
    } finally {
      client.close(force: true);
    }
  }

  Future<EntitlementCheck> _exchange(
    HttpClient client,
    String bearer,
    String? purchaseToken,
    List<String>? tokens,
  ) async {
    final path = tokens != null
        ? '/billing/v1/restore'
        : purchaseToken == null
        ? _readPath
        : _isQa
        ? '/premium/verify'
        : '/billing/v1/verify';
    final request = await client.openUrl(
      purchaseToken == null && tokens == null ? 'GET' : 'POST',
      origin.replace(path: '${origin.path == '/' ? '' : origin.path}$path'),
    );
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    if (purchaseToken != null || tokens != null) {
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(
          tokens == null ? {'token': purchaseToken} : {'tokens': tokens},
        ),
      );
    }
    final response = await request.close();
    if (premiumPlayQaEnabled) {
      debugPrint('BillingQA verifier HTTP ${response.statusCode}');
    }
    if (response.statusCode != HttpStatus.ok) {
      return const EntitlementCheck.unavailable();
    }
    final payload = jsonDecode(await utf8.decoder.bind(response).join());
    if (payload is! Map || (!_isQa && payload['version'] != 1)) {
      return const EntitlementCheck.unavailable();
    }
    purchasesEnabled = payload['purchasesEnabled'] == true;
    if (payload['status'] == 'inactive') {
      return const EntitlementCheck.answered(null);
    }
    final expiresAt = DateTime.tryParse('${payload['expiresAt']}');
    final now = DateTime.now().toUtc();
    if (payload['status'] != 'active' ||
        expiresAt == null ||
        !expiresAt.isAfter(now)) {
      return const EntitlementCheck.unavailable();
    }
    return EntitlementCheck.answered(
      EntitlementGrant(
        plan: Plan.premium,
        verifiedAt: now,
        expiresAt: expiresAt,
      ),
    );
  }
}

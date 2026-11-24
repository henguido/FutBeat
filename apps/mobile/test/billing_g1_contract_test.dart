import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/entitlements.dart';
import 'package:futbeat/core/premium_qa_transport.dart';

// Redirect only the test seam to a local fixture; production TLS is untouched.
class FixtureClient implements HttpClient {
  FixtureClient(this.local, this.seen);
  final HttpClient local;
  final List<Uri> seen;
  late Uri destination;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    seen.add(url);
    return local.openUrl(method, destination.replace(path: url.path));
  }

  @override
  void close({bool force = false}) => local.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('G1 preserves Edge prefix, sends exact bodies and accepts only v1 server rights', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <Uri>[];
    final bodies = <Object>[];
    var status = 'active';
    var code = 200;
    var version = 1;
    var enabled = true;
    var rejectedCount = 0;
    server.listen((r) async {
      expect(r.headers.value('authorization'), 'Bearer synthetic-session');
      if (r.method == 'POST') {
        bodies.add(jsonDecode(await utf8.decoder.bind(r).join()));
      }
      r.response.statusCode = code;
      r.response.write(
        jsonEncode({
          'version': version,
          'status': status,
          'plan': 'monthly',
          'purchasesEnabled': enabled,
          'rejected': rejectedCount,
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 2))
              .toIso8601String(),
        }),
      );
      await r.response.close();
    });
    final origin = Uri.parse(
      'https://fixture.supabase.co/functions/v1/futbeat-billing',
    );
    final transport = PremiumQaTransport.https(
      origin,
      () async => 'synthetic-session',
      clientFactory: () =>
          FixtureClient(HttpClient(), paths)
            ..destination = Uri.parse('http://127.0.0.1:${server.port}'),
    );
    expect((await transport.read()).grant?.plan, Plan.premium);
    expect(transport.activeBasePlanId, 'monthly');
    expect(transport.purchasesEnabled, true);
    expect((await transport.verify('purchase')).grant?.plan, Plan.premium);
    await transport.restore(['purchase']);
    expect(paths.map((p) => p.path), [
      '/functions/v1/futbeat-billing/billing/v1/entitlement',
      '/functions/v1/futbeat-billing/billing/v1/verify',
      '/functions/v1/futbeat-billing/billing/v1/restore',
    ]);
    expect(bodies, [
      {'token': 'purchase'},
      {
        'tokens': ['purchase'],
      },
    ]);
    code = 503;
    final unavailable = await transport.read();
    expect(unavailable.available, false); // unavailable != revoked
    expect(unavailable.failure, EntitlementFailure.temporarilyUnavailable);
    expect(transport.activeBasePlanId, null);
    expect(unavailable.grant, null);
    expect(transport.purchasesEnabled, false);
    code = 403;
    status = 'rejected';
    final rejected = await transport.verify('other-owner-token');
    expect(rejected.available, false);
    expect(rejected.failure, EntitlementFailure.purchaseRejected);
    expect(rejected.grant, null);
    code = 200;
    status = 'inactive';
    enabled = false;
    final revoked = await transport.read();
    expect(revoked.available, true);
    expect(revoked.grant, null);
    expect(transport.purchasesEnabled, false);
    rejectedCount = 1;
    final foreignRestore = await transport.restore(['other-owner-token']);
    expect(foreignRestore.available, true);
    expect(foreignRestore.grant, null);
    expect(foreignRestore.failure, EntitlementFailure.purchaseRejected);
    rejectedCount = 0;
    version = 2;
    status = 'active';
    expect((await transport.read()).available, false);
  });

  test('G1 rejects insecure, redirected and unexpected service bases', () {
    for (final url in [
      'http://fixture.test',
      'https://user:pass@fixture.test',
      'https://fixture.test/other',
      'https://fixture.test/?token=secret',
    ]) {
      expect(
        () => PremiumQaTransport.https(Uri.parse(url), () async => null),
        throwsArgumentError,
      );
    }
  });
}

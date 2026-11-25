import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/premium_qa_transport.dart';

void main() {
  const prod = 'https://izlmruqawgagwdcsjhte.supabase.co';
  const qa = 'https://wctxcnqcblgewaznxrqh.supabase.co';
  const path = '/functions/v1/futbeat-billing';

  Uri? resolve({
    bool debug = false,
    bool qaFlag = false,
    bool production = false,
    String auth = prod,
    String base = '$prod$path',
  }) => resolvePremiumBillingOrigin(
    debugBuild: debug,
    qaEnabled: qaFlag,
    productionEnabled: production,
    authOrigin: auth,
    billingBase: base,
  );

  test('release stays disabled without explicit server opt-in', () {
    expect(resolve(), isNull);
  });
  test('production opt-in accepts only the paired production service', () {
    expect(resolve(production: true), Uri.parse('$prod$path'));
    expect(resolve(production: true, auth: '$prod/'), Uri.parse('$prod$path'));
  });
  test('G2 QA remains debug-only on its paired Auth project', () {
    expect(
      resolve(debug: true, qaFlag: true, auth: qa, base: '$qa$path'),
      Uri.parse('$qa$path'),
    );
    expect(resolve(qaFlag: true, auth: qa, base: '$qa$path'), isNull);
  });
  test('QA and production flags cannot be combined', () {
    expect(resolve(debug: true, qaFlag: true, production: true), isNull);
  });
  test('a production session cannot be sent to G2 QA', () {
    expect(resolve(production: true, base: '$qa$path'), isNull);
  });
  test('a QA session cannot be sent to G3 production', () {
    expect(resolve(production: true, auth: qa), isNull);
    expect(resolve(debug: true, qaFlag: true, auth: qa), isNull);
  });
  for (final base in [
    'http://izlmruqawgagwdcsjhte.supabase.co$path',
    'https://izlmruqawgagwdcsjhte.supabase.co.evil.invalid$path',
    'https://user@izlmruqawgagwdcsjhte.supabase.co$path',
    '$prod:444$path',
    '$prod$path?token=fixture',
    '$prod$path#fragment',
    '$prod$path/other',
    '$prod/functions/v1/another-function',
    'https://127.0.0.1$path',
    '',
  ]) {
    test('rejects an unapproved verifier URL: $base', () {
      expect(resolve(production: true, base: base), isNull);
    });
  }
}

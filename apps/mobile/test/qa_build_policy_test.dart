import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/qa_development.dart';

void main() {
  test('local-cache build is opt-in and refuses unsafe native services', () {
    final previous = HttpOverrides.current;
    try {
      if (!qaLocalCacheOnly) {
        installQaLocalCachePolicy();
        expect(HttpOverrides.current, same(previous));
      } else if (!const bool.fromEnvironment('FUTBEAT_ADS_DISABLED') ||
          const bool.fromEnvironment('FUTBEAT_USE_DEMO') ||
          const bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') ||
          const bool.fromEnvironment('FUTBEAT_OAUTH_GOOGLE_ENABLED') ||
          const bool.fromEnvironment('FUTBEAT_OAUTH_FACEBOOK_ENABLED')) {
        expect(installQaLocalCachePolicy, throwsStateError);
        expect(HttpOverrides.current, same(previous));
      } else {
        installQaLocalCachePolicy();
        expect(HttpOverrides.current, isA<QaOfflineHttpOverrides>());
        expect(() => HttpClient(), throwsA(isA<SocketException>()));
      }
    } finally {
      HttpOverrides.global = previous;
    }
  });
}

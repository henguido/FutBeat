import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  test(
    'disabled passive Preview blocks unrelated HTTP and live/auth config',
    () {
      final previous = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = previous);
      installPassivePreviewPolicy();
      expect(passivePreviewEnabled, isFalse);
      expect(HttpClient.new, throwsA(isA<SocketException>()));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(liveRealtimeConfigProvider).isConfigured, isFalse);
    },
    skip: !passivePreview,
  );
}

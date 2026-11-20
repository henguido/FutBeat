import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  test(
    'progress resumes after a failed mutation and read waits for writes',
    () async {
      final release = Completer<void>();
      var writes = 0;
      String? stored;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'write') {
              if (++writes == 1) {
                throw PlatformException(code: 'local-fixture-error');
              }
              await release.future;
              stored = (call.arguments as Map)['value'] as String;
            } else if (call.method == 'read') {
              return stored;
            }
            return null;
          });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      const store = SecureOnboardingProgressStore();
      await store.write(OnboardingStep.country);
      final saved = store.write(OnboardingStep.players);
      var readFinished = false;
      final read = store.read().then((value) {
        readFinished = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(readFinished, isFalse);
      release.complete();
      await saved;
      expect(await read, OnboardingStep.players);
    },
  );
  for (final clear in [false, true]) {
    test(
      'onboarding progress preserves mutation order (clear=$clear)',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        String? stored;
        var writes = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'write') {
                writes++;
                final value = (call.arguments as Map)['value'] as String;
                if (writes == 1) {
                  entered.complete();
                  await release.future;
                }
                stored = value;
              } else if (call.method == 'delete') {
                stored = null;
              } else if (call.method == 'read') {
                return stored;
              }
              return null;
            });
        addTearDown(() {
          if (!release.isCompleted) release.complete();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        const store = SecureOnboardingProgressStore();
        final first = store.write(OnboardingStep.teams);
        await entered.future;
        final second = clear
            ? store.clear()
            : store.write(OnboardingStep.players);
        // Allow overlapping platform operations to finish in reverse order.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        release.complete();
        await Future.wait([first, second]);
        expect(await store.read(), clear ? null : OnboardingStep.players);
      },
    );
  }
}

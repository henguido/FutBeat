import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _DelayedSettings extends PushService {
  _DelayedSettings(AppDatabase db)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens(),
        pushConfigured: false,
      );
  final saved = Completer<void>();
  UserProfileSettings? submitted;
  @override
  Future<void> saveProfileSettings(UserProfileSettings value) async {
    submitted = value;
    await saved.future;
  }
}

void main() {
  testWidgets('hour format save may finish after personalization is closed', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final service = _DelayedSettings(db);
    final container = ProviderContainer(
      overrides: [
        pushServiceProvider.overrideWithValue(service),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: 'CR',
              bootstrapDismissed: true,
            ),
          ),
        ),
        followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
        profileSettingsProvider.overrideWith(
          (ref) async => const UserProfileSettings(),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      service.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PersonalizationScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final hour = find.byKey(const ValueKey('hour-format'));
    await tester.scrollUntilVisible(
      hour,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(hour);
    await tester.pumpAndSettle();
    await tester.tap(find.text('24 horas').last);
    await tester.pumpAndSettle();
    expect(service.submitted?.hourFormat, '24h');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: Text('Perfil cerrado'))),
      ),
    );
    await tester.pumpAndSettle();
    service.saved.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Perfil cerrado'), findsOneWidget);
  });
}

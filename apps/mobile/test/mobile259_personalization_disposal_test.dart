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
  _DelayedSettings(AppDatabase db, this.localWriteSucceeds)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens(),
        pushConfigured: false,
      );
  final bool localWriteSucceeds;
  final saved = Completer<void>();
  UserProfileSettings local = const UserProfileSettings();
  UserProfileSettings? submitted;
  var saves = 0;
  @override
  Future<UserProfileSettings> loadProfileSettings() async => local;
  @override
  Future<void> updateProfileSettings(
    UserProfileSettings Function(UserProfileSettings) update, {
    String? expectedUserId,
  }) => saveProfileSettings(update(local));
  @override
  Future<void> saveProfileSettings(UserProfileSettings value) async {
    saves++;
    submitted = value;
    if (localWriteSucceeds) local = value;
    await saved.future;
  }
}

Future<_DelayedSettings> _open(
  WidgetTester tester, {
  bool localWriteSucceeds = true,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final service = _DelayedSettings(db, localWriteSucceeds);
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
        (ref) => service.loadProfileSettings(),
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
  return service;
}

void main() {
  testWidgets('hour format save may finish after personalization is closed', (
    tester,
  ) async {
    final service = await _open(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Perfil cerrado'))),
    );
    await tester.pumpAndSettle();
    service.saved.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Perfil cerrado'), findsOneWidget);
  });
  for (final localWriteSucceeds in [true, false]) {
    testWidgets(
      'hour format handles save rejection with local write $localWriteSucceeds',
      (tester) async {
        final service = await _open(
          tester,
          localWriteSucceeds: localWriteSucceeds,
        );
        service.saved.completeError(StateError('Synthetic save unavailable'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            localWriteSucceeds
                ? 'Guardado en este dispositivo. Se sincronizará cuando haya conexión.'
                : 'No pudimos guardar este cambio. Inténtalo nuevamente.',
          ),
          findsOneWidget,
        );
        expect(service.local.hourFormat, localWriteSucceeds ? '24h' : 'system');
        final dropdown = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        );
        expect(dropdown.value, service.local.hourFormat);
        expect(
          service.saves,
          1,
          reason: 'restoring the field must not save again',
        );
      },
    );
  }
}

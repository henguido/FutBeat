import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build flag selects the shared demo-mode provider', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const demoBuild = bool.fromEnvironment('FUTBEAT_USE_DEMO');
    expect(container.read(demoModeProvider), demoBuild);
    if (demoBuild) {
      expect(container.read(repositoryProvider), isA<DemoRepository>());
      expect(container.read(liveRealtimeConfigProvider).isConfigured, isFalse);
    }
  });

  test('demo uses bundled matches and disables LIVE REST/WebSocket', () async {
    final container = ProviderContainer(
      overrides: [demoModeProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);

    final repository = container.read(repositoryProvider);
    expect(repository, isA<DemoRepository>());

    final config = container.read(liveRealtimeConfigProvider);
    expect(config.isConfigured, isFalse);
    expect(config.supabaseUrl, isEmpty);
    expect(config.publicKey, isEmpty);
    // The demo overlay provider must not even construct the Dio/WebSocket
    // client, regardless of the Android production defaults.
    container.read(liveMatchUpdatesProvider);
    expect(container.exists(liveRealtimeClientProvider), isFalse);
  });

  test('demo account restore cannot contact Supabase Auth', () async {
    FlutterSecureStorage.setMockInitialValues({
      'futbeat.push.session':
          '{"access_token":"stored","refresh_token":"stored"}',
    });
    final database = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        demoModeProvider.overrideWithValue(true),
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final account = container.read(pushServiceProvider);
    await account.restore();
    expect(account.accountConfigured, isFalse);
    expect(account.authenticated, isFalse);
    expect(account.buildOAuthProviders, isEmpty);
    await expectLater(
      account.signIn('qa@example.test', 'not-a-password'),
      throwsStateError,
    );
  });

  testWidgets('demo widgets receive an empty LIVE overlay', (tester) async {
    final container = ProviderContainer(
      overrides: [demoModeProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (context, ref, child) {
              final updates = ref.watch(liveMatchUpdatesProvider);
              return Text(
                updates.asData?.value.isEmpty == true ? 'empty' : 'waiting',
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('empty'), findsOneWidget);
    expect(container.exists(liveRealtimeClientProvider), isFalse);
  });

  test('real mode retains the existing Supabase configuration path', () {
    final container = ProviderContainer(
      overrides: [demoModeProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);

    final actual = container.read(liveRealtimeConfigProvider);
    final expected = LiveRealtimeConfig.fromEnvironment();
    expect(actual.supabaseUrl, expected.supabaseUrl);
    expect(actual.publicKey, expected.publicKey);
    expect(actual.isConfigured, expected.isConfigured);
  });
}

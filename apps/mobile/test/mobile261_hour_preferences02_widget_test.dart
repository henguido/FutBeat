import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

void main() {
  for (final retainedHandler in [true, false]) {
    testWidgets(
      'personalization hour preserves B (retained handler=$retainedHandler)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        FlutterSecureStorage.setMockInitialValues({});
        const storage = FlutterSecureStorage();
        late final AppDatabase db;
        final profiles = <String, Map<String, dynamic>>{
          'a': const UserProfileSettings(
            displayName: 'Account A',
            hourFormat: '12h',
            notifyGoals: true,
            notifyFinal: true,
          ).toJson(),
          'b': const UserProfileSettings(
            displayName: 'Account B',
            hourFormat: '12h',
            notifyGoals: false,
            notifyFinal: true,
          ).toJson(),
        };
        final chosenFieldSaved = Completer<void>();
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (r, h) {
                final uid = '${r.headers['Authorization']}'.endsWith('access-b')
                    ? 'b'
                    : 'a';
                Object? data;
                if (r.path.contains('/auth/v1/token')) {
                  final target = (r.data as Map)['email'] == 'b@example.test'
                      ? 'b'
                      : 'a';
                  data = {
                    'access_token': 'access-$target',
                    'refresh_token': 'refresh-$target',
                    'user': {'id': target},
                  };
                } else if (r.path.endsWith('futbeat_read_user_profile')) {
                  data = {'preferences': profiles[uid]!, 'follows': <Object>[]};
                } else if (r.path.endsWith('futbeat_sync_user_profile_v3')) {
                  profiles[uid] = Map<String, dynamic>.from(
                    (r.data as Map)['p_profile'] as Map,
                  );
                  if (uid == 'b' &&
                      profiles['b']!['hourFormat'] == '24h' &&
                      !chosenFieldSaved.isCompleted) {
                    chosenFieldSaved.complete();
                  }
                }
                h.resolve(
                  Response(requestOptions: r, statusCode: 200, data: data),
                );
              },
            ),
          );
        late final PushService service;
        late final ProviderContainer container;
        var closed = false;
        addTearDown(() async {
          if (closed) return;
          service.dispose();
          await service.pending;
          await service.signOutCleanup;
          container.dispose();
          dio.close(force: true);
          await db.close();
        });
        await tester.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          service = PushService(
            const LiveRealtimeConfig(
              supabaseUrl: 'https://fixture.invalid',
              publicKey: 'synthetic',
            ),
            db,
            _Tokens(),
            dio: dio,
            pushConfigured: false,
          );
          container = ProviderContainer(
            overrides: [
              pushServiceProvider.overrideWithValue(service),
              databaseProvider.overrideWithValue(db),
              preferenceProvider.overrideWith(
                (ref) => Stream.value(
                  const CountryPreference(
                    detectedCountry: 'CR',
                    selectedCountry: 'CR',
                    bootstrapDismissed: true,
                  ),
                ),
              ),
              followsProvider.overrideWith(
                (ref) => Stream.value(const <String>{}),
              ),
            ],
          );
          await service.signIn('a@example.test', 'synthetic-password');
          await service.pending;
          expect(
            (await service.loadProfileSettings()).displayName,
            'Account A',
          );
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: PersonalizationScreen()),
          ),
        );
        final field = find.byType(DropdownButtonFormField<String>);
        for (var turn = 0; turn < 200 && field.evaluate().isEmpty; turn++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(
          field,
          findsOneWidget,
          reason: 'The actual PersonalizationScreen must finish loading',
        );
        await tester.ensureVisible(field);
        final rendered = tester.widget<DropdownButtonFormField<String>>(field);
        expect(rendered.initialValue, '12h');
        expect(rendered.onChanged, isNotNull);
        // Preserve this same mounted screen: its local model was loaded for A.
        await tester.runAsync(() async {
          await service.signOut();
          await service.signIn('b@example.test', 'synthetic-password');
          await service.pending;
          final current = await service.loadProfileSettings();
          expect(
            current.displayName,
            'Account B',
            reason: 'B identity already reconciled before interacting with retained UI',
          );
          expect(current.hourFormat, '12h');
          expect(
            current.notifyGoals,
            isFalse,
            reason: 'Unedited B goal-alert preference must remain false',
          );
          expect(
            await storage.read(key: PushService.leftoverKey),
            isNull,
            reason: 'No A ownership marker remains to mask this caller-intent regression',
          );
        });
        // Invoke the actual handler retained by the rendered A widget before
        // pumping the B provider update. This is a widget-handler test, not a
        // physical gesture or a claim about the discarded old menu harness.
        if (retainedHandler) {
          await tester.runAsync(() async => rendered.onChanged!('24h'));
        } else {
          for (
            var turn = 0;
            turn < 200 &&
                container
                        .read(profileSettingsProvider)
                        .asData
                        ?.value
                        .displayName !=
                    'Account B';
            turn++
          ) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          expect(
            container.read(profileSettingsProvider).asData?.value.displayName,
            'Account B',
          );
          await tester.pump();
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
          final choice = find.text('24 horas').last;
          expect(choice, findsOneWidget);
          await tester.tap(choice);
        }
        for (
          var turn = 0;
          turn < 200 && !chosenFieldSaved.isCompleted;
          turn++
        ) {
          // A real menu selection completes after its closing animation.
          // Advance the widget clock as well as letting native I/O progress.
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(
          chosenFieldSaved.isCompleted,
          isTrue,
          reason: 'The real hour handler must finish its local/simulated sync',
        );
        final observed = await tester.runAsync(() async {
          return (
            current: await service.loadProfileSettings(),
            cloudB: Map<String, dynamic>.from(profiles['b']!),
          );
        });
        expect(
          observed,
          isNotNull,
          reason: 'UI chosen-field save must finish within bounded real I/O',
        );
        final current = observed!.current;
        expect(current.notifyFinal, isTrue);
        expect(profiles['b']!['notifyFinal'], isTrue);
        expect(
          current.displayName,
          'Account B',
          reason:
              'An unedited account name must stay B after the UI field save',
        );
        expect(profiles['b']!['displayName'], 'Account B');
        expect(
          current.hourFormat,
          '24h',
          reason:
              'Stored hour format must reflect only the intended field change',
        );
        expect(
          current.notifyGoals,
          isFalse,
          reason: 'Unedited B goal-alert preference must remain false',
        );
        expect(profiles['a']!['displayName'], 'Account A');

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          service.dispose();
          await service.pending;
          await service.signOutCleanup;
          container.dispose();
          dio.close(force: true);
          await db.close();
          closed = true;
        });
      },
    );
  }
}

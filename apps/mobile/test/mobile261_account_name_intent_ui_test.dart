import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/account_security_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _DeletionRecordingService extends PushService {
  _DeletionRecordingService(AppDatabase db, Dio dio)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );

  final deletionUsers = <String?>[];

  @override
  Future<void> deleteAccount() async {
    deletionUsers.add(userId);
  }
}

void main() {
  for (final switchesAccount in [false, true]) {
    testWidgets(
      switchesAccount
          ? 'confirmation shown for A never dispatches deletion for B'
          : 'confirmation shown for A dispatches deletion for unchanged A',
      (tester) async {
        tester.view.physicalSize = const Size(390, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        FlutterSecureStorage.setMockInitialValues({});

        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) {
                Object? data;
                if (request.path.contains('/auth/v1/token')) {
                  final email = (request.data as Map)['email'] as String;
                  final uid = email.split('@').first;
                  data = {
                    'access_token': 'access-$uid',
                    'refresh_token': 'refresh-$uid',
                    'user': {'id': uid, 'email': email},
                  };
                } else if (request.path.endsWith('futbeat_read_user_profile')) {
                  data = {
                    'preferences': <String, dynamic>{},
                    'follows': <Object>[],
                  };
                }
                handler.resolve(Response(requestOptions: request, data: data));
              },
            ),
          );
        late final AppDatabase db;
        late final _DeletionRecordingService service;
        late final ProviderContainer container;
        await tester.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          service = _DeletionRecordingService(db, dio);
          container = ProviderContainer(
            overrides: [pushServiceProvider.overrideWithValue(service)],
          );
          await service.signIn('a@example.test', 'synthetic-password');
        });
        addTearDown(() async {
          service.dispose();
          container.dispose();
          await db.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: AccountSecurityScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('account-delete')));
        await tester.pumpAndSettle();
        final confirm = find.text('Eliminar definitivamente');
        expect(confirm, findsOneWidget);
        expect(service.userId, 'a');

        if (switchesAccount) {
          await tester.runAsync(
            () => service.signIn('b@example.test', 'synthetic-password'),
          );
          expect(service.userId, 'b');
        }
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(service.deletionUsers, switchesAccount ? isEmpty : ['a']);
        expect(service.userId, switchesAccount ? 'b' : 'a');
        expect(
          find.text(
            switchesAccount
                ? 'La cuenta cambió. Vuelve a abrir esta pantalla.'
                : 'Cuenta eliminada.',
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'old account name form cannot rename a different current account',
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
          hourFormat: '24h',
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
                    profiles['b']!['displayName'] == 'Account A edit' &&
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
          overrides: [pushServiceProvider.overrideWithValue(service)],
        );
        await service.signIn('a@example.test', 'synthetic-password');
        await service.pending;
        expect((await service.loadProfileSettings()).displayName, 'Account A');
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AccountSecurityScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-name')), findsOneWidget);
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
        expect(
          await storage.read(key: PushService.leftoverKey),
          isNull,
          reason: 'No A ownership marker remains to mask this caller-intent regression',
        );
      });
      await tester.enterText(
        find.byKey(const ValueKey('account-name')),
        'Account A edit',
      );
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('account-name-save')),
      );
      expect(save.onPressed, isNotNull);
      save.onPressed!();
      for (
        var turn = 0;
        turn < 200 &&
            !chosenFieldSaved.isCompleted &&
            find
                .text('La cuenta cambió. Vuelve a abrir esta pantalla.')
                .evaluate()
                .isEmpty;
        turn++
      ) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
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
        reason: 'An unedited account name must stay B after the UI field save',
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

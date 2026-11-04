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
import 'package:futbeat/features/profile/notifications_screen_v2.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

void main() {
  testWidgets(
    'notification toggle from retained A screen changes only B chosen field',
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
          child: const MaterialApp(home: NotificationsScreenV2()),
        ),
      );
      await tester.pumpAndSettle();
      final option = find.byKey(const ValueKey('notification-notify_final'));
      await tester.ensureVisible(option);
      expect(tester.widget<SwitchListTile>(option).value, isTrue);
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
        expect(current.hourFormat, '24h');
        expect(current.notifyGoals, isFalse);
        expect(
          await storage.read(key: PushService.leftoverKey),
          isNull,
          reason: 'No A ownership marker remains to mask this caller-intent regression',
        );
      });
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.pending;
        final current = await service.loadProfileSettings();
        expect(current.notifyFinal, isFalse);
        expect(profiles['b']!['notifyFinal'], isFalse);
        expect(current.displayName, 'Account B');
        expect(profiles['b']!['displayName'], 'Account B');
        expect(current.hourFormat, '24h');
        expect(current.notifyGoals, isFalse);
        expect(profiles['a']!['displayName'], 'Account A');
      });
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

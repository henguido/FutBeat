import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

class _DelayedSave extends PushService {
  _DelayedSave(AppDatabase db, Dio dio)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );
  final completion = Completer<void>();
  int loads = 0;
  int saves = 0;
  UserProfileSettings get currentProfile => const UserProfileSettings();
  @override
  Future<void> updateProfileSettings(
    UserProfileSettings Function(UserProfileSettings) update, {
    String? expectedUserId,
  }) => saveProfileSettings(update(currentProfile));
  @override
  Future<UserProfileSettings> loadProfileSettings() async {
    loads++;
    return const UserProfileSettings();
  }

  @override
  Future<void> saveProfileSettings(UserProfileSettings settings) {
    saves++;
    return completion.future;
  }
}

class _DelayedRecovery extends _DelayedSave {
  _DelayedRecovery(super.db, super.dio);
  final recovery = Completer<UserProfileSettings>();
  UserProfileSettings persisted = const UserProfileSettings();
  @override
  UserProfileSettings get currentProfile => persisted;
  @override
  Future<UserProfileSettings> loadProfileSettings() async {
    loads++;
    return loads == 1 ? persisted : recovery.future;
  }

  @override
  Future<void> saveProfileSettings(UserProfileSettings settings) async {
    persisted = settings;
    saves++;
    if (saves == 1) throw StateError('local-only first save');
  }
}

void main() {
  testWidgets('older failed save recovery cannot undo a newer toggle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final service = _DelayedRecovery(db, dio);
    final container = ProviderContainer(
      overrides: [pushServiceProvider.overrideWithValue(service)],
    );
    addTearDown(() async {
      service.dispose();
      container.dispose();
      dio.close(force: true);
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NotificationsScreenV2()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notification-notify_kickoff')));
    await tester.pump();
    expect(service.loads, 2);
    // This read began after the first toggle, before the second was saved.
    final oldRead = service.persisted;
    await tester.tap(find.byKey(const ValueKey('notification-notify_goals')));
    await tester.pump();
    expect(service.persisted.notifyGoals, isFalse);
    service.recovery.complete(oldRead);
    await tester.pump();
    final goals = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('notification-notify_goals')),
    );
    expect(goals.value, isFalse);
    expect(tester.takeException(), isNull);
  });
  for (final fail in [false, true]) {
    testWidgets(
      'closing notification preferences during save (failure=$fail)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final service = _DelayedSave(db, dio);
        final container = ProviderContainer(
          overrides: [pushServiceProvider.overrideWithValue(service)],
        );
        addTearDown(() async {
          service.dispose();
          container.dispose();
          dio.close(force: true);
          await db.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: NotificationsScreenV2()),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Avísame al iniciar el partido'));
        await tester.pump();
        expect(service.saves, 1);
        expect(service.loads, 1);
        await tester.pumpWidget(const SizedBox());
        if (fail) {
          service.completion.completeError(StateError('local fixture failure'));
        } else {
          service.completion.complete();
        }
        await tester.pump();
        expect(
          service.loads,
          1,
          reason: 'a removed route must not start error recovery reads',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

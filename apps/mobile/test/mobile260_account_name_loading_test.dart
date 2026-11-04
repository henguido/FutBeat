import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/account_security_screen.dart';

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _LoadingAccount extends PushService {
  _LoadingAccount(AppDatabase db, Dio dio)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens(),
        dio: dio,
        pushConfigured: false,
      ) {
    session = {
      'access_token': 'synthetic',
      'user': {'id': 'local-test'},
    };
  }
  final initialRestore = Completer<void>();
  final writes = <UserProfileSettings>[];
  bool failLoadOnce = false;
  @override
  Future<void> restore() => initialRestore.future;
  @override
  Future<UserProfileSettings> loadProfileSettings() async {
    if (failLoadOnce) {
      failLoadOnce = false;
      throw StateError('controlled local profile read failure');
    }
    return const UserProfileSettings(
      displayName: 'Nombre guardado',
      notifyGoals: false,
      notifyKickoff: false,
    );
  }

  @override
  Future<void> saveProfileSettings(UserProfileSettings settings) async =>
      writes.add(settings);
  @override
  Future<void> updateProfileSettings(
    UserProfileSettings Function(UserProfileSettings) update, {
    String? expectedUserId,
  }) async => saveProfileSettings(update(await loadProfileSettings()));
}

void main() {
  testWidgets('failed profile loading keeps save disabled and offers retry', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final service = _LoadingAccount(db, dio)..failLoadOnce = true;
    service.initialRestore.complete();
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
        child: const MaterialApp(home: AccountSecurityScreen()),
      ),
    );
    await tester.pump();
    final save = find.byKey(const ValueKey('account-name-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(service.writes, isEmpty);
    expect(find.text('Reintentar'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('account-name')))
          .controller!
          .text,
      'Nombre guardado',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('name save waits for loaded preferences and preserves alerts', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final service = _LoadingAccount(db, dio);
    final container = ProviderContainer(
      overrides: [pushServiceProvider.overrideWithValue(service)],
    );
    addTearDown(() async {
      if (!service.initialRestore.isCompleted) {
        service.initialRestore.complete();
      }
      service.dispose();
      container.dispose();
      dio.close(force: true);
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AccountSecurityScreen()),
      ),
    );
    final field = find.byKey(const ValueKey('account-name'));
    final save = find.byKey(const ValueKey('account-name-save'));
    if (tester.widget<TextField>(field).enabled == true) {
      await tester.enterText(field, 'Nuevo nombre');
    }
    tester.widget<FilledButton>(save).onPressed?.call();
    await tester.pump();
    expect(
      service.writes,
      isEmpty,
      reason:
          'default settings must never overwrite unloaded alert preferences',
    );
    service.initialRestore.complete();
    await tester.pump();
    await tester.enterText(field, 'Nuevo nombre');
    await tester.tap(save);
    await tester.pump();
    expect(service.writes.single.displayName, 'Nuevo nombre');
    expect(service.writes.single.notifyGoals, isFalse);
    expect(service.writes.single.notifyKickoff, isFalse);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

Map<String, dynamic> session(String id) => {
  'access_token': 'synthetic-$id',
  'refresh_token': 'synthetic-refresh-$id',
  'user': {'id': id},
};

class _HeldCleanupStorage extends FlutterSecureStorage {
  final cleanupStarted = Completer<void>();
  final releaseCleanup = Completer<void>();
  final nextSessionStarted = Completer<void>();

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == 'futbeat.push.session' && !cleanupStarted.isCompleted) {
      cleanupStarted.complete();
      await releaseCleanup.future;
    }
    if (key == 'futbeat.auth.pendingConfirmationEmail' &&
        !nextSessionStarted.isCompleted) {
      nextSessionStarted.complete();
    }
    await super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

class _CleanupService extends PushService {
  _CleanupService(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final phase in ['queued', 'success', 'failure']) {
    test(
      'real sign-in B supersedes deletion A at $phase without push transfer',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'futbeat.push.session': jsonEncode(session('A')),
          'futbeat.push.enabled': 'true',
        });
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final storage = _HeldCleanupStorage();
        final service = _CleanupService(db, dio, storage)
          ..session = session('A')
          ..enabled = true;
        final releaseDeletion = Completer<void>();
        final deletionStarted = Completer<void>();
        final queued = Completer<void>();
        final requests = <RequestOptions>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) async {
              requests.add(request);
              Object data = <String, dynamic>{};
              if (request.path.endsWith('futbeat-delete-account')) {
                deletionStarted.complete();
                await releaseDeletion.future;
                if (phase == 'failure') {
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      response: Response(
                        requestOptions: request,
                        statusCode: 503,
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
                data = {'deleted': true};
              } else if (request.path.contains('/auth/v1/token')) {
                data = session('B');
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
        addTearDown(() async {
          if (!storage.releaseCleanup.isCompleted) {
            storage.releaseCleanup.complete();
          }
          if (!releaseDeletion.isCompleted) releaseDeletion.complete();
          if (!queued.isCompleted) queued.complete();
          service.dispose();
          await db.close();
        });
        if (phase == 'queued') service.pending = queued.future;
        final deleting = service.deleteAccount().then(
          (_) => true,
          onError: (_) => false,
        );
        if (phase != 'queued') {
          await deletionStarted.future.timeout(const Duration(seconds: 5));
        }
        final signingIn = service.signIn(
          'b@fixture.invalid',
          'synthetic-password',
        );
        // _startSession has accepted B, before it can finish its session write
        // and reconciliation. This is an actual storage event, not a delay.
        await storage.nextSessionStarted.future.timeout(
          const Duration(seconds: 5),
        );
        expect(service.userId, 'B');
        await service.saveProfileSettings(
          const UserProfileSettings(
            displayName: 'Persona sintética B',
            hourFormat: '24h',
          ),
        );
        if (phase == 'queued') {
          queued.complete();
        } else {
          releaseDeletion.complete();
        }
        await signingIn;
        expect(await deleting, isFalse);
        await service.pending;
        expect(service.userId, 'B');
        expect(
          jsonDecode(
            (await storage.read(key: 'futbeat.push.session'))!,
          )['user']['id'],
          'B',
        );
        expect((await service.loadProfileSettings()).hourFormat, '24h');
        expect(
          service.enabled,
          isFalse,
          reason: 'B must not inherit enabled from A',
        );
        expect(await storage.read(key: 'futbeat.push.enabled'), 'false');
        final deletionCalls = requests.where(
          (r) => r.path.endsWith('futbeat-delete-account'),
        );
        if (phase == 'queued') {
          expect(deletionCalls, isEmpty);
        } else {
          expect(
            deletionCalls.single.headers['Authorization'],
            'Bearer synthetic-A',
          );
        }
      },
    );
  }
  test(
    'confirmed deletion cleanup cannot erase real sign-in B or preferences',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session('A')),
        'futbeat.push.enabled': 'true',
      });
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final storage = _HeldCleanupStorage();
      final service = _CleanupService(db, dio, storage)
        ..session = session('A')
        ..enabled = true;
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            Object data = <String, dynamic>{};
            if (request.path.contains('/auth/v1/token')) {
              data = session('B');
            } else if (request.path.endsWith('futbeat-delete-account')) {
              data = {'deleted': true};
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
      addTearDown(() async {
        if (!storage.releaseCleanup.isCompleted) {
          storage.releaseCleanup.complete();
        }
        service.dispose();
        await db.close();
      });
      final deleting = service.deleteAccount().then(
        (_) => true,
        onError: (_) => false,
      );
      await storage.cleanupStarted.future.timeout(const Duration(seconds: 5));
      expect(service.authenticated, isFalse);
      final signingIn = service.signIn(
        'b@fixture.invalid',
        'synthetic-password',
      );
      await storage.nextSessionStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(service.userId, 'B');
      await service.saveProfileSettings(
        const UserProfileSettings(
          displayName: 'Persona sintética B',
          hourFormat: '24h',
        ),
      );
      // B has accepted real token/login response and saved settings while A's
      // confirmed cleanup is still awaiting its platform session deletion.
      expect((await service.loadProfileSettings()).hourFormat, '24h');
      storage.releaseCleanup.complete();
      await signingIn;
      expect(await deleting, isTrue);
      await service.pending;
      expect(service.userId, 'B');
      expect(
        jsonDecode(
          (await storage.read(key: 'futbeat.push.session'))!,
        )['user']['id'],
        'B',
      );
      final storedProfile = await service.loadProfileSettings();
      expect(storedProfile.hourFormat, '24h');
      expect(storedProfile.displayName, 'Persona sintética B');
      expect(
        service.enabled,
        isFalse,
        reason: 'old account push does not transfer to B',
      );
      expect(
        await storage.read(key: 'futbeat.push.enabled'),
        'false',
        reason: 'B must not inherit persistent push opt-in from deleted A',
      );
      final deletion = requests
          .where((r) => r.path.endsWith('futbeat-delete-account'))
          .single;
      expect(deletion.headers['Authorization'], 'Bearer synthetic-A');
      expect(
        requests.where((r) => r.path.contains('/auth/v1/token')),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path.endsWith('futbeat_register_push')),
        isEmpty,
      );
    },
  );
  for (final phase in ['queued', 'success', 'failure']) {
    test('deletion intent A cannot affect later account B ($phase)', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final service =
          PushService(
              const LiveRealtimeConfig(
                supabaseUrl: 'https://fixture.invalid',
                publicKey: 'synthetic-public',
              ),
              db,
              _Tokens(),
              dio: dio,
              pushConfigured: false,
            )
            ..session = session('A')
            ..enabled = true;
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      final queued = Completer<void>();
      final deletionCalls = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            if (request.path.endsWith('futbeat-delete-account')) {
              deletionCalls.add(request);
              if (!requestStarted.isCompleted) requestStarted.complete();
              if (phase != 'queued') await releaseResponse.future;
              if (phase == 'failure') {
                handler.reject(
                  DioException(
                    requestOptions: request,
                    response: Response(
                      requestOptions: request,
                      statusCode: 503,
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
              handler.resolve(
                Response(requestOptions: request, data: {'deleted': true}),
              );
              return;
            }
            handler.resolve(
              Response(requestOptions: request, data: <String, dynamic>{}),
            );
          },
        ),
      );
      if (phase == 'queued') service.pending = queued.future;
      final deleting = service.deleteAccount().then(
        (_) => true,
        onError: (_) => false,
      );
      if (phase == 'queued') {
        await Future<void>.delayed(Duration.zero);
        expect(deletionCalls, isEmpty);
      } else {
        await requestStarted.future;
        expect(
          deletionCalls.single.headers['Authorization'],
          'Bearer synthetic-A',
        );
      }
      await service.signOut();
      await service.signOutCleanup;
      service.session = session('B');
      await service.storage.write(
        key: 'futbeat.push.session',
        value: jsonEncode(session('B')),
      );
      await service.saveProfileSettings(
        const UserProfileSettings(
          displayName: 'Persona sintética B',
          hourFormat: '24h',
        ),
      );
      expect(service.enabled, isFalse);
      if (phase == 'queued') {
        queued.complete();
      } else {
        releaseResponse.complete();
      }
      expect(
        await deleting,
        isFalse,
        reason: 'stale intent is not a successful deletion of current account',
      );
      expect(service.userId, 'B');
      expect(
        service.enabled,
        isFalse,
        reason: 'A failure must not enable push for B',
      );
      expect((await service.loadProfileSettings()).hourFormat, '24h');
      expect(
        jsonDecode(
          (await service.storage.read(key: 'futbeat.push.session'))!,
        )['user']['id'],
        'B',
      );
      if (phase == 'queued') expect(deletionCalls, isEmpty);
    });
  }
}

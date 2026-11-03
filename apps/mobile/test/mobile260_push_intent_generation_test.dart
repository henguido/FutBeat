import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

Map<String, dynamic> _session(String id) => {
  'access_token': 'synthetic-$id',
  'refresh_token': 'synthetic-refresh-$id',
  'user': {'id': id},
};

class _Tokens implements PushTokenSource {
  _Tokens({this.holdRequest = false, this.value = 'synthetic-device-A'});
  final bool holdRequest;
  final String value;
  final requested = Completer<void>();
  final release = Completer<String?>();
  final controller = StreamController<String>.broadcast();
  @override
  Future<String?> currentToken() async => value;
  @override
  Future<String?> requestToken() async {
    if (!requested.isCompleted) requested.complete();
    return holdRequest ? release.future : value;
  }

  @override
  Stream<String> get rotations => controller.stream;
}

class _HeldInstallation extends FlutterSecureStorage {
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = await super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (key == 'futbeat.push.installation' && !captured.isCompleted) {
      captured.complete();
      await release.future;
    }
    return value;
  }
}

class _Service extends PushService {
  _Service(AppDatabase db, Dio dio, _Tokens tokens, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        db,
        tokens,
        dio: dio,
        pushConfigured: true,
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

class _Harness {
  _Harness(this.db, this.dio, this.tokens, this.storage)
    : service = _Service(db, dio, tokens, storage) {
    service.session = _session('A');
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests.add(request);
          if (request.path.endsWith('futbeat_register_push') &&
              request.headers['Authorization'] == 'Bearer synthetic-A' &&
              (request.data as Map)['p_enabled'] == true &&
              holdRegistration) {
            registrationStarted.complete();
            await releaseRegistration.future;
          }
          Object data = <String, dynamic>{};
          if (request.path.contains('/auth/v1/token')) {
            data = _session('B');
          } else if (request.path.endsWith('futbeat_read_user_profile')) {
            data = {'preferences': <String, dynamic>{}, 'follows': <Object>[]};
          }
          // Every request is resolved here: no real HTTP adapter can run.
          handler.resolve(Response(requestOptions: request, data: data));
        },
      ),
    );
  }
  final AppDatabase db;
  final Dio dio;
  final _Tokens tokens;
  final FlutterSecureStorage storage;
  final _Service service;
  final requests = <RequestOptions>[];
  bool holdRegistration = false;
  final registrationStarted = Completer<void>();
  final releaseRegistration = Completer<void>();
  Iterable<RequestOptions> get enabledRegistrations => requests.where(
    (request) =>
        request.path.endsWith('futbeat_register_push') &&
        (request.data as Map)['p_enabled'] == true,
  );
  Future<void> signInB() =>
      service.signIn('b@fixture.invalid', 'synthetic-password');
  Future<void> close() async {
    if (!tokens.release.isCompleted) tokens.release.complete(null);
    if (!releaseRegistration.isCompleted) releaseRegistration.complete();
    if (storage case final _HeldInstallation held) {
      if (!held.release.isCompleted) held.release.complete();
    }
    service.dispose();
    await tokens.controller.close();
    await db.close();
  }
}

_Harness _open({
  bool holdToken = false,
  String token = 'synthetic-device-A',
  FlutterSecureStorage storage = const FlutterSecureStorage(),
}) {
  FlutterSecureStorage.setMockInitialValues({
    'futbeat.push.enabled': 'false',
    'futbeat.push.installation': 'synthetic-installation',
  });
  final harness = _Harness(
    AppDatabase(NativeDatabase.memory()),
    Dio(),
    _Tokens(holdRequest: holdToken, value: token),
    storage,
  );
  addTearDown(harness.close);
  return harness;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'late permission/token A cannot enable or register real account B',
    () async {
      final h = _open(holdToken: true);
      final enabling = h.service.enable().then(
        (_) => true,
        onError: (_) => false,
      );
      await h.tokens.requested.future.timeout(const Duration(seconds: 5));
      await h.signInB();
      expect(h.service.userId, 'B');
      h.tokens.release.complete('synthetic-device-A');
      await enabling;
      await h.service.pending;
      expect(
        h.enabledRegistrations,
        isEmpty,
        reason: 'old permission request cannot register a token for B',
      );
      expect(h.service.enabled, isFalse);
      expect(await h.storage.read(key: 'futbeat.push.enabled'), 'false');
      expect(h.tokens.controller.hasListener, isFalse);
    },
  );

  test(
    'late registration acknowledgement A cannot enable real account B',
    () async {
      final h = _open()..holdRegistration = true;
      final enabling = h.service.enable().then(
        (_) => true,
        onError: (_) => false,
      );
      await h.registrationStarted.future.timeout(const Duration(seconds: 5));
      expect(
        h.enabledRegistrations.single.headers['Authorization'],
        'Bearer synthetic-A',
      );
      await h.signInB();
      h.releaseRegistration.complete();
      await enabling;
      await h.service.pending;
      expect(h.service.userId, 'B');
      expect(h.service.enabled, isFalse);
      expect(await h.storage.read(key: 'futbeat.push.enabled'), 'false');
      expect(h.tokens.controller.hasListener, isFalse);
    },
  );

  test('disable supersedes pending permission on the same account', () async {
    final h = _open(holdToken: true);
    final enabling = h.service.enable().then(
      (_) => true,
      onError: (_) => false,
    );
    await h.tokens.requested.future.timeout(const Duration(seconds: 5));
    await h.service.disable();
    expect(await h.storage.read(key: 'futbeat.push.enabled'), 'false');
    h.tokens.release.complete('synthetic-device-A');
    await enabling;
    await h.service.pending;
    expect(h.service.userId, 'A');
    expect(
      h.enabledRegistrations,
      isEmpty,
      reason: 'late token cannot reverse an explicit newer disable',
    );
    expect(h.service.enabled, isFalse);
    expect(await h.storage.read(key: 'futbeat.push.enabled'), 'false');
    expect(h.tokens.controller.hasListener, isFalse);
  });

  test('installation read cannot combine headers A with an explicitly enabled token B', () async {
    final storage = _HeldInstallation();
    final h = _open(token: 'synthetic-device-B', storage: storage);
    h.service.token = 'synthetic-device-A';
    final registeringA = h.service
        .register(true)
        .then((_) => true, onError: (_) => false);
    await storage.captured.future.timeout(const Duration(seconds: 5));
    await h.signInB();
    // B explicitly opts in here; its own registration is allowed.
    await h.service.enable();
    expect(h.service.userId, 'B');
    expect(h.service.token, 'synthetic-device-B');
    storage.release.complete();
    await registeringA;
    await h.service.pending;
    final crossed = h.enabledRegistrations.where(
      (request) =>
          request.headers['Authorization'] == 'Bearer synthetic-A' &&
          (request.data as Map)['p_token'] == 'synthetic-device-B',
    );
    expect(
      crossed,
      isEmpty,
      reason: 'token and auth must belong to the same captured intent',
    );
    expect(
      h.enabledRegistrations.where(
        (request) =>
            request.headers['Authorization'] == 'Bearer synthetic-B' &&
            (request.data as Map)['p_token'] == 'synthetic-device-B',
      ),
      hasLength(1),
    );
    expect(
      h.service.enabled,
      isTrue,
      reason: 'only explicit B opt-in remains active',
    );
  });
}

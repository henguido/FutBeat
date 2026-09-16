import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'live_realtime.dart';
import 'providers.dart';

abstract interface class PushTokenSource {
  Future<String?> requestToken();
  Stream<String> get rotations;
}

class FirebasePushTokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: String.fromEnvironment('FUTBEAT_FIREBASE_API_KEY'),
          appId: String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID'),
          messagingSenderId: String.fromEnvironment(
            'FUTBEAT_FIREBASE_SENDER_ID',
          ),
          projectId: String.fromEnvironment('FUTBEAT_FIREBASE_PROJECT_ID'),
        ),
      );
    }
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (![
      AuthorizationStatus.authorized,
      AuthorizationStatus.provisional,
    ].contains(permission.authorizationStatus)) {
      return null;
    }
    if (Platform.isIOS &&
        await FirebaseMessaging.instance.getAPNSToken() == null) {
      return null;
    }
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<String> get rotations => FirebaseMessaging.instance.onTokenRefresh;
}

class PushService {
  PushService(this.config, this.database, this.tokens, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );
  final LiveRealtimeConfig config;
  final AppDatabase database;
  final PushTokenSource tokens;
  final Dio dio;
  final storage = const FlutterSecureStorage();
  Map<String, dynamic>? session;
  String? token;
  StreamSubscription<String>? rotation;
  StreamSubscription<Set<String>>? follows;
  Timer? renewal;
  bool enabled = false;
  bool disposed = false;
  Future<void> pending = Future.value();
  static const configured =
      bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') &&
      String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID') != '';
  bool get authenticated => session?['access_token'] != null;
  Options get authHeaders => Options(
    headers: {
      'apikey': config.publicKey,
      'Authorization': 'Bearer ${session?['access_token']}',
    },
  );
  Future<void> signIn(String email, String password) async {
    final result = await dio.post<Map<String, dynamic>>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=password',
      data: {'email': email.trim(), 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    session = result.data;
    await storage.write(
      key: 'futbeat.push.session',
      value: jsonEncode(session),
    );
  }

  Future<void> signUp(String email, String password) async {
    await dio.post(
      '${config.supabaseUrl}/auth/v1/signup',
      data: {'email': email.trim(), 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  Future<void> restore() async {
    if (!configured) return;
    try {
      final saved = await storage.read(key: 'futbeat.push.session');
      if (saved == null || disposed) return;
      session = jsonDecode(saved) as Map<String, dynamic>;
      await refreshSession();
      if (await storage.read(key: 'futbeat.push.enabled') == 'true') {
        await enable();
      }
    } catch (_) {
      enabled = false;
    }
  }

  Future<void> refreshSession() async {
    if (!authenticated) return;
    final result = await dio.post<Map<String, dynamic>>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=refresh_token',
      data: {'refresh_token': session!['refresh_token']},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    session = result.data;
    await storage.write(
      key: 'futbeat.push.session',
      value: jsonEncode(session),
    );
  }

  Future<String> installation() async {
    final old = await storage.read(key: 'futbeat.push.installation');
    if (old != null) return old;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    await storage.write(key: 'futbeat.push.installation', value: id);
    return id;
  }

  Future<void> register(bool active) async {
    if (!authenticated || token == null) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_register_push',
      options: authHeaders,
      data: {
        'p_installation': await installation(),
        'p_platform': Platform.isIOS ? 'ios' : 'android',
        'p_transport': 'fcm',
        'p_token': token,
        'p_enabled': active,
      },
    );
  }

  Future<void> syncFollows(Set<String> values) async {
    if (!enabled || !authenticated || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_push_follows',
      options: authHeaders,
      data: {
        'p_follows': values
            .where((v) => v.startsWith('team:') || v.startsWith('match:'))
            .map(
              (v) => {
                'type': v.split(':').first,
                'id': v.substring(v.indexOf(':') + 1),
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enable() async {
    if (!configured || !authenticated) {
      throw StateError('Push requires configuration and sign-in');
    }
    token = await tokens.requestToken();
    if (token == null) {
      throw StateError('Notification permission or device token unavailable');
    }
    await register(true);
    enabled = true;
    await syncFollows(await database.watchFollows().first);
    await storage.write(key: 'futbeat.push.enabled', value: 'true');
    await rotation?.cancel();
    await follows?.cancel();
    renewal?.cancel();
    rotation = tokens.rotations.listen((value) {
      pending = pending
          .catchError((_) {})
          .then((_) async {
            if (disposed || !enabled) return;
            token = value;
            await register(true);
          })
          .catchError((_) {});
    });
    follows = database.watchFollows().listen((values) {
      pending = pending
          .catchError((_) {})
          .then((_) => syncFollows(values))
          .catchError((_) {});
    });
    renewal = Timer.periodic(const Duration(minutes: 10), (_) {
      pending = pending
          .catchError((_) {})
          .then((_) async {
            if (disposed || !enabled) return;
            await refreshSession();
            await register(true);
            await syncFollows(await database.watchFollows().first);
          })
          .catchError((_) {});
    });
  }

  Future<void> disable() async {
    await pending;
    await register(false);
    enabled = false;
    renewal?.cancel();
    await rotation?.cancel();
    await follows?.cancel();
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
  }

  Future<void> signOut() async {
    await disable();
    if (authenticated) {
      await dio.post(
        '${config.supabaseUrl}/auth/v1/logout',
        options: authHeaders,
      );
    }
    session = null;
    await storage.delete(key: 'futbeat.push.session');
  }

  void dispose() {
    disposed = true;
    renewal?.cancel();
    unawaited(rotation?.cancel());
    unawaited(follows?.cancel());
    dio.close(force: true);
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(
    ref.watch(liveRealtimeConfigProvider),
    ref.watch(databaseProvider),
    FirebasePushTokens(),
  );
  ref.onDispose(service.dispose);
  unawaited(service.restore());
  return service;
});

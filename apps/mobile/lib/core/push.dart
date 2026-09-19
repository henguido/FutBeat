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

class UserProfileSettings {
  const UserProfileSettings({
    this.displayName,
    this.languageCode = 'es',
    this.timezone = 'device',
    this.hourFormat = 'system',
    this.notifyKickoff = true,
    this.notifyGoals = true,
    this.notifyFinal = true,
    this.notifyCards = true,
    this.notifyLineups = true,
    this.notifyNews = true,
    this.notifyTransfers = true,
  });

  final String? displayName;
  final String languageCode;
  final String timezone;
  final String hourFormat;
  final bool notifyKickoff;
  final bool notifyGoals;
  final bool notifyFinal;
  final bool notifyCards;
  final bool notifyLineups;
  final bool notifyNews;
  final bool notifyTransfers;

  factory UserProfileSettings.fromJson(Map<String, dynamic> json) =>
      UserProfileSettings(
        displayName: _cleanOptional(json['displayName']),
        languageCode: _clean(json['languageCode'], 'es'),
        timezone: _clean(json['timezone'], 'device'),
        hourFormat: _hourFormat(json['hourFormat']),
        notifyKickoff: _bool(json['notifyKickoff'], true),
        notifyGoals: _bool(json['notifyGoals'], true),
        notifyFinal: _bool(json['notifyFinal'], true),
        notifyCards: _bool(json['notifyCards'], true),
        notifyLineups: _bool(json['notifyLineups'], true),
        notifyNews: _bool(json['notifyNews'], true),
        notifyTransfers: _bool(json['notifyTransfers'], true),
      );

  static String _clean(dynamic value, String fallback) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }

  static String? _cleanOptional(dynamic value) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? null : result;
  }

  static bool _bool(dynamic value, bool fallback) =>
      value is bool ? value : fallback;

  static String _hourFormat(dynamic value) {
    final format = value?.toString().trim() ?? '';
    return const {'system', '12h', '24h'}.contains(format) ? format : 'system';
  }

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'languageCode': languageCode,
    'timezone': timezone,
    'hourFormat': hourFormat,
    'notifyKickoff': notifyKickoff,
    'notifyGoals': notifyGoals,
    'notifyFinal': notifyFinal,
    'notifyCards': notifyCards,
    'notifyLineups': notifyLineups,
    'notifyNews': notifyNews,
    'notifyTransfers': notifyTransfers,
  };

  UserProfileSettings copyWith({
    String? displayName,
    bool clearDisplayName = false,
    String? languageCode,
    String? timezone,
    String? hourFormat,
    bool? notifyKickoff,
    bool? notifyGoals,
    bool? notifyFinal,
    bool? notifyCards,
    bool? notifyLineups,
    bool? notifyNews,
    bool? notifyTransfers,
  }) => UserProfileSettings(
    displayName: clearDisplayName ? null : (displayName ?? this.displayName),
    languageCode: languageCode ?? this.languageCode,
    timezone: timezone ?? this.timezone,
    hourFormat: hourFormat ?? this.hourFormat,
    notifyKickoff: notifyKickoff ?? this.notifyKickoff,
    notifyGoals: notifyGoals ?? this.notifyGoals,
    notifyFinal: notifyFinal ?? this.notifyFinal,
    notifyCards: notifyCards ?? this.notifyCards,
    notifyLineups: notifyLineups ?? this.notifyLineups,
    notifyNews: notifyNews ?? this.notifyNews,
    notifyTransfers: notifyTransfers ?? this.notifyTransfers,
  );
}

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
  Future<void>? _restoreFuture;

  static const configured =
      bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') &&
      String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID') != '';

  bool get accountConfigured => config.isConfigured;
  bool get authenticated => session?['access_token'] != null;

  String? get email {
    final user = session?['user'];
    if (user is Map) {
      final value = user['email']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  Options get authHeaders => Options(
    headers: {
      'apikey': config.publicKey,
      'Authorization': 'Bearer ${session?['access_token']}',
    },
  );

  Future<void> signIn(String email, String password) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final result = await dio.post<Map<String, dynamic>>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=password',
      data: {'email': email.trim(), 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    session = result.data;
    await _persistSession();
    await _reconcileAccount();
    await _startAccountSync();
  }

  Future<void> signUp(String email, String password) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    await dio.post(
      '${config.supabaseUrl}/auth/v1/signup',
      data: {'email': email.trim(), 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    if (!accountConfigured || disposed) return;
    try {
      final saved = await storage.read(key: 'futbeat.push.session');
      if (saved == null || disposed) return;
      session = jsonDecode(saved) as Map<String, dynamic>;
      await refreshSession();
      await _reconcileAccount();
      await _startAccountSync();
      if (configured &&
          await storage.read(key: 'futbeat.push.enabled') == 'true') {
        await enable();
      }
    } catch (_) {
      session = null;
      enabled = false;
    }
  }

  Future<void> _persistSession() =>
      storage.write(key: 'futbeat.push.session', value: jsonEncode(session));

  Future<void> refreshSession() async {
    if (!authenticated || disposed) return;
    final refreshToken = session?['refresh_token']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) return;
    final result = await dio.post<Map<String, dynamic>>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=refresh_token',
      data: {'refresh_token': refreshToken},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    session = result.data;
    await _persistSession();
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
    if (!authenticated || token == null || disposed) return;
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
    if (!authenticated || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_push_follows',
      options: authHeaders,
      data: {
        'p_follows': values
            .where(
              (v) =>
                  v.startsWith('team:') ||
                  v.startsWith('player:') ||
                  v.startsWith('competition:') ||
                  v.startsWith('match:'),
            )
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

  Future<void> syncCountries(String? detected, String? selected) async {
    if (!authenticated || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_preferences',
      options: authHeaders,
      data: {'p_detected': detected, 'p_selected': selected},
    );
  }

  Future<void> touchInterest(String type, String id) async {
    if (!authenticated || disposed) return;
    try {
      await dio.post(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_touch_temporary_interest',
        options: authHeaders,
        data: {'p_type': type, 'p_id': id, 'p_ttl_minutes': 30},
      );
    } catch (_) {
      // Local temporary interest remains valid while offline or signed out.
    }
  }

  Future<UserProfileSettings> loadProfileSettings() async {
    try {
      final raw = await storage.read(key: 'futbeat.profile.settings');
      if (raw == null) return const UserProfileSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const UserProfileSettings();
      return UserProfileSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const UserProfileSettings();
    }
  }

  Future<void> saveProfileSettings(UserProfileSettings settings) async {
    await _writeLocalProfile(settings, dirty: true);
    if (authenticated) {
      await _syncProfileSettings(settings);
    }
  }

  Future<void> _writeLocalProfile(
    UserProfileSettings settings, {
    required bool dirty,
  }) async {
    await storage.write(
      key: 'futbeat.profile.settings',
      value: jsonEncode(settings.toJson()),
    );
    await storage.write(
      key: 'futbeat.profile.dirty',
      value: dirty ? 'true' : 'false',
    );
  }

  Future<void> _syncProfileSettings(UserProfileSettings settings) async {
    if (!authenticated || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_profile_v2',
      options: authHeaders,
      data: {
        'p_display_name': settings.displayName,
        'p_language_code': settings.languageCode,
        'p_timezone': settings.timezone,
        'p_hour_format': settings.hourFormat,
        'p_notify_kickoff': settings.notifyKickoff,
        'p_notify_goals': settings.notifyGoals,
        'p_notify_final': settings.notifyFinal,
        'p_notify_cards': settings.notifyCards,
        'p_notify_lineups': settings.notifyLineups,
        'p_notify_news': settings.notifyNews,
        'p_notify_transfers': settings.notifyTransfers,
      },
    );
    await storage.write(key: 'futbeat.profile.dirty', value: 'false');
  }

  Future<Map<String, dynamic>> _readCloudProfile() async {
    final response = await dio.post<dynamic>(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_read_user_profile',
      options: authHeaders,
      data: const <String, dynamic>{},
    );
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Future<void> _reconcileAccount() async {
    if (!authenticated || disposed) return;

    final cloud = await _readCloudProfile();
    final cloudPreferences = cloud['preferences'];
    final dirty = await storage.read(key: 'futbeat.profile.dirty') == 'true';
    final localProfile = await loadProfileSettings();

    if (!dirty && cloudPreferences is Map) {
      await _writeLocalProfile(
        UserProfileSettings.fromJson(
          Map<String, dynamic>.from(cloudPreferences),
        ),
        dirty: false,
      );
    } else {
      await _syncProfileSettings(localProfile);
    }

    if (cloudPreferences is Map) {
      final values = Map<String, dynamic>.from(cloudPreferences);
      final current = await database.watchPreference().first;
      final cloudDetected = values['detectedCountry']?.toString();
      final cloudSelected = values['selectedCountry']?.toString();
      final detected = current.detectedCountry ?? cloudDetected;
      final selected = current.selectedCountry ?? cloudSelected;
      if (detected != current.detectedCountry ||
          selected != current.selectedCountry) {
        await database.savePreference(
          detectedCountry: detected,
          selectedCountry: selected,
          bootstrapDismissed: current.bootstrapDismissed,
        );
      }
      final effective = await database.watchPreference().first;
      await syncCountries(effective.detectedCountry, effective.selectedCountry);
    }

    final local = await database.watchFollows().first;
    final cloudFollows = <String>{};
    final followsJson = cloud['follows'];
    if (followsJson is List) {
      for (final item in followsJson) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        final id = item['id']?.toString();
        if (type == null || id == null || type.isEmpty || id.isEmpty) {
          continue;
        }
        cloudFollows.add('$type:$id');
      }
    }

    for (final value in cloudFollows.difference(local)) {
      final separator = value.indexOf(':');
      if (separator <= 0 || separator == value.length - 1) continue;
      await database.toggle(
        value.substring(0, separator),
        value.substring(separator + 1),
      );
    }
    await syncFollows(await database.watchFollows().first);
  }

  Future<void> _startAccountSync() async {
    if (!authenticated || disposed) return;
    await follows?.cancel();
    renewal?.cancel();

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
            if (disposed || !authenticated) return;
            await refreshSession();
            await syncFollows(await database.watchFollows().first);
            if (await storage.read(key: 'futbeat.profile.dirty') == 'true') {
              await _syncProfileSettings(await loadProfileSettings());
            }
            if (enabled) await register(true);
          })
          .catchError((_) {});
    });
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

    await _startAccountSync();
  }

  Future<void> disable() async {
    await pending;
    await register(false);
    enabled = false;
    await rotation?.cancel();
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
  }

  Future<void> signOut() async {
    await disable();
    await follows?.cancel();
    renewal?.cancel();
    if (authenticated) {
      await dio.post(
        '${config.supabaseUrl}/auth/v1/logout',
        options: authHeaders,
      );
    }
    session = null;
    token = null;
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

final profileSettingsProvider = FutureProvider<UserProfileSettings>((
  ref,
) async {
  final service = ref.watch(pushServiceProvider);
  await service.restore();
  return service.loadProfileSettings();
});

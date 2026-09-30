import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_errors.dart';
import 'database.dart';
import 'live_realtime.dart';
import 'providers.dart';

String? reconcileSelectedCountry({
  required String? local,
  required String? cloud,
  required bool dirty,
}) => dirty ? local : cloud;

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
  String? pendingConfirmationEmail;
  String? token;
  StreamSubscription<String>? rotation;
  StreamSubscription<Set<String>>? follows;
  Timer? renewal;
  bool enabled = false;
  bool disposed = false;
  Future<void> pending = Future.value();
  Future<void> countryPending = Future.value();
  Future<void>? _restoreFuture;

  /// User id whose server follows were merged into Drift in this session.
  /// Follows are never pushed (a full replace) before this matches [userId],
  /// so an unmerged local set can never wipe the server copy.
  String? _linkedUser;

  static String linkedFlagKey(String userId) =>
      'futbeat.account.linked.$userId';

  static const configured =
      bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') &&
      String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID') != '';

  bool get accountConfigured => config.isConfigured;
  bool get authenticated => session?['access_token'] != null;

  String? get userId {
    final user = session?['user'];
    if (user is! Map) return null;
    final value = user['id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool get _followsLinked => authenticated && _linkedUser == (userId ?? '');

  String? get email {
    final user = session?['user'];
    if (user is Map) {
      final value = user['email']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool? get emailVerified {
    final user = session?['user'];
    if (user is! Map) return null;
    final hasConfirmationClaim =
        user.containsKey('email_confirmed_at') ||
        user.containsKey('confirmed_at');
    if (!hasConfirmationClaim) return null;
    final value = user['email_confirmed_at'] ?? user['confirmed_at'];
    if (value == null) return false;
    return value.toString().trim().isNotEmpty;
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
    await _startSession(result.data);
  }

  /// Stores a fresh GoTrue session and starts account sync. A failed first
  /// reconcile (offline) is retried by the renewal tick; the session stays.
  Future<void> _startSession(Map<String, dynamic>? value) async {
    session = value;
    _linkedUser = null;
    pendingConfirmationEmail = null;
    await storage.delete(key: 'futbeat.auth.pendingConfirmationEmail');
    await _persistSession();
    try {
      await _reconcileAccount();
    } catch (_) {
      // Follows stay unpushed until a later reconcile merges the server set.
    }
    await _startAccountSync();
  }

  Future<void> signUp(String email, String password) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final normalized = email.trim();
    final response = await dio.post<dynamic>(
      '${config.supabaseUrl}/auth/v1/signup',
      data: {'email': normalized, 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    final data = response.data;
    // With "Confirm email" disabled GoTrue returns a full session.
    if (data is Map && data['access_token'] != null) {
      await _startSession(Map<String, dynamic>.from(data));
      return;
    }
    pendingConfirmationEmail = normalized;
    await storage.write(
      key: 'futbeat.auth.pendingConfirmationEmail',
      value: normalized,
    );
  }

  Future<void> resendEmailConfirmation() async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final currentEmail = authenticated ? email : pendingConfirmationEmail;
    if (currentEmail == null || (authenticated && emailVerified != false)) {
      throw StateError('Email confirmation is not pending');
    }
    await dio.post(
      '${config.supabaseUrl}/auth/v1/resend',
      data: {'type': 'signup', 'email': currentEmail},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    if (!accountConfigured || disposed) return;
    String? saved;
    try {
      pendingConfirmationEmail = await storage.read(
        key: 'futbeat.auth.pendingConfirmationEmail',
      );
      saved = await storage.read(key: 'futbeat.push.session');
    } catch (_) {
      return;
    }
    if (saved == null || disposed) return;
    try {
      final decoded = jsonDecode(saved);
      session = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      session = null;
    }
    if (!authenticated) {
      await _clearLocalSession();
      return;
    }
    try {
      await refreshSession();
    } catch (error) {
      if (isAuthRejection(error)) {
        await _clearLocalSession();
        return;
      }
      // Offline/timeout/5xx: keep the stored session; the renewal tick or
      // the next app resume retries the refresh.
    }
    if (disposed || !authenticated) return;
    try {
      await _reconcileAccount();
    } catch (_) {
      // Retried by the renewal tick before any follows are pushed.
    }
    await _startAccountSync();
    try {
      if (configured &&
          await storage.read(key: 'futbeat.push.enabled') == 'true') {
        await enable();
      }
    } catch (_) {
      enabled = false;
    }
  }

  /// Drops the local session and account timers. Never touches Drift, so
  /// guest follows and preferences survive sign-out.
  Future<void> _clearLocalSession() async {
    await follows?.cancel();
    await rotation?.cancel();
    renewal?.cancel();
    follows = null;
    rotation = null;
    renewal = null;
    session = null;
    token = null;
    enabled = false;
    _linkedUser = null;
    await storage.delete(key: 'futbeat.push.session');
  }

  /// Retries refresh/reconcile after the app returns to the foreground.
  Future<void> resume() {
    if (disposed || !authenticated) return Future.value();
    final operation = pending
        .catchError((_) {})
        .then((_) => _accountTick())
        .catchError((_) {});
    pending = operation;
    return operation;
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

  /// Pushes [values] as a full replace of the server follows. Skipped until
  /// the server set has been merged into Drift for the current user.
  Future<void> syncFollows(Set<String> values) async {
    if (!authenticated || disposed || !_followsLinked) return;
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

  Future<void> syncCountries(
    String? detected,
    String? selected, {
    bool updateDetected = true,
    bool updateSelected = true,
  }) {
    if (!authenticated || disposed) return Future.value();
    final sessionToken = session?['access_token']?.toString();
    final operation = countryPending.catchError((_) {}).then((_) async {
      if (updateDetected) await markDetectedCountryDirty();
      if (updateSelected) await markSelectedCountryDirty();
      if (disposed || session?['access_token']?.toString() != sessionToken) {
        return;
      }
      await dio.post(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_preference_fields',
        options: authHeaders,
        data: {
          'p_detected': detected,
          'p_selected': selected,
          'p_update_detected': updateDetected,
          'p_update_selected': updateSelected,
        },
      );
      final current = await database.watchPreference().first;
      if (!disposed &&
          session?['access_token']?.toString() == sessionToken &&
          current.detectedCountry == detected &&
          current.selectedCountry == selected) {
        if (updateDetected) {
          await storage.write(
            key: 'futbeat.country.detected.dirty',
            value: 'false',
          );
        }
        if (updateSelected) {
          await storage.write(
            key: 'futbeat.country.selected.dirty',
            value: 'false',
          );
        }
        final detectedDirty =
            await storage.read(key: 'futbeat.country.detected.dirty') == 'true';
        final selectedDirty =
            await storage.read(key: 'futbeat.country.selected.dirty') == 'true';
        if (!detectedDirty && !selectedDirty) {
          await storage.write(key: 'futbeat.country.dirty', value: 'false');
        }
      }
    });
    countryPending = operation;
    return operation;
  }

  Future<void> markDetectedCountryDirty() async {
    await storage.write(key: 'futbeat.country.detected.dirty', value: 'true');
    await storage.write(key: 'futbeat.country.dirty', value: 'true');
  }

  Future<void> markSelectedCountryDirty() async {
    await storage.write(key: 'futbeat.country.selected.dirty', value: 'true');
    await storage.write(key: 'futbeat.country.dirty', value: 'true');
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
      final legacyCountryDirty =
          await storage.read(key: 'futbeat.country.dirty') == 'true';
      var detectedDirty =
          await storage.read(key: 'futbeat.country.detected.dirty') == 'true';
      var selectedDirty =
          await storage.read(key: 'futbeat.country.selected.dirty') == 'true';
      if (legacyCountryDirty && !detectedDirty && !selectedDirty) {
        detectedDirty = true;
        selectedDirty = true;
      }
      final cloudDetected = values['detectedCountry']?.toString();
      final cloudSelected = values['selectedCountry']?.toString();
      final detected = reconcileSelectedCountry(
        local: current.detectedCountry,
        cloud: cloudDetected,
        dirty: detectedDirty,
      );
      final selected = reconcileSelectedCountry(
        local: current.selectedCountry,
        cloud: cloudSelected,
        dirty: selectedDirty,
      );
      if (detected != current.detectedCountry ||
          selected != current.selectedCountry) {
        if (detected != current.detectedCountry) {
          await database.saveDetectedCountry(detected);
        }
        if (selected != current.selectedCountry) {
          await database.saveSelectedCountry(selected);
        }
      }
      if (detectedDirty || selectedDirty) {
        final effective = await database.watchPreference().first;
        await syncCountries(
          effective.detectedCountry,
          effective.selectedCountry,
          updateDetected: detectedDirty,
          updateSelected: selectedDirty,
        );
      }
    }

    final uid = userId;
    final flagKey = uid == null ? null : linkedFlagKey(uid);
    final alreadyLinked =
        flagKey != null && await storage.read(key: flagKey) == 'true';
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

    // First link of this user on this device: union server + local, so an
    // empty (or different) guest set never deletes server follows. After
    // that, local Drift is the source of truth and pushes replace the
    // server set. An empty local set with server follows (fresh install
    // with a restored keychain session) is always treated as a first link.
    final firstLink =
        !alreadyLinked || (local.isEmpty && cloudFollows.isNotEmpty);
    if (firstLink) {
      await database.addFollows(cloudFollows.difference(local));
    }
    _linkedUser = uid ?? '';
    await syncFollows(await database.watchFollows().first);
    if (flagKey != null && firstLink) {
      await storage.write(key: flagKey, value: 'true');
    }
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
          .then((_) => _accountTick())
          .catchError((_) {});
    });
  }

  Future<void> _accountTick() async {
    if (disposed || !authenticated) return;
    try {
      await refreshSession();
    } catch (error) {
      if (isAuthRejection(error)) {
        await _clearLocalSession();
        return;
      }
      rethrow;
    }
    if (!_followsLinked) {
      // The first reconcile failed (offline); merge before any push.
      await _reconcileAccount();
      if (enabled) await register(true);
      return;
    }
    await syncFollows(await database.watchFollows().first);
    if (await storage.read(key: 'futbeat.profile.dirty') == 'true') {
      await _syncProfileSettings(await loadProfileSettings());
    }
    final detectedDirty =
        await storage.read(key: 'futbeat.country.detected.dirty') == 'true';
    final selectedDirty =
        await storage.read(key: 'futbeat.country.selected.dirty') == 'true';
    final legacyDirty =
        await storage.read(key: 'futbeat.country.dirty') == 'true';
    if (detectedDirty || selectedDirty || legacyDirty) {
      final preference = await database.watchPreference().first;
      await syncCountries(
        preference.detectedCountry,
        preference.selectedCountry,
        updateDetected:
            detectedDirty || (legacyDirty && !detectedDirty && !selectedDirty),
        updateSelected:
            selectedDirty || (legacyDirty && !detectedDirty && !selectedDirty),
      );
    }
    if (enabled) await register(true);
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

  /// Always ends the local session, even offline. The server logout is best
  /// effort; Drift follows/preferences stay so the guest keeps them.
  Future<void> signOut() async {
    final headers = authenticated ? authHeaders : null;
    try {
      await disable();
    } catch (_) {
      // Offline: the device row may stay enabled server-side; local
      // sign-out must never depend on the network.
    }
    await _clearLocalSession();
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
    if (headers == null) return;
    try {
      await dio.post('${config.supabaseUrl}/auth/v1/logout', options: headers);
    } catch (_) {
      // The refresh token expires server-side; the local session is gone.
    }
  }

  Future<void> deleteAccount() async {
    if (!accountConfigured || !authenticated) {
      throw StateError('Authentication required');
    }
    final wasEnabled = enabled;
    await rotation?.cancel();
    await follows?.cancel();
    renewal?.cancel();
    rotation = null;
    follows = null;
    renewal = null;
    await pending.catchError((_) {});
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '${config.supabaseUrl}/functions/v1/futbeat-delete-account',
        options: authHeaders,
      );
      if (response.data?['deleted'] != true) {
        throw StateError('Account deletion was not confirmed');
      }
    } catch (_) {
      if (authenticated && !disposed) {
        await _startAccountSync();
        if (wasEnabled) {
          enabled = true;
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
        }
      }
      rethrow;
    }

    final deletedUser = userId;
    enabled = false;
    token = null;
    session = null;
    _linkedUser = null;
    pending = Future.value();
    countryPending = Future.value();
    await storage.delete(key: 'futbeat.push.session');
    if (deletedUser != null) {
      await storage.delete(key: linkedFlagKey(deletedUser));
    }
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
    await _writeLocalProfile(const UserProfileSettings(), dirty: false);
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

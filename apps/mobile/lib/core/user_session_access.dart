part of 'push.dart';

const _publicPreferenceOwnerKey = 'futbeat.public.accountPreferenceOwner';

class _GuestTransfer {
  _GuestTransfer(this.attempt, this.localFollows, this.ticket);
  final int attempt;
  final Set<String> localFollows;
  final String? ticket;
}

/// Production access is part of the existing session service. It shares its
/// secure storage, HTTP client, refresh single-flight and generation guards.
extension UserSessionAccess on PushService {
  void _normalizeUserExpiry(Map<String, dynamic> value) {
    if (value['expires_at'] != null) return;
    final raw = value['expires_in'];
    final seconds = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (seconds != null && seconds > 0) {
      value['expires_at'] =
          clock().add(Duration(seconds: seconds)).millisecondsSinceEpoch ~/
          1000;
    }
  }

  bool _expiredRefresh(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode ?? 0;
    final body = error.response?.data;
    if (status < 400 || status >= 500 || body is! Map) return false;
    return const {
      'refresh_token_not_found',
      'refresh_token_already_used',
    }.contains(body['error_code'] ?? body['code']);
  }

  Future<void> ensureUserSession() async {
    if (!userSessionAccess || disposed || !accountConfigured) return;
    await restore();
    if (disposed ||
        _restoreStorageRetryNeeded ||
        _localSignOutPending != null) {
      return;
    }
    if (authenticated) {
      if (_publicSessionNeedsPersistence) await _persistSession();
      if (_expiresSoon(clock())) {
        try {
          await refreshSession();
        } catch (error) {
          if (!_expiredRefresh(error)) rethrow;
          await _invalidatePublicIdentity();
        }
      }
      if (authenticated) return;
    }
    if (_interactiveAuth.isNotEmpty) return;
    final active = _anonymousBootstrap;
    if (active != null) return active;
    if (_anonymousRetryAfter?.isAfter(clock()) == true) return;
    final generation = _generation;
    final attempt = _authenticationAttempt;
    late final Future<void> operation;
    operation = _createAnonymous(generation, attempt).whenComplete(() {
      if (identical(_anonymousBootstrap, operation)) _anonymousBootstrap = null;
    });
    _anonymousBootstrap = operation;
    return operation;
  }

  Future<void> _createAnonymous(int generation, int attempt) async {
    _anonymousRetryAfter = clock().add(const Duration(seconds: 30));
    try {
      final response = await dio.post<dynamic>(
        '${config.supabaseUrl}/auth/v1/signup',
        data: const <String, dynamic>{},
        options: Options(headers: {'apikey': config.publicKey}),
      );
      if (_stale(generation) ||
          _authenticationStale(attempt) ||
          authenticated) {
        return;
      }
      final next = PushService._validSession(response.data);
      final user = next?['user'];
      if (next == null ||
          user is! Map ||
          user['is_anonymous'] != true ||
          user['id'] is! String ||
          (user['id'] as String).isEmpty) {
        throw StateError('Guest session unavailable');
      }
      _normalizeUserExpiry(next);
      if (await _startSession(next)) _anonymousRetryAfter = null;
    } on DioException catch (error) {
      final seconds = int.tryParse(
        error.response?.headers.value('retry-after') ?? '',
      );
      if (seconds != null && seconds > 30) {
        _anonymousRetryAfter = clock().add(Duration(seconds: seconds));
      }
      rethrow;
    }
  }

  Future<({String accessToken, String scope})?> apiSession({
    String? rejectedToken,
  }) async {
    await ensureUserSession();
    if (!authenticated || disposed || userId == null) return null;
    if (rejectedToken != null && session?['access_token'] == rejectedToken) {
      try {
        await refreshSession();
      } catch (error) {
        if (_expiredRefresh(error)) await _invalidatePublicIdentity();
        rethrow;
      }
    }
    final access = session?['access_token'];
    return access is String && access.isNotEmpty && userId != null
        ? (accessToken: access, scope: userSessionScope)
        : null;
  }

  Future<void> _invalidatePublicIdentity() async {
    final keepGuest = isAnonymous;
    final local = keepGuest
        ? await database.watchFollows().first
        : const <String>{};
    final profile = keepGuest ? await loadProfileSettings() : null;
    final country = keepGuest
        ? (await database.watchPreference().first).selectedCountry
        : null;
    await _clearLocalSession();
    final generation = _generation;
    if (authenticated || disposed || _interactiveAuth.isNotEmpty) return;
    if (keepGuest) {
      await database.addFollows(local);
      if (_stale(generation)) return;
      await _writeLocalProfile(profile!, dirty: true);
      if (_stale(generation)) return;
      await database.saveSelectedCountry(country);
    }
    _anonymousRetryAfter = null;
  }

  Future<void> _resetPublicGuestData(int generation) async {
    if (_stale(generation)) return;
    // This stays inside the existing local sign-out FIFO, before credentials
    // disappear. A new login cannot race the account data reset.
    await database.delete(database.follows).go();
    if (_stale(generation)) return;
    await database.saveSelectedCountry(null);
    if (_stale(generation)) return;
    await _writeLocalProfile(const UserProfileSettings(), dirty: false);
    if (_stale(generation)) return;
    await storage.delete(key: PushService.leftoverKey);
    await storage.delete(key: _publicPreferenceOwnerKey);
    _anonymousRetryAfter = null;
    _publicSessionNeedsPersistence = false;
  }

  Future<void> _prepareGuestTransfer(int attempt) async {
    if (!userSessionAccess || registered || _authenticationStale(attempt)) {
      return;
    }
    final local = Set<String>.of(await database.watchFollows().first);
    if (_authenticationStale(attempt)) return;
    String? ticket;
    if (isAnonymous) {
      try {
        final response = await dio.post<dynamic>(
          '${config.supabaseUrl}/rest/v1/rpc/futbeat_issue_guest_merge_ticket',
          options: authHeaders,
          data: const <String, dynamic>{},
        );
        final data = response.data;
        final candidate = data is Map ? data['ticket'] : null;
        final expiry = data is Map
            ? DateTime.tryParse('${data['expiresAt']}')
            : null;
        if (candidate is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate) &&
            expiry != null &&
            expiry.isAfter(clock())) {
          ticket = candidate;
        }
      } catch (_) {
        // Signing in is still allowed. The ordinary follows sync retains
        // local guest choices, without persisting a ticket or exposing it.
      }
    }
    if (!_authenticationStale(attempt)) {
      _guestTransfer = _GuestTransfer(attempt, local, ticket);
    }
  }

  Future<void> _redeemGuestTransfer(
    _GuestTransfer transfer,
    Map<String, dynamic> target,
  ) async {
    if (transfer.ticket == null || _authenticationStale(transfer.attempt)) {
      return;
    }
    final user = target['user'];
    if (user is! Map || user['is_anonymous'] == true || user['id'] is! String) {
      return;
    }
    try {
      await dio.post<dynamic>(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_redeem_guest_merge_ticket',
        options: Options(
          headers: {
            'apikey': config.publicKey,
            'Authorization': 'Bearer ${target['access_token']}',
          },
        ),
        data: {'p_ticket': transfer.ticket},
      );
    } catch (_) {
      // No destructive retry. Login proceeds with the local union fallback.
    }
  }

  Future<void> _linkGuestEmail(
    String emailAddress,
    String password,
    int attempt,
  ) async {
    final uid = userId;
    final response = await dio.put<dynamic>(
      '${config.supabaseUrl}/auth/v1/user',
      options: authHeaders,
      data: {'email': emailAddress, 'password': password},
    );
    if (_authenticationStale(attempt) || userId != uid) return;
    final data = response.data;
    final user = data is Map && data['user'] is Map ? data['user'] : data;
    if (user is! Map || user['id'] != uid) {
      throw StateError('Account linking was not confirmed');
    }
    session = {
      ...session!,
      'user': {
        ...Map<String, dynamic>.from(session!['user'] as Map),
        ...Map<String, dynamic>.from(user),
      },
    };
    pendingConfirmationEmail = emailAddress;
    await _persistSession();
    if (_authenticationStale(attempt)) return;
    await storage.write(
      key: 'futbeat.auth.pendingConfirmationEmail',
      value: emailAddress,
    );
  }

  Future<void> linkAnonymousIdentity(OAuthProvider provider) async {
    if (!userSessionAccess || !isAnonymous) return signInWithOAuth(provider);
    if (!buildOAuthProviders.contains(provider)) {
      throw StateError('Social sign-in is not configured');
    }
    final attempt = ++_authenticationAttempt;
    final uid = userId;
    _interactiveAuth.add(attempt);
    try {
      await _awaitSignOutCleanup();
      if (_authenticationStale(attempt) || userId != uid) return;
      final (:verifier, :challenge) = PushService._pkcePair();
      final response = await dio.get<dynamic>(
        '${config.supabaseUrl}/auth/v1/user/identities/authorize',
        options: authHeaders,
        queryParameters: {
          'provider': provider.id,
          'redirect_to': PushService.oauthRedirect,
          'code_challenge': challenge,
          'code_challenge_method': 's256',
        },
      );
      if (_authenticationStale(attempt) || userId != uid) return;
      final data = response.data;
      final raw = data is Map ? data['url'] : null;
      final url = raw is String ? Uri.tryParse(raw) : null;
      final allowedHosts = {
        Uri.parse(config.supabaseUrl).host,
        if (provider == OAuthProvider.google) 'accounts.google.com',
        if (provider == OAuthProvider.facebook) ...{
          'www.facebook.com',
          'facebook.com',
        },
      };
      if (url == null ||
          url.scheme != 'https' ||
          url.userInfo.isNotEmpty ||
          url.port != 443 ||
          !allowedHosts.contains(url.host)) {
        throw const OAuthFailed('invalid_link_url');
      }
      final callback = Uri.parse(
        await oauthBrowser(url, PushService.oauthCallbackScheme),
      );
      if (_authenticationStale(attempt) || userId != uid) return;
      if (callback.scheme != PushService.oauthCallbackScheme ||
          callback.host != 'login-callback') {
        throw const OAuthFailed('invalid_callback');
      }
      final params = PushService._redirectParams(callback);
      final error = params['error_code'] ?? params['error'];
      if (error == 'access_denied') throw const OAuthCancelled();
      if (error != null) throw OAuthFailed(error);
      final code = params['code'];
      if (code == null || code.isEmpty) throw const OAuthFailed('missing_code');
      final result = await dio.post<dynamic>(
        '${config.supabaseUrl}/auth/v1/token?grant_type=pkce',
        options: Options(headers: {'apikey': config.publicKey}),
        data: {'auth_code': code, 'code_verifier': verifier},
      );
      if (_authenticationStale(attempt) || userId != uid) return;
      final next = PushService._validSession(result.data);
      if (next == null ||
          next['user'] is! Map ||
          (next['user'] as Map)['id'] != uid) {
        throw const OAuthFailed('identity_changed');
      }
      await _startSession(next);
    } finally {
      _interactiveAuth.remove(attempt);
    }
  }
}

part of 'push.dart';

extension NotificationScopesAccess on PushService {
  String _scopePendingKey(String uid) =>
      'futbeat.notificationScopes.pending.$uid';

  /// Uses the existing session/refresh and transport. A late reply from a
  /// previous login must never become the new account's visible preferences.
  Future<NotificationScopes> _scopeRpc(
    String rpc,
    Map<String, dynamic> args,
  ) async {
    final owner = userId;
    final generation = _generation;
    if (!authenticated || owner == null || disposed) {
      throw StateError('Authentication required');
    }
    if (_expiresSoon(clock())) await refreshSession();
    if (_stale(generation) || userId != owner) {
      throw StateError('Account changed');
    }
    final response = await dio.post<dynamic>(
      '${config.supabaseUrl}/rest/v1/rpc/$rpc',
      options: authHeaders,
      data: args,
    );
    if (_stale(generation) || userId != owner) {
      throw StateError('Account changed');
    }
    return NotificationScopes.fromJson(response.data);
  }

  Future<NotificationScopes> _readNotificationScopes() async {
    final owner = userId;
    final generation = _generation;
    await flushNotificationScopes();
    if (_stale(generation) || userId != owner) {
      throw StateError('Account changed');
    }
    return _scopeRpc('futbeat_read_notification_scopes', const {});
  }

  /// Serializes edits and retries only the owning account's durable patch.
  /// No optimistic claim of server delivery, no legacy/global preference write.
  Future<NotificationScopes> _setNotificationScope(
    String scope,
    String kind,
    bool? enabled,
  ) {
    if (notificationScopeKinds[scope]?.contains(kind) != true) {
      throw ArgumentError('Unsupported notification kind');
    }
    final owner = userId;
    final generation = _generation;
    final result = Completer<NotificationScopes>();
    _scopeWrites = _scopeWrites.catchError((_) {}).then((_) async {
      try {
        if (owner == null ||
            !authenticated ||
            _stale(generation) ||
            userId != owner) {
          throw StateError('Account changed');
        }
        final key = _scopePendingKey(owner);
        final raw = await storage.read(key: storageKey(key));
        final pending = raw == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final entries = Map<String, dynamic>.from(pending[scope] as Map? ?? {});
        entries[kind] = enabled;
        pending[scope] = entries;
        if (_stale(generation) || userId != owner) {
          throw StateError('Account changed');
        }
        await storage.write(key: storageKey(key), value: jsonEncode(pending));
        if (_stale(generation) || userId != owner) {
          throw StateError('Account changed');
        }
        final value = await _scopeRpc('futbeat_set_notification_scopes', {
          'p_scopes': pending,
        });
        await storage.delete(key: storageKey(key));
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _flushNotificationScopes() {
    final owner = userId;
    final generation = _generation;
    final operation = _scopeWrites.catchError((_) {}).then((_) async {
      if (owner == null ||
          !authenticated ||
          _stale(generation) ||
          userId != owner) {
        return;
      }
      final key = _scopePendingKey(owner);
      final raw = await storage.read(key: storageKey(key));
      if (raw == null || _stale(generation) || userId != owner) return;
      await _scopeRpc('futbeat_set_notification_scopes', {
        'p_scopes': Map<String, dynamic>.from(jsonDecode(raw) as Map),
      });
      await storage.delete(key: storageKey(key));
    });
    _scopeWrites = operation.catchError((_) {});
    return operation;
  }

  Future<void> _clearNotificationScopes(String uid) {
    final operation = _scopeWrites
        .catchError((_) {})
        .then((_) => storage.delete(key: storageKey(_scopePendingKey(uid))));
    _scopeWrites = operation.catchError((_) {});
    return operation;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

/// [serverNow] is the REST response's server time (HTTP `Date`) and
/// [deviceNow] the device time it arrived; together they give every row a
/// skew-free receipt time (#120: an old LIVE row never looks fresh).
Map<String, LiveMatchUpdate> reconcileLiveBootstrapSnapshot(
  Map<String, LiveMatchUpdate> current,
  Iterable<Json> rows, {
  Set<String>? keysBeforeRequest,
  DateTime? serverNow,
  DateTime? deviceNow,
}) {
  final result = Map<String, LiveMatchUpdate>.of(current);
  final before = keysBeforeRequest ?? current.keys.toSet();
  final fetched = <String>{};
  final arrivedAt = (deviceNow ?? DateTime.now()).toUtc();

  for (final row in rows) {
    try {
      var update = LiveMatchUpdate.fromJson(
        row,
        receivedAt: LiveMatchUpdate.bootstrapReceivedAt(
          row,
          deviceNow: arrivedAt,
          serverNow: serverNow,
        ),
      );
      if (!update.matchId.startsWith('fb_')) continue;
      fetched.add(update.matchId);
      final previous = result[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision))) {
        continue;
      }
      // Same row already received live: keep its (later) local receipt.
      final previousAt = previous?.receivedAt;
      if (previous != null &&
          previous.provider == update.provider &&
          previous.revision == update.revision &&
          previousAt != null &&
          previousAt.isAfter(update.receivedAt!)) {
        update = LiveMatchUpdate.fromJson(row, receivedAt: previousAt);
      }
      result[update.matchId] = update;
    } catch (_) {
      // A malformed REST row must not erase the last valid state.
    }
  }

  result.removeWhere(
    (matchId, _) => before.contains(matchId) && !fetched.contains(matchId),
  );
  return result;
}

class LiveRealtimeConfig {
  const LiveRealtimeConfig({
    required this.supabaseUrl,
    required this.publicKey,
  });

  factory LiveRealtimeConfig.fromEnvironment() => LiveRealtimeConfig.fromValues(
    apiUrl: const String.fromEnvironment('FUTBEAT_API_URL'),
    supabaseUrl: const String.fromEnvironment('FUTBEAT_SUPABASE_URL'),
    publishableKey: const String.fromEnvironment(
      'FUTBEAT_SUPABASE_PUBLISHABLE_KEY',
    ),
    legacyPublicToken: const String.fromEnvironment('FUTBEAT_API_PUBLIC_TOKEN'),
  );

  factory LiveRealtimeConfig.fromValues({
    String apiUrl = '',
    String supabaseUrl = '',
    String publishableKey = '',
    String legacyPublicToken = '',
  }) {
    final explicit = supabaseUrl.trim();
    final derived = explicit.isNotEmpty ? explicit : _originOf(apiUrl.trim());
    return LiveRealtimeConfig(
      supabaseUrl: derived.replaceFirst(RegExp(r'/+$'), ''),
      publicKey: publishableKey.trim().isNotEmpty
          ? publishableKey.trim()
          : legacyPublicToken.trim(),
    );
  }

  final String supabaseUrl;
  final String publicKey;

  bool get isConfigured => supabaseUrl.isNotEmpty && publicKey.isNotEmpty;

  Uri get restUri =>
      Uri.parse('$supabaseUrl/rest/v1/live_match_updates')
          .replace(queryParameters: const {'select': '*'});

  Uri get websocketUri {
    final base = Uri.parse(supabaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/realtime/v1/websocket',
      queryParameters: {'apikey': publicKey, 'vsn': '1.0.0'},
    );
  }

  static String _originOf(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.authority}';
  }
}

class LiveRealtimeClient {
  LiveRealtimeClient(
    this.config,
    this.dio, {
    this.retryDelay = const Duration(seconds: 2),
    this.refreshInterval = const Duration(seconds: 60),
  });
  final LiveRealtimeConfig config;
  final Dio dio;
  final Duration retryDelay, refreshInterval;

  Stream<Map<String, LiveMatchUpdate>> watch() {
    final state = <String, LiveMatchUpdate>{};
    late StreamController<Map<String, LiveMatchUpdate>> controller;
    WebSocket? socket;
    Timer? retry, heartbeat, refresh, joinTimeout;
    var disposed = false;
    var connecting = false;
    var sequence = 0;

    void emit() {
      if (!disposed) {
        controller.add(
          Map.unmodifiable(Map<String, LiveMatchUpdate>.of(state)),
        );
      }
    }

    void accept(Json row) {
      // A realtime frame is new now: its receipt time is local.
      final update = LiveMatchUpdate.fromJson(
        row,
        receivedAt: DateTime.now().toUtc(),
      );
      if (!update.matchId.startsWith('fb_')) return;
      final previous = state[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision))) {
        return;
      }
      state[update.matchId] = update;
    }

    Future<void> bootstrap() async {
      final before = state.keys.toSet();
      try {
        final response = await dio.getUri<dynamic>(
          config.restUri,
          options: Options(headers: {'apikey': config.publicKey}),
        );
        if (disposed) return;
        final deviceNow = DateTime.now().toUtc();
        DateTime? serverNow;
        try {
          final date = response.headers.value('date');
          if (date != null) serverNow = HttpDate.parse(date);
        } catch (_) {
          serverNow = null; // Conservative fallback: row timestamps.
        }
        if (response.data is List) {
          final rows = (response.data as List)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
          final reconciled = reconcileLiveBootstrapSnapshot(
            state,
            rows,
            keysBeforeRequest: before,
            serverNow: serverNow,
            deviceNow: deviceNow,
          );
          state
            ..clear()
            ..addAll(reconciled);
        }
        emit();
      } catch (_) {
        /* Keep HTTP snapshot and the last valid overlay. */
      }
    }

    late Future<void> Function() connect;
    void reconnect() {
      heartbeat?.cancel();
      joinTimeout?.cancel();
      if (!disposed && !(retry?.isActive ?? false)) {
        retry = Timer(retryDelay, () {
          unawaited(connect());
        });
      }
    }

    connect = () async {
      if (disposed || connecting) return;
      connecting = true;
      try {
        final current = await WebSocket.connect(config.websocketUri.toString())
            .timeout(const Duration(seconds: 10));
        if (disposed) {
          await current.close();
          return;
        }
        socket = current;
        final joinRef = '${++sequence}';
        current.add(
          jsonEncode({
            'topic': 'realtime:futbeat:live_match_updates',
            'event': 'phx_join',
            'payload': {
              'config': {
                'broadcast': {'ack': false, 'self': false},
                'presence': {'enabled': false, 'key': ''},
                'postgres_changes': [
                  {
                    'event': '*',
                    'schema': 'public',
                    'table': 'live_match_updates',
                  },
                ],
                'private': false,
              },
            },
            'ref': joinRef,
            'join_ref': joinRef,
          }),
        );
        joinTimeout = Timer(const Duration(seconds: 10), () {
          unawaited(current.close());
        });
        heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
          try {
            current.add(
              jsonEncode({
                'topic': 'phoenix',
                'event': 'heartbeat',
                'payload': {},
                'ref': '${++sequence}',
              }),
            );
          } catch (_) {
            unawaited(current.close());
          }
        });
        current.listen(
          (raw) {
            try {
              if (raw is! String || disposed) return;
              final message = jsonDecode(raw) as Map;
              if (message['event'] == 'phx_reply' &&
                  message['ref'] == joinRef) {
                joinTimeout?.cancel();
                if (message['payload']?['status'] == 'ok') {
                  // Subscribe first, then refetch on EVERY reconnect to close the offline gap.
                  unawaited(bootstrap());
                } else {
                  unawaited(current.close());
                }
                return;
              }
              if (['phx_error', 'phx_close'].contains(message['event'])) {
                unawaited(current.close());
                return;
              }
              if (message['event'] != 'postgres_changes') return;
              final data = message['payload']?['data'];
              if (data is! Map) return;
              if (data['type'] == 'DELETE') {
                state.remove(data['old_record']?['match_id']);
              } else if (data['record'] is Map) {
                accept(Map<String, dynamic>.from(data['record'] as Map));
              }
              emit();
            } catch (_) {
              /* Malformed frames do not erase valid data. */
            }
          },
          onDone: reconnect,
          onError: (_) {
            unawaited(current.close());
            reconnect();
          },
        );
      } catch (_) {
        reconnect();
      } finally {
        connecting = false;
      }
    };
    controller = StreamController<Map<String, LiveMatchUpdate>>(
      onListen: () {
        if (!config.isConfigured) {
          emit();
          unawaited(controller.close());
          return;
        }
        unawaited(bootstrap());
        unawaited(connect());
        refresh = Timer.periodic(refreshInterval, (_) {
          unawaited(bootstrap());
        });
      },
      onCancel: () async {
        disposed = true;
        retry?.cancel();
        heartbeat?.cancel();
        refresh?.cancel();
        joinTimeout?.cancel();
        await socket?.close();
      },
    );
    return controller.stream;
  }
}

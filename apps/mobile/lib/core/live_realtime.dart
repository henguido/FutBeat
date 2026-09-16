import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

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
  LiveRealtimeClient(this.config, this.dio);

  final LiveRealtimeConfig config;
  final Dio dio;

  Stream<Map<String, LiveMatchUpdate>> watch() async* {
    if (!config.isConfigured) {
      yield const <String, LiveMatchUpdate>{};
      return;
    }

    final state = <String, LiveMatchUpdate>{};
    try {
      final response = await dio.getUri<dynamic>(
        config.restUri,
        options: Options(headers: {'apikey': config.publicKey}),
      );
      final rows = response.data;
      if (rows is List) {
        for (final row in rows) {
          if (row is Map) {
            final update = LiveMatchUpdate.fromJson(
              Map<String, dynamic>.from(row),
            );
            state[update.matchId] = update;
          }
        }
      }
    } catch (_) {
      // Realtime is an enhancement over the snapshot. A REST bootstrap failure
      // must never prevent the normal app data from rendering.
    }
    yield Map.unmodifiable(state);

    var retrySeconds = 1;
    var sequence = 1;
    while (true) {
      WebSocket? socket;
      Timer? heartbeat;
      try {
        socket = await WebSocket.connect(config.websocketUri.toString());
        final joinRef = '${sequence++}';
        socket.add(
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
        heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
          try {
            socket?.add(
              jsonEncode({
                'topic': 'phoenix',
                'event': 'heartbeat',
                'payload': const {},
                'ref': '${sequence++}',
              }),
            );
          } catch (_) {
            // The receive loop owns reconnects.
          }
        });

        await for (final raw in socket) {
          if (raw is! String) continue;
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final message = Map<String, dynamic>.from(decoded);
          if (message['event'] == 'phx_reply') {
            final payload = message['payload'];
            if (payload is Map && payload['status'] == 'ok') retrySeconds = 1;
            continue;
          }
          if (message['event'] != 'postgres_changes') continue;

          final payload = message['payload'];
          if (payload is! Map) continue;
          final dataValue = payload['data'];
          if (dataValue is! Map) continue;
          final data = Map<String, dynamic>.from(dataValue);
          final type = data['type'] as String?;
          final rowValue = type == 'DELETE'
              ? data['old_record']
              : data['record'];
          if (rowValue is! Map) continue;
          final row = Map<String, dynamic>.from(rowValue);
          final matchId = row['match_id'] as String?;
          if (matchId == null || matchId.isEmpty) continue;

          if (type == 'DELETE') {
            state.remove(matchId);
          } else {
            state[matchId] = LiveMatchUpdate.fromJson(row);
          }
          yield Map.unmodifiable(Map<String, LiveMatchUpdate>.of(state));
        }
      } catch (_) {
        // Network changes are normal on mobile. Keep the last known overlay and
        // reconnect without affecting the snapshot repository.
      } finally {
        heartbeat?.cancel();
        try {
          await socket?.close();
        } catch (_) {}
      }

      await Future<void>.delayed(Duration(seconds: retrySeconds));
      retrySeconds = retrySeconds >= 16 ? 30 : retrySeconds * 2;
    }
  }
}

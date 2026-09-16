import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

void main() {
  test('Realtime derives Supabase origin from the existing BFF URL', () {
    final config = LiveRealtimeConfig.fromValues(
      apiUrl: 'https://project.supabase.co/functions/v1/futbeat-api',
      legacyPublicToken: 'public-test-key',
    );

    expect(config.isConfigured, isTrue);
    expect(config.supabaseUrl, 'https://project.supabase.co');
    expect(config.restUri.path, '/rest/v1/live_match_updates');
    expect(config.websocketUri.scheme, 'wss');
    expect(config.websocketUri.path, '/realtime/v1/websocket');
    expect(config.websocketUri.queryParameters['apikey'], 'public-test-key');
  });

  test('Realtime stays disabled when no public credential is configured', () {
    final config = LiveRealtimeConfig.fromValues(
      apiUrl: 'https://project.supabase.co/functions/v1/futbeat-api',
    );
    expect(config.isConfigured, isFalse);
  });

  test('FB-US-005/012: canonical LIVE state overlays score and status', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    final snapshot = Snapshot({...raw, 'demo': false});
    final match = snapshot.matches.first;
    final originalEvents = match.events.length;

    final merged = snapshot.withLiveUpdates({
      match.id: LiveMatchUpdate(
        matchId: match.id,
        provider: 'api_football',
        externalMatchId: '123',
        status: 'LIVE',
        minute: 73,
        homeScore: 2,
        awayScore: 1,
        revision: 4,
        eventCount: originalEvents,
        changedAt: DateTime.utc(2026, 9, 16, 6),
      ),
    });

    final live = merged.match(match.id)!;
    expect(live.status, 'LIVE');
    expect(live.statusLabel, '73′ · En vivo');
    expect(live.score, '2 - 1');
    expect(live.events.length, originalEvents);
    expect(merged.stale, isFalse);
  });

  test('Provider-only fixtures can never alter an unrelated canonical match', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    final snapshot = Snapshot({...raw, 'demo': false});
    final merged = snapshot.withLiveUpdates({
      'fb_match_not_in_snapshot': LiveMatchUpdate(
        matchId: 'fb_match_not_in_snapshot',
        provider: 'api_football',
        externalMatchId: '999',
        status: 'LIVE',
        minute: 10,
        homeScore: 1,
        awayScore: 0,
        revision: 1,
        eventCount: 1,
        changedAt: DateTime.utc(2026, 9, 16, 6),
      ),
    });
    expect(identical(merged, snapshot), isTrue);
  });
}

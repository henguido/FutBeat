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

  test(
    'REST bootstrap removes overlays deleted while the client was offline',
    () {
      LiveMatchUpdate update(String id, int revision) => LiveMatchUpdate(
        matchId: id,
        provider: 'goal_api',
        externalMatchId: 'ext-$id',
        status: 'LIVE',
        minute: 30,
        homeScore: 1,
        awayScore: 0,
        revision: revision,
        eventCount: 0,
        changedAt: DateTime.utc(2026, 9, 19, 1),
      );

      final current = <String, LiveMatchUpdate>{
        'fb_match_stale': update('fb_match_stale', 1),
        'fb_match_keep': update('fb_match_keep', 1),
      };

      final reconciled = reconcileLiveBootstrapSnapshot(current, [
        {
          'match_id': 'fb_match_keep',
          'provider': 'goal_api',
          'external_match_id': 'ext-fb_match_keep',
          'status': 'LIVE',
          'minute': 35,
          'home_score': 1,
          'away_score': 0,
          'revision': 2,
          'event_count': 0,
          'latest_events': <dynamic>[],
          'changed_at': '2026-09-19T01:05:00Z',
        },
      ], keysBeforeRequest: current.keys.toSet());

      expect(reconciled.containsKey('fb_match_stale'), isFalse);
      expect(reconciled['fb_match_keep']?.revision, 2);
      expect(reconciled['fb_match_keep']?.minute, 35);
    },
  );

  test(
    'REST bootstrap preserves a newer realtime row that arrived mid-request',
    () {
      final current = <String, LiveMatchUpdate>{
        'fb_match_new': LiveMatchUpdate(
          matchId: 'fb_match_new',
          provider: 'goal_api',
          externalMatchId: 'new',
          status: 'LIVE',
          minute: 42,
          homeScore: 2,
          awayScore: 1,
          revision: 3,
          eventCount: 0,
          changedAt: DateTime.utc(2026, 9, 19, 1, 10),
        ),
      };

      final reconciled = reconcileLiveBootstrapSnapshot(
        current,
        const [],
        keysBeforeRequest: const <String>{},
      );

      expect(reconciled.containsKey('fb_match_new'), isTrue);
      expect(reconciled['fb_match_new']?.revision, 3);
    },
  );

  test('overdue scheduled match keeps its kickoff presentation', () {
    final now = costaRicaNow();
    final match = FootballMatch({
      'id': 'fb_match_overdue',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': now
          .subtract(const Duration(minutes: 30))
          .toUtc()
          .add(const Duration(hours: 6))
          .toIso8601String(),
      'status': 'SCHEDULED',
      'score': null,
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    });

    expect(match.isAwaitingUpdate, isTrue);
    expect(match.isScheduled, isTrue);
    expect(match.isUpcoming, isFalse);
    expect(match.statusLabel, 'Programado');
  });

  test(
    'Provider-only fixtures can never alter an unrelated canonical match',
    () {
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
    },
  );
}

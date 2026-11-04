import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/shared/live_freshness_notice.dart';
import 'package:futbeat/core/database.dart';

final at = DateTime.utc(2026, 10, 31, 18);
Json fixture() => {
  'id': 'fb_match_test',
  'competitionId': 'fb_comp_test',
  'homeTeamId': 'fb_team_h',
  'awayTeamId': 'fb_team_a',
  'startTime': at.subtract(const Duration(hours: 1)).toIso8601String(),
  'status': 'SCHEDULED',
  'events': <Json>[],
  'statistics': <Json>[],
};
Json row({int revision = 1, int home = 1, String status = 'LIVE'}) => {
  'match_id': 'fb_match_test',
  'provider': 'goal_api',
  'external_match_id': '123',
  'status': status,
  'minute': 61,
  'home_score': home,
  'away_score': 0,
  'revision': revision,
  'event_count': 0,
  'latest_events': <Json>[],
  'changed_at': at.toIso8601String(),
};

void main() {
  test(
    'old observation delivered now retains score but does not become fresh',
    () {
      final raw = {
        ...row(),
        'updated_at': at.add(const Duration(hours: 2)).toIso8601String(),
      };
      final now = at.add(const Duration(hours: 2));
      final update = LiveMatchUpdate.fromJson(
        raw,
        receivedAt: LiveMatchUpdate.bootstrapReceivedAt(
          raw,
          deviceNow: now,
          serverNow: now,
        ),
      );
      final shown = FootballMatch(update.applyTo(fixture(), now: now));
      expect(shown.score, '1 - 0');
      expect(shown.status, 'LIVE');
      expect(shown.liveDataStaleAt(now), isTrue);
      expect(shown.json['liveObservedAt'], at.toIso8601String());
    },
  );

  test(
    'fresh, silent, recovered correction, late revision and terminal state',
    () {
      final first = LiveMatchUpdate.fromJson(
        row(),
        receivedAt: at,
      ).applyTo(fixture());
      final match = FootballMatch(first);
      expect(match.liveDataStaleAt(at), isFalse);
      expect(
        match.liveDataStaleAt(at.add(const Duration(minutes: 16))),
        isTrue,
      );
      final recoveredAt = at.add(const Duration(minutes: 17));
      final correction = LiveMatchUpdate.fromJson({
        ...row(revision: 2, home: 0),
        'changed_at': recoveredAt.toIso8601String(),
      }, receivedAt: recoveredAt).applyTo(first);
      expect(FootballMatch(correction).score, '0 - 0');
      expect(FootballMatch(correction).liveDataStaleAt(recoveredAt), isFalse);
      expect(
        identical(
          LiveMatchUpdate.fromJson(row()).applyTo(correction),
          correction,
        ),
        isTrue,
      );
      final finalRow = LiveMatchUpdate.fromJson({
        ...row(revision: 3, home: 2, status: 'VERIFIED'),
        'changed_at': recoveredAt
            .add(const Duration(minutes: 30))
            .toIso8601String(),
      }).applyTo(correction);
      expect(FootballMatch(finalRow).isFinished, isTrue);
      expect(
        FootballMatch(finalRow)
            .liveDataStaleAt(at.add(const Duration(days: 1))),
        isFalse,
      );
      expect(
        identical(
          LiveMatchUpdate.fromJson(row(revision: 9)).applyTo(finalRow),
          finalRow,
        ),
        isTrue,
      );
    },
  );

  test('persistent payload JSON round-trip preserves observation age', () {
    final original = LiveMatchUpdate.fromJson(
      row(),
      receivedAt: at,
    ).applyTo(fixture());
    final restored = FootballMatch(jsonDecode(jsonEncode(original)) as Json);
    expect(restored.score, '1 - 0');
    expect(restored.liveDataStaleAt(at.add(const Duration(hours: 3))), isTrue);
    expect(restored.isFinished, isFalse);
  });

  test('missing observation and future timestamps are unverified; receipt is not evidence', () {
    expect(
      FootballMatch({
        ...fixture(),
        'status': 'LIVE',
        'provenance': {'receivedAt': at.toIso8601String()},
      }).liveDataStaleAt(at),
      isTrue,
    );
    final raw = {
      ...row(),
      'changed_at': at.add(const Duration(hours: 2)).toIso8601String(),
    };
    final deviceAt = LiveMatchUpdate.bootstrapReceivedAt(
      raw,
      deviceNow: at,
      serverNow: at,
    );
    expect(at.difference(deviceAt), greaterThan(LiveMatchUpdate.staleAfter));
  });

  testWidgets('expiry visible without reload; pause/resume and recovery', (
    tester,
  ) async {
    var clock = at;
    final match = FootballMatch(
      LiveMatchUpdate.fromJson(row(), receivedAt: at).applyTo(fixture()),
    );
    Widget app(FootballMatch m) => MaterialApp(
      home: Scaffold(body: LiveFreshnessNotice(m, now: () => clock)),
    );
    await tester.pumpWidget(app(match));
    expect(find.byKey(const ValueKey('live-last-known')), findsNothing);
    clock = at.add(const Duration(minutes: 16));
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const ValueKey('live-last-known')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.textContaining('Último marcador conocido'), findsOneWidget);
    final recovered = FootballMatch(
      LiveMatchUpdate.fromJson({
        ...row(revision: 2),
        'changed_at': clock.toIso8601String(),
      }, receivedAt: clock).applyTo(match.json),
    );
    await tester.pumpWidget(app(recovered));
    expect(find.byKey(const ValueKey('live-last-known')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'SQLite close/reopen keeps the observation timestamp and known score',
    () async {
      final dir = await Directory.systemTemp.createTemp('futbeat-mobile239-');
      final file = File('${dir.path}/cache.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        final payload = LiveMatchUpdate.fromJson(
          row(),
          receivedAt: at,
        ).applyTo(fixture());
        await db.saveCalendarSnapshot(
          '2026-10-31',
          jsonEncode({
            'matches': [payload],
          }),
        );
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        final restored =
            jsonDecode((await db.readCalendarSnapshot('2026-10-31'))!) as Json;
        final match = FootballMatch(
          Map<String, dynamic>.from((restored['matches'] as List).single),
        );
        expect(match.score, '1 - 0');
        expect(match.liveDataStaleAt(at.add(const Duration(hours: 1))), isTrue);
      } finally {
        await db.close();
        if (await file.exists()) await file.delete();
        await dir.delete();
      }
    },
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push_messages.dart';

void main() {
  final fixtures = jsonDecode(
    File('../../backend/test/fixtures/fcm_n1_v9_payloads.json')
        .readAsStringSync(),
  ) as List;
  for (final raw in fixtures) {
    final fixture = raw as Map;
    test('dispatcher v9 shared wire: ${fixture['name']}', () {
      final expected = fixture['parsed'] as Map;
      final message = PushMessage.fromRemote(
        RemoteMessage(data: Map<String, dynamic>.from(fixture['data'] as Map)),
      );
      expect(message.route, expected['route']);
      expect(message.personalPlayerId, expected['personalPlayerId']);
      expect(
        message.scopes,
        expected['scopes'] == null
            ? isNull
            : unorderedEquals(expected['scopes'] as List),
      );
      expect(message.scopeKinds, expected['scopeKinds']);
      expect(message.penalty, expected['penalty']);
      expect(message.playerRole, expected['playerRole']);
      expect(message.deduplicationId, fixture['row']['id']);
    });
  }
  test('FCM personal fields decode without changing match navigation', () {
    final message = PushMessage.fromRemote(
      const RemoteMessage(
        data: {
          'notificationId': 'outbox-1',
          'eventId': 'event-1',
          'matchId': 'fb_match_1',
          'playerId': 'fb_player_1',
          'scopes': '["player","team","match"]',
          'scopeKinds':
              '{"player":"penalty_goal","team":"goal_for","match":"goal"}',
          'penalty': 'true',
          'playerRole': 'primary',
        },
      ),
    );
    expect(message.scopes, {'player', 'team', 'match'});
    expect(message.scopeKinds?['player'], 'penalty_goal');
    expect(message.penalty, true);
    expect(message.playerRole, 'primary');
    expect(message.personalPlayerId, 'fb_player_1');
    expect(message.route, '/match/fb_match_1');
    expect(message.deduplicationId, 'outbox-1');
  });

  for (final scope in ['team', 'match']) {
    test(
      '$scope alert does not become personal just because it has a player',
      () {
        final message = PushMessage(
          data: {
            'matchId': 'm1',
            'playerId': 'p1',
            'scopes': '["$scope"]',
            'scopeKinds': '{"$scope":"goal"}',
            'penalty': 'false',
          },
        );
        expect(message.scopes, {scope});
        expect(message.personalPlayerId, isNull);
        expect(message.penalty, false);
        expect(message.route, '/match/m1');
      },
    );
  }

  test(
    'legacy payload retains route and never infers scope or penalty from text',
    () {
      const message = PushMessage(
        title: 'Gol de penal del jugador',
        data: {
          'notificationId': 'legacy-1',
          'matchId': 'm1',
          'playerId': 'p1',
          'type': 'GOAL',
        },
      );
      expect(message.scopes, isNull);
      expect(message.scopeKinds, isNull);
      expect(message.penalty, isNull);
      expect(message.playerRole, isNull);
      expect(message.personalPlayerId, isNull);
      expect(message.route, '/match/m1');
      expect(message.deduplicationId, 'legacy-1');
    },
  );

  test(
    'malformed optional metadata never breaks an otherwise routable push',
    () {
      for (final invalid in ['not json', 'null', '42', '{}', '["unknown"]']) {
        final message = PushMessage(
          data: {
            'matchId': 'm1',
            'scopes': invalid,
            'scopeKinds': invalid,
            'penalty': 'penal',
            'playerRole': 'scorer',
          },
        );
        expect(message.scopes, isNull);
        expect(message.personalPlayerId, isNull);
        expect(message.penalty, isNull);
        expect(message.playerRole, isNull);
        expect(message.route, '/match/m1');
      }
      expect(
        const PushMessage(data: {'scopeKinds': '{"player":true}'}).scopeKinds,
        isNull,
      );
    },
  );

  test(
    'personal metadata requires a valid player and preserves confirmed roles',
    () {
      for (final role in ['primary', 'assist', 'starter', 'bench']) {
        final message = PushMessage(
          data: {'scopes': '["player"]', 'playerRole': role},
        );
        expect(message.playerRole, role);
        expect(message.personalPlayerId, isNull);
      }
      expect(
        const PushMessage(
          data: {'scopes': '["player"]', 'playerId': 'bad\nplayer'},
        ).personalPlayerId,
        isNull,
      );
    },
  );

  test('event fallback dedupes retries but preserves cancellations and corrections', () {
    const goal = PushMessage(
      deliveryId: 'transport-1',
      data: {'eventId': 'goal-1', 'type': 'GOAL'},
    );
    const retry = PushMessage(
      deliveryId: 'transport-2',
      data: {'eventId': 'goal-1', 'type': 'GOAL', 'scopes': '["match"]'},
    );
    const annulled = PushMessage(
      data: {'eventId': 'goal-1', 'type': 'GOAL_ANNULLED'},
    );
    expect(goal.deduplicationId, retry.deduplicationId);
    expect(annulled.deduplicationId, isNot(goal.deduplicationId));
    expect(
      const PushMessage(
        data: {
          'notificationId': 'correction-2',
          'eventId': 'goal-1',
          'type': 'GOAL',
        },
      ).deduplicationId,
      'correction-2',
    );
    expect(
      const PushMessage(deliveryId: 'old-transport').deduplicationId,
      'old-transport',
    );
  });

  test('empty and native structured values remain optional metadata', () {
    const message = PushMessage(
      data: {
        'scopes': <String>[],
        'scopeKinds': <String, String>{},
        'penalty': false,
      },
    );
    expect(message.scopes, isEmpty);
    expect(message.scopeKinds, isEmpty);
    expect(message.penalty, false);
    expect(message.personalPlayerId, isNull);
  });
}

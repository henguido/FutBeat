import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// P0-A: corrections, annulled goals and deleted events reach the phone.
// Realtime replaces (never unions) a provider's events, the detail memory
// accepts a shorter answer, the timeline drops stale canonical twins, the
// header groups one player once and never lists more goals than the score.
// Everything synthetic.

const _match = 'fb_match_rc';
const _home = 'fb_team_rc_home';
const _away = 'fb_team_rc_away';

Map<String, dynamic> _snapshotJson({
  Map<String, int>? score,
  List<Map<String, dynamic>> events = const [],
  List<Map<String, dynamic>> players = const [],
  String status = 'VERIFIED',
}) {
  final now = DateTime.now().toUtc();
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': 'fb_comp_rc', 'name': 'Liga Correcciones'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Correcciones'},
      {'id': _away, 'name': 'Visita Correcciones'},
    ],
    'players': players,
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_rc',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': now.subtract(const Duration(hours: 1)).toIso8601String(),
        'status': status,
        'score': ?score,
        'events': events,
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _detailJson(List<Map<String, dynamic>> incidents) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const <dynamic>[],
  'incidents': incidents,
  'videos': const <dynamic>[],
};

Map<String, dynamic> _canonicalGoal(
  String id,
  int minute, {
  String team = _home,
  String? key,
  String? playerId,
  bool synthetic = false,
  Map<String, int>? score,
}) => {
  'id': id,
  'type': 'GOAL',
  'minute': minute,
  'teamId': team,
  'providerEventKey': ?key,
  if (key != null) 'provider': 'goal_api',
  'playerId': ?playerId,
  if (synthetic) 'synthetic': true,
  'score': ?score,
};

Map<String, dynamic> _detailGoal(
  int minute, {
  String side = 'home',
  String? key,
  String? name,
  String? playerId,
}) => {
  'type': 'GOAL',
  'minute': minute,
  'label': 'Gol',
  'side': side,
  'providerEventId': ?key,
  'playerName': ?name,
  'playerId': ?playerId,
};

List<String> _labels(List<ScorerLine> lines) =>
    lines.map((line) => line.label).toList();

class _QueueRepository implements FootballRepository {
  _QueueRepository(this.details);
  final List<MatchDetail> details;

  @override
  Future<Snapshot> load() => throw UnimplementedError();

  @override
  Future<Snapshot> loadDate(DateTime date) => throw UnimplementedError();

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => details.removeAt(0);
}

void main() {
  group('realtime replaces a provider event list', () {
    Json match(List<Json> events) =>
        Snapshot(_snapshotJson(status: 'LIVE', events: events))
            .match(_match)!
            .json;

    LiveMatchUpdate update(List<Json>? latest, {int revision = 3}) =>
        LiveMatchUpdate.fromJson({
          'match_id': _match,
          'provider': 'goal_api',
          'external_match_id': 'ext-rc',
          'status': 'LIVE',
          'minute': 30,
          'home_score': 0,
          'away_score': 0,
          'revision': revision,
          'event_count': latest?.length ?? 0,
          'changed_at': DateTime.now().toUtc().toIso8601String(),
          'latest_events': ?latest,
        }, receivedAt: DateTime.now().toUtc());

    final annulled = _canonicalGoal('fb_event_goal', 19, key: '9001');
    final card = {
      'id': 'fb_event_card',
      'type': 'YELLOW_CARD',
      'minute': 25,
      'teamId': _away,
      'providerEventKey': 'c1',
      'provider': 'goal_api',
    };
    final otherProvider = {
      'id': 'fb_event_other',
      'type': 'YELLOW_CARD',
      'minute': 12,
      'teamId': _home,
      'provider': 'api_football',
    };

    test('an event the provider no longer sends disappears (no union)', () {
      final result = update([card])
          .applyTo(match([annulled, card, otherProvider]));
      final ids = (result['events'] as List).map((e) => e['id']).toSet();
      expect(ids, {'fb_event_card', 'fb_event_other'});
      expect(result['score'], {'home': 0, 'away': 0});
    });

    test('unlabelled payload copies are kept unless re-sent or owned', () {
      final copy = {
        'id': 'fb_event_copy',
        'type': 'GOAL',
        'minute': 5,
        'teamId': _home,
      };
      final resent = {
        'id': 'fb_event_card',
        'type': 'YELLOW_CARD',
        'minute': 25,
        'teamId': _away,
      };
      final staleSynthetic = {
        'id': 'fb_event_syn',
        'type': 'GOAL',
        'minute': 40,
        'teamId': _home,
        'synthetic': true,
      };
      final result = update([card])
          .applyTo(match([copy, resent, staleSynthetic]));
      final ids = (result['events'] as List).map((e) => e['id']).toList();
      expect(ids..sort(), ['fb_event_card', 'fb_event_copy']);
      expect(
        (result['events'] as List).firstWhere(
          (e) => e['id'] == 'fb_event_card',
        )['provider'],
        'goal_api',
        reason: 'the re-sent id takes the realtime copy',
      );
    });

    test('an empty list clears that provider (annulled goal, 1 -> 0)', () {
      final result = update(const []).applyTo(match([annulled]));
      expect(result['events'], isEmpty);
    });

    test('a corrected event replaces its older copy', () {
      final corrected = {...annulled, 'minute': 25, 'playerId': 'fb_p2'};
      final result = update([corrected]).applyTo(match([annulled]));
      expect(result['events'], [corrected]);
    });

    test('an update without an event list keeps the events', () {
      final result = LiveMatchUpdate(
        matchId: _match,
        provider: 'goal_api',
        externalMatchId: 'ext-rc',
        status: 'LIVE',
        minute: 30,
        homeScore: 1,
        awayScore: 0,
        revision: 3,
        eventCount: 1,
        changedAt: DateTime.now().toUtc(),
        receivedAt: DateTime.now().toUtc(),
      ).applyTo(match([annulled]));
      expect((result['events'] as List).single['id'], 'fb_event_goal');
    });
  });

  test(
    'detail memory accepts a shorter (and an empty) incidents list',
    () async {
      final remembered = MatchDetail(
        _detailJson([
          _detailGoal(19, key: '9001', name: 'Anulado'),
          _detailGoal(40, key: '9002', name: 'Válido'),
        ]),
      );
      final shorter = MatchDetail(
        _detailJson([_detailGoal(40, key: '9002', name: 'Válido')]),
      );
      final empty = MatchDetail(_detailJson(const []));
      final repository = _QueueRepository([shorter, empty]);
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      container.read(matchDetailMemoryProvider)[_match] = remembered;

      Future<MatchDetail> open() async {
        MatchDetail? last;
        final sub = container.listen(
          matchDetailProvider(_match),
          (_, next) => last = next.asData?.value ?? last,
          fireImmediately: true,
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        sub.close();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return last!;
      }

      final first = await open();
      expect(first.incidents.map((e) => e['providerEventId']), ['9002']);
      expect(
        container
            .read(matchDetailMemoryProvider)[_match]!
            .incidents
            .map((e) => e['providerEventId']),
        ['9002'],
      );
      final second = await open();
      expect(second.incidents, isEmpty);
    },
  );

  group('merged timeline', () {
    test('one row for a detail event and its stale canonical twins', () {
      final data = Snapshot(
        _snapshotJson(
          score: {'home': 1, 'away': 0},
          events: [
            // An older observation (minute 19) and the corrected one (25)
            // of the same upstream row.
            _canonicalGoal('fb_event_old', 19, key: '9001', playerId: 'fb_p1'),
            _canonicalGoal('fb_event_new', 25, key: '9001', playerId: 'fb_p2'),
          ],
        ),
      );
      final timeline = mergedMatchTimeline(
        data.match(_match)!,
        MatchDetail(
          _detailJson([
            _detailGoal(25, key: '9001', name: 'Corregido', playerId: 'x2'),
          ]),
        ),
      );
      final goals = timeline.where((e) => e['type'] == 'GOAL').toList();
      expect(goals, hasLength(1));
      expect(goals.single['detailSource'], isTrue);
      expect(goals.single['minute'], 25);
    });

    test('without keys: pairs by side + minute + score-after only', () {
      final data = Snapshot(
        _snapshotJson(
          score: {'home': 2, 'away': 0},
          events: [
            _canonicalGoal('fb_event_a', 10, score: {'home': 1, 'away': 0}),
            _canonicalGoal('fb_event_b', 30, score: {'home': 2, 'away': 0}),
          ],
        ),
      );
      final goals = mergedMatchTimeline(
        data.match(_match)!,
        MatchDetail(_detailJson([_detailGoal(30, name: 'Segundo')])),
      ).where((e) => e['type'] == 'GOAL').toList();
      expect(goals.map((e) => [e['minute'], e['detailSource'] == true]), [
        [10, false],
        [30, true],
      ]);
    });

    test('two occurrences (:1, :2) of one content key are two goals', () {
      // Same player, same minute, no score-after: the provider listed two
      // indistinguishable rows in one answer (content keys :1 and :2).
      FootballMatch build(String secondKey) => Snapshot(
        _snapshotJson(
          score: {'home': 2, 'away': 0},
          events: [
            _canonicalGoal(
              'fb_event_k1',
              30,
              key: 'fallback:00000000000000aa:1',
              playerId: 'fb_p1',
            ),
            _canonicalGoal(
              'fb_event_k2',
              30,
              key: secondKey,
              playerId: 'fb_p1',
            ),
          ],
        ),
      ).match(_match)!;
      int goals(FootballMatch match) => mergedMatchTimeline(
        match,
        MatchDetail.empty(_match),
      ).where((e) => e['type'] == 'GOAL').length;
      expect(goals(build('fallback:00000000000000aa:2')), 2);
      // Another signature (a weak composed key) still folds as before.
      expect(goals(build('fallback:00000000000000bb:1')), 1);
    });

    test(
      'synthetic goals: folded by ordinal (any minute), capped by score',
      () {
        FootballMatch build(int homeScore) => Snapshot(
          _snapshotJson(
            score: {'home': homeScore, 'away': 0},
            events: [
              _canonicalGoal('fb_event_rich', 12, key: '9001'),
              // Provisional goal seen 20 minutes later for the same ordinal.
              _canonicalGoal(
                'fb_event_syn1',
                32,
                synthetic: true,
                score: {'home': 1, 'away': 0},
              ),
              _canonicalGoal(
                'fb_event_syn2',
                60,
                synthetic: true,
                score: {'home': 2, 'away': 0},
              ),
            ],
          ),
        ).match(_match)!;
        List<String?> goals(FootballMatch match) =>
            mergedMatchTimeline(match, MatchDetail.empty(_match))
                .where((e) => e['type'] == 'GOAL')
                .map((e) => e['id'] as String?)
                .toList();
        expect(goals(build(2)), ['fb_event_rich', 'fb_event_syn2']);
        // The second goal was annulled (score 2 -> 1): its synthetic goes.
        expect(goals(build(1)), ['fb_event_rich']);
      },
    );
  });

  group('header scorers', () {
    test('short vs full name of one player (same playerId): one line', () {
      final data = Snapshot(
        _snapshotJson(
          score: {'home': 3, 'away': 0},
          players: [
            {'id': 'fb_player_rc9', 'name': 'Lionel Ejemplo'},
          ],
          events: [
            _canonicalGoal(
              'fb_event_1',
              10,
              key: '1',
              playerId: 'fb_player_rc9',
            ),
            _canonicalGoal(
              'fb_event_2',
              30,
              key: '2',
              playerId: 'fb_player_rc9',
            ),
          ],
        ),
      );
      final summary = matchScorerSummary(
        data.match(_match)!,
        MatchDetail(
          _detailJson([
            _detailGoal(10, key: '1', name: 'L. Ejemplo', playerId: 'ext9'),
            _detailGoal(50, key: '3', name: 'L. Ejemplo', playerId: 'ext9'),
          ]),
        ),
        data,
      );
      expect(_labels(summary.home), ['Lionel Ejemplo 10′, 30′, 50′']);
      expect(summary.away, isEmpty);
    });

    test('detail rows of one provider player id: one line, one name', () {
      final data = Snapshot(_snapshotJson(score: {'home': 2, 'away': 0}));
      final summary = matchScorerSummary(
        data.match(_match)!,
        MatchDetail(
          _detailJson([
            _detailGoal(10, key: '1', name: 'L. Ejemplo', playerId: 'ext9'),
            _detailGoal(50, key: '3', name: 'Lionel Ejemplo', playerId: 'ext9'),
          ]),
        ),
        data,
      );
      expect(_labels(summary.home), ['L. Ejemplo 10′, 50′']);
    });

    test('never more scorers than the score (anonymous extras first)', () {
      final data = Snapshot(
        _snapshotJson(
          score: {'home': 1, 'away': 0},
          events: [_canonicalGoal('fb_event_anon', 70)],
        ),
      );
      final summary = matchScorerSummary(
        data.match(_match)!,
        MatchDetail(_detailJson([_detailGoal(20, key: '5', name: 'Único')])),
        data,
      );
      expect(_labels(summary.home), ['Único 20′']);
      final noScore = Snapshot(
        _snapshotJson(
          score: {'home': 0, 'away': 0},
          events: [_canonicalGoal('fb_event_x', 70, key: '7')],
        ),
      );
      expect(
        matchScorerSummary(
          noScore.match(_match)!,
          MatchDetail.empty(_match),
          noScore,
        ).home,
        isEmpty,
      );
    });
  });
}

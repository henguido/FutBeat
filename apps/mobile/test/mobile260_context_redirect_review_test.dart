import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';

void main() {
  test('match context retains its exact match ID across explicit team and competition redirects', () async {
    const matchId = 'fb_match_review260';
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          calls++;
          expect(request.queryParameters['id'], matchId);
          handler.resolve(
            Response(
              requestOptions: request,
              data: {
                'schemaVersion': 1,
                'demo': false,
                'updatedAt': '2026-11-03T12:00:00Z',
                'entityRedirects': {
                  'fb_team_old260': 'fb_team_current260',
                  'fb_comp_old260': 'fb_comp_current260',
                },
                'teams': [
                  {'id': 'fb_team_current260', 'name': 'Local'},
                  {'id': 'fb_team_away260', 'name': 'Visita'},
                ],
                'competitions': [
                  {'id': 'fb_comp_current260', 'name': 'Liga'},
                ],
                'players': [],
                'standings': [],
                'matches': [
                  {
                    'id': matchId,
                    'competitionId': 'fb_comp_old260',
                    'homeTeamId': 'fb_team_old260',
                    'awayTeamId': 'fb_team_away260',
                    'startTime': '2026-11-03T10:00:00Z',
                    'status': 'VERIFIED',
                    'score': {'home': 1, 'away': 0},
                    'events': [],
                    'statistics': [],
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final snapshot = await ApiRepository(dio).loadMatchContext(matchId);
    expect(snapshot.match(matchId), isNotNull);
    expect(snapshot.team('fb_team_old260')?.id, 'fb_team_current260');
    expect(snapshot.competition('fb_comp_old260')?.id, 'fb_comp_current260');
    expect(calls, 1);
  });
}

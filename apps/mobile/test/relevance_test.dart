import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/relevance.dart';

Entity _entity(
  String id,
  String name,
  String country, {
  String? competitionId,
  int? relevanceScore,
}) => Entity({
  'id': id,
  'name': name,
  'country': country,
  'competitionId': ?competitionId,
  'relevanceScore': ?relevanceScore,
  'aliases': <dynamic>[],
});

Snapshot _snapshot() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': [
    {
      'id': 'fb_comp_eng',
      'name': 'Premier League',
      'country': 'England',
      'relevanceScore': 930,
    },
    {
      'id': 'fb_comp_cr',
      'name': 'Liga Promerica',
      'country': 'Costa Rica',
      'relevanceScore': 660,
    },
    {
      'id': 'fb_comp_pt',
      'name': 'Primeira Liga',
      'country': 'Portugal',
      'relevanceScore': 790,
    },
  ],
  'teams': [
    {
      'id': 'fb_team_sporting_cr',
      'name': 'Sporting San José',
      'country': 'Costa Rica',
      'competitionId': 'fb_comp_cr',
    },
    {
      'id': 'fb_team_sporting_pt',
      'name': 'Sporting CP',
      'country': 'Portugal',
      'competitionId': 'fb_comp_pt',
    },
  ],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
});

void main() {
  test('canonical relevance ranks competitions without a mobile catalogue', () {
    final premier = _entity(
      'fb_comp_premier',
      'Premier League',
      'England',
      relevanceScore: 930,
    );
    final weak = _entity(
      'fb_comp_weak',
      'A Regional League',
      'England',
      relevanceScore: 100,
    );

    expect(
      competitionImportance(premier),
      greaterThan(competitionImportance(weak)),
    );
  });

  test('search uses country as a relevance signal for comparable matches', () {
    final data = _snapshot();
    final ranked = rankSearchEntities(
      data: data,
      entities: data.teams,
      type: 'team',
      query: 'Sporting',
      follows: const <String>{},
      userCountry: 'CR',
    );

    expect(ranked.first.id, 'fb_team_sporting_cr');
    expect(ranked.map((entity) => entity.id).toSet(), {
      'fb_team_sporting_cr',
      'fb_team_sporting_pt',
    });
  });

  test(
    'favorites outrank recommendations without filtering other entities',
    () {
      final data = _snapshot();
      final ranked = rankSearchEntities(
        data: data,
        entities: data.competitions,
        type: 'competition',
        query: '',
        follows: const {'competition:fb_comp_pt'},
        userCountry: 'CR',
      );

      expect(ranked.first.id, 'fb_comp_pt');
      expect(ranked.length, data.competitions.length);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/relevance.dart';

Entity _entity(
  String id,
  String name,
  String country, {
  String? competitionId,
  int? relevanceScore,
  int? domesticTier,
  String? countryCode,
  String? competitionClass,
  bool? isGlobalRelevant,
}) => Entity({
  'id': id,
  'name': name,
  'country': country,
  'competitionId': ?competitionId,
  'relevanceScore': ?relevanceScore,
  'domesticTier': ?domesticTier,
  'countryCode': ?countryCode,
  'competitionClass': ?competitionClass,
  'isGlobalRelevant': ?isGlobalRelevant,
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
      'countryCode': 'GB',
      'relevanceScore': 930,
    },
    {
      'id': 'fb_comp_cr',
      'name': 'Liga Promerica',
      'country': 'Costa Rica',
      'countryCode': 'CR',
      'relevanceScore': 660,
    },
    {
      'id': 'fb_comp_pt',
      'name': 'Primeira Liga',
      'country': 'Portugal',
      'countryCode': 'PT',
      'relevanceScore': 790,
    },
  ],
  'teams': [
    {
      'id': 'fb_team_sporting_cr',
      'name': 'Sporting San José',
      'country': 'Costa Rica',
      'countryCode': 'CR',
      'competitionId': 'fb_comp_cr',
    },
    {
      'id': 'fb_team_sporting_pt',
      'name': 'Sporting CP',
      'country': 'Portugal',
      'countryCode': 'PT',
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

  test('feed categories are explicit and relevance only orders a category', () {
    final primary = _entity(
      'primary',
      'Primary',
      'Costa Rica',
      relevanceScore: 500,
      domesticTier: 1,
      countryCode: 'CR',
    );
    final global = _entity(
      'global',
      'Global',
      'Europe',
      relevanceScore: 970,
      competitionClass: 'international_club',
      isGlobalRelevant: true,
    );
    final secondary = _entity(
      'secondary',
      'Secondary',
      'Costa Rica',
      relevanceScore: 200,
      domesticTier: 2,
      countryCode: 'CR',
    );
    expect(
      competitionFeedCategory(primary, follows: const {}, userCountry: 'CR'),
      CompetitionFeedCategory.domesticPrimary,
    );
    expect(
      competitionFeedCategory(global, follows: const {}, userCountry: 'CR'),
      CompetitionFeedCategory.globalRelevance,
    );
    expect(
      competitionFeedCategory(secondary, follows: const {}, userCountry: 'CR'),
      CompetitionFeedCategory.domesticSecondary,
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

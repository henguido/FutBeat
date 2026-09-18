import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { openDatabase } from '../storage/database.mjs';

test('global SQL resolver reuses canonical teams and fixture storage preserves canonical profile', async () => {
  const db = await openDatabase();
  try {
    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values ($1,'competition',$2),($3,'team',$4),($5,'team',$6)",
      [
        'fb_comp_cr',
        JSON.stringify({
          id: 'fb_comp_cr',
          name: 'Liga FPD',
          country: 'Costa Rica',
          season: '2026',
          media: null,
        }),
        'fb_team_lda',
        JSON.stringify({
          id: 'fb_team_lda',
          name: 'Alajuelense',
          shortName: 'LDA',
          country: 'Costa Rica',
          competitionId: 'fb_comp_cr',
          aliases: ['LD Alajuelense'],
          media: null,
        }),
        'fb_team_mar',
        JSON.stringify({
          id: 'fb_team_mar',
          name: 'Marathón',
          shortName: 'MAR',
          country: 'Honduras',
          competitionId: 'fb_comp_cr',
          aliases: [],
          media: null,
        }),
      ],
    );

    const resolved = (
      await db.query(
        "select public.futbeat_resolve_global_entity('sofascore','team','1','LD Alajuelense','Costa Rica','LDA') id",
      )
    ).rows[0].id;
    assert.equal(resolved, 'fb_team_lda');

    const cupId = (
      await db.query(
        "select public.futbeat_resolve_global_entity('sofascore','competition','4739','CONCACAF Central American Cup','North & Central America','') id",
      )
    ).rows[0].id;
    assert.match(cupId, /^fb_competition_/);

    const matchId = (
      await db.query(
        "select public.futbeat_resolve_global_match('sofascore','9001','fb_team_lda','fb_team_mar','2026-09-18T00:30:00Z') id",
      )
    ).rows[0].id;
    assert.match(matchId, /^fb_match_/);

    const previous = {
      schemaVersion: 1,
      demo: false,
      updatedAt: '2026-09-17T20:00:00Z',
      coverage: { source: 'TheSportsDB', partial: true, live: false, sources: ['TheSportsDB'] },
      competitions: [{
        id: 'fb_comp_cr',
        name: 'Liga FPD',
        country: 'Costa Rica',
        season: '2026',
        media: null,
      }],
      teams: [{
        id: 'fb_team_lda',
        name: 'Alajuelense',
        shortName: 'LDA',
        country: 'Costa Rica',
        competitionId: 'fb_comp_cr',
        aliases: ['LD Alajuelense'],
        media: null,
      }, {
        id: 'fb_team_mar',
        name: 'Marathón',
        shortName: 'MAR',
        country: 'Honduras',
        competitionId: 'fb_comp_cr',
        aliases: [],
        media: null,
      }],
      players: [],
      matches: [],
      standings: [],
      news: [],
      transfers: [],
    };

    await db.query(
      'insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values ($1,$2,$3,$4)',
      [randomUUID(), '2026-09-17T20:00:00Z', JSON.stringify({ seed: true }), JSON.stringify(previous)],
    );

    const globalSnapshot = {
      schemaVersion: 1,
      demo: false,
      updatedAt: '2026-09-17T21:00:00Z',
      coverage: { source: 'FutBeat Global', partial: true, live: false, sources: ['SofaScore'] },
      competitions: [{
        id: cupId,
        name: 'CONCACAF Central American Cup',
        country: 'North & Central America',
        season: '',
        media: null,
      }],
      teams: [{
        id: 'fb_team_lda',
        name: 'LD Alajuelense',
        shortName: 'LDA',
        country: 'Costa Rica',
        competitionId: cupId,
        aliases: [],
        media: {
          url: 'https://img.sofascore.com/api/v1/team/1/image',
          kind: 'TEAM_LOGO',
          source: 'SofaScore',
          receivedAt: '2026-09-17T21:00:00Z',
          verificationStatus: 'VERIFIED',
          rightsStatus: 'REVIEW_REQUIRED',
          usageScope: 'DEVELOPMENT_ONLY',
        },
      }, {
        id: 'fb_team_mar',
        name: 'Marathón',
        shortName: 'MAR',
        country: 'Honduras',
        competitionId: cupId,
        aliases: [],
        media: null,
      }],
      players: [],
      matches: [{
        id: matchId,
        competitionId: cupId,
        season: '',
        homeTeamId: 'fb_team_lda',
        awayTeamId: 'fb_team_mar',
        startTime: '2026-09-18T00:30:00Z',
        status: 'SCHEDULED',
        score: null,
        minute: null,
        venue: '',
        events: [],
        statistics: [],
        provenance: {
          source: 'SofaScore',
          externalId: '9001',
          receivedAt: '2026-09-17T21:00:00Z',
          verificationStatus: 'PROVISIONAL',
        },
      }],
      standings: [],
      news: [],
      transfers: [],
    };

    const stored = (
      await db.query(
        'select public.futbeat_store_global_fixture_window($1,$2,$3,$4,$5,$6) result',
        [
          randomUUID(),
          '2026-09-17T21:00:00Z',
          '2026-09-17',
          '2026-09-19',
          JSON.stringify({ provider: 'SofaScore', days: [] }),
          JSON.stringify(globalSnapshot),
        ],
      )
    ).rows[0].result;

    assert.equal(stored.duplicate, false);

    const latest = (
      await db.query(
        'select snapshot from futbeat_private.imports order by received_at desc, job_id desc limit 1',
      )
    ).rows[0].snapshot;

    const lda = latest.teams.find((team) => team.id === 'fb_team_lda');
    assert.equal(lda.name, 'Alajuelense');
    assert.equal(lda.competitionId, 'fb_comp_cr');
    assert.equal(lda.media.source, 'SofaScore');
    assert.ok(latest.matches.some((match) => match.id === matchId));
    assert.ok(latest.competitions.some((competition) => competition.id === cupId));
  } finally {
    await db.close();
  }
});

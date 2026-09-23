import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// backend/diagnostics/coverage_report.sql must run read-only and count real
// coverage correctly, so it can be trusted when pointed at production.

const REPORT = new URL('../diagnostics/coverage_report.sql', import.meta.url);
const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;

test('coverage report counts players, squads, lineups and detail in a read-only transaction', async () => {
  const db = await openDatabase();
  try {
    const seed = [
      ['fb_comp_cov', 'competition', { id: 'fb_comp_cov', name: 'Liga' }],
      ['fb_team_cov_h', 'team', { id: 'fb_team_cov_h', name: 'H' }],
      ['fb_team_cov_a', 'team', { id: 'fb_team_cov_a', name: 'A' }],
    ];
    for (const [i, status] of ['VERIFIED', 'VERIFIED', 'SCHEDULED'].entries()) {
      seed.push([`fb_match_cov_${i}`, 'match', { id: `fb_match_cov_${i}`, competitionId: 'fb_comp_cov', status,
        homeTeamId: 'fb_team_cov_h', awayTeamId: 'fb_team_cov_a', startTime: '2026-09-01T18:00:00Z', events: [], statistics: [] }]);
    }
    for (const [id, kind, payload] of seed) {
      await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
    }
    for (let i = 0; i < 3; i++) {
      await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`cov-${i}`, `fb_match_cov_${i}`]);
    }
    const stamp = '2026-08-01T00:00:00Z';
    const squad = await normalizeGoalApiSquad([
      { id: 'p1', name: 'Uno', number: 1, position: 'Goalkeeper', photo: cdn('p1') },
      { id: 'p2', name: 'Dos', number: 2 },
    ], 'fb_team_cov_h', async (kind, external, identity) => (await db.query(
      'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
    await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', ['fb_team_cov_h', 'goal_api', stamp, JSON.stringify(squad)]);
    const store = (i, payload) => db.query("select futbeat_private.store_match_detail($1,$2,'2026-09-01T20:00:00Z',$3)",
      [`fb_match_cov_${i}`, `cov-${i}`, JSON.stringify(payload)]);
    // Match 0: object lineup (p1 with photo, p2 without, p3 new) + object stats.
    await store(0, { lineups: { home: { startingLineups: [{ playerId: 'p1', lineupPlayer: 'Uno' },
      { playerId: 'p2', lineupPlayer: 'Dos' }], substitutes: [{ playerId: 'p3', lineupPlayer: 'Tres' }] } },
    statistics: { match: { fullTime: [{ type: 'Shots', home: 3, away: 1 }] } } });
    // Match 1: array lineup, no statistics. Match 2 (scheduled): detail without lineup.
    await store(1, { lineups: [{ team: 'away', type: 'starting_lineups', playerId: 'p4', lineupPlayer: 'Cuatro' }] });
    await store(2, { statistics: [] });

    const sql = await readFile(REPORT, 'utf8');
    await db.exec('begin transaction read only');
    const report = (await db.query(sql)).rows[0].coverage;
    await db.exec('rollback');

    assert.equal(report.players.canonical_players, 4);
    assert.equal(report.players.with_photo, 1);
    assert.equal(report.players.lineup_appearances_resolved, 4);
    assert.equal(report.players.lineup_appearances_unresolved, 0);
    assert.equal(report.squads.squad_members, 2);
    assert.equal(report.squads.teams_with_squad, 1);
    assert.deepEqual(report.lineups, { appearances: 4, appearances_with_canonical_player: 4, appearances_with_canonical_photo: 1 });
    assert.deepEqual(report.match_detail, {
      cached: 3, with_lineups: 2, with_statistics: 1, with_events: 0,
      lineup_shapes: { object: 1, array: 1, missing: 1 }, statistics_shapes: { object: 1, missing: 1, array: 1 },
      fetched_last_24h: report.match_detail.fetched_last_24h,
      terminal_matches: 2, terminal_with_detail: 2, terminal_with_lineups: 2, terminal_with_statistics: 1,
    });
  } finally { await db.close(); }
});

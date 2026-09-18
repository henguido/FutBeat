import test from 'node:test';
import assert from 'node:assert/strict';

import {
  collectGoalApiStandingsIdentities,
  normalizeGoalApiStandings,
} from '../providers/goal_api_standings.mjs';

const rows = [
  {
    overallLeaguePosition: '2',
    overallLeaguePlayed: '8',
    overallLeagueW: '5',
    overallLeagueD: '2',
    overallLeagueL: '1',
    overallLeagueGF: '16',
    overallLeagueGA: '7',
    overallLeaguePTS: '17',
    team: { id: 'goal-team-a', name: 'Club A' },
  },
  {
    overallLeaguePosition: '1',
    overallLeaguePlayed: '8',
    overallLeagueW: '6',
    overallLeagueD: '1',
    overallLeagueL: '1',
    overallLeagueGF: '18',
    overallLeagueGA: '5',
    overallLeaguePTS: '19',
    team: { id: 'goal-team-b', name: 'Club B' },
  },
];

test('collectGoalApiStandingsIdentities deduplicates provider teams',()=>{
  const identities=collectGoalApiStandingsIdentities([...rows,rows[0]]);
  assert.deepEqual(identities.map(x=>x.external).sort(),['goal-team-a','goal-team-b']);
});

test('normalizeGoalApiStandings emits canonical ordered table rows',async()=>{
  const mapping=new Map([
    ['goal-team-a','fb_team_a'],
    ['goal-team-b','fb_team_b'],
  ]);
  const table=await normalizeGoalApiStandings(
    rows,
    'fb_comp_cr',
    async(_kind,external)=>mapping.get(external),
    '2026-09-18T20:00:00Z',
    {season:'2026/2027'},
  );

  assert.equal(table.competitionId,'fb_comp_cr');
  assert.equal(table.season,'2026/2027');
  assert.equal(table.provisional,false);
  assert.equal(table.source,'GOAL API');
  assert.deepEqual(table.rows,[
    {
      teamId:'fb_team_b',
      played:8,
      won:6,
      drawn:1,
      lost:1,
      gf:18,
      ga:5,
      points:19,
    },
    {
      teamId:'fb_team_a',
      played:8,
      won:5,
      drawn:2,
      lost:1,
      gf:16,
      ga:7,
      points:17,
    },
  ]);
});

test('normalizeGoalApiStandings rejects malformed numeric data',async()=>{
  await assert.rejects(
    normalizeGoalApiStandings(
      [{...rows[0],overallLeaguePlayed:'x'}],
      'fb_comp_cr',
      async()=> 'fb_team_a',
      '2026-09-18T20:00:00Z',
    ),
    /played/,
  );
});

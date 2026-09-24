import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

async function seedMatchContext(db) {
  const competition = 'fb_comp_match_context';
  const home = 'fb_team_match_context_home';
  const away = 'fb_team_match_context_away';
  const third = 'fb_team_match_context_third';
  const player = 'fb_player_match_context_home';
  const match = 'fb_match_match_context';
  const receivedAt = '2026-09-19T14:00:00.000Z';

  await db.query(
    "insert into futbeat_private.entities(id,kind,payload) values($1,'competition',$2)",
    [competition, JSON.stringify({
      id: competition,
      name: 'Liga Contexto',
      country: 'Costa Rica',
    })],
  );

  for (const [id, name] of [
    [home, 'Local Contexto'],
    [away, 'Visita Contexto'],
    [third, 'Tercero Contexto'],
  ]) {
    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'team',$2)",
      [id, JSON.stringify({
        id,
        name,
        country: 'Costa Rica',
        competitionId: competition,
      })],
    );
  }

  await db.query(
    "insert into futbeat_private.entities(id,kind,payload) values($1,'player',$2)",
    [player, JSON.stringify({
      id: player,
      name: 'Jugador Contexto',
      country: 'Costa Rica',
      teamId: home,
    })],
  );
  await db.query(
    "insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at) values($1,$2,'goal_api',now())",
    [home, player],
  );

  await db.query(
    "insert into futbeat_private.entities(id,kind,payload) values($1,'match',$2)",
    [match, JSON.stringify({
      id: match,
      competitionId: competition,
      homeTeamId: home,
      awayTeamId: away,
      startTime: '2026-09-19T20:00:00.000Z',
      status: 'SCHEDULED',
      season: '2026',
      score: null,
      venue: '',
      events: [],
      statistics: [],
      provenance: {
        source: 'GOAL API',
        externalId: 'context-1',
        receivedAt,
        verificationStatus: 'PROVISIONAL',
      },
    })],
  );

  const table = {
    competitionId: competition,
    season: '2026',
    provisional: false,
    source: 'GOAL API',
    updatedAt: receivedAt,
    rows: [
      { teamId: home, played: 1, won: 1, drawn: 0, lost: 0, gf: 2, ga: 0, points: 3 },
      { teamId: away, played: 1, won: 0, drawn: 0, lost: 1, gf: 0, ga: 2, points: 0 },
      { teamId: third, played: 0, won: 0, drawn: 0, lost: 0, gf: 0, ga: 0, points: 0 },
    ],
  };
  await db.query(
    "insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at) values($1,'goal_api','context-league','2026',$2,now())",
    [competition, JSON.stringify(table)],
  );

  return { competition, home, away, third, player, match };
}

test('lightweight match context returns only the entities required by Match Center', async () => {
  const db = await openDatabase();
  try {
    const ids = await seedMatchContext(db);
    const result = (await db.query(
      'select public.futbeat_read_match_context($1) value',
      [ids.match],
    )).rows[0].value;

    assert.equal(result.schemaVersion, 1);
    assert.equal(result.demo, false);
    assert.equal(result.matches.length, 1);
    assert.equal(result.matches[0].id, ids.match);
    assert.deepEqual(
      new Set(result.teams.map((team) => team.id)),
      new Set([ids.home, ids.away, ids.third]),
    );
    assert.deepEqual(result.players.map((item) => item.id), [ids.player]);
    assert.equal(result.competitions.length, 1);
    assert.equal(result.competitions[0].id, ids.competition);
    assert.equal(result.standings.length, 1);
    assert.equal(result.standings[0].competitionId, ids.competition);

    const size = (await db.query(
      'select pg_column_size(public.futbeat_read_match_context($1))::int bytes',
      [ids.match],
    )).rows[0].bytes;
    assert.ok(size < 100_000, `match context unexpectedly large: ${size} bytes`);
  } finally {
    await db.close();
  }
});

test('unknown match context returns null', async () => {
  const db = await openDatabase();
  try {
    const result = (await db.query(
      "select public.futbeat_read_match_context('fb_match_missing') value",
    )).rows[0].value;
    assert.equal(result, null);
  } finally {
    await db.close();
  }
});

test('FutBeat API exposes match-context through the canonical RPC', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /\/futbeat-api\/v1\/match-context/);
  assert.match(source, /futbeat_read_match_context/);
  assert.match(source, /Partido no encontrado/);
});

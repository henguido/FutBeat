import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

async function seed(db) {
  const competition = 'fb_comp_light_tabs';
  const home = 'fb_team_light_saprissa';
  const away = 'fb_team_light_alajuelense';
  const match = 'fb_match_light_tabs';

  await db.query(
    "insert into futbeat_private.entities(id,kind,payload) values($1,'competition',$2)",
    [competition, JSON.stringify({
      id: competition,
      name: 'Primera Division Costa Rica',
      country: 'Costa Rica',
    })],
  );
  for (const [id, name, shortName] of [
    [home, 'Deportivo Saprissa', 'Saprissa'],
    [away, 'Liga Deportiva Alajuelense', 'LDA'],
  ]) {
    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'team',$2)",
      [id, JSON.stringify({
        id,
        name,
        shortName,
        country: 'Costa Rica',
        competitionId: competition,
        aliases: shortName === 'LDA' ? ['Alajuelense'] : [],
      })],
    );
  }
  await db.query(
    "insert into futbeat_private.entities(id,kind,payload) values($1,'match',$2)",
    [match, JSON.stringify({
      id: match,
      competitionId: competition,
      homeTeamId: home,
      awayTeamId: away,
      startTime: '2026-09-19T20:00:00.000Z',
      status: 'SCHEDULED',
      score: null,
      venue: '',
      events: [],
      statistics: [],
      provenance: {
        source: 'GOAL API',
        externalId: 'light-tabs-1',
        receivedAt: '2026-09-19T14:00:00.000Z',
      },
    })],
  );
  return { competition, home, away, match };
}

test('search catalog returns bounded matching entities without fixture catalog', async () => {
  const db = await openDatabase();
  try {
    const ids = await seed(db);
    const value = (await db.query(
      "select public.futbeat_search_catalog('saprissa','CR',50) value",
    )).rows[0].value;

    assert.equal(value.matches.length, 0);
    assert.equal(value.teams.some((item) => item.id === ids.home), true);
    assert.equal(value.teams.length <= 50, true);
    assert.equal(value.competitions.length <= 50, true);

    const bytes = (await db.query(
      "select octet_length(public.futbeat_search_catalog('saprissa','CR',50)::text)::int bytes",
    )).rows[0].bytes;
    assert.ok(bytes < 100_000, `search response unexpectedly large: ${bytes}`);
  } finally {
    await db.close();
  }
});

test('favorites read includes followed item and only match rendering context', async () => {
  const db = await openDatabase();
  try {
    const ids = await seed(db);
    const value = (await db.query(
      'select public.futbeat_read_favorites($1) value',
      [[`team:${ids.home}`, `match:${ids.match}`]],
    )).rows[0].value;

    assert.equal(value.matches.length, 1);
    assert.equal(value.matches[0].id, ids.match);
    assert.deepEqual(
      new Set(value.teams.map((item) => item.id)),
      new Set([ids.home, ids.away]),
    );
    assert.equal(value.competitions.length, 1);
    assert.equal(value.competitions[0].id, ids.competition);

    const bytes = (await db.query(
      'select octet_length(public.futbeat_read_favorites($1)::text)::int bytes',
      [[`team:${ids.home}`, `match:${ids.match}`]],
    )).rows[0].bytes;
    assert.ok(bytes < 100_000, `favorites response unexpectedly large: ${bytes}`);
  } finally {
    await db.close();
  }
});

test('FutBeat API exposes lightweight search and favorites routes', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /\/futbeat-api\/v1\/search/);
  assert.match(source, /futbeat_search_catalog/);
  assert.match(source, /\/futbeat-api\/v1\/favorites/);
  assert.match(source, /futbeat_read_favorites/);
});

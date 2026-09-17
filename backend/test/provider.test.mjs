import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase, PersistentStore } from '../storage/database.mjs';
import { fetchCostaRica } from '../providers/thesportsdb.mjs';
import { createApi } from '../api/server.mjs';

// Synthetic records matching the official API shape; never sports assertions.
const raw = () => ({
  league: { leagues: [{ idLeague: '4815', strSport: 'Soccer', strLeague: 'Liga CR', strCurrentSeason: '2026-2027' }] },
  next: { events: [{ idEvent: 'test-1', idLeague: '4815', strSport: 'Soccer', strHomeTeam: 'Equipo A', strAwayTeam: 'Equipo B', idHomeTeam: '139705', idAwayTeam: '139703', strStatus: 'NS', strSeason: '2026-2027', strTimestamp: '2026-09-19T02:00:00', intHomeScore: null, intAwayScore: null }] },
  past: { events: null },
  teams: { teams: [
    { idTeam: '139705', strSport: 'Soccer', strTeam: 'Equipo A', strTeamShort: 'A' },
    { idTeam: '139703', strSport: 'Soccer', strTeam: 'Equipo B', strTeamShort: 'B' },
  ] },
  table: { table: [
    { idTeam: '139705', intPlayed: '2', intWin: '2', intDraw: '0', intLoss: '0', intGoalsFor: '4', intGoalsAgainst: '1', intPoints: '6' },
  ] },
});

test('persistent identity, atomic rollback, partial windows, durable job dedup and freshness', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'futbeat-db-'));
  let db;
  try {
    db = await openDatabase(folder);
    let store = new PersistentStore(db, () => new Date('2026-09-16T12:00:00Z'));
    await assert.rejects(store.read());
    await store.import(raw(), 'first', '2026-09-16T00:00:00Z');
    const before = await store.read();
    assert.equal(before.matches[0].startTime, '2026-09-19T02:00:00.000Z');
    assert.equal(before.matches[0].homeTeamId, 'fb_team_car');
    assert.equal(before.matches[0].score, null);
    assert.equal(before.freshness.stale, true);
    assert.equal(before.demo, false);
    assert.equal(before.teams.length, 2);
    assert.equal(before.standings[0].rows[0].points, 6);
    for (const mutate of [r => r.next.events[0].strStatus = 'UNKNOWN', r => r.next.events[0].intHomeScore = '1', r => r.next.events[0].strTimestamp = 'bad', r => r.next.events[0].idAwayTeam = '139705']) {
      const invalid = raw(); mutate(invalid);
      await assert.rejects(store.import(invalid, 'failed', '2026-09-16T01:00:00Z'));
      assert.deepEqual(await store.read(), before);
    }
    const finished = raw();
    const conflicting = raw();
    conflicting.past.events = [{ ...conflicting.next.events[0], strVenue: 'Different venue' }];
    await assert.rejects(store.import(conflicting, 'conflict', '2026-09-16T01:30:00Z'), /Conflicting/);
    assert.deepEqual(await store.read(), before);
    Object.assign(finished.next.events[0], { strStatus: 'FT', intHomeScore: '3', intAwayScore: '1' });
    await store.import(finished, 'second', '2026-09-16T02:00:00Z');
    assert.equal((await store.read()).matches[0].id, before.matches[0].id);
    assert.equal((await store.read()).matches[0].status, 'FINISHED_PENDING_VERIFICATION');
    const partial = raw(); partial.next.events = null;
    await store.import(partial, 'third', '2026-09-16T03:00:00Z');
    assert.equal((await store.read()).matches.length, 1);
    await assert.rejects(store.import(raw(), 'old', '2026-09-15T00:00:00Z'));
    await db.close(); db = await openDatabase(folder); store = new PersistentStore(db);
    assert.equal((await store.import({}, 'first')).duplicate, true);
    assert.equal((await store.read()).matches[0].id, before.matches[0].id);
    await db.exec('create role futbeat_test_reader; set role futbeat_test_reader;');
    await assert.rejects(db.query('select * from futbeat_private.imports'));
    await db.exec('reset role');
  } finally { if (db) await db.close(); await rm(folder, { recursive: true, force: true }); }
});

test('provider HTTP failure stops batch without retries; only official endpoints', async () => {
  const urls = [];
  await assert.rejects(fetchCostaRica({ fetcher: async url => { urls.push(url); return { ok: false, status: 429 }; } }), /429/);
    assert.equal(urls.length, 1);
  assert.match(urls[0], /^https:\/\/www.thesportsdb.com\/api\/v1\/json\/123\//);
});

test('country snapshot RPC accepts its UUID job id against the text import ledger', async () => {
  const db = await openDatabase();
  const jobId = '714320e8-4050-4d1c-be14-160e7070fe44';
  const snapshot = {
    schemaVersion: 1, demo: false, competitions: [], teams: [], matches: [], standings: [],
  };
  try {
    await db.query(
      'insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values($1,$2,$3,$4)',
      [jobId, '2026-09-16T02:36:22.347Z', JSON.stringify({}), JSON.stringify(snapshot)],
    );
    const result = await db.query(
      'select public.futbeat_store_country_snapshot($1::uuid,$2::timestamptz,$3::jsonb,$4::jsonb) result',
      [jobId, '2026-09-16T02:36:22.347Z', JSON.stringify({}), JSON.stringify(snapshot)],
    );
    assert.deepEqual(result.rows[0].result, { duplicate: true });
  } finally { await db.close(); }
});

test('real BFF returns 503 until data exists and serves persisted snapshot', async t => {
  const db = await openDatabase();
  const store = new PersistentStore(db);
  const server = createApi(store);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await db.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(`${url}/v1/snapshot`)).status, 503);
  await store.import(raw(), 'http');
  const snapshot = await (await fetch(`${url}/v1/snapshot`)).json();
  assert.equal(snapshot.demo, false);
  assert.equal(snapshot.matches.length, 1);
  assert.equal((await (await fetch(`${url}/health`)).json()).mode, 'provider');
});

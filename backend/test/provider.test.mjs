import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase, PersistentStore } from '../storage/database.mjs';
import { fetchCostaRica, normalize } from '../providers/thesportsdb.mjs';
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

const endpointName = (url) => url.includes('lookupleague') ? 'league'
  : url.includes('eventsnext') ? 'next' : url.includes('eventspast') ? 'past'
    : url.includes('lookup_all_teams') ? 'teams' : 'table';
const providerBodies = () => {
  const value = raw();
  return { league: value.league, next: value.next, past: value.past, teams: value.teams, table: value.table };
};
const timeout = () => Object.assign(new Error('provider took too long'), { name: 'TimeoutError' });
function providerFetcher(overrides = {}, calls = []) {
  const bodies = providerBodies();
  return async (url) => {
    const name = endpointName(url); calls.push(name);
    const override = overrides[name];
    if (override instanceof Error) throw override;
    if (typeof override === 'number') return new Response('{}', { status: override });
    return Response.json(override ?? bodies[name]);
  };
}
const resolver = async (kind, external) => `fb_${kind}_${external}`;

test('five provider endpoints succeed; league precedes four parallel requests with diagnostics', async () => {
  const calls = []; let active = 0; let maxActive = 0;
  const baseFetcher = providerFetcher({}, calls);
  const fetched = await fetchCostaRica({ fetcher: async (url, options) => {
    if (endpointName(url) !== 'league') {
      active++; maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5)); active--;
    }
    return baseFetcher(url, options);
  } });
  assert.deepEqual(calls.slice(0, 1), ['league']);
  assert.deepEqual(new Set(calls.slice(1)), new Set(['next', 'past', 'teams', 'table']));
  assert.equal(calls.length, 5); assert.equal(maxActive, 4);
  for (const [name, diagnostic] of Object.entries(fetched._fetch.endpoints)) {
    assert.equal(diagnostic.name, name); assert.equal(diagnostic.status, 'available');
    assert.equal(diagnostic.httpStatus, 200); assert.ok(diagnostic.durationMs >= 0);
    assert.match(diagnostic.endpoint, /\.php/); assert.equal(typeof diagnostic.itemCount, 'number');
  }
});

for (const name of ['table', 'next', 'past']) test(`timeout in ${name} is degraded without retry`, async () => {
  const calls = [];
  const fetched = await fetchCostaRica({ fetcher: providerFetcher({ [name]: timeout() }, calls) });
  assert.equal(fetched[name], undefined); assert.equal(fetched._fetch.endpoints[name].error, 'timeout');
  assert.equal(fetched._fetch.endpoints[name].status, 'temporarily_unavailable');
  assert.equal(calls.filter((entry) => entry === name).length, 1); assert.equal(calls.length, 5);
  const snapshot = await normalize(fetched, resolver, '2026-09-17T04:00:00Z');
  assert.equal(snapshot.demo, false); assert.equal(snapshot.coverage.partial, true);
  const key = { table: 'standings', next: 'upcomingFixtures', past: 'pastResults' }[name];
  assert.equal(snapshot.coverage.capabilities[key].status, 'temporarily_unavailable');
});

test('successful null table is available with zero rows and no invented standings', async () => {
  const fetched = await fetchCostaRica({ fetcher: providerFetcher({ table: { table: null } }) });
  const snapshot = await normalize(fetched, resolver, '2026-09-17T04:00:00Z');
  assert.equal(fetched._fetch.endpoints.table.status, 'available');
  assert.equal(fetched._fetch.endpoints.table.itemCount, 0);
  assert.deepEqual(snapshot.standings, []);
});

for (const name of ['teams', 'league']) test(`${name} failure rejects the country fetch`, async () => {
  const calls = [];
  await assert.rejects(
    fetchCostaRica({ fetcher: providerFetcher({ [name]: 503 }, calls) }),
    (error) => error.diagnostics[name].httpStatus === 503 && error.message.includes(name),
  );
  assert.equal(calls.filter((entry) => entry === name).length, 1);
  assert.equal(calls.length, name === 'league' ? 1 : 5);
});

test('next and past degrade independently while valid real data is retained', async () => {
  const fetched = await fetchCostaRica({ fetcher: providerFetcher({ next: timeout() }) });
  fetched.past = { events: [{ ...raw().next.events[0], strStatus: 'FT', intHomeScore: '2', intAwayScore: '1' }] };
  const snapshot = await normalize(fetched, resolver, '2026-09-17T04:00:00Z');
  assert.equal(snapshot.matches.length, 1); assert.equal(snapshot.matches[0].score.home, 2);
  assert.equal(snapshot.coverage.capabilities.upcomingFixtures.status, 'temporarily_unavailable');
  assert.equal(snapshot.coverage.capabilities.pastResults.status, 'available');
});

test('HTTP 4xx and 5xx identify the exact endpoint, status and do not retry', async () => {
  for (const [httpStatus, expected] of [[404, 'unavailable'], [503, 'temporarily_unavailable']]) {
    const calls = [];
    const fetched = await fetchCostaRica({ fetcher: providerFetcher({ table: httpStatus }, calls) });
    assert.equal(fetched._fetch.endpoints.table.httpStatus, httpStatus);
    assert.equal(fetched._fetch.endpoints.table.status, expected);
    assert.equal(fetched._fetch.endpoints.table.error, `http_${httpStatus}`);
    assert.equal(calls.filter((entry) => entry === 'table').length, 1);
  }
});

test('malformed successful optional response is rejected rather than hidden as unavailable', async () => {
  const fetched = await fetchCostaRica({ fetcher: providerFetcher({ next: { wrong: [] } }) });
  await assert.rejects(normalize(fetched, resolver, '2026-09-17T04:00:00Z'), /Invalid events response/);
  const malformedTable = await fetchCostaRica({ fetcher: providerFetcher({ table: { wrong: [] } }) });
  await assert.rejects(normalize(malformedTable, resolver, '2026-09-17T04:00:00Z'), /Invalid table response/);
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

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase, PersistentStore } from '../storage/database.mjs';

const MATCH = 'fb_match_writer';
const DATE = '2026-08-20';
const KICKOFF = '2026-08-20T18:00:00Z';
const FINISHED = 'FINISHED_PENDING_VERIFICATION';
const competition = { id: 'fb_comp_writer', name: 'Competition', country: 'Costa Rica' };
const teams = [
  { id: 'fb_team_writer_home', name: 'Home', country: 'Costa Rica' },
  { id: 'fb_team_writer_away', name: 'Away', country: 'Costa Rica' },
];

// Every remaining SQL writer that replaces existing match payloads.
const writers = {
  country: { source: 'GOAL API', sql: 'select futbeat_private.futbeat_store_country_snapshot($1,$2,$3,$4)', window: false },
  fixture: { source: 'API-Football', sql: 'select futbeat_private.futbeat_store_fixture_window($1,$2,$5,$5,$3,$4)', window: true },
  global: { source: 'ESPN', sql: 'select futbeat_private.futbeat_store_global_fixture_window($1,$2,$5,$5,$3,$4)', window: true },
};

const match = (source, { status, start = KICKOFF, receivedAt, score = null }) => ({
  id: MATCH, competitionId: competition.id, homeTeamId: teams[0].id, awayTeamId: teams[1].id,
  startTime: start, status, score, minute: null, venue: 'Stadium', events: [], statistics: [],
  provenance: { source, receivedAt, verificationStatus: 'PROVISIONAL' },
});

async function seed(db, source, stored) {
  const rows = [
    { ...competition, kind: 'competition' },
    ...teams.map((team) => ({ ...team, kind: 'team' })),
    { ...match(source, stored), kind: 'match' },
  ];
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select item->>'id',item->>'kind',item-'kind' from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
}

let clock = Date.parse('2026-08-21T00:00:00Z');
async function write(db, name, incoming) {
  const writer = writers[name];
  const snapshot = { schemaVersion: 1, demo: false, updatedAt: incoming.receivedAt,
    competitions: [competition], teams, matches: [match(writer.source, incoming)], players: [], standings: [] };
  const params = [randomUUID(), new Date(clock += 60e3).toISOString(), '{}', JSON.stringify(snapshot)];
  if (writer.window) params.push(incoming.start?.slice(0, 10) ?? DATE);
  await db.query(writer.sql, params);
}

const stored = async (db) => (await db.query(
  "select payload from futbeat_private.entities where id=$1 and kind='match'", [MATCH])).rows[0].payload;

async function both(db, date = DATE) {
  const calendar = (await db.query(
    "select public.futbeat_read_calendar_range($1::date,$1::date,'UTC') v", [date])).rows[0].v;
  const context = (await db.query('select public.futbeat_read_match_context($1) v', [MATCH])).rows[0].v;
  const fromCalendar = calendar.matches.find((m) => m.id === MATCH);
  assert.equal(fromCalendar.status, context.matches[0].status);
  assert.deepEqual(fromCalendar.score ?? null, context.matches[0].score ?? null);
  return context.matches[0];
}

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    for (const table of ['provider_call_ledger', 'results_date_attempts']) {
      assert.equal((await db.query(`select count(*)::int n from futbeat_private.${table}`)).rows[0].n, 0, table);
    }
  } finally { await db.close(); }
}

const FINAL = { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 2, away: 1 } };

for (const name of Object.keys(writers)) {
  const source = writers[name].source;

  test(`${name}: a pre-match re-ingest of the same fixture keeps the final`, () => withDb(async (db) => {
    await seed(db, source, FINAL);
    for (const status of ['SCHEDULED', 'PRE_MATCH', 'DISCOVERED']) {
      await write(db, name, { status, receivedAt: '2026-08-21T09:00:00Z' });
      const payload = await stored(db);
      assert.equal(payload.status, 'VERIFIED', status);
      assert.deepEqual(payload.score, { home: 2, away: 1 });
      assert.equal(payload.provenance.receivedAt, FINAL.receivedAt);
    }
    const shown = await both(db);
    assert.equal(shown.status, 'VERIFIED');
    assert.deepEqual(shown.score, { home: 2, away: 1 });
  }));

  test(`${name}: FINISHED_PENDING is kept and re-ingest is idempotent`, () => withDb(async (db) => {
    await seed(db, source, { ...FINAL, status: FINISHED });
    await write(db, name, { status: 'PRE_MATCH', receivedAt: '2026-08-21T09:00:00Z' });
    const revision = async () => (await db.query(
      'select revision from futbeat_private.calendar_cache_versions where utc_date=$1', [DATE])).rows[0]?.revision ?? 0;
    const before = { payload: await stored(db), revision: await revision() };
    await write(db, name, { status: 'PRE_MATCH', receivedAt: '2026-08-21T09:00:00Z' });
    assert.deepEqual(await stored(db), before.payload);
    assert.equal(before.payload.status, FINISHED);
    assert.equal(await revision(), before.revision);
    assert.equal((await both(db)).status, FINISHED);
  }));

  test(`${name}: an old final is not kept after a later reschedule`, () => withDb(async (db) => {
    await seed(db, source, FINAL);
    const start = '2026-08-27T18:00:00Z';
    await write(db, name, { status: 'SCHEDULED', start, receivedAt: '2026-08-22T09:00:00Z' });
    const payload = await stored(db);
    assert.equal(payload.status, 'SCHEDULED');
    assert.equal(payload.score, null);
    assert.equal(payload.startTime, start);
    assert.equal((await both(db, '2026-08-27')).status, 'SCHEDULED');
  }));

  test(`${name}: LIVE, interrupted and new terminal entries keep their semantics`, () => withDb(async (db) => {
    await seed(db, source, { status: 'SCHEDULED', receivedAt: '2026-08-20T12:00:00Z' });
    await write(db, name, { ...FINAL, score: { home: 0, away: 1 } });
    assert.equal((await stored(db)).status, 'VERIFIED');
    for (const status of ['SUSPENDED', 'CANCELLED', 'LIVE']) {
      await write(db, name, { status, receivedAt: '2026-08-21T09:00:00Z', score: status === 'LIVE' ? { home: 1, away: 1 } : null });
      assert.equal((await stored(db)).status, status);
    }
    // A stored interruption is not degraded to pre-match nor turned into a final.
    await write(db, name, { status: 'ABANDONED', receivedAt: '2026-08-21T10:00:00Z' });
    await write(db, name, { status: 'SCHEDULED', receivedAt: '2026-08-21T11:00:00Z' });
    assert.equal((await stored(db)).status, 'ABANDONED');
    assert.equal((await both(db)).status, 'ABANDONED');
  }));
}

// Local development import (TheSportsDB) shares the same SQL rule.
const raw = (event) => ({
  league: { leagues: [{ idLeague: '4815', strSport: 'Soccer', strLeague: 'Costa-Rica Liga FPD', strCountry: 'Costa Rica', strCurrentSeason: '2026-2027' }] },
  next: { events: [{ idEvent: 'writer-1', idLeague: '4815', strSport: 'Soccer', strHomeTeam: 'Equipo A', strAwayTeam: 'Equipo B',
    idHomeTeam: '139705', idAwayTeam: '139703', strStatus: 'NS', strSeason: '2026-2027', strTimestamp: '2026-09-19T02:00:00',
    intHomeScore: null, intAwayScore: null, ...event }] },
  past: { events: null },
  teams: { teams: [
    { idTeam: '139705', idLeague: '4815', strCountry: 'Costa Rica', strSport: 'Soccer', strTeam: 'Equipo A', strTeamShort: 'A' },
    { idTeam: '139703', idLeague: '4815', strCountry: 'Costa Rica', strSport: 'Soccer', strTeam: 'Equipo B', strTeamShort: 'B' },
  ] },
  table: { table: [] },
});

test('local PersistentStore import keeps a final and honours reschedules', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'futbeat-writer-'));
  let db;
  try {
    db = await openDatabase(folder);
    const store = new PersistentStore(db, () => new Date('2026-09-20T12:00:00Z'));
    await store.import(raw({ strStatus: 'FT', intHomeScore: '3', intAwayScore: '1' }), 'final', '2026-09-19T05:00:00Z');
    await store.import(raw({}), 'stale', '2026-09-19T06:00:00Z');
    let [match] = (await store.read()).matches;
    assert.equal(match.status, FINISHED);
    assert.deepEqual(match.score, { home: 3, away: 1 });
    await store.import(raw({ strTimestamp: '2026-09-26T02:00:00' }), 'moved', '2026-09-19T07:00:00Z');
    [match] = (await store.read()).matches;
    assert.equal(match.status, 'SCHEDULED');
    assert.equal(match.score, null);
  } finally { if (db) await db.close(); await rm(folder, { recursive: true, force: true }); }
});

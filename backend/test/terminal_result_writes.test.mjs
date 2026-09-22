import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

const MATCH = 'fb_match_write';
const DATE = '2026-08-20';
const KICKOFF = '2026-08-20T18:00:00Z';
const FINISHED = 'FINISHED_PENDING_VERIFICATION';

// Exactly what backend/providers/goal_api.mjs produces for one fixture.
function fixture({ status, start = KICKOFF, receivedAt, score = null, venue = 'Stadium' }) {
  return {
    id: MATCH, competitionId: 'fb_comp_write', season: '2026',
    homeTeamId: 'fb_team_write_home', awayTeamId: 'fb_team_write_away',
    startTime: start, status, score, minute: null, venue, events: [], statistics: [],
    provenance: { source: 'GOAL API', externalId: 'write', receivedAt, verificationStatus: 'PROVISIONAL' },
  };
}

async function ingest(db, options) {
  const match = fixture(options);
  const snapshot = {
    schemaVersion: 1, demo: false, updatedAt: options.receivedAt,
    competitions: [{ id: 'fb_comp_write', name: 'Competition', country: 'Costa Rica' }],
    teams: [
      { id: 'fb_team_write_home', name: 'Home', country: 'Costa Rica' },
      { id: 'fb_team_write_away', name: 'Away', country: 'Costa Rica' },
    ],
    matches: [match], players: [], standings: [],
  };
  const date = match.startTime.slice(0, 10);
  await db.query('select public.futbeat_store_calendar_range($1,$2,$3,$4)',
    ['goal_api', options.receivedAt, JSON.stringify([{ date, count: 1 }]), JSON.stringify(snapshot)]);
}

const stored = async (db) => (await db.query(
  "select payload from futbeat_private.entities where id=$1 and kind='match'", [MATCH])).rows[0].payload;

async function setStored(db, patch) {
  await db.query("update futbeat_private.entities set payload=payload||$2::jsonb where id=$1", [MATCH, JSON.stringify(patch)]);
}

let hash = 0;
async function observation(db, status, receivedAt, score = [2, 1]) {
  await db.query(`insert into futbeat_private.provider_observations
    (provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api','write',$1,$2,$3,$4,$5,$6,'{}')`,
  [MATCH, receivedAt, status, score?.[0] ?? null, score?.[1] ?? null, (++hash).toString(16).padStart(64, '0')]);
}

const reconcile = async (db, date = DATE) => (await db.query(
  'select public.futbeat_reconcile_goal_results_local($1::date) v', [date])).rows[0].v;

// Calendar and Match Center must agree after every write.
async function both(db, date = DATE) {
  const calendar = (await db.query(
    "select public.futbeat_read_calendar_range($1::date,$1::date,'UTC') v", [date])).rows[0].v;
  const context = (await db.query('select public.futbeat_read_match_context($1) v', [MATCH])).rows[0].v;
  const fromCalendar = calendar.matches.find((m) => m.id === MATCH);
  assert.equal(fromCalendar.status, context.matches[0].status);
  assert.deepEqual(fromCalendar.score ?? null, context.matches[0].score ?? null);
  return context.matches[0];
}

// Local only: no provider reservation, ledger row or results attempt.
async function assertNoProviderWork(db) {
  for (const table of ['provider_call_ledger', 'results_date_attempts']) {
    assert.equal((await db.query(`select count(*)::int n from futbeat_private.${table}`)).rows[0].n, 0, table);
  }
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); await assertNoProviderWork(db); } finally { await db.close(); }
}

test('VERIFIED + later calendar SCHEDULED with the same kickoff stays terminal', () => withDb(async (db) => {
  await ingest(db, { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 2, away: 1 } });
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z', venue: 'New Stadium' });
  const payload = await stored(db);
  assert.equal(payload.status, 'VERIFIED');
  assert.deepEqual(payload.score, { home: 2, away: 1 });
  assert.equal(payload.provenance.receivedAt, '2026-08-20T21:00:00Z');
  assert.equal(payload.venue, 'New Stadium');
  const match = await both(db);
  assert.equal(match.status, 'VERIFIED');
  assert.deepEqual(match.score, { home: 2, away: 1 });
}));

test('FINISHED_PENDING + later PRE_MATCH stays terminal with its events', () => withDb(async (db) => {
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-20T12:00:00Z' });
  const events = [{ id: 'fb_event_goal', type: 'GOAL', minute: 20 }];
  await setStored(db, { status: FINISHED, score: { home: 1, away: 0 }, events,
    provenance: { source: 'GOAL API', receivedAt: '2026-08-20T19:58:00Z' } });
  await ingest(db, { status: 'PRE_MATCH', receivedAt: '2026-08-21T09:00:00Z' });
  const payload = await stored(db);
  assert.equal(payload.status, FINISHED);
  assert.deepEqual(payload.score, { home: 1, away: 0 });
  assert.deepEqual(payload.events.map(({ id, type, minute }) => ({ id, type, minute })), events);
  assert.equal((await both(db)).status, FINISHED);
}));

test('an old final is not kept after a later reschedule; a kickoff correction is', () => withDb(async (db) => {
  await ingest(db, { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 2, away: 1 } });
  // Correction before the stored evidence: same fixture, fresher kickoff.
  await ingest(db, { status: 'SCHEDULED', start: '2026-08-20T18:30:00Z', receivedAt: '2026-08-21T09:00:00Z' });
  let payload = await stored(db);
  assert.equal(payload.status, 'VERIFIED');
  assert.equal(payload.startTime, '2026-08-20T18:30:00Z');
  // Real reschedule: the final predates the new kickoff and is not preserved.
  await ingest(db, { status: 'SCHEDULED', start: '2026-08-27T18:00:00Z', receivedAt: '2026-08-22T09:00:00Z' });
  payload = await stored(db);
  assert.equal(payload.status, 'SCHEDULED');
  assert.equal(payload.score, null);
  assert.equal(payload.startTime, '2026-08-27T18:00:00Z');
  const match = await both(db, '2026-08-27');
  assert.equal(match.status, 'SCHEDULED');
  assert.equal(match.score ?? null, null);
}));

test('reconciliation closes with a valid final although calendar receivedAt is newer', () => withDb(async (db) => {
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-20T12:00:00Z' });
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z', [1, 1]);
  await observation(db, FINISHED, '2026-08-20T19:56:00Z', [2, 1]);
  // A lagging LIVE feed after the whistle must not hide the final.
  await observation(db, 'LIVE', '2026-08-20T20:01:00Z', [2, 1]);
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z' });
  const result = await reconcile(db);
  assert.equal(result.resultsComplete, true);
  assert.equal(result.unresolved, 0);
  const payload = await stored(db);
  assert.equal(payload.status, FINISHED);
  assert.deepEqual(payload.score, { home: 2, away: 1 });
  assert.equal(Date.parse(payload.provenance.receivedAt), Date.parse('2026-08-20T19:56:00Z'));
  assert.equal((await db.query('select state from futbeat_private.match_result_reconciliation where match_id=$1',
    [MATCH])).rows[0].state, 'resolved');
  assert.equal((await db.query("select results_complete ok from futbeat_private.calendar_coverage where provider_date=$1",
    [DATE])).rows[0].ok, true);
  assert.equal((await both(db)).status, FINISHED);
  // Once closed, a further pre-match re-ingest cannot reopen the date.
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-22T09:00:00Z' });
  assert.equal((await stored(db)).status, FINISHED);
}));

test('a new terminal calendar entry closes a scheduled match', () => withDb(async (db) => {
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-20T12:00:00Z' });
  await ingest(db, { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 0, away: 3 } });
  assert.equal((await both(db)).status, 'VERIFIED');
}));

test('terminal evidence before the current kickoff never closes; no final by time or score', () => withDb(async (db) => {
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z' });
  await observation(db, FINISHED, '2026-08-19T20:00:00Z', [9, 9]);
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z', [3, 0]);
  const result = await reconcile(db);
  assert.equal(result.resultsComplete, false);
  const payload = await stored(db);
  assert.equal(payload.status, 'SCHEDULED');
  assert.equal(payload.score, null);
  const match = await both(db);
  assert.equal(match.status, 'SCHEDULED');
  assert.deepEqual(match.score, { home: 3, away: 0 });
}));

test('a recent LIVE is not converted to a final by reconciliation', () => withDb(async (db) => {
  const start = new Date(Date.now() - 2 * 3600e3);
  const date = start.toISOString().slice(0, 10);
  await ingest(db, { status: 'LIVE', start: start.toISOString(), receivedAt: new Date().toISOString(),
    score: { home: 1, away: 0 } });
  await observation(db, FINISHED, new Date(start.getTime() + 30 * 60e3).toISOString(), [1, 0]);
  await reconcile(db, date);
  assert.equal((await stored(db)).status, 'LIVE');
  assert.equal((await both(db, date)).status, 'LIVE');
}));

for (const status of ['SUSPENDED', 'ABANDONED']) {
  test(`${status} is neither degraded by the calendar nor converted to a final`, () => withDb(async (db) => {
    await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-20T12:00:00Z' });
    await setStored(db, { status, score: { home: 1, away: 1 },
      provenance: { source: 'GOAL API', receivedAt: '2026-08-20T19:00:00Z' } });
    await observation(db, FINISHED, '2026-08-20T18:50:00Z', [1, 1]);
    await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z' });
    assert.equal((await stored(db)).status, status);
    await reconcile(db);
    assert.equal((await stored(db)).status, status);
    assert.equal((await both(db)).status, status);
  }));
}

test('an incoming interrupted state keeps its semantics over a stored final', () => withDb(async (db) => {
  await ingest(db, { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 2, away: 1 } });
  await ingest(db, { status: 'SUSPENDED', receivedAt: '2026-08-21T09:00:00Z' });
  assert.equal((await stored(db)).status, 'SUSPENDED');
}));

test('re-ingest and reconciliation are idempotent and do not invalidate caches', () => withDb(async (db) => {
  await ingest(db, { status: 'VERIFIED', receivedAt: '2026-08-20T21:00:00Z', score: { home: 2, away: 1 } });
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z' });
  await reconcile(db);
  const revision = async () => (await db.query(
    'select revision from futbeat_private.calendar_cache_versions where utc_date=$1', [DATE])).rows[0].revision;
  const before = { payload: await stored(db), revision: await revision(),
    reconciliation: (await db.query('select * from futbeat_private.match_result_reconciliation')).rows };
  // Same payload re-sent (coverage fetched_at is the only legitimate write).
  await ingest(db, { status: 'SCHEDULED', receivedAt: '2026-08-21T09:00:00Z' });
  const second = await reconcile(db);
  assert.equal(second.updated, 0);
  assert.deepEqual(await stored(db), before.payload);
  assert.equal(await revision(), before.revision);
  assert.deepEqual((await db.query('select * from futbeat_private.match_result_reconciliation')).rows,
    before.reconciliation);
}));

test('merge helper stays private', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated']) {
    for (const fn of ['futbeat_private.merge_calendar_match_payload(jsonb,jsonb)',
      'futbeat_private.reconcile_goal_results_local(date)']) {
      assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok, false);
    }
  }
}));

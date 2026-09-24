import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

const MATCH = 'fb_match_final';
const FINISHED = 'FINISHED_PENDING_VERIFICATION';

// Canonical payload as left by a calendar re-ingest AFTER the match: not
// terminal, no score, and a receivedAt newer than the real terminal evidence.
async function seed(db, { status = 'SCHEDULED', start = '2026-08-20T18:00:00Z',
  receivedAt = '2026-08-21T09:00:00Z' } = {}) {
  const rows = [
    { id: 'fb_comp_final', kind: 'competition', name: 'Competition', country: 'Costa Rica' },
    { id: 'fb_team_final_home', kind: 'team', name: 'Home', country: 'Costa Rica' },
    { id: 'fb_team_final_away', kind: 'team', name: 'Away', country: 'Costa Rica' },
    { id: MATCH, kind: 'match', competitionId: 'fb_comp_final', homeTeamId: 'fb_team_final_home',
      awayTeamId: 'fb_team_final_away', startTime: start, status, score: null, events: [],
      statistics: [], provenance: { source: 'GOAL API', receivedAt } },
  ];
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select item->>'id',item->>'kind',item-'kind' from jsonb_array_elements($1::jsonb) item`,
  [JSON.stringify(rows)]);
}

let hash = 0;
async function observation(db, status, receivedAt, score = [2, 1]) {
  await db.query(`insert into futbeat_private.provider_observations
    (provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api','final',$1,$2,$3,$4,$5,$6,'{}')`,
  [MATCH, receivedAt, status, score?.[0] ?? null, score?.[1] ?? null, (++hash).toString(16).padStart(64, '0')]);
}

async function event(db, type, firstSeenAt, minute) {
  await db.query(`insert into futbeat_private.canonical_events values($1,$2,'goal_api',$3,$4,false,$5)`,
    [`fb_event_${type.toLowerCase()}_${++hash}`, MATCH, type, JSON.stringify({ minute }), firstSeenAt]);
}

// Calendar and Match Center must always agree on status and score.
async function both(db, date = '2026-08-20') {
  const calendar = (await db.query(
    "select public.futbeat_read_calendar_range($1::date,$1::date,'UTC') v", [date])).rows[0].v;
  const context = (await db.query('select public.futbeat_read_match_context($1) v', [MATCH])).rows[0].v;
  const fromCalendar = calendar.matches.find((m) => m.id === MATCH);
  const fromContext = context.matches[0];
  assert.equal(fromCalendar.status, fromContext.status);
  assert.deepEqual(fromCalendar.score ?? null, fromContext.score ?? null);
  assert.equal(fromCalendar.hasPlayedEvidence, fromContext.hasPlayedEvidence);
  return fromContext;
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('1. SCHEDULED + score + real FULL_TIME event is final', () => withDb(async (db) => {
  await seed(db);
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z');
  await event(db, 'GOAL', '2026-08-20T18:40:00Z', 38);
  await event(db, 'FULL_TIME', '2026-08-20T19:55:00Z', 90);
  const match = await both(db);
  assert.equal(match.status, FINISHED);
  assert.deepEqual(match.score, { home: 2, away: 1 });
  assert.equal(match.hasPlayedEvidence, true);
}));

test('FULL_TIME recorded before the current kickoff (reschedule) is ignored', () => withDb(async (db) => {
  await seed(db);
  await event(db, 'FULL_TIME', '2026-08-19T20:00:00Z', 90);
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z');
  const match = await both(db);
  assert.equal(match.status, 'SCHEDULED');
  assert.deepEqual(match.score, { home: 2, away: 1 });
}));

test('2. SCHEDULED + score without terminal evidence stays partial', () => withDb(async (db) => {
  await seed(db);
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z', [3, 0]);
  await event(db, 'GOAL', '2026-08-20T18:40:00Z', 38);
  await event(db, 'HALFTIME', '2026-08-20T18:50:00Z', 45);
  const match = await both(db);
  // Goals, a halftime whistle and elapsed time are never a final whistle.
  assert.equal(match.status, 'SCHEDULED');
  assert.deepEqual(match.score, { home: 3, away: 0 });
  assert.equal(match.hasPlayedEvidence, true);
}));

test('3. terminal observation older than a canonical rewrite is final', () => withDb(async (db) => {
  await seed(db);
  await observation(db, 'LIVE', '2026-08-20T19:00:00Z', [1, 1]);
  await observation(db, FINISHED, '2026-08-20T19:56:00Z', [2, 1]);
  // Regression proof: the previous projection hid this real final.
  const previous = await readFile(new URL(
    '../../supabase/migrations/20260921230212_mobile_feed_history_read_model.sql', import.meta.url), 'utf8');
  const fixed = await readFile(new URL(
    '../../supabase/migrations/20260922220000_terminal_evidence_read_model.sql', import.meta.url), 'utf8');
  const fn = (sql) => sql.slice(sql.indexOf('create or replace function futbeat_private.match_read_model'),
    sql.indexOf('revoke all on function futbeat_private.match_read_model'));
  await db.exec(fn(previous));
  assert.equal((await both(db)).status, 'SCHEDULED');
  // The migration's own cache invalidation must evict the stale cached day.
  await db.exec(fixed.slice(fixed.indexOf('create or replace function futbeat_private.match_read_model'),
    fixed.indexOf('notify pgrst')));
  const match = await both(db);
  assert.equal(match.status, FINISHED);
  assert.deepEqual(match.score, { home: 2, away: 1 });
}));

test('3b. terminal match detail cache and live state are final evidence', () => withDb(async (db) => {
  await seed(db);
  await db.query(`insert into futbeat_private.match_detail_cache values($1,'goal_api','final',
    '2026-08-20T20:05:00Z','{"matchStatus":"AFTER_PEN","homeTeamScore":1,"awayTeamScore":1}')`, [MATCH]);
  let match = await both(db);
  assert.equal(match.status, FINISHED);
  assert.deepEqual(match.score, { home: 1, away: 1 });
  await db.query('delete from futbeat_private.match_detail_cache where match_id=$1', [MATCH]);
  await db.query(`insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,
    status,minute,home_score,away_score,event_count,last_payload_hash,revision,first_seen_at,last_seen_at,changed_at)
    values('goal_api','final',$1,$2,90,0,2,0,$3,1,'2026-08-20T18:00:00Z','2026-08-20T19:58:00Z','2026-08-20T19:58:00Z')`,
  [MATCH, FINISHED, 'f'.repeat(64)]);
  match = await both(db);
  assert.equal(match.status, FINISHED);
  assert.deepEqual(match.score, { home: 0, away: 2 });
}));

test('4. old LIVE without a final never becomes final', () => withDb(async (db) => {
  await seed(db, { status: 'LIVE', receivedAt: '2026-08-20T19:30:00Z' });
  await observation(db, 'LIVE', '2026-08-20T19:30:00Z');
  await observation(db, 'HALFTIME', '2026-08-20T18:50:00Z', [1, 1]);
  await event(db, 'KICKOFF', '2026-08-20T18:00:00Z', 0);
  const match = await both(db);
  assert.equal(match.status, 'SCHEDULED');
  assert.deepEqual(match.score, { home: 2, away: 1 });
}));

test('strong or fresh canonical states are not overridden by older finals', () => withDb(async (db) => {
  const start = new Date(Date.now() - 2 * 3600e3);
  const at = (minutes) => new Date(start.getTime() + minutes * 60e3).toISOString();
  const today = start.toISOString().slice(0, 10);
  await seed(db, { status: 'LIVE', start: start.toISOString(), receivedAt: new Date().toISOString() });
  await observation(db, FINISHED, at(30));
  // A fresh LIVE canonical newer than the final keeps the strict ordering.
  assert.equal((await both(db, today)).status, 'LIVE');
  await db.query(`update futbeat_private.entities set payload=payload||'{"status":"SUSPENDED"}'::jsonb where id=$1`, [MATCH]);
  // UTC today is a short-TTL snapshot (unversioned): read after it expires.
  await db.exec("update futbeat_private.compact_calendar_cache set expires_at=now()-interval '1 second'");
  assert.equal((await both(db, today)).status, 'SUSPENDED');
}));

test('migration invalidates cached calendar days and keeps helper private', () => withDb(async (db) => {
  assert.ok((await db.query('select revision from futbeat_private.catalog_cache_version')).rows[0].revision > 1);
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query(
      "select has_function_privilege($1,'futbeat_private.match_read_model(jsonb)','EXECUTE') ok", [role])).rows[0].ok, false);
  }
}));

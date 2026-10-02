import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// Current phase of a multi-phase standings table: `currentGroup` is set on
// every standings_cache write from the stageName of the competition's recent
// match details. Synthetic ids/names; DB-only, no provider calls.

const DAY = 24 * 3600e3;
const iso = (ms) => new Date(ms).toISOString();
let seq = 0;

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

async function entity(db, kind, prefix, payload = {}) {
  const id = `fb_${prefix}_cg${++seq}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, name: `N${seq}`, ...payload })]);
  return id;
}

// A started match of `comp` whose stored GOAL detail carries `stage`.
async function detail(db, comp, stage, at) {
  const [home, away] = [await entity(db, 'team', 'team'), await entity(db, 'team', 'team')];
  const id = await entity(db, 'match', 'match', {
    competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: iso(at),
    status: 'VERIFIED', season: '2026', events: [], statistics: [],
  });
  await db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    values($1,'goal_api',$2,now(),$3)`, [id, `x${seq}`, JSON.stringify({ stageName: stage, matchRound: '3' })]);
}

// labels: one entry per group (null = the unlabelled overall table).
function table(comp, labels) {
  const rows = labels.flatMap((group) => [1, 2].map((position) => ({
    teamId: `fb_team_row${position}`, position, ...(group ? { group } : {}),
    played: 3, won: 1, drawn: 1, lost: 1, gf: 2, ga: 2, points: 4,
  })));
  return { competitionId: comp, season: '2026', grouped: labels.length > 1, groupsResolved: true, rows };
}

async function store(db, comp, labels, { at = Date.now(), extra = {} } = {}) {
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api','l1','2026',$2,$3)
    on conflict(competition_id) do update set table_payload=excluded.table_payload,fetched_at=excluded.fetched_at`,
  [comp, JSON.stringify({ ...table(comp, labels), ...extra }), iso(at)]);
  return (await db.query('select table_payload p from futbeat_private.standings_cache where competition_id=$1', [comp])).rows[0].p;
}

test('match detail exposes the provider stage (additive)', () => {
  assert.equal(normalizeMatchDetail({ payload: { stageName: ' Clausura ', matchRound: '3' } }).stage, 'Clausura');
  assert.equal(normalizeMatchDetail({ payload: { matchRound: '3' } }).stage, null);
});

test('recent stages naming one phase: currentGroup is that phase', () => withDb(async (db) => {
  const comp = await entity(db, 'competition', 'comp', { season: '2026' });
  const now = Date.now();
  await detail(db, comp, 'Clausura', now - 2 * DAY);
  await detail(db, comp, 'CLÁUSURA', now - 6 * DAY);
  // Older than the 21-day window: not evidence.
  await detail(db, comp, 'Apertura', now - 40 * DAY);
  // Not started yet at the table's time: not evidence.
  await detail(db, comp, 'Apertura', now + 2 * DAY);
  const payload = await store(db, comp, [null, 'Apertura', 'Clausura'], { at: now });
  assert.equal(payload.currentGroup, 'Clausura');
  // Archived with it too.
  const archived = (await db.query('select table_payload p from futbeat_private.standings_snapshots where competition_id=$1', [comp])).rows[0].p;
  assert.equal(archived.currentGroup, 'Clausura');
}));

test('a stage containing the label tokens still names it', () => withDb(async (db) => {
  const comp = await entity(db, 'competition', 'comp', { season: '2026' });
  await detail(db, comp, 'Clausura - Quadrangulars', Date.now() - DAY);
  assert.equal((await store(db, comp, [null, 'Apertura', 'Clausura'])).currentGroup, 'Clausura');
}));

test('parallel groups, unmatched stages or no evidence: no currentGroup', () => withDb(async (db) => {
  const now = Date.now();
  // Two groups played on the same days.
  const parallel = await entity(db, 'competition', 'comp', { season: '2026' });
  await detail(db, parallel, 'League A', now - DAY);
  await detail(db, parallel, 'League D', now - DAY);
  assert.equal((await store(db, parallel, ['League A', 'League B', 'League D'])).currentGroup, undefined);
  // A stage that names no group next to one that does.
  const mixed = await entity(db, 'competition', 'comp', { season: '2026' });
  await detail(db, mixed, 'Group Stage', now - DAY);
  await detail(db, mixed, 'League A', now - 2 * DAY);
  assert.equal((await store(db, mixed, ['League A', 'League B'])).currentGroup, undefined);
  // No recent detail at all.
  const none = await entity(db, 'competition', 'comp', { season: '2026' });
  assert.equal((await store(db, none, [null, 'Apertura', 'Clausura'])).currentGroup, undefined);
  // A single table never gets one.
  const single = await entity(db, 'competition', 'comp', { season: '2026' });
  await detail(db, single, 'Regular season', now - DAY);
  assert.equal((await store(db, single, [null])).currentGroup, undefined);
}));

test('a stale hint never survives a new write', () => withDb(async (db) => {
  const comp = await entity(db, 'competition', 'comp', { season: '2026' });
  const payload = await store(db, comp, [null, 'Apertura', 'Clausura'], { extra: { currentGroup: 'Apertura' } });
  assert.equal(payload.currentGroup, undefined);
  await detail(db, comp, 'Apertura', Date.now() - DAY);
  assert.equal((await store(db, comp, [null, 'Apertura', 'Clausura'])).currentGroup, 'Apertura');
  // The phase changes: the next table follows the new evidence only.
  await db.query('delete from futbeat_private.match_detail_cache');
  await detail(db, comp, 'Clausura', Date.now() - DAY);
  assert.equal((await store(db, comp, [null, 'Apertura', 'Clausura'])).currentGroup, 'Clausura');
}));

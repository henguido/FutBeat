import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

let seq = 0;
async function seedCanonicalPlayer(db, { withMedia = false } = {}) {
  const n = ++seq;
  const id = `fb_player_lh_${n}`;
  const payload = { id, name: `Jugador ${n}`, teamId: `fb_team_lh_${n}`,
    // player_hydration_due also treats missing profile fields as due, so a
    // "fully hydrated" fixture needs these alongside valid media.
    ...(withMedia ? { media: { url: `https://media.goal-api.com/players/${n}.png`,
      verificationStatus: 'VERIFIED' }, dateOfBirth: '2000-01-01', country: 'Test',
      position: 'Forward', height: '180' } : {}) };
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, 'player', JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','player',$1,$2)", [`ext-lh-${n}`, id]);
  return id;
}

const hydrate = (db, starters, bench) =>
  db.query('select public.futbeat_request_lineup_hydration($1,$2) v', [starters, bench]).then((r) => r.rows[0].v);
const coverage = (db, playerId) =>
  db.query('select priority::int p,request_count::int n from futbeat_private.player_profile_coverage where player_id=$1', [playerId])
    .then((r) => r.rows[0]);
const reserve = (db) =>
  db.query("select public.futbeat_reserve_player_call('test') v").then((r) => r.rows[0].v);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('starter missing photo: registers demand at priority 1, wakes worker, one call per RPC batch', () => withDb(async (db) => {
  const starter = await seedCanonicalPlayer(db);
  const result = await hydrate(db, [starter], []);
  assert.equal(result.enrichmentPending, true);
  assert.deepEqual(await coverage(db, starter), { p: 1, n: 1 });
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='demand'")).rows[0].n, 1);
}));

test('bench player missing photo: priority 2, starter still reserved first', () => withDb(async (db) => {
  const bench = await seedCanonicalPlayer(db);
  const starter = await seedCanonicalPlayer(db);
  await hydrate(db, [starter], [bench]);
  const first = await reserve(db);
  assert.equal(first.allowed, true);
  assert.equal(first.playerId, starter);
}));

test('canonical player already has verified media: not due, no demand', () => withDb(async (db) => {
  const player = await seedCanonicalPlayer(db, { withMedia: true });
  const result = await hydrate(db, [player], []);
  assert.equal(result.enrichmentPending, false);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.player_profile_coverage where player_id=$1', [player])).rows[0].n, 0);
}));

test('unmapped provider player (no provider_entities row): skipped silently, no error', () => withDb(async (db) => {
  await db.query("insert into futbeat_private.entities values('fb_player_unmapped','player',$1)",
    [JSON.stringify({ id: 'fb_player_unmapped', name: 'Nadie' })]);
  const result = await hydrate(db, ['fb_player_unmapped'], []);
  assert.equal(result.enrichmentPending, false);
}));

test('same player requested twice within a minute dedupes', () => withDb(async (db) => {
  const player = await seedCanonicalPlayer(db);
  await hydrate(db, [player], []);
  await hydrate(db, [player], []);
  assert.equal((await db.query('select request_count::int n from futbeat_private.player_profile_coverage where player_id=$1', [player])).rows[0].n, 2);
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='demand'")).rows[0].n, 1);
}));

test('hydration later adds photo: a subsequent lineup media read reflects it (photo pipeline case 5)', () => withDb(async (db) => {
  const player = await seedCanonicalPlayer(db);
  const before = (await db.query(
    "select futbeat_private.futbeat_read_lineup_player_media('goal_api',array['ext-lh-'||$1]) v",
    [player.split('_').pop()],
  )).rows[0].v[`ext-lh-${player.split('_').pop()}`];
  assert.equal(before.image, null);

  await db.query(
    "update futbeat_private.entities set payload=payload||jsonb_build_object('media',jsonb_build_object('url',$2::text,'verificationStatus','VERIFIED')) where id=$1",
    [player, 'https://media.goal-api.com/players/hydrated.png'],
  );

  const after = (await db.query(
    "select futbeat_private.futbeat_read_lineup_player_media('goal_api',array['ext-lh-'||$1]) v",
    [player.split('_').pop()],
  )).rows[0].v[`ext-lh-${player.split('_').pop()}`];
  assert.equal(after.image, 'https://media.goal-api.com/players/hydrated.png');
}));

test('match-detail API route requests lineup hydration for missing photos only', async () => {
  const source = await (await import('node:fs/promises')).readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /lineupPlayerIdsBySection/);
  assert.match(source, /futbeat_request_lineup_hydration/);
  assert.match(source, /lineupEnrichmentPending/);
  assert.ok(
    source.indexOf("/futbeat-api/v1/match-detail") <
      source.indexOf("futbeat_request_lineup_hydration"),
    'lineup hydration demand must run inside the match-detail route',
  );
});

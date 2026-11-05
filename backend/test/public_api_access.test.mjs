import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// FutBeat 1.0 public access (20261105100000): browsing never creates
// provider demand while the switch is off (the default), and every request
// is admitted against identity, IP-hash and global windows. PGlite; no
// provider is ever called.

const DEMAND_TABLES = [
  'match_detail_requests', 'calendar_date_requests', 'player_search_demands', 'standings_demands',
  'team_squad_demands', 'team_match_demands', 'results_date_user_demand',
];

async function withDb(fn) {
  // The migrated default, not the test helper's demand-lane default.
  const db = await openDatabase(undefined, { navigationDemands: null });
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_comp_pa','competition','{"id":"fb_comp_pa","name":"Liga Pasiva","season":"2026"}'),
      ('fb_team_pa1','team','{"id":"fb_team_pa1","name":"Club Pasivo","competitionId":"fb_comp_pa"}'),
      ('fb_team_pa2','team','{"id":"fb_team_pa2","name":"Rival Pasivo","competitionId":"fb_comp_pa"}'),
      ('fb_player_pa','player','{"id":"fb_player_pa","name":"Jugador Pasivo","teamId":"fb_team_pa1"}')`);
    await db.query(`insert into futbeat_private.entities values('fb_match_pa','match',$1)`, [JSON.stringify({
      id: 'fb_match_pa', competitionId: 'fb_comp_pa', homeTeamId: 'fb_team_pa1', awayTeamId: 'fb_team_pa2',
      startTime: new Date(Date.now() - 3 * 3600e3).toISOString(), status: 'SCHEDULED', events: [], statistics: [] })]);
    for (const [kind, ext, id] of [['team', 'pa-1', 'fb_team_pa1'], ['team', 'pa-2', 'fb_team_pa2'], ['match', 'pa-m', 'fb_match_pa'], ['player', 'pa-p', 'fb_player_pa'], ['competition', 'pa-c', 'fb_comp_pa']]) {
      await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api',$1,$2,$3)", [kind, ext, id]);
    }
    await fn(db);
  } finally { await db.close(); }
}

const v = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;
const demandRows = async (db) => {
  let total = 0;
  for (const table of DEMAND_TABLES) {
    const exists = await v(db, 'select to_regclass($1) is not null v', [`futbeat_private.${table}`]);
    if (exists) total += await v(db, `select count(*)::int v from futbeat_private.${table}`);
  }
  return total;
};
const ledger = (db) => v(db, 'select count(*)::int v from futbeat_private.provider_call_ledger');

async function browse(db) {
  const results = {};
  for (const [name, sql, args] of [
    ['detail', 'select public.futbeat_request_match_detail($1) v', ['fb_match_pa']],
    ['calendar', "select public.futbeat_request_calendar_date(current_date,'America/Costa_Rica') v", []],
    ['player', 'select public.futbeat_request_player_profile($1) v', ['fb_player_pa']],
    ['terminal', 'select public.futbeat_request_terminal_result($1) v', ['fb_match_pa']],
    ['lineup', "select public.futbeat_request_lineup_hydration(array['fb_player_pa'],array[]::text[]) v", []],
    ['standings', 'select public.futbeat_request_match_standings($1) v', ['fb_match_pa']],
    ['squad', 'select public.futbeat_request_team_squad($1) v', ['fb_team_pa1']],
    ['teamMatches', 'select public.futbeat_request_team_matches($1,current_date-30) v', ['fb_team_pa1']],
    ['h2h', 'select public.futbeat_request_match_h2h($1) v', ['fb_match_pa']],
    ['h2hHistory', 'select public.futbeat_request_match_h2h_history($1) v', ['fb_match_pa']],
    ['search', "select public.futbeat_search_catalog('zzqx unknown player') v", []],
  ]) {
    try { results[name] = await v(db, sql, args); } catch (error) { results[name] = { error: error.message }; }
  }
  return results;
}

test('passive by default: browsing every demand entry point writes no demand and no ledger row', () => withDb(async (db) => {
  assert.equal(await v(db, 'select futbeat_private.navigation_demands_enabled() v'), false);
  const before = await demandRows(db);
  const r = await browse(db);
  assert.equal(await demandRows(db), before);
  assert.equal(await ledger(db), 0);
  for (const key of ['calendar', 'player', 'terminal', 'lineup', 'standings', 'squad', 'teamMatches', 'h2h', 'h2hHistory']) {
    assert.deepEqual(r[key], { passive: true, requested: false }, key);
  }
  // The detail falls back to the stored read (same shape as request=0).
  assert.deepEqual(r.detail, await v(db, 'select public.futbeat_read_match_detail($1) v', ['fb_match_pa']));
  assert.notEqual(r.search?.coverage?.pendingRemote, true);
}));

test('switch on: the original demand behaviour comes back without a redeploy', () => withDb(async (db) => {
  await db.query('update futbeat_private.api_access_policy set navigation_demands=true');
  const before = await demandRows(db);
  await browse(db);
  assert.ok(await demandRows(db) > before, 'demands recorded again');
}));

test('only service_role can call the gated functions; the originals are private', () => withDb(async (db) => {
  const acl = async (sig) => v(db, `select coalesce(array_to_string(array(select a.grantee::regrole::text from aclexplode(p.proacl) a where a.privilege_type='EXECUTE' order by 1),','),'') v
    from pg_proc p where p.oid=$1::regprocedure`, [sig]);
  assert.equal(await acl('public.futbeat_request_match_detail(text)'), 'postgres,service_role');
  assert.equal(await acl('futbeat_private.futbeat_request_match_detail__ungated(text)'), 'postgres');
  assert.equal(await acl('public.futbeat_api_admit(text,text,text,integer)'), 'postgres,service_role');
  assert.equal(await v(db, "select to_regprocedure('public.futbeat_request_match_detail__ungated(text)') v"), null);
}));

const ANON = 'anon:11111111-1111-4111-8111-111111111111';
const ANON2 = 'anon:22222222-2222-4222-8222-222222222222';
const USER = 'user:33333333-3333-4333-8333-333333333333';
const IP = 'a'.repeat(32);
const admit = (db, subject, kind, ip = null, cost = 1) =>
  v(db, 'select public.futbeat_api_admit($1,$2,$3,$4) v', [subject, kind, ip, cost]);

test('admission: per-identity minute limits, separate per user, with Retry-After', () => withDb(async (db) => {
  await db.query('update futbeat_private.api_access_policy set anonymous_per_minute=3,registered_per_minute=5');
  for (let i = 0; i < 3; i++) assert.deepEqual(await admit(db, ANON, 'anonymous'), { allowed: true });
  const blocked = await admit(db, ANON, 'anonymous');
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.reason, 'identity_minute');
  assert.ok(blocked.retryAfterSeconds >= 1 && blocked.retryAfterSeconds <= 60);
  // Another guest and a registered user are unaffected.
  assert.equal((await admit(db, ANON2, 'anonymous')).allowed, true);
  for (let i = 0; i < 5; i++) assert.equal((await admit(db, USER, 'registered')).allowed, true);
  assert.equal((await admit(db, USER, 'registered')).allowed, false);
}));

test('admission: hour, IP and global windows; cost weights', () => withDb(async (db) => {
  await db.query('update futbeat_private.api_access_policy set anonymous_per_hour=4,ip_per_minute=6,global_per_minute=100');
  assert.equal((await admit(db, ANON, 'anonymous', null, 4)).allowed, true);
  assert.equal((await admit(db, ANON, 'anonymous')).reason, 'identity_hour');
  // Many guests behind one IP: the IP window caps them together.
  const many = [];
  for (let i = 0; i < 4; i++) many.push(await admit(db, `anon:4444444${i}-4444-4444-8444-444444444444`, 'anonymous', IP, 2));
  assert.deepEqual(many.map((r) => r.allowed), [true, true, true, false]);
  assert.equal(many[3].reason, 'ip_minute');
  // Unauthenticated (open mode) traffic still counts globally.
  await db.query('update futbeat_private.api_access_policy set global_per_minute=12');
  const open = [];
  for (let i = 0; i < 5; i++) open.push(await admit(db, null, 'none', 'b'.repeat(32)));
  assert.ok(open.some((r) => r.reason === 'global_minute'), JSON.stringify(open));
}));

test('admission: concurrent requests are counted exactly', () => withDb(async (db) => {
  await db.query('update futbeat_private.api_access_policy set anonymous_per_minute=50');
  const results = await Promise.all(Array.from({ length: 60 }, () => admit(db, ANON, 'anonymous')));
  assert.equal(results.filter((r) => r.allowed).length, 50);
  assert.equal(await v(db, "select hits v from futbeat_private.api_rate_counters where bucket=$1", [`id:${ANON}`]), 60);
}));

test('admission: malformed subjects, kinds, hashes and costs are refused', () => withDb(async (db) => {
  for (const args of [
    ['anon:not-a-uuid', 'anonymous', null, 1], [USER, 'anonymous', null, 1], [ANON, 'registered', null, 1],
    [null, 'anonymous', null, 1], [ANON, 'none', null, 1], [ANON, 'anonymous', 'not-hex', 1], [ANON, 'anonymous', null, 11],
  ]) {
    await assert.rejects(admit(db, ...args), /Invalid admission request/, JSON.stringify(args));
  }
}));

test('rollback restores the original demand functions and drops admission', async () => {
  const { readFile } = await import('node:fs/promises');
  const db = await openDatabase(undefined, { navigationDemands: null });
  try {
    await db.exec(await readFile(new URL('../../supabase/manual/20261105100000_public_api_access_rollback.sql', import.meta.url), 'utf8'));
    assert.equal(await v(db, "select to_regprocedure('futbeat_private.futbeat_request_match_detail__ungated(text)') v"), null);
    assert.ok(!(await v(db, "select pg_get_functiondef('public.futbeat_request_match_detail(text)'::regprocedure) v")).includes('navigation_demands_enabled'));
    assert.ok(!(await v(db, "select pg_get_functiondef('futbeat_private.note_player_search_demand(text)'::regprocedure) v")).includes('navigation_demands_enabled'));
    assert.equal(await v(db, "select to_regclass('futbeat_private.api_access_policy') v"), null);
  } finally { await db.close(); }
});

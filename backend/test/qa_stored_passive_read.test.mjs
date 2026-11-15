import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { handleStoredRead, resetStoredReadCache, storedRpcs } from '../../supabase/functions/futbeat-qa-stored/handler.ts';

// Candidate futbeat-qa-stored (not deployed): real SQL (PGlite, all migrations
// plus the manual candidate) and the real handler. Each RPC runs as the Edge
// does through PostgREST for STABLE functions, in a READ ONLY transaction.

const manual = (name) => readFile(new URL(`../../supabase/manual/${name}`, import.meta.url), 'utf8');
const handlerSource = () => readFile(new URL('../../supabase/functions/futbeat-qa-stored/handler.ts', import.meta.url), 'utf8');
const request = (path, method = 'GET') =>
  new Request(`https://local.test/functions/v1/futbeat-qa-stored/v1/qa-stored/${path}`, { method });

const match = 'fb_match_passive_1', home = 'fb_team_passive_h', away = 'fb_team_passive_a', comp = 'fb_comp_passive';
const day = new Date(Date.now() - 2 * 86400e3).toISOString().slice(0, 10);

const rpcOf = (db, calls = []) => async (name, args = {}) => {
  calls.push(name);
  const keys = Object.keys(args);
  const values = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k])
    ? JSON.stringify(args[k]) : args[k]));
  await db.exec('begin read only');
  try {
    const { rows } = await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, values);
    await db.exec('commit');
    return { data: rows[0].v, error: null };
  } catch (error) {
    await db.exec('rollback');
    return { data: null, error };
  }
};

// Every base table outside the catalogs: row count and content hash.
async function fingerprint(db) {
  const tables = (await db.query(`select format('%I.%I',n.nspname,c.relname) t from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where c.relkind in ('r','p') and n.nspname in ('public','futbeat_private') order by 1`)).rows.map((r) => r.t);
  const out = {};
  for (const t of tables) {
    out[t] = (await db.query(`select count(*)::int n,coalesce(md5(string_agg(md5(x::text),'' order by md5(x::text))),'') h from ${t} x`)).rows[0];
  }
  return out;
}
const changed = (a, b) => Object.keys(b).filter((t) => JSON.stringify(a[t]) !== JSON.stringify(b[t]));

async function open() {
  const db = await openDatabase();
  await db.exec(await manual('20261031_qa_stored_reads_candidate.sql'));
  const rows = [
    { id: comp, kind: 'competition', name: 'Passive League', country: 'England' },
    { id: home, kind: 'team', name: 'Passive Home', competitionId: comp },
    { id: away, kind: 'team', name: 'Passive Away', competitionId: comp },
    { id: 'fb_player_passive', kind: 'player', name: 'Passive Striker', teamId: home },
    // Kickoff two days ago, never finished: the state that triggers every demand.
    { id: match, kind: 'match', competitionId: comp, homeTeamId: home, awayTeamId: away,
      startTime: `${day}T18:00:00Z`, status: 'SCHEDULED', score: null, events: [],
      provenance: { receivedAt: `${day}T12:00:00Z` } },
  ];
  await db.query(`insert into futbeat_private.entities select item->>'id',item->>'kind',item-'kind'
    from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','team','ph',$1),('goal_api','team','pa',$2)", [home, away]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','pm',$1)", [match]);
  return db;
}

const routes = [
  `calendar?date=${day}&timezone=UTC`, `calendar?date=${day}`, 'calendar?date=2031-01-01',
  `match-context?id=${match}`, `match-detail?id=${match}`, `match-detail?id=${match}&request=1`,
  `match-preview?id=${match}`, `match-h2h?id=${match}`, `match-h2h?id=${match}&extend=1`,
  `entity?type=team&id=${home}`, `entity?type=player&id=fb_player_passive`, `entity?type=competition&id=${comp}`,
  `team-context?id=${home}`, `team-matches?id=${home}&bucket=results`, `team-matches?id=${home}&bucket=upcoming`,
  `standings-form?competitionId=${comp}&season=2026`, `favorites?keys=team:${home},match:${match}`,
  'explore', 'explore?country=CR', 'search?q=Passive', 'search?q=Passive&country=CR', 'search?q=zzzzqqqq', 'search?q=', 'search?q=x',
];

test('off by default and invalid input never reach the database', async () => {
  const noDb = () => { throw new Error('Unexpected DB call'); };
  const off = await handleStoredRead(request(`calendar?date=${day}`), noDb);
  assert.equal(off.status, 404);
  assert.equal(off.headers.get('x-futbeat-qa-stored'), null);
  assert.equal((await handleStoredRead(request('calendar', 'POST'), noDb, true)).status, 405);
  resetStoredReadCache();
  const stub = async () => ({ data: { teams: {} }, error: null });
  for (const [path, status] of [
    ['calendar?date=2026-02-30', 400], ['match-detail?id=Everton', 400], ['match-context?id=fb_team_x12', 400],
    ['entity?type=venue&id=fb_x123', 400], ['team-matches?id=fb_team_x12&bucket=all', 400],
    ['news?tab=latest', 403], ['snapshot', 403], ['player-suggestions', 403],
  ]) {
    const response = await handleStoredRead(request(path), stub, true);
    assert.equal(response.status, status, path);
    assert.equal(response.headers.get('x-futbeat-qa-stored'), 'v1', path);
  }
});

test('every callable RPC is STABLE and service_role only; the source names no demand path', async () => {
  const db = await open();
  try {
    const candidates = storedRpcs.filter((n) => n.includes('qa_stored'));
    assert.equal(candidates.length, 4);
    for (const name of storedRpcs) {
      const { rows } = await db.query(`select p.provolatile v,has_function_privilege('service_role',p.oid,'EXECUTE') svc,
        has_function_privilege('anon',p.oid,'EXECUTE') anon,has_function_privilege('authenticated',p.oid,'EXECUTE') auth
        from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=$1`, [name]);
      assert.ok(rows.length > 0, `${name} exists`);
      for (const row of rows) {
        assert.equal(row.v, 's', `${name} is STABLE`);
        assert.equal(row.svc, true, name);
        assert.equal(row.anon, false, name);
        assert.equal(row.auth, false, name);
      }
    }
    assert.doesNotMatch(await handlerSource(), /['"`]futbeat_(request|wake|enqueue|store|note)|fetch\(|goal-api|read_calendar_range|read_explore|search_catalog['"`]/);
    const stored = await manual('20261031_qa_stored_reads_candidate.sql');
    const body = stored.replace(/--[^\n]*/g, '');
    assert.doesNotMatch(body, /\b(insert into|update\s+futbeat|delete from|net\.http|wake_provider|enqueue_|materialize_|build_compact|note_player)/i);
  } finally { await db.close(); }
});

test('an RPC failure answers 503 with the header and no fallback', async () => {
  resetStoredReadCache();
  const calls = [];
  const response = await handleStoredRead(request(`calendar?date=${day}`), async (name) => {
    calls.push(name);
    return { data: null, error: { message: 'offline' } };
  }, true);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('x-futbeat-qa-stored'), 'v1');
  assert.deepEqual(calls, ['futbeat_read_qa_stored_national_teams', 'futbeat_read_qa_stored_calendar']);
});

test('all routes on a demand-prone match: 0 writes, 0 demands, 0 network; the ordinary RPCs do write', async () => {
  const db = await open();
  const realFetch = globalThis.fetch;
  let network = 0;
  globalThis.fetch = async () => { network++; throw new Error('network'); };
  try {
    // A cached calendar row, outdated on purpose.
    await db.query(`insert into futbeat_private.compact_calendar_cache values($1,'UTC','old',$2,now()-interval '2 days',now()-interval '1 day')`,
      [day, JSON.stringify({ schemaVersion: 1, demo: false, coverage: { partial: true }, matches: [{ id: match }] })]);
    const before = await fingerprint(db);
    const calls = [];
    resetStoredReadCache();
    const statuses = {};
    for (let round = 0; round < 3; round++) {
      for (const path of routes) {
        const response = await handleStoredRead(request(path), rpcOf(db, calls), true);
        statuses[path] = response.status;
        assert.equal(response.headers.get('x-futbeat-qa-stored'), 'v1', path);
        assert.equal(response.headers.get('cache-control'), 'no-store', path);
        assert.ok([200, 404].includes(response.status), `${path} ${response.status} ${await response.clone().text()}`);
        await response.text();
      }
    }
    assert.equal(statuses[`match-detail?id=${match}`], 200);
    assert.equal(statuses[`match-context?id=${match}`], 200);
    assert.equal(statuses[`entity?type=team&id=${home}`], 200);
    assert.equal(statuses['search?q=zzzzqqqq'], 200);
    assert.equal(statuses['calendar?date=2031-01-01'], 404);
    const found = await (await handleStoredRead(request('search?q=Passive'), rpcOf(db), true)).json();
    assert.ok(found.teams.some((t) => t.id === home));
    assert.ok(found.players.some((p) => p.id === 'fb_player_passive'));
    assert.equal(found.coverage?.pendingRemote, undefined);
    const after = await fingerprint(db);
    console.log(`fingerprint tables: ${Object.keys(before).length}`);
    for (const table of ['entities', 'demand_metrics', 'worker_wakeups', 'match_detail_requests', 'calendar_date_requests',
      'player_search_demands', 'player_profile_coverage', 'team_match_demands', 'team_squad_demands', 'standings_demands',
      'results_date_user_demand', 'calendar_snapshot_queue', 'calendar_snapshot_zones', 'compact_calendar_cache',
      'explore_cache', 'explore_country_cache', 'national_team_cache']) {
      assert.ok(`futbeat_private.${table}` in before, `fingerprint covers ${table}`);
    }
    assert.deepEqual(changed(before, after), [], 'no table changed');
    assert.equal(network, 0);
    assert.ok(calls.every((name) => storedRpcs.includes(name)));

    // Control: the same openings through the ordinary RPCs are seen by the detector.
    for (const sql of [
      `select public.futbeat_request_match_detail('${match}')`,
      `select public.futbeat_request_terminal_result('${match}')`,
      `select public.futbeat_request_match_h2h('${match}')`,
      `select public.futbeat_request_team_squad('${home}')`,
      `select public.futbeat_search_catalog('zzzzqqqq',null,50)`,
      `select public.futbeat_read_calendar_range('${day}','${day}','America/Costa_Rica')`,
      `select public.futbeat_request_calendar_date('${day}','UTC')`,
      `select public.futbeat_read_explore()`,
    ]) await db.query(sql);
    const touched = changed(after, await fingerprint(db));
    for (const table of ['match_detail_requests', 'team_match_demands', 'player_search_demands', 'calendar_date_requests',
      'compact_calendar_cache', 'explore_cache', 'calendar_snapshot_zones']) {
      assert.ok(touched.includes(`futbeat_private.${table}`), `control touches ${table}`);
    }
  } finally { globalThis.fetch = realFetch; await db.close(); }
});

test('the ordinary volatile readers fail in the transaction the candidate runs in', async () => {
  const db = await open();
  try {
    await db.exec('begin read only');
    await assert.rejects(db.query(`select public.futbeat_read_calendar_range('${day}','${day}','UTC')`), /read-only/);
    await db.exec('rollback');
  } finally { await db.close(); }
});

test('calendar serves the stored row marked stale and never builds; a miss is 404', async () => {
  const db = await open();
  try {
    await db.exec(`create or replace function futbeat_private.build_compact_calendar(p_from_date date,p_to_date date,p_timezone text default 'America/Costa_Rica')
      returns jsonb language plpgsql stable security definer set search_path='' as $$ begin raise exception 'builder called'; end $$`);
    await db.query(`insert into futbeat_private.compact_calendar_cache values($1,'America/Costa_Rica',
      futbeat_private.calendar_cache_version($1,'America/Costa_Rica'),'{"schemaVersion":1,"demo":false,"matches":[]}',now(),now()+interval '1 day')`, [day]);
    resetStoredReadCache();
    const read = async (path) => {
      const r = await handleStoredRead(request(path), rpcOf(db), true);
      return [r.status, await r.json()];
    };
    const [fresh, freshBody] = await read(`calendar?date=${day}`);
    assert.equal(fresh, 200);
    assert.deepEqual(freshBody.freshness, { stale: false, revalidating: false });
    await db.exec("update futbeat_private.compact_calendar_cache set expires_at=now()-interval '1 minute'");
    assert.equal((await read(`calendar?date=${day}`))[1].freshness.stale, true);
    await db.exec(`update futbeat_private.compact_calendar_cache set expires_at=now()+interval '1 day',version='older'`);
    assert.equal((await read(`calendar?date=${day}`))[1].freshness.stale, true);
    assert.equal((await read(`calendar?date=${day}&timezone=UTC`))[0], 404);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.compact_calendar_cache')).rows[0].n, 1);
  } finally { await db.close(); }
});

test('explore serves expired cache as stale and an empty catalog when cold', async () => {
  const db = await open();
  try {
    await db.exec('delete from futbeat_private.explore_cache where singleton');
    resetStoredReadCache();
    const cold = await handleStoredRead(request('explore'), rpcOf(db), true);
    assert.equal(cold.status, 200);
    assert.deepEqual((await cold.json()).teams, []);
    await db.query(`insert into futbeat_private.explore_cache values(true,0,$1,now()-interval '1 hour')`,
      [JSON.stringify({ schemaVersion: 1, demo: false, teams: [{ id: home, name: 'Passive Home' }], competitions: [] })]);
    const stale = await (await handleStoredRead(request('explore?country=CR'), rpcOf(db), true)).json();
    assert.equal(stale.teams.length, 1);
    assert.equal(stale.freshness.stale, true);
  } finally { await db.close(); }
});

test('detail does not ask the app to poll; entity drops excerpts; teams keep national marks', async () => {
  resetStoredReadCache();
  const rpc = async (name) => {
    if (name === 'futbeat_read_qa_stored_national_teams') return { data: { teams: { fb_team_cr1: { code: 'CR' } } }, error: null };
    if (name === 'futbeat_read_match_detail') {
      return { data: { matchId: 'fb_match_abc', pending: true, hydrationNeeded: true, coverage: { pending: true, hydrationNeeded: true }, payload: {} }, error: null };
    }
    if (name === 'futbeat_read_match_videos') return { data: null, error: { message: 'x' } };
    if (name === 'futbeat_read_entity_detail') {
      return { data: { schemaVersion: 1, demo: false, teams: [{ id: 'fb_team_cr1', name: 'Costa Rica' }],
        news: [{ title: 't', description: 'd', imageUrl: 'i' }] }, error: null };
    }
    throw new Error(name);
  };
  const detail = await (await handleStoredRead(request('match-detail?id=fb_match_abc'), rpc, true)).json();
  assert.equal(detail.pending, false);
  assert.equal(detail.coverage.pending, false);
  assert.equal(detail.hydrationNeeded, true);
  assert.equal(detail.coverage.videos, 'unavailable');
  const entity = await (await handleStoredRead(request('entity?type=team&id=fb_team_cr1'), rpc, true)).json();
  assert.deepEqual(entity.news, [{ title: 't' }]);
  assert.equal(entity.teams[0].nationalTeamCode, 'CR');
});

test('rollback removes exactly the four candidate functions', async () => {
  const db = await open();
  try {
    const count = async () => (await db.query("select count(*)::int n from pg_proc where proname like 'futbeat_read_qa_stored%'")).rows[0].n;
    assert.equal(await count(), 4);
    await db.exec(await manual('20261031_qa_stored_reads_candidate_rollback.sql'));
    assert.equal(await count(), 0);
  } finally { await db.close(); }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Hardening from the QA/concurrency review of the on-demand pipeline.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const search = (db, q) => db.query('select public.futbeat_search_catalog($1,null,50) v', [q]).then((r) => r.rows[0].v);
const keys = (db) => db.query('select query_key from futbeat_private.player_search_demands order by query_key')
  .then((r) => r.rows.map((x) => x.query_key));
const decide = (db, kind, cls) => db.query("select futbeat_private.quota_decision('goal_api',$1,$2) v", [kind, cls])
  .then((r) => r.rows[0].v);

test('typing a name does not queue one paid search per prefix', () => withDb(async (db) => {
  for (const q of ['haa', 'haal', 'haala', 'haalan', 'haaland']) await search(db, q);
  assert.deepEqual(await keys(db), ['haaland']);
  // Deleting characters (a shorter query) is a new demand, not a supersede.
  await search(db, 'haal');
  assert.deepEqual(await keys(db), ['haal', 'haaland']);
}));

test('a popular prefix another user asked for is kept', () => withDb(async (db) => {
  for (let i = 0; i < 3; i++) await search(db, 'mess');
  await search(db, 'messiah');
  assert.deepEqual(await keys(db), ['mess', 'messiah']);
}));

test('repeating a junk query cannot monopolize the search budget', () => withDb(async (db) => {
  for (let i = 0; i < 50; i++) await search(db, 'zzzz junk');
  await db.query("update futbeat_private.player_search_demands set requested_at=now()-interval '5 minutes'");
  await search(db, 'julian alvarez');
  const reservation = (await db.query("select public.futbeat_reserve_player_call('test') v")).rows[0].v;
  assert.equal(reservation.query, 'julian alvarez');
}));

test('stale demand rows are cleaned up by the reservation housekeeping', () => withDb(async (db) => {
  await search(db, 'olvidado uno');
  await db.query("update futbeat_private.player_search_demands set requested_at=now()-interval '2 hours'");
  await db.query(`insert into futbeat_private.player_search_demands(query_key,query_text,status,next_retry_at,last_attempt_at)
    values('viejo cache','viejo cache','NO_DATA',now()-interval '40 days',now()-interval '43 days')`);
  const reservation = (await db.query("select public.futbeat_reserve_player_call('test') v")).rows[0].v;
  assert.equal(reservation.reason, 'no_player_demand');
  assert.deepEqual(await keys(db), []);
}));

test('unknown remaining: LIVE/results keep working, everything else stops at the conservative total', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','live-goal','test','FAILED' from generate_series(1,600)`);
  assert.equal((await decide(db, 'match-detail', 'user')).reason, 'unknown_budget_cap');
  assert.equal((await decide(db, 'player-search', 'user')).allowed, false);
  assert.equal((await decide(db, 'match-detail', 'live')).allowed, true);
  assert.equal((await decide(db, 'match-detail', 'results')).allowed, true);
  // Once the provider reports remaining, the bands decide again.
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,completed_at)
    values('goal_api','live-goal','test','SUCCEEDED',900,now())`);
  assert.equal((await decide(db, 'match-detail', 'user')).allowed, true);
}));

test('unknown remaining: no single demand lane can take the whole blind budget', () => withDb(async (db) => {
  const search = await decide(db, 'player-search', 'user');
  assert.equal(search.safetyCap, 150); // 25% of unknownDailyCap (600)
  assert.equal((await decide(db, 'player-profile', 'user')).safetyCap, 150);
  assert.equal((await decide(db, 'match-detail', 'live')).safetyCap, 400, 'LIVE keeps its own cap');
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','player-search','test','FAILED' from generate_series(1,150)`);
  assert.equal((await decide(db, 'player-search', 'user')).reason, 'kind_daily_cap');
  assert.equal((await decide(db, 'player-profile', 'user')).allowed, true);
  assert.equal((await decide(db, 'match-detail', 'live')).allowed, true);
}));

test('flood: 1000 distinct junk queries do not create 1000 rows; local search keeps working', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values('fb_player_fl','player','{"id":"fb_player_fl","name":"Keylor Navas"}')`);
  for (let i = 0; i < 1000; i++) await search(db, `junk${i} qx${i * 7919}`);
  const rows = (await db.query('select count(*)::int n from futbeat_private.player_search_demands')).rows[0].n;
  assert.equal(rows, 60); // searchAdmissionsPerWindow
  assert.equal((await db.query("select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric='player_search_demand_limited'")).rows[0].n, 940);
  const local = await search(db, 'keylor navas');
  assert.deepEqual(local.players.map((p) => p.name), ['Keylor Navas']);
  // A limited query answers locally without claiming pending work.
  assert.equal((await search(db, 'otro junk nuevo')).coverage.pendingRemote, undefined);
}));

test('flood limit: repeated and cached queries are unaffected; the window frees up', () => withDb(async (db) => {
  await search(db, 'repetida uno');
  await db.query(`insert into futbeat_private.player_search_demands(query_key,query_text,status,next_retry_at)
    values('cacheada','cacheada','AVAILABLE',now()+interval '3 days')`);
  for (let i = 0; i < 80; i++) await search(db, `llenar${i} zz${i}`);
  // Duplicate of a queued key: still one row, still pending.
  const again = await search(db, 'repetida uno');
  assert.equal(again.coverage.pendingRemote, true);
  assert.equal((await db.query("select request_count::int n from futbeat_private.player_search_demands where query_key='repetida uno'")).rows[0].n, 2);
  // Cached key: cache hit, no slot needed.
  assert.equal((await search(db, 'cacheada')).coverage.pendingRemote, undefined);
  assert.equal((await db.query("select status from futbeat_private.player_search_demands where query_key='cacheada'")).rows[0].status, 'AVAILABLE');
  // Blocked now...
  assert.equal((await search(db, 'nueva tras ventana')).coverage.pendingRemote, undefined);
  // ...admitted again once the admission window has passed.
  await db.query("update futbeat_private.player_search_demands set admitted_at=now()-interval '10 minutes'");
  assert.equal((await search(db, 'nueva tras ventana')).coverage.pendingRemote, true);
}));

test('flood limit: a full pending queue stops new demand', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.player_search_demands(query_key,query_text,admitted_at)
    select 'cola '||i,'cola '||i,now()-interval '1 hour' from generate_series(1,200) i`);
  assert.equal((await search(db, 'no cabe')).coverage.pendingRemote, undefined);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.player_search_demands where query_key='no cabe'")).rows[0].n, 0);
}));

test('profile badge only promises enrichment the quota would allow', () => withDb(async (db) => {
  const id = (await db.query("select public.futbeat_resolve_global_entity('goal_api','player','goal-badge','Badge') id")).rows[0].id;
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,completed_at)
    values('goal_api','live-goal','test','SUCCEEDED',250,now())`);
  const low = (await db.query('select public.futbeat_request_player_profile($1) v', [id])).rows[0].v;
  assert.equal(low.enrichmentPending, false);
  await db.exec("update futbeat_private.provider_call_ledger set provider_remaining=900");
  assert.equal((await db.query('select public.futbeat_request_player_profile($1) v', [id])).rows[0].v.enrichmentPending, true);
}));

test('a squad-owned player: profile fills only missing personal facts (no flip-flop)', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values('fb_team_hd','team','{"id":"fb_team_hd","name":"T"}')`);
  const id = (await db.query("select public.futbeat_resolve_global_entity('goal_api','player','goal-sq','Squad Man') id")).rows[0].id;
  await db.query("update futbeat_private.entities set payload=payload||'{\"teamId\":\"fb_team_hd\",\"dateOfBirth\":\"1995-01-01\"}' where id=$1", [id]);
  await db.query("insert into futbeat_private.team_squad_members(team_id,player_id,provider) values('fb_team_hd',$1,'goal_api')", [id]);
  const result = (await db.query(`select futbeat_private.upsert_goal_player('{"externalId":"goal-sq","name":"Squad Man",
    "dateOfBirth":"1996-06-06","height":181}','profile',now()) v`)).rows[0].v;
  assert.equal(result.id, id);
  const player = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
  assert.deepEqual([player.dateOfBirth, player.height], ['1995-01-01', 181]);
}));

test('an expired user request reused by the prefetch enqueuer loses user priority', () => withDb(async (db) => {
  const rows = [
    ['fb_comp_hd', 'competition', { id: 'fb_comp_hd', name: 'L' }],
    ['fb_team_hd_h', 'team', { id: 'fb_team_hd_h', name: 'H' }],
    ['fb_team_hd_a', 'team', { id: 'fb_team_hd_a', name: 'A' }],
    ['fb_match_hd', 'match', { id: 'fb_match_hd', competitionId: 'fb_comp_hd', homeTeamId: 'fb_team_hd_h',
      awayTeamId: 'fb_team_hd_a', startTime: new Date(Date.now() + 3600e3).toISOString(), status: 'SCHEDULED' }],
  ];
  for (const [id, kind, payload] of rows) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','hd','fb_match_hd')");
  await db.query("select public.futbeat_request_match_detail('fb_match_hd')");
  await db.query("update futbeat_private.match_detail_requests set expires_at=now()-interval '1 second'");
  // Same upsert the prefetch enqueuer performs (it never sets source).
  await db.query(`insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count)
    values('fb_match_hd',now(),now()+interval '10 minutes',1) on conflict(match_id) do update
    set requested_at=excluded.requested_at,expires_at=excluded.expires_at,
      request_count=futbeat_private.match_detail_requests.request_count+1`);
  const row = (await db.query('select source,user_requested_at from futbeat_private.match_detail_requests')).rows[0];
  assert.deepEqual(row, { source: 'prefetch', user_requested_at: null });
  // A user opening it again restores user priority.
  await db.query("select public.futbeat_request_match_detail('fb_match_hd')");
  assert.equal((await db.query('select source from futbeat_private.match_detail_requests')).rows[0].source, 'user');
}));

test('wake-ups never block: debounces are counted as a sharded metric', () => withDb(async (db) => {
  const results = [];
  for (let i = 0; i < 5; i++) results.push((await db.query("select futbeat_private.wake_provider_worker('demand') v")).rows[0].v);
  assert.deepEqual(results, ['unavailable', 'debounced', 'debounced', 'debounced', 'debounced']);
  assert.equal((await db.query("select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric='wake_debounced'")).rows[0].n, 4);
  await assert.rejects(db.query("select futbeat_private.wake_provider_worker('anything')"), /Invalid wake trigger/);
}));

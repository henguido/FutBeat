# Match Center Real-Data Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three real-data gaps in Match Center — historical matches stuck on "Marcador parcial", lineup players missing photos, and lineup players not tappable — by extending the on-demand server pipeline built in PR #91, without ever calling the real GOAL API or touching production.

**Architecture:** Two new server-side demand lanes reuse the exact pattern PR #91 already established (`futbeat_request_*` RPC → dedupe/lease table → central `quota_decision` → `wake_provider_worker` → worker reservation RPC → GOAL fetch → `futbeat_complete_*`): (1) a **terminal-result demand** keyed by GOAL provider-date, so opening a historical "partial" match elevates that whole day's result-recovery priority instead of one call per match; (2) a **lineup-hydration demand** that reuses the existing player-profile coverage table/worker loop, adding a priority column so starters hydrate before bench. On the Flutter side, `_PitchPlayer`/`_BenchPlayer` become tappable via the `canonicalId` the API already emits (but the client ignores today), and `MatchScreen` gets the same bounded-refresh pattern `EntityScreen` already uses for `enrichmentPending`.

**Tech Stack:** Supabase Postgres (PL/pgSQL, PGlite for local tests), Deno edge functions (`futbeat-api`, `futbeat-goal-live-sync`), Flutter/Dart (Riverpod, GoRouter), Node `node:test` for backend, `flutter_test` for the app.

**Spec:** The follow-up brief supplied by the user in this conversation (objectives A–G: terminal result recovery, lineup player hydration, tap-to-profile navigation, photo pipeline regressions, partial-result tests, navigation tests, final validation). No separate spec file exists; this plan **is** the spec's technical design, grounded in the current `main` (commit `c484a6c`).

## Global Constraints

- Local work only: no `supabase db push`, no deploy, no call to the real GOAL API, no `git push`. Every test runs against local PGlite (`backend/test`, via `openDatabase()`) or the Flutter test runner.
- Never infer `FINISHED` from the clock, goal counts, or score presence — only real terminal evidence (a fresh GOAL fetch) may promote a match's status. This existing invariant (`futbeat_private.match_read_model`, `supabase/migrations/20260922220000_terminal_evidence_read_model.sql:11`) must not be touched.
- The mobile app never calls GOAL and never makes 22 individual player-hydration calls; all new demand must flow through one server RPC call per user action, deduped, leased, and quota-gated exactly like the existing player-search/profile and match-detail demand lanes.
- New SQL functions follow the file's existing conventions: `security definer`, `set search_path=''`, `language plpgsql`/`sql`, private helpers under `futbeat_private.*` revoked from `public,anon,authenticated,service_role`, public `request_*`/`reserve_*`/`store_*` wrappers revoked from `public,anon,authenticated` then explicitly `grant execute ... to service_role`, and every migration ends with `notify pgrst,'reload schema';`.
- Migration filenames use `YYYYMMDDHHMMSS_snake_case_description.sql`, later than the current top of chain (`20260923120000_player_on_demand.sql`).
- Commit locally in blocks (one commit per task once its tests are green); do not push.

## Review Focus

- **A match that exists but was never indexed into `calendar_matches`** (no provider_date can be resolved) — `futbeat_request_terminal_result` must not crash or insert a malformed `calendar_coverage` row; it should report `resultsPending:false, reason:'unscheduled'` (Task 1's "match not indexed in calendar_matches" test).
- **A match already terminal when the user opens it** — `futbeat_request_terminal_result` must short-circuit to `resultsPending:false` and issue zero provider calls, never re-queuing an already-resolved date (Task 1's "terminal already" test).
- **The same date requested by two different open matches within the debounce window** — must still produce exactly one wake and one dedup-safe demand row, not two independent races (Task 1's "same-date double open" test).
- **A lineup player whose provider id never maps to a canonical id** (unmapped/new player) — hydration request must skip them silently rather than erroring the whole match-detail response (Task 3's "unmapped player" test).
- **`_PitchPlayer`/`_BenchPlayer` rendered with a raw provider `id` but no `canonicalId` yet (pre-hydration)** — must render exactly as before (no tap, no crash, no dead route), only becoming tappable once hydration fills `canonicalId` on a later refresh (Task 5's "no canonicalId yet" test).

---

## Task 1: Terminal result recovery — user demand + priority reservation

**Files:**
- Create: `supabase/migrations/20260923130000_terminal_result_user_demand.sql`
- Test: `backend/test/terminal_result_user_demand.test.mjs`

**Interfaces:**
- Consumes: `futbeat_private.match_read_model(jsonb)` (`supabase/migrations/20260922220000_terminal_evidence_read_model.sql:19`, returns `status`/`hasPlayedEvidence`), `futbeat_private.quota_decision(provider,kind,class)`, `futbeat_private.wake_provider_worker(trigger)`, `futbeat_private.calendar_matches(match_id,start_time)`, `futbeat_private.calendar_coverage(provider,provider_date,fixtures_complete,results_complete,results_checked_at)`, `futbeat_private.results_date_attempts(provider,provider_date,next_retry_at)`.
- Produces: `public.futbeat_request_terminal_result(p_match_id text) returns jsonb` — `{resultsPending: boolean, reason?: text, providerDate?: date}`, called by Task 2. `futbeat_private.reserve_goal_results_date` keeps its existing signature/return shape (`{allowed, reservationId?, date?, reason?, usedToday, providerRemaining}`) so `syncOneResultsDate` in the worker (`supabase/functions/futbeat-goal-live-sync/index.ts:550`) needs no change.

- [ ] **Step 1: Write the migration — schema, request RPC, and the priority-aware reservation rewrite**

```sql
-- supabase/migrations/20260923130000_terminal_result_user_demand.sql
--
-- Terminal result recovery on user demand. Opening a historical match whose
-- kickoff has passed but has no terminal evidence (still shows "Marcador
-- parcial") elevates that whole GOAL provider-date for result recovery,
-- instead of one call per match. Never infers FINISHED from the clock or
-- score; only a fresh GOAL /results/date fetch can promote status.
--
-- Reservation order (lower first) via futbeat_private.reserve_goal_results_date:
--   1 date opened by a user in the last 24h, not yet re-checked since then
--   2 date with the most currently-unresolved matches (background)
--   3 most recent uncomplete date (background)
-- All reservations pass through the central quota manager (class 'results',
-- safety cap 'results-date'), replacing the old fixed 60/day + remaining<=120
-- guard. A date already flagged results_complete never re-enters the queue
-- (0 provider calls). A date with a pending backoff in results_date_attempts
-- (set by futbeat_complete_results_date_attempt on FAILED/PARTIAL) is skipped
-- until next_retry_at, including for user-requested dates.

alter table futbeat_private.calendar_coverage
  add column if not exists user_requested_at timestamptz,
  add column if not exists user_request_count bigint not null default 0
    check(user_request_count>=0);

update futbeat_private.provider_quota_policy
set kind_daily_caps=kind_daily_caps||'{"results-date":100}'::jsonb,updated_at=now()
where provider='goal_api' and not (kind_daily_caps ? 'results-date');

-- One canonical match -> the GOAL provider-date its kickoff falls in (UTC),
-- the same bucketing calendar_coverage/finalize_goal_results_date already use.
create or replace function futbeat_private.match_provider_date(p_match_id text)
returns date language sql stable set search_path='' as $$
  select (start_time at time zone 'UTC')::date
  from futbeat_private.calendar_matches where match_id=p_match_id
$$;

create or replace function public.futbeat_request_terminal_result(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_payload jsonb;
  v_model jsonb;
  v_status text;
  v_date date;
  v_previous timestamptz;
begin
  select payload into v_payload from futbeat_private.entities
  where id=p_match_id and kind='match';
  if v_payload is null then
    return jsonb_build_object('resultsPending',false,'reason','unknown_match');
  end if;

  v_model:=futbeat_private.match_read_model(v_payload);
  v_status:=v_model->>'status';
  if v_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED',
                  'POSTPONED','SUSPENDED','ABANDONED') then
    return jsonb_build_object('resultsPending',false,'reason','terminal');
  end if;
  if not coalesce((v_model->>'hasPlayedEvidence')::boolean,false) then
    return jsonb_build_object('resultsPending',false,'reason','no_evidence');
  end if;

  v_date:=futbeat_private.match_provider_date(p_match_id);
  if v_date is null then
    return jsonb_build_object('resultsPending',false,'reason','unscheduled');
  end if;

  perform pg_advisory_xact_lock(hashtext('futbeat-terminal-result-request'),hashtext(v_date::text));
  select user_requested_at into v_previous from futbeat_private.calendar_coverage
  where provider='goal_api' and provider_date=v_date;

  insert into futbeat_private.calendar_coverage(
    provider,provider_date,fetched_at,fixture_count,fixtures_complete,
    results_complete,user_requested_at,user_request_count
  ) values('goal_api',v_date,now(),0,true,false,now(),1)
  on conflict(provider,provider_date) do update set
    user_requested_at=now(),
    user_request_count=futbeat_private.calendar_coverage.user_request_count+1;

  if v_previous is not null and v_previous>now()-interval '5 minutes' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('terminal_result_user_demands');
    perform futbeat_private.wake_provider_worker('results');
  end if;

  return jsonb_build_object('resultsPending',true,'providerDate',v_date);
end
$$;

-- Priority-aware, quota-class-backed rewrite of the results-date reservation.
-- Same signature/return shape the worker already calls.
create or replace function futbeat_private.reserve_goal_results_date(
  p_trigger_source text default 'supabase-cron'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_date date; v_id bigint; v_cap jsonb; v_remaining integer; v_used integer;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  v_cap:=futbeat_private.quota_decision('goal_api','results-date','results');
  v_remaining:=(v_cap->>'providerRemaining')::integer;
  v_used:=(v_cap->>'usedToday')::integer;
  if not (v_cap->>'allowed')::boolean then
    return v_cap||jsonb_build_object('allowed',false);
  end if;

  select c.provider_date into v_date
  from futbeat_private.calendar_coverage c
  left join futbeat_private.results_date_attempts a
    on a.provider='goal_api' and a.provider_date=c.provider_date
  where c.provider='goal_api' and c.fixtures_complete and not c.results_complete
    and c.provider_date<(now() at time zone 'UTC')::date
    and (a.next_retry_at is null or a.next_retry_at<=now())
    and (
      (c.user_requested_at is not null and c.user_requested_at>now()-interval '24 hours'
        and (c.results_checked_at is null or c.results_checked_at<c.user_requested_at))
      or (c.results_checked_at is null or c.results_checked_at<now()-interval '6 hours')
    )
  order by
    (c.user_requested_at is not null and c.user_requested_at>now()-interval '24 hours') desc,
    coalesce(c.user_requested_at,'-infinity') desc,
    (select count(*) from futbeat_private.calendar_matches cm join futbeat_private.entities e
       on e.id=cm.match_id and e.kind='match'
     where cm.start_time>=c.provider_date::timestamp at time zone 'UTC'
       and cm.start_time<(c.provider_date+1)::timestamp at time zone 'UTC'
       and coalesce(e.payload->>'status','') not in
         ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')) desc,
    c.provider_date desc
  limit 1;

  if v_date is null then
    return jsonb_build_object('allowed',false,'reason','no_results_due',
      'usedToday',v_used,'providerRemaining',v_remaining);
  end if;

  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),jsonb_build_object('date',v_date))
  returning id into v_id;
  update futbeat_private.calendar_coverage set results_checked_at=now()
   where provider='goal_api' and provider_date=v_date;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'usedToday',v_used+1,'providerRemaining',v_remaining);
end $$;

-- The dedicated wake lane for terminal-result recovery, separate from the
-- match-detail/player 'demand' lane so opening a stale historical match
-- never competes with a live Match Center's detail refresh budget.
create or replace function futbeat_private.wake_provider_worker(p_trigger text default 'demand')
returns text language plpgsql security definer set search_path='' as $$
declare debounce interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','wakeDebounceSeconds',15));
  last_wake timestamptz; url text; result text;
begin
  if p_trigger is null or p_trigger not in ('demand','results') then raise exception 'Invalid wake trigger'; end if;
  select w.last_wake_at into last_wake from futbeat_private.worker_wakeups w
  where w.trigger=p_trigger for update skip locked;
  if not found then
    if exists(select 1 from futbeat_private.worker_wakeups where trigger=p_trigger) then
      perform futbeat_private.bump_metric('wake_debounced');
      return 'debounced';
    end if;
    insert into futbeat_private.worker_wakeups(trigger,last_wake_at,wake_count)
    values(p_trigger,now(),1) on conflict(trigger) do nothing;
    if not found then
      perform futbeat_private.bump_metric('wake_debounced');
      return 'debounced';
    end if;
  elsif last_wake>now()-debounce then
    perform futbeat_private.bump_metric('wake_debounced');
    return 'debounced';
  else
    update futbeat_private.worker_wakeups set last_wake_at=now(),wake_count=wake_count+1 where trigger=p_trigger;
  end if;
  select value into url from futbeat_private.runtime_settings where key='goal_worker_url';
  if to_regnamespace('net') is null or to_regnamespace('vault') is null or url is null then
    result:='unavailable';
  else
    execute $q$select net.http_post(
        url:=$1,
        headers:=jsonb_build_object('Content-Type','application/json','x-futbeat-cron-token',(
          select decrypted_secret from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token' order by updated_at desc nulls last,created_at desc limit 1)),
        body:=jsonb_build_object('trigger',$2),
        timeout_milliseconds:=30000)$q$ using url,p_trigger;
    result:='queued';
  end if;
  update futbeat_private.worker_wakeups set last_result=result where trigger=p_trigger;
  return result;
end $$;

revoke all on function futbeat_private.match_provider_date(text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_request_terminal_result(text)
from public,anon,authenticated;
grant execute on function public.futbeat_request_terminal_result(text) to service_role;

notify pgrst,'reload schema';
```

- [ ] **Step 2: Write the backend tests**

```js
// backend/test/terminal_result_user_demand.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

let seq = 0;
async function seedPartialMatch(db, { startOffsetHours = -30, status = 'SCHEDULED', withScore = true } = {}) {
  const n = ++seq;
  const comp = `fb_comp_tr_${n}`, home = `fb_team_tr_h${n}`, away = `fb_team_tr_a${n}`, match = `fb_match_tr_${n}`;
  const start = new Date(Date.now() + startOffsetHours * 3600000).toISOString();
  const score = withScore ? { home: 1, away: 0 } : undefined;
  for (const [id, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Home ${n}` }],
    [away, 'team', { id: away, name: `Away ${n}` }],
    [match, 'match', { id: match, competitionId: comp, homeTeamId: home, awayTeamId: away,
      startTime: start, status, ...(score ? { score } : {}), events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.calendar_matches(match_id,start_time,source,updated_at) values($1,$2,'test',now())",
    [match, start]);
  return match;
}

const request = (db, match) =>
  db.query('select public.futbeat_request_terminal_result($1) v', [match]).then((r) => r.rows[0].v);
const reserve = (db) =>
  db.query("select futbeat_private.reserve_goal_results_date('test') v").then((r) => r.rows[0].v);
const metric = (db, name) =>
  db.query('select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1', [name])
    .then((r) => r.rows[0].n);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('unknown match: no crash, no demand', () => withDb(async (db) => {
  const result = await request(db, 'fb_match_does_not_exist');
  assert.deepEqual(result, { resultsPending: false, reason: 'unknown_match' });
}));

test('match not indexed in calendar_matches: reports unscheduled, no crash, no coverage row', () => withDb(async (db) => {
  await db.query("insert into futbeat_private.entities values('fb_match_unindexed','match',$1)", [
    JSON.stringify({ id: 'fb_match_unindexed', competitionId: 'fb_comp_x', homeTeamId: 'fb_home_x',
      awayTeamId: 'fb_away_x', startTime: new Date(Date.now() - 30 * 3600000).toISOString(),
      status: 'SCHEDULED', score: { home: 1, away: 0 }, events: [], statistics: [] }),
  ]);
  const result = await request(db, 'fb_match_unindexed');
  assert.deepEqual(result, { resultsPending: false, reason: 'unscheduled' });
  assert.equal((await db.query('select count(*)::int n from futbeat_private.calendar_coverage')).rows[0].n, 0);
}));

test('CANCELLED/POSTPONED/SUSPENDED matches are treated as terminal, never re-queued', () => withDb(async (db) => {
  for (const status of ['CANCELLED', 'POSTPONED', 'SUSPENDED']) {
    const match = await seedPartialMatch(db, { status });
    const result = await request(db, match);
    assert.deepEqual(result, { resultsPending: false, reason: 'terminal' }, status);
  }
  assert.equal((await db.query('select count(*)::int n from futbeat_private.calendar_coverage')).rows[0].n, 0);
}));

test('terminal result real -> Finalizado: once GOAL evidence lands, match_read_model reports it terminal', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const { providerDate } = await request(db, match);
  const plan = await reserve(db);
  assert.equal(plan.allowed, true);
  assert.equal(plan.date, providerDate);

  // Simulate the worker's GOAL fetch landing real terminal evidence for the date.
  await db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,minute,raw_payload,payload_hash)
    values('goal_api','ext-finalize-test',$1,now(),'VERIFIED',2,1,90,'{}',md5(random()::text)||md5(clock_timestamp()::text))`,
    [match]);
  await db.query('select futbeat_private.finalize_goal_results_date($1,now())', [providerDate]);

  const status = (await db.query('select payload->>\'status\' s from futbeat_private.entities where id=$1', [match])).rows[0].s;
  assert.equal(status, 'VERIFIED');
  const stillDue = await request(db, match);
  assert.deepEqual(stillDue, { resultsPending: false, reason: 'terminal' });
}));

test('score + past kickoff + no terminal evidence: still partial, records date demand', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const result = await request(db, match);
  assert.equal(result.resultsPending, true);
  assert.ok(result.providerDate);
  const row = (await db.query('select user_request_count::int n,fixtures_complete,results_complete from futbeat_private.calendar_coverage where provider_date=$1', [result.providerDate])).rows[0];
  assert.deepEqual(row, { n: 1, fixtures_complete: true, results_complete: false });
  assert.equal(await metric(db, 'terminal_result_user_demands'), 1);
}));

test('terminal evidence already present: 0 provider calls, no demand', () => withDb(async (db) => {
  const match = await seedPartialMatch(db, { status: 'VERIFIED' });
  const result = await request(db, match);
  assert.deepEqual(result, { resultsPending: false, reason: 'terminal' });
  assert.equal((await db.query('select count(*)::int n from futbeat_private.calendar_coverage')).rows[0].n, 0);
}));

test('20 partial matches same date: opening several dedupes to one date demand, one wake', () => withDb(async (db) => {
  const matches = [];
  for (let i = 0; i < 20; i++) matches.push(await seedPartialMatch(db, { startOffsetHours: -25 - i / 60 }));
  for (const m of matches) await request(db, m);
  const rows = (await db.query('select provider_date,user_request_count::int n from futbeat_private.calendar_coverage')).rows;
  assert.equal(rows.length, 1, 'all 20 matches bucket into the same provider_date');
  assert.equal(rows[0].n, 20);
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='results'")).rows[0].n, 1);
}));

test('user-opened date is reserved before an older date with fewer partials', () => withDb(async (db) => {
  const older = await seedPartialMatch(db, { startOffsetHours: -80 });
  await db.query(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count,fixtures_complete,results_complete)
    values('goal_api',$1,now()-interval '1 day',1,true,false)`,
    [(await db.query('select futbeat_private.match_provider_date($1) v', [older])).rows[0].v]);
  const userMatch = await seedPartialMatch(db, { startOffsetHours: -30 });
  const requested = await request(db, userMatch);
  const plan = await reserve(db);
  assert.equal(plan.allowed, true);
  assert.equal(plan.date, requested.providerDate);
}));

test('date in backoff is skipped even when user-requested', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const { providerDate } = await request(db, match);
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at)
    values('goal_api',$1,now(),1,'FAILED',now()+interval '1 hour')
    on conflict(provider,provider_date) do update set next_retry_at=excluded.next_retry_at`, [providerDate]);
  const plan = await reserve(db);
  assert.equal(plan.allowed, false);
  assert.equal(plan.reason, 'no_results_due');
}));

test('quota class results: reservation is refused once remaining is at or below its floor (20)', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  await request(db, match);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,
    reserved_at,completed_at,status,provider_remaining) values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',15)`);
  const plan = await reserve(db);
  assert.equal(plan.allowed, false);
  assert.equal(plan.reason, 'provider_remaining_reserve');
}));

test('same date requested twice within 5 minutes dedupes (no second wake)', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  await request(db, match);
  const second = await seedPartialMatch(db, { startOffsetHours: -30.1 });
  await request(db, second);
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='results'")).rows[0].n, 1);
  assert.equal(await metric(db, 'deduped_requests'), 1);
}));
```

- [ ] **Step 3: Run the new tests**

Run: `node --test backend/test/terminal_result_user_demand.test.mjs`
Expected: all 8 tests PASS.

- [ ] **Step 4: Run the full backend suite to confirm no regression in existing results/quota tests**

Run: `npm test --prefix backend`
Expected: all tests PASS (in particular `calendar_demand.test.mjs`, `terminal_result_evidence.test.mjs`, `terminal_result_writes.test.mjs`, any existing `results_date` test).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260923130000_terminal_result_user_demand.sql backend/test/terminal_result_user_demand.test.mjs
git commit -m "feat: elevate terminal-result recovery by date on user demand"
```

---

## Task 2: Wire terminal-result demand into futbeat-api

**Files:**
- Modify: `supabase/functions/futbeat-api/index.ts:175-197` (the `/futbeat-api/v1/match-context` route)
- Test: `backend/test/terminal_result_user_demand.test.mjs` (append)

**Interfaces:**
- Consumes: `public.futbeat_request_terminal_result(p_match_id text)` (Task 1).
- Produces: no new response field is required by the client for this task — the call is fire-and-forget bookkeeping exactly like `/v1/entity`'s player-profile demand call, so `match_read_model`'s own status/`hasPlayedEvidence` (already returned by `futbeat_read_match_context`) is what eventually flips once the worker lands real data on a later poll.

- [ ] **Step 1: Modify the match-context route**

In `supabase/functions/futbeat-api/index.ts`, replace:

```ts
    if (path.endsWith('/futbeat-api/v1/match-context')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return reply(400, { error: 'Partido inválido' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_match_context',
        { p_match_id: id },
      );
```

with:

```ts
    if (path.endsWith('/futbeat-api/v1/match-context')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return reply(400, { error: 'Partido inválido' });
      }

      // Opening a historical partial match elevates that day's terminal-result
      // recovery (server-side only, deduped by date). Best-effort: a failure
      // here never blocks the read.
      ctx.supabaseAdmin
        .rpc('futbeat_request_terminal_result', { p_match_id: id })
        .then(({ error: demandError }) => {
          if (demandError) console.warn('terminal result demand unavailable');
        });

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_match_context',
        { p_match_id: id },
      );
```

- [ ] **Step 2: Write a source-level wiring test (same pattern as `calendar_demand.test.mjs`'s API wiring check)**

```js
// append to backend/test/terminal_result_user_demand.test.mjs
import { readFile } from 'node:fs/promises';

test('match-context API route requests terminal result recovery', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /futbeat_request_terminal_result/);
  assert.ok(
    source.indexOf("/futbeat-api/v1/match-context") <
      source.indexOf("futbeat_request_terminal_result"),
    'terminal result demand must run inside the match-context route',
  );
});
```

- [ ] **Step 3: Run the test**

Run: `node --test backend/test/terminal_result_user_demand.test.mjs`
Expected: PASS (9 tests total).

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/futbeat-api/index.ts backend/test/terminal_result_user_demand.test.mjs
git commit -m "feat: request terminal-result recovery when Match Center opens"
```

---

## Task 3: Lineup player hydration demand

**Files:**
- Create: `supabase/migrations/20260923140000_lineup_player_hydration.sql`
- Test: `backend/test/lineup_player_hydration.test.mjs`

**Interfaces:**
- Consumes: `futbeat_private.player_hydration_due(text)`, `futbeat_private.quota_decision`, `futbeat_private.wake_provider_worker('demand')`, `futbeat_private.provider_entities`, `futbeat_private.player_profile_coverage` (`supabase/migrations/20260923120000_player_on_demand.sql:47-61`), `public.futbeat_reserve_player_call` (same file, line 266).
- Produces: `public.futbeat_request_lineup_hydration(p_starter_ids text[], p_bench_ids text[]) returns jsonb` — `{enrichmentPending: boolean}`, called by Task 4 with **canonical** player ids (not provider ids). `player_profile_coverage.priority` (smallint, lower = more urgent, default 100) — consumed by the reservation ordering below.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/20260923140000_lineup_player_hydration.sql
--
-- Lineup player hydration on match-detail demand. Match Center already
-- resolves each lineup player's canonicalId and available media via
-- futbeat_read_lineup_player_media (preserve_match_detail_and_lineup_identity
-- .sql:114, player_media_squad_coverage.sql:232). When a canonical player is
-- missing a verified photo, this reuses the existing player on-demand
-- pipeline (player_on_demand.sql) instead of one call per lineup player: one
-- RPC call from futbeat-api registers up to 60 canonical ids at once,
-- deduped per player, leased, and drained by the same
-- futbeat_reserve_player_call the worker already runs every demand cycle.
-- Starters are prioritized over bench so the most visible photos land first.

alter table futbeat_private.player_profile_coverage
  add column if not exists priority smallint not null default 100;

create or replace function public.futbeat_request_lineup_hydration(
  p_starter_ids text[] default null,
  p_bench_ids text[] default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  pid text; v_priority smallint; ext text; due jsonb;
  previous timestamptz; lease_at timestamptz; any_pending boolean:=false;
begin
  for pid,v_priority in
    select s.player_id,s.priority from (
      select unnest(coalesce(p_starter_ids,array[]::text[])) player_id,1::smallint priority
      union all
      select unnest(coalesce(p_bench_ids,array[]::text[])),2::smallint
    ) s
    where s.player_id is not null and s.player_id<>''
    limit 60
  loop
    select external_id into ext from futbeat_private.provider_entities
    where provider='goal_api' and kind='player' and canonical_id=pid
    order by external_id limit 1;
    if ext is null then continue; end if;

    due:=futbeat_private.player_hydration_due(pid);
    if not coalesce((due->>'profileDue')::boolean,false) then continue; end if;
    if not coalesce((futbeat_private.quota_decision('goal_api','player-profile','user')->>'allowed')::boolean,false) then
      continue;
    end if;

    select requested_at,lease_until into previous,lease_at
    from futbeat_private.player_profile_coverage where player_id=pid;
    insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count,priority)
    values(pid,ext,now(),1,v_priority)
    on conflict(player_id) do update set
      requested_at=now(),
      external_id=excluded.external_id,
      request_count=futbeat_private.player_profile_coverage.request_count+1,
      priority=least(futbeat_private.player_profile_coverage.priority,excluded.priority);

    if lease_at>now() or previous>now()-interval '1 minute' then
      perform futbeat_private.bump_metric('deduped_requests');
    else
      perform futbeat_private.bump_metric('lineup_player_hydration_demands');
      any_pending:=true;
    end if;
  end loop;

  if any_pending then perform futbeat_private.wake_provider_worker('demand'); end if;
  return jsonb_build_object('enrichmentPending',any_pending);
end
$$;

-- Starters/urgent hydration first, then freshest demand, matching the
-- priority most recently requested by lineup hydration or player-profile.
create or replace function public.futbeat_reserve_player_call(p_trigger_source text default 'supabase-cron')
returns jsonb language plpgsql security definer set search_path='' as $$
declare window_start timestamptz:=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','demandWindowMinutes',30)::integer);
  lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  decision jsonb; last_decision jsonb; demand futbeat_private.player_search_demands; player record; id bigint;
begin
  if nullif(btrim(p_trigger_source),'') is null then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  delete from futbeat_private.player_search_demands where query_key in (
    select query_key from futbeat_private.player_search_demands
    where (status='QUEUED' and last_attempt_at is null and requested_at<=window_start)
       or (status<>'QUEUED' and coalesce(next_retry_at,last_attempt_at,requested_at)<now()-interval '30 days')
    limit 500);

  decision:=futbeat_private.quota_decision('goal_api','player-search','user');
  last_decision:=decision;
  if (decision->>'allowed')::boolean then
    select * into demand from futbeat_private.player_search_demands
    where status='QUEUED' and requested_at>window_start and coalesce(lease_until,'-infinity')<=now()
      and coalesce(next_retry_at,'-infinity')<=now()
    order by requested_at>now()-interval '1 minute' desc,least(request_count,5) desc,requested_at desc,query_key
    limit 1 for update skip locked;
    if demand.query_key is not null then
      update futbeat_private.player_search_demands set lease_until=now()+lease,last_attempt_at=now()
      where query_key=demand.query_key;
      insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
      values('goal_api','player-search',left(p_trigger_source,40),now(),
        jsonb_build_object('queryKey',demand.query_key,'query',demand.query_text))
      returning provider_call_ledger.id into id;
      return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind','player-search',
        'query',demand.query_text,'queryKey',demand.query_key);
    end if;
  end if;

  for player in
    select c.player_id,c.external_id,(d->>'profileDue')::boolean profile_due,(d->>'statsDue')::boolean stats_due
    from futbeat_private.player_profile_coverage c
    cross join lateral futbeat_private.player_hydration_due(c.player_id) d
    where c.requested_at>window_start and coalesce(c.lease_until,'-infinity')<=now()
      and ((d->>'profileDue')::boolean or (d->>'statsDue')::boolean)
    order by c.priority,c.requested_at desc,c.player_id
    limit 20
  loop
    decision:=futbeat_private.quota_decision('goal_api',
      case when player.profile_due then 'player-profile' else 'player-stats' end,'user');
    last_decision:=decision;
    if not (decision->>'allowed')::boolean then continue; end if;
    update futbeat_private.player_profile_coverage set lease_until=now()+lease where player_id=player.player_id;
    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
    values('goal_api',decision->>'kind',left(p_trigger_source,40),now(),
      jsonb_build_object('playerId',player.player_id,'externalPlayerId',player.external_id))
    returning provider_call_ledger.id into id;
    return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind',decision->>'kind',
      'playerId',player.player_id,'externalPlayerId',player.external_id);
  end loop;

  return jsonb_build_object('allowed',false,'reason',
    case when last_decision->>'reason' is not null and not (last_decision->>'allowed')::boolean
      then last_decision->>'reason' else 'no_player_demand' end,
    'providerRemaining',last_decision->'providerRemaining');
end $$;

revoke all on function public.futbeat_request_lineup_hydration(text[],text[])
from public,anon,authenticated;
grant execute on function public.futbeat_request_lineup_hydration(text[],text[]) to service_role;

notify pgrst,'reload schema';
```

- [ ] **Step 2: Write the backend tests**

```js
// backend/test/lineup_player_hydration.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

let seq = 0;
async function seedCanonicalPlayer(db, { withMedia = false } = {}) {
  const n = ++seq;
  const id = `fb_player_lh_${n}`;
  const payload = { id, name: `Jugador ${n}`, teamId: `fb_team_lh_${n}`,
    ...(withMedia ? { media: { url: `https://media.goal-api.com/players/${n}.png`,
      verificationStatus: 'VERIFIED' } } : {}) };
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
    "update futbeat_private.entities set payload=payload||jsonb_build_object('media',jsonb_build_object('url',$2,'verificationStatus','VERIFIED')) where id=$1",
    [player, 'https://media.goal-api.com/players/hydrated.png'],
  );

  const after = (await db.query(
    "select futbeat_private.futbeat_read_lineup_player_media('goal_api',array['ext-lh-'||$1]) v",
    [player.split('_').pop()],
  )).rows[0].v[`ext-lh-${player.split('_').pop()}`];
  assert.equal(after.image, 'https://media.goal-api.com/players/hydrated.png');
}));
```

- [ ] **Step 3: Run the new tests**

Run: `node --test backend/test/lineup_player_hydration.test.mjs`
Expected: all 6 tests PASS.

- [ ] **Step 4: Run the full backend suite**

Run: `npm test --prefix backend`
Expected: all tests PASS, including `player_on_demand.test.mjs` (the priority column/ORDER BY change must not break its existing ordering assertions — re-check `order by c.requested_at desc,c.player_id` cases there still hold since untouched rows keep `priority=100`, a constant, so ties still break by `requested_at desc,player_id` as before).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260923140000_lineup_player_hydration.sql backend/test/lineup_player_hydration.test.mjs
git commit -m "feat: hydrate missing lineup player photos on demand, starters first"
```

---

## Task 4: Wire lineup hydration into futbeat-api match-detail and expose it to Flutter

**Files:**
- Modify: `supabase/functions/_shared/match_detail.ts` (add `lineupPlayerIdsBySection`)
- Modify: `supabase/functions/futbeat-api/index.ts:199-257` (the `/futbeat-api/v1/match-detail` route)
- Modify: `apps/mobile/lib/core/models.dart:178-240` (`MatchDetail` class)
- Test: `backend/test/match_detail_normalizers.test.mjs` (append), `backend/test/lineup_player_hydration.test.mjs` (append wiring test), `apps/mobile/test/match_status_copy_test.dart` (append)

**Interfaces:**
- Consumes: `public.futbeat_request_lineup_hydration(text[],text[])` (Task 3).
- Produces: `lineupPlayerIdsBySection(raw): {starters: string[], substitutes: string[]}` (shared TS helper). Match-detail JSON response gains `coverage.lineupEnrichmentPending: boolean` when set. `MatchDetail.lineupEnrichmentPending` (Dart bool getter) — consumed by Task 6.

- [ ] **Step 1: Add `lineupPlayerIdsBySection` to the shared normalizer module**

In `supabase/functions/_shared/match_detail.ts`, immediately after the existing `lineupPlayerIds` function (ends at line 139), add:

```ts
// Same extraction as lineupPlayerIds, split by section so the caller can
// prioritize starters over bench when registering hydration demand.
export function lineupPlayerIdsBySection(raw: unknown) {
  const payload = asRecord(asRecord(raw).payload);
  const lineups = payload.lineups;
  const starters = new Set<string>();
  const substitutes = new Set<string>();
  const add = (set: Set<string>, value: unknown) => {
    const row = asRecord(value);
    const nested = asRecord(row.player);
    const id = cleanText(row.playerId) || cleanText(row.playerKey) || cleanText(nested.id);
    if (id) set.add(id);
  };
  if (Array.isArray(lineups)) {
    for (const row of lineups.map(asRecord)) {
      const section = lineupSection(row.type);
      if (section === 'starters') add(starters, row);
      else if (section === 'substitutes') add(substitutes, row);
    }
  } else {
    const root = asRecord(lineups);
    for (const side of ['home', 'away']) {
      const team = asRecord(root[side]);
      asList(team.startingLineups).forEach((row) => add(starters, row));
      asList(team.substitutes).forEach((row) => add(substitutes, row));
    }
  }
  return {
    starters: [...starters].slice(0, 30),
    substitutes: [...substitutes].slice(0, 30),
  };
}
```

- [ ] **Step 2: Wire hydration demand into the match-detail route**

In `supabase/functions/futbeat-api/index.ts`, update the import at the top of the file:

```ts
import {
  asRecord,
  cleanText,
  lineupPlayerIds,
  lineupPlayerIdsBySection,
  normalizeMatchDetail,
  safeImage,
  type PlayerMedia,
} from '../_shared/match_detail.ts';
```

Then replace the tail of the `/futbeat-api/v1/match-detail` block (from `let playerMedia: PlayerMedia = {};` through the final `return replyNoStore(...)`):

```ts
      let playerMedia: PlayerMedia = {};
      const playerIds = lineupPlayerIds(detail);
      if (playerIds.length > 0) {
        const { data: media, error: mediaError } = await ctx.supabaseAdmin.rpc(
          'futbeat_read_lineup_player_media',
          { p_provider: 'goal_api', p_external_ids: playerIds },
        );
        if (mediaError) {
          console.warn('lineup player media unavailable');
        } else {
          playerMedia = asRecord(media) as PlayerMedia;
        }
      }

      let lineupEnrichmentPending = false;
      const { starters, substitutes } = lineupPlayerIdsBySection(detail);
      const missingCanonicalIds = (ids: string[]) =>
        ids
          .map((id) => asRecord(playerMedia[id]))
          .filter((entry) => cleanText(entry.canonicalId) && !safeImage(entry.image))
          .map((entry) => cleanText(entry.canonicalId));
      const starterIds = missingCanonicalIds(starters);
      const benchIds = missingCanonicalIds(substitutes);
      if (starterIds.length > 0 || benchIds.length > 0) {
        const { data: hydration, error: hydrationError } = await ctx.supabaseAdmin.rpc(
          'futbeat_request_lineup_hydration',
          { p_starter_ids: starterIds, p_bench_ids: benchIds },
        );
        if (hydrationError) {
          console.warn('lineup player hydration demand unavailable');
        } else {
          lineupEnrichmentPending = asRecord(hydration).enrichmentPending === true;
        }
      }

      const normalized = normalizeMatchDetail(detail, videosError ? [] : videos, playerMedia) as Record<string, unknown>;
      if (lineupEnrichmentPending) {
        // Partial lineup photos now; the app refreshes once hydration lands.
        normalized.coverage = { ...asRecord(normalized.coverage), lineupEnrichmentPending: true };
      }
      return replyNoStore(200, normalized);
```

- [ ] **Step 3: Add the Dart getters**

In `apps/mobile/lib/core/models.dart`, inside `class MatchDetail` (after the existing `String? get round => _optional(json['round']);` line), add:

```dart
  Json? get coverage => _nullableMap(json['coverage']);
  bool get lineupEnrichmentPending => coverage?['lineupEnrichmentPending'] == true;
```

- [ ] **Step 4: Write the tests**

```js
// append to backend/test/match_detail_normalizers.test.mjs
test('lineupPlayerIdsBySection splits starters/substitutes for both raw shapes', async () => {
  const { lineupPlayerIdsBySection } = await import('../../supabase/functions/_shared/match_detail.ts');
  const arrayLineups = [
    { team: 'home', type: 'starting', playerId: 'p1' },
    { team: 'home', type: 'sub', playerId: 'p2' },
    { team: 'away', type: 'starting', playerId: 'p3' },
  ];
  assert.deepEqual(lineupPlayerIdsBySection({ payload: { lineups: arrayLineups } }), {
    starters: ['p1', 'p3'], substitutes: ['p2'],
  });
  const objectLineups = {
    home: { startingLineups: [{ playerId: 'a' }], substitutes: [{ playerId: 'b' }] },
    away: { startingLineups: [{ playerId: 'c' }], substitutes: [] },
  };
  assert.deepEqual(lineupPlayerIdsBySection({ payload: { lineups: objectLineups } }), {
    starters: ['a', 'c'], substitutes: ['b'],
  });
});
```

```js
// append to backend/test/lineup_player_hydration.test.mjs
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
```

```dart
// append to apps/mobile/test/match_status_copy_test.dart
import 'package:futbeat/core/models.dart';

void main() {
  // ... existing tests above ...

  test('MatchDetail.lineupEnrichmentPending reads coverage.lineupEnrichmentPending', () {
    final pending = MatchDetail({...MatchDetail.empty('fb_match').json,
      'coverage': {'lineupEnrichmentPending': true}});
    expect(pending.lineupEnrichmentPending, isTrue);

    final settled = MatchDetail(MatchDetail.empty('fb_match').json);
    expect(settled.lineupEnrichmentPending, isFalse);
  });
}
```

If `match_status_copy_test.dart` does not already have a single top-level `void main()` wrapping its tests, add the new `test(...)` block inside the existing `main()` instead of declaring a second one (Dart allows only one `main` per file).

- [ ] **Step 5: Run the tests**

Run: `node --test backend/test/match_detail_normalizers.test.mjs backend/test/lineup_player_hydration.test.mjs`
Expected: PASS.

Run: `flutter test test/match_status_copy_test.dart` (from `apps/mobile`)
Expected: PASS.

- [ ] **Step 6: Run full suites**

Run: `npm test --prefix backend` and `flutter test` (from `apps/mobile`)
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add supabase/functions/_shared/match_detail.ts supabase/functions/futbeat-api/index.ts apps/mobile/lib/core/models.dart backend/test/match_detail_normalizers.test.mjs backend/test/lineup_player_hydration.test.mjs apps/mobile/test/match_status_copy_test.dart
git commit -m "feat: request lineup photo hydration from match-detail, surface coverage flag"
```

---

## Task 5: Tap a lineup player to open their profile, plus photo regression tests

**Files:**
- Modify: `apps/mobile/lib/features/matches/match_screen.dart:1824-1888` (`_PitchPlayer`), `:1927-1976` (`_BenchPlayer`)
- Test: `apps/mobile/test/match_center_player_navigation_test.dart` (new)

**Interfaces:**
- Consumes: `player['canonicalId']` (already emitted by `normalizeLineupPlayer`, `supabase/functions/_shared/match_detail.ts:41`), GoRouter route `/player/:id` (`apps/mobile/lib/main.dart:63-68`).
- Produces: nothing new consumed elsewhere; this is leaf UI behavior.

- [ ] **Step 1: Make `_PitchPlayer` tappable via `canonicalId`**

In `apps/mobile/lib/features/matches/match_screen.dart`, replace the `_PitchPlayer` class body:

```dart
class _PitchPlayer extends StatelessWidget {
  const _PitchPlayer(this.player, {required this.events});

  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) {
    final name = player['name']?.toString() ?? 'Jugador';
    final number = player['number']?.toString().trim() ?? '';
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;

    final content = Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 6),
                ],
              ),
              child: _PlayerAvatar(player, size: 42),
            ),
            if (number.isNotEmpty)
              Positioned(left: -7, bottom: -3, child: _NumberBadge(number)),
            if (player['rating'] is num)
              Positioned(
                right: -9,
                top: -5,
                child: _RatingBadge(player['rating'] as num),
              ),
            if (player['captain'] == true)
              const Positioned(left: -7, top: -5, child: _CaptainBadge()),
          ],
        ),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .38),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            _pitchName(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (events.isNotEmpty) ...[
          const SizedBox(height: 3),
          _PlayerEvents(events),
        ],
      ],
    );

    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}
```

- [ ] **Step 2: Make `_BenchPlayer` tappable via `canonicalId`**

Replace the `_BenchPlayer` class body:

```dart
class _BenchPlayer extends StatelessWidget {
  const _BenchPlayer(this.player, {required this.events});
  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) {
    final number = player['number']?.toString().trim() ?? '';
    final position = _positionLabel(player['position']);
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cardBorder),
      ),
      child: Row(
        children: [
          _PlayerAvatar(player, size: 38),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player['name']?.toString() ?? 'Jugador',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [if (number.isNotEmpty) '#$number', ?position].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
                if (events.isNotEmpty) _PlayerEvents(events),
              ],
            ),
          ),
          if (player['rating'] is num) _RatingBadge(player['rating'] as num),
        ],
      ),
    );

    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}
```

- [ ] **Step 3: Write navigation + photo regression widget tests**

```dart
// apps/mobile/test/match_center_player_navigation_test.dart
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

Map<String, dynamic> _payload() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-23T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba'},
  ],
  'teams': [
    {'id': 'fb_home', 'name': 'Local FC'},
    {'id': 'fb_away', 'name': 'Visita FC'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': DateTime.utc(2026, 9, 20, 18).toIso8601String(),
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': const [],
      'statistics': const [],
    },
  ],
};

Map<String, dynamic> _lineupPlayer({
  required String name,
  String? canonicalId,
  String? image,
  int lineupPosition = 1,
}) => {
  'id': 'ext-$name',
  'canonicalId': canonicalId,
  'name': name,
  'number': '9',
  'position': 'Forward',
  'lineupPosition': lineupPosition,
  'image': image,
};

Map<String, dynamic> _detail({
  required Map<String, dynamic> starter,
  required Map<String, dynamic> bench,
}) => {
  'matchId': 'fb_match',
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'home': {
    'formation': '4-3-3',
    'starters': [starter],
    'substitutes': [bench],
  },
  'away': <String, dynamic>{},
  'statistics': const [],
  'incidents': const [],
};

Future<void> _pumpMatch(WidgetTester tester, Map<String, dynamic> detail) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  final payload = _payload();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(Dio())),
      matchContextSnapshotProvider.overrideWith((ref, id) async => Snapshot(payload)),
      matchDetailProvider.overrideWith((ref, id) => Stream.value(MatchDetail(detail))),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings,
          builder: (_) => const Scaffold(body: Text('Player profile route')),
        ),
        home: MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starter with canonicalId and canonical photo: tappable, photo renders (cases B1/D1)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Goleador', canonicalId: 'fb_player_1',
          image: 'https://media.goal-api.com/players/1.png'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(find.byWidgetPredicate((w) => w is Image.network && w.image.url.endsWith('1.png')), findsOneWidget);
    final starterInkWell = find.ancestor(of: find.text('Goleador'), matching: find.byType(InkWell)).first;
    expect(starterInkWell, findsOneWidget);
  });

  testWidgets('bench player with canonical photo renders it (case D2)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Titular', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Con Foto', canonicalId: 'fb_player_2', lineupPosition: 2,
          image: 'https://media.goal-api.com/players/2.png'),
      ),
    );
    expect(find.byWidgetPredicate((w) => w is Image.network && w.image.url.endsWith('2.png')), findsOneWidget);
  });

  testWidgets('player without any photo shows initials, not a broken image (case D4)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Sin Foto', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(find.text('SF'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('tapping a starter with canonicalId navigates to /player/<canonicalId> (case C, F)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Goleador', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    await tester.tap(find.text('Goleador'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsOneWidget);
  });

  testWidgets('tapping a bench player with canonicalId navigates to /player/<canonicalId> (case C, F)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Titular', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    await tester.tap(find.text('Suplente'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsOneWidget);
  });

  testWidgets('player without canonicalId yet: not tappable, no crash, presentation unchanged (review focus)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Pendiente', canonicalId: null),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(find.text('Pendiente'), findsOneWidget);
    final pendienteInkWell = find.ancestor(of: find.text('Pendiente'), matching: find.byType(InkWell));
    expect(pendienteInkWell, findsNothing);
    await tester.tap(find.text('Pendiente'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsNothing);
  });

  testWidgets('renders at 320px and 360px without overflow (case F)', (tester) async {
    for (final width in [320.0, 360.0]) {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      await _pumpMatch(
        tester,
        _detail(
          starter: _lineupPlayer(name: 'Goleador con Nombre Largo', canonicalId: 'fb_player_1'),
          bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
```

- [ ] **Step 4: Run the new tests**

Run: `flutter test test/match_center_player_navigation_test.dart` (from `apps/mobile`)
Expected: all 7 tests PASS.

- [ ] **Step 5: Run the full Flutter suite and analyzer**

Run: `flutter test` and `flutter analyze` (from `apps/mobile`)
Expected: no regressions (in particular `match_center_redesign_test.dart`, `match_center_ui_v4_test.dart`, `match_detail_e2e_test.dart`, which render `_PitchPlayer`/`_BenchPlayer` without `canonicalId` in their fixtures and must keep rendering exactly as before, un-tappable).

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/lib/features/matches/match_screen.dart apps/mobile/test/match_center_player_navigation_test.dart
git commit -m "feat: tap a lineup player to open their real profile via canonicalId"
```

---

## Task 6: Bounded refresh while lineup photos are still hydrating

**Files:**
- Modify: `apps/mobile/lib/features/matches/match_screen.dart` (imports, `_MatchScreenState`)
- Test: `apps/mobile/test/match_center_lineup_enrichment_test.dart` (new)

**Interfaces:**
- Consumes: `MatchDetail.lineupEnrichmentPending` (Task 4), `matchDetailProvider` (`apps/mobile/lib/core/providers.dart:505`).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Add the bounded-refresh timer, mirroring `EntityScreen`'s `_scheduleEnrichmentRefresh`**

In `apps/mobile/lib/features/matches/match_screen.dart`, add the import:

```dart
import 'dart:async';
```

alongside the existing `import 'package:flutter/material.dart';` at the top.

Add a module-level constant right after the existing color constants (after `const awaySideColor = Color(0xFF4FC3F7);`):

```dart
/// Bounded refreshes while the server hydrates missing lineup photos.
/// Same cadence as EntityScreen's profileEnrichmentRetryDelays.
const _lineupEnrichmentRetryDelays = [
  Duration(seconds: 6),
  Duration(seconds: 12),
];
```

In `_MatchScreenState`, add fields next to `_recordedTeamInterests`:

```dart
  Timer? _lineupEnrichmentRetry;
  int _lineupEnrichmentAttempts = 0;
```

Add the scheduling method next to `_syncTabs`:

```dart
  void _scheduleLineupEnrichmentRefresh() {
    if (_lineupEnrichmentRetry != null ||
        _lineupEnrichmentAttempts >= _lineupEnrichmentRetryDelays.length) {
      return;
    }
    _lineupEnrichmentRetry = Timer(
      _lineupEnrichmentRetryDelays[_lineupEnrichmentAttempts],
      () {
        if (!mounted) return;
        setState(() {
          _lineupEnrichmentAttempts++;
          _lineupEnrichmentRetry = null;
        });
        ref.invalidate(matchDetailProvider(widget.id));
      },
    );
  }
```

Update `dispose`:

```dart
  @override
  void dispose() {
    _tabs.dispose();
    _lineupEnrichmentRetry?.cancel();
    super.dispose();
  }
```

In `build`, right after the existing `final updates = ...;` block, add the listener:

```dart
    ref.listen(matchDetailProvider(widget.id), (_, next) {
      // Ignore the refresh-in-progress state (it still carries old data).
      if (!next.isLoading && next.asData?.value.lineupEnrichmentPending == true) {
        _scheduleLineupEnrichmentRefresh();
      }
    });
```

- [ ] **Step 2: Write the test**

```dart
// apps/mobile/test/match_center_lineup_enrichment_test.dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

Map<String, dynamic> _payload() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-23T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba'},
  ],
  'teams': [
    {'id': 'fb_home', 'name': 'Local FC'},
    {'id': 'fb_away', 'name': 'Visita FC'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': DateTime.utc(2026, 9, 20, 18).toIso8601String(),
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': const [],
      'statistics': const [],
    },
  ],
};

Map<String, dynamic> _detail({required bool pending}) => {
  'matchId': 'fb_match',
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const [],
  'incidents': const [],
  'coverage': {'lineupEnrichmentPending': pending},
};

void main() {
  testWidgets('lineupEnrichmentPending schedules a bounded refresh, then stops (no infinite spinner)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    final payload = _payload();
    // Broadcast: ref.invalidate() re-subscribes matchDetailProvider each
    // retry, which a single-subscription StreamController would reject.
    final detailController = StreamController<MatchDetail>.broadcast();
    addTearDown(detailController.close);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(ApiRepository(Dio())),
        matchContextSnapshotProvider.overrideWith((ref, id) async => Snapshot(payload)),
        matchDetailProvider.overrideWith((ref, id) => detailController.stream),
        followsProvider.overrideWith((ref) => Stream.value({})),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(db.close);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
        ),
      ),
    );
    detailController.add(MatchDetail(_detail(pending: true)));
    await tester.pump();
    await tester.pump();

    // Two bounded retries (6s, 12s) then no more, per _lineupEnrichmentRetryDelays.
    await tester.pump(const Duration(seconds: 6));
    detailController.add(MatchDetail(_detail(pending: true)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));
    detailController.add(MatchDetail(_detail(pending: true)));
    await tester.pump();

    // No third timer is scheduled: advancing further does not throw, and
    // flutter_test itself fails this test if any Timer is still pending
    // when it ends, so an unbounded retry loop would fail here.
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 3: Run the test**

Run: `flutter test test/match_center_lineup_enrichment_test.dart` (from `apps/mobile`)
Expected: PASS, no pending timer errors (`flutter_test` fails a test if a `Timer` is still pending when it ends, so this test also proves the retry loop terminates — it would fail loudly if the refresh became unbounded).

- [ ] **Step 4: Run the full Flutter suite**

Run: `flutter test` and `flutter analyze` (from `apps/mobile`)
Expected: all PASS, no analyzer warnings.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/features/matches/match_screen.dart apps/mobile/test/match_center_lineup_enrichment_test.dart
git commit -m "feat: bound Match Center refresh while lineup photos are hydrating"
```

---

## Task 7: Final validation and report

**Files:** none (validation only).

- [ ] **Step 1: Run the full backend suite**

Run: `npm test --prefix backend`
Expected: all tests PASS (0 failures), including every test added in Tasks 1–4 and every pre-existing test (in particular `terminal_result_evidence.test.mjs`, `terminal_result_writes.test.mjs`, `terminal_other_writers.test.mjs`, `match_detail_user_demand.test.mjs`, `player_on_demand.test.mjs`, `calendar_demand.test.mjs`, `match_detail_reservation_concurrency.test.mjs`, `on_demand_hardening.test.mjs`).

- [ ] **Step 2: Run the full Flutter suite and analyzer**

Run (from `apps/mobile`): `flutter test` then `flutter analyze`
Expected: all tests PASS, analyzer reports 0 issues.

- [ ] **Step 3: Check for whitespace/EOF issues across the whole diff**

Run: `git diff --check`
Expected: no output (clean).

- [ ] **Step 4: If any step above failed, fix and re-run before proceeding**

Do not report success until Steps 1–3 all pass cleanly in the same run.

- [ ] **Step 5: Confirm working tree and commit history**

Run: `git status` and `git log --oneline -8`
Expected: working tree clean (everything already committed task-by-task in Tasks 1–6); 6 new commits on top of `c484a6c`, no push performed.

- [ ] **Step 6: Write the final report (max 12 lines, Spanish)**

Cover exactly: terminal recovery, grouping por fecha, lineup hydration, fotos, navegación, quota behavior, tests, migraciones, archivos y riesgos — matching the user's requested report shape. Do not push.

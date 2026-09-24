// Match-detail backlog simulation (local PGlite, simulated provider, no GOAL).
// Usage: node backend/bench/detail_backlog_sim.mjs [minutes] [remaining|unknown]
//
// Seeds a stationary mix of matches around "now" (live, pre-match, upcoming,
// recently finished, history) with a scripted provider truth (whether GOAL
// ever has a lineup / statistics for the match), then simulates the worker
// minute by minute: before each reservation the worker runs the planner
// (futbeat_enqueue_stale_live_detail), and up to WORKER_CALLS reservations
// are served per minute. Time passes by ageing every work timestamp one
// minute per tick (kickoffs stay fixed, so the mix is stationary).
//
// Reports provider calls per bucket, useful calls (a new lineup, statistics
// or events), empty calls, queue depth and user-open latency.
import { openDatabase } from '../storage/database.mjs';

const MINUTES = Number(process.argv[2] ?? 120);
const REMAINING_ARG = process.argv[3] ?? '5000';
const WORKER_CALLS = Number(process.env.WORKER_CALLS ?? 4);
const USER_OPENS_PER_HOUR = Number(process.env.USER_OPENS ?? 12);
const MIX = {
  live: Number(process.env.LIVE ?? 25),
  prematch: Number(process.env.PREMATCH ?? 30),
  upcoming: Number(process.env.UPCOMING ?? 80),
  recentHot: Number(process.env.RECENT_HOT ?? 60),
  recent: Number(process.env.RECENT ?? 250),
  history: Number(process.env.HISTORY ?? 900),
};
// Kickoff offsets in minutes relative to now, per profile.
const RANGES = {
  live: [-100, -15], prematch: [10, 90], upcoming: [180, 1440],
  recentHot: [-360, -150], recent: [-2160, -360], history: [-10080, -2160],
};

let rng = 42;
const rand = () => { rng = (rng * 1103515245 + 12345) % 2147483648; return rng / 2147483648; };
const between = ([a, b]) => Math.round(a + (b - a) * rand());

const db = await openDatabase();
const q = (sql, params = []) => db.query(sql, params);

const truth = new Map();
let n = 0;
for (const [profile, count] of Object.entries(MIX)) {
  for (let i = 0; i < count; i++) {
    n++;
    const id = `fb_match_sim${n}`;
    const offset = between(RANGES[profile]);
    const status = profile === 'live' ? 'LIVE'
      : ['recentHot', 'recent', 'history'].includes(profile) ? 'VERIFIED' : 'SCHEDULED';
    truth.set(id, { profile, offset, lineup: rand() < 0.55, stats: rand() < 0.65, events: rand() < 0.8, ext: `sim-${n}` });
    await q(`insert into futbeat_private.entities values($1,'match',jsonb_build_object('id',$1::text,
      'competitionId','fb_comp_sim','homeTeamId','fb_team_sim_h','awayTeamId','fb_team_sim_a',
      'startTime',(now()+make_interval(mins=>$2::int))::text,'status',$3::text,
      'provenance',jsonb_build_object('receivedAt',now()::text),'events','[]'::jsonb,'statistics','[]'::jsonb))`,
    [id, offset, status]);
    await q("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`sim-${n}`, id]);
  }
}
await q(`insert into futbeat_private.entities values
  ('fb_comp_sim','competition','{"id":"fb_comp_sim","name":"Sim"}'),
  ('fb_team_sim_h','team','{"id":"fb_team_sim_h","name":"H"}'),
  ('fb_team_sim_a','team','{"id":"fb_team_sim_a","name":"A"}') on conflict do nothing`);
await q('analyze');

// What GOAL would answer for a match at this moment (scripted truth).
function providerPayload(t) {
  const payload = {};
  const started = t.offset <= 0;
  if (t.lineup && t.offset <= 60) payload.lineups = { home: { startingLineups: [{ playerId: `p-${t.ext}`, lineupPlayer: 'Sim' }] } };
  if (t.stats && t.offset <= -10) payload.statistics = [{ type: 'Shots', home: 3, away: 1 }];
  if (t.events && t.offset <= -20) payload.events = [{ minute: 12, type: 'GOAL' }];
  payload.matchStatus = t.profile === 'live' ? 'LIVE' : started ? 'FINISHED' : 'NOT_STARTED';
  return payload;
}

const state = async (matchId) => (await q(`select exists(select 1 from futbeat_private.match_detail_cache c
    where c.match_id=$1 and exists(select 1 from futbeat_private.lineup_rows(c.payload))) lineup,
  exists(select 1 from futbeat_private.match_detail_cache c where c.match_id=$1
    and futbeat_private.detail_statistics_count(c.payload->'statistics')>0) stats,
  coalesce((select jsonb_array_length(case when jsonb_typeof(c.payload->'events')='array' then c.payload->'events' else '[]' end)
    from futbeat_private.match_detail_cache c where c.match_id=$1),0) events`, [matchId])).rows[0];

let remaining = REMAINING_ARG === 'unknown' ? null : Number(REMAINING_ARG);
const calls = {}; const useful = {}; const empty = {}; const skips = {};
const depth = []; const userWaits = []; const pendingUsers = new Map();
const bump = (o, k) => { o[k] = (o[k] ?? 0) + 1; };

for (let minute = 0; minute < MINUTES; minute++) {
  // User opens (Match Center), spread over the mix.
  if (rand() < USER_OPENS_PER_HOUR / 60) {
    const ids = [...truth.keys()];
    const id = ids[Math.floor(rand() * ids.length)];
    await q('select public.futbeat_request_match_detail($1)', [id]);
    if (!pendingUsers.has(id)) pendingUsers.set(id, minute);
  }
  for (let c = 0; c < WORKER_CALLS; c++) {
    try { await q('select public.futbeat_enqueue_stale_live_detail()'); } catch { /* planner unavailable */ }
    const r = (await q("select public.futbeat_reserve_match_detail_call('sim') v")).rows[0].v;
    if (!r.allowed) { bump(skips, r.reason ?? 'unknown'); break; }
    const t = truth.get(r.matchId);
    const bucket = `${t.profile}/${r.quotaClass}`;
    const before = await state(r.matchId);
    const detail = providerPayload(t);
    if (remaining != null) remaining = Math.max(0, remaining - 1);
    await q("select public.futbeat_store_match_detail($1,$2,now(),$3)", [r.matchId, t.ext, JSON.stringify(detail)]);
    await q("select public.futbeat_complete_provider_call($1,'SUCCEEDED',$2,200,null,'{}')", [r.reservationId, remaining]);
    const after = await state(r.matchId);
    bump(calls, bucket);
    const gained = (!before.lineup && after.lineup) || (!before.stats && after.stats) || after.events > before.events;
    bump(gained ? useful : empty, bucket);
    if (pendingUsers.has(r.matchId)) { userWaits.push(minute - pendingUsers.get(r.matchId)); pendingUsers.delete(r.matchId); }
  }
  if (minute % 10 === 0) {
    const d = (await q(`select source,count(*)::int n from futbeat_private.match_detail_requests
      where expires_at>now() group by source order by source`)).rows;
    depth.push({ minute, ...Object.fromEntries(d.map((x) => [x.source, x.n])) });
  }
  // One simulated minute passes for every work timestamp.
  await db.exec(`update futbeat_private.match_detail_cache set fetched_at=fetched_at-interval '1 minute';
    update futbeat_private.match_detail_requests set requested_at=requested_at-interval '1 minute',
      expires_at=expires_at-interval '1 minute',user_requested_at=user_requested_at-interval '1 minute';
    update futbeat_private.match_detail_coverage set last_fetch_at=last_fetch_at-interval '1 minute',
      next_retry_at=next_retry_at-interval '1 minute';
    update futbeat_private.provider_call_ledger set reserved_at=reserved_at-interval '1 minute',
      completed_at=completed_at-interval '1 minute' where call_kind='match-detail'`);
  const extra = (await q(`select column_name c from information_schema.columns where table_schema='futbeat_private'
    and table_name='match_detail_coverage' and data_type like 'timestamp%' and column_name not in ('last_fetch_at','next_retry_at')`)).rows;
  for (const { c } of extra) await q(`update futbeat_private.match_detail_coverage set ${c}=${c}-interval '1 minute'`);
  // Planner pacing state (present after the backlog-control migration).
  if ((await q("select to_regclass('futbeat_private.detail_planner_state') t")).rows[0].t) {
    await db.exec(`update futbeat_private.detail_planner_state set last_planned_at=last_planned_at-interval '1 minute';
      update futbeat_private.match_detail_queue_log set at=at-interval '1 minute'`);
  }
}

const total = Object.values(calls).reduce((a, b) => a + b, 0);
const usefulTotal = Object.values(useful).reduce((a, b) => a + b, 0);
const perDay = (v) => Math.round(v * 1440 / MINUTES);
console.log(JSON.stringify({
  minutes: MINUTES, remainingStart: REMAINING_ARG, mix: MIX,
  // Absolute counts are the result. The per-day figures are a naive linear
  // upper bound: they ignore the 24 h per-match caps, daily bucket budgets
  // and the 900 daily cap, which bind over a full day.
  calls: total, usefulCalls: usefulTotal,
  linearUpperBoundPerDay: { calls: perDay(total), useful: perDay(usefulTotal) },
  usefulCoveragePerCall: total ? +(usefulTotal / total).toFixed(2) : null,
  callsByBucket: calls, usefulByBucket: useful, emptyByBucket: empty, skips,
  queueDepth: depth,
  userOpenWaitMinutes: { served: userWaits.length, max: Math.max(0, ...userWaits),
    avg: userWaits.length ? +(userWaits.reduce((a, b) => a + b, 0) / userWaits.length).toFixed(1) : null,
    stillWaiting: pendingUsers.size },
}, null, 1));
await db.close();

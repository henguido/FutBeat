import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// 20261108100000: same answers, fewer pages. The previous match read model
// is loaded verbatim next to the new one and both are compared on many
// generated matches (status classes, stale LIVE, detail-only evidence,
// abandoned, out-of-order finals). PGlite; no provider.

const previousCore = async () => {
  const src = (await readFile(new URL('../../supabase/migrations/20260930125000_goal_terminal_score_semantics.sql', import.meta.url), 'utf8')).split('\n');
  return src.slice(362, 499).join('\n').replace('futbeat_private.match_read_model_core(', 'futbeat_private.match_read_model_core_before(');
};

const v = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;

// Deterministic pseudo-random generator.
const rng = (seed) => () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (r, list) => list[Math.floor(r() * list.length)];

test('match read model: identical output to the previous version on 400 generated matches', async () => {
  const db = await openDatabase();
  try {
    await db.exec(await previousCore());
    const r = rng(42);
    const STATUSES = ['SCHEDULED', 'LIVE', 'HALFTIME', 'VERIFIED', 'FINISHED_PENDING_VERIFICATION', 'POSTPONED', 'DISCOVERED', 'PRE_MATCH'];
    const OBS = ['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES', 'VERIFIED', 'FINISHED_PENDING_VERIFICATION', 'ABANDONED', 'SUSPENDED', 'SCHEDULED', 'POSTPONED', 'CANCELLED'];
    const DETAIL = ['LIVE', 'FINISHED', 'AFTER_ET', 'AFTER_PEN', 'AWARDED', 'HALF_TIME', 'SCHEDULED', 'POSTPONED'];
    for (let i = 0; i < 400; i++) {
      const id = `fb_match_eq${i}`;
      const startMin = -Math.floor(r() * 600) + 60;
      const status = pick(r, STATUSES);
      const receivedMin = startMin + Math.floor(r() * 200) - 50;
      await db.query(`insert into futbeat_private.entities values($1,'match',jsonb_build_object('id',$1::text,'homeTeamId','fb_team_h','awayTeamId','fb_team_a',
        'competitionId','fb_comp_eq','startTime',now()+make_interval(mins=>$2::int),'status',$3::text,
        'score',case when $4::boolean then jsonb_build_object('home',1,'away',0) end,
        'provenance',jsonb_build_object('receivedAt',now()+make_interval(mins=>$5::int)),'events','[]'::jsonb))`,
        [id, startMin, status, r() < 0.5, receivedMin]);
      const nObs = Math.floor(r() * 8);
      for (let o = 0; o < nObs; o++) {
        const s = pick(r, OBS);
        await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,minute,home_score,away_score,events,payload_hash,raw_payload)
          values($1,$2,$3,now()+make_interval(mins=>$4::int),$5,$6,$7,$8,'[]'::jsonb,md5($2||$9)||md5($9||$2),$10)`,
          [r() < 0.8 ? 'goal_api' : 'thesportsdb', `eq${i}`, id, startMin + Math.floor(r() * 180) - 20, s, Math.floor(r() * 95),
            r() < 0.7 ? Math.floor(r() * 4) : null, r() < 0.7 ? Math.floor(r() * 4) : null, `${o}`,
            JSON.stringify(r() < 0.5 ? { matchStatus: s, homeTeamScore: Math.floor(r() * 4), awayTeamScore: Math.floor(r() * 4) } : { other: true })]);
      }
      if (r() < 0.5) {
        await db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
          values($1,'goal_api',$2,now()+make_interval(mins=>$3::int),$4)`, [id, `eq${i}`, startMin + Math.floor(r() * 200) - 30,
          JSON.stringify({ matchStatus: pick(r, DETAIL), matchPeriod: pick(r, ['EXTRA_TIME', 'PENALTIES', 'HALF_TIME', 'FIRST_HALF']),
            matchElapsed: r() < 0.5 ? Math.floor(r() * 90) : undefined, homeTeamScore: Math.floor(r() * 3), awayTeamScore: Math.floor(r() * 3),
            events: r() < 0.5 ? [{ minute: 3 }] : [], incidents: r() < 0.3 ? [{ minute: 5 }] : undefined })]);
      }
      if (r() < 0.3) {
        await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
          values($1,$2,'goal_api',$3,'{"minute":90}',now()+make_interval(mins=>$4::int))`,
          [`fb_event_eq${i}`, id, pick(r, ['FULL_TIME', 'GOAL']), startMin + 100]);
      }
    }
    const diffs = (await db.query(`select id from futbeat_private.entities where kind='match' and id like 'fb_match_eq%'
      and (futbeat_private.match_read_model_core(payload,false) is distinct from futbeat_private.match_read_model_core_before(payload,false)
        or futbeat_private.match_read_model_core(payload,true) is distinct from futbeat_private.match_read_model_core_before(payload,true))`)).rows;
    assert.deepEqual(diffs, []);
  } finally { await db.close(); }
});

test('calendar snapshot: unchanged content keeps its stored payload; changed content is rewritten', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_comp_cal','competition','{"id":"fb_comp_cal","name":"Copa"}'),
      ('fb_team_c1','team','{"id":"fb_team_c1","name":"Uno"}'),('fb_team_c2','team','{"id":"fb_team_c2","name":"Dos"}')`);
    await db.query(`insert into futbeat_private.entities values('fb_match_cal','match',jsonb_build_object('id','fb_match_cal','competitionId','fb_comp_cal',
      'homeTeamId','fb_team_c1','awayTeamId','fb_team_c2','startTime',now()-interval '3 days','status','VERIFIED','score','{"home":1,"away":0}'::jsonb))`);
    const day = await v(db, "select ((now()-interval '3 days') at time zone 'UTC')::date::text v");
    const build = () => db.query("select futbeat_private.materialize_calendar_day($1,'UTC')", [day]);
    const row = () => db.query("select xmin::text x,payload_md5,payload from futbeat_private.compact_calendar_cache where calendar_date=$1 and timezone='UTC'", [day]).then((r) => r.rows[0]);
    await build();
    const first = await row();
    assert.match(first.payload_md5, /^[0-9a-f]{32}$/);
    await db.query("update futbeat_private.compact_calendar_cache set expires_at=now()-interval '1 second'");
    const wal0 = await v(db, 'select pg_current_wal_lsn()::text v');
    await build();
    const second = await row();
    assert.equal(second.payload_md5, first.payload_md5);
    assert.deepEqual(second.payload, first.payload);
    const wal = await v(db, 'select pg_wal_lsn_diff(pg_current_wal_lsn(),$1)::bigint v', [wal0]);
    assert.ok(Number(wal) < 4096, `only the small row is rewritten (${wal} bytes WAL)`);
    // Real change: the new payload lands.
    await db.query(`update futbeat_private.entities set payload=jsonb_set(payload,'{score}','{"home":2,"away":0}') where id='fb_match_cal'`);
    await db.query("update futbeat_private.compact_calendar_cache set expires_at=now()-interval '1 second'");
    await build();
    const third = await row();
    assert.notEqual(third.payload_md5, first.payload_md5);
    assert.equal(third.payload.matches[0].score.home, 2);
  } finally { await db.close(); }
});

test('detail planner: returns before the window scan when nothing can be queued', async () => {
  const db = await openDatabase();
  try {
    const def = await v(db, "select pg_get_functiondef('futbeat_private.plan_match_detail_coverage(integer)'::regprocedure) v");
    assert.match(def, /if not live_open and \(bg_lim=0 or not bg_open or not floor_ok\) then/);
    const cutAt = def.indexOf('if not live_open and (bg_lim=0');
    assert.ok(cutAt > 0 && cutAt < def.indexOf('for cand in'), 'the early return precedes the candidate loop');
  } finally { await db.close(); }
});

test('the migration refuses to build the observation indexes blocking on a large table', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20261108100000_disk_io_hot_paths.sql', import.meta.url), 'utf8');
  assert.match(sql, /pg_relation_size\('futbeat_private\.provider_observations'\)>64\*1024\*1024/);
  const manual = await readFile(new URL('../../supabase/manual/20261108100000_observation_indexes_concurrently.sql', import.meta.url), 'utf8');
  assert.equal((manual.match(/create index concurrently if not exists/g) ?? []).length, 2);
});

test('rollback restores the previous functions verbatim', async () => {
  const db = await openDatabase();
  try {
    await db.exec(await readFile(new URL('../../supabase/manual/20261108100000_disk_io_hot_paths_rollback.sql', import.meta.url), 'utf8'));
    const def = (sig) => v(db, 'select pg_get_functiondef($1::regprocedure) v', [sig]);
    assert.ok(!(await def('futbeat_private.match_read_model_core(jsonb,boolean)')).includes('jsonb_to_record'));
    assert.ok(!(await def('futbeat_private.plan_match_detail_coverage(integer)')).includes('if not live_open and (bg_lim=0'));
    assert.ok(!(await def('futbeat_private.materialize_calendar_day(date,text)')).includes('payload_md5'));
  } finally { await db.close(); }
});

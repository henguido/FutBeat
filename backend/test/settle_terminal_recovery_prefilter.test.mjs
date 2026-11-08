import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// BE11-A1 (20261108010000): settle_terminal_recovery() runs the read model
// only for pending rows whose match has terminal evidence. Production
// 2026-11-07: 583 pending rows x 87-190 ms of match_read_model_core inside
// the provider quota lock = 57014 on every recovery reservation.

const STATUSES = ['VERIFIED', 'FINISHED_PENDING_VERIFICATION', 'ABANDONED'];
let seq = 0;

async function pending(db, { evidence = null, payloadStatus = 'SCHEDULED' } = {}) {
  const k = ++seq;
  const id = `fb_match_pf${k}`;
  const ext = `pf-${k}`;
  const start = new Date(Date.now() - 3 * 3600e3).toISOString();
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, 'match', JSON.stringify({
    id, homeTeamId: 'fb_team_h', awayTeamId: 'fb_team_a', status: payloadStatus, startTime: start, events: [],
    provenance: { receivedAt: new Date(Date.now() - 4 * 3600e3).toISOString() },
  })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ext, id]);
  const seen = new Date(Date.now() - 3600e3).toISOString();
  if (evidence === 'observation') {
    await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,received_at,payload_hash,raw_payload)
      values('goal_api',$1,$2,'FINISHED_PENDING_VERIFICATION',90,1,0,$3,md5($1)||md5($2),'{}'::jsonb)`, [ext, id, seen]);
  } else if (evidence === 'detail') {
    await db.query("insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,payload,fetched_at) values($1,'goal_api',$4,$2,$3)",
      [id, JSON.stringify({ matchStatus: 'FINISHED' }), seen, ext]);
  } else if (evidence === 'live') {
    // In play an hour ago: not terminal evidence.
    await db.query(`insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,last_payload_hash,first_seen_at,last_seen_at,changed_at)
      values('goal_api',$1,$2,'LIVE',29,0,0,md5($1)||md5($2),$3,$3,$3)`, [ext, id, seen]);
  }
  await db.query(`insert into futbeat_private.live_terminal_recovery(provider,external_match_id,canonical_match_id,reason,state,last_live_status,detected_at,attempts,next_attempt_at)
    values('goal_api',$1,$2,'absent_from_live','PENDING','LIVE',now()-interval '1 hour',0,now())`, [ext, id]);
  return id;
}

test('settlement evaluates the read model only for matches with terminal evidence and resolves exactly the same rows', async () => {
  const db = await openDatabase();
  const cases = [];
  for (let i = 0; i < 12; i++) cases.push({ id: await pending(db, { evidence: 'live' }), terminal: false });
  for (let i = 0; i < 6; i++) cases.push({ id: await pending(db), terminal: false });
  cases.push({ id: await pending(db, { evidence: 'observation' }), terminal: true });
  cases.push({ id: await pending(db, { evidence: 'detail' }), terminal: true });
  cases.push({ id: await pending(db, { payloadStatus: 'POSTPONED' }), terminal: true });

  // Reference answer: the unfiltered read model on every pending row.
  const reference = new Map((await db.query(
    "select canonical_match_id id, futbeat_private.match_effectively_terminal(canonical_match_id) t from futbeat_private.live_terminal_recovery where state='PENDING'",
  )).rows.map((r) => [r.id, r.t]));
  for (const c of cases) assert.equal(reference.get(c.id), c.terminal, c.id);
  // The prefilter is a necessary condition on every case.
  for (const c of cases) {
    const may = (await db.query('select futbeat_private.match_may_be_terminal($1) v', [c.id])).rows[0].v;
    if (c.terminal) assert.equal(may, true, c.id);
  }

  await db.exec("set track_functions='all'");
  const calls = await db.transaction(async (tx) => {
    await tx.query('select futbeat_private.settle_terminal_recovery()');
    const r = await tx.query("select coalesce(sum(calls),0)::int n from pg_stat_xact_user_functions where schemaname='futbeat_private' and funcname='match_effectively_terminal'");
    return r.rows[0].n;
  });
  assert.equal(calls, 3, 'read model only for the 3 rows with terminal evidence (was 21)');

  const states = new Map((await db.query('select canonical_match_id id,state,resolution from futbeat_private.live_terminal_recovery')).rows.map((r) => [r.id, r]));
  for (const c of cases) {
    assert.equal(states.get(c.id).state, c.terminal ? 'RESOLVED' : 'PENDING', c.id);
    if (c.terminal) assert.equal(states.get(c.id).resolution, 'terminal_evidence');
  }
  // Non-terminal pending rows still demand their results date.
  const demand = (await db.query("select count(*)::int n from futbeat_private.results_date_user_demand where provider='goal_api'")).rows[0].n;
  assert.ok(demand >= 1);
  // And still expire after the 6 h window.
  await db.query("update futbeat_private.live_terminal_recovery set detected_at=now()-interval '7 hours' where state='PENDING'");
  await db.query('select futbeat_private.settle_terminal_recovery()');
  assert.equal((await db.query("select count(*)::int n from futbeat_private.live_terminal_recovery where state='PENDING'")).rows[0].n, 0);
  await db.close();
});

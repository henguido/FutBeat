import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';

// #120: terminal canonical state is absorbing across the realtime projection
// (futbeat_record_live_batch -> live_match_state -> public.live_match_updates),
// against the real migrations in PGlite. Generic: no fixed teams/matches.

const MIGRATION = new URL('../../supabase/migrations/20260926020000_terminal_realtime_absorbing.sql', import.meta.url);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
// Monotonic and never behind wall time (push devices register at now()).
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seedMatch(db, { status = 'SCHEDULED', score = null, hoursAgo = 1, receivedHoursAgo = null } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_tr${n}`, home: `fb_team_trh${n}`, away: `fb_team_tra${n}`, match: `fb_match_tr${n}`, ext: `goal-tr-${n}` };
  const start = new Date(Date.now() - hoursAgo * 3600e3).toISOString();
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  await put(ids.match, 'match', {
    competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, startTime: start, status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - (receivedHoursAgo ?? hoursAgo) * 3600e3).toISOString() },
  });
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  return { ...ids, start };
}

const observation = (ext, status, [home, away] = [0, 0], minute = 30, events = []) => {
  const obs = { externalMatchId: ext, status, minute, score: { home, away }, events, nonce: ++seq };
  obs.payloadHash = createHash('sha256').update(JSON.stringify(obs)).digest('hex');
  return obs;
};
const record = (db, observations, at = tick()) =>
  db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', at, JSON.stringify(observations)]).then((r) => r.rows[0].v);
const publicRow = (db, id) => db.query('select status,home_score,away_score,revision from public.live_match_updates where match_id=$1', [id]).then((r) => r.rows[0] ?? null);
const liveState = (db, ext) => db.query("select status,home_score,away_score,revision from futbeat_private.live_match_state where provider='goal_api' and external_match_id=$1", [ext]).then((r) => r.rows[0] ?? null);
const readModel = (db, id) => db.query("select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1", [id]).then((r) => r.rows[0].v);
const terminal = (db, id) => db.query('select futbeat_private.match_effectively_terminal($1) v', [id]).then((r) => r.rows[0].v);
const regressions = (db) => db.query('select * from futbeat_private.terminal_realtime_regressions()').then((r) => r.rows);
const count = (db, sql, args = []) => db.query(`select count(*)::int n from ${sql}`, args).then((r) => r.rows[0].n);

test('A. canonical VERIFIED + incoming LIVE: suppressed (audited), no state, no public row, no provider observation', () => withDb(async (db) => {
  const s = await seedMatch(db, { status: 'VERIFIED', score: [1, 4], hoursAgo: 3 });
  const result = await record(db, [observation(s.ext, 'HALFTIME', [1, 1], 45)]);
  assert.equal(result.suppressedByCanonicalTerminal, true);
  assert.deepEqual(result.suppressed, [{ externalMatchId: s.ext, canonicalMatchId: s.match, status: 'HALFTIME', reason: 'canonical_terminal' }]);
  assert.deepEqual(result.changes, []);
  assert.equal(await liveState(db, s.ext), null);
  assert.equal(await publicRow(db, s.match), null);
  assert.equal(await count(db, 'futbeat_private.provider_observations where canonical_match_id=$1', [s.match]), 0);
  const [audit] = (await db.query('select status,home_score,away_score,canonical_match_id from futbeat_private.live_suppressed_observations')).rows;
  assert.deepEqual(audit, { status: 'HALFTIME', home_score: 1, away_score: 1, canonical_match_id: s.match });
  const shown = await readModel(db, s.match);
  assert.deepEqual([shown.status, shown.score], ['VERIFIED', { home: 1, away: 4 }]);
}));

test('A/E. terminal evidence in live_match_state (raw payload SCHEDULED): later LIVE never downgrades state, row or score', () => withDb(async (db) => {
  const s = await seedMatch(db, { hoursAgo: 2 });
  await record(db, [observation(s.ext, 'LIVE', [1, 2], 80)]);
  await record(db, [observation(s.ext, 'FINISHED_PENDING_VERIFICATION', [2, 2], 90)]);
  assert.equal(await terminal(db, s.match), true, 'effective read model, not the raw payload');
  const before = await liveState(db, s.ext);
  assert.equal(before.status, 'FINISHED_PENDING_VERIFICATION');

  const result = await record(db, [observation(s.ext, 'LIVE', [2, 2], 91)]);
  assert.equal(result.suppressedByCanonicalTerminal, true);
  assert.deepEqual(await liveState(db, s.ext), before, 'live_match_state not downgraded');
  assert.deepEqual(await publicRow(db, s.match), { status: 'FINISHED_PENDING_VERIFICATION', home_score: 2, away_score: 2, revision: before.revision });
  const shown = await readModel(db, s.match);
  assert.deepEqual([shown.status, shown.score], ['FINISHED_PENDING_VERIFICATION', { home: 2, away: 2 }]);
}));

test('malformed observation for a terminal match is never suppressed: core validation still rejects it, nothing audited', () => withDb(async (db) => {
  const done = await seedMatch(db, { status: 'VERIFIED', score: [1, 4], hoursAgo: 3 });
  const evidence = await seedMatch(db, { hoursAgo: 2 });
  await record(db, [observation(evidence.ext, 'LIVE', [1, 2], 80)]);
  await record(db, [observation(evidence.ext, 'FINISHED_PENDING_VERIFICATION', [2, 2], 90)]);
  const stateBefore = await liveState(db, evidence.ext);
  const rowBefore = await publicRow(db, evidence.match);
  const audits = () => count(db, 'futbeat_private.live_suppressed_observations');

  const variants = {
    missing: (o) => { delete o.payloadHash; return o; },
    empty: (o) => ({ ...o, payloadHash: '' }),
    short: (o) => ({ ...o, payloadHash: 'abc123' }),
    uppercase: (o) => ({ ...o, payloadHash: o.payloadHash.toUpperCase() }),
  };
  for (const [label, corrupt] of Object.entries(variants)) {
    for (const [s, status] of [[done, 'LIVE'], [evidence, 'HALFTIME']]) {
      assert.equal(await terminal(db, s.match), true);
      await assert.rejects(record(db, [corrupt(observation(s.ext, status, [1, 1], 45))]), /invalid payloadHash/, `${label}/${status}`);
      // A valid suppressible observation in the same batch is rolled back too.
      await assert.rejects(record(db, [observation(done.ext, 'LIVE', [0, 0], 10), corrupt(observation(s.ext, status, [1, 1], 46))]), /invalid payloadHash/);
    }
  }
  assert.equal(await audits(), 0, 'no audit row for malformed input');
  assert.equal(await liveState(db, done.ext), null);
  assert.equal(await publicRow(db, done.match), null, 'no public realtime row');
  assert.deepEqual(await liveState(db, evidence.ext), stateBefore, 'live_match_state unchanged');
  assert.deepEqual(await publicRow(db, evidence.match), rowBefore, 'public row unchanged (still terminal)');
  assert.deepEqual(await regressions(db), []);

  // The audit table itself refuses a row without a valid hash.
  await assert.rejects(db.query(`insert into futbeat_private.live_suppressed_observations(provider,external_match_id,canonical_match_id,received_at,status)
    values('goal_api',$1,$2,now(),'LIVE')`, [done.ext, done.match]), /null value|not-null/);
  // A valid one is still suppressed and audited.
  const ok = await record(db, [observation(done.ext, 'LIVE', [0, 0], 10)]);
  assert.equal(ok.suppressedByCanonicalTerminal, true);
  assert.equal(await audits(), 1);
}));

test('malformed numeric, timestamp or event fields on a terminal match: the whole batch is rejected before any suppression', () => withDb(async (db) => {
  const done = await seedMatch(db, { status: 'VERIFIED', score: [1, 4], hoursAgo: 3 });
  const evidence = await seedMatch(db, { hoursAgo: 2 });
  const live = await seedMatch(db, { hoursAgo: 0.5 });
  await record(db, [observation(evidence.ext, 'LIVE', [1, 2], 80)]);
  await record(db, [observation(evidence.ext, 'FINISHED_PENDING_VERIFICATION', [2, 2], 90)]);
  const stateBefore = await liveState(db, evidence.ext);
  const rowBefore = await publicRow(db, evidence.match);
  const rehash = (o) => { delete o.payloadHash; o.payloadHash = createHash('sha256').update(JSON.stringify(o)).digest('hex'); return o; };
  const withField = (s, status, patch) => rehash({ ...observation(s.ext, status, [1, 1], 45), ...patch(observation(s.ext, status, [1, 1], 45)) });

  const variants = {
    'minute="abc"': [() => ({ minute: 'abc' }), /invalid input syntax for type integer/],
    'score.home="abc"': [(o) => ({ score: { ...o.score, home: 'abc' } }), /invalid input syntax for type integer/],
    'score.away="abc"': [(o) => ({ score: { ...o.score, away: 'abc' } }), /invalid input syntax for type integer/],
    'providerObservedAt invalid': [() => ({ providerObservedAt: 'not-a-timestamp' }), /invalid input syntax for type timestamp/],
    'event without eventKey': [() => ({ events: [{ type: 'GOAL', minute: 10 }] }), /eventKey is required/],
    'event.minute="abc"': [() => ({ events: [{ eventKey: 'k1', type: 'GOAL', minute: 'abc' }] }), /invalid input syntax for type integer/],
    'events not an array': [() => ({ events: { eventKey: 'k1' } }), /events must be an array/],
    'negative minute': [() => ({ minute: -1 }), /non-negative/],
    'event.minute=-1': [() => ({ events: [{ eventKey: 'k1', type: 'GOAL', minute: -1 }] }), /event minute must be non-negative/],
  };
  for (const [label, [patch, error]] of Object.entries(variants)) {
    for (const [s, status] of [[done, 'LIVE'], [evidence, 'HALFTIME']]) {
      await assert.rejects(record(db, [withField(s, status, patch)]), error, `${label} (${status})`);
      // Validation covers the whole batch before any suppression or mapping.
      await assert.rejects(record(db, [observation(done.ext, 'LIVE', [0, 0], 10), withField(s, status, patch)]), error, `${label} batch`);
    }
    // Same rejection for a normal (non-terminal) match: validation parity.
    await assert.rejects(record(db, [withField(live, 'LIVE', patch)]), error, `${label} (non-terminal)`);
  }
  assert.equal(await count(db, 'futbeat_private.live_suppressed_observations'), 0, 'no audit row');
  assert.equal(await liveState(db, done.ext), null);
  assert.equal(await publicRow(db, done.match), null, 'no public realtime row');
  assert.equal(await liveState(db, live.ext), null);
  assert.equal(await publicRow(db, live.match), null);
  assert.deepEqual(await liveState(db, evidence.ext), stateBefore, 'live_match_state unchanged');
  assert.deepEqual(await publicRow(db, evidence.match), rowBefore);
  assert.deepEqual(await regressions(db), []);

  // Defense in depth: the audit table itself refuses negative values.
  for (const column of ['minute', 'home_score', 'away_score']) {
    await assert.rejects(db.query(`insert into futbeat_private.live_suppressed_observations(provider,external_match_id,canonical_match_id,received_at,status,payload_hash,${column})
      values('goal_api',$1,$2,now(),'LIVE',$3,-1)`, [done.ext, done.match, 'b'.repeat(64)]), /check constraint/, column);
  }
}));

test('E. terminal evidence from provider_observations, FULL_TIME event or match detail alone suppresses realtime', () => withDb(async (db) => {
  const hash = () => createHash('sha256').update(String(++seq)).digest('hex');
  const sources = {
    provider_observations: (s) => db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
      values('goal_api','other-feed',$1,now()-interval '10 minutes','FINISHED_PENDING_VERIFICATION',3,4,$2,'{}')`, [s.match, hash()]),
    full_time_event: (s) => db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
      values($1,$2,'goal_api','FULL_TIME','{"minute":90}',now()-interval '10 minutes')`, [`fb_event_ft_${seq++}`, s.match]),
    match_detail: (s) => db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
      values($1,'goal_api',$2,now()-interval '10 minutes','{"matchStatus":"FINISHED","homeTeamScore":"3","awayTeamScore":"4"}')`, [s.match, s.ext]),
  };
  for (const [label, insert] of Object.entries(sources)) {
    const s = await seedMatch(db, { hoursAgo: 3 });
    assert.equal(await terminal(db, s.match), false, `${label}: not terminal before evidence`);
    await insert(s);
    assert.equal(await terminal(db, s.match), true, label);
    const result = await record(db, [observation(s.ext, 'LIVE', [3, 3], 70)]);
    assert.equal(result.suppressedByCanonicalTerminal, true, label);
    assert.equal(await publicRow(db, s.match), null, label);
    assert.equal(await liveState(db, s.ext), null, label);
  }
}));

test('B. an existing bad public row is removed by publish and by the migration cleanup; terminal rows are kept', () => withDb(async (db) => {
  const bad = await seedMatch(db, { status: 'VERIFIED', score: [1, 4], hoursAgo: 4 });
  const bad2 = await seedMatch(db, { status: 'FINISHED_PENDING_VERIFICATION', score: [2, 2], hoursAgo: 4 });
  const okTerminal = await seedMatch(db, { status: 'VERIFIED', score: [0, 1], hoursAgo: 4 });
  const live = await seedMatch(db, { hoursAgo: 1 });
  const at = new Date().toISOString();
  // Simulate the production state: private LIVE/HALFTIME state + public rows.
  for (const [s, status, score] of [[bad, 'HALFTIME', [1, 1]], [bad2, 'LIVE', [2, 2]], [okTerminal, 'VERIFIED', [0, 1]], [live, 'LIVE', [1, 0]]]) {
    await db.query(`insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,event_count,last_payload_hash,revision,first_seen_at,last_seen_at,changed_at)
      values('goal_api',$1,$2,$3,45,$4,$5,0,$6,3,$7,$7,$7)`, [s.ext, s.match, status, score[0], score[1], 'a'.repeat(64), at]);
    await db.query(`insert into public.live_match_updates(match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at)
      values($1,'goal_api',$2,$3,45,$4,$5,3,0,'[]',$6,now())`, [s.match, s.ext, status, score[0], score[1], at]);
  }
  assert.deepEqual((await regressions(db)).map((r) => r.match_id).sort(), [bad.match, bad2.match].sort());

  await db.query("select public.futbeat_publish_live_state('goal_api',$1)", [bad.ext]);
  assert.equal(await publicRow(db, bad.match), null);
  assert.equal((await liveState(db, bad.ext)).status, 'HALFTIME', 'private diagnostic state is retained');

  await db.exec(await readFile(MIGRATION, 'utf8')); // idempotent; runs the cleanup
  assert.equal(await publicRow(db, bad2.match), null);
  assert.equal((await publicRow(db, okTerminal.match)).status, 'VERIFIED', 'terminal rows stay');
  assert.equal((await publicRow(db, live.match)).status, 'LIVE', 'live matches untouched');
  assert.deepEqual(await regressions(db), [], 'production-style regression query');
  // Canonical data is never deleted.
  assert.equal(await count(db, "futbeat_private.entities where kind='match'"), 4);
}));

test('C/D. scheduled -> LIVE publishes; LIVE -> newer LIVE follows the normal revision path', () => withDb(async (db) => {
  const s = await seedMatch(db, { hoursAgo: 0.5 });
  const first = await record(db, [observation(s.ext, 'LIVE', [0, 0], 10)]);
  assert.equal(first.suppressedByCanonicalTerminal, false);
  assert.deepEqual(await publicRow(db, s.match), { status: 'LIVE', home_score: 0, away_score: 0, revision: 1 });
  const second = await record(db, [observation(s.ext, 'LIVE', [1, 0], 20)]);
  assert.equal(second.changes[0].scoreChanged, true);
  assert.deepEqual(await publicRow(db, s.match), { status: 'LIVE', home_score: 1, away_score: 0, revision: 2 });
  const half = await record(db, [observation(s.ext, 'HALFTIME', [1, 0], 45)]);
  assert.equal(half.changes[0].statusChanged, true);
  assert.equal((await publicRow(db, s.match)).status, 'HALFTIME');
  // Final whistle still reaches realtime clients.
  await record(db, [observation(s.ext, 'FINISHED_PENDING_VERIFICATION', [1, 0], 90)]);
  assert.equal((await publicRow(db, s.match)).status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(await regressions(db), []);
}));

test('F. never terminal by clock: an old SCHEDULED match without terminal evidence still accepts LIVE', () => withDb(async (db) => {
  const s = await seedMatch(db, { hoursAgo: 72 });
  assert.equal(await terminal(db, s.match), false);
  const result = await record(db, [observation(s.ext, 'LIVE', [0, 0], 5)]);
  assert.equal(result.suppressedByCanonicalTerminal, false);
  assert.equal((await liveState(db, s.ext)).status, 'LIVE');
  assert.equal((await publicRow(db, s.match)).status, 'LIVE');
}));

test('G. one batch: the terminal match is suppressed, the valid live match is processed', () => withDb(async (db) => {
  const done = await seedMatch(db, { status: 'VERIFIED', score: [3, 4], hoursAgo: 3 });
  const live = await seedMatch(db, { hoursAgo: 0.5 });
  const unmapped = { ext: 'goal-unmapped-tr' };
  const result = await record(db, [
    observation(done.ext, 'LIVE', [3, 3], 60),
    observation(live.ext, 'LIVE', [1, 1], 33),
    observation(unmapped.ext, 'LIVE', [0, 0], 1),
  ]);
  assert.equal(result.suppressedByCanonicalTerminal, true);
  assert.deepEqual(result.suppressed.map((x) => x.externalMatchId), [done.ext]);
  assert.equal(result.insertedObservations, 2);
  assert.deepEqual(result.changes.map((c) => c.externalMatchId), [live.ext, unmapped.ext]);
  assert.equal((await publicRow(db, live.match)).status, 'LIVE');
  assert.equal(await publicRow(db, done.match), null);
}));

test('H. terminal -> LIVE regression creates no change, no KICKOFF/FULL_TIME duplicate and no notification', () => withDb(async (db) => {
  const s = await seedMatch(db, { hoursAgo: 2 });
  const uid = randomUUID();
  await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test','tr-token')", [uid, randomUUID()]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, s.match]);
  await record(db, [observation(s.ext, 'LIVE', [0, 0], 10)]);
  await record(db, [observation(s.ext, 'LIVE', [1, 0], 50)]);
  const final = await record(db, [observation(s.ext, 'FINISHED_PENDING_VERIFICATION', [1, 0], 90)]);
  assert.equal(final.changes[0].notifyCandidate, true);
  const outbox = await count(db, 'futbeat_private.notification_outbox');
  const events = (await db.query('select event_type from futbeat_private.canonical_events where match_id=$1 order by event_type', [s.match])).rows.map((r) => r.event_type);
  assert.ok(events.includes('FULL_TIME'), JSON.stringify(events));
  assert.ok(outbox > 0, 'the real final notified once');

  for (const status of ['LIVE', 'HALFTIME', 'LIVE']) {
    const r = await record(db, [observation(s.ext, status, [1, 0], 92)]);
    assert.deepEqual(r.changes, [], 'no change -> no notifyCandidate');
  }
  // A late terminal repeat is processed normally and stays a no-op for push.
  await record(db, [observation(s.ext, 'FINISHED_PENDING_VERIFICATION', [1, 0], 90)]);
  assert.equal(await count(db, 'futbeat_private.notification_outbox'), outbox);
  assert.deepEqual((await db.query('select event_type from futbeat_private.canonical_events where match_id=$1 order by event_type', [s.match])).rows.map((r) => r.event_type), events);
  assert.equal((await publicRow(db, s.match)).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('new helpers and the audit table are not reachable by public clients', () => withDb(async (db) => {
  const rows = (await db.query(`select p.proname,has_function_privilege('anon',p.oid,'execute') anon,has_function_privilege('authenticated',p.oid,'execute') auth
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='futbeat_private'
    and p.proname in ('is_terminal_match_status','match_effectively_terminal','record_live_events','terminal_realtime_regressions','validate_live_observation')`)).rows;
  assert.equal(rows.length, 5);
  assert.ok(rows.every((r) => !r.anon && !r.auth), JSON.stringify(rows));
  const table = (await db.query("select has_table_privilege('anon','futbeat_private.live_suppressed_observations','select') a")).rows[0].a;
  assert.equal(table, false);
}));

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import {
  fixtureEventSections,
  liveEventsContentSignature,
  normalizeFixtureEvents,
} from '../../supabase/functions/_shared/live_events.ts';

// Re-issued GOAL event ids (20260930140000): the provider gives every event
// row a fresh id on every answer. One goal must stay one visible goal, one
// push and one active canonical row, whatever the worker version (with or
// without completeSections). Generic fixtures only.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seed(db) {
  const n = ++seq;
  const ids = { comp: `fb_comp_kd${n}`, home: `fb_team_kdh${n}`, away: `fb_team_kda${n}`, match: `fb_match_kd${n}`,
    ext: `goal-kd-${n}`, homeExt: `H${n}`, awayExt: `A${n}`, p1: `fb_player_kd${n}a`, p2: `fb_player_kd${n}b`, p3: `fb_player_kd${n}c` };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  for (const p of [ids.p1, ids.p2, ids.p3]) await put(p, 'player', { name: `Jugador ${p}` });
  await put(ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: new Date(Date.now() - 3600e3).toISOString(), status: 'SCHEDULED', events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - 7200e3).toISOString() } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', ids.homeExt, ids.home], ['team', ids.awayExt, ids.away],
    ['player', `P1-${n}`, ids.p1], ['player', `P2-${n}`, ids.p2], ['player', `P3-${n}`, ids.p3]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  const uid = randomUUID();
  await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-kd-${n}`]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, ids.match]);
  return { ...ids, n };
}

// Same shape as futbeat-goal-live-sync normalizeLiveFixture. legacy: the
// worker deployed in production before this fix (no completeSections, no
// source, the GOAL row id as the key).
function fixture(s, { home = 0, away = 0, minute = 10, status = 'LIVE', events = [], cards = [], legacy = false } = {}) {
  const raw = { id: s.ext, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards, substitutions: [] };
  const normalized = normalizeFixtureEvents(raw)
    .map((event) => (legacy && event.providerEventId ? { ...event, eventKey: event.providerEventId } : event));
  const completeSections = fixtureEventSections(raw);
  const obs = { externalMatchId: s.ext, status, minute, score: { home, away }, events: normalized, rawPayload: raw,
    ...(legacy ? {} : { completeSections, source: 'live-list' }) };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, status, minute, home, away,
    normalized.map((event) => event.eventKey), liveEventsContentSignature(normalized, legacy ? [] : completeSections)])).digest('hex');
  return obs;
}
// Every answer re-issues the row ids (as measured on GOAL): poll is part of the id.
const goal = (s, poll, { time, side = 'home', player = 'P1', score }) => ({ id: `r${poll}-${time}-${player}`, type: 'goal', time, score,
  ...(side === 'home' ? { homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre' } : { awayScorerId: `${player}-${s.n}`, awayScorer: 'Nombre' }) });
const card = (s, poll, { time, player = 'P2' }) => ({ id: `c${poll}-${time}-${player}`, card: 'Yellow Card', time, homePlayerId: `${player}-${s.n}`, homeFault: 'Nombre' });

const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const readModel = (db, id) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v);
const ofType = async (db, id, type) => ((await readModel(db, id)).events ?? []).filter((e) => e.type === type);
const realtimeOf = async (db, id, type) => ((await db.query('select latest_events v from public.live_match_updates where match_id=$1', [id])).rows[0]?.v ?? []).filter((e) => e.type === type);
const active = (db, id, type) => db.query('select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type=$2 and retracted_at is null', [id, type]).then((r) => r.rows[0].n);
const stored = (db, id) => db.query('select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and not futbeat_private.is_phase_event(event_type)', [id]).then((r) => r.rows[0].n);
const pushes = (db, id, type) => db.query('select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type=$2', [id, type]).then((r) => r.rows[0].n);
const minutes = (list) => list.map((e) => `${e.minute}' ${e.playerId}`);

// The scenario measured in production: 1-0 (10'), a 1-1 at 16' later
// annulled (gone from the answer, score back to 1-0), 2-0 (18'), 2-1 (24'),
// a card at 21', every answer with fresh ids.
function answers(s, opts) {
  const g10 = (p) => goal(s, p, { time: '10', score: '1 - 0' });
  const g16 = (p) => goal(s, p, { time: '16', side: 'away', player: 'P3', score: '1 - 1' });
  const g18 = (p) => goal(s, p, { time: '18', player: 'P2', score: '2 - 0' });
  const g24 = (p) => goal(s, p, { time: '24', side: 'away', player: 'P3', score: '2 - 1' });
  const c21 = (p) => card(s, p, { time: '21' });
  return [
    fixture(s, { ...opts, minute: 5 }),
    fixture(s, { ...opts, home: 1, minute: 11, events: [g10(1)] }),
    fixture(s, { ...opts, home: 1, away: 1, minute: 17, events: [g10(2), g16(2)] }),
    fixture(s, { ...opts, home: 2, minute: 19, events: [g10(3), g18(3)] }),
    fixture(s, { ...opts, home: 2, minute: 22, events: [g10(4), g18(4)], cards: [c21(4)] }),
    fixture(s, { ...opts, home: 2, away: 1, minute: 25, events: [g10(5), g18(5), g24(5)], cards: [c21(5)] }),
    ...[6, 7, 8, 9, 10, 11].map((p) => fixture(s, { ...opts, home: 2, away: 1, minute: 20 + p * 2, events: [g10(p), g18(p), g24(p)], cards: [c21(p)] })),
  ];
}

test('dedupe: copies of one row collapse whichever member sorts first (transitive duplicateOf)', () => withDb(async (db) => {
  const root = { id: 'fb_event_z', type: 'GOAL', matchId: 'm', minute: 10, teamId: 'h', playerId: 'p', providerEventKey: 'k0', provider: 'goal_api', score: { home: 1, away: 0 } };
  const copies = ['fb_event_a', 'fb_event_b', 'fb_event_c'].map((id, i) => ({ ...root, id, providerEventKey: `k${i + 1}`, duplicateOf: root.id }));
  const v = (await db.query("select futbeat_private.visible_match_events($1::jsonb,'h','a',$2::jsonb) v",
    [JSON.stringify([root, ...copies]), JSON.stringify({ home: 1, away: 0 })])).rows[0].v;
  assert.equal(v.length, 1, 'one goal, not one per re-issued id');
  assert.equal(v[0].duplicateOf, undefined, 'technical marker never shown');
  // The copied row itself already gone (retracted): its copies are still one.
  const orphans = (await db.query("select futbeat_private.visible_match_events($1::jsonb,'h','a',null::jsonb) v", [JSON.stringify(copies)])).rows[0].v;
  assert.equal(orphans.length, 1);
  // Two real provider ids without a duplicateOf marker are still two events.
  const two = (await db.query("select futbeat_private.visible_match_events($1::jsonb,'h','a',null::jsonb) v",
    [JSON.stringify([root, { ...root, id: 'fb_event_y', providerEventKey: 'k9', score: { home: 2, away: 0 } }])])).rows[0].v;
  assert.equal(two.length, 2);
}));

test('re-issued ids, deployed (legacy) worker without completeSections: one goal each, one push, no new canonical row per answer', () => withDb(async (db) => {
  const s = await seed(db);
  for (const obs of answers(s, { legacy: true })) await record(db, obs);
  const goals = await ofType(db, s.match, 'GOAL');
  // The annulled 16' goal cannot be retracted without a complete answer (the
  // legacy worker never sends one); it is the only extra and is flagged.
  assert.deepEqual(minutes(goals), [`10' ${s.p1}`, `16' ${s.p3}`, `18' ${s.p2}`, `24' ${s.p3}`]);
  assert.equal((await readModel(db, s.match)).scoreMismatch, true);
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 1);
  assert.equal((await realtimeOf(db, s.match, 'GOAL')).length, 4);
  assert.equal(await active(db, s.match, 'GOAL'), 4, 'one active canonical row per goal, not per answer');
  assert.equal(await active(db, s.match, 'YELLOW_CARD'), 1);
  assert.equal(await pushes(db, s.match, 'GOAL'), 4);
  assert.equal(await pushes(db, s.match, 'YELLOW_CARD'), 1);
}));

test('re-issued ids, current worker (complete answers): annulled goal retracted, one of each, one push', () => withDb(async (db) => {
  const s = await seed(db);
  for (const obs of answers(s, {})) await record(db, obs);
  assert.deepEqual(minutes(await ofType(db, s.match, 'GOAL')), [`10' ${s.p1}`, `18' ${s.p2}`, `24' ${s.p3}`]);
  assert.equal((await readModel(db, s.match)).scoreMismatch, undefined);
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 1);
  assert.equal((await realtimeOf(db, s.match, 'GOAL')).length, 3);
  assert.equal(await active(db, s.match, 'GOAL'), 3);
  assert.equal(await stored(db, s.match), 5, 'no row per answer: 4 goals + 1 card ever stored, nothing churned');
  assert.equal(await pushes(db, s.match, 'GOAL'), 4, 'the annulled goal was pushed when scored, nothing more');
  assert.equal(await pushes(db, s.match, 'YELLOW_CARD'), 1);
}));

test('normalizer: re-issued GOAL ids keep the same keys; the same content is a duplicate observation', () => withDb(async (db) => {
  const s = await seed(db);
  const a = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt },
    events: [goal(s, 1, { time: '10', score: '1 - 0' })], cards: [card(s, 1, { time: '21' })] });
  const b = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt },
    events: [goal(s, 2, { time: '10', score: '1 - 0' })], cards: [card(s, 2, { time: '21' })] });
  assert.notDeepEqual(a.map((e) => e.providerEventId), b.map((e) => e.providerEventId));
  assert.deepEqual(a.map((e) => e.eventKey), b.map((e) => e.eventKey));
  assert.ok(a.every((e) => e.eventKey.startsWith('fallback:')));
  await record(db, fixture(s, { minute: 5 }));
  await record(db, fixture(s, { home: 1, minute: 22, events: [goal(s, 1, { time: '10', score: '1 - 0' })], cards: [card(s, 1, { time: '21' })] }));
  const again = await record(db, fixture(s, { home: 1, minute: 22, events: [goal(s, 2, { time: '10', score: '1 - 0' })], cards: [card(s, 2, { time: '21' })] }));
  assert.equal(again.duplicates, 1, 'a re-issued id alone is not a new observation');
  const keys = (await db.query('select count(*)::int n from futbeat_private.live_events where external_match_id=$1', [s.ext])).rows[0].n;
  assert.equal(keys, 2);
}));

test('worker keys GOAL events by content (live list, detail and results alike)', async () => {
  const source = await readFile(new URL('../../supabase/functions/_shared/live_events.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /eventKey = clean\(row\.id\)/);
  assert.equal(source.match(/const eventKey = fallbackKey\(/g)?.length, 3);
});

test('copies stored before the fix self-heal on the next answer (retracted, audited, never pushed)', () => withDb(async (db) => {
  const s = await seed(db);
  const all = answers(s, { legacy: true });
  for (const obs of all.slice(0, 2)) await record(db, obs);
  const [root] = (await db.query("select id,payload from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL'", [s.match])).rows;
  // Copies as 20260930100000 stored them (own row, duplicateOf the content row).
  for (const k of ['old-a', 'old-b']) {
    const id = `fb_event_${createHash('md5').update(`${root.id}|${k}`).digest('hex')}`;
    await db.query(`insert into futbeat_private.live_events(provider,external_match_id,event_key,canonical_match_id,event_type,minute,team_external_id,player_external_id,payload,first_seen_at)
      select provider,external_match_id,$1,canonical_match_id,event_type,minute,team_external_id,player_external_id,payload||jsonb_build_object('eventKey',$1::text),now()
      from futbeat_private.live_events where external_match_id=$2 and event_type='GOAL' limit 1`, [k, s.ext]);
    await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,notify_candidate,first_seen_at)
      values($1,$2,'goal_api','GOAL',$3,false,now())`, [id, s.match, JSON.stringify({ ...root.payload, id, providerEventKey: k, duplicateOf: root.id })]);
  }
  assert.equal(await active(db, s.match, 'GOAL'), 3);
  await record(db, fixture(s, { legacy: true, home: 1, minute: 13, events: [goal(s, 99, { time: '10', score: '1 - 0' })] }));
  assert.equal(await active(db, s.match, 'GOAL'), 1);
  const reasons = (await db.query("select retraction_reason r from futbeat_private.canonical_events where match_id=$1 and retracted_at is not null", [s.match])).rows.map((r) => r.r);
  assert.deepEqual(reasons, ['duplicate_upstream_key', 'duplicate_upstream_key']);
  assert.equal((await ofType(db, s.match, 'GOAL')).length, 1);
  assert.equal(await pushes(db, s.match, 'GOAL'), 1);
}));

test('manual cleanup: dry run counts, retracts copies only, keeps what users see, idempotent', () => withDb(async (db) => {
  const s = await seed(db);
  for (const obs of answers(s, { legacy: true }).slice(0, 2)) await record(db, obs);
  await record(db, fixture(s, { legacy: true, home: 1, minute: 22, events: [goal(s, 50, { time: '10', score: '1 - 0' })], cards: [card(s, 50, { time: '21' })] }));
  const roots = (await db.query("select id,event_type,payload from futbeat_private.canonical_events where match_id=$1 and retracted_at is null and not futbeat_private.is_phase_event(event_type) order by event_type", [s.match])).rows;
  assert.deepEqual(roots.map((r) => r.event_type), ['GOAL', 'YELLOW_CARD']);
  const copy = (root, k, at) => {
    const id = `fb_event_${createHash('md5').update(`${root.id}|${k}`).digest('hex')}`;
    return db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,notify_candidate,first_seen_at)
      values($1,$2,'goal_api',$3,$4,false,$5)`, [id, s.match, root.event_type,
      JSON.stringify({ ...root.payload, id, providerEventKey: k, duplicateOf: root.id }), at]);
  };
  // Goal: three copies of an active row. Card: two copies of a row that is
  // no longer active (the oldest copy is the occurrence now).
  for (const k of ['g-a', 'g-b', 'g-c']) await copy(roots[0], k, new Date().toISOString());
  await copy(roots[1], 'c-a', new Date(Date.now() - 2000).toISOString());
  await copy(roots[1], 'c-b', new Date(Date.now() - 1000).toISOString());
  await db.query("select futbeat_private.retract_canonical_event($1,now(),'provider_retracted')", [roots[1].id]);
  const visibleBefore = (await readModel(db, s.match)).events.filter((e) => !['KICKOFF'].includes(e.type));
  assert.deepEqual(visibleBefore.map((e) => e.type), ['GOAL', 'YELLOW_CARD']);

  const dryRun = await readFile(new URL('../../supabase/manual/20260930140000_event_key_duplicates_dry_run.sql', import.meta.url), 'utf8');
  const [row] = (await db.query(dryRun)).rows;
  assert.deepEqual([row.match_id, Number(row.candidates), Number(row.goal_candidates), Number(row.occurrences)], [s.match, 4, 3, 2]);
  assert.equal(row.visible_before, row.visible_after);
  assert.equal(row.visible_same, true, 'never changes what users see');

  const cleanup = await readFile(new URL('../../supabase/manual/20260930140000_event_key_duplicates_cleanup.sql', import.meta.url), 'utf8');
  await db.exec(cleanup);
  assert.equal(await active(db, s.match, 'GOAL'), 1);
  assert.equal(await active(db, s.match, 'YELLOW_CARD'), 1);
  const [kept] = (await db.query("select payload->>'providerEventKey' k from futbeat_private.canonical_events where match_id=$1 and event_type='YELLOW_CARD' and retracted_at is null", [s.match])).rows;
  assert.equal(kept.k, 'c-a');
  const audit = (await db.query("select count(*)::int n from futbeat_private.canonical_event_revisions where match_id=$1 and reason='duplicate_upstream_key_cleanup'", [s.match])).rows[0].n;
  assert.equal(audit, 4);
  assert.deepEqual((await readModel(db, s.match)).events.filter((e) => e.type !== 'KICKOFF').map((e) => [e.type, e.minute]),
    visibleBefore.map((e) => [e.type, e.minute]));
  assert.equal((await realtimeOf(db, s.match, 'GOAL')).length, 1);
  // Idempotent: nothing left to touch.
  await db.exec(cleanup);
  assert.equal((await db.query(dryRun)).rows.length, 0);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.canonical_event_revisions where match_id=$1 and reason='duplicate_upstream_key_cleanup'", [s.match])).rows[0].n, 4);
  assert.equal(await pushes(db, s.match, 'GOAL'), 1);
}));

test('two goals with the same content and no score-after under two ids stay two when the score needs them', () => withDb(async (db) => {
  const s = await seed(db);
  const twin = (id) => ({ id, type: 'goal', time: '30', homeScorerId: `P1-${s.n}`, homeScorer: 'Nombre' });
  await record(db, fixture(s, { legacy: true, minute: 29 }));
  await record(db, fixture(s, { legacy: true, home: 2, minute: 31, events: [twin('x1'), twin('x2')] }));
  assert.equal((await ofType(db, s.match, 'GOAL')).length, 2);
  assert.equal(await active(db, s.match, 'GOAL'), 2);
}));

// Correction (new content key) and a new goal of the same team in ONE
// answer: each correction claims its own twin whatever the key order.
const pushedGoals = (db, id) => db.query(`select e.payload->>'minute' m, e.payload->>'playerId' p from futbeat_private.notification_outbox o
  join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL' order by o.id`, [id])
  .then((r) => r.rows.map((x) => `${x.m}' ${x.p}`).sort());
for (const variant of [
  { name: 'assist added to 10\' + another player scores 12\'', fix: { time: '10', assist: 'P3' }, next: { time: '12', player: 'P2' } },
  { name: 'minute corrected 10\' -> 11\' + the same player scores again 40\'', fix: { time: '11' }, next: { time: '40', player: 'P1' } },
]) {
  test(`correction + new same-team goal in one answer, both key orders: ${variant.name}`, () => withDb(async (db) => {
    const orders = new Set();
    for (let i = 0; i < 24 && orders.size < 2; i++) {
      const s = await seed(db);
      const row = ({ time, player = 'P1', assist, score }) => ({ id: `x${i}-${time}-${player}`, type: 'goal', time, score,
        homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre', ...(assist ? { homeAssistId: `${assist}-${s.n}` } : {}) });
      const evs = [row({ ...variant.fix, score: '1 - 0' }), row({ ...variant.next, score: '2 - 0' })];
      const [kFix, kNew] = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, events: evs }).map((e) => e.eventKey);
      const order = kNew < kFix ? 'new-first' : 'correction-first';
      if (orders.has(order)) continue;
      orders.add(order);
      await record(db, fixture(s, { minute: 5 }));
      await record(db, fixture(s, { home: 1, minute: 11, events: [row({ time: '10', score: '1 - 0' })] }));
      await record(db, fixture(s, { home: 2, minute: 41, events: evs }));
      const nextPlayer = variant.next.player === 'P2' ? s.p2 : s.p1;
      assert.deepEqual(minutes(await ofType(db, s.match, 'GOAL')), [`${variant.fix.time}' ${s.p1}`, `${variant.next.time}' ${nextPlayer}`], order);
      assert.deepEqual(await pushedGoals(db, s.match), [`10' ${s.p1}`, `${variant.next.time}' ${nextPlayer}`].sort(), `${order}: one push per goal`);
      assert.equal(await active(db, s.match, 'GOAL'), 2, order);
    }
    assert.equal(orders.size, 2, 'both key orders exercised');
  }));
}

test('two real goals by the same player in the same minute without score-after (:1, :2) stay two; one annulled leaves one', () => withDb(async (db) => {
  const s = await seed(db);
  const row = (id) => ({ id, type: 'goal', time: '30', homeScorerId: `P1-${s.n}`, homeScorer: 'Nombre' });
  await record(db, fixture(s, { minute: 5 }));
  await record(db, fixture(s, { home: 1, minute: 30, events: [row('a1')] }));
  await record(db, fixture(s, { home: 2, minute: 31, events: [row('b1'), row('b2')] }));
  assert.equal((await ofType(db, s.match, 'GOAL')).length, 2);
  assert.equal(await pushes(db, s.match, 'GOAL'), 2);
  await record(db, fixture(s, { home: 1, minute: 33, events: [row('c1')] }));
  assert.equal((await ofType(db, s.match, 'GOAL')).length, 1);
  assert.equal(await pushes(db, s.match, 'GOAL'), 2);
  // The projection rule on its own: :1 and :2 of one signature never merge.
  const base = { type: 'GOAL', matchId: 'm', minute: 30, teamId: 'h', playerId: 'p', provider: 'goal_api' };
  const v = (await db.query("select futbeat_private.visible_match_events($1::jsonb,'h','a',null::jsonb) v", [JSON.stringify([
    { ...base, id: 'fb_event_1', providerEventKey: 'fallback:00000000000000aa:1' },
    { ...base, id: 'fb_event_2', providerEventKey: 'fallback:00000000000000aa:2' }])])).rows[0].v;
  assert.equal(v.length, 2);
}));

test('migration and cleanup are generic (no fixture, team, player or match literals)', async () => {
  for (const path of ['../../supabase/migrations/20260930140000_event_key_duplicates.sql',
    '../../supabase/manual/20260930140000_event_key_duplicates_cleanup.sql']) {
    const sql = await readFile(new URL(path, import.meta.url), 'utf8');
    assert.doesNotMatch(sql, /fb_match_[0-9a-f]{6,}|fb_player_[0-9a-f]{6,}|fb_team_[0-9a-f]{6,}/);
  }
});

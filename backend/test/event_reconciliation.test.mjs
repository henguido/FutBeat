import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import {
  fixtureEventSections,
  isOwnGoalRow,
  liveEventsContentSignature,
  normalizeFixtureEvents,
} from '../../supabase/functions/_shared/live_events.ts';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// P0-A: match events / goals reconciliation (corrections, annulments, own
// goals, re-issued ids, deleted cards / substitutions), against the real
// migrations in PGlite. Generic fixtures only (no real teams, fixtures or
// players). Provider shapes are UNVERIFIED: both id-present and id-absent
// rows are exercised.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
// Monotonic and never behind wall time (push devices register at now()).
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seed(db, { follow = true } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_rc${n}`, home: `fb_team_rch${n}`, away: `fb_team_rca${n}`, match: `fb_match_rc${n}`,
    ext: `goal-rc-${n}`, homeExt: `H${n}`, awayExt: `A${n}`, p1: `fb_player_rc${n}a`, p2: `fb_player_rc${n}b` };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  await put(ids.p1, 'player', { name: `Jugador A ${n}` });
  await put(ids.p2, 'player', { name: `Jugador B ${n}` });
  await put(ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: new Date(Date.now() - 3600e3).toISOString(), status: 'SCHEDULED', events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - 7200e3).toISOString() } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', ids.homeExt, ids.home], ['team', ids.awayExt, ids.away],
    ['player', `P1-${n}`, ids.p1], ['player', `P2-${n}`, ids.p2]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  if (follow) {
    const uid = randomUUID();
    await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-rc-${n}`]);
    await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, ids.match]);
  }
  return { ...ids, n };
}

// A GOAL fixture exactly as the worker normalizes it: completeSections are
// the sections present as arrays; the payload hash covers the event content
// (same inputs as futbeat-goal-live-sync normalizeLiveFixture).
function fixture(s, { home = 0, away = 0, minute = 10, status = 'LIVE', events = [], cards = [], substitutions = [], omit = [], source, extra = {} } = {}) {
  const raw = { id: s.ext, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards, substitutions, ...extra };
  for (const key of omit) delete raw[key];
  const normalized = normalizeFixtureEvents(raw);
  const completeSections = fixtureEventSections(raw);
  const obs = { externalMatchId: s.ext, status, minute, score: { home, away }, events: normalized, completeSections, rawPayload: raw,
    ...(source ? { source } : {}) };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, status, minute, home, away,
    normalized.map((event) => event.eventKey), liveEventsContentSignature(normalized, completeSections)])).digest('hex');
  return obs;
}
const goalRow = (s, { id, time, side = 'home', player = 'P1', type = 'goal', score } = {}) => ({
  ...(id ? { id } : {}), type, time, ...(score ? { score } : {}),
  ...(side === 'home' ? { homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre' } : { awayScorerId: `${player}-${s.n}`, awayScorer: 'Nombre' }),
});
const cardRow = (s, { id, time = '44', player = 'P1', card = 'Yellow Card' } = {}) => ({
  ...(id ? { id } : {}), card, time, homePlayerId: `${player}-${s.n}`, homeFault: 'Nombre' });
const subRow = (s, { id, time = '60', out = 'P1', inn = 'P2' } = {}) => ({
  ...(id ? { id } : {}), team: 'home', time, substitutionPlayerId: `${out}-${s.n}|${inn}-${s.n}` });

const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const readModel = (db, id) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v);
const visible = async (db, id) => (await readModel(db, id)).events ?? [];
const goals = async (db, id) => (await visible(db, id)).filter((e) => e.type === 'GOAL');
const ofType = async (db, id, type) => (await visible(db, id)).filter((e) => e.type === type);
const realtime = (db, id) => db.query('select latest_events v from public.live_match_updates where match_id=$1', [id]).then((r) => r.rows[0]?.v ?? []);
const realtimeGoals = async (db, id) => (await realtime(db, id)).filter((e) => e.type === 'GOAL');
const goalPushes = (db, id) => db.query("select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL'", [id]).then((r) => r.rows[0].n);
const allPushes = (db, id) => db.query('select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1', [id]).then((r) => r.rows[0].n);
const canonical = (db, id, type = 'GOAL') => db.query('select id,payload,retracted_at,retraction_reason from futbeat_private.canonical_events where match_id=$1 and event_type=$2 order by first_seen_at,id', [id, type]).then((r) => r.rows);
const revisions = (db, id) => db.query('select action,reason,event_id from futbeat_private.canonical_event_revisions where match_id=$1 order by id', [id]).then((r) => r.rows);
const summary = (list) => list.map((e) => `${e.minute}'${e.extraMinute ? `+${e.extraMinute}` : ''} ${e.teamId} ${e.playerId ?? '-'}${e.synthetic ? ' SYN' : ''}`);

// ---------------------------------------------------------------------------
// Pure normalizer / hash
// ---------------------------------------------------------------------------

test('sections: only arrays are complete; absent / null never are', () => {
  assert.deepEqual(fixtureEventSections({ events: [], cards: null, substitutions: [{}] }), ['events', 'substitutions']);
  assert.deepEqual(fixtureEventSections({}), []);
  const [goal, card, sub] = normalizeFixtureEvents({ homeTeam: { id: 'h' }, awayTeam: { id: 'a' },
    events: [{ id: '1', type: 'goal', time: '5', homeScorerId: 'x' }], cards: [{ id: '2', card: 'Red Card', time: '6', homePlayerId: 'x' }],
    substitutions: [{ id: '3', team: 'home', time: '7', substitutionPlayerId: 'x|y' }] });
  assert.deepEqual([goal.section, card.section, sub.section], ['events', 'cards', 'substitutions']);
});

test('payload hash input changes with the event content, not only with keys', () => {
  const s = { ext: 'g', homeExt: 'H', awayExt: 'A', n: 0 };
  const one = normalizeFixtureEvents({ homeTeam: { id: 'H' }, events: [goalRow(s, { id: '9001', time: '19' })] });
  const two = normalizeFixtureEvents({ homeTeam: { id: 'H' }, events: [goalRow(s, { id: '9001', time: '19', player: 'P2' })] });
  const late = normalizeFixtureEvents({ homeTeam: { id: 'H' }, events: [goalRow(s, { id: '9001', time: '25' })] });
  assert.deepEqual(one.map((e) => e.eventKey), two.map((e) => e.eventKey), 'same upstream id');
  assert.notEqual(liveEventsContentSignature(one), liveEventsContentSignature(two), 'scorer correction');
  assert.notEqual(liveEventsContentSignature(one), liveEventsContentSignature(late), 'minute correction');
  assert.equal(liveEventsContentSignature(one), liveEventsContentSignature(normalizeFixtureEvents({ homeTeam: { id: 'H' }, events: [goalRow(s, { id: '9001', time: '19' })] })));
  assert.notEqual(liveEventsContentSignature(one, ['events']), liveEventsContentSignature(one, []), 'sections are part of it');
});

test('worker hashes the normalized event content and marks full answers authoritative', async () => {
  const source = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
  assert.match(source, /liveEventsContentSignature\(events, completeSections\)/);
  assert.match(source, /fixtureEventSections\(fixture\)/);
  // The results list shape is unverified: it never retracts.
  assert.match(source, /authoritativeEvents: false,\s*source: "results"/);
  // Every answer names its path (retraction is per path).
  assert.match(source, /source: "live-list"/);
  assert.match(source, /\{ source: "detail" \}/);
});

test('own goal marker (UNVERIFIED shape): credited to the other team, player kept, detail agrees', () => {
  assert.equal(isOwnGoalRow({ type: 'own-goal' }), true);
  assert.equal(isOwnGoalRow({ type: 'Goal', isOwnGoal: true }), true);
  assert.equal(isOwnGoalRow({ type: 'OWN_GOAL' }), true);
  assert.equal(isOwnGoalRow({ type: 'goal' }), false);
  assert.equal(isOwnGoalRow({ type: 'KNOWN goal' }), false);
  const row = { id: '1', type: 'own goal', time: '19', homeScorerId: 'x', homeScorer: 'Nombre' };
  const [live] = normalizeFixtureEvents({ homeTeam: { id: 'h' }, awayTeam: { id: 'a' }, events: [row] });
  assert.deepEqual([live.type, live.teamExternalId, live.playerExternalId, live.ownGoal, live.playerTeamExternalId], ['GOAL', 'a', 'x', true, 'h']);
  const [detail] = normalizeMatchDetail({ payload: { events: [row] } }).incidents;
  assert.deepEqual([detail.type, detail.side, detail.ownGoal], ['GOAL', 'away', true]);
});

// ---------------------------------------------------------------------------
// Corrections
// ---------------------------------------------------------------------------

test('replace scorer with a stable id: updated in place, audited, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  const [before] = await canonical(db, s.match);
  await record(db, fixture(s, { home: 1, minute: 22, events: [goalRow(s, { id: '9001', time: '19', player: 'P2' })] }));
  const shown = await goals(db, s.match);
  assert.deepEqual(summary(shown), [`19' ${s.home} ${s.p2}`]);
  assert.equal(shown[0].id, before.id, 'same canonical identity');
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`19' ${s.home} ${s.p2}`]);
  assert.equal((await canonical(db, s.match)).length, 1);
  assert.deepEqual((await revisions(db, s.match)).map((r) => r.action), ['update']);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('replace scorer without a provider id: retract old + add new, one visible, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { time: '19' })] }));
  await record(db, fixture(s, { home: 1, minute: 22, events: [goalRow(s, { time: '19', player: 'P2' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.home} ${s.p2}`]);
  assert.equal((await realtimeGoals(db, s.match)).length, 1);
  const rows = await canonical(db, s.match);
  assert.equal(rows.length, 2, 'audit keeps the old row');
  // Retracted by the provider, then consumed as the twin of its correction.
  assert.deepEqual(rows.map((r) => r.retraction_reason), ['corrected', null]);
  assert.equal(await goalPushes(db, s.match), 1, 'the correction never pushes again');
}));

test('change minute (stable id), first sighting >5 minutes late: no leftover synthetic', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 26, events: [goalRow(s, { id: '9001', time: '19' })] }));
  assert.equal((await canonical(db, s.match)).filter((r) => r.payload.synthetic).length, 0, 'late rich goal explains the score');
  await record(db, fixture(s, { home: 1, minute: 28, events: [goalRow(s, { id: '9001', time: '25' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`25' ${s.home} ${s.p1}`]);
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`25' ${s.home} ${s.p1}`]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('change minute (no provider id), first sighting late: one goal at the corrected minute', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 26, events: [goalRow(s, { time: '19' })] }));
  await record(db, fixture(s, { home: 1, minute: 28, events: [goalRow(s, { time: '25' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`25' ${s.home} ${s.p1}`]);
  assert.equal((await realtimeGoals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('annul goal (VAR, score 1 -> 0): nothing visible, realtime empty, audit retained', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { home: 0, minute: 23, events: [{ id: '9901', type: 'VAR', time: '21', info: 'Goal cancelled' }] }));
  assert.equal((await goals(db, s.match)).length, 0);
  assert.equal((await realtimeGoals(db, s.match)).length, 0);
  assert.equal((await ofType(db, s.match, 'VAR')).length, 1, 'the VAR row itself is shown');
  const [row] = await canonical(db, s.match);
  assert.ok(row.retracted_at, 'kept for audit, retracted');
  assert.equal(row.payload.playerId, s.p1);
  assert.deepEqual((await revisions(db, s.match)).map((r) => [r.action, r.reason]), [['retract', 'provider_retracted']]);
  assert.equal((await readModel(db, s.match)).scoreMismatch, undefined);
  // The same goal restored (VAR reversed): back, never pushed twice.
  await record(db, fixture(s, { home: 1, minute: 25, events: [goalRow(s, { id: '9001', time: '19' })] }));
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('annul a synthetic-only goal: the score drop hides it', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20 }));
  assert.equal((await goals(db, s.match)).length, 1);
  await record(db, fixture(s, { home: 0, minute: 23 }));
  assert.equal((await goals(db, s.match)).length, 0);
  assert.equal((await realtimeGoals(db, s.match)).length, 0);
  assert.equal((await canonical(db, s.match)).length, 1, 'audit keeps the synthetic row');
}));

test('own goal correction (1-0 -> 0-1): credited to the benefiting team, no synthetic, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { away: 1, minute: 22, events: [goalRow(s, { id: '9001', time: '19', type: 'own-goal', score: '0 - 1' })] }));
  const shown = await goals(db, s.match);
  assert.deepEqual(summary(shown), [`19' ${s.away} ${s.p1}`]);
  assert.equal(shown[0].ownGoal, true);
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`19' ${s.away} ${s.p1}`]);
  assert.equal((await canonical(db, s.match)).filter((r) => r.payload.synthetic).length, 0);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('own goal without a provider id: retract + add across teams is one logical goal (one push)', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { time: '19' })] }));
  await record(db, fixture(s, { away: 1, minute: 22, events: [goalRow(s, { time: '19', type: 'own goal' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.away} ${s.p1}`]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('correct team (stable id, home -> away with the score): one goal on the right side', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19', player: 'P2' })] }));
  await record(db, fixture(s, { away: 1, minute: 22, events: [goalRow(s, { id: '9001', time: '19', side: 'away', player: 'P2' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.away} ${s.p2}`]);
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`19' ${s.away} ${s.p2}`]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('delete obsolete card and substitution; update other events with the same id', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { minute: 61, cards: [cardRow(s, { id: 'c1' }), cardRow(s, { id: 'c2', time: '50', player: 'P2' })],
    substitutions: [subRow(s, { id: 's1' }), subRow(s, { id: 's2', time: '61', out: 'P2', inn: 'P1' })] }));
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 2);
  assert.equal((await ofType(db, s.match, 'SUBSTITUTION')).length, 2);
  const pushes = await allPushes(db, s.match);
  // c1 deleted, c2 corrected (minute + player, now red); s1 deleted, s2 corrected.
  await record(db, fixture(s, { minute: 63, cards: [cardRow(s, { id: 'c2', time: '51', player: 'P1', card: 'Red Card' })],
    substitutions: [subRow(s, { id: 's2', time: '62', out: 'P2', inn: 'P1' })] }));
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 0);
  const [red] = await ofType(db, s.match, 'RED_CARD');
  assert.deepEqual([red.minute, red.playerId], [51, s.p1]);
  const subs = await ofType(db, s.match, 'SUBSTITUTION');
  assert.deepEqual(subs.map((e) => [e.minute, e.playerId, e.assistPlayerId]), [[62, s.p2, s.p1]]);
  assert.equal((await realtime(db, s.match)).filter((e) => ['YELLOW_CARD', 'RED_CARD', 'SUBSTITUTION'].includes(e.type)).length, 2);
  assert.equal(await allPushes(db, s.match), pushes, 'corrections and deletions never push');
}));

// ---------------------------------------------------------------------------
// No duplicates
// ---------------------------------------------------------------------------

test('no duplicates across re-polls: identical answers are duplicates, nothing is rewritten', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const g = goalRow(s, { id: '9001', time: '19' });
  await record(db, fixture(s, { home: 1, minute: 20, events: [g] }));
  const again = await record(db, fixture(s, { home: 1, minute: 20, events: [g] }));
  assert.equal(again.duplicates, 1);
  for (const minute of [21, 22, 23]) await record(db, fixture(s, { home: 1, minute, events: [g] }));
  assert.equal((await canonical(db, s.match)).length, 1);
  assert.equal((await revisions(db, s.match)).length, 0, 'unchanged content is never rewritten');
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('provider re-issues a new id for the same goal: one visible, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { home: 1, minute: 22, events: [goalRow(s, { id: '9005', time: '20' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`20' ${s.home} ${s.p1}`]);
  assert.equal((await realtimeGoals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
  // Same content re-issued (identical content id): still one.
  await record(db, fixture(s, { home: 1, minute: 24, events: [goalRow(s, { id: '9007', time: '20' })] }));
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('a re-keyed copy in a non-authoritative answer: its own row (no ping-pong), shown once, never a second push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  for (const minute of [22, 23]) {
    const partial = fixture(s, { home: 1, minute, events: [goalRow(s, { id: '9001-b', time: '19' })] });
    delete partial.completeSections;
    await record(db, partial);
  }
  // One canonical row per provider id (no shared row, nothing rewritten);
  // the exact copy is shown once and never pushed.
  assert.equal((await canonical(db, s.match)).length, 2, 'one row per provider id');
  assert.equal((await revisions(db, s.match)).length, 0, 'no key ping-pong');
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('synthetic first, rich much later (> 3 minutes apart): one visible, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 30 }));
  await record(db, fixture(s, { home: 1, minute: 40, events: [goalRow(s, { id: '9001', time: '23' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`23' ${s.home} ${s.p1}`]);
  assert.equal((await realtimeGoals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
  // A second goal only in the score: exactly the deficit is synthetic.
  await record(db, fixture(s, { home: 2, minute: 44, events: [goalRow(s, { id: '9001', time: '23' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`23' ${s.home} ${s.p1}`, `44' ${s.home} - SYN`]);
  assert.equal(await goalPushes(db, s.match), 2);
}));

test('absent section never retracts; an empty array does', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 45, events: [goalRow(s, { id: '9001', time: '19' })], cards: [cardRow(s, { id: 'c1' })] }));
  // events / cards keys absent (or null): nothing retracted.
  await record(db, fixture(s, { home: 1, minute: 46, omit: ['events', 'cards'] }));
  const nullSections = fixture(s, { home: 1, minute: 47 });
  nullSections.rawPayload.events = null; nullSections.completeSections = ['substitutions'];
  await record(db, nullSections);
  // An observation without completeSections (older worker / results list).
  const legacy = fixture(s, { home: 1, minute: 48 });
  delete legacy.completeSections;
  await record(db, legacy);
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 1);
  // Explicit empty arrays retract (cards at once; a goal only when the score
  // no longer requires it).
  await record(db, fixture(s, { home: 1, minute: 49, events: [], cards: [] }));
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 0);
  assert.equal((await goals(db, s.match)).length, 1, 'score 1 still requires the goal');
  await record(db, fixture(s, { home: 0, minute: 50, events: [], cards: [] }));
  assert.equal((await goals(db, s.match)).length, 0, 'rich goal retracted with the score');
}));

// ---------------------------------------------------------------------------
// Score authority
// ---------------------------------------------------------------------------

test('rich goals above the score: kept, scoreMismatch flagged', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 30, events: [goalRow(s, { id: '9001', time: '19' }), goalRow(s, { id: '9002', time: '28', player: 'P2' })] }));
  const model = await readModel(db, s.match);
  assert.equal(model.events.filter((e) => e.type === 'GOAL').length, 2, 'rich goals are never hidden by the score');
  assert.equal(model.scoreMismatch, true);
  await record(db, fixture(s, { home: 2, minute: 31, events: [goalRow(s, { id: '9001', time: '19' }), goalRow(s, { id: '9002', time: '28', player: 'P2' })] }));
  assert.equal((await readModel(db, s.match)).scoreMismatch, undefined);
  assert.equal((await goals(db, s.match)).length, 2, 'no synthetic: the rich goals explain the score');
}));

test('exactly one push per logical goal through a chain of corrections', () => withDb(async (db) => {
  const s = await seed(db);
  const uid = randomUUID();
  await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-rcp-${s.n}`]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'player',$2)", [uid, s.p2]);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20 }));                                       // synthetic
  await record(db, fixture(s, { home: 1, minute: 21, events: [goalRow(s, { time: '19' })] }));  // rich, no id
  await record(db, fixture(s, { home: 1, minute: 22, events: [goalRow(s, { time: '19', player: 'P2' })] })); // scorer fix
  await record(db, fixture(s, { home: 1, minute: 23, events: [goalRow(s, { id: '9010', time: '19', player: 'P2' })] })); // id appears
  await record(db, fixture(s, { home: 1, minute: 24, events: [goalRow(s, { id: '9010', time: '20', player: 'P2' })] })); // minute fix
  assert.deepEqual(summary(await goals(db, s.match)), [`20' ${s.home} ${s.p2}`]);
  const outbox = (await db.query("select o.user_id,o.event_id from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL'", [s.match])).rows;
  assert.equal(outbox.length, 1, 'one push to the match follower, none to the late player follower');
}));

// ---------------------------------------------------------------------------
// Detail cache
// ---------------------------------------------------------------------------

test('detail cache: a present shorter / empty array replaces, an absent key preserves', () => withDb(async (db) => {
  const s = await seed(db);
  const g = (id, t) => ({ id, type: 'goal', time: t, homeScorer: 'Nombre', homeScorerId: `P1-${s.n}`, score: '1 - 0' });
  let at = Date.now() - 60e3;
  const store = (payload) => db.query('select futbeat_private.store_match_detail($1,$2,$3,$4)', [s.match, s.ext, new Date((at += 1000)).toISOString(),
    JSON.stringify({ homeTeamScore: '1', awayTeamScore: '0', ...payload })]);
  const cached = () => db.query('select payload from futbeat_private.match_detail_cache where match_id=$1', [s.match]).then((r) => r.rows[0].payload);
  await store({ events: [g('9001', '19'), g('9002', '30')], cards: [cardRow(s, { id: 'c1' }), cardRow(s, { id: 'c2' })], substitutions: [subRow(s, { id: 's1' })] });
  await store({ events: [g('9002', '30')], cards: [cardRow(s, { id: 'c2' })], substitutions: [] });
  let payload = await cached();
  assert.deepEqual(payload.events.map((e) => e.id), ['9002'], 'shorter list replaces');
  assert.deepEqual(payload.cards.map((e) => e.id), ['c2']);
  assert.deepEqual(payload.substitutions, [], 'empty list replaces');
  await store({ matchStatus: 'LIVE' });
  payload = await cached();
  assert.deepEqual(payload.events.map((e) => e.id), ['9002'], 'absent key preserves');
  assert.deepEqual(payload.cards.map((e) => e.id), ['c2']);
  await store({ events: null, cards: [] });
  payload = await cached();
  assert.deepEqual(payload.events.map((e) => e.id), ['9002'], 'null (not an array) preserves');
  assert.deepEqual(payload.cards, []);
  await store({ events: [] });
  assert.deepEqual((await cached()).events.map((e) => e.id), ['9002'], 'score 1-0 still requires the goal');
  await store({ events: [], homeTeamScore: '0' });
  assert.deepEqual((await cached()).events, [], 'annulled goal (score 0-0): empty array replaces');
}));

// ---------------------------------------------------------------------------
// Legacy rows
// ---------------------------------------------------------------------------

test('legacy rows reconcile on the next complete observation', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  // Pre-P0-A state: the first observation (stored exactly as before) ...
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  const [original] = await canonical(db, s.match);
  const insert = (id, payload, ago = 0) => db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values($1,$2,'goal_api','GOAL',$3,now()-make_interval(mins=>$4))`, [id, s.match, JSON.stringify({ id, matchId: s.match, type: 'GOAL', ...payload }), ago]);
  // ... plus a later content-id row of the same upstream key, a pre-#121 row
  // without a key for a goal the provider no longer lists, and a leftover
  // synthetic from the old 3-minute folding.
  await insert('fb_event_legacy_dup', { minute: 19, teamId: s.home, playerId: s.p1, providerEventKey: '9001', provider: 'goal_api' }, -1);
  await insert('fb_event_legacy_nokey', { minute: 33, teamId: s.home, playerId: s.p2 });
  await insert('fb_event_legacy_syn', { minute: 26, teamId: s.home, synthetic: true, score: { home: 1, away: 0 }, detail: 'Marcador actualizado' });
  assert.ok((await goals(db, s.match)).length >= 2, 'legacy state shows duplicates');
  // The provider corrects the scorer (complete answer).
  await record(db, fixture(s, { home: 1, minute: 34, events: [goalRow(s, { id: '9001', time: '19', player: 'P2' })] }));
  const shown = await goals(db, s.match);
  assert.deepEqual(summary(shown), [`19' ${s.home} ${s.p2}`]);
  assert.equal(shown[0].id, original.id, 'the original id (and its push) keeps the identity');
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`19' ${s.home} ${s.p2}`]);
  const reasons = Object.fromEntries((await canonical(db, s.match)).map((r) => [r.id, r.retraction_reason]));
  assert.equal(reasons.fb_event_legacy_dup, 'superseded');
  assert.equal(reasons.fb_event_legacy_nokey, 'absent_from_snapshot');
  assert.equal(reasons.fb_event_legacy_syn, null, 'synthetic rows are only hidden by the projection');
  // A match payload copy of retracted rows (results lifecycle) is never re-injected.
  await db.query(`update futbeat_private.entities set payload=jsonb_set(payload,'{events}',
    (select jsonb_agg(payload) from futbeat_private.canonical_events where match_id=$1)) where id=$1`, [s.match]);
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.home} ${s.p2}`]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

// ---------------------------------------------------------------------------
// Review follow-up (P1 / P2)
// ---------------------------------------------------------------------------

test('P1-1 A: VAR annuls synthetic + rich goal; the next real goal pushes once at its own minute', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 10 }));                                       // synthetic S1
  await record(db, fixture(s, { home: 1, minute: 11, events: [goalRow(s, { id: '9001', time: '10' })] }));
  assert.equal(await goalPushes(db, s.match), 1);
  await record(db, fixture(s, { home: 0, minute: 13, events: [] }));                           // VAR
  const syn = (await canonical(db, s.match)).find((r) => r.payload.synthetic);
  assert.equal(syn.retraction_reason, 'score_decrease');
  assert.ok((await revisions(db, s.match)).some((r) => r.reason === 'score_decrease'), 'audited');
  assert.equal((await goals(db, s.match)).length, 0);
  await record(db, fixture(s, { home: 1, minute: 31, events: [goalRow(s, { id: '9002', time: '30', player: 'P2' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`30' ${s.home} ${s.p2}`]);
  assert.deepEqual(summary(await realtimeGoals(db, s.match)), [`30' ${s.home} ${s.p2}`]);
  assert.equal(await goalPushes(db, s.match), 2, 'the second real goal pushes exactly once');
}));

test('P1-1 B: synthetic-only 1-0 -> 0-0 -> 1-0: the new goal pushes and shows its own minute', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 10 }));
  await record(db, fixture(s, { home: 0, minute: 13 }));
  assert.equal((await goals(db, s.match)).length, 0);
  await record(db, fixture(s, { home: 1, minute: 40 }));
  assert.deepEqual(summary(await goals(db, s.match)), [`40' ${s.home} - SYN`]);
  assert.equal(await goalPushes(db, s.match), 2);
  // Another increase with the same ordinal never repeats that push.
  await record(db, fixture(s, { home: 1, minute: 41 }));
  assert.equal(await goalPushes(db, s.match), 2);
}));

test('P1-2 D: a transient empty list answer never retracts a goal the score requires (no flicker)', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const g = goalRow(s, { id: '9001', time: '10' });
  await record(db, fixture(s, { home: 1, minute: 10, events: [g], source: 'live-list' }));
  await record(db, fixture(s, { home: 1, minute: 11, events: [], source: 'live-list' }));
  assert.equal((await goals(db, s.match)).length, 1, 'no flicker');
  assert.equal((await realtimeGoals(db, s.match)).length, 1);
  await record(db, fixture(s, { home: 1, minute: 12, events: [g], source: 'live-list' }));
  assert.equal((await revisions(db, s.match)).length, 0, 'no audit churn');
  const [live] = (await db.query('select revision,retracted_at from futbeat_private.live_events where external_match_id=$1', [s.ext])).rows;
  assert.deepEqual([live.revision, live.retracted_at], [1, null]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('P1-2: list vs detail answers only retract rows last seen on their own path', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  // The detail answer lists a card the (partial) live list does not.
  await record(db, fixture(s, { minute: 40, cards: [cardRow(s, { id: 'c1' })], source: 'detail' }));
  for (const minute of [41, 42]) await record(db, fixture(s, { minute, cards: [], source: 'live-list' }));
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 1, 'the list never undoes the detail row');
  assert.equal((await revisions(db, s.match)).length, 0);
  // Once the list itself has seen it, the list's complete answer may drop it.
  await record(db, fixture(s, { minute: 43, cards: [cardRow(s, { id: 'c1' })], source: 'live-list' }));
  await record(db, fixture(s, { minute: 44, cards: [], source: 'live-list' }));
  assert.equal((await ofType(db, s.match, 'YELLOW_CARD')).length, 0);
  // A genuine annulment (score drops) still retracts on either path.
  await record(db, fixture(s, { home: 1, minute: 50, events: [goalRow(s, { id: '9001', time: '49' })], source: 'live-list' }));
  await record(db, fixture(s, { home: 0, minute: 52, events: [], source: 'live-list' }));
  assert.equal((await goals(db, s.match)).length, 0);
}));

test('P2-1: annul one goal and a different player scores in the same poll: the new goal pushes', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 10, events: [goalRow(s, { id: '9001', time: '10' })] }));
  await record(db, fixture(s, { home: 1, minute: 31, events: [goalRow(s, { id: '9002', time: '30', player: 'P2' })] }));
  assert.deepEqual(summary(await goals(db, s.match)), [`30' ${s.home} ${s.p2}`]);
  assert.equal(await goalPushes(db, s.match), 2);
  const reasons = (await canonical(db, s.match)).map((r) => r.retraction_reason);
  assert.deepEqual(reasons, ['provider_retracted', null], 'the annulled goal is not a correction twin');
}));

test('P2-2: two provider ids with the same content are two rows; re-polls never ping-pong', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const rows = [goalRow(s, { id: '7001', time: '12' }), goalRow(s, { id: '7002', time: '12' })];
  // Score 1-0: the second id is a surplus copy (shown once, never pushed).
  for (const minute of [13, 14, 15]) await record(db, fixture(s, { home: 1, minute, events: rows }));
  const stored = await canonical(db, s.match);
  assert.equal(stored.length, 2);
  assert.deepEqual(stored.map((r) => r.payload.providerEventKey).sort(), ['7001', '7002']);
  assert.equal((await revisions(db, s.match)).length, 0, 'no audit churn');
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('P2-2: two provider ids with the same content at score 2-0 are two goals and two pushes', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const rows = [goalRow(s, { id: '7101', time: '12' }), goalRow(s, { id: '7102', time: '12' })];
  await record(db, fixture(s, { home: 2, minute: 13, events: rows }));
  await record(db, fixture(s, { home: 2, minute: 14, events: rows }));
  assert.equal((await goals(db, s.match)).length, 2);
  assert.equal((await readModel(db, s.match)).scoreMismatch, undefined);
  assert.equal(await goalPushes(db, s.match), 2);
  assert.equal((await revisions(db, s.match)).length, 0);
}));

test('P2-3: a pending push of a retracted event is cancelled at claim; a correction keeps its push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 10, events: [goalRow(s, { id: '9001', time: '10' })] }));
  await record(db, fixture(s, { home: 0, minute: 12, events: [] }));
  const t = await seed(db);
  await record(db, fixture(t));
  await record(db, fixture(t, { home: 1, minute: 10, events: [goalRow(t, { time: '10' })] }));
  await record(db, fixture(t, { home: 1, minute: 12, events: [goalRow(t, { time: '10', player: 'P2' })] }));
  await db.query("select public.futbeat_claim_notifications('dry_run',100)");
  const state = (match) => db.query('select o.state from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1', [match]).then((r) => r.rows.map((x) => x.state));
  assert.deepEqual(await state(s.match), ['cancelled'], 'annulled goal never sent');
  assert.deepEqual(await state(t.match), ['sending'], 'the corrected goal is still announced once');
}));

test('P2-5: identical normalized content with a different raw row never bumps a revision', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const base = goalRow(s, { id: '9001', time: '10' });
  await record(db, fixture(s, { home: 1, minute: 10, events: [base], source: 'live-list' }));
  await record(db, fixture(s, { home: 1, minute: 11, events: [{ ...base, lastUpdated: 'x1', homeScorer: 'N. Ombre' }], source: 'detail' }));
  await record(db, fixture(s, { home: 1, minute: 12, events: [{ ...base, lastUpdated: 'x2' }], source: 'live-list' }));
  const [live] = (await db.query('select revision,updated_at from futbeat_private.live_events where external_match_id=$1', [s.ext])).rows;
  assert.deepEqual([live.revision, live.updated_at], [1, null]);
  assert.equal((await revisions(db, s.match)).length, 0);
  assert.equal(await goalPushes(db, s.match), 1);
}));

// ---------------------------------------------------------------------------
// Re-review follow-up (cross-path authority)
// ---------------------------------------------------------------------------

test('E: a full-time detail answer corrects a list-only goal (no provider id): one goal, one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { source: 'live-list' }));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { time: '19' })], source: 'live-list' }));
  await record(db, fixture(s, { home: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION',
    events: [goalRow(s, { time: '19', player: 'P2' })], source: 'detail' }));
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.home} ${s.p2}`]);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('F: annulled right after a detail sighting: the list answer at 0-0 removes it at once', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { source: 'live-list' }));
  const g = goalRow(s, { id: '9001', time: '19' });
  await record(db, fixture(s, { home: 1, minute: 20, events: [g], source: 'live-list' }));
  await record(db, fixture(s, { home: 1, minute: 21, events: [g], source: 'detail' }));
  await record(db, fixture(s, { home: 0, minute: 23, events: [], source: 'live-list' }));
  assert.equal((await goals(db, s.match)).length, 0);
  assert.equal((await realtimeGoals(db, s.match)).length, 0);
}));

test('G: a pre-deploy row (no recorded path) annulled 0-0 by a list answer is retracted', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { home: 0, minute: 23, events: [], source: 'live-list' }));
  assert.equal((await goals(db, s.match)).length, 0);
  const [row] = await canonical(db, s.match);
  assert.ok(row.retracted_at);
}));

test('a list answer never retracts detail-seen rows while the score holds; score evidence trims any path', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { source: 'live-list' }));
  const g1 = goalRow(s, { id: '9001', time: '19' }), g2 = goalRow(s, { id: '9002', time: '40', player: 'P2' });
  await record(db, fixture(s, { home: 2, minute: 41, events: [g1, g2], source: 'detail' }));
  await record(db, fixture(s, { home: 2, minute: 42, events: [g1], source: 'live-list' }));
  assert.equal((await goals(db, s.match)).length, 2, 'detail-seen goal kept (score 2)');
  // Score 1: exactly one unlisted goal goes, whatever its path.
  await record(db, fixture(s, { home: 1, minute: 44, events: [g1], source: 'live-list' }));
  assert.deepEqual(summary(await goals(db, s.match)), [`19' ${s.home} ${s.p1}`]);
}));

test('P2-3b: a correction that may not notify still keeps the original push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 10, events: [goalRow(s, { time: '10' })] }));
  const [original] = await canonical(db, s.match);
  const at = tick();
  const match = (await db.query('select payload from futbeat_private.entities where id=$1', [s.match])).rows[0].payload;
  await db.query("select futbeat_private.retract_canonical_event($1,$2,'provider_retracted')", [original.id, at]);
  await db.query("select futbeat_private.store_canonical_event($1,'goal_api',false,$2,$3)", [JSON.stringify({
    id: 'fb_event_correction_quiet', matchId: s.match, type: 'GOAL', minute: 10, teamId: s.home, playerId: s.p2,
    providerEventKey: 'fallback:quiet:1', provider: 'goal_api' }), at, JSON.stringify(match)]);
  assert.equal((await canonical(db, s.match)).find((r) => r.id === original.id).retraction_reason, 'corrected');
  await db.query("select public.futbeat_claim_notifications('dry_run',100)");
  const states = (await db.query('select o.state from futbeat_private.notification_outbox o where o.event_id=$1', [original.id])).rows.map((r) => r.state);
  assert.deepEqual(states, ['sending'], 'the original push is still sent');
}));

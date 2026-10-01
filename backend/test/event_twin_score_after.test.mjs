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

// Correction twins decided by the score after the goal (20261001120000). A
// correction (new content key) and a genuinely new goal of the same team in
// ONE answer: the correction claims the retracted row (no second push), the
// new goal pushes. A goal that raises its team's tally above the retracted
// row's is never that row's correction. Generic fixtures only.

let shared;
async function getDb() { if (!shared) shared = await openDatabase(); return shared; }
test.after(async () => { if (shared) await shared.close(); });

let seq = 0;
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seed(db) {
  const n = ++seq;
  const ids = { comp: `fb_comp_ts${n}`, home: `fb_team_tsh${n}`, away: `fb_team_tsa${n}`, match: `fb_match_ts${n}`,
    ext: `goal-ts-${n}`, homeExt: `H${n}`, awayExt: `A${n}`, p1: `fb_player_ts${n}a`, p2: `fb_player_ts${n}b`, p3: `fb_player_ts${n}c` };
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
  await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-ts-${n}`]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, ids.match]);
  return { ...ids, n };
}

function fixture(s, { home = 0, away = 0, minute = 10, events = [] } = {}) {
  const raw = { id: s.ext, matchStatus: 'LIVE', matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards: [], substitutions: [] };
  const normalized = normalizeFixtureEvents(raw);
  const completeSections = fixtureEventSections(raw);
  const obs = { externalMatchId: s.ext, status: 'LIVE', minute, score: { home, away }, events: normalized, rawPayload: raw,
    completeSections, source: 'live-list' };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, minute, home, away,
    normalized.map((e) => e.eventKey), liveEventsContentSignature(normalized, completeSections)])).digest('hex');
  return obs;
}
let rid = 0;
// Every answer re-issues GOAL row ids (as measured): the id is never identity.
const G = (s, { time, side = 'home', player = 'P1', score, assist }) => ({ id: `r${++rid}`, type: 'goal', time, score,
  ...(side === 'home' ? { homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre', ...(assist ? { homeAssistId: `${assist}-${s.n}` } : {}) }
    : { awayScorerId: `${player}-${s.n}`, awayScorer: 'Nombre', ...(assist ? { awayAssistId: `${assist}-${s.n}` } : {}) }) });

const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const readModel = (db, id) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v);
const label = (s, minute, playerId) => `${minute}'${{ [s.p1]: 'a', [s.p2]: 'b', [s.p3]: 'c' }[playerId] ?? '?'}`;
const shown = async (db, s) => ((await readModel(db, s.match)).events ?? []).filter((e) => e.type === 'GOAL').map((e) => label(s, e.minute, e.playerId));
const pushed = (db, s) => db.query(`select e.payload->>'minute' m, e.payload->>'playerId' p from futbeat_private.notification_outbox o
  join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL'`, [s.match])
  .then((r) => r.rows.map((x) => label(s, x.m, x.p)).sort());
const activeGoals = (db, s) => db.query("select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL' and retracted_at is null", [s.match]).then((r) => r.rows[0].n);

// Runs a scenario until both key orders of the last answer's first two rows
// were exercised (keys are content hashes: the order depends on the seed).
async function scenario(build, expectPushed, expectShown) {
  const db = await getDb();
  const orders = new Set();
  for (let i = 0; i < 40 && orders.size < 2; i++) {
    const s = await seed(db);
    const answers = build(s);
    const last = answers.at(-1).events;
    const [k0, k1] = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events: last }).map((e) => e.eventKey);
    const order = k0 < k1 ? 'correction-key-first' : 'new-key-first';
    if (orders.has(order)) continue;
    orders.add(order);
    for (const a of answers) await record(db, fixture(s, a));
    assert.deepEqual(await pushed(db, s), [...expectPushed].sort(), `${order}: one push per goal`);
    // Same-minute goals may be listed in either order.
    assert.deepEqual((await shown(db, s)).sort(), [...expectShown].sort(), `${order}: timeline`);
    assert.equal(await activeGoals(db, s), expectShown.length, order);
  }
  assert.equal(orders.size, 2, 'both key orders exercised');
}

test('minute corrected 10\' -> 14\' while the same player scores at 11\' in the same answer', () => scenario((s) => [
  { minute: 5 },
  { home: 1, minute: 11, events: [G(s, { time: '10', score: '1 - 0' })] },
  { home: 2, minute: 15, events: [G(s, { time: '14', score: '1 - 0' }), G(s, { time: '11', score: '2 - 0' })] },
], ["10'a", "11'a"], ["11'a", "14'a"]));

test('tie: scorer corrected at 10\' and a team-mate scores at 10\' (key order never decides)', () => scenario((s) => [
  { minute: 5 },
  { home: 1, minute: 10, events: [G(s, { time: '10', score: '1 - 0' })] },
  { home: 2, minute: 11, events: [G(s, { time: '10', player: 'P3', score: '1 - 0' }), G(s, { time: '10', player: 'P2', score: '2 - 0' })] },
], ["10'a", "10'b"], ["10'c", "10'b"]));

test('annulment + rewritten score + the same player scoring later', () => scenario((s) => [
  { minute: 5 },
  { home: 2, minute: 19, events: [G(s, { time: '10', score: '1 - 0' }), G(s, { time: '18', player: 'P2', score: '2 - 0' })] },
  { home: 2, minute: 26, events: [G(s, { time: '18', player: 'P2', score: '1 - 0' }), G(s, { time: '25', score: '2 - 0' })] },
], ["10'a", "18'b", "25'a"], ["18'b", "25'a"]));

test('scorer and minute corrected (10\' -> 14\') while a team-mate scores at 11\'', () => scenario((s) => [
  { minute: 5 },
  { home: 1, minute: 11, events: [G(s, { time: '10', score: '1 - 0' })] },
  { home: 2, minute: 15, events: [G(s, { time: '14', player: 'P3', score: '1 - 0' }), G(s, { time: '11', player: 'P2', score: '2 - 0' })] },
], ["10'a", "11'b"], ["11'b", "14'c"]));

test('a correction that also lists an earlier goal of the other team keeps its push (per-team tally)', () => scenario((s) => [
  { minute: 5 },
  { home: 1, minute: 11, events: [G(s, { time: '10', score: '1 - 0' })] },
  { home: 1, away: 1, minute: 13, events: [G(s, { time: '12', score: '1 - 1' }), G(s, { time: '6', side: 'away', player: 'P3', score: '0 - 1' })] },
], ["10'a", "6'c"], ["6'c", "12'a"]));

test('event_correction_twin: a goal raising its team tally is never a twin; the same score-after is preferred', async () => {
  const db = await getDb();
  const s = await seed(db);
  const at = new Date().toISOString();
  const put = async (id, payload, reason) => {
    await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,notify_candidate,first_seen_at,retracted_at,retraction_reason)
      values($1,$2,'goal_api','GOAL',$3,false,$4,$4,$5)`, [id, s.match, JSON.stringify({ id, matchId: s.match, type: 'GOAL', ...payload }), at, reason]);
  };
  await put('fb_event_t_old1', { minute: 10, teamId: s.home, playerId: s.p1, score: { home: 1, away: 0 } }, 'absent_from_snapshot');
  await put('fb_event_t_old2', { minute: 20, teamId: s.home, playerId: s.p2, score: { home: 2, away: 0 } }, 'absent_from_snapshot');
  const twin = (ev) => db.query('select futbeat_private.event_correction_twin($1::jsonb,$2) v',
    [JSON.stringify({ id: 'fb_event_t_new', matchId: s.match, type: 'GOAL', ...ev }), at]).then((r) => r.rows[0].v);
  assert.equal(await twin({ minute: 11, teamId: s.home, playerId: s.p1, score: { home: 2, away: 0 } }), 'fb_event_t_old2',
    'same player but a higher tally than old1: only the 2-0 row can be corrected (same score-after)');
  assert.equal(await twin({ minute: 30, teamId: s.home, playerId: s.p1, score: { home: 3, away: 0 } }), null, 'a new goal');
  assert.equal(await twin({ minute: 14, teamId: s.home, playerId: s.p1, score: { home: 1, away: 0 } }), 'fb_event_t_old1');
  assert.equal(await twin({ minute: 18, teamId: s.home, playerId: s.p3, score: { home: 1, away: 0 } }), 'fb_event_t_old1',
    'same score-after preferred over the closer minute');
  assert.equal(await twin({ minute: 12, teamId: s.home, playerId: s.p3 }), 'fb_event_t_old1', 'no score-after: as before (closest minute)');
});

test('migration is generic (no fixture, team, player or match literals)', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20261001120000_event_twin_score_after.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /fb_match_[0-9a-f]{6,}|fb_player_[0-9a-f]{6,}|fb_team_[0-9a-f]{6,}/);
});

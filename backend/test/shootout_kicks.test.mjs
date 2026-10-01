import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import {
  fixtureEventSections,
  isShootoutKickRow,
  liveEventsContentSignature,
  normalizeFixtureEvents,
} from '../../supabase/functions/_shared/live_events.ts';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// Penalty shoot-out kicks (20261001110000). GOAL lists every scored kick as
// a plain "goal" row of the shoot-out phase (scoreInfoTime 'Penalty', time =
// kick round, score = shoot-out tally); a penalty scored in the match is
// info 'Penalty' with a regular phase and stays a goal. Generic fixtures.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seed(db) {
  const n = ++seq;
  const ids = { comp: `fb_comp_so${n}`, home: `fb_team_soh${n}`, away: `fb_team_soa${n}`, match: `fb_match_so${n}`,
    ext: `goal-so-${n}`, homeExt: `H${n}`, awayExt: `A${n}`, p1: `fb_player_so${n}a`, p2: `fb_player_so${n}b`, p3: `fb_player_so${n}c` };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Copa ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  for (const p of [ids.p1, ids.p2, ids.p3]) await put(p, 'player', { name: `Jugador ${p}` });
  await put(ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: new Date(Date.now() - 3 * 3600e3).toISOString(), status: 'SCHEDULED', events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - 4 * 3600e3).toISOString() } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', ids.homeExt, ids.home], ['team', ids.awayExt, ids.away],
    ['player', `P1-${n}`, ids.p1], ['player', `P2-${n}`, ids.p2], ['player', `P3-${n}`, ids.p3]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  const uid = randomUUID();
  await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-so-${n}`]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, ids.match]);
  return { ...ids, n };
}

let rid = 0;
// phase: GOAL's scoreInfoTime. info 'Penalty' marks any penalty.
const row = (s, { time, side = 'home', player = 'P1', score, phase = '2nd Half', info = null }) => ({
  id: `r${++rid}`, type: 'goal', time, score, scoreInfoTime: phase, info,
  ...(side === 'home' ? { homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre' } : { awayScorerId: `${player}-${s.n}`, awayScorer: 'Nombre' }) });
const kick = (s, { round, side, player, tally }) => row(s, { time: String(round), side, player, score: tally, phase: 'Penalty', info: 'Penalty' });

// 1-1 after extra time: an in-game penalty (home, 30') and an open-play goal
// (away, 70'), then a shoot-out won by the away side.
const inGame = (s) => [
  row(s, { time: '30', score: '1 - 0', phase: '1st Half', info: 'Penalty' }),
  row(s, { time: '70', side: 'away', player: 'P3', score: '1 - 1' }),
];
const shootout = (s) => [
  kick(s, { round: 1, side: 'home', player: 'P1', tally: '1 - 0' }),
  kick(s, { round: 1, side: 'away', player: 'P3', tally: '1 - 1' }),
  kick(s, { round: 2, side: 'away', player: 'P3', tally: '1 - 2' }),
  kick(s, { round: 3, side: 'home', player: 'P2', tally: '2 - 2' }),
  kick(s, { round: 3, side: 'away', player: 'P3', tally: '2 - 3' }),
];

// kicksAsGoals: what a worker older than isShootoutKickRow sent (every
// events[] row normalized as a goal, raw row kept as payload).
function fixture(s, { home = 1, away = 1, minute = 120, events = [], kicksAsGoals = false, complete = true } = {}) {
  const raw = { id: s.ext, matchStatus: 'LIVE', matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards: [], substitutions: [] };
  const normalized = kicksAsGoals
    ? normalizeFixtureEvents({ ...raw, events: events.map((e) => ({ ...e, scoreInfoTime: null })) })
      .map((e, i) => ({ ...e, payload: events[i] }))
    : normalizeFixtureEvents(raw);
  const completeSections = complete ? fixtureEventSections(raw) : [];
  const obs = { externalMatchId: s.ext, status: 'LIVE', minute, score: { home, away }, events: normalized, rawPayload: raw,
    ...(complete ? { completeSections, source: 'live-list' } : {}) };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, minute, home, away,
    normalized.map((e) => e.eventKey), liveEventsContentSignature(normalized, completeSections), Math.random()])).digest('hex');
  return obs;
}

const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const readModel = (db, id) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v);
const goalsShown = async (db, s) => ((await readModel(db, s.match)).events ?? []).filter((e) => e.type === 'GOAL').map((e) => `${e.minute}' ${e.playerId}`);
const activeGoals = (db, s) => db.query("select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL' and retracted_at is null", [s.match]).then((r) => r.rows[0].n);
const pushes = (db, s) => db.query("select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL'", [s.match]).then((r) => r.rows[0].n);

test('normalizers: shoot-out kicks are skipped, in-game penalties stay goals (live list and detail)', () => withDb(async (db) => {
  const s = await seed(db);
  const events = [...inGame(s), ...shootout(s)];
  assert.equal(isShootoutKickRow(events[0]), false, 'in-game penalty (info Penalty, regular phase)');
  assert.equal(isShootoutKickRow(events[2]), true);
  assert.equal(isShootoutKickRow({ type: 'goal', info: 'Penalty' }), false, 'info alone never decides');
  const live = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events });
  assert.deepEqual(live.map((e) => `${e.type} ${e.minute} ${e.playerExternalId}`), [`GOAL 30 P1-${s.n}`, `GOAL 70 P3-${s.n}`]);
  const detail = normalizeMatchDetail({ payload: { events } }).incidents;
  assert.deepEqual(detail.map((e) => `${e.type} ${e.minute} ${e.playerId}`), [`GOAL 30 P1-${s.n}`, `GOAL 70 P3-${s.n}`]);
  assert.equal(detail[0].info, 'Penalty', 'the in-game penalty keeps its marker');
  // Detail score guard counts the same goals.
  const side = (k) => db.query('select futbeat_private.detail_side_goals($1::jsonb,$2) n', [JSON.stringify(events), k]).then((r) => r.rows[0].n);
  assert.deepEqual([await side('home'), await side('away')], [1, 1]);
}));

test('current worker: a shoot-out never adds canonical goals, timeline or pushes', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { home: 0, away: 0, minute: 5 }));
  await record(db, fixture(s, { minute: 118, events: inGame(s) }));
  await record(db, fixture(s, { minute: 120, events: [...inGame(s), ...shootout(s)] }));
  assert.deepEqual(await goalsShown(db, s), [`30' ${s.p1}`, `70' ${s.p3}`]);
  assert.equal(await activeGoals(db, s), 2);
  assert.equal(await pushes(db, s), 2);
}));

test('older worker sending kicks as goals: the database never stores them; a complete answer retracts kicks stored before', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { home: 0, away: 0, minute: 5 }));
  await record(db, fixture(s, { minute: 118, events: inGame(s) }));
  await record(db, fixture(s, { minute: 120, events: [...inGame(s), ...shootout(s)], kicksAsGoals: true }));
  assert.deepEqual(await goalsShown(db, s), [`30' ${s.p1}`, `70' ${s.p3}`]);
  assert.equal(await activeGoals(db, s), 2);
  assert.equal(await pushes(db, s), 2);
  // A kick row stored by the previous record_live_events: a complete answer
  // (older worker, kicks still listed) no longer backs it.
  const [k] = (await db.query("select event_key from futbeat_private.live_events where external_match_id=$1 and payload#>>'{payload,scoreInfoTime}'='Penalty' limit 1", [s.ext])).rows;
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,notify_candidate,first_seen_at)
    values('fb_event_legacy_kick_'||$1::text,$1,'goal_api','GOAL',jsonb_build_object('id','fb_event_legacy_kick_'||$1::text,'matchId',$1::text,'type','GOAL','minute',1,'teamId',$2::text,'playerId',$3::text,'providerEventKey',$4::text,'provider','goal_api'),false,now())`,
  [s.match, s.home, s.p1, k.event_key]);
  assert.equal(await activeGoals(db, s), 3);
  await record(db, fixture(s, { minute: 121, events: [...inGame(s), ...shootout(s)], kicksAsGoals: true }));
  assert.equal(await activeGoals(db, s), 2);
  assert.deepEqual(await goalsShown(db, s), [`30' ${s.p1}`, `70' ${s.p3}`]);
  assert.equal(await pushes(db, s), 2, 'a retraction never pushes');
}));

// Rows as the previous record_live_events stored them: the kicks recorded as
// goals (their live rows then carry the raw shoot-out row, as in production).
async function legacyKicks(db, s) {
  await record(db, fixture(s, { home: 0, away: 0, minute: 5 }));
  await record(db, fixture(s, { minute: 118, events: inGame(s) }));
  const kicks = shootout(s);
  await record(db, fixture(s, { minute: 120, events: [...inGame(s), ...kicks.map((k) => ({ ...k, scoreInfoTime: null }))], complete: false }));
  await db.query(`update futbeat_private.live_events set payload=jsonb_set(payload,'{payload,scoreInfoTime}','"Penalty"')
    where external_match_id=$1 and payload#>>'{payload,info}'='Penalty' and minute<10`, [s.ext]);
}

test('manual cleanup: dry run counts, expected-count guard, retracts kicks only (audited), idempotent', () => withDb(async (db) => {
  const s = await seed(db);
  await legacyKicks(db, s);
  const kicksStored = (await db.query("select count(*)::int n from futbeat_private.live_events where external_match_id=$1 and payload#>>'{payload,scoreInfoTime}'='Penalty'", [s.ext])).rows[0].n;
  assert.equal(kicksStored, 5);
  assert.equal(await activeGoals(db, s), 7, 'two goals + five kicks before the cleanup');
  const pushedBefore = await pushes(db, s);

  const dryRun = await readFile(new URL('../../supabase/manual/20261001110000_shootout_kicks_dry_run.sql', import.meta.url), 'utf8');
  const rows = (await db.query(dryRun)).rows;
  assert.deepEqual(rows.map((r) => [r.match_id, Number(r.candidates), Number(r.ambiguous_kept)]), [[s.match, 5, 0]]);

  const cleanup = await readFile(new URL('../../supabase/manual/20261001110000_shootout_kicks_cleanup.sql', import.meta.url), 'utf8');
  await assert.rejects(db.exec(cleanup), /expected_shootout_rows/, 'refuses without an expected count');
  await assert.rejects(db.exec(`set futbeat.expected_shootout_rows='4'; ${cleanup}`), /5 rows selected, 4 expected/);
  assert.equal(await activeGoals(db, s), 7, 'a failed guard changes nothing');
  await db.exec(`set futbeat.expected_shootout_rows='5'; ${cleanup}`);
  assert.equal(await activeGoals(db, s), 2);
  assert.deepEqual(await goalsShown(db, s), [`30' ${s.p1}`, `70' ${s.p3}`], 'the in-game penalty is kept');
  const audit = (await db.query("select count(*)::int n from futbeat_private.canonical_event_revisions where match_id=$1 and reason='shootout_kick'", [s.match])).rows[0].n;
  assert.equal(audit, 5);
  const deleted = (await db.query("select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL'", [s.match])).rows[0].n;
  assert.equal(deleted, 7, 'retracted, never deleted');
  assert.equal(await pushes(db, s), pushedBefore, 'never pushed');
  assert.equal((await db.query(dryRun)).rows.length, 0);
  await db.exec(`set futbeat.expected_shootout_rows='0'; ${cleanup}`);
  assert.equal(await activeGoals(db, s), 2);
}));

test('migration and cleanup are generic (no fixture, team, player or match literals)', async () => {
  for (const path of ['../../supabase/migrations/20261001110000_shootout_kicks.sql',
    '../../supabase/manual/20261001110000_shootout_kicks_cleanup.sql',
    '../../supabase/manual/20261001110000_shootout_kicks_dry_run.sql']) {
    const sql = await readFile(new URL(path, import.meta.url), 'utf8');
    assert.doesNotMatch(sql, /fb_match_[0-9a-f]{6,}|fb_player_[0-9a-f]{6,}|fb_team_[0-9a-f]{6,}|fb_event_[0-9a-f]{6,}/);
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import {
  fixtureEventSections,
  liveEventsContentSignature,
  normalizeFixtureEvents,
} from '../../supabase/functions/_shared/live_events.ts';

// Partidos feed integrity, against the real migrations in PGlite:
//   * one canonical fixture is listed exactly once (no duplicates by
//     provider, competition or merged team identities);
//   * the latest authoritative score REPLACES the previous one (annulled
//     goal, corrected score, corrected final result).
// Generic fixtures only: no real teams, matches, dates or competitions.

const tz = 'America/Costa_Rica';
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString();

// ---------------------------------------------------------------------------
// 1. One fixture, once (evidence levels; see the migration header).
// ---------------------------------------------------------------------------

async function seedTeams(db) {
  const n = ++seq;
  const ids = { comp: `fb_comp_fi${n}`, comp2: `fb_comp_fi${n}b`, home: `fb_team_fih${n}`, alias: `fb_team_fih${n}_alias`, away: `fb_team_fia${n}`, other: `fb_team_fio${n}` };
  await put(db, ids.comp, 'competition', { name: `Liga ${n}` });
  await put(db, ids.comp2, 'competition', { name: `Otra competición ${n}` });
  for (const [id, name] of [[ids.home, 'Local'], [ids.alias, 'Local (alias)'], [ids.away, 'Visita'], [ids.other, 'Otro']]) {
    await put(db, id, 'team', { name: `${name} ${n}` });
  }
  // The alias is a second identity of the home team (merged later).
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [ids.alias, ids.home]);
  return { ...ids, n, id: (suffix) => `fb_match_fi${n}_${suffix}` };
}
// A match entity. `verified` = reconciled evidence (the real one); a calendar
// copy is PROVISIONAL. `observed` adds its own provider observation trail.
async function match(db, t, suffix, { home, away, comp, start, status = 'SCHEDULED', score = null, received = hoursAgo(200), verified = false, observed = false }) {
  const id = t.id(suffix);
  await put(db, id, 'match', { competitionId: comp ?? t.comp, homeTeamId: home ?? t.home, awayTeamId: away ?? t.away, startTime: start, status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [],
    provenance: { source: 'GOAL API', receivedAt: received, verificationStatus: verified ? 'VERIFIED' : 'PROVISIONAL' } });
  if (observed) {
    await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
      values('goal_api',$1,$2,$3,$4,$5,$6,$7,'{}')`, [`ext-${id}`, id, received, status, score?.[0] ?? null, score?.[1] ?? null,
      createHash('sha256').update(id).digest('hex')]);
  }
  return id;
}
const localDay = (db, iso) => db.query('select ($1::timestamptz at time zone $2)::date::text d', [iso, tz]).then((r) => r.rows[0].d);
async function listed(db, iso) {
  const day = await localDay(db, iso);
  const v = (await db.query('select futbeat_private.build_compact_calendar($1::date,$1::date,$2) v', [day, tz])).rows[0].v;
  return v.matches;
}
// Ids of this scenario listed on the calendar days of the given kickoffs.
async function shownIds(db, t, ...kickoffs) {
  const ids = new Set();
  for (const iso of kickoffs) for (const m of await listed(db, iso)) if (m.id.startsWith(t.id(''))) ids.add(m.id);
  return [...ids].map((id) => id.slice(t.id('').length)).sort();
}
const duplicates = (db, t, iso) => db.query('select level,kept_match_id kept,hidden_match_id hidden from futbeat_private.duplicate_calendar_fixtures(($1::timestamptz)::date-2,($1::timestamptz)::date+2) order by level,hidden_match_id', [iso])
  .then((r) => r.rows.filter((d) => d.hidden.startsWith(t.id(''))).map((d) => [d.level, d.kept.slice(t.id('').length), d.hidden.slice(t.id('').length)]));
const plus = (iso, hours) => new Date(Date.parse(iso) + hours * 3600e3).toISOString();

test('same match from two representations (provider copy, same kickoff): listed once, the verified one', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const start = hoursAgo(30);
  // Real entity: reconciled, with its own observations. Copy: a later
  // provisional ingest of the same fixture (other provider / alias team).
  await match(db, t, 'real', { start, status: 'FINISHED_PENDING_VERIFICATION', score: [2, 1], verified: true, observed: true, received: hoursAgo(28) });
  await match(db, t, 'copy', { home: t.alias, start, status: 'FINISHED_PENDING_VERIFICATION', score: [2, 1], received: hoursAgo(1) });
  await match(db, t, 'unrelated', { home: t.other, start });
  assert.deepEqual(await shownIds(db, t, start), ['real', 'unrelated']);
  assert.deepEqual(await duplicates(db, t, start), [['exact_kickoff', 'real', 'copy']]);
  // Nothing is deleted; the public read path serves the same day.
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='match' and id like $1", [`${t.id('')}%`])).rows[0].n, 3);
  const day = await localDay(db, start);
  const served = (await db.query('select public.futbeat_read_calendar_range($1,$1,$2) v', [day, tz])).rows[0].v;
  assert.deepEqual(served.matches.filter((m) => m.id.startsWith(t.id(''))).map((m) => m.id).sort(), [t.id('real'), t.id('unrelated')]);
  assert.equal(new Set(served.matches.map((m) => m.id)).size, served.matches.length);
}));

test('provider copy with a kickoff one hour off (no evidence of its own): merged; both really played: kept apart', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const start = hoursAgo(30);
  await match(db, t, 'real', { start, status: 'VERIFIED', score: [1, 0], verified: true, observed: true });
  await match(db, t, 'copy', { start: plus(start, 1), status: 'VERIFIED', score: [1, 0] });
  assert.deepEqual(await shownIds(db, t, start), ['real']);
  assert.deepEqual(await duplicates(db, t, start), [['single_evidence_3h', 'real', 'copy']]);

  // Friendly double-header: same clubs twice in one afternoon, each game
  // with its own observation trail, same competition: two games.
  const f = await seedTeams(db);
  await match(db, f, 'first', { start, status: 'VERIFIED', score: [1, 1], verified: true, observed: true });
  await match(db, f, 'second', { start: plus(start, 2), status: 'VERIFIED', score: [1, 1], verified: true, observed: true });
  assert.deepEqual(await shownIds(db, f, start, plus(start, 2)), ['first', 'second']);
  assert.deepEqual(await duplicates(db, f, start), []);
}));

test('never merged: return leg, same opponent at another time, another competition, different final scores, a team against itself', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const start = hoursAgo(54);
  await match(db, t, 'base', { start, status: 'VERIFIED', score: [2, 1], verified: true, observed: true });
  await match(db, t, 'return', { home: t.away, away: t.home, start }); // return leg, same time
  await match(db, t, 'later', { start: plus(start, 30) }); // same fixture pairing 30 h later
  await match(db, t, 'rival', { away: t.other, start }); // genuinely different fixture
  // Same clubs, same kickoff, ANOTHER competition (e.g. the women's or the
  // youth side mapped to the same team identity, a friendly): two matches.
  await match(db, t, 'othercomp', { comp: t.comp2, start });
  // Same competition and kickoff but a different final result: two games.
  await match(db, t, 'otherscore', { start, status: 'VERIFIED', score: [0, 3], verified: true });
  await match(db, t, 'self1', { home: t.other, away: t.other, start });
  await match(db, t, 'self2', { home: t.other, away: t.other, start });
  assert.deepEqual(await shownIds(db, t, start, plus(start, 30)),
    ['base', 'later', 'othercomp', 'otherscore', 'return', 'rival', 'self1', 'self2']);
  // The cross-competition pair is only reported for review, never hidden.
  assert.deepEqual(await duplicates(db, t, start), [['cross_competition_review', 'othercomp', 'base'], ['cross_competition_review', 'otherscore', 'othercomp']].sort((a, b) => a[2].localeCompare(b[2])));
}));

// A live kickoff near now whose copy 2 h later falls on the same local day:
// the scenario is one calendar day, whatever the wall clock (around local
// midnight a fixed "1 h ago" put the two on different days).
async function sameDayKickoff(db, offsets) {
  for (const h of offsets) {
    const start = hoursAgo(h);
    if (await localDay(db, start) === await localDay(db, plus(start, 2))) return start;
  }
  throw new Error('unreachable: one of the offsets keeps both kickoffs on one day');
}
const sameDayLiveKickoff = (db) => sameDayKickoff(db, [1, 2, 0]);

test('LIVE fixture vs its stale calendar copy (re-issued id, kickoff moved 2 h): only the live one', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const start = await sameDayLiveKickoff(db);
  await match(db, t, 'ghost', { start: plus(start, 2), received: hoursAgo(240) });
  await match(db, t, 'live', { start, status: 'LIVE', score: [1, 0], verified: true, observed: true, received: new Date().toISOString() });
  assert.deepEqual(await shownIds(db, t, start, plus(start, 2)), ['live']);
  assert.deepEqual(await duplicates(db, t, start), [['single_evidence_3h', 'live', 'ghost']]);
}));

// Known gap (P2): when the live kickoff and its stale copy straddle local
// midnight each day is built alone, so the copy stays listed on the next day.
test.todo('LIVE fixture vs its stale calendar copy across local midnight: the copy is hidden on its own day');

test('corrected kickoff: the scheduled ghost at the old time (another day, 18 h away) disappears once the real one is played', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const real = hoursAgo(20);
  const old = plus(real, -18);
  await match(db, t, 'ghost', { start: old, received: hoursAgo(300) });
  await match(db, t, 'real', { start: real, received: hoursAgo(300) });
  // Before anything is played there is no evidence to choose: both listed.
  assert.deepEqual(await shownIds(db, t, old, real), ['ghost', 'real']);
  assert.deepEqual(await duplicates(db, t, real), []);
  // The real one is played: the ghost is hidden from its own day.
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [t.id('real'),
    JSON.stringify({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 3, away: 2 }, provenance: { source: 'GOAL API', receivedAt: hoursAgo(18), verificationStatus: 'VERIFIED' } })]);
  assert.deepEqual(await shownIds(db, t, old, real), ['real']);
  assert.deepEqual(await duplicates(db, t, real), [['ghost_24h', 'real', 'ghost']]);
  // A ghost is only a SCHEDULED entity without evidence: an abandoned game
  // and its replay the next day are two matches.
  const r = await seedTeams(db);
  await match(db, r, 'abandoned', { start: old, status: 'ABANDONED', verified: true, observed: true });
  await match(db, r, 'replay', { start: real, status: 'VERIFIED', score: [1, 0], verified: true, observed: true });
  assert.deepEqual(await shownIds(db, r, old, real), ['abandoned', 'replay']);
}));

test('double-header: a game scheduled AFTER a played game of the same pairing is a second game, never hidden', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const first = hoursAgo(6);
  await match(db, t, 'first', { start: first, status: 'VERIFIED', score: [2, 0], verified: true, observed: true });
  await match(db, t, 'second', { start: plus(first, 5), received: hoursAgo(300) });
  assert.deepEqual(await shownIds(db, t, first, plus(first, 5)), ['first', 'second']);
  assert.deepEqual(await duplicates(db, t, first), []);
}));

test('both still scheduled, no evidence, 2 h apart: one fixture (production re-issues look exactly like this)', () => withDb(async (db) => {
  // Accepted limitation, measured in production: every such pair seen in 134
  // days was a GOAL re-issue. Once both games are really observed they are
  // kept apart (see the double-header with observations above).
  const t = await seedTeams(db);
  // About a day ahead, with both kickoffs on one local day (a fixed +30 h
  // put the later one past local midnight between 16:00 and 18:00).
  const start = await sameDayKickoff(db, [-30, -27, -33]);
  // Same evidence time for both (one ingest): the tie is decided by id.
  const received = hoursAgo(50);
  await match(db, t, 'early', { start, received });
  await match(db, t, 'late', { start: plus(start, 2), received });
  assert.deepEqual(await shownIds(db, t, start, plus(start, 2)), ['early']);
  assert.deepEqual(await duplicates(db, t, start), [['single_evidence_3h', 'early', 'late']]);
}));

test('the survivor is deterministic: verified evidence beats a newer provisional copy; equal twins by id', () => withDb(async (db) => {
  const t = await seedTeams(db);
  const start = hoursAgo(-20); // tomorrow: both scheduled
  // Same evidence time (one ingest): only the id can decide.
  const received = hoursAgo(50);
  await match(db, t, 'a', { start, received });
  await match(db, t, 'b', { start, received });
  assert.deepEqual(await shownIds(db, t, start), ['a']);
  assert.deepEqual(await shownIds(db, t, start), ['a'], 'stable across builds');
  const v = await seedTeams(db);
  await match(db, v, 'verified', { start, verified: true, received: hoursAgo(90) });
  await match(db, v, 'newer_copy', { start, received: hoursAgo(1) });
  assert.deepEqual(await shownIds(db, v, start), ['verified']);
}));

// ---------------------------------------------------------------------------
// 2. The latest authoritative score replaces the previous one.
// ---------------------------------------------------------------------------

async function seedLive(db, { started = 1 } = {}) {
  const n = ++seq;
  const s = { comp: `fb_comp_sc${n}`, home: `fb_team_sch${n}`, away: `fb_team_sca${n}`, match: `fb_match_sc${n}`,
    ext: `goal-sc-${n}`, homeExt: `SH${n}`, awayExt: `SA${n}`, player: `fb_player_sc${n}`, n };
  await put(db, s.comp, 'competition', { name: `Liga ${n}` });
  await put(db, s.home, 'team', { name: `Local ${n}` });
  await put(db, s.away, 'team', { name: `Visita ${n}` });
  await put(db, s.player, 'player', { name: `Jugador ${n}` });
  await put(db, s.match, 'match', { competitionId: s.comp, homeTeamId: s.home, awayTeamId: s.away,
    startTime: hoursAgo(started), status: 'SCHEDULED', events: [], provenance: { source: 'GOAL API', receivedAt: hoursAgo(started + 1) } });
  for (const [kind, ext, id] of [['match', s.ext, s.match], ['team', s.homeExt, s.home], ['team', s.awayExt, s.away], ['player', `SP-${n}`, s.player]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  return s;
}
// A GOAL fixture exactly as the worker normalizes it.
function observation(s, { home = 0, away = 0, minute = 10, status = 'LIVE', events = [], source } = {}) {
  const raw = { id: s.ext, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards: [], substitutions: [] };
  const normalized = normalizeFixtureEvents(raw);
  const completeSections = fixtureEventSections(raw);
  const obs = { externalMatchId: s.ext, status, minute, score: { home, away }, events: normalized, completeSections, rawPayload: raw,
    ...(source ? { source } : {}) };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, status, minute, home, away,
    normalized.map((e) => e.eventKey), liveEventsContentSignature(normalized, completeSections), ++seq])).digest('hex');
  return obs;
}
const goal = (s, id, time, side = 'home') => ({ id, type: 'goal', time,
  ...(side === 'home' ? { homeScorerId: `SP-${s.n}`, homeScorer: 'Nombre' } : { awayScorerId: `SP-${s.n}`, awayScorer: 'Nombre' }) });
const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const shown = (db, s) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [s.match]).then((r) => r.rows[0].v);
const realtime = (db, s) => db.query('select status,home_score,away_score,latest_events from public.live_match_updates where match_id=$1', [s.match]).then((r) => r.rows[0]);
const feedRow = async (db, s) => {
  const day = (await db.query('select (now() at time zone $1)::date::text d', [tz])).rows[0].d;
  const days = [day, (await db.query('select ((now() at time zone $1)::date-1)::text d', [tz])).rows[0].d];
  for (const d of days) {
    const v = (await db.query('select futbeat_private.build_compact_calendar($1::date,$1::date,$2) v', [d, tz])).rows[0].v;
    const row = v.matches.find((m) => m.id === s.match);
    if (row) return row;
  }
  return null;
};
const goalsOf = (model) => (model.events ?? []).filter((e) => e.type === 'GOAL');

test('annulled goal: snapshot 1-0, then 0-0 -> FutBeat shows 0-0 everywhere and no goal', () => withDb(async (db) => {
  const s = await seedLive(db);
  await record(db, observation(s));
  await record(db, observation(s, { home: 1, minute: 20, events: [goal(s, '501', '19')] }));
  let model = await shown(db, s);
  assert.deepEqual([model.status, model.score, goalsOf(model).length], ['LIVE', { home: 1, away: 0 }, 1]);

  await record(db, observation(s, { home: 0, minute: 23, events: [] })); // goal annulled
  model = await shown(db, s);
  assert.deepEqual(model.score, { home: 0, away: 0 });
  assert.equal(goalsOf(model).length, 0, 'the annulled goal is gone from the timeline');
  const live = await realtime(db, s);
  assert.deepEqual([live.home_score, live.away_score], [0, 0]);
  assert.equal(live.latest_events.filter((e) => e.type === 'GOAL').length, 0);
  assert.deepEqual((await feedRow(db, s)).score, { home: 0, away: 0 }, 'Partidos feed row');
}));

test('corrected score: 1-1 -> 2-1 -> 1-1 ends at 1-1 (live and final)', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 2 });
  const g1 = goal(s, '601', '10');
  const g2 = goal(s, '602', '30', 'away');
  const g3 = goal(s, '603', '70');
  await record(db, observation(s));
  await record(db, observation(s, { home: 1, away: 1, minute: 35, events: [g1, g2] }));
  await record(db, observation(s, { home: 2, away: 1, minute: 71, events: [g1, g2, g3] }));
  assert.deepEqual((await shown(db, s)).score, { home: 2, away: 1 });
  await record(db, observation(s, { home: 1, away: 1, minute: 74, events: [g1, g2] })); // correction
  let model = await shown(db, s);
  assert.deepEqual(model.score, { home: 1, away: 1 });
  assert.equal(goalsOf(model).length, 2);
  assert.deepEqual([(await realtime(db, s)).home_score, (await realtime(db, s)).away_score], [1, 1]);

  // Full time keeps the corrected result.
  await record(db, observation(s, { home: 1, away: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [g1, g2] }));
  model = await shown(db, s);
  assert.deepEqual([model.status, model.score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 1 }]);
  assert.deepEqual((await feedRow(db, s)).score, { home: 1, away: 1 });
}));

test('a final result already stored is replaced by a later provider correction (2-1 -> 1-1)', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 3 });
  const g1 = goal(s, '701', '10');
  const g2 = goal(s, '702', '30', 'away');
  const g3 = goal(s, '703', '70');
  const providerDate = (await db.query("select ((payload->>'startTime')::timestamptz at time zone 'UTC')::date::text d from futbeat_private.entities where id=$1", [s.match])).rows[0].d;
  const reconcile = () => db.query('select futbeat_private.finalize_goal_results_date($1::date,now()) v', [providerDate]);
  const stored = () => db.query("select payload->>'status' status,payload->'score' score from futbeat_private.entities where id=$1", [s.match]).then((r) => r.rows[0]);

  await record(db, observation(s));
  await record(db, observation(s, { home: 2, away: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [g1, g2, g3] }));
  await reconcile();
  assert.deepEqual(await stored(), { status: 'FINISHED_PENDING_VERIFICATION', score: { home: 2, away: 1 } }, 'canonical final stored');

  // The provider later corrects the final result.
  await record(db, observation(s, { home: 1, away: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [g1, g2], source: 'results' }));
  await reconcile();
  assert.deepEqual((await stored()).score, { home: 1, away: 1 }, 'canonical final corrected');
  const model = await shown(db, s);
  assert.deepEqual([model.status, model.score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 1 }]);
  assert.deepEqual((await feedRow(db, s)).score, { home: 1, away: 1 });
  // Status never regresses while the score is corrected.
  assert.equal((await stored()).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('a corrected final arriving outside the results reconciliation still replaces the stored final', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 3 });
  const g1 = goal(s, '801', '10');
  const g2 = goal(s, '802', '30', 'away');
  const g3 = goal(s, '803', '70');
  const providerDate = (await db.query("select ((payload->>'startTime')::timestamptz at time zone 'UTC')::date::text d from futbeat_private.entities where id=$1", [s.match])).rows[0].d;
  const stored = () => db.query("select payload->>'status' status,payload->'score' score,payload#>>'{provenance,scoreCorrected}' corrected from futbeat_private.entities where id=$1", [s.match]).then((r) => r.rows[0]);
  await record(db, observation(s));
  await record(db, observation(s, { home: 2, away: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [g1, g2, g3] }));
  await db.query('select futbeat_private.finalize_goal_results_date($1::date,now())', [providerDate]);
  assert.deepEqual((await stored()).score, { home: 2, away: 1 });

  // Correction on the LIVE path; NO results reconciliation runs afterwards.
  await record(db, observation(s, { home: 1, away: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [g1, g2] }));
  assert.deepEqual(await stored(), { status: 'FINISHED_PENDING_VERIFICATION', score: { home: 1, away: 1 }, corrected: 'true' });
  const model = await shown(db, s);
  assert.deepEqual([model.status, model.score, goalsOf(model).length], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 1 }, 2]);
  assert.deepEqual((await feedRow(db, s)).score, { home: 1, away: 1 });
  const live = await realtime(db, s);
  assert.deepEqual([live.status, live.home_score, live.away_score], ['FINISHED_PENDING_VERIFICATION', 1, 1]);

  // A lagging non-terminal answer never reopens or rewrites the final (#120).
  await record(db, observation(s, { home: 2, away: 1, minute: 88, status: 'LIVE', events: [g1, g2, g3] }));
  assert.deepEqual([(await stored()).status, (await stored()).score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 1 }]);
  assert.deepEqual((await shown(db, s)).score, { home: 1, away: 1 });
}));

test('final correction guards: VERIFIED never regresses, older evidence and other providers never rewrite', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 5 });
  const hash = () => createHash('sha256').update(String(++seq)).digest('hex');
  const insert = (provider, status, home, away, receivedAt) => db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values($1,$2,$3,$4,$5,$6,$7,$8,'{}')`, [provider, s.ext, s.match, receivedAt, status, home, away, hash()]);
  const stored = () => db.query("select payload->>'status' status,payload->'score' score from futbeat_private.entities where id=$1", [s.match]).then((r) => r.rows[0]);
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [s.match,
    JSON.stringify({ status: 'VERIFIED', score: { home: 3, away: 0 }, provenance: { source: 'GOAL API', receivedAt: hoursAgo(2) } })]);

  await insert('goal_api', 'FINISHED_PENDING_VERIFICATION', 9, 9, hoursAgo(3)); // older than canonical evidence
  assert.deepEqual(await stored(), { status: 'VERIFIED', score: { home: 3, away: 0 } });
  await insert('api_football', 'VERIFIED', 8, 8, hoursAgo(1)); // not the primary provider
  assert.deepEqual(await stored(), { status: 'VERIFIED', score: { home: 3, away: 0 } });
  await insert('goal_api', 'LIVE', 7, 7, hoursAgo(1)); // non-terminal
  assert.deepEqual(await stored(), { status: 'VERIFIED', score: { home: 3, away: 0 } });
  await insert('goal_api', 'FINISHED_PENDING_VERIFICATION', null, 2, hoursAgo(1)); // incomplete score
  assert.deepEqual(await stored(), { status: 'VERIFIED', score: { home: 3, away: 0 } });

  await insert('goal_api', 'FINISHED_PENDING_VERIFICATION', 2, 0, hoursAgo(0.5)); // real correction
  assert.deepEqual(await stored(), { status: 'VERIFIED', score: { home: 2, away: 0 } }, 'score corrected, VERIFIED kept');
  await insert('goal_api', 'FINISHED_PENDING_VERIFICATION', 3, 0, hoursAgo(0.9)); // older than the correction
  assert.deepEqual((await stored()).score, { home: 2, away: 0 });

  // Cancelled / postponed payloads are never turned into a result.
  const c = await seedLive(db, { started: 5 });
  await db.query("update futbeat_private.entities set payload=payload||'{\"status\":\"CANCELLED\"}'::jsonb where id=$1", [c.match]);
  await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api',$1,$2,now(),'FINISHED_PENDING_VERIFICATION',1,0,$3,'{}')`, [c.ext, c.match, hash()]);
  assert.equal((await db.query("select payload->>'status' s from futbeat_private.entities where id=$1", [c.match])).rows[0].s, 'CANCELLED');
}));

test('final correction safety: audited, never from before kickoff, and a confirmation rewrites nothing', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 4 });
  const hash = () => createHash('sha256').update(String(++seq)).digest('hex');
  const insert = (status, home, away, receivedAt) => db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api',$1,$2,$3,$4,$5,$6,$7,'{}')`, [s.ext, s.match, receivedAt, status, home, away, hash()]);
  const payload = () => db.query('select payload from futbeat_private.entities where id=$1', [s.match]).then((r) => r.rows[0].payload);
  // Canonical final 2-1 whose evidence predates the kickoff bookkeeping (no provenance time).
  await db.query('update futbeat_private.entities set payload=(payload-$2)||$3::jsonb where id=$1', [s.match, 'provenance',
    JSON.stringify({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 2, away: 1 } })]);

  await insert('FINISHED_PENDING_VERIFICATION', 0, 0, hoursAgo(6)); // before the kickoff (4 h ago)
  assert.deepEqual((await payload()).score, { home: 2, away: 1 });

  const before = await payload();
  await insert('FINISHED_PENDING_VERIFICATION', 2, 1, hoursAgo(1)); // confirms the stored final
  assert.deepEqual(await payload(), before, 'a confirmation never rewrites the match');

  await insert('FINISHED_PENDING_VERIFICATION', 1, 1, hoursAgo(0.5)); // real correction
  const after = await payload();
  assert.deepEqual([after.status, after.score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 1 }]);
  assert.deepEqual(after.provenance.scoreCorrectedFrom, { home: 2, away: 1 }, 'the replaced final is kept for audit');
  assert.equal(after.provenance.scoreCorrected, true);
  // Everything else in the match payload is untouched.
  for (const key of ['id', 'competitionId', 'homeTeamId', 'awayTeamId', 'startTime', 'events']) {
    assert.deepEqual(after[key], before[key], key);
  }
}));

test('final correction order: two consecutive corrections, replays, a late older observation and called-off answers', () => withDb(async (db) => {
  const s = await seedLive(db, { started: 5 });
  const hash = () => createHash('sha256').update(`order-${++seq}`).digest('hex');
  const insert = (status, home, away, receivedAt, { linked = true, payloadHash = hash() } = {}) => db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api',$1,$2,$3,$4,$5,$6,$7,'{}') on conflict do nothing`, [s.ext, linked ? s.match : null, receivedAt, status, home, away, payloadHash]);
  const payload = () => db.query('select payload from futbeat_private.entities where id=$1', [s.match]).then((r) => r.rows[0].payload);
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [s.match,
    JSON.stringify({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 2, away: 1 }, provenance: { source: 'GOAL API', receivedAt: hoursAgo(3) } })]);

  // An older terminal answer reaches the store late and unlinked...
  await insert('FINISHED_PENDING_VERIFICATION', 3, 3, hoursAgo(2.5), { linked: false });
  // ...then two real corrections in a row.
  await insert('FINISHED_PENDING_VERIFICATION', 1, 1, hoursAgo(2));
  await insert('FINISHED_PENDING_VERIFICATION', 1, 2, hoursAgo(1));
  let p = await payload();
  assert.deepEqual([p.status, p.score, p.provenance.scoreCorrectedFrom], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 2 }, { home: 1, away: 1 }]);
  const latest = JSON.stringify(p);

  // The same observation delivered twice (same hash): stored once, no write.
  const replay = hash();
  await insert('FINISHED_PENDING_VERIFICATION', 1, 2, hoursAgo(0.5), { payloadHash: replay });
  await insert('FINISHED_PENDING_VERIFICATION', 1, 2, hoursAgo(0.5), { payloadHash: replay });
  assert.equal(JSON.stringify(await payload()), latest, 'a repeated final with the same score rewrites nothing');

  // The late, older answer is linked now (UPDATE OF canonical_match_id fires
  // the trigger again): it is older than the canonical evidence, ignored.
  await db.query('update futbeat_private.provider_observations set canonical_match_id=$1 where external_match_id=$2 and canonical_match_id is null', [s.match, s.ext]);
  assert.deepEqual((await payload()).score, { home: 1, away: 2 });
  // Called-off / non-terminal answers never touch a final.
  for (const status of ['POSTPONED', 'CANCELLED', 'ABANDONED', 'SCHEDULED']) {
    await insert(status, 0, 0, new Date().toISOString());
  }
  p = await payload();
  assert.deepEqual([p.status, p.score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 2 }]);
}));

test('an incomplete observation never erases a complete score; a scheduled answer never replaces a final', () => withDb(async (db) => {
  const s = await seedLive(db);
  await record(db, observation(s));
  await record(db, observation(s, { home: 1, away: 0, minute: 20, events: [goal(s, '901', '19')] }));
  // The provider answers without a score (partial payload).
  const partial = observation(s, { minute: 25, events: [goal(s, '901', '19')] });
  // The raw answer itself has no score (GOAL answers are re-read from raw).
  partial.score = { home: null, away: null };
  partial.rawPayload = { ...partial.rawPayload, homeTeamScore: null, awayTeamScore: null };
  await record(db, partial);
  assert.deepEqual((await shown(db, s)).score, { home: 1, away: 0 }, 'the last complete score stays');

  // Full time, then a lagging "scheduled" answer: the final stands.
  await record(db, observation(s, { home: 1, away: 0, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [goal(s, '901', '19')] }));
  const lagging = await record(db, observation(s, { minute: 0, status: 'SCHEDULED' }));
  assert.equal(lagging.suppressedByCanonicalTerminal, true);
  const model = await shown(db, s);
  assert.deepEqual([model.status, model.score], ['FINISHED_PENDING_VERIFICATION', { home: 1, away: 0 }]);
  assert.equal((await realtime(db, s)).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('the authoritative source for a stored final is the PRIMARY provider of the hub, not a literal', () => withDb(async (db) => {
  const primary = () => db.query('select futbeat_private.primary_result_provider() v').then((r) => r.rows[0].v);
  assert.equal(await primary(), 'goal_api');
  const s = await seedLive(db, { started: 5 });
  const hash = () => createHash('sha256').update(String(++seq)).digest('hex');
  const insert = (provider, home, away) => db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values($1,$2,$3,now(),'FINISHED_PENDING_VERIFICATION',$4,$5,$6,'{}')`, [provider, s.ext, s.match, home, away, hash()]);
  const score = () => db.query("select payload->'score' v from futbeat_private.entities where id=$1", [s.match]).then((r) => r.rows[0].v);
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [s.match,
    JSON.stringify({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 2, away: 1 }, provenance: { source: 'GOAL API', receivedAt: hoursAgo(2) } })]);
  // Secondary and integration-only providers never rewrite the final.
  await insert('api_football', 5, 5);
  await insert('sportmonks', 6, 6);
  assert.deepEqual(await score(), { home: 2, away: 1 });
  await insert('goal_api', 1, 1);
  assert.deepEqual(await score(), { home: 1, away: 1 });
  // The production config keeps exactly one enabled PRIMARY.
  assert.deepEqual((await db.query("select provider from futbeat_private.provider_hub_config where role='PRIMARY' and enabled")).rows, [{ provider: 'goal_api' }]);
}));

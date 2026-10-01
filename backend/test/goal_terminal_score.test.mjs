import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { openDatabase } from '../storage/database.mjs';
import { goalFixtureScore } from '../../supabase/functions/_shared/live_events.ts';
import { normalizeGoalApiFixtures } from '../providers/goal_api.mjs';

// GOAL terminal result semantics (incident 2026-10-01): after a match GOAL
// can reset the running total (homeTeamScore/awayTeamScore) to 0-0 while
// homeTeamFtScore/awayTeamFtScore and the half-time score keep the result.
// One rule for every reader: goalFixtureScore (TS) and goal_fixture_score
// (SQL), exercised here on the same fixtures, then through every writer.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// Minimized shape of the two real production answers (ids anonymized).
const realA = { matchStatus: 'FINISHED', matchPeriod: 'FINISHED', homeTeamScore: '0', awayTeamScore: '0',
  homeTeamFtScore: '6', awayTeamFtScore: '3', homeTeamHalftimeScore: '2', awayTeamHalftimeScore: '1',
  homeTeamExtraScore: null, awayTeamExtraScore: null, homeTeamPenaltyScore: null, awayTeamPenaltyScore: null };
const realB = { matchStatus: 'FINISHED', matchPeriod: 'FINISHED', homeTeamScore: '0', awayTeamScore: '0',
  homeTeamFtScore: '1', awayTeamFtScore: '2', homeTeamHalftimeScore: '0', awayTeamHalftimeScore: '1',
  homeTeamExtraScore: null, awayTeamExtraScore: null };
const fin = (live, ft, extra = {}) => ({ matchStatus: 'FINISHED', homeTeamScore: live?.[0], awayTeamScore: live?.[1],
  homeTeamFtScore: ft?.[0], awayTeamFtScore: ft?.[1], ...extra });
const txt = (v) => (v == null ? v : String(v));
const pen = (live, ft, et, pens, extra = {}, as = txt) => ({ matchStatus: 'AFTER_PEN', matchPeriod: 'FINISHED',
  homeTeamScore: as(live[0]) ?? null, awayTeamScore: as(live[1]) ?? null,
  homeTeamFtScore: as(ft[0]) ?? null, awayTeamFtScore: as(ft[1]) ?? null,
  homeTeamExtraScore: as(et[0]) ?? null, awayTeamExtraScore: as(et[1]) ?? null,
  homeTeamPenaltyScore: pens[0] == null ? null : txt(pens[0]), awayTeamPenaltyScore: pens[1] == null ? null : txt(pens[1]), ...extra });
const S = (h, a) => ({ home: h, away: a });
const NONE = S(null, null);

const cases = [
  ['real case A: live reset 0-0, FT 6-3', realA, S(6, 3)],
  ['real case B: live reset 0-0, FT 1-2', realB, S(1, 2)],
  ['a real 0-0 final', fin(['0', '0'], ['0', '0'], { homeTeamHalftimeScore: '0', awayTeamHalftimeScore: '0' }), S(0, 0)],
  ['a 1-0 final, totals agree', fin(['1', '0'], ['1', '0']), S(1, 0)],
  ['terminal without FT: the running total', fin(['2', '1'], [null, null]), S(2, 1)],
  ['FT partial: treated as absent', fin(['2', '1'], ['2', null]), S(2, 1)],
  ['FT invalid text: treated as absent', fin(['2', '1'], ['x', '1']), S(2, 1)],
  ['numbers as JSON numbers', fin([3, 1], [3, 1]), S(3, 1)],
  ['incoherent: running total 2-1 vs FT 1-1 (no extra time)', fin(['2', '1'], ['1', '1']), NONE],
  ['reset without FT but half-time 1-0: impossible 0-0', fin(['0', '0'], [null, null], { homeTeamHalftimeScore: '1', awayTeamHalftimeScore: '0' }), NONE],
  ['after extra time: FT + extra', { matchStatus: 'AFTER_ET', homeTeamScore: '1', awayTeamScore: '2', homeTeamFtScore: '1', awayTeamFtScore: '1',
    homeTeamExtraScore: '0', awayTeamExtraScore: '1' }, S(1, 2)],
  ['after extra time with a reset running total', { matchStatus: 'AFTER_ET', homeTeamScore: '0', awayTeamScore: '0', homeTeamFtScore: '1', awayTeamFtScore: '1',
    homeTeamExtraScore: '0', awayTeamExtraScore: '1' }, S(1, 2)],
  ['after extra time without the extra-time score: unknown', { matchStatus: 'AFTER_ET', homeTeamScore: '0', awayTeamScore: '0',
    homeTeamFtScore: '1', awayTeamFtScore: '1' }, NONE],
  ['after penalties: the shoot-out is never part of the score', { matchStatus: 'AFTER_PEN', homeTeamScore: '0', awayTeamScore: '0',
    homeTeamFtScore: '0', awayTeamFtScore: '0', homeTeamExtraScore: '0', awayTeamExtraScore: '0', homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3' }, S(0, 0)],
  ['LIVE: the running total, FT ignored', { matchStatus: 'LIVE', matchPeriod: 'SECOND_HALF', homeTeamScore: '2', awayTeamScore: '1' }, S(2, 1)],
  ['LIVE in extra time: running total includes extra time', { matchStatus: 'LIVE', matchPeriod: 'EXTRA_TIME', homeTeamScore: '2', awayTeamScore: '1',
    homeTeamFtScore: '1', awayTeamFtScore: '1', homeTeamExtraScore: '1', awayTeamExtraScore: '0' }, S(2, 1)],
  ['half time', { matchStatus: 'HALF_TIME', homeTeamScore: '1', awayTeamScore: '0' }, S(1, 0)],
  ['cancelled without score', { matchStatus: 'CANCELLED', homeTeamScore: null, awayTeamScore: null }, NONE],
  ['postponed: not a result, the (absent) running total', { matchStatus: 'POSTPONED', homeTeamScore: null, awayTeamScore: null,
    homeTeamFtScore: null, awayTeamFtScore: null }, NONE],
  ['abandoned at 1-0: not a final, the running total', { matchStatus: 'ABANDONED', homeTeamScore: '1', awayTeamScore: '0' }, S(1, 0)],
  ['awarded with FT and a reset running total', { matchStatus: 'AWARDED', homeTeamScore: '0', awayTeamScore: '0',
    homeTeamFtScore: '3', awayTeamFtScore: '0' }, S(3, 0)],
  ['awarded without FT: the running total', { matchStatus: 'AWARDED', homeTeamScore: '3', awayTeamScore: '0' }, S(3, 0)],
  ['after penalties with extra-time goals, totals agree', { matchStatus: 'AFTER_PEN', homeTeamScore: '2', awayTeamScore: '2',
    homeTeamFtScore: '1', awayTeamFtScore: '1', homeTeamExtraScore: '1', awayTeamExtraScore: '1', homeTeamPenaltyScore: '5', awayTeamPenaltyScore: '4' }, S(2, 2)],
  ['after penalties without the extra-time score: unknown', { matchStatus: 'AFTER_PEN', homeTeamScore: '1', awayTeamScore: '1',
    homeTeamFtScore: '1', awayTeamFtScore: '1', homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3' }, NONE],
  ['finished, every score null', fin([null, null], [null, null]), NONE],
  ['finished, running total only on one side', fin(['2', null], [null, null]), NONE],
  ['digit text with spaces, lowercase status', { matchStatus: 'finished', homeTeamScore: ' 2 ', awayTeamScore: '1', homeTeamFtScore: '2', awayTeamFtScore: ' 1' }, S(2, 1)],
  ['empty strings are not scores', fin(['', ''], ['', '']), NONE],
  ['missing status: the running total', { homeTeamScore: '1', awayTeamScore: '1' }, S(1, 1)],
  // AFTER_PEN (production audit, 117 answers): the running total carries a
  // +1/+2 bonus for the shoot-out winner; the result is FT + ET.
  ['after pens: +1 bonus to the home shoot-out winner', pen([3, 2], [2, 2], [0, 0], [4, 3]), S(2, 2)],
  ['after pens: two-legged tie, FT+ET not tied, bonus to the away winner', pen([0, 2], [0, 1], [0, 0], [2, 4]), S(0, 1)],
  ['after pens: two-legged tie, no extra time played (ET 0-0 in answer)', pen([2, 0], [1, 0], [0, 0], [4, 3]), S(1, 0)],
  ['after pens: extra-time goals, +1 bonus', pen([5, 4], [2, 2], [2, 2], [4, 3]), S(4, 4)],
  ['after pens: extra-time goals, +2 bonus', pen([6, 4], [2, 2], [2, 2], [4, 3]), S(4, 4)],
  ['after pens: +2 bonus to the away winner', pen([1, 3], [1, 1], [0, 0], [2, 3]), S(1, 1)],
  ['after pens: no bonus, totals agree', pen([1, 1], [1, 1], [0, 0], [5, 4]), S(1, 1)],
  ['after pens: running total absent', pen([null, null], [1, 1], [0, 0], [5, 4]), S(1, 1)],
  ['after pens: running total reset 0-0', pen([0, 0], [2, 2], [1, 0], [5, 4]), S(3, 2)],
  ['after pens: excess without a penalty score: unknown', pen([3, 2], [2, 2], [0, 0], [null, null]), NONE],
  ['after pens: excess with a tied penalty score: unknown', pen([3, 2], [2, 2], [0, 0], [3, 3]), NONE],
  ['after pens: bonus to the shoot-out loser: unknown', pen([3, 2], [2, 2], [0, 0], [3, 4]), NONE],
  ['after pens: excess on both sides: unknown', pen([3, 3], [2, 2], [0, 0], [4, 3]), NONE],
  ['after pens: excess of 3: unknown', pen([5, 2], [2, 2], [0, 0], [4, 3]), NONE],
  ['after pens: negative excess: unknown', pen([1, 2], [2, 2], [0, 0], [3, 4]), NONE],
  ['after pens: incomplete penalty score: unknown', pen([3, 2], [2, 2], [0, 0], ['4', null]), NONE],
  ['after pens without FT: unknown, never the running total', pen([3, 2], [null, null], [0, 0], [4, 3]), NONE],
  ['after pens without FT and no bonus: still unknown', pen([2, 2], [null, null], [null, null], [4, 3]), NONE],
  ['after pens without the extra-time score but a bonus: unknown', pen([3, 2], [2, 2], [null, null], [4, 3]), NONE],
  ['after pens: FT+ET below half-time: unknown', pen([3, 2], [2, 2], [0, 0], [4, 3], { homeTeamHalftimeScore: '3', awayTeamHalftimeScore: '0' }), NONE],
  ['after pens: JSON numbers', pen([3, 2], [2, 2], [0, 0], [4, 3], {}, Number), S(2, 2)],
  ['finished never takes a shoot-out bonus', fin(['3', '2'], ['2', '2'], { homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3' }), NONE],
  ['after extra time never takes a shoot-out bonus', { matchStatus: 'AFTER_ET', homeTeamScore: '3', awayTeamScore: '2', homeTeamFtScore: '2', awayTeamFtScore: '2',
    homeTeamExtraScore: '0', awayTeamExtraScore: '0', homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3' }, NONE],
];

test('goalFixtureScore: provider semantics, cases A/B and edge cases', () => {
  for (const [name, fixture, expected] of cases) assert.deepEqual(goalFixtureScore(fixture), expected, name);
});

test('SQL goal_fixture_score gives exactly the TS result on every case (one rule)', () => withDb(async (db) => {
  for (const [name, fixture, expected] of cases) {
    const sql = (await db.query('select futbeat_private.goal_fixture_score($1::jsonb) v', [JSON.stringify(fixture)])).rows[0].v;
    const ts = goalFixtureScore(fixture);
    assert.deepEqual(sql ?? NONE, ts, name);
    assert.deepEqual(ts, expected, name);
  }
  // Non-GOAL observations keep their stored columns.
  assert.deepEqual((await db.query("select futbeat_private.observation_score('api_football',2,1,'{}'::jsonb) v")).rows[0].v, S(2, 1));
  assert.deepEqual((await db.query("select futbeat_private.observation_score('goal_api',0,0,$1::jsonb) v", [JSON.stringify(realA)])).rows[0].v, S(6, 3));
}));

test('calendar ingest normalizer: a reset finished answer keeps its full-time result', async () => {
  const base = {
    id: 'cms_x', apiId: '900001', countryName: 'Testland', leagueId: 'l1', leagueName: 'Liga', leagueYear: '2026',
    league: { id: 'l1', name: 'Liga' }, kickoffUtc: '2026-09-29T17:45:00.000Z', matchPeriod: 'FINISHED',
    homeTeam: { id: 'h1', name: 'Local' }, awayTeam: { id: 'a1', name: 'Visita' },
  };
  const snapshot = await normalizeGoalApiFixtures([{ ...base, ...realA }], async (kind, ext) => `fb_${kind}_${ext}`, '2026-10-01T02:06:00.000Z');
  const [match] = snapshot.matches;
  assert.deepEqual(match.score, S(6, 3));
});

// ---------------------------------------------------------------------------
// Database writers: trigger, results reconciliation, read model.
// ---------------------------------------------------------------------------

let seq = 0;
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString();
const hash = () => createHash('sha256').update(`gts-${++seq}`).digest('hex');
async function seedMatch(db, { status = 'FINISHED_PENDING_VERIFICATION', score = [6, 3], received = hoursAgo(20), started = 30 } = {}) {
  const n = ++seq;
  const ids = { match: `fb_match_gts${n}`, ext: `gts-${n}`, comp: `fb_comp_gts${n}`, home: `fb_team_gtsh${n}`, away: `fb_team_gtsa${n}` };
  for (const [id, kind, payload] of [[ids.comp, 'competition', { name: 'Liga' }], [ids.home, 'team', { name: 'Local' }], [ids.away, 'team', { name: 'Visita' }]]) {
    await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  }
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [ids.match, 'match', JSON.stringify({ id: ids.match,
    competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, startTime: hoursAgo(started), status,
    ...(score ? { score: S(...score) } : {}), events: [], statistics: [],
    provenance: { source: 'GOAL API', receivedAt: received } })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  return ids;
}
// An observation as the CURRENT production worker stored it: the columns
// hold the running total read from the raw answer.
const observe = (db, m, raw, { received = hoursAgo(1), status = 'FINISHED_PENDING_VERIFICATION' } = {}) => db.query(`insert into futbeat_private.provider_observations(
    provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
  values('goal_api',$1,$2,$3,$4,$5,$6,$7,$8)`, [m.ext, m.match, received, status,
  raw.homeTeamScore == null ? null : Number(raw.homeTeamScore), raw.awayTeamScore == null ? null : Number(raw.awayTeamScore), hash(), JSON.stringify(raw)]);
const stored = (db, m) => db.query("select payload->>'status' status,payload->'score' score,payload#>>'{provenance,scoreCorrected}' corrected from futbeat_private.entities where id=$1", [m.match]).then((r) => r.rows[0]);
const shown = (db, m) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [m.match]).then((r) => r.rows[0].v);
const providerDate = (db, m) => db.query("select ((payload->>'startTime')::timestamptz at time zone 'UTC')::date::text d from futbeat_private.entities where id=$1", [m.match]).then((r) => r.rows[0].d);

test('terminal score correction: cases A and B never turn a final into 0-0; a real correction still applies', () => withDb(async (db) => {
  const a = await seedMatch(db, { score: [6, 3] });
  await observe(db, a, realA);
  assert.deepEqual(await stored(db, a), { status: 'FINISHED_PENDING_VERIFICATION', score: S(6, 3), corrected: null });
  const b = await seedMatch(db, { score: [1, 2] });
  await observe(db, b, realB);
  assert.deepEqual((await stored(db, b)).score, S(1, 2));
  // An incoherent terminal answer never applies.
  await observe(db, a, fin(['2', '1'], ['1', '1']));
  assert.deepEqual((await stored(db, a)).score, S(6, 3));
  // A legitimate correction (FT and running total agree) still applies, and
  // a reset answer carrying a corrected FT is a correction too.
  await observe(db, a, fin(['5', '3'], ['5', '3']));
  assert.deepEqual(await stored(db, a), { status: 'FINISHED_PENDING_VERIFICATION', score: S(5, 3), corrected: 'true' });
  await observe(db, b, fin(['0', '0'], ['1', '1']));
  assert.deepEqual((await stored(db, b)).score, S(1, 1));
  // An older answer and a repeated one change nothing.
  await observe(db, a, fin(['6', '3'], ['6', '3']), { received: hoursAgo(2) });
  assert.deepEqual((await stored(db, a)).score, S(5, 3));
}));

test('results reconciliation: a reset answer never replaces a final, and closes a scheduled match with its FT result', () => withDb(async (db) => {
  const reconcile = async (m) => db.query('select futbeat_private.finalize_goal_results_date($1::date,now())', [await providerDate(db, m)]);
  // Stored final 6-3; the newest observation is the reset answer.
  const a = await seedMatch(db, { score: [6, 3] });
  await observe(db, a, realA);
  await reconcile(a);
  assert.deepEqual((await stored(db, a)).score, S(6, 3));
  // A match still SCHEDULED whose only terminal answer is the reset one.
  const b = await seedMatch(db, { status: 'SCHEDULED', score: null, received: hoursAgo(40) });
  await observe(db, b, realB);
  await reconcile(b);
  assert.deepEqual(await stored(db, b), { status: 'FINISHED_PENDING_VERIFICATION', score: S(1, 2), corrected: null });
  // A legitimate correction through the reconciliation still applies.
  await observe(db, a, fin(['6', '2'], ['6', '2']), { received: new Date().toISOString() });
  await reconcile(a);
  assert.deepEqual((await stored(db, a)).score, S(6, 2));
  // canonical 2-1, newer GOAL answer: reset running total, FT 1-1 -> 1-1.
  const c = await seedMatch(db, { score: [2, 1] });
  await observe(db, c, fin(['0', '0'], ['1', '1']));
  await reconcile(c);
  assert.deepEqual((await stored(db, c)).score, S(1, 1), 'a real correction carried by FT is applied');
}));

test('read model: a stored final never shows 0-0 because a reset detail answer is newer', () => withDb(async (db) => {
  const m = await seedMatch(db, { score: [6, 3] });
  await db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    values($1,'goal_api',$2,now(),$3)`, [m.match, m.ext, JSON.stringify(realA)]);
  await observe(db, m, realA, { received: new Date().toISOString() });
  const model = await shown(db, m);
  assert.deepEqual([model.status, model.score], ['FINISHED_PENDING_VERIFICATION', S(6, 3)]);
}));

test('match detail cache: a reset answer with a shorter events list never drops goals the result requires', () => withDb(async (db) => {
  const m = await seedMatch(db, { score: [2, 0] });
  const goals = [{ id: 'g1', type: 'goal', time: '10', homeScorer: 'A', homeScorerId: 'p1' },
    { id: 'g2', type: 'goal', time: '70', homeScorer: 'B', homeScorerId: 'p2' }];
  const detail = (payload) => db.query('select futbeat_private.store_match_detail($1,$2,now(),$3)', [m.match, m.ext, JSON.stringify(payload)]);
  await detail({ matchStatus: 'FINISHED', homeTeamScore: '2', awayTeamScore: '0', homeTeamFtScore: '2', awayTeamFtScore: '0', events: goals });
  await detail({ matchStatus: 'FINISHED', homeTeamScore: '0', awayTeamScore: '0', homeTeamFtScore: '2', awayTeamFtScore: '0', events: [] });
  const events = (await db.query('select payload->\'events\' v from futbeat_private.match_detail_cache where match_id=$1', [m.match])).rows[0].v;
  assert.equal(events.length, 2, 'the result (FT 2-0) still requires both goals');
}));

test('read model: reset observation and reset match-detail cache show the real result', () => withDb(async (db) => {
  // Payload not yet terminal: the score comes from the evidence candidates.
  const m = await seedMatch(db, { status: 'SCHEDULED', score: null, received: hoursAgo(40) });
  await observe(db, m, fin(['6', '3'], [null, null]), { received: hoursAgo(25) });
  await observe(db, m, realA, { received: hoursAgo(2) });
  let model = await shown(db, m);
  assert.deepEqual([model.status, model.score], ['FINISHED_PENDING_VERIFICATION', S(6, 3)]);
  // Match-detail cache newer than every observation, also reset.
  await db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    values($1,'goal_api',$2,now(),$3)`, [m.match, m.ext, JSON.stringify(realA)]);
  model = await shown(db, m);
  assert.deepEqual(model.score, S(6, 3));
  // A live match keeps showing its running total.
  const live = await seedMatch(db, { status: 'SCHEDULED', score: null, started: 1, received: hoursAgo(2) });
  await observe(db, live, { matchStatus: 'LIVE', matchPeriod: 'SECOND_HALF', homeTeamScore: '2', awayTeamScore: '0' },
    { status: 'LIVE', received: new Date().toISOString() });
  assert.deepEqual((await shown(db, live)).score, S(2, 0));
}));

test('AFTER_PEN: terminal correction and results reconciliation adopt FT + ET over an inflated stored final', () => withDb(async (db) => {
  const reconcile = async (m) => db.query('select futbeat_private.finalize_goal_results_date($1::date,now())', [await providerDate(db, m)]);
  // Terminal correction trigger: stored 3-2 (running total with the bonus).
  const a = await seedMatch(db, { score: [3, 2] });
  await observe(db, a, pen([3, 2], [2, 2], [0, 0], [4, 3]));
  assert.deepEqual(await stored(db, a), { status: 'FINISHED_PENDING_VERIFICATION', score: S(2, 2), corrected: 'true' });
  // A later answer with the bonus drifting to +2 confirms the same result.
  await observe(db, a, pen([4, 2], [2, 2], [0, 0], [4, 3]), { received: new Date().toISOString() });
  assert.deepEqual((await stored(db, a)).score, S(2, 2));
  // An answer giving the bonus to the shoot-out loser is unknown: no change.
  const b = await seedMatch(db, { score: [3, 2] });
  await observe(db, b, pen([3, 2], [2, 2], [0, 0], [3, 4]));
  assert.deepEqual((await stored(db, b)).score, S(3, 2));
  // AFTER_PEN without FT never writes the running total.
  const c = await seedMatch(db, { score: [2, 2] });
  await observe(db, c, pen([3, 2], [null, null], [null, null], [4, 3]));
  assert.deepEqual((await stored(db, c)).score, S(2, 2));
  // Results reconciliation (trigger bypassed: observation stored before the
  // canonical final, as the pre-fix worker left it).
  const d = await seedMatch(db, { status: 'SCHEDULED', score: null, received: hoursAgo(40) });
  await observe(db, d, pen([0, 2], [0, 1], [0, 0], [2, 4]), { received: hoursAgo(2) });
  await reconcile(d);
  assert.deepEqual((await stored(db, d)).score, S(0, 1));
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{score}',$2::jsonb) where id=$1", [d.match, JSON.stringify(S(0, 2))]);
  await observe(db, d, pen([0, 3], [0, 1], [0, 0], [2, 4]), { received: new Date().toISOString() });
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{score}',$2::jsonb) where id=$1", [d.match, JSON.stringify(S(0, 2))]);
  await reconcile(d);
  assert.deepEqual((await stored(db, d)).score, S(0, 1), 'reconciliation adopts FT + ET');
  // Read model: a non-terminal payload shows FT + ET from the AFTER_PEN answer.
  const e = await seedMatch(db, { status: 'SCHEDULED', score: null, received: hoursAgo(40) });
  await db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    values($1,'goal_api',$2,now(),$3)`, [e.match, e.ext, JSON.stringify(pen([5, 4], [2, 2], [2, 2], [4, 3]))]);
  assert.deepEqual((await shown(db, e)).score, S(4, 4));
}));

test('manual AFTER_PEN repair: dry-run lists only unambiguous inflated finals; apply is guarded by the expected count', () => withDb(async (db) => {
  const script = readFileSync(new URL('../../supabase/manual/2026-10-01_after_pen_repair.sql', import.meta.url), 'utf8');
  const dryRun = script.slice(script.indexOf('-- [dry-run]'), script.indexOf('-- [apply]'));
  const apply = script.slice(script.indexOf('-- [apply]'));
  // Store the inflated running total as the final (as the pre-fix rule did).
  const inflate = (m, score) => db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{score}',$2::jsonb) where id=$1", [m.match, JSON.stringify(score)]);
  // a: candidate (bonus +2 in an older answer, +1 in the latest).
  const a = await seedMatch(db, { score: [3, 2] });
  await observe(db, a, pen([4, 2], [2, 2], [0, 0], [4, 3]), { received: hoursAgo(3) });
  await observe(db, a, pen([3, 2], [2, 2], [0, 0], [4, 3]), { received: hoursAgo(2) });
  await inflate(a, S(3, 2));
  // b: AFTER_PEN answers disagree on the result -> not a candidate.
  const b = await seedMatch(db, { score: [3, 2] });
  await observe(db, b, pen([3, 2], [2, 2], [0, 0], [4, 3]), { received: hoursAgo(3) });
  await observe(db, b, pen([3, 1], [2, 1], [0, 0], [4, 3]), { received: hoursAgo(2) });
  await inflate(b, S(3, 2));
  // c: the stored score is no running total (independent value) -> untouched.
  const c = await seedMatch(db, { score: [3, 2] });
  await observe(db, c, pen([3, 2], [2, 2], [0, 0], [4, 3]));
  await inflate(c, S(5, 5));
  // d: the latest terminal answer is FINISHED, not AFTER_PEN -> untouched.
  const d = await seedMatch(db, { score: [3, 2] });
  await observe(db, d, pen([3, 2], [2, 2], [0, 0], [4, 3]), { received: hoursAgo(3) });
  await observe(db, d, fin(['2', '2'], ['2', '2']), { received: hoursAgo(2) });
  await inflate(d, S(3, 2));
  const results = await db.exec(dryRun);
  assert.equal(results[0].rows[0].after_pen_semantics_installed, true);
  assert.deepEqual(results.at(-1).rows.map((r) => [r.id, r.old, r.new, Number(r.candidate_count)]), [[a.match, S(3, 2), S(2, 2), 1]]);
  // A wrong expected count raises and writes nothing.
  await assert.rejects(db.exec(apply.replace('__EXPECTED_COUNT__', '2')), /expected 2/);
  assert.deepEqual((await stored(db, a)).score, S(3, 2));
  // The right count applies, with the audit trail; status/receivedAt unchanged.
  const payload = async (m) => (await db.query('select payload from futbeat_private.entities where id=$1', [m.match])).rows[0].payload;
  const before = await payload(a);
  await db.exec(apply.replace('__EXPECTED_COUNT__', '1'));
  const after = await payload(a);
  assert.deepEqual(after.score, S(2, 2));
  assert.equal(after.status, before.status);
  assert.equal(after.provenance.receivedAt, before.provenance.receivedAt);
  assert.equal(after.provenance.scoreCorrected, true);
  assert.deepEqual(after.provenance.scoreCorrectedFrom, S(3, 2));
  assert.equal(after.provenance.scoreCorrectionReason, 'goal_after_pen_shootout_bonus');
  assert.ok(after.provenance.scoreCorrectionObservation != null && after.provenance.scoreCorrectedAt && after.provenance.scoreCorrectionEvidence);
  assert.deepEqual((await stored(db, b)).score, S(3, 2));
  assert.deepEqual((await stored(db, c)).score, S(5, 5));
  assert.deepEqual((await stored(db, d)).score, S(3, 2));
  // Idempotent: nothing left to repair.
  assert.equal((await db.exec(dryRun)).at(-1).rows.length, 0);
}));

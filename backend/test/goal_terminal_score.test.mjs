import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
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

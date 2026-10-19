import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// QA81 (#222): a team profile listed the same fixture twice (a final 3-1 and
// a "Por confirmar" copy). Shape reproduced with generic ids: one provider
// stored the fixture against team identity A, another against identity B of
// the same club. Nothing here merges by name:
//   * team_identity_twin_candidates only REPORTS identity pairs with
//     structural evidence (same competition, same opponent on the same side,
//     kickoff within 24 h, mapped by disjoint providers, never together);
//   * once an operator registers the team redirect, the team profile applies
//     the calendar's existing same-fixture rule (canonical ids only) and lists
//     the fixture once.
// No provider is ever called.

const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString();

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const v = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;

async function entity(db, kind, id, payload = {}) {
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
}
async function mapTo(db, provider, kind, external, id) {
  await db.query('insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values($1,$2,$3,$4)',
    [provider, kind, external, id]);
}
async function match(db, id, { comp = 'fb_comp_l', home, away, start, status = 'VERIFIED', score, verification }) {
  await entity(db, 'match', id, {
    competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: start, status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}),
    events: [], statistics: [],
    ...(verification ? { provenance: { verificationStatus: verification } } : {}),
  });
}

async function seed(db) {
  await entity(db, 'competition', 'fb_comp_l', { name: 'Primera Ejemplo', country: 'Costa Rica' });
  await entity(db, 'competition', 'fb_comp_cup', { name: 'Copa Ejemplo', country: 'Costa Rica' });
  await entity(db, 'team', 'fb_team_home', { name: 'Local SC', competitionId: 'fb_comp_l' });
  await entity(db, 'team', 'fb_team_pun_a', { name: 'Puerto FC', competitionId: 'fb_comp_l' });
  await entity(db, 'team', 'fb_team_pun_b', { name: 'Puerto F.C.', competitionId: 'fb_comp_l' });
  await entity(db, 'team', 'fb_team_third', { name: 'Tercero', competitionId: 'fb_comp_l' });
  await mapTo(db, 'thesportsdb', 'team', 'tsdb-home', 'fb_team_home');
  await mapTo(db, 'goal_api', 'team', 'goal-home', 'fb_team_home');
  await mapTo(db, 'thesportsdb', 'team', 'tsdb-pun', 'fb_team_pun_a');
  await mapTo(db, 'goal_api', 'team', 'goal-pun', 'fb_team_pun_b');
  await mapTo(db, 'goal_api', 'team', 'goal-third', 'fb_team_third');
}

const results = (db, team) => v(db,
  "select public.futbeat_read_team_matches(p_team_id=>$1,p_bucket=>'results') v", [team]);
const candidates = async (db) => (await db.query(
  `select team_a,team_b,evidence from futbeat_private.team_identity_twin_candidates(current_date-30,current_date+1)
   order by team_a,team_b`)).rows;

// The QA81 shape: provisional copy (date-only kickoff, never observed) and
// the played fixture of the other provider, 2 h apart.
async function qa81Pair(db) {
  const day = Math.floor((Date.now() - 6 * DAY) / DAY) * DAY;
  await match(db, 'fb_match_tsdb', { home: 'fb_team_home', away: 'fb_team_pun_a', start: iso(day), status: 'SCHEDULED' });
  await match(db, 'fb_match_goal', { home: 'fb_team_home', away: 'fb_team_pun_b', start: iso(day + 2 * 3600e3),
    score: [3, 1], verification: 'VERIFIED' });
}

test('two team identities: profile keeps both rows (no name merge) and the pair is reported', () => withDb(async (db) => {
  await seed(db);
  await qa81Pair(db);
  const page = await results(db, 'fb_team_home');
  assert.deepEqual(page.matches.map((m) => m.id).sort(), ['fb_match_goal', 'fb_match_tsdb']);
  assert.deepEqual(await candidates(db), [{ team_a: 'fb_team_pun_a', team_b: 'fb_team_pun_b', evidence: 1 }]);
  // Read-only: nothing was redirected.
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.entity_redirects'), 0);
}));

test('after an operator redirect the profile lists the fixture once (the played one)', () => withDb(async (db) => {
  await seed(db);
  await qa81Pair(db);
  await db.query("select futbeat_private.futbeat_register_entity_redirect('team','fb_team_pun_a','fb_team_pun_b','test: reviewed twin')");
  const page = await results(db, 'fb_team_home');
  assert.deepEqual(page.matches.map((m) => m.id), ['fb_match_goal']);
  // The other side's profile too.
  const other = await results(db, 'fb_team_pun_b');
  assert.deepEqual(other.matches.map((m) => m.id), ['fb_match_goal']);
  // A resolved pair is no longer a candidate.
  assert.deepEqual(await candidates(db), []);
}));

test('two played games with different results are never collapsed', () => withDb(async (db) => {
  await seed(db);
  const day = Math.floor((Date.now() - 5 * DAY) / DAY) * DAY;
  await match(db, 'fb_match_g1', { home: 'fb_team_home', away: 'fb_team_third', start: iso(day), score: [1, 0] });
  await match(db, 'fb_match_g2', { home: 'fb_team_home', away: 'fb_team_third', start: iso(day + 3600e3), score: [2, 2] });
  const page = await results(db, 'fb_team_home');
  assert.equal(page.matches.length, 2);
}));

test('other competition or later scheduled game of the same pairing is kept', () => withDb(async (db) => {
  await seed(db);
  const day = Math.floor((Date.now() - 5 * DAY) / DAY) * DAY;
  await match(db, 'fb_match_league', { home: 'fb_team_home', away: 'fb_team_third', start: iso(day), score: [1, 0] });
  await match(db, 'fb_match_cup', { comp: 'fb_comp_cup', home: 'fb_team_home', away: 'fb_team_third', start: iso(day), score: [1, 0] });
  await match(db, 'fb_match_later', { home: 'fb_team_home', away: 'fb_team_third', start: iso(day + 20 * 3600e3), status: 'SCHEDULED' });
  const page = await results(db, 'fb_team_home');
  assert.deepEqual(page.matches.map((m) => m.id).sort(), ['fb_match_cup', 'fb_match_later', 'fb_match_league']);
}));

test('candidates: same-provider pairs, homonyms without shared fixtures and co-players are not reported', () => withDb(async (db) => {
  await seed(db);
  // Homonym in another competition with no shared fixture.
  await entity(db, 'team', 'fb_team_pun_c', { name: 'Puerto FC', competitionId: 'fb_comp_cup' });
  await mapTo(db, 'goal_api', 'team', 'goal-pun-c', 'fb_team_pun_c');
  const day = Math.floor((Date.now() - 4 * DAY) / DAY) * DAY;
  // Same opponent, same day, both GOAL-mapped (one provider never creates two ids for one club).
  await match(db, 'fb_match_x1', { home: 'fb_team_home', away: 'fb_team_third', start: iso(day), score: [0, 0] });
  await match(db, 'fb_match_x2', { home: 'fb_team_home', away: 'fb_team_pun_b', start: iso(day + 3600e3), score: [1, 1] });
  // Two identities that already played each other are two clubs.
  await match(db, 'fb_match_y1', { home: 'fb_team_pun_a', away: 'fb_team_pun_b', start: iso(day - 2 * DAY), score: [2, 0] });
  await match(db, 'fb_match_y2', { home: 'fb_team_home', away: 'fb_team_pun_a', start: iso(day - 9 * DAY), status: 'SCHEDULED' });
  await match(db, 'fb_match_y3', { home: 'fb_team_home', away: 'fb_team_pun_b', start: iso(day - 9 * DAY + 3600e3), score: [1, 0] });
  assert.deepEqual(await candidates(db), []);
}));

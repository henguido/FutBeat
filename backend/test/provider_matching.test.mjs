import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import {
  DEFAULT_KICKOFF_TOLERANCE_MINUTES,
  FixtureMatch,
  canonicalEventFingerprint,
  dedupeCanonicalEvents,
  matchCanonicalEvent,
  matchFixture,
} from '../providers/core/matching.mjs';

// Cross-provider identity (#102 Phase 1A): canonical ids only, no name-only
// merge, ambiguity never resolved arbitrarily, conservative event dedup.
// Synthetic ids/names; no network.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// ---------------------------------------------------------------------------
// Pure fixture matcher.
// ---------------------------------------------------------------------------
const K = '2026-10-04T18:00:00.000Z';
const at = (minutes) => new Date(Date.parse(K) + minutes * 60000).toISOString();
const provider = (over = {}) => ({
  provider: 'sportmonks', externalMatchId: '5001', canonicalCompetitionId: 'fb_comp_1',
  canonicalHomeTeamId: 'fb_team_h', canonicalAwayTeamId: 'fb_team_a', startTime: K, ...over,
});
const canonical = (matchId, over = {}) => ({
  matchId, competitionId: 'fb_comp_1', homeTeamId: 'fb_team_h', awayTeamId: 'fb_team_a', startTime: K, ...over,
});

test('matcher: unique structural candidate within tolerance -> MATCHED', () => {
  assert.equal(DEFAULT_KICKOFF_TOLERANCE_MINUTES, 10);
  const r = matchFixture(provider(), [canonical('fb_match_1', { startTime: at(7) }), canonical('fb_match_x', { startTime: at(60 * 24 * 7) })]);
  assert.deepEqual([r.status, r.canonicalMatchId], [FixtureMatch.matched, 'fb_match_1']);
  assert.equal(matchFixture(provider(), [canonical('fb_match_1', { startTime: at(11) })]).status, FixtureMatch.unmapped);
});

test('matcher: two candidates -> AMBIGUOUS (never picks one)', () => {
  const r = matchFixture(provider(), [canonical('fb_match_1'), canonical('fb_match_2', { startTime: at(5) })]);
  assert.deepEqual([r.status, r.candidates], [FixtureMatch.ambiguous, ['fb_match_1', 'fb_match_2']]);
  assert.equal(r.canonicalMatchId, undefined);
});

test('matcher: unmapped identity, other competition, no swap without evidence', () => {
  assert.equal(matchFixture(provider({ canonicalHomeTeamId: null }), [canonical('fb_match_1')]).status, FixtureMatch.unmapped);
  assert.equal(matchFixture(provider(), [canonical('fb_match_1', { competitionId: 'fb_comp_2' })]).status, FixtureMatch.unmapped);
  const swapped = [canonical('fb_match_1', { homeTeamId: 'fb_team_a', awayTeamId: 'fb_team_h' })];
  assert.equal(matchFixture(provider(), swapped).status, FixtureMatch.unmapped, 'default: never swap');
  assert.equal(matchFixture(provider({ orientationSwapped: true }), swapped).status, FixtureMatch.matched);
});

test('matcher: season/round contradictions reject; absence never blocks', () => {
  assert.equal(matchFixture(provider({ season: '2026/27' }), [canonical('fb_match_1', { season: '2026-2027' })]).status, FixtureMatch.matched);
  assert.equal(matchFixture(provider({ season: '2025/26' }), [canonical('fb_match_1', { season: '2026-2027' })]).status, FixtureMatch.unmapped);
  assert.equal(matchFixture(provider({ season: '2026' }), [canonical('fb_match_1')]).status, FixtureMatch.matched);
  assert.equal(matchFixture(provider({ round: '7' }), [canonical('fb_match_1', { round: '8' })]).status, FixtureMatch.unmapped);
});

// ---------------------------------------------------------------------------
// Strict identity + SQL matcher (real database).
// ---------------------------------------------------------------------------
let seq = 0;
async function entity(db, kind, name, extra = {}) {
  const id = `fb_${kind}_ph${++seq}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, name, ...extra })]);
  return id;
}
const bind = (db, provider, kind, ext, canonicalId, evidence) => db.query(
  'select public.futbeat_bind_provider_entity($1,$2,$3,$4,$5) v', [provider, kind, ext, canonicalId, JSON.stringify(evidence)])
  .then((r) => r.rows[0].v);
const verified = { type: 'EXPLICIT_VERIFIED', verifiedBy: 'ops-review' };
const matchFixtureSql = (db, provider, ext, comp, home, away, start, season = null, swapped = false) => db.query(
  'select public.futbeat_match_provider_fixture($1,$2,$3,$4,$5,$6,$7,null,$8) v',
  [provider, ext, comp, home, away, start, season, swapped]).then((r) => r.rows[0].v);
const mapping = (db, provider, kind, ext) => db.query(
  'select canonical_id from futbeat_private.provider_entities where provider=$1 and kind=$2 and external_id=$3', [provider, kind, ext])
  .then((r) => r.rows[0]?.canonical_id ?? null);

async function seedGoalFixture(db, { name = 'Liga Uno', home = 'Club Norte', away = 'Club Sur', start = K } = {}) {
  const comp = await entity(db, 'competition', name);
  const h = await entity(db, 'team', home);
  const a = await entity(db, 'team', away);
  const match = await entity(db, 'match', 'm', { competitionId: comp, homeTeamId: h, awayTeamId: a, startTime: start, status: 'SCHEDULED', season: '2026' });
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`g-${seq}`, match]);
  return { comp, h, a, match };
}

test('strict binding: explicit verified evidence only; names never suffice; no overwrite', () => withDb(async (db) => {
  const team = await entity(db, 'team', 'Club Norte');
  const other = await entity(db, 'team', 'Club Norte'); // same display name, different canonical team
  assert.deepEqual(await bind(db, 'api_football', 'team', '100', team, { type: 'NAME_MATCH', name: 'Club Norte' }),
    { status: 'REJECTED', reason: 'insufficient_evidence' });
  assert.deepEqual(await bind(db, 'api_football', 'team', '100', team, { type: 'EXPLICIT_VERIFIED' }),
    { status: 'REJECTED', reason: 'insufficient_evidence' }, 'verifier required');
  assert.equal(await mapping(db, 'api_football', 'team', '100'), null, 'no name-only merge');
  assert.deepEqual(await bind(db, 'api_football', 'team', '100', team, verified), { status: 'BOUND', canonicalId: team });
  assert.deepEqual(await bind(db, 'api_football', 'team', '100', team, verified), { status: 'EXISTING', canonicalId: team });
  assert.deepEqual(await bind(db, 'api_football', 'team', '100', other, verified), { status: 'CONFLICT', canonicalId: team });
  assert.equal(await mapping(db, 'api_football', 'team', '100'), team, 'never overwritten');
  // Same names stay distinct canonical teams.
  assert.deepEqual(await bind(db, 'sportmonks', 'team', '9001', other, verified), { status: 'BOUND', canonicalId: other });
  assert.notEqual(team, other);
  assert.equal((await bind(db, 'goal_api', 'team', 'x', team, verified)).reason, 'not_a_hub_provider');
  assert.equal((await bind(db, 'api_football', 'team', '101', 'fb_team_missing', verified)).reason, 'unknown_canonical');
  // Resolving an unknown provider id never creates an entity.
  const before = (await db.query('select count(*)::int n from futbeat_private.entities')).rows[0].n;
  assert.equal((await db.query("select futbeat_private.resolve_provider_entity_strict('api_football','team','nope') v")).rows[0].v, null);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.entities')).rows[0].n, before);
}));

test('fixture match: unique fixture binds the provider match id to the GOAL canonical match', () => withDb(async (db) => {
  const f = await seedGoalFixture(db);
  await bind(db, 'sportmonks', 'competition', '777', f.comp, verified);
  await bind(db, 'sportmonks', 'team', '9001', f.h, verified);
  await bind(db, 'sportmonks', 'team', '9002', f.a, verified);
  const matchesBefore = (await db.query("select count(*)::int n from futbeat_private.entities where kind='match'")).rows[0].n;
  const r = await matchFixtureSql(db, 'sportmonks', '5001', '777', '9001', '9002', at(4), '2026');
  assert.deepEqual(r, { status: 'MATCHED', canonicalMatchId: f.match });
  assert.equal(await mapping(db, 'sportmonks', 'match', '5001'), f.match);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='match'")).rows[0].n, matchesBefore, 'no duplicate fixture');
  assert.deepEqual(await matchFixtureSql(db, 'sportmonks', '5001', '777', '9001', '9002', at(4)), r, 'idempotent');
}));

test('fixture match: unmapped teams and ambiguous candidates never bind or publish', () => withDb(async (db) => {
  const f = await seedGoalFixture(db);
  // Same names exist, but no strict mapping: UNMAPPED (never name-matched).
  const unmapped = await matchFixtureSql(db, 'api_football', '700', '39', '33', '34', K);
  assert.equal(unmapped.status, 'UNMAPPED');
  assert.equal(await mapping(db, 'api_football', 'match', '700'), null);
  // Two GOAL fixtures for the same pairing within tolerance: AMBIGUOUS.
  const twin = await entity(db, 'match', 'm', { competitionId: f.comp, homeTeamId: f.h, awayTeamId: f.a, startTime: at(6), status: 'SCHEDULED' });
  await bind(db, 'api_football', 'competition', '39', f.comp, verified);
  await bind(db, 'api_football', 'team', '33', f.h, verified);
  await bind(db, 'api_football', 'team', '34', f.a, verified);
  const ambiguous = await matchFixtureSql(db, 'api_football', '701', '39', '33', '34', at(3));
  assert.equal(ambiguous.status, 'AMBIGUOUS');
  assert.deepEqual(ambiguous.candidates.sort(), [f.match, twin].sort());
  assert.equal(await mapping(db, 'api_football', 'match', '701'), null);
  const diag = (await db.query("select status from futbeat_private.provider_fixture_diagnostics where provider='api_football' order by external_match_id")).rows;
  assert.deepEqual(diag.map((d) => d.status), ['UNMAPPED', 'AMBIGUOUS']);
  // Swapped orientation only with explicit evidence.
  assert.equal((await matchFixtureSql(db, 'api_football', '702', '39', '34', '33', K)).status, 'UNMAPPED');
  assert.equal((await matchFixtureSql(db, 'api_football', '702', '39', '34', '33', K, null, true)).status, 'AMBIGUOUS');
  // Season contradiction rejects.
  await db.query("delete from futbeat_private.entities where id=$1", [twin]);
  assert.equal((await matchFixtureSql(db, 'api_football', '703', '39', '33', '34', K, '2025')).status, 'UNMAPPED');
  assert.equal((await matchFixtureSql(db, 'api_football', '703', '39', '33', '34', K, '2026')).status, 'MATCHED');
}));

test('fixture match: an external id already mapped elsewhere is a CONFLICT, never rebound', () => withDb(async (db) => {
  const f = await seedGoalFixture(db);
  const other = await seedGoalFixture(db, { name: 'Liga Dos' });
  await bind(db, 'api_football', 'match', '800', other.match, verified);
  await bind(db, 'api_football', 'competition', '39', f.comp, verified);
  await bind(db, 'api_football', 'team', '33', f.h, verified);
  await bind(db, 'api_football', 'team', '34', f.a, verified);
  const r = await matchFixtureSql(db, 'api_football', '800', '39', '33', '34', K);
  assert.equal(r.status, 'CONFLICT');
  assert.equal(await mapping(db, 'api_football', 'match', '800'), other.match);
}));

test('the legacy name-matching resolver is NOT extended to the new providers', () => withDb(async (db) => {
  for (const p of ['api_football', 'sportmonks']) {
    await assert.rejects(db.query("select futbeat_private.futbeat_resolve_global_entity($1,'team','1','Club Norte')", [p]),
      /Invalid global provider identity/);
  }
}));

// ---------------------------------------------------------------------------
// Event dedup A-I.
// ---------------------------------------------------------------------------
const ev = (provider, eventId, over = {}) => ({
  matchId: 'fb_match_1', type: 'GOAL', teamId: 'fb_team_h', minute: 20, playerId: 'fb_player_9',
  provenance: { provider, eventId }, ...over,
});

test('A/B/C/I. the same goal from GOAL, API-Football and Sportmonks is one canonical event', () => {
  const goal = ev('goal_api', 'g-1', { scoreAfter: { home: 1, away: 0 } });
  const af = ev('api_football', 'af-77', { scoreAfter: { home: 1, away: 0 } });
  const sm = ev('sportmonks', '11', { minute: 21 });
  assert.equal(matchCanonicalEvent(goal, af), true, 'A');
  assert.equal(matchCanonicalEvent(goal, sm), true, 'B');
  assert.equal(matchCanonicalEvent(af, sm), true, 'C');
  const merged = dedupeCanonicalEvents([sm, af, goal]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].provenance[0].provider, 'goal_api', 'primary represents the group');
  assert.deepEqual(merged[0].provenance.map((p) => p.eventId), ['g-1', 'af-77', '11'], 'I: different provider ids kept as provenance');
});

test('D/E. same minute but different team or different canonical player: never merged', () => {
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g'), ev('api_football', 'a', { teamId: 'fb_team_a' })), false, 'D');
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g'), ev('sportmonks', 's', { playerId: 'fb_player_10' })), false, 'E');
  assert.equal(dedupeCanonicalEvents([ev('goal_api', 'g'), ev('api_football', 'a', { teamId: 'fb_team_a' })]).length, 2);
});

test('F. explicit minute rule: 45 vs 45+1 compatible; 45 vs 47 not', () => {
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g', { minute: 45 }), ev('sportmonks', 's', { minute: 45, extraMinute: 1 })), true);
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g', { minute: 45, extraMinute: 2 }), ev('sportmonks', 's', { minute: 47 })), true);
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g', { minute: 45 }), ev('sportmonks', 's', { minute: 47 })), false);
  assert.equal(matchCanonicalEvent(ev('goal_api', 'g', { minute: null }), ev('sportmonks', 's')), false);
});

test('G. two goals of the same player in the same minute with different score-after stay two', () => {
  const first = ev('goal_api', 'g1', { scoreAfter: { home: 1, away: 0 } });
  const second = ev('api_football', 'a2', { scoreAfter: { home: 2, away: 0 } });
  assert.equal(matchCanonicalEvent(first, second), false);
  const merged = dedupeCanonicalEvents([first, ev('goal_api', 'g2', { scoreAfter: { home: 2, away: 0 } }),
    ev('api_football', 'a1', { scoreAfter: { home: 1, away: 0 } }), second]);
  assert.equal(merged.length, 2);
  assert.deepEqual(merged.map((m) => m.provenance.map((p) => p.eventId)), [['g1', 'a1'], ['g2', 'a2']]);
});

test('H. substitution with the same in/out pair is one event; a different pair is not', () => {
  const sub = (provider, id, over = {}) => ev(provider, id, { type: 'SUBSTITUTION', playerId: undefined, teamId: 'fb_team_a', minute: 60,
    inPlayerId: 'fb_player_in', outPlayerId: 'fb_player_out', ...over });
  assert.equal(matchCanonicalEvent(sub('goal_api', 'g'), sub('sportmonks', 's')), true);
  assert.equal(matchCanonicalEvent(sub('goal_api', 'g'), sub('sportmonks', 's', { inPlayerId: 'fb_player_other' })), false);
});

test('insufficient evidence never collapses; same-provider observations never merge', () => {
  const bare = (provider, id) => ({ matchId: 'fb_match_1', type: 'YELLOW_CARD', minute: 30, provenance: { provider, eventId: id } });
  assert.equal(matchCanonicalEvent(bare('goal_api', 'g'), bare('sportmonks', 's')), false, 'type + minute only');
  assert.equal(dedupeCanonicalEvents([ev('goal_api', 'g1'), ev('goal_api', 'g2')]).length, 2);
  assert.equal(canonicalEventFingerprint(ev('goal_api', 'g', { minute: 45, extraMinute: 1 })), 'fb_match_1|GOAL|fb_team_h|46');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderQuotaError, ProviderResponseError, RequestBudget, providerCapabilities } from '../providers/core/provider.mjs';
import {
  SportmonksNormalizationError,
  createSportmonksProvider,
  mapSportmonksState,
  normalizeSportmonksFixture,
  normalizeSportmonksFixtures,
  sportmonksDescriptor,
} from '../providers/sportmonks.mjs';
import { AWAY, HOME, LEAGUE, SEASON, envelope, fixture, goalEvent, substitutionEvent } from './fixtures/sportmonks_v3.mjs';

// Sportmonks v3 adapter (#102 Phase 1A): injected fetcher only, no network,
// synthetic token and payloads.

const TOKEN = 'synthetic-sportmonks-token-DO-NOT-LEAK';
const budget = (dailyLimit = 50, perMinuteLimit = 10) =>
  new RequestBudget({ provider: 'sportmonks', dailyLimit, perMinuteLimit });
const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const resolveNone = async () => null;
const receivedAt = '2026-10-04T18:30:00.000Z';

test('descriptor: development-only LIVE provider declaring only implemented capabilities', () => {
  assert.equal(sportmonksDescriptor.id, 'sportmonks');
  assert.equal(sportmonksDescriptor.source, 'Sportmonks');
  assert.equal(sportmonksDescriptor.developmentOnly, true);
  assert.equal(sportmonksDescriptor.live, true);
  assert.deepEqual([...sportmonksDescriptor.capabilities], ['fixtures', 'liveScores', 'events']);
  for (const capability of sportmonksDescriptor.capabilities) assert.ok(providerCapabilities.includes(capability));
  assert.ok(!sportmonksDescriptor.capabilities.includes('lineups'), 'not normalized yet');
});

test('factory: token, budget and timeout are required (no invented limit)', () => {
  assert.throws(() => createSportmonksProvider({ budget: budget() }), /token is required/);
  assert.throws(() => createSportmonksProvider({ token: TOKEN }), /request budget is required/);
  assert.throws(() => createSportmonksProvider({ token: TOKEN, budget: budget(), timeoutMs: 0 }), /timeout/);
});

test('endpoints: v3 paths, includes, token in the Authorization header only', async () => {
  const calls = [];
  const provider = createSportmonksProvider({
    token: TOKEN,
    budget: budget(),
    fetcher: async (url, options) => { calls.push({ url, options }); return ok(envelope(url.includes('/fixtures/5001') ? fixture() : [])); },
  });
  await provider.fetchFixturesByDate({ date: '2026-10-04' });
  await provider.fetchLivescores();
  const one = await provider.fetchFixture({ id: 5001, includes: ['participants', 'scores', 'state', 'events.type'] });
  const urls = calls.map((c) => new URL(c.url));
  assert.deepEqual(urls.map((u) => u.pathname), [
    '/v3/football/fixtures/date/2026-10-04',
    '/v3/football/livescores/inplay',
    '/v3/football/fixtures/5001',
  ]);
  assert.equal(urls[0].searchParams.get('include'), 'participants;scores;state;events;venue;periods');
  assert.equal(urls[2].searchParams.get('include'), 'participants;scores;state;events.type');
  for (const call of calls) {
    assert.equal(call.options.headers.Authorization, TOKEN);
    assert.ok(!call.url.includes(TOKEN), 'token never in the URL');
    assert.ok(call.options.signal instanceof AbortSignal);
  }
  assert.equal(one.data.id, 5001);
  assert.deepEqual(one.rateLimit, { remaining: 2999, resetsInSeconds: 3600 });
  assert.equal(provider.budget.snapshot().dailyUsed, 3);
});

test('validation before spending quota; unsupported includes rejected', async () => {
  let calls = 0;
  const provider = createSportmonksProvider({ token: TOKEN, budget: budget(), fetcher: async () => { calls++; } });
  await assert.rejects(provider.fetchFixturesByDate({ date: 'today' }), /ISO date/);
  await assert.rejects(provider.fetchFixture({ id: '5001; drop' }), /numeric/);
  await assert.rejects(provider.fetchLivescores({ includes: ['odds'] }), /Unsupported Sportmonks include/);
  assert.equal(calls, 0);
  assert.equal(provider.budget.snapshot().dailyUsed, 0);
});

test('injected budget defends quota before the network', async () => {
  let calls = 0;
  const provider = createSportmonksProvider({ token: TOKEN, budget: budget(2, 2), fetcher: async () => { calls++; return ok(envelope([])); } });
  await provider.fetchLivescores();
  await provider.fetchLivescores();
  await assert.rejects(provider.fetchLivescores(), ProviderQuotaError);
  assert.equal(calls, 2);
});

for (const [status, message] of [[401, 'Unauthenticated'], [429, 'Too Many Attempts'], [500, 'Server Error']]) {
  test(`HTTP ${status}: sanitized ProviderResponseError, token never echoed`, async () => {
    const provider = createSportmonksProvider({
      token: TOKEN,
      budget: budget(),
      fetcher: async () => ({ ok: false, status, json: async () => ({ message: `${message} for token ${TOKEN}` }) }),
    });
    await assert.rejects(provider.fetchLivescores(), (error) => {
      assert.ok(error instanceof ProviderResponseError);
      assert.equal(error.details.httpStatus, status);
      const serialized = JSON.stringify({ message: error.message, details: error.details, stack: error.stack });
      assert.ok(!serialized.includes(TOKEN), 'no token in serialized error');
      assert.match(String(error.details.providerErrors), /\[REDACTED\]/);
      return true;
    });
  });
}

test('timeout / network errors are sanitized', async () => {
  const provider = createSportmonksProvider({
    token: TOKEN,
    budget: budget(),
    timeoutMs: 5,
    // AbortSignal.timeout does not keep the event loop alive (Node 22): the
    // guard timer does, and fails the test for real if the adapter's signal
    // never fires (instead of leaving a pending promise / cancelled test).
    fetcher: async (_url, { signal }) => new Promise((_, reject) => {
      const guard = setTimeout(() => {
        reject(new Error('AbortSignal timeout did not fire'));
      }, 500);
      signal.addEventListener('abort', () => {
        clearTimeout(guard);
        const error = new Error(`aborted ${TOKEN}`);
        error.name = 'TimeoutError';
        reject(error);
      }, { once: true });
    }),
  });
  await assert.rejects(provider.fetchLivescores(), (error) => {
    assert.ok(error instanceof ProviderResponseError);
    assert.equal(error.details.providerErrors, 'timeout');
    assert.ok(!JSON.stringify(error.details).includes(TOKEN));
    assert.ok(!error.message.includes(TOKEN));
    return true;
  });
});

test('malformed responses fail explicitly (never an empty success)', async () => {
  for (const body of [{ message: 'odd' }, { data: {} }, null]) {
    const provider = createSportmonksProvider({ token: TOKEN, budget: budget(), fetcher: async () => ok(body) });
    await assert.rejects(provider.fetchLivescores(), /payload missing/);
  }
  const provider = createSportmonksProvider({ token: TOKEN, budget: budget(), fetcher: async () => ok({ data: [] }) });
  await assert.rejects(provider.fetchFixture({ id: 1 }), /payload missing/);
});

test('status mapping: every recognized state; unknown states are never guessed', () => {
  const expected = {
    TBA: 'DISCOVERED', NS: 'SCHEDULED', DELAYED: 'SCHEDULED', INPLAY_1ST_HALF: 'LIVE', INPLAY_2ND_HALF: 'LIVE',
    HT: 'HALFTIME', BREAK: 'EXTRA_TIME', INPLAY_ET: 'EXTRA_TIME', EXTRA_TIME_BREAK: 'EXTRA_TIME',
    INPLAY_PENALTIES: 'PENALTIES', PEN_BREAK: 'PENALTIES', FT: 'FINISHED_PENDING_VERIFICATION',
    AET: 'FINISHED_PENDING_VERIFICATION', FT_PEN: 'FINISHED_PENDING_VERIFICATION',
    AWARDED: 'FINISHED_PENDING_VERIFICATION', WO: 'FINISHED_PENDING_VERIFICATION', POSTPONED: 'POSTPONED',
    SUSPENDED: 'SUSPENDED', INTERRUPTED: 'SUSPENDED', ABANDONED: 'ABANDONED', CANCELLED: 'CANCELLED',
  };
  for (const [state, status] of Object.entries(expected)) assert.equal(mapSportmonksState(state), status, state);
  for (const unknown of ['PENDING', 'DELETED', 'SOMETHING_NEW', '', null]) assert.equal(mapSportmonksState(unknown), null);
});

test('normalization: scheduled fixture identity, kickoff, participants, venue; no score', async () => {
  const n = await normalizeSportmonksFixture(fixture(), { resolve: resolveNone, receivedAt });
  assert.equal(n.externalMatchId, '5001');
  assert.equal(n.competitionExternalId, String(LEAGUE));
  assert.equal(n.seasonExternalId, String(SEASON));
  assert.equal(n.startTime, '2026-10-04T18:00:00.000Z');
  assert.equal(n.status, 'SCHEDULED');
  assert.equal(n.score, null);
  assert.equal(n.minute, null);
  assert.deepEqual([n.home.externalId, n.away.externalId], [String(HOME), String(AWAY)]);
  assert.deepEqual(n.venue, { externalId: '321', name: 'Estadio Sintético' });
  assert.deepEqual(n.canonical, { matchId: null, competitionId: null, homeTeamId: null, awayTeamId: null });
});

test('normalization: live score, ticking minute, events with provenance and score-after', async () => {
  const resolve = async (kind, id) => ({ team: { [HOME]: 'fb_team_h', [AWAY]: 'fb_team_a' }, competition: { [LEAGUE]: 'fb_comp_x' } })[kind]?.[id] ?? null;
  const n = await normalizeSportmonksFixture(fixture({
    state: 'INPLAY_1ST_HALF',
    score: [1, 0],
    periods: [{ id: 1, type_id: 1, ticking: true, minutes: 33, description: '1st-half' }],
    events: [goalEvent(11, { minute: 20 }), goalEvent(11, { minute: 20 }), substitutionEvent(12, { minute: 30 })],
  }), { resolve, receivedAt });
  assert.equal(n.status, 'LIVE');
  assert.deepEqual(n.score, { home: 1, away: 0 });
  assert.equal(n.minute, 33);
  assert.equal(n.events.length, 2, 'duplicate event id inside one payload kept once');
  const [goal, sub] = n.events;
  assert.deepEqual(goal.provenance, { provider: 'sportmonks', eventId: '11' });
  assert.deepEqual([goal.type, goal.minute, goal.side, goal.teamExternalId, goal.playerExternalId], ['GOAL', 20, 'home', String(HOME), '70001']);
  assert.deepEqual(goal.scoreAfter, { home: 1, away: 0 });
  assert.deepEqual([sub.type, sub.playerExternalId, sub.relatedPlayerExternalId, sub.side], ['SUBSTITUTION', '80002', '80001', 'away']);
  assert.deepEqual(n.canonical, { matchId: null, competitionId: 'fb_comp_x', homeTeamId: 'fb_team_h', awayTeamId: 'fb_team_a' });
});

test('normalization: halftime, fulltime, postponed; missing optional includes', async () => {
  const ht = await normalizeSportmonksFixture(fixture({ state: 'HT', score: [0, 0] }), { resolve: resolveNone, receivedAt });
  assert.deepEqual([ht.status, ht.score], ['HALFTIME', { home: 0, away: 0 }]);
  const ft = await normalizeSportmonksFixture(fixture({ state: 'FT', score: [2, 1] }), { resolve: resolveNone, receivedAt });
  assert.deepEqual([ft.status, ft.score], ['FINISHED_PENDING_VERIFICATION', { home: 2, away: 1 }]);
  const pp = await normalizeSportmonksFixture(fixture({ state: 'POSTPONED' }), { resolve: resolveNone, receivedAt });
  assert.equal(pp.status, 'POSTPONED');
  const bare = await normalizeSportmonksFixture(fixture({ state: 'NS', omit: ['scores', 'events', 'periods', 'venue'] }),
    { resolve: resolveNone, receivedAt });
  assert.deepEqual([bare.score, bare.events, bare.minute, bare.venue], [null, [], null, null]);
  // A single-sided score is not a score.
  const oneSided = fixture({ state: 'INPLAY_1ST_HALF', score: [1, 0] });
  oneSided.scores = oneSided.scores.filter((s) => s.score.participant === 'home');
  assert.equal((await normalizeSportmonksFixture(oneSided, { resolve: resolveNone, receivedAt })).score, null);
});

test('normalization: unknown state / bad participants are controlled rejections in a batch', async () => {
  await assert.rejects(normalizeSportmonksFixture(fixture({ state: 'PENDING' }), { resolve: resolveNone, receivedAt }),
    SportmonksNormalizationError);
  const noAway = fixture({ id: 5003 });
  noAway.participants = noAway.participants.filter((p) => p.meta.location === 'home');
  const { fixtures, rejected } = await normalizeSportmonksFixtures([
    fixture({ id: 5001 }), fixture({ id: 5001 }), fixture({ id: 5002, state: 'DELETED' }), noAway,
  ], { resolve: resolveNone, receivedAt });
  assert.deepEqual(fixtures.map((f) => f.externalMatchId), ['5001'], 'duplicate fixture ids kept once');
  assert.deepEqual(rejected.map((r) => r.externalMatchId), ['5002', '5003']);
  assert.match(rejected[0].reason, /Unsupported Sportmonks state: DELETED/);
  await assert.rejects(normalizeSportmonksFixtures({ not: 'an array' }, { resolve: resolveNone, receivedAt }), /must be an array/);
  await assert.rejects(normalizeSportmonksFixture(fixture(), { receivedAt }), /resolver is required/);
});

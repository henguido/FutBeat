// Provider Hub F1 (shadow, offline): API-Football contract tests against REAL
// stored responses (backend/test/fixtures/api_football, copied unmodified from
// the legacy live/date workers' raw payloads). No network, no writes.
//
// Covered by real evidence: NS / 1H / HT / 2H, score breakdown shape, cards
// (incl. a staff card without player id), a goal + VAR confirmation with
// time.extra, substitutions (player = out, assist = in), event ids stable
// across polls. NOT covered yet (no real sample): FT / AET / PEN finals, own
// goals, lineups — kept as todos, never invented.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

import {
  apiFootballFixtureObservation,
  normalizeApiFootballFixtures,
} from '../providers/api_football.mjs';
import { validateSnapshot } from '../providers/core/snapshot.mjs';

const dir = new URL('./fixtures/api_football/', import.meta.url);
const docs = readdirSync(dir)
  .filter((name) => name.endsWith('.json'))
  .sort()
  .map((name) => ({ name, ...JSON.parse(readFileSync(new URL(name, dir), 'utf8')) }));

// Every real fixture item, with where it came from.
const items = docs.flatMap((doc) => {
  const list = Array.isArray(doc.payload.response) ? doc.payload.response : [doc.payload];
  return list.map((item) => ({ file: doc.name, receivedAt: doc.contract.receivedAt, item }));
});
const byFile = (prefix) => {
  const entry = items.find((candidate) => candidate.file.startsWith(prefix));
  assert.ok(entry, `missing real fixture ${prefix}*`);
  return entry;
};
const observe = ({ item, receivedAt }) => apiFootballFixtureObservation(item, receivedAt);

const resolver = async (kind, externalId) => `fb_${kind}_${externalId}`;
const snapshotOf = ({ item, receivedAt }) =>
  normalizeApiFootballFixtures({ errors: [], results: 1, response: [item] }, resolver, receivedAt);

test('fixtures are real, unmodified and carry no secrets', () => {
  assert.ok(items.length >= 10 && items.length <= 20, `items=${items.length}`);
  const secret = /key|token|secret|authorization|apisports/i;
  const scan = (value, path) => {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      assert.doesNotMatch(key, secret, `${path}.${key}`);
      scan(child, `${path}.${key}`);
    }
  };
  for (const doc of docs) {
    assert.equal(doc.contract.real, true, doc.name);
    assert.equal(doc.contract.unmodified, true, doc.name);
    scan(doc.payload, doc.name);
  }
});

test('every real item normalizes to a secondary observation with a known status and a complete score', () => {
  for (const entry of items) {
    const observation = observe(entry);
    assert.equal(observation.provider, 'api_football');
    assert.equal(observation.externalMatchId, String(entry.item.fixture.id));
    assert.notEqual(observation.status, null, `${entry.file}: ${entry.item.fixture.status.short}`);
    assert.equal(observation.providerStatus, entry.item.fixture.status.short);
    const goals = entry.item.goals;
    assert.deepEqual(
      observation.score,
      goals.home === null ? null : { home: goals.home, away: goals.away },
      entry.file,
    );
  }
});

test('status: real short codes map the same in the observation and the snapshot', async () => {
  const expected = { NS: 'SCHEDULED', '1H': 'LIVE', HT: 'HALFTIME', '2H': 'LIVE' };
  const seen = new Set();
  for (const entry of items) {
    const short = entry.item.fixture.status.short;
    seen.add(short);
    assert.equal(observe(entry).status, expected[short], `${entry.file}: ${short}`);
    const snapshot = await snapshotOf(entry);
    validateSnapshot(snapshot);
    assert.equal(snapshot.matches[0].status, expected[short], `${entry.file}: ${short}`);
  }
  assert.deepEqual([...seen].sort(), Object.keys(expected).sort());
});

test('score: the breakdown keeps halftime / fulltime / extratime / penalty, only complete pairs', () => {
  const ht = observe(byFile('observation_13_'));
  assert.deepEqual(ht.periodScores, {
    halftime: { home: 1, away: 0 },
    fulltime: null,
    extratime: null,
    penalty: null,
  });
  assert.deepEqual(observe(byFile('observation_16_')).periodScores.halftime, { home: 1, away: 0 });

  for (const entry of items) {
    const { periodScores, score } = observe(entry);
    assert.deepEqual(Object.keys(periodScores), ['halftime', 'fulltime', 'extratime', 'penalty']);
    // Real invariant: at half time the running score is the half-time score.
    if (entry.item.fixture.status.short === 'HT') assert.deepEqual(score, periodScores.halftime, entry.file);
    // Nothing is final in the real sample: no fulltime / extra time / shoot-out.
    if (entry.item.fixture.status.short !== 'FT') assert.equal(periodScores.fulltime, null, entry.file);
  }
});

test('events: goal + VAR confirmation keep time.extra, and VAR is never a second goal', async () => {
  const entry = byFile('observation_13_');
  const observation = observe(entry);
  const goals = observation.events.filter((e) => e.type === 'GOAL');
  assert.equal(goals.length, observation.score.home + observation.score.away);
  assert.deepEqual(
    { minute: goals[0].minute, extra: goals[0].extraMinute, side: goals[0].side, player: goals[0].playerExternalId },
    { minute: 45, extra: null, side: 'home', player: '181421' },
  );
  const varEvent = observation.events.find((e) => e.type === 'VAR');
  assert.deepEqual({ minute: varEvent.minute, extra: varEvent.extraMinute }, { minute: 45, extra: 2 });

  const snapshot = await snapshotOf(entry);
  const snapshotVar = snapshot.matches[0].events.find((e) => e.type === 'VAR');
  assert.equal(snapshotVar.minute, 45);
  assert.equal(snapshotVar.extraMinute, 2);
  assert.equal(snapshot.matches[0].events.find((e) => e.type === 'GOAL').extraMinute, undefined);
});

test('cards: a staff card without player id stays on its team with no player (never created by name)', async () => {
  const entry = byFile('observation_10_');
  const observation = observe(entry);
  const cards = observation.events.filter((e) => e.type === 'YELLOW_CARD');
  assert.equal(cards.length, 3);
  const staff = cards.find((e) => e.minute === 19);
  assert.equal(staff.playerExternalId, null);
  assert.equal(staff.side, 'away');

  const snapshot = await snapshotOf(entry);
  const staffEvent = snapshot.matches[0].events.find((e) => e.minute === 19);
  assert.equal(staffEvent.playerId, undefined);
  assert.equal(snapshot.players.length, 2);
});

test('substitutions: player is the one going off, assist the one coming on (real evidence)', () => {
  const entry = byFile('observation_15_');
  const observation = observe(entry);
  const subs = observation.events.filter((e) => e.type === 'SUBSTITUTION');
  assert.equal(subs.length, 3);
  for (const sub of subs) {
    assert.equal(sub.playerExternalId, null);
    assert.ok(sub.outPlayerExternalId && sub.inPlayerExternalId);
    assert.notEqual(sub.outPlayerExternalId, sub.inPlayerExternalId);
  }
  // Evidence for the roles: two of the players going off were booked earlier
  // in the same match, so they were on the pitch; none coming on was.
  const booked = new Set(observation.events
    .filter((e) => e.type === 'YELLOW_CARD' && e.playerExternalId)
    .map((e) => e.playerExternalId));
  assert.equal(subs.filter((s) => booked.has(s.outPlayerExternalId)).length, 2);
  assert.equal(subs.filter((s) => booked.has(s.inPlayerExternalId)).length, 0);
});

test('event ids are stable across real polls of the same fixture', () => {
  const polls = ['observation_10_', 'observation_13_', 'observation_15_', 'observation_16_']
    .map((prefix) => observe(byFile(prefix)));
  const idsAt = (observation, minute) => observation.events
    .filter((e) => e.minute === minute && e.type === 'YELLOW_CARD')
    .map((e) => e.provenance.eventId);
  for (const minute of [19, 24, 25]) {
    const first = idsAt(polls[0], minute);
    assert.equal(first.length, 1);
    for (const poll of polls.slice(1)) assert.deepEqual(idsAt(poll, minute), first);
  }
  // Every poll only adds events: earlier ids are all still present.
  for (let i = 1; i < polls.length; i += 1) {
    const ids = new Set(polls[i].events.map((e) => e.provenance.eventId));
    for (const event of polls[i - 1].events) assert.ok(ids.has(event.provenance.eventId));
  }
});

test.todo('final scores: FT / AET / PEN (score.fulltime / extratime / penalty) — no real sample stored yet');
test.todo('own goal (detail "Own Goal": team and score side) — no real sample stored yet');
test.todo('lineups (/fixtures?id= includes them) — no real sample stored yet');

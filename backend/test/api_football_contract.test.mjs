// Provider Hub F1 (shadow, offline): API-Football contract tests against REAL
// responses (backend/test/fixtures/api_football): 15 items copied unmodified
// from the legacy live/date workers' raw payloads, plus 3 controlled
// `/fixtures?id=` captures (2026-10-03). No network, no writes.
//
// Covered by real evidence: NS / 1H / HT / 2H / FT / PEN, score breakdown
// (fulltime = 90', extratime = extra-time goals only, penalty = shoot-out),
// cards (incl. a staff card without player id), goal + VAR with time.extra,
// substitutions (player = out, assist = in), event ids stable across polls,
// shoot-out kicks, an own goal, lineups. NOT covered (no real sample): a
// match decided in extra time without penalties (AET) — todo, never invented.
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
  // Exact credential names only (`passes.key` is a real "key passes" stat).
  const secret = /^(x-apisports-key|x-rapidapi-key|apikey|api_key|token|access_token|authorization|secret)$/i;
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
  const expected = {
    NS: 'SCHEDULED',
    '1H': 'LIVE',
    HT: 'HALFTIME',
    '2H': 'LIVE',
    FT: 'FINISHED_PENDING_VERIFICATION',
    PEN: 'FINISHED_PENDING_VERIFICATION',
  };
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
    // Live / scheduled items carry no fulltime, extra time or shoot-out yet.
    if (['NS', '1H', 'HT', '2H'].includes(entry.item.fixture.status.short)) {
      assert.deepEqual([periodScores.fulltime, periodScores.extratime, periodScores.penalty], [null, null, null]);
    }
  }
});

test('finals: FT and PEN scores follow the real breakdown (goals exclude the shoot-out)', async () => {
  const ft = observe(byFile('fixture_976642_'));
  assert.equal(ft.status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(ft.score, { home: 2, away: 1 });
  assert.deepEqual(ft.periodScores, {
    halftime: { home: 1, away: 0 }, fulltime: { home: 2, away: 1 }, extratime: null, penalty: null,
  });

  const pen = observe(byFile('fixture_979139_'));
  assert.equal(pen.providerStatus, 'PEN');
  assert.equal(pen.status, 'FINISHED_PENDING_VERIFICATION');
  assert.equal(pen.minute, 120);
  assert.deepEqual(pen.periodScores, {
    halftime: { home: 2, away: 0 },
    fulltime: { home: 2, away: 2 },
    extratime: { home: 1, away: 1 },
    penalty: { home: 4, away: 2 },
  });
  // fulltime is the 90' score and extratime only the extra-time goals: the
  // result (goals) is their sum, without the shoot-out.
  assert.deepEqual(pen.score, {
    home: pen.periodScores.fulltime.home + pen.periodScores.extratime.home,
    away: pen.periodScores.fulltime.away + pen.periodScores.extratime.away,
  });
  const snapshot = await snapshotOf(byFile('fixture_979139_'));
  validateSnapshot(snapshot);
  assert.deepEqual(snapshot.matches[0].score, { home: 3, away: 3 });
});

test('shoot-out kicks are not match events: goals match the score, regulation penalties stay', async () => {
  const entry = byFile('fixture_979139_');
  const raw = entry.item.events.filter((e) => e.comments === 'Penalty Shootout');
  assert.equal(raw.length, 8);
  const observation = observe(entry);
  const goals = observation.events.filter((e) => e.type === 'GOAL');
  assert.equal(goals.length, observation.score.home + observation.score.away);
  assert.equal(observation.events.filter((e) => e.type === 'MISSED_PENALTY').length, 0);
  assert.equal(observation.events.length, entry.item.events.length - raw.length);
  // Regulation penalties (Messi 23', Mbappé 80' and 118') are still goals.
  assert.deepEqual(goals.map((e) => e.minute).sort((a, b) => a - b), [23, 36, 80, 81, 108, 118]);

  const snapshot = await snapshotOf(entry);
  const snapshotGoals = snapshot.matches[0].events.filter((e) => e.type === 'GOAL');
  assert.equal(snapshotGoals.length, 6);
  assert.equal(snapshot.matches[0].events.length, entry.item.events.length - raw.length);
});

test('own goal: the event team is the side credited; the scorer keeps his own team', async () => {
  const entry = byFile('fixture_976642_');
  const observation = observe(entry);
  const own = observation.events.filter((e) => e.ownGoal);
  assert.equal(own.length, 1);
  assert.deepEqual(
    { type: own[0].type, minute: own[0].minute, side: own[0].side },
    { type: 'GOAL', minute: 77, side: 'away' },
  );
  assert.equal(own[0].teamExternalId, String(entry.item.teams.away.id));
  assert.equal(own[0].playerExternalId, '5996');
  assert.equal(own[0].provenance.provider, 'api_football');
  const goals = observation.events.filter((e) => e.type === 'GOAL');
  assert.deepEqual(
    { home: goals.filter((e) => e.side === 'home').length, away: goals.filter((e) => e.side === 'away').length },
    observation.score,
  );
  assert.ok(goals.filter((e) => e !== own[0]).every((e) => e.ownGoal === false));

  const snapshot = await snapshotOf(entry);
  validateSnapshot(snapshot);
  const match = snapshot.matches[0];
  const ownEvent = match.events.find((e) => e.ownGoal);
  assert.equal(ownEvent.teamId, match.awayTeamId);
  // E. Fernández plays for Argentina (home) — never filed under Australia.
  const scorer = snapshot.players.find((p) => p.id === ownEvent.playerId);
  assert.equal(scorer.teamId, match.homeTeamId);
  const homeRows = entry.item.lineups[0].startXI.concat(entry.item.lineups[0].substitutes);
  assert.ok(homeRows.some((row) => `fb_player_${row.player.id}` === ownEvent.playerId));
});

test('lineups: both sides with formation, coach, XI and bench, provider ids only', () => {
  for (const prefix of ['fixture_979139_', 'fixture_976642_', 'fixture_1570386_']) {
    const entry = byFile(prefix);
    const { lineups } = observe(entry);
    assert.equal(lineups.length, 2, prefix);
    assert.deepEqual(lineups.map((l) => l.side), ['home', 'away'], prefix);
    for (const [i, lineup] of lineups.entries()) {
      const raw = entry.item.lineups[i];
      assert.equal(lineup.teamExternalId, String(raw.team.id));
      assert.equal(lineup.formation, raw.formation);
      assert.equal(lineup.coachExternalId, String(raw.coach.id));
      assert.equal(lineup.startXI.length, 11, prefix);
      assert.equal(lineup.substitutes.length, raw.substitutes.length);
      for (const row of [...lineup.startXI, ...lineup.substitutes]) {
        assert.match(row.playerExternalId, /^\d+$/);
        assert.ok(['G', 'D', 'M', 'F', null].includes(row.position), `${prefix}: ${row.position}`);
      }
      assert.ok(lineup.startXI.every((row) => typeof row.grid === 'string'));
    }
  }
  const betis = observe(byFile('fixture_1570386_')).lineups[0];
  assert.deepEqual(betis.startXI[0], { playerExternalId: '46990', number: 1, position: 'G', grid: '1:1' });
  // Live items carry no lineups.
  assert.equal(observe(byFile('observation_13_')).lineups, null);
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

test.todo('AET without penalties (status AET) — no real sample identified without spending quota');

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ProviderQuotaError,
  RequestBudget,
  createProviderDescriptor,
} from '../providers/core/provider.mjs';
import {
  apiFootballDescriptor,
  createApiFootballProvider,
  normalizeApiFootballLive,
} from '../providers/api_football.mjs';
import { validateSnapshot } from '../providers/core/snapshot.mjs';

test('provider descriptors reject unknown capabilities and expose API-Football LIVE capabilities', () => {
  assert.throws(() => createProviderDescriptor({
    id: 'bad',
    source: 'Bad',
    capabilities: ['telepathy'],
  }), /Unknown provider capability/);
  assert.equal(apiFootballDescriptor.id, 'api_football');
  assert.equal(apiFootballDescriptor.live, true);
  assert.ok(apiFootballDescriptor.capabilities.includes('events'));
  assert.ok(apiFootballDescriptor.capabilities.includes('liveScores'));
});

test('free-first request budget enforces 100/day and 10/minute before network calls', () => {
  let now = new Date('2026-09-16T00:00:00Z');
  const budget = new RequestBudget({
    provider: 'api_football',
    dailyLimit: 100,
    perMinuteLimit: 10,
    clock: () => now,
  });
  for (let i = 0; i < 10; i++) budget.reserve();
  assert.throws(() => budget.reserve(), ProviderQuotaError);
  now = new Date('2026-09-16T00:01:00Z');
  budget.reserve();
  assert.equal(budget.snapshot().dailyUsed, 11);
  for (let minute = 2; minute <= 9; minute++) {
    now = new Date(`2026-09-16T00:${String(minute).padStart(2, '0')}:00Z`);
    for (let i = 0; i < 10; i++) budget.reserve();
  }
  now = new Date('2026-09-16T00:10:00Z');
  for (let i = 0; i < 9; i++) budget.reserve();
  assert.equal(budget.snapshot().dailyUsed, 100);
  now = new Date('2026-09-16T00:11:00Z');
  assert.throws(() => budget.reserve(), error => (
    error instanceof ProviderQuotaError && error.details.scope === 'day'
  ));
  now = new Date('2026-09-17T00:00:00Z');
  assert.equal(budget.reserve().dailyUsed, 1);
});

test('API-Football LIVE request uses one call, server-only key and league filter', async () => {
  const calls = [];
  const provider = createApiFootballProvider({
    apiKey: 'server-secret',
    leagueIds: [162, 163],
    fetcher: async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        json: async () => ({ errors: [], results: 0, response: [] }),
      };
    },
  });
  const result = await provider.fetchLive();
  assert.equal(result.results, 0);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://v3.football.api-sports.io/fixtures?live=162-163');
  assert.equal(calls[0].options.headers['x-apisports-key'], 'server-secret');
  assert.equal(provider.budget.snapshot().dailyUsed, 1);
});

test('API-Football HTTP/API errors are sanitized and never echo the key', async () => {
  const provider = createApiFootballProvider({
    apiKey: 'do-not-leak',
    fetcher: async () => ({ ok: false, status: 429 }),
  });
  await assert.rejects(provider.fetchLive(), error => (
    /429/.test(error.message) && !/do-not-leak/.test(error.message)
  ));

  const apiError = createApiFootballProvider({
    apiKey: 'do-not-leak',
    fetcher: async () => ({
      ok: true,
      json: async () => ({ errors: { rateLimit: 'slow down' }, response: [] }),
    }),
  });
  await assert.rejects(apiError.fetchLive(), error => (
    /API errors/.test(error.message) && !/do-not-leak/.test(error.message)
  ));
});

test('LIVE payload normalizes score, goal, player and canonical references', async () => {
  const ids = new Map();
  const resolve = async (kind, externalId) => {
    const key = `${kind}:${externalId}`;
    if (!ids.has(key)) ids.set(key, `fb_${kind}_${externalId}`);
    return ids.get(key);
  };
  const raw = {
    errors: [],
    results: 1,
    response: [{
      fixture: {
        id: 9001,
        date: '2026-09-16T02:00:00+00:00',
        status: { short: '2H', elapsed: 68 },
        venue: { name: 'Estadio de prueba' },
      },
      league: {
        id: 162,
        name: 'Primera División',
        country: 'Costa Rica',
        season: 2026,
      },
      teams: {
        home: { id: 10, name: 'Equipo A' },
        away: { id: 20, name: 'Equipo B' },
      },
      goals: { home: 1, away: 0 },
      events: [{
        time: { elapsed: 68, extra: null },
        team: { id: 10, name: 'Equipo A' },
        player: { id: 77, name: 'Jugador Gol' },
        assist: { id: 88, name: 'Asistente' },
        type: 'Goal',
        detail: 'Normal Goal',
        comments: null,
      }],
    }],
  };

  const snapshot = await normalizeApiFootballLive(raw, resolve, '2026-09-16T03:08:02Z');
  validateSnapshot(snapshot);
  assert.equal(snapshot.demo, false);
  assert.equal(snapshot.matches[0].status, 'LIVE');
  assert.deepEqual(snapshot.matches[0].score, { home: 1, away: 0 });
  assert.equal(snapshot.matches[0].minute, 68);
  assert.equal(snapshot.matches[0].events[0].type, 'GOAL');
  assert.equal(snapshot.matches[0].events[0].playerId, 'fb_player_77');
  assert.equal(snapshot.players[0].name, 'Jugador Gol');
  assert.equal(snapshot.matches[0].provenance.source, 'API-Football');
});

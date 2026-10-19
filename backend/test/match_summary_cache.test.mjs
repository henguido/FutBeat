import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';
import * as matchSummary from '../../supabase/functions/_shared/match_summary.ts';

// /v1/match-summary end to end: the API builds the deterministic summary
// from the stored read model and the shared cache row is rewritten only on
// a significant change. PGlite; no provider.

const HOME = 'fb_team_msc_home';
const AWAY = 'fb_team_msc_away';
const MATCH = 'fb_match_msc';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_comp_msc','competition','{"id":"fb_comp_msc","name":"Copa Ejemplo"}'),
      ('${HOME}','team','{"id":"${HOME}","name":"Club Uno"}'),
      ('${AWAY}','team','{"id":"${AWAY}","name":"Club Dos"}'),
      ('fb_player_msc_a','player','{"id":"fb_player_msc_a","name":"Ana Delantera"}')`);
    await fn(db);
  } finally { await db.close(); }
}

async function api(db) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const ctx = { supabaseAdmin: { rpc: async (name, args = {}) => {
    if (name === 'futbeat_read_national_teams') return { data: null, error: null };
    try {
      const keys = Object.keys(args);
      const sql = `select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`;
      const values = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
      return { data: (await db.query(sql, values)).rows[0]?.v ?? null, error: null };
    } catch (error) { return { data: null, error }; }
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, TextEncoder, Intl, BigInt, setTimeout, clearTimeout, Promise,
    console: { warn() {}, error() {}, log() {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache, ...matchSummary,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  return async (query) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-summary${query}`));
    return { status: response.status, body: JSON.parse(JSON.stringify(await response.json())) };
  };
}

async function setMatch(db, payload) {
  await db.query(`insert into futbeat_private.entities values($1,'match',$2)
    on conflict(id) do update set payload=excluded.payload`, [MATCH, JSON.stringify({
    id: MATCH, competitionId: 'fb_comp_msc', homeTeamId: HOME, awayTeamId: AWAY,
    startTime: '2026-10-10T20:00:00Z', statistics: [], ...payload })]);
}
const row = (db) => db.query('select xmin::text x,generator_version,significant_hash,regenerations,phase from futbeat_private.match_summaries where match_id=$1', [MATCH]).then((r) => r.rows[0]);

test('summary is served, cached once, and rewritten only on a significant change', () => withDb(async (db) => {
  const call = await api(db);
  await setMatch(db, { status: 'VERIFIED', score: { home: 1, away: 0 }, events: [
    { id: 'fb_event_msc1', type: 'GOAL', minute: 12, teamId: HOME, playerId: 'fb_player_msc_a' },
  ] });
  const first = await call(`?id=${MATCH}`);
  assert.equal(first.status, 200);
  assert.equal(first.body.headline, 'Club Uno 1-0 Club Dos');
  assert.deepEqual(first.body.paragraphs.map((p) => p.text), [
    'Club Uno venció 1-0 a Club Dos. Copa Ejemplo.',
    'Goles de Club Uno: Ana Delantera (12′).',
  ]);
  const r1 = await row(db);
  assert.equal(r1.phase, 'FINAL');
  // Same facts: no write.
  await call(`?id=${MATCH}`);
  assert.equal((await row(db)).x, r1.x);
  // An insignificant change (a yellow card): no write.
  await setMatch(db, { status: 'VERIFIED', score: { home: 1, away: 0 }, events: [
    { id: 'fb_event_msc1', type: 'GOAL', minute: 12, teamId: HOME, playerId: 'fb_player_msc_a' },
    { id: 'fb_event_msc2', type: 'YELLOW_CARD', minute: 30, teamId: AWAY },
  ] });
  await call(`?id=${MATCH}`);
  assert.equal((await row(db)).x, r1.x);
  // A corrected score: regenerated once.
  await setMatch(db, { status: 'VERIFIED', score: { home: 1, away: 1 }, events: [
    { id: 'fb_event_msc1', type: 'GOAL', minute: 12, teamId: HOME, playerId: 'fb_player_msc_a' },
  ] });
  const corrected = await call(`?id=${MATCH}`);
  assert.equal(corrected.body.headline, 'Club Uno 1-1 Club Dos');
  assert.ok(corrected.body.omissions.some((o) => o.code === 'scorers_unverified'));
  const r2 = await row(db);
  assert.notEqual(r2.significant_hash, r1.significant_hash);
  assert.equal(r2.regenerations, 1);
}));

test('an older generator never overwrites a newer cached summary', () => withDb(async (db) => {
  await setMatch(db, { status: 'SCHEDULED' });
  const call = await api(db);
  const { body } = await call(`?id=${MATCH}`);
  const store = (summary) => db.query('select public.futbeat_store_match_summary($1,$2) v', [MATCH, JSON.stringify(summary)]).then((r) => r.rows[0].v);
  assert.deepEqual(await store({ ...body, generatorVersion: '9.0.0' }), { status: 'regenerated' });
  assert.deepEqual(await store(body), { status: 'older_generator', kept: '9.0.0' });
  await assert.rejects(store({ ...body, matchId: 'fb_match_other' }));
  await assert.rejects(store({ ...body, contractVersion: 2 }));
}));

test('validation: bad id 400, unknown match 404', () => withDb(async (db) => {
  const call = await api(db);
  assert.equal((await call('?id=../x')).status, 400);
  assert.equal((await call('?id=fb_match_missing')).status, 404);
}));

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #161: competition + season as the profile context. Synthetic ids/names
// only; DB-only reads; no provider call anywhere.

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const DAY = 24 * 3600e3;
const iso = (ms) => new Date(ms).toISOString();
let seq = 0;
async function entity(db, kind, prefix, payload) {
  const id = `${prefix}${++seq}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  return id;
}
const team = (db, name, extra = {}) => entity(db, 'team', 'fb_team_pc', { name, ...extra });
const competition = (db, name, season) => entity(db, 'competition', 'fb_comp_pc', { name, ...(season ? { season } : {}) });
async function match(db, { comp, home, away, at, season, status = 'VERIFIED', score = [1, 0] }) {
  return entity(db, 'match', 'fb_match_pc', {
    competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: iso(at), status,
    ...(season !== undefined ? { season } : {}),
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [],
  });
}
async function snapshot(db, comp, seasonKey, season, teamIds, fetchedAgoDays = 1) {
  const rows = teamIds.map((teamId, i) => ({ position: i + 1, teamId, played: 3, won: 1, drawn: 1, lost: 1, gf: 3, ga: 3, points: 4 }));
  await db.query(`insert into futbeat_private.standings_snapshots(competition_id,season_key,season,table_payload,fetched_at)
    values($1,$2,$3,$4,now()-make_interval(days=>$5))`,
  [comp, seasonKey, season, JSON.stringify({ competitionId: comp, season, provisional: false, source: 'goal_api', rows }), fetchedAgoDays]);
}
const context = (db, id, comp = null, season = null) => db.query(
  'select public.futbeat_read_team_context($1,$2,$3) v', [id, comp, season]).then((r) => r.rows[0].v);
const teamMatches = (db, id, bucket, { cursor = null, limit = 20, comp = null, season = null } = {}) => db.query(
  'select public.futbeat_read_team_matches($1,$2,$3,$4,$5,$6) v', [id, bucket, cursor, limit, comp, season]).then((r) => r.rows[0].v);
const key = (o) => `${o.competitionId}|${o.seasonKey ?? '-'}`;

// A national team with two Nations League seasons, a World Cup, friendlies
// without a season label, and an alias identity.
async function world(db) {
  const now = Date.now();
  const nations = await competition(db, 'Liga de Naciones PC', '2026/27');
  const cup = await competition(db, 'Copa Mundial PC', '2026');
  const friendly = await competition(db, 'Amistosos PC');
  const T = await team(db, 'Selección PC', { competitionId: nations });
  const alias = await team(db, 'Selección PC (alias)');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [alias, T]);
  const R = [await team(db, 'Rival PC 1'), await team(db, 'Rival PC 2'), await team(db, 'Rival PC 3')];
  const ids = {};
  ids.oldNations = [
    await match(db, { comp: nations, home: T, away: R[0], at: now - 400 * DAY, season: '2024/25' }),
    await match(db, { comp: nations, home: R[1], away: alias, at: now - 380 * DAY, season: '2024-2025' }),
  ];
  ids.nations = [
    await match(db, { comp: nations, home: T, away: R[0], at: now - 20 * DAY, season: '2026/27' }),
    await match(db, { comp: nations, home: R[1], away: T, at: now - 10 * DAY, season: '2026-27' }),
    await match(db, { comp: nations, home: T, away: R[2], at: now + 12 * DAY, season: '2026/27', status: 'SCHEDULED', score: null }),
  ];
  ids.cup = [await match(db, { comp: cup, home: T, away: R[2], at: now - 90 * DAY, season: '2026' })];
  ids.friendly = [await match(db, { comp: friendly, home: alias, away: R[1], at: now - 30 * DAY })];
  // Not the team's: never an option.
  await match(db, { comp: cup, home: R[0], away: R[1], at: now - 5 * DAY, season: '2030' });
  return { now, nations, cup, friendly, T, alias, R, ids };
}

// ---------------------------------------------------------------------------

test('options are the real (competition, season) combinations, aliases included, no invented season', () => withDb(async (db) => {
  const w = await world(db);
  const c = await context(db, w.T);
  assert.equal(c.teamId, w.T);
  const byKey = new Map(c.options.map((o) => [key(o), o]));
  assert.deepEqual([...byKey.keys()].sort(), [
    `${w.cup}|2026`, `${w.friendly}|-`, `${w.nations}|2024-2025`, `${w.nations}|2026-2027`].sort());
  assert.equal(byKey.get(`${w.nations}|2026-2027`).matchCount, 3);
  assert.equal(byKey.get(`${w.nations}|2024-2025`).matchCount, 2, 'alias match joins the canonical team');
  assert.equal(byKey.get(`${w.friendly}|-`).seasonKey, undefined, 'no season: none invented');
  assert.ok(byKey.get(`${w.nations}|2026-2027`).nextStart);
  assert.equal(byKey.get(`${w.cup}|2026`).competitionName, 'Copa Mundial PC');
  assert.ok(!c.options.some((o) => o.seasonKey === '2030'));
  // Grouped by season (newest first), seasonless last.
  assert.deepEqual(c.options.map((o) => o.seasonKey ?? null), ['2026-2027', '2026', '2024-2025', null]);
  // Same answer through the alias id.
  assert.deepEqual((await context(db, w.alias)).options, c.options);
}));

test('default is deterministic: active, with the team in its table, main competition first', () => withDb(async (db) => {
  const w = await world(db);
  // No tables at all: the active main competition (upcoming match).
  let c = await context(db, w.T);
  assert.deepEqual(c.selected, { competitionId: w.nations, seasonKey: '2026-2027', requested: false });
  assert.deepEqual(c.standings, []);
  assert.equal(c.coverage.standings, 'missing');
  // Only the cup has a table with the team: an active option with a table wins.
  await snapshot(db, w.cup, '2026', '2026', [w.R[2], w.T]);
  c = await context(db, w.T);
  assert.deepEqual(c.selected, { competitionId: w.cup, seasonKey: '2026', requested: false });
  assert.equal(c.standings[0].competitionId, w.cup);
  // Both have tables: the main competition.
  await snapshot(db, w.nations, '2026-2027', '2026/27', [w.T, w.R[0], w.R[1]]);
  c = await context(db, w.T);
  assert.equal(c.selected.competitionId, w.nations);
  // A table that does not contain the team never counts as "has table".
  const other = await snapshot(db, w.nations, '2024-2025', '2024/25', [w.R[0], w.R[1]]);
  void other;
  const old = (await context(db, w.T)).options.find((o) => key(o) === `${w.nations}|2024-2025`);
  assert.equal(old.hasStandings, false);
  // Repeated reads: identical.
  for (let i = 0; i < 3; i++) assert.deepEqual((await context(db, w.T)).selected, c.selected);
}));

test('a requested context is honoured only when real; its table is exactly that season', () => withDb(async (db) => {
  const w = await world(db);
  await snapshot(db, w.nations, '2026-2027', '2026/27', [w.T, w.R[0]]);
  await snapshot(db, w.nations, '2024-2025', '2024/25', [w.R[0], w.T, w.R[1]]);
  let c = await context(db, w.T, w.nations, '2024-2025');
  assert.deepEqual(c.selected, { competitionId: w.nations, seasonKey: '2024-2025', requested: true });
  assert.equal(c.standings.length, 1);
  assert.equal(c.standings[0].season, '2024/25', 'never another season');
  assert.equal(c.standings[0].rows.length, 3);
  assert.ok(c.teams.some((t) => t.id === w.R[1]), 'every table row has its team entity');
  // A raw label from a match is normalized like the stored seasons.
  assert.equal((await context(db, w.T, w.nations, '2024/25')).selected.seasonKey, '2024-2025');
  // Competition only: its latest season.
  c = await context(db, w.T, w.nations);
  assert.deepEqual(c.selected, { competitionId: w.nations, seasonKey: '2026-2027', requested: true });
  // A season the team never played: default instead, flagged as not requested.
  c = await context(db, w.T, w.nations, '1999');
  assert.equal(c.selected.requested, false);
  // A competition the team never played: default.
  const foreign = await competition(db, 'Otra PC');
  assert.equal((await context(db, w.T, foreign)).selected.requested, false);
  // A seasonless option has no table (never a guessed season).
  c = await context(db, w.T, w.friendly);
  assert.deepEqual(c.selected, { competitionId: w.friendly, requested: true });
  assert.deepEqual(c.standings, []);
  // '-' selects the seasonless option even when the competition also has
  // seasons (never silently replaced by its latest season).
  await match(db, { comp: w.friendly, home: w.T, away: w.R[0], at: w.now - 40 * DAY, season: '2026' });
  assert.equal((await context(db, w.T, w.friendly)).selected.seasonKey, '2026');
  c = await context(db, w.T, w.friendly, '-');
  assert.deepEqual(c.selected, { competitionId: w.friendly, requested: true });
  const seasonless = await teamMatches(db, w.T, 'results', { comp: w.friendly, season: '-' });
  assert.deepEqual(seasonless.matches.map((m) => m.id), w.ids.friendly);
  // An uppercase raw label is normalized like the stored seasons.
  assert.equal((await context(db, w.T, w.cup, ' 2026 ')).selected.seasonKey, '2026');
}));

test('default prefers the competition\'s current season over last season\'s table (close season)', () => withDb(async (db) => {
  const now = Date.now();
  const league = await competition(db, 'Liga PC Cierre', '2026/27');
  const T = await team(db, 'Club PC Cierre', { competitionId: league });
  const R = await team(db, 'Rival PC Cierre');
  await match(db, { comp: league, home: T, away: R, at: now - 60 * DAY, season: '2025/26' });
  await match(db, { comp: league, home: R, away: T, at: now + 20 * DAY, season: '2026/27', status: 'SCHEDULED', score: null });
  await snapshot(db, league, '2025-2026', '2025/26', [T, R]);
  const c = await context(db, T);
  assert.deepEqual(c.selected, { competitionId: league, seasonKey: '2026-2027', requested: false });
  assert.equal(c.options.find((o) => o.seasonKey === '2026-2027').currentSeason, true);
  assert.equal(c.options.find((o) => o.seasonKey === '2025-2026').currentSeason, false);
}));

test('the context table is in canonical ids (competition and row teams)', () => withDb(async (db) => {
  const w = await world(db);
  const oldTeam = await team(db, 'Rival PC viejo');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [oldTeam, w.R[0]]);
  const aliasComp = await competition(db, 'Liga de Naciones PC (id viejo)');
  await snapshot(db, w.nations, '2026-2027', '2026/27', [w.T, oldTeam]);
  await db.query(`update futbeat_private.standings_snapshots set table_payload=jsonb_set(table_payload,'{competitionId}',to_jsonb($1::text))
    where competition_id=$2`, [aliasComp, w.nations]);
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'competition','test')", [aliasComp, w.nations]);
  const c = await context(db, w.T);
  assert.equal(c.standings[0].competitionId, w.nations);
  assert.deepEqual(c.standings[0].rows.map((r) => r.teamId), [w.T, w.R[0]]);
  assert.ok(c.teams.some((t) => t.id === w.R[0]));
}));

test('context: invalid input rejected, unknown team is null, no team without matches breaks', () => withDb(async (db) => {
  await assert.rejects(context(db, ''), /Invalid team context request/);
  await assert.rejects(context(db, 'fb_team_x', 'fb_comp_x', 'x'.repeat(41)), /Invalid team context request/);
  assert.equal(await context(db, 'fb_team_missing'), null);
  const lonely = await team(db, 'Sin partidos PC');
  const c = await context(db, lonely);
  assert.deepEqual(c.options, []);
  assert.equal(c.selected, null);
  assert.deepEqual(c.standings, []);
  assert.ok(c.coverage.teamMatches.state);
}));

test('team matches: competition + season filter (canonical, normalized), keyset pages without gaps', () => withDb(async (db) => {
  const w = await world(db);
  // Many more results in the current Nations League season.
  const extra = [];
  for (let i = 1; i <= 25; i++) {
    extra.push(await match(db, { comp: w.nations, home: i % 2 ? w.T : w.R[0], away: i % 2 ? w.R[1] : w.alias,
      at: w.now - (30 + i) * DAY, season: i % 3 ? '2026/27' : '2026-2027' }));
  }
  const pages = [];
  let cursor = null;
  do {
    const p = await teamMatches(db, w.T, 'results', { cursor, limit: 7, comp: w.nations, season: '2026-2027' });
    pages.push(p); cursor = p.nextCursor;
  } while (cursor);
  const ids = pages.flatMap((p) => p.matches.map((m) => m.id));
  assert.equal(new Set(ids).size, ids.length, 'no duplicates');
  assert.deepEqual(new Set(ids), new Set([...w.ids.nations.slice(0, 2), ...extra]));
  assert.ok(pages.every((p) => p.competitionId === w.nations && p.seasonKey === '2026-2027'));
  // Upcoming respects the filter too; another competition's upcoming never leaks.
  await match(db, { comp: w.cup, home: w.T, away: w.R[0], at: w.now + 5 * DAY, season: '2026', status: 'SCHEDULED', score: null });
  const up = await teamMatches(db, w.T, 'upcoming', { comp: w.nations, season: '2026-2027' });
  assert.deepEqual(up.matches.map((m) => m.id), [w.ids.nations[2]]);
  const raw = await teamMatches(db, w.T, 'results', { limit: 50, comp: w.nations, season: '2026/27' });
  assert.equal(raw.seasonKey, '2026-2027');
  assert.equal(raw.matches.length, 2 + 25);
  // Competition only: every season of it.
  const all = await teamMatches(db, w.T, 'results', { limit: 50, comp: w.nations });
  assert.equal(all.matches.length, 2 + 25 + 2);
  // Unfiltered: unchanged behaviour (every competition), coverage exposed.
  const plain = await teamMatches(db, w.T, 'results', { limit: 50 });
  assert.equal(plain.matches.length, 2 + 25 + 2 + 1 + 1);
  assert.equal(plain.competitionId, null);
  assert.ok(['AVAILABLE', 'STALE', 'PENDING', 'NO_DATA', 'UNAVAILABLE'].includes(plain.coverage.teamMatches.state));
  // The 4-argument call of older callers still works.
  const legacy = (await db.query("select public.futbeat_read_team_matches($1,'results',null,50) v", [w.T])).rows[0].v;
  assert.equal(legacy.matches.length, plain.matches.length);
  await assert.rejects(teamMatches(db, w.T, 'results', { comp: '' }), /Invalid team matches request/);
}));

test('team matches filter resolves competition aliases; a match without season never matches a season', () => withDb(async (db) => {
  const w = await world(db);
  const aliasComp = await competition(db, 'Liga de Naciones PC (alias)');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'competition','test')", [aliasComp, w.nations]);
  const viaAlias = await match(db, { comp: aliasComp, home: w.T, away: w.R[2], at: w.now - 2 * DAY, season: '2026/27' });
  const r = await teamMatches(db, w.T, 'results', { comp: w.nations, season: '2026-2027' });
  assert.ok(r.matches.some((m) => m.id === viaAlias));
  assert.ok((await teamMatches(db, w.T, 'results', { comp: aliasComp, season: '2026-2027' })).matches.some((m) => m.id === viaAlias));
  const f = await teamMatches(db, w.T, 'results', { comp: w.friendly, season: '2026' });
  assert.deepEqual(f.matches, []);
  // The alias competition shows up once, as the canonical option.
  const c = await context(db, w.T);
  assert.equal(c.options.filter((o) => key(o) === `${w.nations}|2026-2027`).length, 1);
  assert.ok(!c.options.some((o) => o.competitionId === aliasComp));
}));

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

async function api(db) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const rpcs = [];
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    if (name !== 'futbeat_read_national_teams') rpcs.push({ name, args });
    const keys = Object.keys(args ?? {});
    try {
      const v = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, keys.map((k) => args[k]))).rows[0]?.v;
      return { data: v ?? null, error: null };
    } catch (error) { return { data: null, error: { message: error.message } }; }
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, setTimeout, clearTimeout, console: { warn: () => {}, error: () => {}, log: () => {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache,
  });
  const code = stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {');
  vm.runInContext(code, context);
  const call = async (route, query) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/${route}${query}`));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { call, rpcs };
}

test('API: /v1/team-context validates and reads; /v1/team-matches forwards the filter', () => withDb(async (db) => {
  const w = await world(db);
  const { call, rpcs } = await api(db);
  const ok = await call('team-context', `?id=${w.T}&competitionId=${w.nations}&season=2024-2025`);
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.selected, { competitionId: w.nations, seasonKey: '2024-2025', requested: true });
  assert.match(ok.cache, /max-age/);
  assert.equal((await call('team-context', `?id=${w.T}`)).body.selected.competitionId, w.nations);
  assert.equal((await call('team-context', '?id=nope')).status, 400);
  assert.equal((await call('team-context', `?id=${w.T}&season=2026`)).status, 400, 'a season needs its competition');
  assert.equal((await call('team-context', `?id=${w.T}&competitionId=${w.nations}&season=${'9'.repeat(41)}`)).status, 400);
  assert.equal((await call('team-context', `?id=${w.T}&competitionId=${w.nations}&season=${encodeURIComponent('Apertura 2026')}`)).status, 200,
    'raw labels are accepted and normalized by the server');
  assert.equal((await call('team-context', `?id=${w.T}&competitionId=${w.friendly}&season=-`)).body.selected.competitionId, w.friendly);
  assert.equal((await call('team-context', '?id=fb_team_missing_pc')).status, 404);
  const filtered = await call('team-matches', `?id=${w.T}&bucket=results&competitionId=${w.nations}&season=2026-2027`);
  assert.equal(filtered.status, 200);
  assert.equal(filtered.body.matches.length, 2);
  assert.equal((await call('team-matches', `?id=${w.T}&bucket=results&season=2026`)).status, 400);
  assert.equal((await call('team-matches', `?id=${w.T}&bucket=results&competitionId=bad`)).status, 400);
  // The end of a FILTERED list is not the end of the team's history.
  assert.ok(!rpcs.some((r) => r.name === 'futbeat_request_team_matches'));
  // Unfiltered calls keep the 4 original arguments.
  await call('team-matches', `?id=${w.T}&bucket=upcoming`);
  assert.deepEqual(Object.keys(rpcs.at(-1).args).sort(), ['p_bucket', 'p_cursor', 'p_limit', 'p_team_id']);
}));

test('grants: the context reads are service_role only; the options helper is private', () => withDb(async (db) => {
  const rows = (await db.query(`select p.proname, r.rolname,
      has_function_privilege(r.rolname, p.oid, 'execute') can
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    cross join (select rolname from pg_roles where rolname in ('anon','authenticated','service_role')) r
    where (n.nspname='public' and p.proname in ('futbeat_read_team_context','futbeat_read_team_matches'))
       or (n.nspname='futbeat_private' and p.proname='team_context_options')`)).rows;
  assert.ok(rows.length >= 9);
  for (const r of rows) {
    const expected = r.rolname === 'service_role' && r.proname !== 'team_context_options';
    assert.equal(r.can, expected, `${r.proname} / ${r.rolname}`);
  }
  assert.equal((await db.query(`select count(*)::int n from pg_proc where proname='futbeat_read_team_matches'`)).rows[0].n, 1,
    'one signature (no ambiguous overload)');
}));

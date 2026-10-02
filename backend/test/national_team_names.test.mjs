import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// National teams get a stable country code (+ age/gender suffix) from the
// catalog, so the app can show them under their localized name. Fixture
// names are catalogued country names on purpose; the production SQL names
// none. Synthetic data only; no provider is ever called.

async function seed(db) {
  const rows = [];
  let n = 0;
  const team = (id, name, competitionId) => rows.push({ id, kind: 'team', name, competitionId, country: '' });
  const match = (competitionId, home, away) => rows.push({
    id: `fb_match_nt_${++n}`, kind: 'match', competitionId, homeTeamId: home, awayTeamId: away,
    startTime: '2026-09-01T18:00:00Z', status: 'FINISHED', score: { home: 1, away: 0 }, events: [],
  });
  rows.push(
    { id: 'fb_comp_nations', kind: 'competition', name: 'Nations Cup', country: 'intl' },
    // The catalog classifies these as club competitions (as production does
    // for mixed friendlies and youth qualifiers).
    { id: 'fb_comp_friendlies', kind: 'competition', name: 'Friendlies', country: 'World' },
    { id: 'fb_comp_youth', kind: 'competition', name: 'Youth Qualification', country: 'Europe' },
    { id: 'fb_comp_women', kind: 'competition', name: 'Women Qualifiers', country: '' },
    { id: 'fb_comp_club_friendlies', kind: 'competition', name: 'Club Friendlies', country: 'World' },
    { id: 'fb_comp_club_cup', kind: 'competition', name: 'Continental Club Cup', country: 'Europe' },
    { id: 'fb_comp_league', kind: 'competition', name: 'First Division', country: 'France' },
  );
  team('fb_team_az', 'Azerbaijan', 'fb_comp_nations');
  team('fb_team_gr', 'Greece', 'fb_comp_friendlies');
  team('fb_team_nl', 'Netherlands', 'fb_comp_nations');
  team('fb_team_pl', 'Poland', 'fb_comp_friendlies');
  team('fb_team_pl19', 'Poland U19', 'fb_comp_friendlies');
  team('fb_team_kz19', 'Kazakhstan U19', 'fb_comp_youth');
  team('fb_team_kp20', 'Korea DPR U20', 'fb_comp_youth');
  team('fb_team_pf', 'Tahiti', 'fb_comp_nations');
  team('fb_team_nlw', 'Netherlands W', 'fb_comp_women');
  team('fb_team_es20w', 'Spain U20 Women', 'fb_comp_women');
  team('fb_team_unnamed_nation', 'Atlantis', 'fb_comp_friendlies');
  // Clubs: a namesake of a country in its domestic league and in club
  // tournaments, a youth club whose name starts with a country alias, and
  // an exact namesake playing club friendlies against other clubs.
  team('fb_team_namesake', 'Monaco', 'fb_comp_league');
  team('fb_team_club_a', 'Olympique Club', 'fb_comp_league');
  team('fb_team_club_b', 'Racing Club', 'fb_comp_league');
  team('fb_team_prefix_club', 'Polonia Warszawa U19', 'fb_comp_youth');
  team('fb_team_friendly_namesake', 'Guadalupe', 'fb_comp_club_friendlies');
  team('fb_team_club_c', 'Sporting Club', 'fb_comp_club_friendlies');
  team('fb_team_club_d', 'Athletic Club', 'fb_comp_club_friendlies');
  // A name two countries share in the catalog is ambiguous.
  team('fb_team_ambiguous', 'Congo', 'fb_comp_nations');
  // A redirected duplicate of a national team.
  team('fb_team_pl_dup', 'Poland', 'fb_comp_friendlies');

  match('fb_comp_nations', 'fb_team_az', 'fb_team_nl');
  match('fb_comp_nations', 'fb_team_ambiguous', 'fb_team_az');
  match('fb_comp_friendlies', 'fb_team_gr', 'fb_team_pl');
  match('fb_comp_friendlies', 'fb_team_pl19', 'fb_team_unnamed_nation');
  match('fb_comp_youth', 'fb_team_pl19', 'fb_team_kz19');
  match('fb_comp_youth', 'fb_team_kz19', 'fb_team_kp20');
  match('fb_comp_youth', 'fb_team_prefix_club', 'fb_team_kp20');
  match('fb_comp_women', 'fb_team_nlw', 'fb_team_es20w');
  match('fb_comp_league', 'fb_team_namesake', 'fb_team_club_a');
  match('fb_comp_league', 'fb_team_club_b', 'fb_team_namesake');
  match('fb_comp_club_cup', 'fb_team_namesake', 'fb_team_club_c');
  match('fb_comp_club_friendlies', 'fb_team_friendly_namesake', 'fb_team_club_c');
  match('fb_comp_club_friendlies', 'fb_team_club_d', 'fb_team_friendly_namesake');
  await db.query(`insert into futbeat_private.entities select item->>'id',item->>'kind',item-'kind'
    from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
  await db.exec(`
    insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
      values('fb_team_pl_dup','fb_team_pl','team','test');
    update futbeat_private.country_catalog set aliases=aliases||'["congo"]'
      where canonical_name='Congo - Kinshasa';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code=null,
      competition_class='international_national',audience_class='open'
      where competition_id='fb_comp_nations';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='WORLD',
      competition_class='international_club',audience_class='unknown'
      where competition_id in ('fb_comp_friendlies','fb_comp_club_friendlies');
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='EUROPE',
      competition_class='international_club',audience_class='unknown'
      where competition_id in ('fb_comp_youth','fb_comp_club_cup');
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code=null,
      competition_class='other',audience_class='unknown'
      where competition_id='fb_comp_women';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='FR',
      competition_class='domestic_league',domestic_tier=1,is_primary_domestic=true,audience_class='open'
      where competition_id='fb_comp_league';`);
}

const identities = async (db) => Object.fromEntries((await db.query(
  'select team_id,country_code,suffix from futbeat_private.national_team_identities()',
)).rows.map((r) => [r.team_id, r.suffix ? `${r.country_code} ${r.suffix}` : r.country_code]));

const read = async (db) => (await db.query('select public.futbeat_read_national_teams() v')).rows[0].v;

test('national teams are identified by catalogued name plus national-team competitions', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const found = await identities(db);
    assert.equal(found.fb_team_az, 'AZ');
    assert.equal(found.fb_team_nl, 'NL');
    // Mixed friendlies / youth qualifiers count by their participants even
    // when the catalog calls them club competitions.
    assert.equal(found.fb_team_gr, 'GR');
    assert.equal(found.fb_team_pl, 'PL');
    assert.equal(found.fb_team_pl19, 'PL U19');
    assert.equal(found.fb_team_kz19, 'KZ U19');
    // Provider spelling added to the catalog aliases.
    assert.equal(found.fb_team_kp20, 'KP U20');
    assert.equal(found.fb_team_pf, 'PF');
    assert.equal(found.fb_team_nlw, 'NL W');
    assert.equal(found.fb_team_es20w, 'ES U20 W');
    // A redirected duplicate answers its canonical team's identity.
    assert.equal(found.fb_team_pl_dup, 'PL');

    // Negative cases.
    assert.equal(found.fb_team_namesake, undefined, 'domestic club named like a country');
    assert.equal(found.fb_team_friendly_namesake, undefined, 'club friendlies are club competitions');
    assert.equal(found.fb_team_prefix_club, undefined, 'a country alias inside a club name');
    assert.equal(found.fb_team_ambiguous, undefined, 'a name two countries share');
    assert.equal(found.fb_team_unnamed_nation, undefined, 'no catalogued country');
    for (const club of ['fb_team_club_a', 'fb_team_club_b', 'fb_team_club_c', 'fb_team_club_d']) {
      assert.equal(found[club], undefined, club);
    }
  } finally { await db.close(); }
});

test('the national-team map is cached and recomputed after catalog changes', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const first = await read(db);
    assert.equal(first.schemaVersion, 1);
    assert.deepEqual(first.teams.fb_team_pl19, { code: 'PL', suffix: 'U19' });
    assert.deepEqual(first.teams.fb_team_az, { code: 'AZ' });
    assert.equal(first.teams.fb_team_namesake, undefined);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.national_team_cache')).rows[0].n, 1);

    // A new national team changes the catalog revision; within 10 minutes
    // the cached map is served as is.
    await db.exec(`insert into futbeat_private.entities values('fb_team_gr19','team',
      '{"id":"fb_team_gr19","name":"Greece U19","competitionId":"fb_comp_youth"}')`);
    assert.equal((await read(db)).teams.fb_team_gr19, undefined);
    await db.exec(`update futbeat_private.national_team_cache set computed_at=now()-interval '11 minutes'`);
    assert.deepEqual((await read(db)).teams.fb_team_gr19, { code: 'GR', suffix: 'U19' });
    // Unchanged revision: the cache stays valid regardless of its age.
    await db.exec(`update futbeat_private.national_team_cache set computed_at=now()-interval '1 day'`);
    await db.exec(`delete from futbeat_private.entity_redirects where alias_id='fb_team_pl_dup'`);
    const revision = (await db.query('select revision from futbeat_private.catalog_cache_version')).rows[0].revision;
    await db.query('update futbeat_private.national_team_cache set version=$1', [revision]);
    assert.deepEqual((await read(db)).teams.fb_team_pl_dup, { code: 'PL' });

    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_national_teams()','execute') ok", [role])).rows[0].ok, false);
      assert.equal((await db.query("select has_table_privilege($1,'futbeat_private.national_team_cache','select') ok", [role])).rows[0].ok, false);
    }
    assert.equal((await db.query("select has_function_privilege('service_role','public.futbeat_read_national_teams()','execute') ok")).rows[0].ok, true);
  } finally { await db.close(); }
});

async function api(answers, clock = Date) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const rpcs = [];
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    rpcs.push(name);
    return answers[name] ? answers[name](args) : { data: null, error: null };
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, setTimeout, clearTimeout, Object, Promise, Date: clock, console: { warn() {}, error() {}, log() {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (path) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/${path}`));
    return { status: response.status, body: await response.json() };
  };
  return { call, rpcs };
}

const calendar = () => ({
  schemaVersion: 1, demo: false, coverage: { partial: false }, competitions: [],
  teams: [
    { id: 'fb_team_pl19', name: 'Poland U19', country: '' },
    { id: 'fb_team_az', name: 'Azerbaijan', country: '' },
    { id: 'fb_team_namesake', name: 'Monaco', country: '' },
  ],
  matches: [{ id: 'fb_match_nt_1', homeTeamId: 'fb_team_pl19', awayTeamId: 'fb_team_az' }],
});

test('API: team objects carry nationalTeamCode/Suffix from the cached map, clubs untouched', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const map = await read(db);
    const { call, rpcs } = await api({
      futbeat_read_national_teams: () => ({ data: map, error: null }),
      futbeat_read_calendar_range: () => ({ data: calendar(), error: null }),
      futbeat_read_entity_detail: () => ({ data: {
        schemaVersion: 1, demo: false, entity: { id: 'fb_team_pl19', name: 'Poland U19' },
        teams: [{ id: 'fb_team_nlw', name: 'Netherlands W' }], players: [{ id: 'fb_player_x', name: 'Poland', teamId: 'fb_team_pl19' }],
      }, error: null }),
    });
    const day = await call('calendar?date=2026-09-01');
    assert.equal(day.status, 200);
    const byId = Object.fromEntries(day.body.teams.map((t) => [t.id, t]));
    assert.equal(byId.fb_team_pl19.nationalTeamCode, 'PL');
    assert.equal(byId.fb_team_pl19.nationalTeamSuffix, 'U19');
    // Provider name is kept: the app decides what to show.
    assert.equal(byId.fb_team_pl19.name, 'Poland U19');
    assert.equal(byId.fb_team_az.nationalTeamCode, 'AZ');
    assert.equal('nationalTeamSuffix' in byId.fb_team_az, false);
    assert.equal('nationalTeamCode' in byId.fb_team_namesake, false);
    assert.deepEqual(day.body.matches, calendar().matches);

    const detail = await call('entity?type=team&id=fb_team_pl19');
    assert.equal(detail.body.entity.nationalTeamCode, 'PL');
    assert.equal(detail.body.teams[0].nationalTeamSuffix, 'W');
    assert.equal(detail.body.players[0].nationalTeamCode, undefined, 'only team objects');
    // One map read per isolate, not per request.
    assert.equal(rpcs.filter((name) => name === 'futbeat_read_national_teams').length, 1);

    // Invalid requests never reach the database.
    const before = rpcs.length;
    assert.equal((await call('calendar?date=nope')).status, 400);
    assert.equal(rpcs.length, before);
  } finally { await db.close(); }
});

test('API: without the national-team map answers are served unchanged', async () => {
  const { call } = await api({
    futbeat_read_national_teams: () => { throw new Error('down'); },
    futbeat_read_calendar_range: () => ({ data: calendar(), error: null }),
  });
  const day = await call('calendar?date=2026-09-01');
  assert.equal(day.status, 200);
  assert.deepEqual(day.body, calendar());
});

test('the migration names no country, league or team in its derivation', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20261002100000_national_team_names.sql', import.meta.url), 'utf8');
  const derivation = sql.slice(sql.indexOf('create or replace function futbeat_private.national_team_identities'))
    .split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(derivation, /'[A-Z]{2}(?:-[A-Z]{3})?'/);
  assert.doesNotMatch(derivation, /fb_(team|comp|competition)_[0-9a-f]{8}/);
});

test('API: a refresh never delays answers; a stalled cold load is cut off at ~1 s', async () => {
  let now = Date.now();
  class Clock extends Date {}
  Clock.now = () => now;
  const map = { schemaVersion: 1, teams: { fb_team_pl19: { code: 'PL', suffix: 'U19' } } };
  let mode = 'ok';
  let reads = 0;
  const { call } = await api({
    futbeat_read_national_teams: () => {
      reads++;
      // A stalled RPC: never settles.
      return mode === 'ok' ? { data: map, error: null } : new Promise(() => {});
    },
    futbeat_read_calendar_range: () => ({ data: calendar(), error: null }),
  }, Clock);
  const team = (body) => body.teams.find((t) => t.id === 'fb_team_pl19');

  // Cold isolate: waits for the (fast) first load and decorates.
  assert.equal(team((await call('calendar?date=2026-09-01')).body).nationalTeamCode, 'PL');
  assert.equal(reads, 1);

  // Expired map with a stalled refresh: answered at once with the old map.
  now += 11 * 60 * 1000;
  mode = 'stalled';
  let started = performance.now();
  const warm = await call('calendar?date=2026-09-01');
  assert.ok(performance.now() - started < 500, 'a refresh in flight never delays a warm isolate');
  assert.equal(team(warm.body).nationalTeamCode, 'PL');
  assert.equal(reads, 2);
  // Still in flight: no second refresh, still the old map.
  assert.equal(team((await call('calendar?date=2026-09-01')).body).nationalTeamCode, 'PL');
  assert.equal(reads, 2);

  // A cold isolate whose first load stalls serves undecorated after ~1 s.
  const cold = await api({
    futbeat_read_national_teams: () => new Promise(() => {}),
    futbeat_read_calendar_range: () => ({ data: calendar(), error: null }),
  });
  started = performance.now();
  const answer = await cold.call('calendar?date=2026-09-01');
  const waited = performance.now() - started;
  assert.equal(answer.status, 200);
  assert.ok(waited >= 900 && waited < 3000, `waited ${waited} ms`);
  assert.deepEqual(answer.body, calendar());
});
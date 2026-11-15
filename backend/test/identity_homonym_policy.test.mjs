import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// BE-244: a name is never an identity. Tirol / Tirol U20 (GOAL 857201), Platense of
// Argentina and of Honduras, Alianza / Alianza FC: the provider id decides or nothing does.

const start = new Date(Date.now() - 3600000).toISOString();
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const insert = (db, id, kind, payload) => db.query('insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const mapId = (db, kind, ext, id) => db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api',$1,$2,$3)", [kind, ext, id]);
const teamMap = (db, ext) => db.query("select canonical_id c from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=$1", [ext]).then((r) => r.rows[0]?.c);
const matchMap = (db, ext) => db.query("select canonical_id c from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id=$1", [ext]).then((r) => r.rows[0]?.c);
const fixture = (ext, home, away, league = 'lg') => ({ apiId: ext, kickoffUtc: start, matchStatus: 'LIVE', leagueId: league,
  homeTeam: home, awayTeam: away });
const link = (db, f) => db.query('select public.futbeat_link_goal_live_matches($1) v', [JSON.stringify([f])]).then((r) => r.rows[0].v);
const stored = (db, id, home, away) => insert(db, id, 'match', { homeTeamId: home, awayTeamId: away, competitionId: 'fb_c1', startTime: start, status: 'SCHEDULED', events: [], statistics: [], provenance: { source: 'GOAL API' } });

test('Tirol is not linked to a Tirol U20 match of the same rival and hour', () => withDb(async (db) => {
  await insert(db, 'fb_c1', 'competition', { name: 'Copa' });
  await insert(db, 'fb_u20', 'team', { name: 'Tirol U20' });
  await insert(db, 'fb_riv', 'team', { name: 'Rival' });
  await stored(db, 'fb_m', 'fb_u20', 'fb_riv');
  await mapId(db, 'competition', 'lg', 'fb_c1');
  await link(db, fixture('857201', { id: 'tirol', name: 'Tirol' }, { id: 'rv', name: 'Rival' }));
  assert.equal(await matchMap(db, '857201'), undefined);
  assert.equal(await teamMap(db, 'tirol'), undefined);
  assert.equal(await teamMap(db, 'rv'), undefined);
}));

test('a match found by name never moves a team id already mapped elsewhere', () => withDb(async (db) => {
  await insert(db, 'fb_c1', 'competition', { name: 'Liga' });
  await insert(db, 'fb_pla_ar', 'team', { name: 'Platense' });
  await insert(db, 'fb_pla_hn', 'team', { name: 'Platense' });
  await insert(db, 'fb_riv', 'team', { name: 'Rival' });
  await stored(db, 'fb_m', 'fb_pla_hn', 'fb_riv');
  await mapId(db, 'team', 'x_ar', 'fb_pla_ar');
  await link(db, fixture('g1', { id: 'x_ar', name: 'Platense' }, { id: 'rv', name: 'Rival' }));
  assert.equal(await teamMap(db, 'x_ar'), 'fb_pla_ar');
}));

test('an empty match of a homonym holds instead of reading the other club', () => withDb(async (db) => {
  await insert(db, 'fb_c1', 'competition', { name: 'Liga' });
  await mapId(db, 'competition', 'lg', 'fb_c1');
  await insert(db, 'fb_pla', 'team', { name: 'Platense' });
  await insert(db, 'fb_lan', 'team', { name: 'Lanús' });
  await insert(db, 'fb_mot', 'team', { name: 'Motagua' });
  await mapId(db, 'team', 'x_ar', 'fb_pla');
  await mapId(db, 'team', 'x_hn', 'fb_pla');
  await mapId(db, 'team', 'x_la', 'fb_lan');
  await stored(db, 'fb_real', 'fb_pla', 'fb_mot');
  await insert(db, 'fb_empty', 'match', { name: '', country: '', shortName: '' });
  await mapId(db, 'match', 'g1', 'fb_empty');
  await link(db, fixture('g1', { id: 'x_ar', name: 'Platense' }, { id: 'x_la', name: 'Lanús' }));
  const p = (await db.query("select payload p from futbeat_private.entities where id='fb_empty'")).rows[0].p;
  assert.equal(p.homeTeamId, undefined);
}));

test('names alone cannot fill an empty match', () => withDb(async (db) => {
  await insert(db, 'fb_c1', 'competition', { name: 'Liga' });
  await mapId(db, 'competition', 'lg', 'fb_c1');
  await insert(db, 'fb_a', 'team', { name: 'Alianza' });
  await insert(db, 'fb_b', 'team', { name: 'Marathón' });
  await insert(db, 'fb_empty', 'match', { name: '', country: '', shortName: '' });
  await mapId(db, 'match', 'g1', 'fb_empty');
  await link(db, fixture('g1', { id: 'nx', name: 'Marathón' }, { id: 'ny', name: 'Alianza' }));
  const p = (await db.query("select payload p from futbeat_private.entities where id='fb_empty'")).rows[0].p;
  assert.equal(p.homeTeamId, undefined);
}));

test('no link path creates a redirect', () => withDb(async (db) => {
  await insert(db, 'fb_c1', 'competition', { name: 'Liga' });
  await insert(db, 'fb_pla', 'team', { name: 'Platense' });
  await insert(db, 'fb_riv', 'team', { name: 'Rival' });
  await stored(db, 'fb_m', 'fb_pla', 'fb_riv');
  await link(db, fixture('g1', { id: 'x', name: 'Platense' }, { id: 'y', name: 'Rival' }));
  assert.equal((await db.query('select count(*)::int n from futbeat_private.entity_redirects')).rows[0].n, 0);
}));

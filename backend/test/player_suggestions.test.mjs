import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// 20261005050000: player suggestions from stored squads only (no provider
// call): followed teams first, then the country's clubs, then globally
// relevant clubs; <= 30, deduplicated by canonical id, never invented.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const photo = (n) => ({ url: `https://media.goal-api.com/players/p${n}.png`, source: 'Test CDN', verificationStatus: 'VERIFIED' });
async function competition(db, { country = null, global = false, score = 500 } = {}) {
  const id = `fb_competition_ps${++seq}`;
  await put(db, id, 'competition', { name: `Liga ${seq}` });
  await db.query(`insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source,country_code,is_global_relevant)
    values($1,'domestic_league',$2,'editorial',$3,$4)
    on conflict(competition_id) do update set relevance_score=excluded.relevance_score,
      country_code=excluded.country_code,is_global_relevant=excluded.is_global_relevant`, [id, score, country, global]);
  return id;
}
async function team(db, competitionId, players, { photos = 0 } = {}) {
  const id = `fb_team_ps${++seq}`;
  await put(db, id, 'team', { name: `Club ${seq}`, competitionId });
  const ids = [];
  for (let i = 0; i < players; i++) {
    const pid = `fb_player_ps${++seq}`;
    await put(db, pid, 'player', { name: `Jugador ${seq}`, ...(i < photos ? { media: photo(seq) } : {}) });
    await db.query("insert into futbeat_private.team_squad_members(team_id,player_id,provider) values($1,$2,'goal_api')", [id, pid]);
    ids.push(pid);
  }
  return { id, players: ids };
}
const suggest = (db, teams = [], country = null) => db.query(
  'select public.futbeat_read_player_suggestions($1::text[],$2) v', [teams, country],
).then((r) => r.rows[0].v);

test('followed teams first (their squad, <= 10 each), then country clubs, then global clubs', () => withDb(async (db) => {
  const local = await competition(db, { country: 'CR' });
  const world = await competition(db, { global: true, score: 900 });
  const mine = await team(db, local, 12, { photos: 2 });
  const crClub = await team(db, local, 4);
  const big = await team(db, world, 4);
  const out = await suggest(db, [mine.id], 'CR');
  const ids = out.map((p) => p.id);
  assert.equal(new Set(ids).size, ids.length, 'no duplicates');
  assert.ok(out.length <= 30);
  const first = out.slice(0, 10);
  assert.ok(first.every((p) => mine.players.includes(p.id) && p.teamId === mine.id), 'tier 1 = followed squad, teamId = that team');
  assert.ok(first.slice(0, 2).every((p) => p.media), 'verified photos first inside a tier');
  const crIndex = ids.findIndex((id) => crClub.players.includes(id));
  const bigIndex = ids.findIndex((id) => big.players.includes(id));
  assert.ok(crIndex > 9 && bigIndex > crIndex, 'country clubs before global clubs');
}));

test('without follows or country: real players of globally relevant clubs only', () => withDb(async (db) => {
  const world = await competition(db, { global: true });
  const other = await competition(db, {});
  const big = await team(db, world, 3);
  await team(db, other, 3);
  const out = await suggest(db);
  assert.deepEqual(out.map((p) => p.id).sort(), big.players.slice(0, 2).sort(), '2 per global club, nothing else');
}));

test('no squads stored -> [] (never invented)', () => withDb(async (db) => {
  await competition(db, { global: true, country: 'CR' });
  assert.deepEqual(await suggest(db, ['fb_team_unknown'], 'CR'), []);
}));

test('a player in two followed squads is listed once; malformed team ids are ignored', () => withDb(async (db) => {
  const local = await competition(db, { country: 'CR' });
  const a = await team(db, local, 2);
  const b = await team(db, local, 0);
  await db.query("insert into futbeat_private.team_squad_members(team_id,player_id,provider) values($1,$2,'goal_api')", [b.id, a.players[0]]);
  const out = await suggest(db, [a.id, b.id, "x'); drop table x;--"], null);
  assert.equal(out.filter((p) => p.id === a.players[0]).length, 1);
  assert.equal(out.length, 2);
}));

test('at most 30 players', () => withDb(async (db) => {
  const local = await competition(db, { country: 'CR' });
  const teams = [];
  for (let i = 0; i < 4; i++) teams.push((await team(db, local, 10)).id);
  assert.equal((await suggest(db, teams, 'CR')).length, 30);
}));

test('API: /v1/player-suggestions validates ids and country, and only service_role can run the RPC', async () => {
  const { readFile } = await import('node:fs/promises');
  const src = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  assert.match(src, /\/futbeat-api\/v1\/player-suggestions/);
  assert.match(src, /futbeat_read_player_suggestions/);
  assert.match(src, /\^fb_team_\[A-Za-z0-9_\]\{1,64\}\$/);
  assert.match(src, /\.slice\(0, 20\)/);
  await withDb(async (db) => {
    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_player_suggestions(text[],text)','execute') ok", [role])).rows[0].ok, false);
    }
  });
});

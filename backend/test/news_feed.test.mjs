import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// 20261005060000: Noticias feed from stored articles only. Followed subjects
// first, then the country, then the rest; one copy per title; images only
// when https; nothing invented when the store is empty.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
async function team(db, country = null) {
  const comp = `fb_competition_nf${++seq}`;
  await put(db, comp, 'competition', { name: `Liga ${seq}` });
  if (country) {
    await db.query(`insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source,country_code)
      values($1,'domestic_league',500,'editorial',$2) on conflict(competition_id) do update set country_code=excluded.country_code`, [comp, country]);
  }
  const id = `fb_team_nf${++seq}`;
  await put(db, id, 'team', { name: `Club ${seq}`, competitionId: comp });
  return id;
}
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString();
async function store(db, subject, articles) {
  return (await db.query('select public.futbeat_store_news_batch($1,$2,now(),$3,$4) v',
    ['team', subject, 'query', JSON.stringify(articles)])).rows[0].v;
}
const article = (id, title, h, extra = {}) => ({ id, title, url: `https://news.test/${id}`, sourceName: 'Fuente', publishedAt: hoursAgo(h), ...extra });
const feed = (db, subjects = [], country = null) => db.query('select public.futbeat_read_news_feed($1::text[],$2) v', [subjects, country]).then((r) => r.rows[0].v);

test('followed subjects first, then the country, then the rest; newest first inside each tier', () => withDb(async (db) => {
  const mine = await team(db);
  const local = await team(db, 'CR');
  const other = await team(db, 'ES');
  await store(db, other, [article('o1', 'Otro reciente', 1)]);
  await store(db, local, [article('l1', 'Local', 2)]);
  await store(db, mine, [article('m1', 'Mío viejo', 30), article('m2', 'Mío nuevo', 5)]);
  const out = await feed(db, [`team:${mine}`], 'CR');
  assert.deepEqual(out.news.map((a) => a.title), ['Mío nuevo', 'Mío viejo', 'Local', 'Otro reciente']);
  assert.equal(out.news[0].followed, true);
  assert.deepEqual(out.news[0].subjects, [{ type: 'team', id: mine }]);
  assert.equal(out.schemaVersion, 1);
  assert.equal(out.demo, false);
}));

test('the same title from several sources is listed once; old articles are left out', () => withDb(async (db) => {
  const a = await team(db);
  await store(db, a, [
    article('d1', 'Gran Fichaje', 3),
    article('d2', 'gran  fichaje', 1, { sourceName: 'Otra' }),
    article('old', 'Viejo', 24 * 20),
  ]);
  const out = await feed(db);
  assert.equal(out.news.length, 1);
  assert.equal(out.news[0].id, 'newsdata:d2', 'the newest copy');
}));

test('images: https kept, anything else dropped; an image is never required', () => withDb(async (db) => {
  const a = await team(db);
  await store(db, a, [
    article('i1', 'Con imagen', 1, { imageUrl: 'https://img.test/a.jpg' }),
    article('i2', 'Imagen insegura', 2, { imageUrl: 'http://img.test/b.jpg' }),
    article('i3', 'Sin imagen', 3),
  ]);
  const out = await feed(db);
  const byTitle = Object.fromEntries(out.news.map((n) => [n.title, n]));
  assert.equal(byTitle['Con imagen'].imageUrl, 'https://img.test/a.jpg');
  assert.equal(byTitle['Imagen insegura'].imageUrl, undefined);
  assert.equal(byTitle['Sin imagen'].imageUrl, undefined);
}));

test('empty store -> empty lists (never invented)', () => withDb(async (db) => {
  const out = await feed(db, ['team:fb_team_x'], 'CR');
  assert.deepEqual(out.news, []);
  assert.deepEqual(out.transfers, []);
}));

test('transfers: real roster changes with names, followed teams first', () => withDb(async (db) => {
  const a = await team(db);
  const b = await team(db);
  const c = await team(db);
  for (const [pid, from, to, h] of [['fb_player_nf1', a, b, 1], ['fb_player_nf2', b, c, 2]]) {
    await put(db, pid, 'player', { name: `Jugador ${pid}` });
    await db.query(`insert into futbeat_private.transfer_events(player_id,from_team_id,to_team_id,detected_at,detected_period,provider,status,source_label)
      values($1,$2,$3,now()-($4||' hours')::interval,current_date,'goal_api','ROSTER_CHANGE','GOAL API · plantilla de equipo')`, [pid, from, to, String(h)]);
  }
  const out = await feed(db, [`team:${c}`]);
  assert.deepEqual(out.transfers.map((t) => t.playerId), ['fb_player_nf2', 'fb_player_nf1']);
  assert.equal(out.transfers[0].toTeamName, (await db.query("select payload->>'name' n from futbeat_private.entities where id=$1", [c])).rows[0].n);
}));

test('malformed subject keys are ignored; RPC is service_role only; API route exists', () => withDb(async (db) => {
  const out = await feed(db, ["team:x'); drop table x;--", 'nope'], 'zz');
  assert.deepEqual(out.news, []);
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_news_feed(text[],text)','execute') ok", [role])).rows[0].ok, false);
  }
  const src = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  assert.match(src, /\/futbeat-api\/v1\/news'/);
  assert.match(src, /futbeat_read_news_feed/);
}));

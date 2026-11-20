import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// BE11-A3: team/competition media must never be erased, emptied (`{}`) or
// stripped of its provenance by a writer. Real SQL (PGlite, all migrations)
// through the production calendar stores and a direct update (any writer).

const url = (name) => `https://media.goal-api.com/badges/${name}.png`;
const full = (name, receivedAt = '2026-11-01T00:00:00Z') => ({
  url: url(name), kind: 'TEAM_LOGO', source: 'GOAL API', receivedAt,
  verificationStatus: 'VERIFIED', rightsStatus: 'REVIEW_REQUIRED', usageScope: 'DEVELOPMENT_ONLY',
});
const lossy = (name) => ({ url: url(name), verificationStatus: 'VERIFIED' });
const team = (id, media) => ({ id, name: id, shortName: '', competitionId: 'fb_comp_a3',
  ...(media === undefined ? {} : { media }) });
const snapshot = (teams, competitions = []) => ({ schemaVersion: 1, demo: false, competitions, teams, matches: [] });

async function scene(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const put = (db, id, payload, kind = 'team') => db.query(
  'insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
const media = async (db, id) => (await db.query(
  "select payload->'media' m, payload ? 'media' k from futbeat_private.entities where id=$1", [id])).rows[0];
const storeEntities = async (db, snap) => (await db.query(
  "select public.futbeat_store_calendar_entities('goal_api',$1) v", [JSON.stringify(snap)])).rows[0].v;
const storeRange = async (db, snap) => (await db.query(
  "select public.futbeat_store_calendar_range('goal_api',now(),'[]'::jsonb,$1) v", [JSON.stringify(snap)])).rows[0].v;

test('a writer without media (null, {} or no key) never erases a stored image', async () => {
  await scene(async (db) => {
    for (const [id, next] of [['fb_team_null', null], ['fb_team_empty', {}], ['fb_team_absent', undefined], ['fb_team_nourl', { verificationStatus: 'VERIFIED' }]]) {
      await put(db, id, team(id, full(id)));
      await storeEntities(db, snapshot([team(id, next)]));
      assert.deepEqual((await media(db, id)).m, full(id), id);
    }
  });
});

test('compact (lossy) or receivedAt-only media keeps the complete stored one and writes nothing', async () => {
  await scene(async (db) => {
    await put(db, 'fb_team_keep', team('fb_team_keep', full('fb_team_keep')));
    const lossyRun = await storeEntities(db, snapshot([team('fb_team_keep', lossy('fb_team_keep'))]));
    assert.equal(lossyRun.teams, 0);
    const fresh = await storeRange(db, snapshot([team('fb_team_keep', full('fb_team_keep', '2026-11-07T18:00:00Z'))]));
    assert.equal(fresh.teams, 1); // count of the batch, not of writes
    assert.deepEqual((await media(db, 'fb_team_keep')).m, full('fb_team_keep'));
    const xmin = async () => (await db.query("select xmin::text x from futbeat_private.entities where id='fb_team_keep'")).rows[0].x;
    const before = await xmin();
    await storeRange(db, snapshot([team('fb_team_keep', full('fb_team_keep', '2026-11-08T00:00:00Z'))]));
    await storeEntities(db, snapshot([team('fb_team_keep', lossy('fb_team_keep'))]));
    assert.equal(await xmin(), before, 'receivedAt-only / lossy media: the row is not rewritten');
  });
});

test('fresh complete media replaces {}, null, lossy and a different url', async () => {
  await scene(async (db) => {
    await put(db, 'fb_team_empty', team('fb_team_empty', {}));
    await put(db, 'fb_team_jnull', team('fb_team_jnull', null));
    await put(db, 'fb_team_lossy', team('fb_team_lossy', lossy('fb_team_lossy')));
    await put(db, 'fb_team_moved', team('fb_team_moved', full('fb_team_old')));
    await storeRange(db, snapshot(['fb_team_empty', 'fb_team_jnull', 'fb_team_lossy', 'fb_team_moved'].map((id) => team(id, full(id, '2026-11-07T18:00:00Z')))));
    for (const id of ['fb_team_empty', 'fb_team_jnull', 'fb_team_lossy', 'fb_team_moved']) {
      assert.deepEqual((await media(db, id)).m, full(id, '2026-11-07T18:00:00Z'), id);
    }
  });
});

test('unusable media is never stored: {} / null become no media key (insert and update)', async () => {
  await scene(async (db) => {
    await storeEntities(db, snapshot([team('fb_team_new_empty', {}), team('fb_team_new_null', null)],
      [{ id: 'fb_comp_a3', name: 'A3 Cup', country: 'X', season: '', media: {} }]));
    for (const id of ['fb_team_new_empty', 'fb_team_new_null', 'fb_comp_a3']) {
      assert.equal((await media(db, id)).k, false, id);
    }
    await db.query(`update futbeat_private.entities set payload=payload||'{"media":{}}' where id='fb_team_new_null'`);
    assert.equal((await media(db, 'fb_team_new_null')).k, false);
  });
});

test('any writer (direct update) keeps a competition logo; players are untouched by this rule', async () => {
  await scene(async (db) => {
    const logo = { ...full('comp'), kind: 'COMPETITION_LOGO' };
    await put(db, 'fb_comp_keep', { id: 'fb_comp_keep', name: 'Keep', country: 'X', media: logo }, 'competition');
    await db.query(`update futbeat_private.entities set payload=payload||'{"media":null}' where id='fb_comp_keep'`);
    assert.deepEqual((await media(db, 'fb_comp_keep')).m, logo);
  });
});

test('entity_payload_media rule table', async () => {
  await scene(async (db) => {
    const f = async (o, n) => (await db.query('select futbeat_private.entity_payload_media($1,$2) v',
      [o && JSON.stringify(o), JSON.stringify(n)])).rows[0].v;
    assert.deepEqual(await f(null, { id: 'x', media: {} }), { id: 'x' });
    assert.deepEqual(await f(null, { id: 'x', media: lossy('a') }), { id: 'x', media: lossy('a') });
    assert.deepEqual(await f({ media: lossy('a') }, { id: 'x', media: lossy('b') }), { id: 'x', media: lossy('b') });
    assert.deepEqual(await f({ media: lossy('a') }, { id: 'x', media: null }), { id: 'x', media: lossy('a') });
    // Complete stored + complete new of the same url but different rights: new wins.
    const approved = { ...full('a'), rightsStatus: 'APPROVED' };
    assert.deepEqual(await f({ media: full('a') }, { id: 'x', media: approved }), { id: 'x', media: approved });
    assert.deepEqual(await f({ media: { url: 'http://insecure/a.png' } }, { id: 'x' }), { id: 'x' });
  });
});

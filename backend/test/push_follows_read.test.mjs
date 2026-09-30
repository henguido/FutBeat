import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// The mobile first-login merge reads the caller's server follows through
// public.futbeat_read_user_profile() before its first full-replace push.
// These checks pin the read side: auth.uid() scoping, authenticated-only.

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';

const follows = (value) => value.follows.map((f) => `${f.type}:${f.id}`).sort();

async function setup() {
  const db = await openDatabase();
  await db.exec(`create schema if not exists auth;
    create or replace function auth.uid() returns uuid language sql as
    $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;`);
  for (const id of ['fb_team_a', 'fb_team_b', 'fb_team_c']) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id })]);
  }
  const as = async (user, sql, params = []) => {
    await db.query("select set_config('request.jwt.claim.sub',$1,false)", [user ?? '']);
    await db.exec('set role authenticated');
    try {
      return (await db.query(sql, params)).rows;
    } finally {
      await db.exec('reset role');
    }
  };
  const sync = (user, ids) => as(user, 'select public.futbeat_sync_push_follows($1::jsonb)', [
    JSON.stringify(ids.map((id) => ({ type: 'team', id }))),
  ]);
  const read = async (user) => (await as(user, 'select public.futbeat_read_user_profile() as value'))[0].value;
  return { db, as, sync, read };
}

test('read_user_profile returns only the caller follows', async () => {
  const { db, sync, read } = await setup();
  try {
    await sync(userA, ['fb_team_a', 'fb_team_b']);
    await sync(userB, ['fb_team_c']);
    assert.deepEqual(follows(await read(userA)), ['team:fb_team_a', 'team:fb_team_b']);
    assert.deepEqual(follows(await read(userB)), ['team:fb_team_c']);
    const other = '33333333-3333-4333-8333-333333333333';
    assert.deepEqual(follows(await read(other)), []);
  } finally { await db.close(); }
});

test('read_user_profile requires an authenticated caller', async () => {
  const { db, as } = await setup();
  try {
    await assert.rejects(as(null, 'select public.futbeat_read_user_profile()'), /Authentication required/);
    await db.query("select set_config('request.jwt.claim.sub',$1,false)", [userA]);
    await db.exec('set role anon');
    await assert.rejects(db.query('select public.futbeat_read_user_profile()'), /permission denied/);
    await assert.rejects(db.query('select * from futbeat_private.push_follows'), /permission denied/);
    await db.exec('reset role');
  } finally { await db.close(); }
});

test('sync is a full replace, so the client must merge before its first push', async () => {
  const { db, sync, read } = await setup();
  try {
    await sync(userA, ['fb_team_a', 'fb_team_b']);
    // Union of server {a,b} and local {b,c}, as the app pushes on first link.
    await sync(userA, ['fb_team_a', 'fb_team_b', 'fb_team_c']);
    assert.deepEqual(follows(await read(userA)), ['team:fb_team_a', 'team:fb_team_b', 'team:fb_team_c']);
    // An unmerged empty push would wipe the server copy; the app gates it.
    await sync(userA, []);
    assert.deepEqual(follows(await read(userA)), []);
  } finally { await db.close(); }
});

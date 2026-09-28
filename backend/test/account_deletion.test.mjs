import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';

function jwt(subject) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'HS256' })}.${encode({ sub: subject })}.test-signature`;
}

async function edgeHarness({ activeUser = userA, existingUsers = new Set([userA]) } = {}) {
  let handler;
  const calls = [];
  const secret = 'server-only-test-secret';
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    calls.push({ url: url.href, method: init.method ?? 'GET', headers: init.headers });
    if (url.pathname === '/auth/v1/user') {
      return activeUser == null
        ? Response.json({ message: 'not found' }, { status: 401 })
        : Response.json({ id: activeUser });
    }
    const id = url.pathname.split('/').at(-1);
    if (init.method === 'DELETE') {
      if (!existingUsers.has(id)) return Response.json({}, { status: 404 });
      existingUsers.delete(id);
      return Response.json({});
    }
    return existingUsers.has(id)
      ? Response.json({ id })
      : Response.json({}, { status: 404 });
  };
  const source = (await read('supabase/functions/futbeat-delete-account/index.ts'))
    .replace(/^import .*;\r?\n/gm, '');
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, JSON, atob, fetch,
    Deno: {
      env: { get: (name) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: secret })[name] },
      serve: (value) => { handler = value; },
    },
  });
  vm.runInContext(stripTypeScriptTypes(source), context);
  return { handler, calls, secret, existingUsers };
}

test('delete account requires a verified caller and can only delete its JWT subject', async () => {
  const harness = await edgeHarness({ activeUser: userB, existingUsers: new Set([userA, userB]) });
  const response = await harness.handler(new Request('https://edge.test', {
    method: 'POST', headers: { authorization: `Bearer ${jwt(userA)}` },
  }));
  assert.equal(response.status, 403);
  assert.deepEqual([...harness.existingUsers].sort(), [userA, userB].sort());
  assert.equal(harness.calls.some((call) => call.method === 'DELETE'), false);
});

test('delete account removes the authenticated user and treats a retry as success', async () => {
  const existingUsers = new Set([userA]);
  const first = await edgeHarness({ activeUser: userA, existingUsers });
  const request = () => new Request('https://edge.test', {
    method: 'POST', headers: { authorization: `Bearer ${jwt(userA)}` },
  });
  const response = await first.handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deleted: true });
  assert.equal(existingUsers.has(userA), false);
  assert.equal(JSON.stringify(first.calls).includes(first.secret), true, 'admin key is used only server-side');

  const retry = await edgeHarness({ activeUser: null, existingUsers });
  const retryResponse = await retry.handler(request());
  assert.equal(retryResponse.status, 200);
  const retryBody = await retryResponse.text();
  assert.deepEqual(JSON.parse(retryBody), { deleted: true, alreadyDeleted: true });
  assert.equal(retryBody.includes(retry.secret), false);
});

test('auth user deletion cascades private data and preserves shared sports data', async () => {
  const db = new PGlite();
  await db.exec(`
    create schema auth; create schema futbeat_private;
    create table auth.users(id uuid primary key);
    create table futbeat_private.entities(id text primary key);
    create table futbeat_private.push_devices(id uuid primary key, user_id uuid not null);
    create table futbeat_private.push_follows(user_id uuid not null, entity_id text references futbeat_private.entities(id));
    create table futbeat_private.user_preferences(user_id uuid primary key);
    create table futbeat_private.temporary_interests(user_id uuid not null, entity_id text references futbeat_private.entities(id));
    create table futbeat_private.notification_outbox(id uuid primary key, device_id uuid not null references futbeat_private.push_devices(id), user_id uuid not null);
    create table futbeat_private.coverage_interests(entity_id text primary key, explicit_followers int not null);
    create function futbeat_private.refresh_interest_aggregates() returns void
    language sql as $$
      delete from futbeat_private.coverage_interests;
      insert into futbeat_private.coverage_interests
      select entity_id,count(*)::int from futbeat_private.push_follows group by entity_id;
    $$;
  `);
  const orphan = '33333333-3333-4333-8333-333333333333';
  await db.exec("insert into futbeat_private.entities values ('fb_team_orphan')");
  await db.query("insert into futbeat_private.push_follows values ($1,'fb_team_orphan')", [orphan]);
  await db.exec('select futbeat_private.refresh_interest_aggregates()');
  assert.equal((await db.query('select count(*)::int count from futbeat_private.coverage_interests')).rows[0].count, 1);
  await db.exec(await read('supabase/migrations/20260927174752_account_deletion_cascade.sql'));
  assert.equal((await db.query('select count(*)::int count from futbeat_private.coverage_interests')).rows[0].count, 0);
  await db.query('insert into auth.users values ($1),($2)', [userA, userB]);
  await db.exec("insert into futbeat_private.entities values ('fb_team_shared')");
  const device = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const outbox = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  await db.query('insert into futbeat_private.push_devices values ($1,$2)', [device, userA]);
  await db.query("insert into futbeat_private.push_follows values ($1,'fb_team_shared')", [userA]);
  await db.exec('select futbeat_private.refresh_interest_aggregates()');
  await db.query('insert into futbeat_private.user_preferences values ($1)', [userA]);
  await db.query("insert into futbeat_private.temporary_interests values ($1,'fb_team_shared')", [userA]);
  await db.query('insert into futbeat_private.notification_outbox values ($1,$2,$3)', [outbox, device, userA]);

  await db.query('delete from auth.users where id=$1', [userA]);
  for (const table of ['push_devices', 'push_follows', 'user_preferences', 'temporary_interests', 'notification_outbox']) {
    assert.equal((await db.query(`select count(*)::int count from futbeat_private.${table}`)).rows[0].count, 0, table);
  }
  assert.equal((await db.query('select count(*)::int count from futbeat_private.entities')).rows[0].count, 2);
  assert.equal((await db.query('select count(*)::int count from futbeat_private.coverage_interests')).rows[0].count, 0);
  assert.equal((await db.query('select count(*)::int count from auth.users')).rows[0].count, 1);
  await db.close();
});

test('account deletion stays server-only and JWT verification remains enabled', async () => {
  const [mobile, config, edge] = await Promise.all([
    read('apps/mobile/lib/core/push.dart'), read('supabase/config.toml'),
    read('supabase/functions/futbeat-delete-account/index.ts'),
  ]);
  assert.doesNotMatch(mobile, /SERVICE_ROLE|SECRET_KEYS|admin\/users/);
  assert.match(config, /\[functions\.futbeat-delete-account\]\s*\r?\nverify_jwt = true/);
  assert.match(edge, /auth\/v1\/admin\/users\/\$\{subject\}/);
  assert.doesNotMatch(edge, /console\.(?:log|error|warn)/);
});

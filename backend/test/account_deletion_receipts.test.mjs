import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { PGlite } from '@electric-sql/pglite';

// R05: durable account-deletion receipts. Real migration SQL (PGlite) behind
// the real futbeat-delete-account source; Auth and PostgREST are simulated
// over the same database. No real account is ever touched.

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const idA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const idB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

const jwt = (subject, signature = 'sig') => {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'ES256' })}.${encode({ sub: subject, role: 'authenticated' })}.${signature}`;
};

const open = [];
test.afterEach(async () => { while (open.length) await open.pop().close(); });

async function database() {
  const db = new PGlite();
  open.push(db);
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema futbeat_private;
    create table auth.users (id uuid primary key);
    create table futbeat_private.push_follows (user_id uuid references auth.users(id) on delete cascade, entity_id text);
  `);
  await db.exec(await read('supabase/migrations/20261106120000_account_deletion_receipts.sql'));
  return db;
}

async function harness(db, { failRpc = new Set(), deleteStatus = null } = {}) {
  let handler;
  const calls = [];
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const headers = new Headers(init.headers);
    calls.push({ path: url.pathname, method: init.method ?? 'GET' });
    if (url.pathname.startsWith('/rest/v1/rpc/')) {
      const fn = url.pathname.split('/').at(-1);
      if (failRpc.has(fn)) return Response.json({ message: 'down' }, { status: 503 });
      const args = JSON.parse(init.body);
      const r = await db.query(`select public.${fn}($1::uuid, $2::uuid) v`, [args.p_deletion_id, args.p_subject]);
      return Response.json(r.rows[0].v);
    }
    const bearer = headers.get('authorization')?.replace('Bearer ', '') ?? '';
    const exists = async (id) => (await db.query('select 1 from auth.users where id=$1', [id])).rows.length > 0;
    if (url.pathname === '/auth/v1/user') {
      // Auth rejects a token it did not sign (simulated by the signature).
      if (bearer.split('.')[2] === 'forged') return Response.json({}, { status: 401 });
      const sub = JSON.parse(Buffer.from(bearer.split('.')[1], 'base64url')).sub;
      return (await exists(sub)) ? Response.json({ id: sub }) : Response.json({}, { status: 401 });
    }
    const id = url.pathname.split('/').at(-1);
    if (init.method === 'DELETE') {
      if (deleteStatus) return Response.json({}, { status: deleteStatus });
      if (!(await exists(id))) return Response.json({}, { status: 404 });
      await db.query('delete from auth.users where id=$1', [id]);
      return Response.json({});
    }
    return (await exists(id)) ? Response.json({ id }) : Response.json({}, { status: 404 });
  };
  const source = (await read('supabase/functions/futbeat-delete-account/index.ts')).replace(/^import .*;\r?\n/gm, '');
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, JSON, atob, fetch,
    Deno: {
      env: { get: (name) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'server-secret' })[name] },
      serve: (value) => { handler = value; },
    },
  });
  vm.runInContext(stripTypeScriptTypes(source), context);
  const post = async (subject, deletionId, signature) => {
    const headers = { authorization: `Bearer ${jwt(subject, signature)}` };
    if (deletionId !== undefined) headers['x-futbeat-deletion-id'] = deletionId;
    const r = await handler(new Request('https://edge.test', { method: 'POST', headers }));
    return { status: r.status, body: await r.json() };
  };
  return { post, calls };
}

const status = async (db, id) => (await db.query('select public.futbeat_account_deletion_status($1::uuid) v', [id])).rows[0].v;
const users = async (db) => (await db.query('select id from auth.users order by id')).rows.map((r) => r.id);
const receipts = async (db) => (await db.query('select * from futbeat_private.account_deletion_receipts')).rows;

test('with a deletion id: receipt first, delete, receipt deleted and queryable without a session', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1),($2)', [userA, userB]);
  await db.query("insert into futbeat_private.push_follows values ($1,'team:x')", [userA]);
  const { post } = await harness(db);
  assert.deepEqual(await status(db, idA), { status: 'unknown' });
  const r = await post(userA, idA);
  assert.deepEqual([r.status, r.body.deleted, r.body.deletionId], [200, true, idA]);
  assert.deepEqual(await users(db), [userB]);
  assert.equal((await db.query('select count(*)::int c from futbeat_private.push_follows')).rows[0].c, 0, 'cascade');
  const s = await status(db, idA);
  assert.equal(s.status, 'deleted');
  assert.ok(s.completedAt);
  const [row] = await receipts(db);
  assert.equal(row.subject, null, 'uid erased once deleted');
  assert.ok(!JSON.stringify(row).includes(idA) && !JSON.stringify(row).includes(userA), 'only hashes stored');
});

test('lost ACK: finish fails after the delete; the status still reads deleted', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post } = await harness(db, { failRpc: new Set(['futbeat_account_deletion_finish']) });
  assert.equal((await post(userA, idA)).status, 200);
  assert.equal((await receipts(db))[0].status, 'pending');
  assert.equal((await status(db, idA)).status, 'deleted', 'status completes a pending receipt whose account is gone');
  assert.equal((await receipts(db))[0].subject, null);
});

test('receipt unavailable: nothing is deleted (503, retry is safe)', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db, { failRpc: new Set(['futbeat_account_deletion_begin']) });
  const r = await post(userA, idA);
  assert.deepEqual([r.status, r.body.code], [503, 'RECEIPT_UNAVAILABLE']);
  assert.deepEqual(await users(db), [userA]);
  assert.ok(!calls.some((c) => c.method === 'DELETE'));
});

test('retries are idempotent: the same id after success never deletes again', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db);
  await post(userA, idA);
  const again = await post(userA, idA);
  assert.deepEqual([again.status, again.body.alreadyDeleted], [200, true]);
  assert.equal(calls.filter((c) => c.method === 'DELETE').length, 1);
});

test('concurrent requests with the same id: one deletion, both confirmed', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db);
  const results = await Promise.all([post(userA, idA), post(userA, idA)]);
  assert.deepEqual(results.map((r) => [r.status, r.body.deleted]), [[200, true], [200, true]]);
  assert.ok(calls.filter((c) => c.method === 'DELETE').length >= 1);
  assert.equal((await receipts(db)).length, 1);
  assert.equal((await status(db, idA)).status, 'deleted');
});

test('an id bound to another subject is a conflict and deletes nothing', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1),($2)', [userA, userB]);
  const { post } = await harness(db, { deleteStatus: 503 });
  assert.equal((await post(userA, idA)).status, 503, 'A: pending, account kept');
  const { post: post2 } = await harness(db);
  const r = await post2(userB, idA);
  assert.deepEqual([r.status, r.body.code], [409, 'DELETION_ID_CONFLICT']);
  assert.deepEqual(await users(db), [userA, userB]);
  assert.equal((await status(db, idA)).status, 'pending', 'A still exists: not deleted');
});

test('a failed delete leaves pending (account exists); a later retry with the same id completes', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  assert.equal((await (await harness(db, { deleteStatus: 503 })).post(userA, idA)).status, 503);
  assert.equal((await status(db, idA)).status, 'pending');
  assert.equal((await (await harness(db)).post(userA, idA)).status, 200);
  assert.equal((await status(db, idA)).status, 'deleted');
});

test('without the header: exactly the previous behaviour, no receipt', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db);
  const r = await post(userA);
  assert.deepEqual([r.status, r.body], [200, { deleted: true }]);
  assert.equal((await receipts(db)).length, 0);
  assert.ok(!calls.some((c) => c.path.startsWith('/rest/')));
});

test('invalid ids are rejected before anything happens', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db);
  for (const bad of ['', 'not-a-uuid', '11111111-1111-1111-1111-11111111111']) {
    assert.equal((await post(userA, bad)).status, 400, bad);
  }
  assert.equal(calls.length, 0);
  assert.deepEqual(await users(db), [userA]);
});

test('receipts older than 30 days are purged; grants: status for anon, begin/finish service only', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1),($2)', [userA, userB]);
  await (await harness(db)).post(userA, idA);
  await db.query("update futbeat_private.account_deletion_receipts set created_at = now() - interval '31 days'");
  await (await harness(db, { deleteStatus: 503 })).post(userB, idB);
  assert.equal((await receipts(db)).length, 1, 'the old receipt was purged by the next begin');
  const can = async (role, fn) => (await db.query('select has_function_privilege($1, $2, \'execute\') v', [role, fn])).rows[0].v;
  assert.equal(await can('anon', 'public.futbeat_account_deletion_status(uuid)'), true);
  assert.equal(await can('anon', 'public.futbeat_account_deletion_begin(uuid,uuid)'), false);
  assert.equal(await can('authenticated', 'public.futbeat_account_deletion_finish(uuid,uuid)'), false);
  assert.equal(await can('service_role', 'public.futbeat_account_deletion_begin(uuid,uuid)'), true);
  assert.equal((await db.query("select has_table_privilege('anon','futbeat_private.account_deletion_receipts','select') v")).rows[0].v, false);
});

// BE11-A5: the receipt is written only after Auth accepted the token, so the
// function never stores a live uid from an unverified payload (defence in
// depth if the gateway check were ever off).
test('a token Auth rejects writes no receipt and deletes nothing, even for an existing uid', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post, calls } = await harness(db);
  const r = await post(userA, idA, 'forged');
  assert.equal(r.status, 401);
  assert.deepEqual(await users(db), [userA]);
  assert.equal((await receipts(db)).length, 0, 'no pending receipt with the victim uid');
  assert.ok(!calls.some((c) => c.method === 'DELETE' || c.path.startsWith('/rest/')));
  assert.deepEqual(await status(db, idA), { status: 'unknown' });
});

test('account already gone (deleted without a receipt): a retry with an id is 200 and the id reads deleted', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1)', [userA]);
  const { post } = await harness(db);
  assert.equal((await post(userA)).status, 200, 'legacy delete, no receipt');
  const r = await post(userA, idA);
  assert.deepEqual([r.status, r.body.alreadyDeleted, r.body.deletionId], [200, true, idA]);
  assert.equal((await status(db, idA)).status, 'deleted');
  assert.equal((await receipts(db))[0].subject, null, 'no uid kept for a deleted account');
});

test('account already gone: an id bound to another subject is still a conflict', async () => {
  const db = await database();
  await db.query('insert into auth.users values ($1),($2)', [userA, userB]);
  assert.equal((await (await harness(db, { deleteStatus: 503 })).post(userB, idA)).status, 503, 'B owns idA (pending)');
  const { post } = await harness(db);
  assert.equal((await post(userA)).status, 200, 'A deleted without a receipt');
  const r = await post(userA, idA);
  assert.deepEqual([r.status, r.body.code], [409, 'DELETION_ID_CONFLICT']);
  assert.equal((await status(db, idA)).status, 'pending', 'B still exists');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Guest -> account (20261105110000). A Supabase session is simulated with
// request.jwt.claims (auth.uid() / auth.jwt() as Supabase defines them).
// Linking an identity keeps the user id (nothing to test server-side);
// signing in to an existing account merges through a one-time ticket.

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.exec(`create schema if not exists auth;
      create or replace function auth.jwt() returns jsonb language sql stable as
        $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      create or replace function auth.uid() returns uuid language sql stable as
        $$ select nullif(auth.jwt()->>'sub','')::uuid $$;`);
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_gm1','team','{"id":"fb_team_gm1","name":"Equipo Uno"}'),
      ('fb_team_gm2','team','{"id":"fb_team_gm2","name":"Equipo Dos"}'),
      ('fb_team_gm3','team','{"id":"fb_team_gm3","name":"Equipo Tres"}')`);
    await fn(db);
  } finally { await db.close(); }
}

const as = (db, uid, anonymous) => db.query("select set_config('request.jwt.claims',$1,false)",
  [JSON.stringify({ sub: uid, role: 'authenticated', is_anonymous: anonymous })]);
const v = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;
const follows = async (db, uid) => (await db.query(
  'select entity_id from futbeat_private.push_follows where user_id=$1 order by entity_id', [uid])).rows.map((r) => r.entity_id);
const follow = (db, uid, team) => db.query("insert into futbeat_private.push_follows values($1,'team',$2,now())", [uid, team]);
const issue = (db) => v(db, 'select public.futbeat_issue_guest_merge_ticket() v');
const redeem = (db, ticket) => v(db, 'select public.futbeat_redeem_guest_merge_ticket($1) v', [ticket]);

test('two guests on two phones keep separate follows', () => withDb(async (db) => {
  const a = randomUUID(), b = randomUUID();
  await follow(db, a, 'fb_team_gm1');
  await follow(db, b, 'fb_team_gm2');
  assert.deepEqual(await follows(db, a), ['fb_team_gm1']);
  assert.deepEqual(await follows(db, b), ['fb_team_gm2']);
}));

test('guest signs in to an existing account: union of follows, account preferences win', () => withDb(async (db) => {
  const guest = randomUUID(), account = randomUUID();
  await follow(db, guest, 'fb_team_gm1');
  await follow(db, guest, 'fb_team_gm2');
  await follow(db, account, 'fb_team_gm2');
  await follow(db, account, 'fb_team_gm3');
  await db.query("insert into futbeat_private.user_preferences(user_id,selected_country,notify_goals) values($1,'CR',false)", [guest]);
  await db.query("insert into futbeat_private.user_preferences(user_id,selected_country,detected_country,notify_goals) values($1,null,'ES',true)", [account]);
  await db.query(`insert into futbeat_private.push_devices(id,user_id,installation_id,platform,transport,token,enabled,registered_at)
    values($1,$2,$3,'android','test','guest-token',true,now())`, [randomUUID(), guest, randomUUID()]);

  await as(db, guest, true);
  const { ticket, expiresAt } = await issue(db);
  assert.match(ticket, /^[0-9a-f]{64}$/);
  assert.ok(Date.parse(expiresAt) > Date.now());
  // Only its hash is stored.
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.guest_merge_tickets where ticket_hash=$1', [ticket]), 0);

  await as(db, account, false);
  const result = await redeem(db, ticket);
  assert.deepEqual(result, { merged: true, follows: 1, interests: 0, preferences: 'filled', devicesDisabled: 1 });
  assert.deepEqual(await follows(db, account), ['fb_team_gm1', 'fb_team_gm2', 'fb_team_gm3']);
  const prefs = (await db.query('select selected_country,detected_country,notify_goals from futbeat_private.user_preferences where user_id=$1', [account])).rows[0];
  assert.deepEqual(prefs, { selected_country: 'CR', detected_country: 'ES', notify_goals: true });
  assert.equal(await v(db, 'select enabled v from futbeat_private.push_devices where user_id=$1', [guest]), false);
  // The guest's rows are not deleted.
  assert.deepEqual(await follows(db, guest), ['fb_team_gm1', 'fb_team_gm2']);
  // Single use.
  await assert.rejects(redeem(db, ticket), /Invalid merge ticket/);
}));

test('account without preferences takes the guest row; guest without preferences changes nothing', () => withDb(async (db) => {
  const guest = randomUUID(), account = randomUUID(), other = randomUUID();
  await db.query("insert into futbeat_private.user_preferences(user_id,selected_country,hour_format) values($1,'MX','24h')", [guest]);
  await as(db, guest, true);
  const { ticket } = await issue(db);
  await as(db, account, false);
  assert.equal((await redeem(db, ticket)).preferences, 'copied');
  assert.deepEqual((await db.query('select selected_country,hour_format from futbeat_private.user_preferences where user_id=$1', [account])).rows[0],
    { selected_country: 'MX', hour_format: '24h' });
  await as(db, other, true);
  const second = await issue(db);
  await as(db, account, false);
  assert.equal((await redeem(db, second.ticket)).preferences, 'kept');
}));

test('tickets: guest-only issue, account-only redeem, expiry, never into the same user, at most 3 open', () => withDb(async (db) => {
  const guest = randomUUID(), account = randomUUID();
  await as(db, account, false);
  await assert.rejects(issue(db), /Only a guest session/);
  await as(db, guest, true);
  const { ticket } = await issue(db);
  await assert.rejects(redeem(db, ticket), /Sign in to an account/);
  await issue(db); await issue(db);
  await assert.rejects(issue(db), /Too many open merge tickets/);
  await as(db, account, false);
  await assert.rejects(redeem(db, 'f'.repeat(64)), /Invalid merge ticket/);
  await assert.rejects(redeem(db, 'not-a-ticket'), /Invalid merge ticket/);
  await db.query("update futbeat_private.guest_merge_tickets set created_at=now()-interval '20 minutes',expires_at=now()-interval '10 minutes'");
  await assert.rejects(redeem(db, ticket), /Invalid merge ticket/);
  // A guest session that is no longer anonymous (linked) cannot merge into itself.
  await as(db, guest, true);
  const own = await issue(db);
  await as(db, guest, false);
  await assert.rejects(redeem(db, own.ticket), /Invalid merge ticket/);
  await db.query("select set_config('request.jwt.claims','',false)");
  await assert.rejects(issue(db), /Authentication required/);
}));

test('grants: only signed-in sessions (authenticated) can issue or redeem', () => withDb(async (db) => {
  const acl = (sig) => v(db, `select array_to_string(array(select a.grantee::regrole::text from aclexplode(p.proacl) a
    where a.privilege_type='EXECUTE' order by 1),',') v from pg_proc p where p.oid=$1::regprocedure`, [sig]);
  assert.equal(await acl('public.futbeat_issue_guest_merge_ticket()'), 'authenticated,postgres');
  assert.equal(await acl('public.futbeat_redeem_guest_merge_ticket(text)'), 'authenticated,postgres');
}));

test('rollback removes the merge objects', () => withDb(async (db) => {
  await db.exec(await readFile(new URL('../../supabase/manual/20261105110000_guest_account_merge_rollback.sql', import.meta.url), 'utf8'));
  assert.equal(await v(db, "select to_regprocedure('public.futbeat_issue_guest_merge_ticket()') v"), null);
  assert.equal(await v(db, "select to_regclass('futbeat_private.guest_merge_tickets') v"), null);
}));

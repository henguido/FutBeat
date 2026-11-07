import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

// BE11-A5: deleting an Auth user leaves no uid in the guest-merge tables.
// The two tables mirror production (columns read 2026-11-07); the migration
// under test is the real file.

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const guest = '11111111-1111-4111-8111-111111111111';
const account = '22222222-2222-4222-8222-222222222222';
const other = '33333333-3333-4333-8333-333333333333';

const open = [];
test.afterEach(async () => { while (open.length) await open.pop().close(); });

async function database({ guestTables = true } = {}) {
  const db = new PGlite();
  open.push(db);
  await db.exec(`
    create schema auth; create schema futbeat_private;
    create table auth.users (id uuid primary key);
  `);
  if (guestTables) await db.exec(`
    create table futbeat_private.guest_merge_tickets (
      ticket_hash text primary key check(ticket_hash ~ '^[0-9a-f]{64}$'),
      guest_user_id uuid not null, created_at timestamptz not null default now(),
      expires_at timestamptz not null, redeemed_at timestamptz, redeemed_by uuid,
      check(expires_at>created_at));
    create table futbeat_private.guest_account_merges (
      id bigint generated always as identity primary key,
      guest_user_id uuid not null, account_user_id uuid not null,
      merged_at timestamptz not null default now(), follows integer not null,
      interests integer not null, preferences text not null check(preferences in ('copied','filled','kept')),
      devices_disabled integer not null, check(guest_user_id<>account_user_id));
  `);
  return db;
}

const migration = () => read('supabase/migrations/20261107120000_account_deletion_residue.sql');
const rollback = () => read('supabase/manual/20261107120000_account_deletion_residue_rollback.sql');
const count = async (db, table) => (await db.query(`select count(*)::int c from futbeat_private.${table}`)).rows[0].c;
const fks = async (db) => (await db.query("select count(*)::int c from pg_constraint where contype = 'f' and conname like 'guest_%_fk'")).rows[0].c;
const hash = (n) => String(n).repeat(64);

async function seed(db) {
  await db.query('insert into auth.users values ($1),($2),($3)', [guest, account, other]);
  await db.query(`insert into futbeat_private.guest_merge_tickets (ticket_hash, guest_user_id, expires_at, redeemed_at, redeemed_by)
    values ($1, $2, now() + interval '10 minutes', now(), $3), ($4, $5, now() + interval '10 minutes', null, null)`,
  [hash(1), guest, account, hash(2), other]);
  await db.query(`insert into futbeat_private.guest_account_merges (guest_user_id, account_user_id, follows, interests, preferences, devices_disabled)
    values ($1, $2, 3, 0, 'filled', 1)`, [guest, account]);
}

test('deleting the account removes its merge audit and clears redeemed_by', async () => {
  const db = await database();
  await seed(db);
  await db.exec(await migration());
  await db.query('delete from auth.users where id = $1', [account]);
  assert.equal(await count(db, 'guest_account_merges'), 0);
  const rows = (await db.query('select guest_user_id, redeemed_by from futbeat_private.guest_merge_tickets order by ticket_hash')).rows;
  assert.deepEqual(rows, [{ guest_user_id: guest, redeemed_by: null }, { guest_user_id: other, redeemed_by: null }]);
});

test('deleting the guest removes its tickets and merge audit; other users untouched', async () => {
  const db = await database();
  await seed(db);
  await db.exec(await migration());
  await db.query('delete from auth.users where id = $1', [guest]);
  assert.equal(await count(db, 'guest_account_merges'), 0);
  const rows = (await db.query('select guest_user_id from futbeat_private.guest_merge_tickets')).rows;
  assert.deepEqual(rows, [{ guest_user_id: other }]);
});

test('existing orphans are cleaned; the migration is idempotent; rollback drops only the keys', async () => {
  const db = await database();
  await seed(db);
  await db.query('delete from auth.users where id = $1', [account]);
  assert.equal(await count(db, 'guest_account_merges'), 1, 'the defect: residue without the keys');
  await db.exec(await migration());
  await db.exec(await migration());
  assert.equal(await count(db, 'guest_account_merges'), 0);
  assert.equal((await db.query('select count(*)::int c from futbeat_private.guest_merge_tickets where redeemed_by is not null')).rows[0].c, 0);
  assert.equal(await fks(db), 4);
  await db.exec(await rollback());
  assert.equal(await fks(db), 0);
  assert.equal(await count(db, 'guest_merge_tickets'), 2);
});

test('a database without the guest-merge tables is left unchanged', async () => {
  const db = await database({ guestTables: false });
  await db.exec(await migration());
  await db.exec(await rollback());
  assert.equal((await db.query("select count(*)::int c from pg_constraint where contype = 'f'")).rows[0].c, 0);
});

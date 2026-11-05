import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';

const migration = '20261020071515_news111_source_collection_authorization.sql';
const catalogMigration = '20261020063629_news110_international_sources.sql';
const folder = new URL('../../supabase/migrations/', import.meta.url);

test('NEWS110 catalog applies and transaction rollback leaves the base untouched', async () => {
  const db = await PGlite.create({ extensions: { pg_trgm } });
  try {
    await db.exec(`do $$ begin
      if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
      if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
      if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
    end $$;`);
    const names = (await readdir(folder)).filter((name) => name.endsWith('.sql')).sort();
    for (const name of names.filter((name) => name < catalogMigration)) {
      await db.exec(await readFile(new URL(name, folder), 'utf8'));
    }
    const sql = await readFile(new URL(catalogMigration, folder), 'utf8');
    const count = async () => (await db.query(`select count(*)::int n from futbeat_private.news_feeds
      where id in ('as-futbol','clarin-futbol','ge-futebol','eltiempo-futbol-co','marca-liga-mx')`)).rows[0].n;
    assert.equal(await count(), 0);
    await assert.rejects(db.transaction(async (tx) => {
      await tx.exec(sql);
      assert.equal((await tx.query(`select count(*)::int n from futbeat_private.news_feeds
        where id in ('as-futbol','clarin-futbol','ge-futebol','eltiempo-futbol-co','marca-liga-mx')`)).rows[0].n, 5);
      throw new Error('simulate-catalog-rollback');
    }), /simulate-catalog-rollback/);
    assert.equal(await count(), 0);
    await db.exec(sql);
    assert.equal(await count(), 5);
    assert.equal((await db.query(`select count(*)::int n from futbeat_private.news_feeds
      where enabled and id in ('as-futbol','clarin-futbol','ge-futebol','eltiempo-futbol-co','marca-liga-mx')`)).rows[0].n, 0);
  } finally {
    await db.close();
  }
});

test('NEWS111 applies after NEWS110 and rolls back atomically in isolated PostgreSQL', async () => {
  const db = await PGlite.create({ extensions: { pg_trgm } });
  try {
    await db.exec(`do $$ begin
      if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
      if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
      if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
    end $$;`);
    const names = (await readdir(folder)).filter((name) => name.endsWith('.sql')).sort();
    assert.ok(names.includes(migration));
    for (const name of names.filter((name) => name < migration)) {
      await db.exec(await readFile(new URL(name, folder), 'utf8'));
    }
    const sql = await readFile(new URL(migration, folder), 'utf8');
    const columnCount = async (client = db) => (await client.query(`select count(*)::int n from information_schema.columns
      where table_schema='futbeat_private' and table_name='news_sources'
        and column_name in ('collection_authorized_at','collection_permission_ref')`)).rows[0].n;
    assert.equal(await columnCount(), 0);
    await assert.rejects(db.transaction(async (tx) => {
      await tx.exec(sql);
      assert.equal(await columnCount(tx), 2);
      throw new Error('simulate-rollback');
    }), /simulate-rollback/);
    assert.equal(await columnCount(), 0, 'aborted migration leaves baseline unchanged');
    await db.exec(sql);
    assert.equal(await columnCount(), 2);
    assert.equal((await db.query(`select count(*)::int n from futbeat_private.news_sources
      where collection_authorized_at is not null or collection_permission_ref is not null`)).rows[0].n, 0);
    await db.exec(await readFile(new URL('../../docs/integration/NEWS111-LOCAL-ROLLBACK.sql', import.meta.url), 'utf8'));
    assert.equal(await columnCount(), 0, 'emergency rollback removes the approval fields');
    assert.equal((await db.query('select public.futbeat_news_feed_due() v')).rows[0].v, null,
      'emergency rollback leaves RSS fail-closed');
    await db.exec(sql);
    assert.equal(await columnCount(), 2, 'the forward migration can be reapplied locally');
  } finally {
    await db.close();
  }
});

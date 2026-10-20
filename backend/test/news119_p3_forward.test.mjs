import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

const migrationUrl = new URL('../../supabase/migrations/20261020212315_news119_p3_reader_forward_compat.sql', import.meta.url);
const p3Url = new URL('../../supabase/migrations/20261019120000_news_pipeline_v2.sql', import.meta.url);
const legacyUrl = new URL('./fixtures/news/p3_legacy_reader.sql', import.meta.url);
const signature = 'futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer)';

const readerSql = (sql) => sql.match(/create or replace function futbeat_private\.futbeat_read_news_feed\([\s\S]*?end \$\$;/)?.[0].replaceAll('\r\n', '\n');
const readerHash = async (db) => (await db.query(`select md5(replace(prosrc,chr(13),'')) hash
  from pg_proc where oid='${signature}'::regprocedure`)).rows[0].hash;
const stories = async (db, tab = 'latest') => (await db.query(`select public.futbeat_read_news_feed(
  $1,'ES','[]'::jsonb,0,10) feed`, [tab])).rows[0].feed.stories;

test('NEWS119 reconciles historical P3 without changing data or bypassing rights', async () => {
  const [migration, p3, legacy] = await Promise.all(
    [migrationUrl, p3Url, legacyUrl].map((url) => readFile(url, 'utf8')));
  assert.equal(readerSql(migration), readerSql(p3), 'forward reader must track final P3 exactly');
  assert.ok(readerSql(legacy), 'historical reader fixture must be present');
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.news_articles
      (id,provider,external_id,title,description,url,source_name,published_at,
       language,source_domain,image_url,cluster_id,contract_version)
      values ('rss:news119','rss','news119','Synthetic story','Synthetic excerpt',
        'https://as.com/news119','Synthetic',now()-interval '1 hour','es',
        'as.com','https://as.com/news119-image','rss:news119',2)`);
    await db.query(`select futbeat_private.refresh_news_cluster('rss:news119')`);
    const count = async () => (await db.query(`select count(*)::int n from futbeat_private.news_articles`)).rows[0].n;
    const beforeCount = await count();
    const finalHash = await readerHash(db);
    assert.equal(finalHash, '85ede30c7ad35dc049d62042f42d65f8');
    await db.exec(migration);
    assert.equal(await readerHash(db), finalHash, 'clean install is idempotent');
    assert.equal(await count(), beforeCount);

    await db.exec(legacy);
    assert.equal(await readerHash(db), '0073fe6b0bd1fad59d526cccaf9fb03b');
    assert.equal((await stories(db))[0].sourceCountryCode, undefined);
    assert.equal((await stories(db, 'country')).length, 1,
      'old reader misclassifies publisher country as story country');

    await db.exec(migration);
    assert.equal(await readerHash(db), finalHash);
    assert.equal(await count(), beforeCount, 'forward migration rewrites no articles');
    assert.equal((await stories(db, 'country')).length, 0);
    const card = (await stories(db))[0];
    assert.equal(card.sourceCountryCode, 'ES');
    assert.equal(card.inSelectedCountry, false);
    assert.deepEqual(card.storyCountryNames, []);
    assert.equal(card.rights.snippet, 'UNVERIFIED');
    assert.equal(card.snippet, undefined);
    assert.equal(card.imageUrl, undefined);
    assert.equal((Date.parse(card.rights.expiresAt) - Date.parse(card.rights.checkedAt)), 30_000);
    assert.equal((await db.query(`select to_regprocedure(
      'public.futbeat_read_news_feed(text[],text)') is not null present`)).rows[0].present, true);

    await db.query(`update futbeat_private.news_provider_config set snippet_allowed=true,
      image_allowed=true,terms_reviewed_at=now() where provider='rss'`);
    await db.query(`update futbeat_private.news_sources set snippet_allowed=true,
      image_allowed=true,rights_reviewed_at=now() where domain='as.com'`);
    const allowed = (await stories(db))[0];
    assert.equal(allowed.rights.snippet, 'ALLOWED');
    assert.equal(allowed.rights.image, 'ALLOWED');
    assert.equal(allowed.snippet, 'Synthetic excerpt');
    assert.equal(allowed.imageUrl, 'https://as.com/news119-image');
    await db.query(`update futbeat_private.news_sources set image_allowed=false where domain='as.com'`);
    const imageRevoked = (await stories(db))[0];
    assert.equal(imageRevoked.rights.snippet, 'ALLOWED');
    assert.equal(imageRevoked.rights.image, 'REVOKED');
    assert.equal(imageRevoked.imageUrl, undefined);
    await db.query(`update futbeat_private.news_sources set snippet_allowed=false where domain='as.com'`);
    const revoked = (await stories(db))[0];
    assert.equal(revoked.rights.snippet, 'REVOKED');
    assert.equal(revoked.snippet, undefined);
    assert.equal(revoked.url, 'https://as.com/news119');
    const activation = (await db.query(`select
      (select count(*)::int from futbeat_private.news_feeds where enabled) feeds,
      (select count(*)::int from futbeat_private.news_provider_config where enabled or production_allowed) providers,
      futbeat_private.futbeat_news_feed_due() is null due_empty`)).rows[0];
    assert.deepEqual(activation, { feeds: 0, providers: 0, due_empty: true });
  } finally {
    await db.close();
  }
});

test('NEWS119 stops before replacing an unrecognized P3 reader', async () => {
  const migration = await readFile(migrationUrl, 'utf8');
  const db = await openDatabase();
  try {
    await db.exec(`create or replace function futbeat_private.futbeat_read_news_feed(
      p_tab text,p_country text,p_follows jsonb,p_offset integer,p_limit integer)
      returns jsonb language sql stable security definer set search_path='' as $$
        select '{}'::jsonb
      $$;`);
    const unexpectedHash = await readerHash(db);
    await assert.rejects(db.exec(migration), /unrecognized P3 reader body/);
    await db.exec('rollback;');
    assert.equal(await readerHash(db), unexpectedHash,
      'a failed precondition must leave the unknown body untouched');
  } finally {
    await db.close();
  }
});

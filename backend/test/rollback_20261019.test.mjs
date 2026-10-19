import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// The four 2026-10-19 packages each ship a manual rollback. Applied in
// reverse order on a fully migrated database, they restore the previous
// definitions and leave v1 data intact.

const manual = (name) => readFile(new URL(`../../supabase/manual/${name}`, import.meta.url), 'utf8');
const exists = async (db, signature) => (await db.query('select to_regprocedure($1) is not null v', [signature])).rows[0].v;
const def = async (db, signature) => (await db.query('select pg_get_functiondef($1::regprocedure) d', [signature])).rows[0].d;

test('rollbacks restore the previous functions and keep v1 news', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_rb','team','{"id":"fb_team_rb","name":"Club RB"}')`);
    await db.query(`insert into futbeat_private.news_articles(id,provider,external_id,title,url,source_name,published_at)
      values('newsdata:v1','newsdata','v1','Titular v1','https://teletica.com/v1','Teletica',now())`);
    await db.query(`insert into futbeat_private.news_articles(id,provider,external_id,title,url,source_name,published_at,contract_version)
      values('rss:v2','rss','v2','Titular v2','https://teletica.com/v2','Teletica',now(),2)`);

    await db.exec(await manual('20261019130000_match_summary_cache_rollback.sql'));
    assert.equal(await exists(db, 'public.futbeat_store_match_summary(text,jsonb)'), false);

    await db.exec(await manual('20261019120000_news_pipeline_v2_rollback.sql'));
    assert.equal(await exists(db, 'public.futbeat_read_news_feed(text,text,jsonb,integer,integer)'), false);
    assert.deepEqual((await db.query('select id from futbeat_private.news_articles order by id')).rows, [{ id: 'newsdata:v1' }]);
    assert.equal((await db.query("select count(*)::int n from information_schema.columns where table_name='news_articles' and column_name='url_key'")).rows[0].n, 0);

    await db.exec(await manual('20261019110000_team_profile_fixture_twins_rollback.sql'));
    assert.ok(!(await def(db, 'public.futbeat_read_team_matches(text,text,text,integer,text,text)')).includes('fixture_better_twin'));
    const page = (await db.query("select public.futbeat_read_team_matches('fb_team_rb','results') v")).rows[0].v;
    assert.equal(page.teamId, 'fb_team_rb');

    await db.exec(await manual('20261019100000_player_club_national_membership_rollback.sql'));
    assert.equal(await exists(db, 'futbeat_private.store_team_squad_before_national_context(text,text,timestamptz,jsonb)'), false);
    assert.equal(await exists(db, 'futbeat_private.read_entity_detail_before_player_teams(text,text)'), false);
    assert.ok((await def(db, 'futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)')).includes('store_team_squad_before_identity_dedup'));
    assert.ok((await def(db, 'futbeat_private.futbeat_read_entity_detail(text,text)')).includes('read_entity_detail_before_squad_dedup'));
    const detail = (await db.query("select public.futbeat_read_entity_detail('team','fb_team_rb') v")).rows[0].v;
    assert.equal(detail.schemaVersion, 1);
  } finally { await db.close(); }
});

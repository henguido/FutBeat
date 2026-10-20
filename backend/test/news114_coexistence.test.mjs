import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

test('v1 writer never prunes shared v2 articles and rollback preserves v1', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities(id,kind,payload) values
      ('fb_team_news114','team','{"id":"fb_team_news114"}')`);
    await db.query(`insert into futbeat_private.news_articles
      (id,provider,external_id,title,url,source_name,published_at,contract_version) values
      ('newsdata:old-v1','newsdata','old-v1','Old v1','https://example.com/v1','Example',now()-interval '40 days',null),
      ('currents:old-v2','currents','old-v2','Old v2','https://example.com/v2','Example',now()-interval '40 days',2)`);
    const response = await db.query(`select futbeat_private.futbeat_store_news_batch(
      'team','fb_team_news114',now(),'Club Ejemplo',
      jsonb_build_array(jsonb_build_object('id','fresh-v1','title','Fresh v1',
      'url','https://example.com/fresh','sourceName','Example',
      'publishedAt',now()::text)))`);
    assert.equal(response.rows.length, 1);
    assert.deepEqual((await db.query(`select id from futbeat_private.news_articles
      where id in ('newsdata:old-v1','currents:old-v2') order by id`)).rows,
      [{ id: 'currents:old-v2' }]);
    const sql = await readFile(new URL('../../supabase/manual/20261019120000_news_pipeline_v2_rollback.sql', import.meta.url), 'utf8');
    await db.exec(sql);
    assert.equal((await db.query(`select to_regprocedure('public.futbeat_read_news_feed(text[],text)') is not null AS present`)).rows[0].present, true);
    assert.equal((await db.query(`select to_regprocedure('public.futbeat_read_news_feed(text,text,jsonb,integer,integer)') is not null AS present`)).rows[0].present, false);
    assert.deepEqual((await db.query(`select id from futbeat_private.news_articles order by id`)).rows,
      [{ id: 'newsdata:fresh-v1' }]);
    await db.query(`select futbeat_private.futbeat_store_news_batch(
      'team','fb_team_news114',now(),'Club Ejemplo',
      jsonb_build_array(jsonb_build_object('id','after-rollback','title','After rollback',
      'url','https://example.com/again','sourceName','Example',
      'publishedAt',now()::text)))`);
    assert.equal((await db.query(`select count(*)::int AS n from futbeat_private.news_articles
      where id='newsdata:after-rollback'`)).rows[0].n, 1);
  } finally {
    await db.close();
  }
});

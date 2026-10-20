import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

test('Noticias v1 reads bounded stored articles and roster changes without collection', async () => {
  const db = await openDatabase();
  try {
    const empty = (await db.query(
      "select public.futbeat_read_news_feed('{}'::text[], null) value",
    )).rows[0].value;
    assert.equal(empty.schemaVersion, 1);
    assert.equal(empty.demo, false);
    assert.deepEqual(empty.news, []);
    assert.deepEqual(empty.transfers, []);

    const competition = 'fb_comp_news113';
    const team = 'fb_team_news113';
    await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [
      competition, JSON.stringify({ id: competition, name: 'Liga de prueba' }),
    ]);
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [
      team, JSON.stringify({ id: team, name: 'Equipo de prueba', competitionId: competition }),
    ]);
    const now = new Date().toISOString();
    for (const [id, title, days] of [
      ['one', 'Noticia verificada', 0],
      ['two', 'Noticia verificada', 0],
      ['old', 'Noticia caducada', 20],
    ]) {
      const publishedAt = new Date(Date.now() - days * 86400000).toISOString();
      await db.query(`insert into futbeat_private.news_articles
        (id,provider,external_id,title,description,url,source_name,published_at)
        values($1,'fixture',$2,$3,'Texto no autorizado',$4,'Fuente sintética',$5)`,
      [id, id, title, `https://example.invalid/${id}`, publishedAt]);
      await db.query(`insert into futbeat_private.news_subjects
        (article_id,subject_type,subject_id,matched_at) values($1,'team',$2,$3)`,
      [id, team, now]);
    }
    const otherTeam = 'fb_team_news113_other';
    const player = 'fb_player_news113';
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [
      otherTeam, JSON.stringify({ id: otherTeam, name: 'Otro club' }),
    ]);
    await db.query("insert into futbeat_private.entities values($1,'player',$2)", [
      player, JSON.stringify({ id: player, name: 'Jugador de prueba' }),
    ]);
    await db.query(`insert into futbeat_private.transfer_events
      (player_id,from_team_id,to_team_id,detected_at,detected_period,
       provider,status,source_label)
      values($1,$2,$3,$4,current_date,'fixture','ROSTER_CHANGE','Fuente sintética')`,
    [player, team, otherTeam, now]);
    const value = (await db.query(
      'select public.futbeat_read_news_feed($1,$2) value',
      [[`team:${team}`], 'CR'],
    )).rows[0].value;
    assert.equal(value.news.length, 1, 'duplicate title and expired article excluded');
    assert.equal(value.news[0].followed, true);
    assert.equal(value.news[0].title, 'Noticia verificada');
    assert.equal(Object.hasOwn(value.news[0], 'description'), false);
    assert.equal(Object.hasOwn(value.news[0], 'imageUrl'), false);
    assert.equal(value.transfers.length, 1);
    assert.equal(value.transfers[0].playerId, player);
  } finally {
    await db.close();
  }
});

test('Noticias v1 rollback removes only its function and can be reapplied', async () => {
  const db = await openDatabase();
  try {
    await db.exec(await readFile(new URL(
      '../../supabase/manual/20261005060000_news_feed_rollback.sql',
      import.meta.url,
    ), 'utf8'));
    const missing = (await db.query(`select to_regprocedure(
      'public.futbeat_read_news_feed(text[],text)') value`)).rows[0].value;
    assert.equal(missing, null);
    assert.ok((await db.query(`select to_regclass(
      'futbeat_private.news_articles') value`)).rows[0].value);
    await db.exec(await readFile(new URL(
      '../../supabase/migrations/20261005060000_news_feed.sql',
      import.meta.url,
    ), 'utf8'));
    const restored = (await db.query(`select to_regprocedure(
      'public.futbeat_read_news_feed(text[],text)') value`)).rows[0].value;
    assert.ok(restored);
  } finally {
    await db.close();
  }
});

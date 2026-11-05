import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

const manual = (name) => readFile(
  new URL(`../../supabase/manual/${name}`, import.meta.url),
  'utf8',
);
const exists = async (db, signature) => (await db.query(
  'select to_regprocedure($1) is not null v', [signature],
)).rows[0].v;
const definition = async (db, signature) => (await db.query(
  'select pg_get_functiondef($1::regprocedure) d', [signature],
)).rows[0].d;

test('identity rollbacks restore prior functions without deleting historical rows', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_rb','team','{"id":"fb_team_rb","name":"Club RB"}')`);
    await db.query(`insert into futbeat_private.entities values
      ('fb_player_rb','player','{"id":"fb_player_rb","name":"Player RB","teamId":"fb_team_rb"}')`);
    await db.query(`insert into futbeat_private.team_squad_members
      (team_id,player_id,provider,updated_at)
      values('fb_team_rb','fb_player_rb','synthetic_local',now())`);

    await db.exec(await manual('20261019110000_team_profile_fixture_twins_rollback.sql'));
    assert.ok(!(await definition(
      db, 'public.futbeat_read_team_matches(text,text,text,integer,text,text)',
    )).includes('fixture_better_twin'));
    assert.equal(await exists(db, 'futbeat_private.fixture_better_twin(jsonb)'), false);
    assert.equal(await exists(db, 'futbeat_private.team_identity_twin_candidates(date,date)'), false);
    const page = (await db.query(
      "select public.futbeat_read_team_matches('fb_team_rb','results') v",
    )).rows[0].v;
    assert.equal(page.teamId, 'fb_team_rb');

    await db.exec(await manual('20261019100000_player_club_national_membership_rollback.sql'));
    assert.equal(await exists(
      db, 'futbeat_private.store_team_squad_before_national_context(text,text,timestamptz,jsonb)',
    ), false);
    assert.equal(await exists(
      db, 'futbeat_private.read_entity_detail_before_player_teams(text,text)',
    ), false);
    assert.ok((await definition(
      db, 'futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)',
    )).includes('store_team_squad_before_identity_dedup'));
    assert.ok((await definition(
      db, 'futbeat_private.futbeat_read_entity_detail(text,text)',
    )).includes('read_entity_detail_before_squad_dedup'));

    const rows = (await db.query(`select team_id,player_id,provider
      from futbeat_private.team_squad_members where player_id='fb_player_rb'`)).rows;
    assert.deepEqual(rows, [{
      team_id: 'fb_team_rb', player_id: 'fb_player_rb', provider: 'synthetic_local',
    }]);
  } finally {
    await db.close();
  }
});

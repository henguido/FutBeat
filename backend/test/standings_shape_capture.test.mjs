import test from 'node:test';
import assert from 'node:assert/strict';
import { goalStandingsShape } from '../../supabase/functions/_shared/goal_standings.ts';
import { openDatabase } from '../storage/database.mjs';

test('shape capture retains only bounded stage/group field paths and numeric/UUID IDs', () => {
  const rows = [
    {
      team: { id: 'private-team', name: 'Never retain this' },
      stageId: 42,
      overallLeaguePosition: '4',
      overallLeagueSeason: 'private-season',
      group: { id: 'e965870b-30ce-4d22-a726-220cb19321d9', name: 'Private label', secret: 'not retained' },
      phase_name: 'Private phase',
      roundId: 'abc-not-an-id',
    },
    { stageId: 43, group: { id: 'e965870b-30ce-4d22-a726-220cb19321d9' } },
  ];
  const shape = goalStandingsShape(rows);
  assert.deepEqual(shape, {
    version: 1,
    sampledRows: 2,
    fields: ['group', 'group.id', 'group.name', 'group.secret', 'overallLeaguePosition', 'overallLeagueSeason', 'phase_name', 'roundId', 'stageId'],
    ids: { 'group.id': ['e965870b-30ce-4d22-a726-220cb19321d9'], stageId: ['42', '43'] },
  });
  const serialized = JSON.stringify(shape);
  assert.doesNotMatch(serialized, /private-team|Never retain|Private label|Private phase|private-season|not retained|abc-not-an-id/);
  assert.equal(goalStandingsShape([rows[0]]), null);
});

test('shape capture limits identifiers and field count', () => {
  const rows = Array.from({ length: 120 }, (_, i) => ({
    stageId: String(i),
    ...Object.fromEntries(Array.from({ length: 40 }, (_, n) => [`groupField${n}`, 'discard'])),
  }));
  const shape = goalStandingsShape(rows);
  assert.equal(shape.sampledRows, 100);
  assert.equal(shape.fields.length, 32);
  assert.deepEqual(shape.ids.stageId, ['0', '1', '2', '3', '4', '5', '6', '7']);
});

test('private shape sample is service-only, expires and prunes on subsequent writes', async () => {
  const db = await openDatabase();
  try {
    const privileges = await db.query(`select
      has_function_privilege('service_role','public.futbeat_record_goal_standings_shape(text,text,jsonb)','EXECUTE') service_exec,
      has_function_privilege('anon','public.futbeat_record_goal_standings_shape(text,text,jsonb)','EXECUTE') anon_exec,
      has_table_privilege('anon','futbeat_private.goal_standings_shape_samples','SELECT') anon_read`);
    assert.deepEqual(privileges.rows[0], { service_exec: true, anon_exec: false, anon_read: false });
    const shape = goalStandingsShape([{ stageId: 42 }, { stageId: 43 }]);
    // PGlite's test role lacks Supabase's built-in BYPASSRLS until mirrored here.
    await db.exec('alter role service_role bypassrls; set role service_role');
    try {
      await db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
        ['fb_comp_service', 'demand', JSON.stringify(shape)]);
    } finally {
      await db.exec('reset role');
    }
    assert.equal((await db.query("select count(*)::integer n from futbeat_private.goal_standings_shape_samples where competition_id='fb_comp_service'")).rows[0].n, 1);
    await db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
      ['fb_comp_test', 'demand', JSON.stringify(shape)]);
    const found = await db.query(`select source, shape, expires_at > now() valid
      from futbeat_private.goal_standings_shape_samples where competition_id='fb_comp_test'`);
    assert.equal(found.rows.length, 1);
    assert.equal(found.rows[0].source, 'demand');
    assert.equal(found.rows[0].valid, true);
    assert.deepEqual(found.rows[0].shape, shape);
    await db.query(`update futbeat_private.goal_standings_shape_samples
      set expires_at=now()-interval '1 second' where competition_id='fb_comp_test'`);
    await db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
      ['fb_comp_next', 'scheduled', JSON.stringify(shape)]);
    const count = await db.query('select count(*)::integer n from futbeat_private.goal_standings_shape_samples');
    assert.equal(count.rows[0].n, 2);
  } finally {
    await db.close();
  }
});

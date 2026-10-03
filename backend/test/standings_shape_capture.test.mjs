import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { goalStandingsShape } from '../../supabase/functions/_shared/goal_standings.ts';
import { openDatabase } from '../storage/database.mjs';

const adversarialRows = () => Array.from({ length: 8 }, (_, i) => {
  const id = (offset) => `00000000-0000-4000-8000-${String(offset + i).padStart(12, '0')}`;
  return {
    stageId: id(0), stage_id: id(8), groupId: id(16), group_id: id(24),
    phaseId: id(32), phase_id: id(40), roundId: id(48), round_id: id(56),
    stage: { id: id(64) }, group: { id: id(72) },
    phase: { id: id(80) }, round: { id: id(88) },
    ...Object.fromEntries(Array.from({ length: 16 }, (_, n) =>
      [`groupField${String(n).padStart(2, '0')}${'x'.repeat(50)}`, 'private-value'])),
  };
});

test('shape RPC migration reloads the PostgREST schema cache', () => {
  const migration = readFileSync(new URL('../../supabase/migrations/20261003050020_goal_standings_shape_sample.sql', import.meta.url), 'utf8');
  assert.match(migration, /notify pgrst\s*,\s*'reload schema'\s*;\s*$/i);
  const retirement = readFileSync(new URL('../../supabase/manual/20261003050020_goal_standings_shape_sample_retire.sql', import.meta.url), 'utf8');
  assert.match(retirement, /notify pgrst\s*,\s*'reload schema'\s*;\s*commit\s*;\s*$/i);
});

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

test('adversarial UUID aliases stay below the global SQL size cap without dropping field names', () => {
  const rows = adversarialRows();
  const shape = goalStandingsShape(rows);
  const expectedFields = Object.keys(rows[0]).flatMap((key) =>
    ['stage', 'group', 'phase', 'round'].includes(key) ? [key, `${key}.id`] : [key]).sort();
  assert.deepEqual(shape.fields, expectedFields);
  assert.equal(shape.fields.length, 32);
  assert.ok(Object.values(shape.ids).reduce((n, values) => n + values.length, 0) < 96,
    'some IDs must be trimmed to meet the global budget');
  assert.ok(Object.keys(shape.ids).length >= 8, 'examples span the ID paths');
  assert.ok(Buffer.byteLength(JSON.stringify(shape), 'utf8') <= 3200);
  assert.deepEqual(goalStandingsShape(rows), shape, 'trimming is deterministic');
  assert.doesNotMatch(JSON.stringify(shape), /private-value/);
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
    for (const invalid of [{ fields: [], ids: {}, sampledRows: 2 },
      { version: null, fields: [], ids: {}, sampledRows: 2 }]) {
      await assert.rejects(
        db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
          ['fb_comp_invalid', 'demand', JSON.stringify(invalid)]),
        /Invalid standings shape sample/,
      );
      await assert.rejects(
        db.query(`insert into futbeat_private.goal_standings_shape_samples
          (competition_id, source, shape) values ($1, 'demand', $2)`,
          ['fb_comp_invalid', JSON.stringify(invalid)]),
        /check constraint/i,
      );
    }
    // PGlite's test role lacks Supabase's built-in BYPASSRLS until mirrored here.
    await db.exec('alter role service_role bypassrls; set role service_role');
    try {
      await db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
        ['fb_comp_service', 'demand', JSON.stringify(shape)]);
      await db.query('select public.futbeat_record_goal_standings_shape($1,$2,$3)',
        ['fb_comp_dense', 'demand', JSON.stringify(goalStandingsShape(adversarialRows()))]);
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
    assert.equal(count.rows[0].n, 3);
  } finally {
    await db.close();
  }
});

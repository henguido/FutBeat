import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// BE-237: 2026-10-31 13:05 UTC. A few fixtures outside the catalogue cost 1.17 s each,
// the link hit 57014, the rollback linked none of them and every poll repeated it.

const migration = await readFile(new URL('../../supabase/migrations/20261101010000_live_link_cannot_block_poll.sql', import.meta.url), 'utf8');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const kickoff = () => new Date(Date.now() - 3600000).toISOString();
const seed = async (db, start) => {
  for (const [id, name] of [['fb_team_a', 'Alfa'], ['fb_team_b', 'Beta']]) {
    await db.query(`insert into futbeat_private.entities(id,kind,payload) values($1,'team',jsonb_build_object('id',$1::text,'name',$2::text))`, [id, name]);
  }
  await db.query(`insert into futbeat_private.entities(id,kind,payload) values('fb_match_ab','match',jsonb_build_object(
    'id','fb_match_ab','homeTeamId','fb_team_a','awayTeamId','fb_team_b','startTime',$1::text,'status','SCHEDULED','competitionId','fb_comp_x'))`, [start]);
};
const link = (db, fixtures) => db.query('select public.futbeat_link_goal_live_matches($1) v', [JSON.stringify(fixtures)]).then((r) => r.rows[0].v);
const fixture = (id, start, home = 'Alfa', away = 'Beta') => ({ apiId: id, kickoffUtc: start, homeTeam: { name: home }, awayTeam: { name: away } });

test('the name lookup still finds a catalogue match, now through calendar_matches', () => withDb(async (db) => {
  const start = kickoff();
  await seed(db, start);
  const r = await link(db, [fixture('x1', start)]);
  assert.equal(r.linked, 1);
  const { rows } = await db.query(`select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id='x1'`);
  assert.equal(rows[0].canonical_id, 'fb_match_ab');
}));

test('a match kicked off outside three hours is not taken', () => withDb(async (db) => {
  await seed(db, new Date(Date.now() - 6 * 3600000).toISOString());
  assert.equal((await link(db, [fixture('x2', kickoff())])).linked, 0);
}));

test('past the deadline fixtures are deferred, known ones count and the call commits', () => withDb(async (db) => {
  const start = kickoff();
  await seed(db, start);
  assert.equal((await link(db, [fixture('x3', start)])).linked, 1);
  const body = migration.slice(migration.indexOf('CREATE OR REPLACE FUNCTION'));
  for (const fn of body.replace("interval '4 seconds'", "interval '-1 second'").replace("interval '6 seconds'", "interval '-1 second'").split(/(?<=\$function\$);/)) {
    if (fn.trim()) await db.query(fn);
  }
  const r = await link(db, [fixture('x3', start), fixture('x4', start)]);
  assert.equal(r.alreadyLinked, 1);
  assert.equal(r.deferredCount, 1);
  assert.equal(r.linked, 0);
  assert.equal(r.unmappedCount, 0);
}));

test('no scan of entities remains in the linker lookups', () => {
  assert.doesNotMatch(migration, /from futbeat_private\.entities m\s+join/);
  assert.match(migration, /from futbeat_private\.calendar_matches c\s+join futbeat_private\.entities m/);
});

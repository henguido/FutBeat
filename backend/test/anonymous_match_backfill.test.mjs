import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// BE-244: empties left by failed global stores are filled in small batches from
// the latest observation, by provider ids only. No fusion, and reversible.

const kickoff = new Date(Date.now() - 2 * 3600000);
const iso = (ms = 0) => new Date(kickoff.getTime() + ms).toISOString();
const H = 3600000;

async function withDb(fn) {
  const db = await openDatabase();
  try {
    for (const [id, kind, name] of [['fb_t1', 'team', 'Platense'], ['fb_t2', 'team', 'Lanús'], ['fb_t3', 'team', 'Motagua'],
      ['fb_t4', 'team', 'Tirol'], ['fb_c1', 'competition', 'Liga'], ['fb_c2', 'competition', 'Copa']]) {
      await db.query('insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, kind, JSON.stringify({ id, name })]);
      await mapId(db, kind, `x${id.slice(3)}`, id);
    }
    await fn(db);
  } finally { await db.close(); }
}
const mapId = (db, kind, ext, id) => db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api',$1,$2,$3)", [kind, ext, id]);
const fixture = (ext, over = {}) => ({ apiId: ext, kickoffUtc: iso(), matchStatus: 'FINISHED', leagueId: 'xc1', leagueYear: '2026',
  homeTeam: { id: 'xt1', name: 'Platense' }, awayTeam: { id: 'xt2', name: 'Lanús' }, ...over });
async function empty(db, id, ext, fx = fixture(ext)) {
  await db.query('insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, 'match', JSON.stringify({ id, name: '', country: '', shortName: '' })]);
  await mapId(db, 'match', ext, id);
  await db.query("insert into futbeat_private.provider_observations(provider,external_match_id,received_at,status,payload_hash,raw_payload) values('goal_api',$1,now(),'FINISHED_PENDING_VERIFICATION',$2,$3)", [ext, ext.padEnd(64, '0').replace(/[^0-9a-f]/g, 'a'), JSON.stringify(fx)]);
  await db.query('insert into futbeat_private.anonymous_match_backfill(match_id,external_id,kickoff) values($1,$2,$3)', [id, ext, fx.kickoffUtc]);
}
const real = async (db, id, ext, home, away, start) => {
  await db.query('insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, 'match', JSON.stringify({ id, homeTeamId: home, awayTeamId: away, competitionId: 'fb_c2', startTime: start, status: 'SCHEDULED', events: [], statistics: [], provenance: { source: 'GOAL API' } })]);
  if (ext) await mapId(db, 'match', ext, id);
};
const run = (db, n = 25) => db.query('select futbeat_private.backfill_anonymous_matches($1) v', [n]).then((r) => r.rows[0].v);
const rollback = (db, n = 25) => db.query('select futbeat_private.rollback_anonymous_match_backfill($1) v', [n]).then((r) => r.rows[0].v);
const payload = (db, id) => db.query('select payload p from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].p);
const state = (db, id) => db.query('select state s from futbeat_private.anonymous_match_backfill where match_id=$1', [id]).then((r) => r.rows[0].s);
const inCalendar = (db, id) => db.query('select count(*)::int n from futbeat_private.calendar_matches where match_id=$1', [id]).then((r) => r.rows[0].n);
const entityCount = (db) => db.query("select count(*)::int n from futbeat_private.entities where kind='match'").then((r) => r.rows[0].n);

test('a batch fills teams, competition and calendar row and is marked as backfill', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  const before = await entityCount(db);
  const r = await run(db);
  assert.equal(r.hydrated, 1);
  assert.equal(r.pending, 0);
  const p = await payload(db, 'fb_m1');
  assert.equal(p.homeTeamId, 'fb_t1');
  assert.equal(p.awayTeamId, 'fb_t2');
  assert.equal(p.competitionId, 'fb_c1');
  assert.equal(p.provenance.discoveredVia, 'backfill');
  assert.equal(p.status, 'SCHEDULED');
  assert.equal(await inCalendar(db, 'fb_m1'), 1);
  assert.equal(await entityCount(db), before);
}));

test('a limit is respected and a second call continues in kickoff order', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1', fixture('g1', { kickoffUtc: iso(30 * H) }));
  await empty(db, 'fb_m2', 'g2', fixture('g2', { homeTeam: { id: 'xt3' }, awayTeam: { id: 'xt4' } }));
  assert.equal((await run(db, 1)).pending, 1);
  assert.equal(await state(db, 'fb_m2'), 'hydrated');
  assert.equal(await state(db, 'fb_m1'), 'PENDING');
  assert.equal((await run(db, 1)).pending, 0);
}));

test('a second pass changes nothing', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  await run(db);
  const first = await payload(db, 'fb_m1');
  await run(db);
  assert.deepEqual(await payload(db, 'fb_m1'), first);
}));

test('a real match of the same teams keeps the entity empty, nothing is merged', () => withDb(async (db) => {
  await real(db, 'fb_r1', 'g9', 'fb_t1', 'fb_t2', iso(H));
  await empty(db, 'fb_m1', 'g1');
  assert.equal((await run(db)).twin_exists, 1);
  assert.equal((await payload(db, 'fb_m1')).homeTeamId, undefined);
  assert.equal((await db.query("select canonical_id c from futbeat_private.provider_entities where external_id='g1'")).rows[0].c, 'fb_m1');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.entity_redirects')).rows[0].n, 0);
}));

test('one shared team within 3 hours holds: twin under another team id, or a merged homonym', () => withDb(async (db) => {
  await real(db, 'fb_r1', 'g9', 'fb_t1', 'fb_t3', iso(H / 2));
  await empty(db, 'fb_m1', 'g1');
  assert.equal((await run(db)).team_busy, 1);
  assert.equal((await payload(db, 'fb_m1')).homeTeamId, undefined);
}));

test('the same team more than 3 hours away does not hold', () => withDb(async (db) => {
  await real(db, 'fb_r1', 'g9', 'fb_t1', 'fb_t3', iso(4 * H));
  await empty(db, 'fb_m1', 'g1');
  assert.equal((await run(db)).hydrated, 1);
}));

test('two empties of one team in the window: the second holds', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  await empty(db, 'fb_m2', 'g2', fixture('g2', { kickoffUtc: iso(H), awayTeam: { id: 'xt3' } }));
  const r = await run(db);
  assert.equal(r.hydrated, 1);
  assert.equal(r.team_busy, 1);
}));

test('a remapped provider id is left alone', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  await real(db, 'fb_r1', null, 'fb_t3', 'fb_t4', iso(50 * H));
  await db.query("update futbeat_private.provider_entities set canonical_id='fb_r1' where external_id='g1'");
  assert.equal((await run(db)).remapped, 1);
  assert.equal((await payload(db, 'fb_m1')).homeTeamId, undefined);
}));

test('an unlinked observation and live state join the filled match', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  await run(db);
  const r = await db.query("select canonical_match_id c from futbeat_private.provider_observations where external_match_id='g1'");
  assert.equal(r.rows[0].c, 'fb_m1');
}));

test('an observation of another fixture is never used', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1', fixture('other'));
  assert.equal((await run(db)).no_observation, 1);
  assert.equal((await payload(db, 'fb_m1')).homeTeamId, undefined);
}));

test('rollback restores the empty entity and leaves the calendar as before', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  const prior = await payload(db, 'fb_m1');
  await run(db);
  const r = await rollback(db);
  assert.equal(r.ROLLED_BACK, 1);
  assert.deepEqual(await payload(db, 'fb_m1'), prior);
  assert.equal(await inCalendar(db, 'fb_m1'), 0);
}));

test('rollback keeps a match a real ingest rewrote', () => withDb(async (db) => {
  await empty(db, 'fb_m1', 'g1');
  await run(db);
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{provenance}','{\"source\":\"GOAL API\"}') where id='fb_m1'");
  assert.equal((await rollback(db)).KEPT_REWRITTEN, 1);
  assert.equal((await payload(db, 'fb_m1')).homeTeamId, 'fb_t1');
}));

test('the queue and both functions stay closed to API roles', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated', 'service_role']) {
    const r = await db.query(`select has_table_privilege('${role}','futbeat_private.anonymous_match_backfill','select') t,
      has_function_privilege('${role}','futbeat_private.backfill_anonymous_matches(integer)','execute') f`);
    assert.equal(r.rows[0].t, false, role);
    assert.equal(r.rows[0].f, false, role);
  }
}));

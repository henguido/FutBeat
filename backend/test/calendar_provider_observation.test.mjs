import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { openDatabase } from '../storage/database.mjs';

const calendarSql = (operation) => readFile(new URL(
  `./fixtures/calendar_provider_observation_${operation}.sql`, import.meta.url,
), 'utf8');

test('calendar exposes matching observed LIVE state and rolls back to the captured contract', async (t) => {
  const db = await openDatabase();
  t.after(() => db.close());
  const apply = await calendarSql('apply');
  const rollback = await calendarSql('rollback');
  const capturedDefinition = rollback.slice(rollback.indexOf('CREATE OR REPLACE FUNCTION'), rollback.lastIndexOf('commit;'));
  await db.exec(capturedDefinition);
  const matchId = 'fb_match_8da4aa4fd93b40c3b1ec9245ae28e05f';
  const clock = (await db.query(`select now() now,
    (now()-interval '1 hour') kickoff,
    ((now()-interval '1 hour') at time zone 'America/Costa_Rica')::date::text calendar_day,
    now()-interval '4 minutes' observed, now()-interval '1 minute' repeated`)).rows[0];
  const match = {
    id: matchId, startTime: clock.kickoff, status: 'LIVE', minute: 70,
    competitionId: 'fb_comp_test', homeTeamId: 'fb_team_home', awayTeamId: 'fb_team_away',
    score: { home: 1, away: 0 }, events: [],
    provenance: { receivedAt: clock.now, source: 'GOAL API', externalId: 'private-id' },
  };
  await db.query("insert into futbeat_private.entities(id,kind,payload) values($1,'match',$2)", [matchId, match]);
  const build = async () => (await db.query(
    'select futbeat_private.build_compact_calendar($1,$1) payload', [clock.calendar_day],
  )).rows[0].payload;
  const baseline = await build();
  assert.equal(baseline.matches[0].status, 'LIVE');
  assert.equal(baseline.matches[0].provenance, undefined);

  await db.exec(apply);
  assert.deepEqual(await build(), baseline, 'internal ingestion time provides no live observation');
  await db.query(`insert into futbeat_private.live_match_state(
    provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,
    last_payload_hash,revision,first_seen_at,last_seen_at,changed_at)
    values('goal_api','private-id',$1,'LIVE',70,1,0,repeat('a',64),16,$2,$2,$2)`,
  [matchId, clock.observed]);
  const observed = await build();
  assert.equal(observed.updatedAt, baseline.updatedAt);
  assert.deepEqual(Object.keys(observed.matches[0].provenance), ['providerObservedAt']);
  assert.equal(Date.parse(observed.matches[0].provenance.providerObservedAt), +clock.observed);

  const read = async () => (await db.query(
    'select public.futbeat_read_calendar_range($1,$1) payload', [clock.calendar_day],
  )).rows[0].payload;
  assert.equal(Date.parse((await read()).matches[0].provenance.providerObservedAt), +clock.observed);
  await db.query('update futbeat_private.live_match_state set last_seen_at=$1 where canonical_match_id=$2',
    [clock.repeated, matchId]);
  assert.equal(Date.parse((await read()).matches[0].provenance.providerObservedAt), +clock.observed,
    'cache hits keep the timestamp of the actual observation included in the snapshot');
  assert.equal(Date.parse((await build()).matches[0].provenance.providerObservedAt), +clock.repeated,
    'a rebuild can expose an unchanged repeat without advancing a sporting revision');

  await db.query('update futbeat_private.live_match_state set minute=72 where canonical_match_id=$1', [matchId]);
  assert.equal((await build()).matches[0].provenance, undefined, 'observation of another minute does not freshen the displayed state');

  await db.exec(rollback);
  assert.deepEqual(await build(), baseline);
});

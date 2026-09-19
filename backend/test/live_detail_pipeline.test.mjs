import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

test('GOAL LIVE reservation tolerates five-minute scheduler jitter', async () => {
  const db = await openDatabase();
  try {
    const row = (await db.query(`
      select pg_get_functiondef(
        'futbeat_private.futbeat_reserve_goal_live_call(text)'::regprocedure
      ) def
    `)).rows[0];

    assert.match(row.def, /interval '4 minutes'/);
    assert.match(row.def, /240-extract\(epoch/);
    assert.doesNotMatch(row.def, /v_last>v_now-interval '5 minutes'/);
  } finally {
    await db.close();
  }
});

test('GOAL worker reconciles detailed fixtures into global LIVE state', async () => {
  const source = await readFile(
    new URL(
      '../../supabase/functions/futbeat-goal-live-sync/index.ts',
      import.meta.url,
    ),
    'utf8',
  );

  assert.match(source, /normalizeFixtureEvents/);
  assert.match(source, /events\.map\(\(event\) => event\.eventKey\)/);
  assert.match(source, /p_observations: \[liveObservation\]/);
  assert.match(source, /futbeat_record_live_batch/);
  assert.match(source, /trigger === "detail-only"/);
  assert.match(source, /futbeat_enqueue_stale_live_detail/);
});

test('Match API supports actual GOAL array payloads and read-only refresh', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );

  assert.match(source, /Array\.isArray\(lineups\)/);
  assert.match(source, /normalizeStatistics\(payload\.statistics\)/);
  assert.match(source, /Array\.isArray\(value\)/);
  assert.match(source, /requestUrl\.searchParams\.get\('request'\)/);
  assert.match(source, /futbeat_read_match_detail/);
});

test('detail fast lane runs every minute without replacing LIVE cadence', async () => {
  const source = await readFile(
    new URL(
      '../../supabase/migrations/20260919174500_live_detail_fast_lane.sql',
      import.meta.url,
    ),
    'utf8',
  );

  assert.match(source, /futbeat-goal-detail-cron/);
  assert.match(source, /'\* \* \* \* \*'/);
  assert.match(source, /'detail-only'/);
  assert.match(source, /futbeat-goal-live-sync/);
  assert.match(source, /enqueue_stale_interested_match_detail/);
  assert.match(source, /coverage_interests/);
  assert.match(source, /explicit_followers/);
  assert.match(source, /temporary_users/);
  assert.match(source, /interval '8 minutes'/);
});


test('calendar uses fresh cached detail when canonical state is behind', async () => {
  const db = await openDatabase();
  try {
    const localDate = (await db.query(
      "select ((now() at time zone 'America/Costa_Rica')::date)::text value",
    )).rows[0].value;
    const startTime = (await db.query(
      "select (now()-interval '30 minutes')::text value",
    )).rows[0].value;

    const competition = 'fb_comp_cached_live';
    const home = 'fb_team_cached_live_home';
    const away = 'fb_team_cached_live_away';
    const match = 'fb_match_cached_live';

    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'competition',$2)",
      [competition, JSON.stringify({
        id: competition,
        name: 'Cached Live League',
        country: 'Costa Rica',
      })],
    );

    for (const [id, name] of [[home, 'Cached Home'], [away, 'Cached Away']]) {
      await db.query(
        "insert into futbeat_private.entities(id,kind,payload) values($1,'team',$2)",
        [id, JSON.stringify({
          id,
          name,
          country: 'Costa Rica',
          competitionId: competition,
        })],
      );
    }

    const canonical = {
      id: match,
      competitionId: competition,
      homeTeamId: home,
      awayTeamId: away,
      startTime,
      status: 'SCHEDULED',
      score: null,
      events: [],
      statistics: [],
      provenance: {
        source: 'GOAL API',
        externalId: 'cached-live-1',
        receivedAt: startTime,
      },
    };
    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'match',$2)",
      [match, JSON.stringify(canonical)],
    );
    await db.query(
      "insert into futbeat_private.calendar_matches(match_id,start_time,source,updated_at) values($1,$2,'goal_api',now())",
      [match, startTime],
    );
    await db.query(
      "insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload) values($1,'goal_api','cached-live-1',now(),$2)",
      [match, JSON.stringify({
        matchStatus: 'LIVE',
        matchPeriod: 'SECOND_HALF',
        matchElapsed: 61,
        homeTeamScore: '2',
        awayTeamScore: '1',
      })],
    );

    const snapshot = (await db.query(
      "select public.futbeat_read_calendar_range($1::date,$1::date,'America/Costa_Rica') value",
      [localDate],
    )).rows[0].value;
    const visible = snapshot.matches.find((item) => item.id === match);

    assert.ok(visible);
    assert.equal(visible.status, 'LIVE');
    assert.equal(visible.minute, 61);
    assert.deepEqual(visible.score, { home: 2, away: 1 });
  } finally {
    await db.close();
  }
});

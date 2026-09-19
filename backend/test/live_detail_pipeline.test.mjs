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

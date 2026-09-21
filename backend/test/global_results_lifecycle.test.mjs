import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';

function observation(externalMatchId, overrides = {}) {
  const value = {
    externalMatchId,
    status: 'FINISHED_PENDING_VERIFICATION',
    minute: 90,
    score: { home: 2, away: 1 },
    events: [{
      eventKey: `${externalMatchId}:goal:63`,
      type: 'GOAL',
      minute: 63,
      teamExternalId: 'home-provider',
      playerExternalId: null,
      assistExternalId: null,
      payload: { type: 'GOAL', time: '63' },
    }],
    rawPayload: {},
    ...overrides,
  };
  value.payloadHash = createHash('sha256')
    .update(JSON.stringify(value))
    .digest('hex');
  return value;
}

async function seedMatch(db, { date, score = null }) {
  const competition = 'fb_comp_results_test';
  const home = 'fb_team_results_home';
  const away = 'fb_team_results_away';
  const match = 'fb_match_results_test';
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [
    competition,
    JSON.stringify({ id: competition, name: 'Competition', country: 'Test' }),
  ]);
  for (const [id, name] of [[home, 'Home'], [away, 'Away']]) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [
      id, JSON.stringify({ id, name, country: 'Test' }),
    ]);
  }
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [
    match,
    JSON.stringify({
      id: match,
      competitionId: competition,
      homeTeamId: home,
      awayTeamId: away,
      startTime: `${date}T18:00:00.000Z`,
      status: 'SCHEDULED',
      score,
      events: [],
    }),
  ]);
  for (const [kind, external, id] of [
    ['match', 'result-provider-match', match],
    ['team', 'home-provider', home],
    ['team', 'away-provider', away],
  ]) {
    await db.query(
      'insert into futbeat_private.provider_entities values($1,$2,$3,$4)',
      ['goal_api', kind, external, id],
    );
  }
  await db.query(
    "insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count,fixtures_complete,results_complete) values('goal_api',$1,now(),1,true,false)",
    [date],
  );
  return { match };
}

test('grouped historical results close a scheduled match and preserve canonical events', async () => {
  const db = await openDatabase();
  try {
    const date = '2026-08-01';
    const { match } = await seedMatch(db, { date });
    const receivedAt = new Date().toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt, JSON.stringify([observation('result-provider-match')]),
    ]);
    const finalized = (await db.query(
      'select public.futbeat_finalize_goal_results_date($1,$2) value',
      [date, receivedAt],
    )).rows[0].value;
    assert.equal(finalized.updated, 1);
    assert.equal(finalized.resultsComplete, true);
    const payload = (await db.query(
      'select payload from futbeat_private.entities where id=$1', [match],
    )).rows[0].payload;
    assert.equal(payload.status, 'FINISHED_PENDING_VERIFICATION');
    assert.deepEqual(payload.score, { home: 2, away: 1 });
    assert.ok(payload.events.some((event) => event.type === 'GOAL'));
    assert.equal(new Set(payload.events.map((event) => event.id)).size, payload.events.length);
    assert.ok(payload.events.every((event) => /^fb_event_/.test(event.id)));
    const plan = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(plan.allowed, false);
    assert.equal(plan.reason, 'no_results_due');
  } finally {
    await db.close();
  }
});

test('partial terminal result never erases a known score', async () => {
  const db = await openDatabase();
  try {
    const date = '2026-08-02';
    const { match } = await seedMatch(db, { date, score: { home: 3, away: 2 } });
    const receivedAt = new Date().toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt,
      JSON.stringify([observation('result-provider-match', { score: { home: null, away: null }, events: [] })]),
    ]);
    await db.query('select public.futbeat_finalize_goal_results_date($1,$2)', [date, receivedAt]);
    const payload = (await db.query(
      'select payload from futbeat_private.entities where id=$1', [match],
    )).rows[0].payload;
    assert.deepEqual(payload.score, { home: 3, away: 2 });
  } finally {
    await db.close();
  }
});

test('rescheduled historical result moves the calendar day without duplicating the match', async () => {
  const db = await openDatabase();
  try {
    const date = '2026-08-03';
    const moved = '2026-08-04';
    const { match } = await seedMatch(db, { date });
    const receivedAt = new Date().toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt,
      JSON.stringify([observation('result-provider-match', {
        status: 'POSTPONED',
        rawPayload: { kickoffUtc: `${moved}T20:00:00.000Z` },
      })]),
    ]);
    await db.query('select public.futbeat_finalize_goal_results_date($1,$2)', [date, receivedAt]);
    const rows = (await db.query(
      'select match_id,start_time::date::text as provider_day from futbeat_private.calendar_matches where match_id=$1',
      [match],
    )).rows;
    assert.deepEqual(rows, [{ match_id: match, provider_day: moved }]);
  } finally {
    await db.close();
  }
});

test('results worker uses one paginated date endpoint and has no automatic retry', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /\/results\/date\/\$\{providerDate\}\?limit=500&offset=\$\{offset\}/);
  assert.match(source, /pagination == null && data\.length === 500/);
  assert.match(source, /futbeat_finalize_goal_results_date/);
  assert.match(source, /trigger === "results-only"/);
  assert.doesNotMatch(source, /GOAL_RESULTS_DATE_FETCH_FAILED[\s\S]{0,800}(retry|setTimeout)/i);
});

test('player media coverage keeps verified photos and negative-caches confirmed absence', async () => {
  const db = await openDatabase();
  try {
    const available = 'fb_player_media_available';
    const missing = 'fb_player_media_missing';
    for (const [id, media] of [
      [available, {
        url: 'https://media.goal-api.com/players/available.png',
        verificationStatus: 'VERIFIED',
      }],
      [missing, null],
    ]) {
      await db.query("insert into futbeat_private.entities values($1,'player',$2)", [
        id,
        JSON.stringify({ id, name: id, media, provenance: { source: 'GOAL API' } }),
      ]);
    }
    const rows = (await db.query(
      'select player_id,status,retry_after>last_checked_at delayed from futbeat_private.player_media_coverage order by player_id',
    )).rows;
    assert.deepEqual(rows.map(({ player_id, status, delayed }) => ({ player_id, status, delayed })), [
      { player_id: available, status: 'AVAILABLE', delayed: true },
      { player_id: missing, status: 'NOT_AVAILABLE', delayed: true },
    ]);
    await db.query("update futbeat_private.entities set payload=$2 where id=$1", [
      available,
      JSON.stringify({
        id: available,
        name: 'Updated squad row without a photo',
        media: null,
        provenance: { source: 'GOAL API' },
      }),
    ]);
    const preserved = (await db.query(
      'select payload#>>\'{media,url}\' as url from futbeat_private.entities where id=$1',
      [available],
    )).rows[0].url;
    assert.equal(preserved, 'https://media.goal-api.com/players/available.png');
    await db.exec('create role media_outsider; set role media_outsider');
    await assert.rejects(db.query('select * from futbeat_private.player_media_coverage'));
    await db.exec('reset role');
  } finally {
    await db.close();
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { nextResultsOffset } from '../../supabase/functions/_shared/results_pagination.ts';

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

function historicalDate(daysAgo) {

  const value = new Date();
  value.setUTCDate(value.getUTCDate() - daysAgo);
  return value.toISOString().slice(0, 10);
}

async function seedMatch(db, { date, score = null, coverage = true, suffix = '' }) {
  const competition = `fb_comp_results_test${suffix}`;
  const home = `fb_team_results_home${suffix}`;
  const away = `fb_team_results_away${suffix}`;
  const match = `fb_match_results_test${suffix}`;
  const externalMatch = `result-provider-match${suffix}`;
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
      provenance: { receivedAt: `${date}T00:00:00.000Z` },
      score,
      events: [],
    }),
  ]);
  for (const [kind, external, id] of [
    ['match', externalMatch, match],
    ['team', `home-provider${suffix}`, home],
    ['team', `away-provider${suffix}`, away],
  ]) {
    await db.query(
      'insert into futbeat_private.provider_entities values($1,$2,$3,$4)',
      ['goal_api', kind, external, id],
    );
  }
  if (coverage) {
    await db.query(
      "insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count,fixtures_complete,results_complete) values('goal_api',$1,now(),1,true,false)",
      [date],
    );
  }
  return { match, competition, externalMatch };
}

async function insertStoredObservation(db, {
  match, external = 'stored-result', status, receivedAt, kickoffUtc = null,
  home = null, away = null, hashChar = 'a',
}) {
  await db.query(`insert into futbeat_private.provider_observations(
    provider,external_match_id,canonical_match_id,received_at,provider_observed_at,
    status,minute,home_score,away_score,events,payload_hash,raw_payload)
    values('goal_api',$1,$2,$3,$3,$4,90,$5,$6,'[]',$7,$8)`, [
    external, match, receivedAt, status, home, away, hashChar.repeat(64),
    JSON.stringify(kickoffUtc == null ? {} : { kickoffUtc }),
  ]);
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

test('date without coverage is discovered and repaired from stored observations', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2);
    const { match } = await seedMatch(db, { date, coverage: false });
    const receivedAt = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt, JSON.stringify([observation('result-provider-match')]),
    ]);
    const plan = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(plan.allowed, false);
    assert.equal(plan.reason, 'reconciled_locally');
    const payload = (await db.query(
      'select payload from futbeat_private.entities where id=$1', [match],
    )).rows[0].payload;
    assert.equal(payload.status, 'FINISHED_PENDING_VERIFICATION');
    assert.deepEqual(payload.score, { home: 2, away: 1 });
    assert.ok(payload.events.some((event) => event.type === 'GOAL'));
    assert.equal((await db.query(
      'select count(*)::integer count from futbeat_private.calendar_coverage where provider_date=$1',
      [date],
    )).rows[0].count, 0);
  } finally {
    await db.close();
  }
});

test('stored canonical events alone make a completed historical date repairable', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(3);
    const { match } = await seedMatch(db, { date, coverage: false });
    const receivedAt = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt, JSON.stringify([observation('result-provider-match')]),
    ]);
    await db.query(
      "update futbeat_private.entities set payload=jsonb_set(jsonb_set(payload,'{status}','\"VERIFIED\"'::jsonb),'{events}','[]'::jsonb) where id=$1",
      [match],
    );
    const plan = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(plan.allowed, false);
    assert.equal(plan.reason, 'reconciled_locally');
    const events = (await db.query(
      'select payload->\'events\' events from futbeat_private.entities where id=$1',
      [match],
    )).rows[0].events;
    assert.ok(events.some((event) => event.type === 'GOAL'));
  } finally {
    await db.close();
  }
});

test('historical repair exposes every canonical event type in timeline order', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(4);
    const { match } = await seedMatch(db, { date, coverage: false });
    const types = ['YELLOW_CARD', 'RED_CARD', 'SUBSTITUTION', 'VAR', 'MISSED_PENALTY', 'GOAL'];
    const events = types.map((type, index) => ({
      eventKey: `history:${type}`,
      type,
      minute: index === 0 ? 45 : 50 + index,
      extraMinute: index === 0 ? 2 : null,
      teamExternalId: 'home-provider',
      playerExternalId: null,
      assistExternalId: null,
      payload: { type, minute: index === 0 ? 45 : 50 + index, extraMinute: index === 0 ? 2 : null },
    }));
    const receivedAt = new Date().toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt,
      JSON.stringify([observation('result-provider-match', { events })]),
    ]);
    const repaired = (await db.query(
      'select public.futbeat_reconcile_goal_results_local($1) value', [date],
    )).rows[0].value;
    assert.equal(repaired.resultsComplete, true);
    const timeline = (await db.query(
      'select payload->\'events\' events from futbeat_private.entities where id=$1', [match],
    )).rows[0].events;
    assert.ok(types.every((type) => timeline.some((event) => event.type === type)));
    assert.equal(new Set(timeline.map((event) => event.id)).size, timeline.length);
    assert.ok(timeline.every((event) => event.playerId == null));
    assert.deepEqual(timeline.map((event) => [event.minute, event.extraMinute ?? 0]),
      [...timeline].map((event) => [event.minute, event.extraMinute ?? 0])
        .sort((a, b) => a[0] - b[0] || a[1] - b[1]));
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

test('old postponed evidence cannot undo a newer reschedule', async () => {
  const db = await openDatabase();
  try {
    const oldDate = historicalDate(3);
    const newDate = historicalDate(2);
    const { match } = await seedMatch(db, { date: oldDate, coverage: false });
    const canonicalAt = new Date().toISOString();
    await db.query(`update futbeat_private.entities set payload=payload||$2::jsonb where id=$1`, [
      match, JSON.stringify({ status: 'SCHEDULED', startTime: `${newDate}T18:00:00.000Z`, provenance: { receivedAt: canonicalAt } }),
    ]);
    await insertStoredObservation(db, {
      match, status: 'POSTPONED', receivedAt: new Date(Date.now() - 86400000).toISOString(),
      kickoffUtc: `${oldDate}T18:00:00.000Z`,
    });
    await db.query('select public.futbeat_reconcile_goal_results_local($1)', [oldDate]);
    const payload = (await db.query(
      'select payload from futbeat_private.entities where id=$1', [match],
    )).rows[0].payload;
    assert.equal(payload.status, 'SCHEDULED');
    assert.ok(payload.startTime.startsWith(newDate));
    assert.deepEqual((await db.query(
      'select start_time::date::text date from futbeat_private.calendar_matches where match_id=$1', [match],
    )).rows, [{ date: newDate }]);
  } finally {
    await db.close();
  }
});

test('newer finished evidence closes suspended, while finished never degrades', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2);
    const { match } = await seedMatch(db, { date, coverage: false });
    await db.query(`update futbeat_private.entities set payload=payload||$2::jsonb where id=$1`, [
      match, JSON.stringify({ status: 'SUSPENDED', provenance: { receivedAt: new Date(Date.now() - 86400000).toISOString() } }),
    ]);
    await insertStoredObservation(db, {
      match, status: 'FINISHED_PENDING_VERIFICATION', receivedAt: new Date().toISOString(), home: 2, away: 1,
    });
    await db.query('select public.futbeat_reconcile_goal_results_local($1)', [date]);
    assert.equal((await db.query(
      'select payload->>\'status\' status from futbeat_private.entities where id=$1', [match],
    )).rows[0].status, 'FINISHED_PENDING_VERIFICATION');
    await insertStoredObservation(db, {
      match, external: 'newer-postponed', status: 'POSTPONED', receivedAt: new Date(Date.now() + 1000).toISOString(), hashChar: 'b',
    });
    await db.query('select public.futbeat_reconcile_goal_results_local($1)', [date]);
    assert.equal((await db.query(
      'select payload->>\'status\' status from futbeat_private.entities where id=$1', [match],
    )).rows[0].status, 'FINISHED_PENDING_VERIFICATION');
  } finally {
    await db.close();
  }
});

test('results pagination advances through envelopes and cached full pages', () => {
  assert.equal(nextResultsOffset({
    pagination: { limit: 500, offset: 0, total: 501, hasMore: true },
    rowCount: 500, added: 500, currentOffset: 0,
  }), 500);
  assert.equal(nextResultsOffset({
    pagination: null, rowCount: 500, added: 500, currentOffset: 0,
  }), 500);
  assert.equal(nextResultsOffset({
    pagination: { limit: 500, offset: 500, total: 501, hasMore: false },
    rowCount: 1, added: 1, currentOffset: 500,
  }), null);
  assert.throws(() => nextResultsOffset({
    pagination: { limit: 500, offset: 500, total: 1000, hasMore: true },
    rowCount: 500, added: 0, currentOffset: 500,
  }), /cannot make progress/);
  let offset = 0;
  offset = nextResultsOffset({ pagination: { hasMore: true, limit: 500 }, rowCount: 500, added: 500, currentOffset: offset });
  offset = nextResultsOffset({ pagination: { hasMore: true, limit: 500 }, rowCount: 500, added: 500, currentOffset: offset });
  assert.equal(offset, 1000);
  assert.equal(nextResultsOffset({
    pagination: { hasMore: false, limit: 500 }, rowCount: 118, added: 118, currentOffset: offset,
  }), null);
  assert.equal(nextResultsOffset({
    pagination: { hasMore: true, limit: 500 }, rowCount: 100, added: 100, currentOffset: 0,
  }), 100);
  assert.equal(nextResultsOffset({
    pagination: { total: 600 }, rowCount: 100, added: 100, currentOffset: 0,
  }), 100);
  assert.equal(nextResultsOffset({
    pagination: {}, rowCount: 100, added: 100, currentOffset: 0,
  }), null);
  assert.equal(nextResultsOffset({
    pagination: null, rowCount: 100, added: 100, currentOffset: 0,
  }), null);
  assert.equal(nextResultsOffset({
    pagination: {}, rowCount: 0, added: 0, currentOffset: 0,
  }), null);
  assert.equal(nextResultsOffset({
    pagination: { offset: 0, hasMore: true }, rowCount: 100, added: 100, currentOffset: 100,
  }), 200);
  assert.throws(() => nextResultsOffset({
    pagination: { hasMore: true }, rowCount: 100, added: 0, currentOffset: 100,
  }), /cannot make progress/);
});

test('canonical relevance sample keeps major competitions above secondary tiers', async () => {
  const db = await openDatabase();
  try {
    const samples = [
      ['Champions League', 'Europe', 970],
      ['Premier League', 'England', 930],
      ['LaLiga', 'Spain', 920],
      ['Serie A', 'Italy', 910],
      ['Bundesliga', 'Germany', 900],
      ['Copa Libertadores', 'CONMEBOL', 950],
      ['Liga Promerica', 'Costa Rica', 660],
      ['Segunda División', 'Costa Rica', 100],
      ['Liga 2', 'Spain', 100],
      ['Second League', 'England', 100],
    ];
    for (const [name, country, expected] of samples) {
      const score = (await db.query(
        'select futbeat_private.competition_relevance_score($1,$2) score',
        [name, country],
      )).rows[0].score;
      assert.equal(score, expected, `${name} (${country})`);
    }
  } finally {
    await db.close();
  }
});

test('calendar RPC preserves editorial competition metadata across provider upserts', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(1);
    const { competition } = await seedMatch(db, { date });
    await db.query(`update futbeat_private.competition_editorial_metadata set
      competition_class='domestic_league',domestic_tier=1,is_primary_domestic=true,
      audience_class='open',relevance_score=930,is_global_relevant=true,
      country_code='GB',source='editorial'
      where competition_id=$1`, [competition]);
    await db.query(`insert into futbeat_private.entities(id,kind,payload)
      values($1,'competition',$2) on conflict(id) do update set payload=excluded.payload`, [
      competition,
      JSON.stringify({ id: competition, name: 'Provider replacement', country: 'England' }),
    ]);
    const payload = (await db.query(
      'select public.futbeat_read_calendar_range($1,$1,$2) value',
      [date, 'UTC'],
    )).rows[0].value;
    const row = payload.competitions.find((item) => item.id === competition);
    assert.equal(row.relevanceScore, 930);
    assert.equal(row.competitionClass, 'domestic_league');
    assert.equal(row.domesticTier, 1);
    assert.equal(row.isPrimaryDomestic, true);
    assert.equal(row.isGlobalRelevant, true);
    assert.equal(row.countryCode, 'GB');
    assert.equal(row.relevanceSource, 'editorial');
  } finally {
    await db.close();
  }
});

test('planner records cooldown without coverage and lets another date advance', async () => {
  const db = await openDatabase();
  try {
    const firstDate = historicalDate(1);
    const secondDate = historicalDate(2);
    await seedMatch(db, { date: firstDate, coverage: false });
    await seedMatch(db, { date: secondDate, coverage: false, suffix: '_2' });
    const first = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(first.allowed, true);
    const second = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(second.allowed, true);
    assert.notEqual(second.date, first.date);
    const attempts = (await db.query(
      'select provider_date::text date,attempt_count,next_retry_at>now() cooling from futbeat_private.results_date_attempts order by provider_date',
    )).rows;
    assert.equal(attempts.length, 2);
    assert.ok(attempts.every((row) => row.attempt_count === 1 && row.cooling));
    const blocked = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(blocked.allowed, false);
    assert.equal(blocked.reason, 'no_results_due');
  } finally {
    await db.close();
  }
});

test('local repair is quota-independent, idempotent, and old dates stay outside automation', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2);
    const { match } = await seedMatch(db, { date, coverage: false });
    const receivedAt = new Date().toISOString();
    await db.query('select public.futbeat_record_live_batch($1,$2,$3)', [
      'goal_api', receivedAt, JSON.stringify([observation('result-provider-match')]),
    ]);
    await db.query(`insert into futbeat_private.provider_call_ledger(
      provider,call_kind,trigger_source,reserved_at,status,provider_remaining)
      values('goal_api','test','test',now(),'SUCCEEDED',0)`);
    const plan = (await db.query(
      "select public.futbeat_reserve_goal_results_date('test') value",
    )).rows[0].value;
    assert.equal(plan.reason, 'reconciled_locally');
    const again = (await db.query(
      'select public.futbeat_reconcile_goal_results_local($1) value', [date],
    )).rows[0].value;
    assert.equal(again.updated, 0);
    assert.equal((await db.query(
      'select payload->>\'status\' status from futbeat_private.entities where id=$1', [match],
    )).rows[0].status, 'FINISHED_PENDING_VERIFICATION');

    const oldDate = historicalDate(20);
    await seedMatch(db, { date: oldDate, coverage: false, suffix: '_old' });
    assert.equal((await db.query(
      'select public.futbeat_next_goal_results_candidate() candidate',
    )).rows[0].candidate, null);
  } finally {
    await db.close();
  }
});

test('repeated unresolved fixture closes internally as missing without inventing a score', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(3);
    const { match } = await seedMatch(db, { date });
    await db.query(`insert into futbeat_private.results_date_attempts(
      provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at)
      values('goal_api',$1,now(),4,'PARTIAL',now())`, [date]);
    const repaired = (await db.query(
      'select public.futbeat_reconcile_goal_results_local($1) value', [date],
    )).rows[0].value;
    assert.equal(repaired.resultsComplete, true);
    assert.equal((await db.query(
      'select state from futbeat_private.match_result_reconciliation where match_id=$1', [match],
    )).rows[0].state, 'missing_from_provider');
    const payload = (await db.query(
      'select payload from futbeat_private.entities where id=$1', [match],
    )).rows[0].payload;
    assert.equal(payload.status, 'SCHEDULED');
    assert.equal(payload.score, null);
    assert.equal((await db.query(
      "select results_complete from futbeat_private.calendar_coverage where provider='goal_api' and provider_date=$1", [date],
    )).rows[0].results_complete, true);
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
  assert.match(source, /nextResultsOffset/);
  assert.match(source, /page === 4/);
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

test('closed date reopens for a new fixture, relocated fixture, and late missing evidence', async () => {
 const db=await openDatabase();
 try {
  const date=historicalDate(3);
  const first=await seedMatch(db,{date,coverage:false});
  await insertStoredObservation(db,{match:first.match,status:'VERIFIED',receivedAt:new Date().toISOString(),home:1,away:0});
  const plan=async()=> (await db.query("select public.futbeat_reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal((await plan()).reason,'reconciled_locally');
  assert.equal((await plan()).reason,'no_results_due');
  await seedMatch(db,{date,coverage:false,suffix:'_late'});
  assert.equal((await plan()).allowed,true);
  await db.query("update futbeat_private.results_date_attempts set attempt_count=4,next_retry_at=now() where provider_date=$1",[date]);
  assert.equal((await plan()).reason,'reconciled_locally');
  assert.equal((await plan()).reason,'no_results_due');
  await insertStoredObservation(db,{match:'fb_match_results_test_late',status:'FINISHED_PENDING_VERIFICATION',receivedAt:new Date().toISOString(),home:3,away:1,hashChar:'b'});
  assert.equal((await plan()).reason,'reconciled_locally');
  const repaired=(await db.query("select payload from futbeat_private.entities where id='fb_match_results_test_late'")).rows[0].payload;
  assert.equal(repaired.status,'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(repaired.score,{home:3,away:1});
  const moved=await seedMatch(db,{date:historicalDate(1),coverage:false,suffix:'_moved'});
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb($2::text)) where id=$1",[moved.match,date+'T20:00:00Z']);
  assert.equal((await plan()).date,date);
 } finally {await db.close();}
});

test('quota defer repairs once, records no provider attempt, and obeys 30 minute cooldown',async()=>{
 const db=await openDatabase();
 try {
  const date=historicalDate(2);
  const fixed=await seedMatch(db,{date,coverage:false});
  await seedMatch(db,{date,coverage:false,suffix:'_pending'});
  await insertStoredObservation(db,{match:fixed.match,status:'VERIFIED',receivedAt:new Date().toISOString(),home:2,away:0});
  await db.query("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,status,provider_remaining) values('goal_api','test','test',now(),'SUCCEEDED',0)");
  const plan=async()=> (await db.query("select public.futbeat_reserve_goal_results_date('test') v")).rows[0].v;
  const first=await plan();
  assert.equal(first.reason,'results_quota_guard');
  assert.equal(first.localRepair.updated,1);
  assert.equal((await plan()).reason,'no_results_due');
  assert.equal((await plan()).reason,'no_results_due');
  const attempt=(await db.query("select attempt_count,last_outcome,next_retry_at>now() and next_retry_at<=now()+interval '30 minutes' cooldown from futbeat_private.results_date_attempts")).rows[0];
  assert.deepEqual(attempt,{attempt_count:0,last_outcome:'QUOTA_DEFERRED',cooldown:true});
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='results-date'")).rows[0].n,0);
 } finally {await db.close();}
});

test('second local repair performs zero entity or reconciliation row updates',async()=>{
 const db=await openDatabase();
 try {
  const date=historicalDate(2);
  const {match}=await seedMatch(db,{date});
  await insertStoredObservation(db,{match,status:'VERIFIED',receivedAt:new Date().toISOString(),home:2,away:1});
  await db.query("select public.futbeat_reconcile_goal_results_local($1)",[date]);
  await db.exec(`create table public.audit_writes(n int);
    create function public.audit_write() returns trigger language plpgsql as $$begin insert into public.audit_writes values(1); return new; end$$;
    create trigger audit_entity after update on futbeat_private.entities for each row execute function public.audit_write();
    create trigger audit_reconciliation after update on futbeat_private.match_result_reconciliation for each row execute function public.audit_write();`);
  assert.equal((await db.query("select public.futbeat_reconcile_goal_results_local($1) v",[date])).rows[0].v.updated,0);
  assert.equal((await db.query("select count(*)::int n from public.audit_writes")).rows[0].n,0);
 } finally {await db.close();}
});

test('reschedule without provenance rejects old postponed observation on CURRENT date and batch finalizer',async()=>{
 const db=await openDatabase();
 try {
  const oldDate=historicalDate(3), newDate=historicalDate(2);
  const {match}=await seedMatch(db,{date:oldDate});
  await insertStoredObservation(db,{match,status:'POSTPONED',receivedAt:new Date(Date.now()-86400000).toISOString(),kickoffUtc:oldDate+'T18:00:00Z'});
  await db.query("update futbeat_private.entities set payload=(payload-'provenance')||$2::jsonb where id=$1",[match,JSON.stringify({status:'SCHEDULED',startTime:newDate+'T18:00:00Z'})]);
  await db.query("select public.futbeat_reconcile_goal_results_local($1)",[newDate]);
  await db.query("select public.futbeat_finalize_goal_results_date($1,now())",[newDate]);
  const payload=(await db.query("select payload from futbeat_private.entities where id=$1",[match])).rows[0].payload;
  assert.equal(payload.status,'SCHEDULED');
  assert.equal(payload.startTime,newDate+'T18:00:00Z');
  for(const [date,n] of [[oldDate,0],[newDate,1]]){
   const snapshot=(await db.query("select public.futbeat_read_calendar_range($1,$1,'UTC') v",[date])).rows[0].v;
   assert.equal(snapshot.matches.filter(m=>m.id===match).length,n);
   if(n===1) assert.equal(snapshot.matches.find(m=>m.id===match).status,'SCHEDULED');
  }
 } finally {await db.close();}
});

test('cancelled stays strong; newer live evidence resumes suspended without requiring kickoff',async()=>{
 const db=await openDatabase();
 try {
  const date=historicalDate(1);
  const {match}=await seedMatch(db,{date,coverage:false});
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{status}','\"CANCELLED\"') where id=$1",[match]);
  await insertStoredObservation(db,{match,status:'VERIFIED',receivedAt:new Date().toISOString(),home:3,away:0,kickoffUtc:historicalDate(0)+'T20:00:00Z'});
  await db.query("select public.futbeat_reconcile_goal_results_local($1)",[date]);
  let payload=(await db.query("select payload from futbeat_private.entities where id=$1",[match])).rows[0].payload;
  assert.equal(payload.status,'CANCELLED'); assert.ok(payload.startTime.startsWith(date));
  const resumed=await seedMatch(db,{date,coverage:false,suffix:'_suspended'});
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{status}','\"SUSPENDED\"') where id=$1",[resumed.match]);
  await insertStoredObservation(db,{match:resumed.match,external:'resumed',status:'LIVE',receivedAt:new Date().toISOString(),hashChar:'c'});
  await db.query("select public.futbeat_reconcile_goal_results_local($1)",[date]);
  payload=(await db.query("select payload from futbeat_private.entities where id=$1",[resumed.match])).rows[0].payload;
  assert.equal(payload.status,'LIVE');
 } finally {await db.close();}
});

test('persistent editorial seed applies to tomorrow ingestion; region and audience alone never confer global priority',async()=>{
 const db=await openDatabase();
 try {
  const rows=[
   ['known','UEFA Champions League','Europe',{},true,'editorial'],
   ['friendly','Club Friendlies','World',{},false,'derived'],
   ['youth','UEFA Youth League','Europe',{audienceClass:'youth'},false,'provider'],
   ['women',"UEFA Women's Champions League",'Europe',{audienceClass:'women',isGlobalRelevant:true},false,'provider'],
   ['reserve','Premier League','England',{audienceClass:'reserve'},false,'provider'],
   ['unknown','Unknown League','Japan',{},false,'derived']
  ];
  for(const [id,name,country,extra,global,source] of rows){
   await db.query("insert into futbeat_private.entities values($1,'competition',$2)",['fb_comp_'+id,JSON.stringify({id:'fb_comp_'+id,name,country,...extra})]);
   const metadata=(await db.query("select * from futbeat_private.competition_editorial_metadata where competition_id=$1",['fb_comp_'+id])).rows[0];
   assert.equal(metadata.is_global_relevant,global,id); assert.equal(metadata.source,source,id);
   if(id!=='known') assert.equal(metadata.is_primary_domestic,false,id);
  }
  assert.equal((await db.query("select count(*)::int n from futbeat_private.country_catalog where length(country_code)=2 and country_code<>'XK'")).rows[0].n,249);
  for(const [country,code] of [['Japan','JP'],['South Africa','ZA'],['Panamá','PA'],['England','GB-ENG'],['Scotland','GB-SCT'],['Wales','GB-WLS'],['Northern Ireland','GB-NIR'],['Colombia','CO']]){
   assert.equal((await db.query("select futbeat_private.resolve_country_code($1) code",[country])).rows[0].code,code);
  }
 } finally {await db.close();}
});

test('safe event minute normalization and internal helpers deny client execute',async()=>{
 const db=await openDatabase();
 try {
  for(const value of ['45+2','HT',null,'99999999999999999999']){
   assert.equal((await db.query("select futbeat_private.safe_result_integer($1) n",[value])).rows[0].n,null);
  }
  for(const signature of [
   'resolve_country_code(text)', 'sync_competition_metadata()',
   'results_retry_delay(date,integer)', 'safe_result_integer(text)',
   'try_timestamptz(text)', 'competition_relevance_score(text,text)',
   'apply_competition_relevance()', 'preserve_verified_player_media()',
   'track_player_media_coverage()', 'reconcile_goal_results_local(date)',
   'next_goal_results_candidate()', 'reserve_goal_results_date(text)',
   'finalize_goal_results_date(date,timestamptz)',
   'complete_results_date_attempt(date,text,integer,integer)',
   'normalize_event_minutes(jsonb)', 'normalize_event_array(jsonb)',
   'normalize_canonical_event_contract()',
  ]){
   for(const role of ['anon','authenticated']){
    assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') permitted",[role,'futbeat_private.'+signature])).rows[0].permitted,false);
   }
  }
  const date=historicalDate(2),{match}=await seedMatch(db,{date,coverage:false});
  for(const [i,minute] of ['45+2','HT',null].entries()){
   const id='fb_event_malformed_'+i;
   await db.query("insert into futbeat_private.canonical_events values($1,$2,'goal_api','GOAL',$3,false,now())",[id,match,JSON.stringify({id,matchId:match,type:'GOAL',minute,extraMinute:'HT'})]);
  }
  await db.query("select public.futbeat_reconcile_goal_results_local($1)",[date]);
  assert.equal((await db.query("select jsonb_array_length(payload->'events') n from futbeat_private.entities where id=$1",[match])).rows[0].n,3);
 } finally {await db.close();}
});

test('closed date reopens for corrected final score and late canonical events', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2), { match } = await seedMatch(db, { date, coverage: false });
    await insertStoredObservation(db, { match, status: 'VERIFIED', receivedAt: new Date(Date.now()-1000).toISOString(), home: 1, away: 0 });
    const plan = async () => (await db.query("select public.futbeat_reserve_goal_results_date('test') v")).rows[0].v;
    assert.equal((await plan()).reason, 'reconciled_locally');
    assert.equal((await plan()).reason, 'no_results_due');
    await insertStoredObservation(db, { match, status: 'FINISHED_PENDING_VERIFICATION', receivedAt: new Date().toISOString(), home: 3, away: 1, hashChar: 'd' });
    assert.equal((await plan()).reason, 'reconciled_locally');
    let payload = (await db.query('select payload from futbeat_private.entities where id=$1', [match])).rows[0].payload;
    assert.equal(payload.status, 'VERIFIED');
    assert.deepEqual(payload.score, { home: 3, away: 1 });
    await db.query("insert into futbeat_private.canonical_events values('fb_event_late_goal',$1,'goal_api','GOAL',$2,false,now())", [match, JSON.stringify({id:'fb_event_late_goal', matchId:match, type:'GOAL', minute:90})]);
    assert.equal((await plan()).reason, 'reconciled_locally');
    payload = (await db.query('select payload from futbeat_private.entities where id=$1', [match])).rows[0].payload;
    assert.equal(payload.events.length, 1);
    assert.equal((await plan()).reason, 'no_results_due');
  } finally { await db.close(); }
});

test('planner uses UTC index ranges and attempts older than 90 days are pruned', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(14);
    await seedMatch(db, { date, coverage:false, suffix:'_boundary' });
    await seedMatch(db, { date:historicalDate(15), coverage:false, suffix:'_outside' });
    await seedMatch(db, { date:historicalDate(0), coverage:false, suffix:'_today' });
    for (const zone of ['Pacific/Kiritimati', 'Pacific/Honolulu', 'UTC']) {
      await db.query("select set_config('TimeZone',$1,false)", [zone]);
      assert.equal((await db.query('select public.futbeat_next_goal_results_candidate()::text d')).rows[0].d, date);
    }
    const source = (await db.query("select prosrc from pg_proc where oid='futbeat_private.next_goal_results_candidate()'::regprocedure")).rows[0].prosrc;
    assert.doesNotMatch(source, /start_time\s*::\s*date/i);
    await db.exec('set enable_seqscan=off');
    const plan = await db.query('explain (format json) '+source);
    assert.match(JSON.stringify(plan.rows), /calendar_matches_start_time_idx/);
    await db.query("insert into futbeat_private.results_date_attempts(provider,provider_date) values('goal_api',$1),('goal_api',$2)", [historicalDate(91),historicalDate(90)]);
    await db.query("select public.futbeat_reserve_goal_results_date('test')");
    assert.equal((await db.query("select count(*)::int n from futbeat_private.results_date_attempts where provider_date=$1", [historicalDate(91)])).rows[0].n, 0);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.results_date_attempts where provider_date=$1", [historicalDate(90)])).rows[0].n, 1);
    const indexes=(await db.query("select indexname from pg_indexes where schemaname='futbeat_private' and tablename in ('competition_editorial_metadata','results_date_attempts')")).rows.map(r=>r.indexname);
    assert.ok(!indexes.includes('competition_editorial_country_idx'));
    assert.ok(!indexes.includes('results_date_attempts_due_idx'));
  } finally { await db.close(); }
});

test('empty pagination envelope probes a full page and respects explicit end',()=>{
 assert.equal(nextResultsOffset({pagination:{},rowCount:500,added:500,currentOffset:0}),500);
 assert.equal(nextResultsOffset({pagination:{limit:100},rowCount:100,added:100,currentOffset:100}),200);
 assert.equal(nextResultsOffset({pagination:{},rowCount:118,added:118,currentOffset:1000}),null);
 assert.equal(nextResultsOffset({pagination:{hasMore:false},rowCount:500,added:500,currentOffset:0}),null);
 assert.throws(()=>nextResultsOffset({pagination:{},rowCount:500,added:0,currentOffset:500}),/cannot make progress/);
});

test('canonical hash is stable by JSONB identity and reopens on functional changes', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2), { match } = await seedMatch(db, { date, coverage: false });
    await db.query("update futbeat_private.entities set payload=payload||'{\"status\":\"VERIFIED\"}'::jsonb where id=$1", [match]);
    const plan = async () => (await db.query("select public.futbeat_reserve_goal_results_date('test') v")).rows[0].v;
    const row = async () => (await db.query('select canonical_payload_hash,updated_at from futbeat_private.match_result_reconciliation where match_id=$1', [match])).rows[0];
    assert.equal((await plan()).reason, 'reconciled_locally');
    let previous = await row();
    assert.match(previous.canonical_payload_hash, /^[0-9a-f]{32}$/);
    await db.query('select public.futbeat_reconcile_goal_results_local($1)', [date]);
    assert.deepEqual(await row(), previous);
    for (const patch of [
      {score:{home:3,away:1}}, {status:'CANCELLED'},
      {events:[{id:'fb_event_hash',type:'GOAL',minute:45}]},
      {statistics:[{type:'possession',home:55,away:45}]},
      {startTime:date+'T21:00:00Z'},
    ]) {
      await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [match, JSON.stringify(patch)]);
      assert.equal((await plan()).reason, 'reconciled_locally');
      const current = await row();
      assert.notEqual(current.canonical_payload_hash, previous.canonical_payload_hash);
      assert.equal((await plan()).reason, 'no_results_due');
      previous = current;
    }
    const a = '{"status":"VERIFIED","score":{"home":3,"away":1}}';
    const b = '{ "score": { "away": 1, "home": 3 }, "status": "VERIFIED" }';
    assert.equal((await db.query('select md5($1::jsonb::text)=md5($2::jsonb::text) same', [a,b])).rows[0].same, true);
    assert.equal((await db.query("select count(*)::int n from information_schema.columns where table_schema='futbeat_private' and table_name='match_result_reconciliation' and column_name='canonical_payload'")).rows[0].n, 0);
  } finally { await db.close(); }
});

test('reconciliation retention removes only dates older than 90 UTC days with an index', async () => {
  const db = await openDatabase();
  try {
    for (const age of [120,91,60,10]) {
      const date = historicalDate(age);
      const {match} = await seedMatch(db, {date, coverage:false, suffix:'_retention_'+age});
      await db.query("update futbeat_private.entities set payload=payload||$2::jsonb where id=$1", [match, JSON.stringify({status:'VERIFIED'})]);
      await db.query('select public.futbeat_reconcile_goal_results_local($1)', [date]);
    }
    await db.query("select public.futbeat_reserve_goal_results_date('test')");
    const rows = (await db.query('select provider_date::text d from futbeat_private.match_result_reconciliation order by provider_date')).rows;
    assert.deepEqual(rows.map(r=>r.d), [historicalDate(60),historicalDate(10)]);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='match'")).rows[0].n, 4);
    await db.exec('set enable_seqscan=off');
    const plan = await db.query("explain (format json) delete from futbeat_private.match_result_reconciliation where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90");
    assert.match(JSON.stringify(plan.rows), /match_result_reconciliation_date_idx/);
  } finally { await db.close(); }
});

test('event minutes are typed at canonical, entity, detail, and calendar boundaries', async () => {
  const db = await openDatabase();
  try {
    const date = historicalDate(2), {match} = await seedMatch(db, {date, coverage:false});
    const inputs = ['45','45+2','90+5','HT',null, '999999999999999999999'];
    const expected = [[45,null],[45,2],[90,5],[null,null],[null,null],[null,null]];
    for (const [i,minute] of inputs.entries()) {
      const event = {id:'fb_event_typed_'+i, matchId:match, type:'GOAL', minute};
      await db.query("insert into futbeat_private.canonical_events values($1,$2,'goal_api','GOAL',$3,false,now())", [event.id,match,JSON.stringify(event)]);
      const payload = (await db.query('select payload from futbeat_private.canonical_events where id=$1', [event.id])).rows[0].payload;
      assert.deepEqual([payload.minute,payload.extraMinute], expected[i]);
    }
    const events = inputs.map((minute,i)=>({id:'fb_event_typed_'+i,matchId:match,type:'GOAL',minute}));
    await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{events}',$2::jsonb) where id=$1", [match,JSON.stringify(events)]);
    await db.query("insert into futbeat_private.match_detail_cache values($1,'goal_api','typed',now(),$2)", [match,JSON.stringify({events})]);
    for (const table of ['entities','match_detail_cache']) {
      const column = table==='entities'?'id':'match_id';
      const stored = (await db.query('select payload from futbeat_private.'+table+' where '+column+'=$1',[match])).rows[0].payload.events;
      assert.deepEqual(stored.map(e=>[e.minute,e.extraMinute]), expected);
    }
    await db.query('select public.futbeat_reconcile_goal_results_local($1)', [date]);
    const snapshot=(await db.query("select public.futbeat_read_calendar_range($1,$1,'UTC') v", [date])).rows[0].v;
    assert.ok(snapshot.matches[0].events.every(e=>e.minute===null||Number.isInteger(e.minute)));
    assert.ok(snapshot.matches[0].events.every(e=>e.extraMinute===null||Number.isInteger(e.extraMinute)));
    const once=(await db.query('select public.futbeat_reconcile_goal_results_local($1) v',[date])).rows[0].v;
    assert.equal(once.updated,0);
  } finally { await db.close(); }
});

test('expanded editorial seed matches verified catalog identities and future domestic ingestion', async () => {
  const db = await openDatabase();
  try {
    const catalog = JSON.parse(await readFile(new URL('./fixtures/editorial_catalog.json', import.meta.url),'utf8'));
    for (const c of catalog) {
      await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [c.id,JSON.stringify({id:c.id,name:c.name,country:c.country})]);
      const meta=(await db.query('select * from futbeat_private.competition_editorial_metadata where competition_id=$1',[c.id])).rows[0];
      assert.deepEqual([meta.country_code,meta.competition_class,meta.domestic_tier,meta.is_primary_domestic,meta.is_global_relevant,meta.audience_class,meta.relevance_score,meta.source],
        [c.code,c.cls,c.tier,c.primary,c.global,'open',c.score,'editorial'], c.name+' / '+c.country);
      if(c.tier===2) { assert.equal(meta.is_primary_domestic,false); assert.equal(meta.is_global_relevant,false); }
      if(c.tier===1) {
        const id=c.id+'_future';
        await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[id,JSON.stringify({id,name:c.name,country:c.country})]);
        assert.equal((await db.query('select is_primary_domestic from futbeat_private.competition_editorial_metadata where competition_id=$1',[id])).rows[0].is_primary_domestic,true,c.name);
      }
    }
    for (const audience of ['women','youth','reserve','amateur']) {
      const id='fb_comp_editorial_negative_'+audience;
      await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[id,JSON.stringify({id,name:'Serie A',country:'Italy',audienceClass:audience,relevanceScore:1000,isGlobalRelevant:true})]);
      const meta=(await db.query('select * from futbeat_private.competition_editorial_metadata where competition_id=$1',[id])).rows[0];
      assert.equal(meta.is_primary_domestic,false); assert.equal(meta.is_global_relevant,false);
      assert.equal(meta.audience_class,audience);
    }
    assert.equal((await db.query('select count(*)::int n from futbeat_private.competition_editorial_seed')).rows[0].n,54);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.competition_editorial_metadata where is_global_relevant and source<>'editorial'")).rows[0].n,0);
  } finally { await db.close(); }
});

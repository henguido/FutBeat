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
  // Lineup/statistics normalizers live in _shared/match_detail.ts (behavior is
  // covered by match_detail_normalizers.test.mjs); the handler wires them up.
  const source = (await Promise.all([
    'futbeat-api/index.ts', '_shared/match_detail.ts',
  ].map((file) => readFile(new URL(`../../supabase/functions/${file}`, import.meta.url), 'utf8')))).join('\n');

  assert.match(source, /Array\.isArray\(lineups\)/);
  assert.match(source, /normalizeStatistics\(payload\.statistics\)/);
  assert.match(source, /Array\.isArray\(value\)/);
  assert.match(source, /requestUrl\.searchParams\.get\('request'\)/);
  assert.match(source, /futbeat_read_match_detail/);
  assert.match(source, /homeScorerId/);
  assert.match(source, /assistPlayerId/);
  assert.match(source, /homePlayerId/);
  assert.match(source, /outPlayerId/);
  assert.match(source, /inPlayerId/);
  assert.match(source, /playerRating/);
  assert.match(source, /value === 'coach'/);
  assert.match(source, /row\.playerId\).*row\.playerKey/);
  assert.match(source, /futbeat_read_lineup_player_media/);
  assert.match(source, /safeImage\(canonical\.image\)/);
});

test('detail ingestion resolves lineup playerKey identities without names as keys', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /clean\(row\.playerId\) \|\| clean\(row\.playerKey\)/);
  assert.match(source, /futbeat_resolve_global_entities/);
  assert.match(source, /type\.startsWith\("start"\) \|\| type\.startsWith\("sub"\)/);
});

test('newer partial detail preserves richer lineups and canonical verified media', async () => {
  const db = await openDatabase();
  try {
    const match = 'fb_match_rich_detail';
    const player = 'fb_player_rich_detail';
    await db.query("insert into futbeat_private.entities values($1,'match',$2),($3,'player',$4)", [
      match, JSON.stringify({ id: match }), player,
      JSON.stringify({ id: player, name: 'Jugador real', media: {
        url: 'https://media.goal-api.com/players/real.png', verificationStatus: 'VERIFIED',
      } }),
    ]);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','match','detail-1',$1),('goal_api','player','player-key-1',$2)", [match, player]);
    const rich = { lineups: [
      { type: 'starting_lineups', team: 'home', playerKey: 'player-key-1', lineupPlayer: 'Jugador real' },
      { type: 'substitutes', team: 'home', playerKey: 'player-key-2', lineupPlayer: 'Suplente real' },
    ], statistics: [{ type: 'Shots', home: 4, away: 2 }], homeTeamScore: '1', awayTeamScore: '0' };
    await db.query("select futbeat_private.store_match_detail($1,'detail-1',now()-interval '1 minute',$2)", [match, JSON.stringify(rich)]);
    await db.query("select futbeat_private.store_match_detail($1,'detail-1',now(),$2)", [match, JSON.stringify({ lineups: [{ type: 'coach', team: 'home', lineupPlayer: 'Coach' }], statistics: [] })]);

    const cached = (await db.query('select payload from futbeat_private.match_detail_cache where match_id=$1', [match])).rows[0].payload;
    assert.equal(cached.lineups.length, 2);
    assert.equal(cached.statistics.length, 1);
    assert.equal(cached.homeTeamScore, '1');
    const media = (await db.query("select public.futbeat_read_lineup_player_media('goal_api',array['player-key-1','missing']) value")).rows[0].value;
    assert.equal(media['player-key-1'].canonicalId, player);
    assert.equal(media['player-key-1'].image, 'https://media.goal-api.com/players/real.png');
    assert.deepEqual(media.missing, { providerId: 'missing', canonicalId: null, image: null });
  } finally {
    await db.close();
  }
});

test('calendar field merge keeps a valid canonical score beside newer status data', async () => {
  const db = await openDatabase();
  try {
    // Calendar day of the kickoff (not of now): stable around local midnight.
    const day = (await db.query("select (((now()-interval '30 minutes') at time zone 'America/Costa_Rica')::date)::text value")).rows[0].value;
    const ids = ['fb_comp_field_merge','fb_team_field_home','fb_team_field_away'];
    await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [ids[0], JSON.stringify({ id: ids[0], name: 'Liga', country: 'Costa Rica' })]);
    for (const id of ids.slice(1)) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name: id, competitionId: ids[0] })]);
    const match = 'fb_match_field_merge';
    const start = (await db.query("select (now()-interval '30 minutes')::text value")).rows[0].value;
    await db.query("insert into futbeat_private.entities values($1,'match',$2)", [match, JSON.stringify({ id: match, competitionId: ids[0], homeTeamId: ids[1], awayTeamId: ids[2], startTime: start, status: 'SCHEDULED', score: { home: 2, away: 1 }, events: [], statistics: [] })]);
    await db.query("insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,last_payload_hash,first_seen_at,last_seen_at,changed_at) values('goal_api','field-merge',$1,'LIVE',70,$2,now(),now(),now())", [match, 'c'.repeat(64)]);
    const snapshot = (await db.query("select public.futbeat_read_calendar_range($1::date,$1::date,'America/Costa_Rica') value", [day])).rows[0].value;
    const visible = snapshot.matches.find((item) => item.id === match);
    assert.equal(visible.status, 'LIVE');
    assert.deepEqual(visible.score, { home: 2, away: 1 });
    assert.equal(visible.startTime, start);
  } finally {
    await db.close();
  }
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
      // Calendar day of the kickoff (not of now): stable around local midnight.
      "select (((now()-interval '30 minutes') at time zone 'America/Costa_Rica')::date)::text value",
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

test('calendar reconciliation expires stale LIVE and never reopens a terminal match', async () => {
  const db = await openDatabase();
  try {
    const day = (await db.query(
      // Calendar day of the kickoff (not of now): stable around local midnight.
      "select (((now()-interval '1 hour') at time zone 'America/Costa_Rica')::date)::text value",
    )).rows[0].value;
    const start = (await db.query("select (now()-interval '1 hour')::text value")).rows[0].value;
    const competition = 'fb_comp_reconcile';
    const home = 'fb_team_reconcile_home';
    const away = 'fb_team_reconcile_away';

    await db.query(
      "insert into futbeat_private.entities values($1,'competition',$2)",
      [competition, JSON.stringify({ id: competition, name: 'Liga', country: 'Spain' })],
    );
    for (const [id, name] of [[home, 'Home'], [away, 'Away']]) {
      await db.query("insert into futbeat_private.entities values($1,'team',$2)", [
        id, JSON.stringify({ id, name, country: 'Spain', competitionId: competition }),
      ]);
    }

    const addMatch = async (id, status, score = null, receivedAt = new Date().toISOString()) => {
      const payload = {
        id, competitionId: competition, homeTeamId: home, awayTeamId: away,
        startTime: start, status, score, events: [], statistics: [],
        provenance: { source: 'GOAL API', receivedAt },
      };
      await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify(payload)]);
    };

    await addMatch('fb_match_recent_live', 'SCHEDULED');
    await addMatch('fb_match_stale_live', 'SCHEDULED');
    await addMatch(
      'fb_match_stale_canonical_live',
      'LIVE',
      { home: 4, away: 4 },
      new Date(Date.now() - 20 * 60 * 1000).toISOString(),
    );
    await addMatch('fb_match_terminal', 'VERIFIED', { home: 3, away: 1 });
    const hash = 'a'.repeat(64);
    for (const [external, id, seen, score] of [
      ['recent', 'fb_match_recent_live', 'now()', [1, 0]],
      ['stale', 'fb_match_stale_live', "now()-interval '20 minutes'", [2, 2]],
      ['terminal-old-live', 'fb_match_terminal', 'now()', [0, 0]],
    ]) {
      await db.query(`insert into futbeat_private.live_match_state(
        provider,external_match_id,canonical_match_id,status,minute,home_score,
        away_score,last_payload_hash,first_seen_at,last_seen_at,changed_at
      ) values($1,$2,$3,'LIVE',63,$4,$5,$6,${seen},${seen},${seen})`,
      ['goal_api', external, id, score[0], score[1], hash]);
    }

    const snapshot = (await db.query(
      "select public.futbeat_read_calendar_range($1::date,$1::date,'America/Costa_Rica') value",
      [day],
    )).rows[0].value;
    const match = (id) => snapshot.matches.find((item) => item.id === id);

    assert.equal(match('fb_match_recent_live').status, 'LIVE');
    assert.deepEqual(match('fb_match_recent_live').score, { home: 1, away: 0 });
    assert.equal(match('fb_match_stale_live').status, 'SCHEDULED');
    assert.deepEqual(match('fb_match_stale_live').score, { home: 2, away: 2 });
    assert.equal(match('fb_match_stale_live').hasPlayedEvidence, true);
    assert.equal(match('fb_match_stale_canonical_live').status, 'SCHEDULED');
    assert.deepEqual(match('fb_match_stale_canonical_live').score, { home: 4, away: 4 });
    assert.equal(match('fb_match_stale_canonical_live').hasPlayedEvidence, true);
    assert.equal(match('fb_match_terminal').status, 'VERIFIED');
    assert.deepEqual(match('fb_match_terminal').score, { home: 3, away: 1 });
  } finally {
    await db.close();
  }
});

test('newer terminal detail wins over an older LIVE observation with its real score', async () => {
  const db = await openDatabase();
  try {
    const day = (await db.query(
      // Calendar day of the kickoff (not of now): stable around local midnight.
      "select (((now()-interval '2 hours') at time zone 'America/Costa_Rica')::date)::text value",
    )).rows[0].value;
    const start = (await db.query("select (now()-interval '2 hours')::text value")).rows[0].value;
    const ids = ['fb_comp_detail_terminal', 'fb_team_detail_home', 'fb_team_detail_away'];
    await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [ids[0], JSON.stringify({ id: ids[0], name: 'Liga', country: 'England' })]);
    for (const id of ids.slice(1)) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name: id, country: 'England', competitionId: ids[0] })]);
    const id = 'fb_match_detail_terminal';
    await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({ id, competitionId: ids[0], homeTeamId: ids[1], awayTeamId: ids[2], startTime: start, status: 'SCHEDULED', score: null, events: [], statistics: [] })]);
    await db.query("insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,last_payload_hash,first_seen_at,last_seen_at,changed_at) values('goal_api','older-live',$1,'LIVE',89,1,1,$2,now()-interval '5 minutes',now()-interval '5 minutes',now()-interval '5 minutes')", [id, 'b'.repeat(64)]);
    await db.query("insert into futbeat_private.match_detail_cache values($1,'goal_api','older-live',now(),$2)", [id, JSON.stringify({ matchStatus: 'FINISHED', homeTeamScore: '2', awayTeamScore: '1' })]);

    const snapshot = (await db.query("select public.futbeat_read_calendar_range($1::date,$1::date,'America/Costa_Rica') value", [day])).rows[0].value;
    const visible = snapshot.matches.find((item) => item.id === id);
    assert.equal(visible.status, 'FINISHED_PENDING_VERIFICATION');
    assert.deepEqual(visible.score, { home: 2, away: 1 });
  } finally {
    await db.close();
  }
});

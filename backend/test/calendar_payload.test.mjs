import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

test('calendar transport keeps visible football data while stripping internal metadata', async () => {
  const db = await openDatabase();
  try {
    const competition = 'fb_comp_calendar_compact';
    const home = 'fb_team_calendar_home';
    const away = 'fb_team_calendar_away';
    const match = 'fb_match_calendar_compact';
    const startTime = '2026-09-19T20:00:00.000Z';
    const receivedAt = new Date().toISOString();

    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'competition',$2)",
      [
        competition,
        JSON.stringify({
          id: competition,
          name: 'Liga Compacta',
          country: 'Costa Rica',
          season: '2026',
          media: {
            url: 'https://example.com/league.png',
            verificationStatus: 'VERIFIED',
            rightsStatus: 'REVIEW_REQUIRED',
            usageScope: 'DEVELOPMENT_ONLY',
            receivedAt,
          },
        }),
      ],
    );

    for (const [id, name, shortName] of [
      [home, 'Local Compacto', 'LOC'],
      [away, 'Visita Compacta', 'VIS'],
    ]) {
      await db.query(
        "insert into futbeat_private.entities(id,kind,payload) values($1,'team',$2)",
        [
          id,
          JSON.stringify({
            id,
            name,
            shortName,
            country: 'Costa Rica',
            competitionId: competition,
            aliases: [name.toUpperCase()],
            media: {
              url: `https://example.com/${id}.png`,
              verificationStatus: 'VERIFIED',
              rightsStatus: 'REVIEW_REQUIRED',
              usageScope: 'DEVELOPMENT_ONLY',
              receivedAt,
            },
          }),
        ],
      );
    }

    await db.query(
      "insert into futbeat_private.entities(id,kind,payload) values($1,'match',$2)",
      [
        match,
        JSON.stringify({
          id: match,
          competitionId: competition,
          homeTeamId: home,
          awayTeamId: away,
          startTime,
          status: 'LIVE',
          score: { home: 1, away: 0 },
          minute: 32,
          season: '2026',
          venue: 'Estadio Compacto',
          events: [
            {
              id: 'goal-1',
              type: 'GOAL',
              minute: 20,
              teamId: home,
            },
          ],
          statistics: [
            { label: 'Posesión', home: 55, away: 45, unit: '%' },
          ],
          provenance: {
            source: 'GOAL API',
            externalId: 'internal-provider-id',
            receivedAt,
            verificationStatus: 'PROVISIONAL',
          },
        }),
      ],
    );

    const compact = (await db.query(
      "select public.futbeat_read_calendar_range('2026-09-19','2026-09-19','America/Costa_Rica') value",
    )).rows[0].value;
    const full = (await db.query(
      "select futbeat_private.futbeat_apply_entity_redirects_snapshot(futbeat_private.futbeat_read_calendar_range('2026-09-19','2026-09-19','America/Costa_Rica')) value",
    )).rows[0].value;

    assert.equal(compact.matches.length, full.matches.length);
    assert.equal(compact.matches.length, 1);
    assert.equal(compact.teams.length, 2);
    assert.equal(compact.competitions.length, 1);

    assert.equal(compact.matches[0].id, match);
    assert.equal(compact.matches[0].status, 'LIVE');
    assert.deepEqual(compact.matches[0].score, { home: 1, away: 0 });
    assert.equal(compact.matches[0].latestEvent.type, 'GOAL');
    assert.equal(compact.matches[0].events, undefined);
    assert.equal(compact.matches[0].statistics, undefined);
    assert.equal(compact.matches[0].provenance, undefined);
    assert.deepEqual(compact.players, []);
    assert.deepEqual(compact.standings, []);

    const compactHome = compact.teams.find((item) => item.id === home);
    assert.equal(compactHome.name, 'Local Compacto');
    assert.equal(compactHome.media.url, `https://example.com/${home}.png`);
    assert.equal(compactHome.media.verificationStatus, 'VERIFIED');
    assert.equal(compactHome.media.rightsStatus, undefined);
    assert.equal(compactHome.aliases, undefined);

    const compactText = JSON.stringify(compact);
    const fullText = JSON.stringify(full);
    assert.ok(
      compactText.length < fullText.length,
      `compact calendar should be smaller (${compactText.length} >= ${fullText.length})`,
    );
  } finally {
    await db.close();
  }
});

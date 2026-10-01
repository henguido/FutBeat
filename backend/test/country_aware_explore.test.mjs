import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Fixture names are arbitrary: production SQL never names a team, league or
// country. 'CR' is only the user's chosen ISO code in this fixture.
async function seed(db) {
  const today = (await db.query("select (now() at time zone 'UTC')::date::text d")).rows[0].d;
  const rows = [];
  const match = (id, competitionId, home, away, date = today) => rows.push({
    id, kind: 'match', competitionId, homeTeamId: home, awayTeamId: away,
    startTime: `${date}T18:00:00Z`, status: 'SCHEDULED', score: null, events: [],
    provenance: { receivedAt: `${date}T12:00:00Z` },
  });
  // A crowded global catalog: 12 foreign competitions, all far more relevant.
  for (let i = 0; i < 12; i++) {
    rows.push({ id: `fb_comp_global_${i}`, kind: 'competition', name: `Global League ${i}`, country: 'England' });
    for (const side of ['home', 'away']) {
      rows.push({ id: `fb_team_global_${side}_${i}`, kind: 'team', name: `Global ${side} ${i}`,
        competitionId: `fb_comp_global_${i}` });
    }
    match(`fb_match_global_${i}`, `fb_comp_global_${i}`, `fb_team_global_home_${i}`, `fb_team_global_away_${i}`);
  }
  rows.push(
    { id: 'fb_comp_local_cup', kind: 'competition', name: 'Local Cup', country: 'Costa Rica' },
    { id: 'fb_comp_local_primary', kind: 'competition', name: 'Local First Division', country: 'Costa Rica' },
    { id: 'fb_comp_nations', kind: 'competition', name: 'Regional Nations Cup', country: 'intl' },
    { id: 'fb_comp_foreign_league', kind: 'competition', name: 'Foreign League', country: 'Spain' },
  );
  for (const id of ['a', 'b', 'c', 'd']) {
    rows.push({ id: `fb_team_local_${id}`, kind: 'team', name: `Local Club ${id.toUpperCase()}`,
      // A club's last seen competition can be a regional cup, not its league.
      competitionId: id === 'a' ? 'fb_comp_nations' : 'fb_comp_local_primary' });
  }
  rows.push(
    { id: 'fb_team_national', kind: 'team', name: 'Costa Rica', competitionId: 'fb_comp_nations' },
    { id: 'fb_team_rival_nation', kind: 'team', name: 'Panama', competitionId: 'fb_comp_nations' },
    // Same catalogued name, but a domestic club elsewhere: never a national team.
    { id: 'fb_team_namesake_club', kind: 'team', name: 'Costa Rica', competitionId: 'fb_comp_foreign_league' },
  );
  match('fb_match_local_1', 'fb_comp_local_primary', 'fb_team_local_a', 'fb_team_local_b');
  match('fb_match_local_2', 'fb_comp_local_primary', 'fb_team_local_c', 'fb_team_local_d', '2020-01-02');
  match('fb_match_nations', 'fb_comp_nations', 'fb_team_national', 'fb_team_rival_nation', '2020-01-02');
  await db.query(`insert into futbeat_private.entities select item->>'id',item->>'kind',item-'kind'
    from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
  await db.exec(`update futbeat_private.competition_editorial_metadata set source='editorial',
      relevance_score=900-right(competition_id,1)::int*10,is_global_relevant=true,country_code='GB-ENG'
      where competition_id like 'fb_comp_global_%';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='CR',
      competition_class='domestic_league',domestic_tier=1,is_primary_domestic=true,
      audience_class='open',relevance_score=300,is_global_relevant=false
      where competition_id='fb_comp_local_primary';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='CR',
      competition_class='domestic_cup',domestic_tier=null,is_primary_domestic=false,
      audience_class='open',relevance_score=350,is_global_relevant=false
      where competition_id='fb_comp_local_cup';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code=null,
      competition_class='international_national',domestic_tier=null,is_primary_domestic=false,
      audience_class='open',relevance_score=400,is_global_relevant=false
      where competition_id='fb_comp_nations';
    update futbeat_private.competition_editorial_metadata set source='editorial',country_code='ES',
      competition_class='domestic_league',domestic_tier=1,is_primary_domestic=true,
      audience_class='open',relevance_score=200,is_global_relevant=false
      where competition_id='fb_comp_foreign_league';`);
}

const explore = async (db, country) => (await db.query(
  country === undefined ? 'select public.futbeat_read_explore() v'
    : 'select public.futbeat_read_country_explore($1) v', country === undefined ? [] : [country],
)).rows[0].v;

test('country Explore leads with the primary league, national team and league clubs, keeping the global list', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const global = await explore(db);
    // The pre-existing global list never reaches the local entries.
    assert.equal(global.competitions.some(c => c.id.startsWith('fb_comp_local_')), false);
    assert.equal(global.teams.some(t => t.id.startsWith('fb_team_local_') || t.id === 'fb_team_national'), false);

    const local = await explore(db, 'CR');
    assert.equal(local.schemaVersion, 1);
    assert.equal(local.demo, false);
    assert.deepEqual(local.competitions.slice(0, 2).map(c => c.id), ['fb_comp_local_primary', 'fb_comp_local_cup']);
    assert.equal(local.competitions[0].isPrimaryDomestic, true);
    assert.equal(local.competitions[0].domesticTier, 1);
    assert.equal(local.competitions[0].countryCode, 'CR');
    assert.equal(local.competitions[1].isPrimaryDomestic, false);
    for (const c of global.competitions) assert.ok(local.competitions.some(l => l.id === c.id), c.id);
    assert.equal(new Set(local.competitions.map(c => c.id)).size, local.competitions.length);

    const ids = local.teams.map(t => t.id);
    assert.equal(ids[0], 'fb_team_national');
    assert.equal(local.teams[0].isNationalTeam, true);
    assert.equal(local.teams[0].countryCode, 'CR');
    // Clubs of the primary league, most recently active first; a club whose
    // last competition was a regional cup still belongs to its league.
    assert.deepEqual(ids.slice(1, 5), ['fb_team_local_a', 'fb_team_local_b', 'fb_team_local_c', 'fb_team_local_d']);
    for (const club of local.teams.slice(1, 5)) {
      assert.equal(club.countryCode, 'CR', club.id);
      assert.equal(club.isPrimaryDomesticClub, true, club.id);
      assert.equal(club.isNationalTeam, undefined, club.id);
    }
    assert.equal(ids.includes('fb_team_namesake_club'), false);
    assert.equal(ids.includes('fb_team_rival_nation'), false);
    for (const t of global.teams) assert.ok(ids.includes(t.id), t.id);
    assert.equal(new Set(ids).size, ids.length);
    assert.equal(local.teams.filter(t => t.isNationalTeam).length, 1);
  } finally { await db.close(); }
});

test('country Explore is bounded, cached per country and invalidated by catalog changes', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const global = await explore(db);
    // Unknown, supranational or empty codes answer the plain global list.
    for (const code of ['ZZ', 'EUROPE', '', null]) assert.deepEqual(await explore(db, code), global, String(code));
    await assert.rejects(explore(db, 'X'.repeat(9)));
    const first = await explore(db, 'cr');
    assert.deepEqual(await explore(db, 'CR'), first);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.explore_country_cache')).rows[0].n, 1);
    await db.exec(`update futbeat_private.competition_editorial_metadata set relevance_score=310
      where competition_id='fb_comp_local_primary'`);
    assert.equal((await explore(db, 'CR')).competitions[0].relevanceScore, 310);
    // A country without local data still answers the global suggestions.
    const other = await explore(db, 'PA');
    assert.deepEqual(other.competitions.map(c => c.id), global.competitions.map(c => c.id));
    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_country_explore(text)','execute') ok", [role])).rows[0].ok, false);
      assert.equal((await db.query("select has_table_privilege($1,'futbeat_private.explore_country_cache','select') ok", [role])).rows[0].ok, false);
    }
  } finally { await db.close(); }
});

test('country Explore is wired through the API and names no country, league or team', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20261001100000_country_aware_explore.sql', import.meta.url), 'utf8');
  const code = sql.split('\n').filter(line => !line.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(code, /'[A-Z]{2}(?:-[A-Z]{3})?'/);
  const src = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  assert.match(src, /futbeat_read_country_explore/);
  assert.match(src, /p_country: country/);
});

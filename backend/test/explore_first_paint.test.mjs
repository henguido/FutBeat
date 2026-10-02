import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Explorar first paint (20261002120000): the cache-miss query of
// public.futbeat_read_explore() is reshaped (primary-key probes instead of a
// full entities walk, one resolution per distinct reference). The answer must
// stay exactly the previous one; only the plan changes.

const migration = (name) =>
  readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8');

async function seed(db) {
  const today = (await db.query("select (now() at time zone 'UTC')::date d")).rows[0].d;
  const day = (offset) => {
    const d = new Date(today);
    d.setUTCDate(d.getUTCDate() + offset);
    return d.toISOString().slice(0, 10);
  };
  const rows = [];
  for (let i = 0; i < 16; i++) {
    rows.push({ id: `fb_comp_fp_${i}`, kind: 'competition', name: `League ${String.fromCharCode(65 + (i % 5))}`, country: 'England' });
  }
  // An alias competition (redirected): never listed, its matches score as the canonical.
  rows.push({ id: 'fb_comp_fp_alias', kind: 'competition', name: 'Alias League', country: 'England' });
  for (let i = 0; i < 30; i++) {
    for (const side of ['home', 'away']) {
      rows.push({ id: `fb_team_fp_${side}_${i}`, kind: 'team', name: `Team ${side} ${i % 7}`, competitionId: `fb_comp_fp_${i % 16}` });
    }
  }
  rows.push({ id: 'fb_team_fp_alias', kind: 'team', name: 'Alias Team' });
  const match = (id, competitionId, home, away, date) => rows.push({
    id, kind: 'match', competitionId, homeTeamId: home, awayTeamId: away,
    startTime: `${date}T18:00:00Z`, status: 'SCHEDULED', score: null, events: [],
    provenance: { receivedAt: `${date}T12:00:00Z` },
  });
  for (let i = 0; i < 30; i++) {
    match(`fb_match_fp_${i}`, `fb_comp_fp_${i % 16}`, `fb_team_fp_home_${i}`, `fb_team_fp_away_${i}`, day((i % 13) - 6));
  }
  // Outside the window, through an alias competition, without a competition,
  // and an aliased team side.
  match('fb_match_fp_old', 'fb_comp_fp_0', 'fb_team_fp_home_1', 'fb_team_fp_away_2', day(-20));
  match('fb_match_fp_alias_comp', 'fb_comp_fp_alias', 'fb_team_fp_home_3', 'fb_team_fp_alias', day(1));
  match('fb_match_fp_no_comp', null, 'fb_team_fp_home_4', 'fb_team_fp_away_5', day(0));
  await db.query(`insert into futbeat_private.entities select item->>'id',item->>'kind',jsonb_strip_nulls(item-'kind')
    from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
  await db.exec(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
      ('fb_comp_fp_alias','fb_comp_fp_2','competition','test'),
      ('fb_team_fp_alias','fb_team_fp_away_6','team','test');
    update futbeat_private.competition_editorial_metadata set source='editorial',
      relevance_score=case when competition_id like 'fb_comp_fp_%' and competition_id<>'fb_comp_fp_alias'
        then 500+(right(competition_id,1)::int%4)*100 else relevance_score end,
      is_global_relevant=competition_id in ('fb_comp_fp_1','fb_comp_fp_5')
    where competition_id like 'fb_comp_fp_%';`);
}

const read = async (db) => (await db.query('select public.futbeat_read_explore() v')).rows[0].v;
const comparable = ({ updatedAt, ...rest }) => rest;

test('reshaped Explore miss query answers exactly what the previous one did', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const current = await read(db);
    assert.equal(current.competitions.length, 12);
    assert.ok(current.teams.length > 0 && current.teams.length <= 16);
    assert.equal(current.competitions.some((c) => c.id === 'fb_comp_fp_alias'), false);
    assert.equal(current.teams.some((t) => t.id === 'fb_team_fp_alias'), false);

    const old = await migration('20260922002909_calendar_cache_explore.sql');
    const start = old.indexOf('create function public.futbeat_read_explore()');
    const end = old.indexOf('end $$;', start) + 'end $$;'.length;
    const newDef = (await db.query("select pg_get_functiondef('public.futbeat_read_explore()'::regprocedure) def")).rows[0].def;
    await db.exec(old.slice(start, end).replace('create function', 'create or replace function'));
    await db.exec('delete from futbeat_private.explore_cache where singleton');
    const previous = await read(db);
    await db.exec(newDef);
    assert.deepEqual(comparable(current), comparable(previous));
  } finally {
    await db.close();
  }
});

test('the reshaped function keeps the cache contract (hit, version and TTL)', async () => {
  const db = await openDatabase();
  try {
    await seed(db);
    const first = await read(db);
    // A hit returns the stored payload as is.
    assert.deepEqual(await read(db), first);
    // A catalog change invalidates it.
    await db.exec(`update futbeat_private.entities set payload=payload||'{"name":"Renamed League"}'
      where id='fb_comp_fp_3'`);
    const renamed = await read(db);
    assert.ok(renamed.competitions.some((c) => c.name === 'Renamed League'));
    // An expired row is rebuilt.
    await db.exec(`update futbeat_private.explore_cache set expires_at=now()-interval '1 second',
      payload=payload||'{"marker":true}' where singleton`);
    assert.equal((await read(db)).marker, undefined);
    // Country Explore still builds on top of it.
    const local = (await db.query("select public.futbeat_read_country_explore('GB') v")).rows[0].v;
    assert.equal(local.schemaVersion, 1);
    assert.ok(local.competitions.length >= renamed.competitions.length);
  } finally {
    await db.close();
  }
});

test('the miss query probes primary keys instead of walking every entity', async () => {
  const sql = await migration('20261002120000_explore_first_paint.sql');
  const body = sql.slice(sql.indexOf('create or replace function public.futbeat_read_explore()'));
  // Both entity reads are lateral primary-key probes behind an OFFSET 0 fence.
  assert.equal(body.match(/where e\.id=m\.competition_id and e\.kind='competition' offset 0/g)?.length, 1);
  assert.equal(body.match(/where e\.id=c\.match_id and e\.kind='match' offset 0/g)?.length, 1);
  // Competition references are resolved once per distinct value.
  assert.match(body, /select distinct w\.competition_ref ref from window_matches w/);
  // Same cache, lock and privileges as before.
  assert.match(body, /pg_advisory_xact_lock\(hashtextextended\('futbeat:explore',0\)\)/);
  assert.match(body, /interval '5 minutes'/);
  assert.match(sql, /grant execute on function public\.futbeat_read_explore\(\) to service_role/);
  assert.doesNotMatch(body, /provider_|goal_api|net\.http/);
});

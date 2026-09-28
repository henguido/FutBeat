import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// #150 / #111: team and national-team profiles. Everything synthetic: no real
// team, competition or country is special-cased. No provider call anywhere.

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const hours = (h) => new Date(Date.now() + h * 3600e3).toISOString();
const entity = (db, id, kind, payload) => db.query(
  'insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);

let seq = 0;
async function team(db, name = `Equipo sintético ${++seq}`, { mapped = false } = {}) {
  const id = `fb_team_tp${++seq}`;
  await entity(db, id, 'team', { name, country: 'Nowhere' });
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$2)", [`tp-ext-${seq}`, id]);
  return id;
}
async function competition(db, { mapped = false } = {}) {
  const id = `fb_comp_tp${++seq}`, ext = `tp-league-${seq}`;
  await entity(db, id, 'competition', { name: `Torneo ${seq}`, country: 'Nowhere' });
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  return { id, ext };
}
async function match(db, comp, home, away, offsetHours, extra = {}) {
  const id = `fb_match_tp${++seq}`;
  await entity(db, id, 'match', {
    competitionId: comp, homeTeamId: home, awayTeamId: away, status: 'SCHEDULED',
    startTime: hours(offsetHours), events: [], statistics: [], ...extra,
  });
  return id;
}
const finished = (home, away) => ({ status: 'VERIFIED', score: { home, away } });

const page = (db, id, bucket, cursor = null, limit = 20) => db.query(
  'select public.futbeat_read_team_matches($1,$2,$3,$4) v', [id, bucket, cursor, limit]).then((r) => r.rows[0].v);
const allPages = async (db, id, bucket, limit) => {
  const out = [];
  let cursor = null;
  for (let i = 0; i < 20; i++) {
    const p = await page(db, id, bucket, cursor, limit);
    out.push(...p.matches);
    if (!p.hasMore) return out;
    cursor = p.nextCursor;
  }
  throw new Error('pagination never ended');
};
const detail = (db, type, id) => db.query('select public.futbeat_read_entity_detail($1,$2) v', [type, id]).then((r) => r.rows[0].v);

// ---------------------------------------------------------------------------
// A) Matches
// ---------------------------------------------------------------------------

test('canonical team id gathers matches across every competition', () => withDb(async (db) => {
  const t = await team(db), rivals = [await team(db), await team(db), await team(db)];
  const comps = [await competition(db), await competition(db), await competition(db)];
  for (let i = 0; i < 3; i++) {
    await match(db, comps[i].id, t, rivals[i], -48 - i * 24, finished(1, 0));
    await match(db, comps[i].id, rivals[i], t, 48 + i * 24);
  }
  await match(db, comps[0].id, rivals[0], rivals[1], 30); // not this team
  const upcoming = await page(db, t, 'upcoming');
  const results = await page(db, t, 'results');
  assert.equal(upcoming.matches.length, 3);
  assert.equal(results.matches.length, 3);
  assert.deepEqual(new Set([...upcoming.matches, ...results.matches].map((m) => m.competitionId)), new Set(comps.map((c) => c.id)));
  assert.ok([...upcoming.matches, ...results.matches].every((m) => m.homeTeamId === t || m.awayTeamId === t));
  // Every referenced team and competition travels with the page.
  const teamIds = new Set(upcoming.teams.map((x) => x.id));
  assert.ok(upcoming.matches.every((m) => teamIds.has(m.homeTeamId) && teamIds.has(m.awayTeamId)));
  assert.equal(upcoming.competitions.length, 3);
}));

test('upcoming is ascending and results descending', () => withDb(async (db) => {
  const t = await team(db), r = await team(db), c = await competition(db);
  for (const h of [72, 24, 48]) await match(db, c.id, t, r, h);
  for (const h of [-72, -24, -48]) await match(db, c.id, r, t, h, finished(0, 2));
  const up = (await page(db, t, 'upcoming')).matches.map((m) => Date.parse(m.startTime));
  const res = (await page(db, t, 'results')).matches.map((m) => Date.parse(m.startTime));
  assert.deepEqual(up, [...up].sort((a, b) => a - b));
  assert.deepEqual(res, [...res].sort((a, b) => b - a));
}));

test('pagination returns every match exactly once, then stops', () => withDb(async (db) => {
  const t = await team(db), r = await team(db), c = await competition(db);
  const past = [];
  for (let i = 1; i <= 25; i++) past.push(await match(db, c.id, t, r, -i * 24, finished(1, 1)));
  // Two matches sharing the same kickoff still page deterministically.
  const tieTime = hours(-500);
  past.push(await match(db, c.id, t, r, 0, { ...finished(0, 0), startTime: tieTime }));
  past.push(await match(db, c.id, r, t, 0, { ...finished(2, 2), startTime: tieTime }));
  for (let i = 1; i <= 12; i++) await match(db, c.id, r, t, i * 24);
  const results = await allPages(db, t, 'results', 10);
  const upcoming = await allPages(db, t, 'upcoming', 5);
  assert.equal(results.length, 27);
  assert.equal(new Set(results.map((m) => m.id)).size, 27);
  assert.deepEqual(new Set(results.map((m) => m.id)), new Set(past));
  assert.equal(upcoming.length, 12);
  assert.equal(new Set(upcoming.map((m) => m.id)).size, 12);
  const first = await page(db, t, 'results', null, 10);
  assert.equal(first.hasMore, true);
  assert.match(first.nextCursor, /^\d{4}-\d{2}-\d{2}T.+Z\|fb_match_tp/);
  await assert.rejects(page(db, t, 'results', 'not-a-cursor'), /Invalid team matches cursor/);
  await assert.rejects(page(db, t, 'future'), /Invalid team matches request/);
}));

test('lifecycle: effective status decides the bucket, never the raw SCHEDULED', () => withDb(async (db) => {
  const t = await team(db), r = await team(db), c = await competition(db);
  const future = await match(db, c.id, t, r, 3);
  const stale = await match(db, c.id, t, r, -2); // kickoff passed, still SCHEDULED, no evidence
  const justStarted = await match(db, c.id, t, r, -0.1); // inside the 15-minute grace
  const done = await match(db, c.id, t, r, -30, finished(3, 1));
  const postponedPast = await match(db, c.id, t, r, -5, { status: 'POSTPONED' });
  const postponedFuture = await match(db, c.id, t, r, 10, { status: 'POSTPONED' });
  const cancelled = await match(db, c.id, t, r, 20, { status: 'CANCELLED' });
  const live = await match(db, c.id, t, r, -0.5, {
    status: 'LIVE', score: { home: 1, away: 0 }, provenance: { receivedAt: hours(-0.02) } });
  const staleLive = await match(db, c.id, t, r, -3, {
    status: 'LIVE', provenance: { receivedAt: hours(-2) } }); // LIVE never refreshed
  // Terminal evidence recorded after kickoff ends a raw SCHEDULED match.
  const evidenced = await match(db, c.id, t, r, -4);
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values('fb_event_tp_ft',$1,'goal_api','FULL_TIME','{}',now()-interval '1 hour')`, [evidenced]);

  const liveRows = (await page(db, t, 'live')).matches;
  const up = (await page(db, t, 'upcoming')).matches;
  const res = (await page(db, t, 'results')).matches;
  const liveIds = liveRows.map((m) => m.id), upIds = up.map((m) => m.id), resIds = res.map((m) => m.id);
  // In play is its own bucket: never under "Próximos".
  assert.deepEqual(liveIds, [live]);
  assert.deepEqual(upIds, [justStarted, future]);
  for (const id of [stale, done, postponedPast, postponedFuture, cancelled, staleLive, evidenced]) {
    assert.ok(resIds.includes(id), `${id} must be a result`);
    assert.ok(!upIds.includes(id) && !liveIds.includes(id), `${id} must never be live or upcoming`);
  }
  // The three buckets partition every match exactly once.
  const all = [...liveIds, ...upIds, ...resIds];
  assert.equal(new Set(all).size, all.length);
  assert.equal(all.length, 10);
  // Nothing is invented for the stale match: still SCHEDULED, no score.
  const staleRow = res.find((m) => m.id === stale);
  assert.equal(staleRow.status, 'SCHEDULED');
  assert.equal(staleRow.score ?? null, null);
  assert.equal(res.find((m) => m.id === evidenced).status, 'FINISHED_PENDING_VERIFICATION');
  assert.equal(res.find((m) => m.id === staleLive).status, 'SCHEDULED');
  assert.equal(res.find((m) => m.id === done).status, 'VERIFIED');
}));

test('live pagination: in-play matches page once, next kickoff first', () => withDb(async (db) => {
  const t = await team(db), c = await competition(db);
  const ids = [];
  for (let i = 0; i < 5; i++) {
    const r = await team(db);
    ids.push(await match(db, c.id, t, r, -(5 - i) * 0.1, {
      status: i % 2 ? 'HALFTIME' : 'LIVE', provenance: { receivedAt: hours(-0.01) } }));
  }
  const rows = await allPages(db, t, 'live', 2);
  assert.deepEqual(rows.map((m) => m.id), ids);
  assert.equal((await page(db, t, 'upcoming')).matches.length, 0);
}));

test('a rescheduled match is listed once, at its new kickoff', () => withDb(async (db) => {
  const t = await team(db), r = await team(db), c = await competition(db);
  const id = await match(db, c.id, t, r, -3);
  await db.query(`update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb($2::text))
    where id=$1`, [id, hours(72)]);
  const up = (await page(db, t, 'upcoming')).matches;
  const res = (await page(db, t, 'results')).matches;
  assert.deepEqual(up.map((m) => m.id), [id]);
  assert.equal(res.length, 0);
}));

test('team identity is the canonical id: aliases resolve and join', () => withDb(async (db) => {
  const canonical = await team(db, 'Club Canónico'), alias = await team(db, 'Club Canónico (alias)');
  const r = await team(db), c = await competition(db);
  await db.query(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
    values($1,$2,'team','test')`, [alias, canonical]);
  const viaAlias = await match(db, c.id, alias, r, 24);
  const direct = await match(db, c.id, r, canonical, 48);
  const byAlias = await page(db, alias, 'upcoming');
  assert.equal(byAlias.teamId, canonical);
  assert.deepEqual(byAlias.matches.map((m) => m.id), [viaAlias, direct]);
  assert.equal(byAlias.matches[0].homeTeamId, canonical);
  // Same-named team that is not linked is never merged by name.
  const namesake = await team(db, 'Club Canónico');
  assert.equal((await page(db, namesake, 'upcoming')).matches.length, 0);
  assert.equal(await page(db, 'fb_team_missing_x', 'upcoming'), null);
}));

test('entity detail matches use the effective status too', () => withDb(async (db) => {
  const t = await team(db), r = await team(db), c = await competition(db);
  const staleLive = await match(db, c.id, t, r, -3, { status: 'LIVE', provenance: { receivedAt: hours(-2) } });
  const d = await detail(db, 'team', t);
  assert.equal(d.matches.find((m) => m.id === staleLive).status, 'SCHEDULED');
  assert.equal(typeof d.matches[0].hasPlayedEvidence, 'boolean');
}));

// ---------------------------------------------------------------------------
// C) Squad
// ---------------------------------------------------------------------------

async function storeSquad(db, teamId, rows, at = new Date().toISOString()) {
  const squad = await normalizeGoalApiSquad(rows, teamId, async (kind, external, identity) => (await db.query(
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, at);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', [teamId, 'goal_api', at, JSON.stringify(squad)]);
}
const squadState = async (db, id) => (await detail(db, 'team', id)).coverage.squad;
const request = (db, id) => db.query('select public.futbeat_request_team_squad($1) v', [id]).then((r) => r.rows[0].v);
const demands = (db) => db.query('select * from futbeat_private.team_squad_demands order by team_id').then((r) => r.rows);
const plan = (db) => db.query('select futbeat_private.futbeat_team_squad_plan(25) v').then((r) => r.rows[0].v);

test('squad AVAILABLE: fresh stored players', () => withDb(async (db) => {
  const t = await team(db, undefined, { mapped: true });
  await storeSquad(db, t, [{ id: 'sq-a1', name: 'Uno' }, { id: 'sq-a2', name: 'Dos' }]);
  const st = await squadState(db, t);
  assert.equal(st.state, 'AVAILABLE');
  assert.equal(st.playerCount, 2);
  assert.equal((await request(db, t)).demandRecorded, false);
  assert.equal((await demands(db)).length, 0);
}));

test('squad PENDING: never fetched, in flight or retrying; never "no disponible"', () => withDb(async (db) => {
  const t = await team(db, undefined, { mapped: true });
  assert.deepEqual(await squadState(db, t), { state: 'PENDING', reason: 'never_fetched', playerCount: 0 });
  await db.query(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,last_attempt_at,lease_until)
    values($1,'goal_api',null,0,now(),now()+interval '10 minutes')`, [t]);
  assert.equal((await squadState(db, t)).reason, 'in_flight');
  await db.query(`update futbeat_private.team_detail_coverage set lease_until=null,status='FETCH_FAILED',
    next_retry_at=now()+interval '15 minutes' where team_id=$1`, [t]);
  const st = await squadState(db, t);
  assert.equal(st.state, 'PENDING');
  assert.equal(st.reason, 'retrying');
}));

test('squad CONFIRMED_EMPTY: the provider validly answered no squad', () => withDb(async (db) => {
  const t = await team(db, undefined, { mapped: true });
  await storeSquad(db, t, []);
  assert.equal((await squadState(db, t)).state, 'CONFIRMED_EMPTY');
  assert.equal((await squadState(db, t)).reason, 'provider_no_data');
  assert.equal((await request(db, t)).demandRecorded, false);
  // An expired NO_DATA is revalidated, not confirmed forever.
  await db.query(`update futbeat_private.team_detail_coverage set next_retry_at=now()-interval '1 minute' where team_id=$1`, [t]);
  assert.equal((await squadState(db, t)).state, 'PENDING');
}));

test('squad UNAVAILABLE: no provider source is not a confirmed empty squad', () => withDb(async (db) => {
  const unmapped = await team(db);
  assert.deepEqual(await squadState(db, unmapped), { state: 'UNAVAILABLE', reason: 'no_provider_source', playerCount: 0 });
  assert.equal((await request(db, unmapped)).demandRecorded, false);
  assert.equal((await demands(db)).length, 0);
  // Once the provider validly answers "no squad", it becomes CONFIRMED_EMPTY.
  const mapped = await team(db, undefined, { mapped: true });
  await storeSquad(db, mapped, []);
  assert.equal((await squadState(db, mapped)).state, 'CONFIRMED_EMPTY');
  // A stored squad stays AVAILABLE even if the mapping later disappears.
  const lost = await team(db, undefined, { mapped: true });
  await storeSquad(db, lost, [{ id: 'sq-l1', name: 'Uno' }]);
  await db.query("delete from futbeat_private.provider_entities where kind='team' and canonical_id=$1", [lost]);
  assert.equal((await squadState(db, lost)).state, 'AVAILABLE');
}));

test('squad STALE: old snapshot keeps its players and asks for revalidation', () => withDb(async (db) => {
  const t = await team(db, undefined, { mapped: true });
  await storeSquad(db, t, [{ id: 'sq-s1', name: 'Viejo' }], hours(-24 * 9));
  const st = await squadState(db, t);
  assert.equal(st.state, 'STALE');
  assert.equal(st.playerCount, 1);
  assert.equal((await request(db, t)).demandRecorded, true);
}));

test('squad demand is central and deduplicated, and the planner consumes it once', () => withDb(async (db) => {
  const t = await team(db, undefined, { mapped: true });
  // 100 profile opens (any number of users) -> one demand row.
  for (let i = 0; i < 100; i++) await request(db, t);
  const rows = await demands(db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].team_id, t);
  assert.equal(rows[0].request_count, 1); // writes throttled to one a minute
  const planned = (await plan(db)).filter((x) => x.teamId === t);
  assert.equal(planned.length, 1);
  assert.equal(planned[0].reason, 'requested');
  assert.equal(planned[0].priorityTier, 6);
  // The reservation attempt consumes the demand (lease blocks, then the
  // attempt timestamp keeps it consumed after the lease).
  await db.query(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,last_attempt_at,lease_until)
    values($1,'goal_api',null,0,now(),now()-interval '1 second')`, [t]);
  await db.query(`update futbeat_private.team_squad_demands set requested_at=now()-interval '5 seconds'`);
  assert.equal((await plan(db)).filter((x) => x.teamId === t && x.reason === 'requested').length, 0);
  // Aliases collapse to the canonical team.
  const alias = await team(db);
  await db.query(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')`, [alias, t]);
  await db.query('delete from futbeat_private.team_squad_demands');
  await request(db, alias); await request(db, t);
  assert.deepEqual((await demands(db)).map((d) => d.team_id), [t]);
}));

// ---------------------------------------------------------------------------
// D/E) Standings identity and groups
// ---------------------------------------------------------------------------

const row = (ext, name, position, pts, extra = {}) => ({
  overallLeaguePosition: String(position), overallLeaguePlayed: '3', overallLeagueW: String(Math.floor(pts / 3)),
  overallLeagueD: String(pts % 3), overallLeagueL: '0', overallLeagueGF: String(pts), overallLeagueGA: '1',
  overallLeaguePTS: String(pts), team: { id: ext, name, country: { name: 'Nowhere' } }, ...extra,
});
const store = (db, comp, rows, at = new Date().toISOString()) => db.query(
  'select public.futbeat_store_goal_standings($1,$2,$3,$4,$5) v', [comp.id, comp.ext, at, '2026', JSON.stringify(rows)])
  .then((r) => r.rows[0].v);
const cached = (db, comp) => db.query('select table_payload v from futbeat_private.standings_cache where competition_id=$1', [comp.id])
  .then((r) => r.rows[0].v);

test('grouped standings keep each group with its own positions', () => withDb(async (db) => {
  const comp = await competition(db, { mapped: true });
  const result = await store(db, comp, [
    row('g-b1', 'Beta Uno', 1, 9, { groupName: 'Grupo B' }),
    row('g-a2', 'Alfa Dos', 2, 4, { groupName: 'Grupo A' }),
    row('g-b2', 'Beta Dos', 2, 3, { groupName: 'Grupo B' }),
    row('g-a1', 'Alfa Uno', 1, 7, { groupName: 'Grupo A' }),
  ]);
  assert.equal(result.groups, 2);
  assert.equal(result.groupsResolved, true);
  const table = await cached(db, comp);
  assert.equal(table.grouped, true);
  assert.equal(table.groupsResolved, true);
  const labels = table.rows.map((r) => `${r.group}#${r.position}`);
  // Groups are contiguous, never interleaved by position.
  assert.deepEqual(labels, ['Grupo A#1', 'Grupo A#2', 'Grupo B#1', 'Grupo B#2']);
}));

test('two groups are never mixed: unlabelled groups are flagged, overlays stay inside a group', () => withDb(async (db) => {
  const flat = await competition(db, { mapped: true });
  const flagged = await store(db, flat, [
    row('u-1', 'Uno', 1, 9), row('u-2', 'Dos', 2, 6), row('u-3', 'Tres', 1, 7), row('u-4', 'Cuatro', 2, 1),
  ]);
  assert.equal(flagged.groupsResolved, false);
  assert.equal((await cached(db, flat)).groupsResolved, false);

  const comp = await competition(db, { mapped: true });
  const baseline = hours(-3);
  await store(db, comp, [
    row('o-a1', 'A Uno', 1, 6, { group: 'A' }), row('o-a2', 'A Dos', 2, 5, { group: 'A' }),
    row('o-b1', 'B Uno', 1, 6, { group: { name: 'B' } }), row('o-b2', 'B Dos', 2, 0, { group: { name: 'B' } }),
  ], baseline);
  const ids = Object.fromEntries((await cached(db, comp)).rows.map((r, i) => [['a1', 'a2', 'b1', 'b2'][i], r.teamId]));
  // Same group: A2 beats A1 and overtakes it. Cross group: must not count.
  await match(db, comp.id, ids.a2, ids.a1, -1, finished(2, 0));
  await match(db, comp.id, ids.b2, ids.a1, -1.5, finished(5, 0));
  const overlaid = (await db.query('select futbeat_private.futbeat_apply_provisional_standings(table_payload,fetched_at) v from futbeat_private.standings_cache where competition_id=$1', [comp.id])).rows[0].v;
  assert.equal(overlaid.provisional, true);
  assert.equal(overlaid.provisionalMatches, 1);
  assert.deepEqual(overlaid.rows.map((r) => [r.group, r.position, r.teamId]), [
    ['A', 1, ids.a2], ['A', 2, ids.a1], ['B', 1, ids.b1], ['B', 2, ids.b2]]);
  assert.equal(overlaid.rows.find((r) => r.teamId === ids.b2).played, 3);
}));

test('every standings row resolves a real team entity; no "Equipo" placeholder', () => withDb(async (db) => {
  const comp = await competition(db, { mapped: true });
  const local = await team(db, 'Local Real');
  await store(db, comp, [row('id-1', 'Primero Real', 1, 9), row('id-2', 'Segundo Real', 2, 6), row('id-3', 'Tercero Real', 3, 3)]);
  const rows = (await cached(db, comp)).rows;
  // Only one listed match: the other table teams have no match in the profile.
  await match(db, comp.id, local, rows[0].teamId, 24);
  for (const [type, id] of [['team', local], ['competition', comp.id]]) {
    const d = await detail(db, type, id);
    const table = d.standings.find((s) => s.competitionId === comp.id);
    assert.ok(table, `${type} detail carries the table`);
    const teams = new Map(d.teams.map((t) => [t.id, t]));
    for (const r of table.rows) {
      assert.ok(teams.has(r.teamId), `${type}: row ${r.teamId} has its team`);
      assert.notEqual(teams.get(r.teamId).name, 'Equipo');
    }
    assert.equal(new Set(d.teams.map((t) => t.id)).size, d.teams.length, 'teams are not duplicated');
  }
}));

test('API: team matches route and squad demand only use FutBeat RPCs', async () => {
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  assert.match(source, /\/futbeat-api\/v1\/team-matches/);
  assert.match(source, /rpc\(\s*'futbeat_read_team_matches'/);
  assert.match(source, /rpc\(\s*'futbeat_request_team_squad'/);
  // The API never talks to a provider: only Supabase RPCs.
  assert.doesNotMatch(source, /goal-api\.com|api-football|\bfetch\(/i);
});

test('clean install creates both team-match indexes', () => withDb(async (db) => {
  const rows = (await db.query(`select indexname,indexdef from pg_indexes
    where schemaname='futbeat_private' and indexname in ('entities_match_home_team_idx','entities_match_away_team_idx')
    order by indexname`)).rows;
  assert.deepEqual(rows.map((r) => r.indexname), ['entities_match_away_team_idx', 'entities_match_home_team_idx']);
  assert.match(rows[0].indexdef, /\(payload ->> 'awayTeamId'::text\)+\s+WHERE \(kind = 'match'::text\)/);
  assert.match(rows[1].indexdef, /\(payload ->> 'homeTeamId'::text\)+\s+WHERE \(kind = 'match'::text\)/);
  const { readFile } = await import('node:fs/promises');
  const sql = await readFile(new URL('../../supabase/migrations/20260929100000_team_profile_completeness.sql', import.meta.url), 'utf8');
  assert.match(sql, /create index if not exists entities_match_home_team_idx/);
  assert.match(sql, /create index if not exists entities_match_away_team_idx/);
}));

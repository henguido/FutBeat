import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import {
  fixtureEventSections,
  liveEventsContentSignature,
  normalizeFixtureEvents,
} from '../../supabase/functions/_shared/live_events.ts';

// LIVE lifecycle reliability against the real migrations in PGlite: a match
// goes SCHEDULED -> LIVE -> FINAL without staying trapped. Generic fixtures
// only; the provider is simulated by the payloads the worker would send.

const tz = 'America/Costa_Rica';
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString();
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const map = (db, kind, ext, id) => db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);

// A competition and two teams FutBeat already knows (mapped to GOAL ids).
async function seedKnown(db, { mapCompetition = true, mapTeams = true } = {}) {
  const n = ++seq;
  const k = { n, comp: `fb_comp_ll${n}`, home: `fb_team_llh${n}`, away: `fb_team_lla${n}`,
    compExt: `league-${n}`, homeExt: `LH${n}`, awayExt: `LA${n}` };
  await put(db, k.comp, 'competition', { name: `Liga ${n}` });
  await put(db, k.home, 'team', { name: `Local ${n}` });
  await put(db, k.away, 'team', { name: `Visita ${n}` });
  if (mapCompetition) await map(db, 'competition', k.compExt, k.comp);
  if (mapTeams) { await map(db, 'team', k.homeExt, k.home); await map(db, 'team', k.awayExt, k.away); }
  return k;
}
async function calendarMatch(db, k, suffix, { start, ext, status = 'SCHEDULED', score = null }) {
  const id = `fb_match_ll${k.n}_${suffix}`;
  await put(db, id, 'match', { competitionId: k.comp, homeTeamId: k.home, awayTeamId: k.away, startTime: start, status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [],
    provenance: { source: 'GOAL API', externalId: ext, receivedAt: hoursAgo(300), verificationStatus: 'PROVISIONAL' } });
  if (ext) await map(db, 'match', ext, id);
  return id;
}
// A GOAL fixture row as the live / results feed returns it.
const feedFixture = (k, ext, { kickoff, status = 'LIVE', home = 0, away = 0, minute = 10, names = false } = {}) => ({
  apiId: ext, id: `row-${ext}`, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
  kickoffUtc: kickoff, leagueId: k.compExt, leagueYear: '2026',
  homeTeam: { id: k.homeExt, ...(names ? { name: `Local ${k.n}` } : {}) },
  awayTeam: { id: k.awayExt, ...(names ? { name: `Visita ${k.n}` } : {}) },
  events: [], cards: [], substitutions: [] });
const STATUS = { LIVE: 'LIVE', HALF_TIME: 'HALFTIME', FINISHED: 'FINISHED_PENDING_VERIFICATION', NOT_STARTED: 'SCHEDULED' };
function observation(fixture) {
  const normalized = normalizeFixtureEvents(fixture);
  const completeSections = fixtureEventSections(fixture);
  const obs = { externalMatchId: fixture.apiId, status: STATUS[fixture.matchStatus] ?? 'SCHEDULED', minute: fixture.matchElapsed,
    score: { home: fixture.homeTeamScore, away: fixture.awayTeamScore }, events: normalized, completeSections, rawPayload: fixture, source: 'live-list' };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([obs.externalMatchId, obs.status, obs.minute, obs.score,
    liveEventsContentSignature(normalized, completeSections), ++seq])).digest('hex');
  return obs;
}
// What the worker does on every poll: link (and discover), then record.
async function poll(db, fixtures) {
  const link = (await db.query('select public.futbeat_link_goal_live_matches($1) v', [JSON.stringify(fixtures)])).rows[0].v;
  const batch = (await db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify(fixtures.map(observation))])).rows[0].v;
  return { link, batch };
}
const mapped = (db, ext) => db.query("select canonical_id v from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id=$1", [ext]).then((r) => r.rows[0]?.v ?? null);
const model = (db, id) => db.query('select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v);
const matchCount = (db, k) => db.query("select count(*)::int n from futbeat_private.entities where kind='match' and payload->>'homeTeamId'=$1", [k.home]).then((r) => r.rows[0].n);
async function feedIds(db, iso) {
  const day = (await db.query('select ($1::timestamptz at time zone $2)::date::text d', [iso, tz])).rows[0].d;
  const v = (await db.query('select futbeat_private.build_compact_calendar($1::date,$1::date,$2) v', [day, tz])).rows[0].v;
  return v.matches;
}

test('a fixture the calendar never knew goes SCHEDULED -> LIVE -> FINAL from the live feed', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(0.5);
  assert.equal(await matchCount(db, k), 0);
  const first = await poll(db, [feedFixture(k, 'new-1', { kickoff, home: 1, minute: 28 })]);
  assert.deepEqual([first.link.created, first.link.relinked, first.link.unmappedCount], [1, 0, 0]);
  const id = await mapped(db, 'new-1');
  assert.match(id, /^fb_match_[0-9a-f]{32}$/);
  const stored = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
  assert.deepEqual([stored.status, stored.competitionId, stored.homeTeamId, stored.awayTeamId], ['SCHEDULED', k.comp, k.home, k.away]);
  assert.equal(stored.provenance.discoveredVia, 'live-feed');

  let shown = await model(db, id);
  assert.deepEqual([shown.status, shown.score], ['LIVE', { home: 1, away: 0 }]);
  const row = (await feedIds(db, kickoff)).find((m) => m.id === id);
  assert.deepEqual([row.status, row.score], ['LIVE', { home: 1, away: 0 }], 'visible in the Partidos feed');
  assert.equal((await db.query('select status from public.live_match_updates where match_id=$1', [id])).rows[0].status, 'LIVE');

  // Next polls never create a second entity.
  const second = await poll(db, [feedFixture(k, 'new-1', { kickoff, status: 'HALF_TIME', home: 1, minute: 45 })]);
  assert.deepEqual([second.link.created, second.link.alreadyLinked], [0, 1]);
  assert.equal((await model(db, id)).status, 'HALFTIME');
  await poll(db, [feedFixture(k, 'new-1', { kickoff, status: 'FINISHED', home: 2, away: 1, minute: 90 })]);
  shown = await model(db, id);
  assert.deepEqual([shown.status, shown.score], ['FINISHED_PENDING_VERIFICATION', { home: 2, away: 1 }]);
  assert.equal(await matchCount(db, k), 1);
  // A lagging LIVE answer after the final never reopens it (#120).
  await poll(db, [feedFixture(k, 'new-1', { kickoff, home: 2, away: 1, minute: 89 })]);
  assert.equal((await model(db, id)).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('re-issued fixture (new provider id, kickoff moved 18 h): the scheduled ghost becomes the live match, no second entity', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(1);
  const oldKickoff = new Date(Date.parse(kickoff) - 18 * 3600e3).toISOString();
  const ghost = await calendarMatch(db, k, 'ghost', { start: oldKickoff, ext: 'old-7' });
  const before = (await model(db, ghost)).status;
  assert.equal(before, 'SCHEDULED');

  const { link } = await poll(db, [feedFixture(k, 'new-7', { kickoff, home: 0, minute: 50 })]);
  assert.deepEqual([link.relinked, link.created, link.unmappedCount], [1, 0, 0]);
  assert.equal(await mapped(db, 'new-7'), ghost);
  assert.equal(await mapped(db, 'old-7'), null, 'the dead provider id is retired');
  assert.equal(await matchCount(db, k), 1);
  const payload = (await db.query('select payload from futbeat_private.entities where id=$1', [ghost])).rows[0].payload;
  assert.equal(new Date(payload.startTime).toISOString(), kickoff, 'kickoff corrected');
  assert.deepEqual([payload.provenance.externalId, payload.provenance.previousExternalIds], ['new-7', ['old-7']]);
  assert.equal(new Date(payload.provenance.kickoffCorrectedFrom).toISOString(), oldKickoff);
  assert.equal((await model(db, ghost)).status, 'LIVE');
  // Listed once, on the real day, never as a stale "scheduled" twin.
  const onReal = (await feedIds(db, kickoff)).filter((m) => m.homeTeamId === k.home);
  assert.deepEqual(onReal.map((m) => [m.id, m.status]), [[ghost, 'LIVE']]);
  assert.equal((await feedIds(db, oldKickoff)).filter((m) => m.homeTeamId === k.home && m.id !== ghost).length, 0);
}));

test('the existing linker still wins: a calendar match within 3 hours is linked, never relinked or duplicated', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(1);
  const known = await calendarMatch(db, k, 'known', { start: new Date(Date.parse(kickoff) + 3600e3).toISOString(), ext: null });
  const { link } = await poll(db, [feedFixture(k, 'feed-3', { kickoff })]);
  assert.deepEqual([link.linked, link.relinked, link.created], [1, 0, 0]);
  assert.equal(await mapped(db, 'feed-3'), known);
  assert.equal(await matchCount(db, k), 1);
  assert.equal((await model(db, known)).status, 'LIVE');
}));

test('discovery needs strong identity: nothing is created from names, unmapped teams or competitions, old or not-in-play fixtures', () => withDb(async (db) => {
  const kickoff = hoursAgo(0.5);
  const cases = [
    ['team_unmapped', await seedKnown(db, { mapTeams: false }), { kickoff, names: true }],
    ['competition_unmapped', await seedKnown(db, { mapCompetition: false }), { kickoff }],
    ['not_in_play', await seedKnown(db), { kickoff, status: 'NOT_STARTED' }],
    ['kickoff_out_of_window', await seedKnown(db), { kickoff: hoursAgo(24 * 9), status: 'FINISHED' }],
    ['no_kickoff', await seedKnown(db), { kickoff: null }],
  ];
  for (const [reason, k, options] of cases) {
    const ext = `x-${reason}`;
    const { link } = await poll(db, [feedFixture(k, ext, options)]);
    assert.deepEqual([link.created, link.relinked, link.unmappedCount], [0, 0, 1], reason);
    assert.equal(link.unmapped[0].discovery, reason);
    assert.equal(await mapped(db, ext), null, reason);
    assert.equal(await matchCount(db, k), 0, reason);
  }
  // The observation is still stored (audit) but belongs to no match.
  assert.equal((await db.query("select count(*)::int n from futbeat_private.live_match_state where canonical_match_id is null")).rows[0].n, cases.length);
}));

test('discovery never adds a second entity next to a played twin nor guesses between two ghosts', () => withDb(async (db) => {
  const kickoff = hoursAgo(1);
  // A played match of the same competition and teams 20 hours earlier.
  const p = await seedKnown(db);
  await calendarMatch(db, p, 'played', { start: new Date(Date.parse(kickoff) - 20 * 3600e3).toISOString(), ext: 'played-ext',
    status: 'VERIFIED', score: [1, 0] });
  let { link } = await poll(db, [feedFixture(p, 'twin-ext', { kickoff })]);
  assert.deepEqual([link.created, link.relinked, link.unmapped[0].discovery], [0, 0, 'played_twin_exists']);
  assert.equal(await matchCount(db, p), 1);
  // Two scheduled ghosts that could each be this fixture: ambiguous, left alone.
  const g = await seedKnown(db);
  await calendarMatch(db, g, 'g1', { start: new Date(Date.parse(kickoff) - 10 * 3600e3).toISOString(), ext: 'g1-ext' });
  await calendarMatch(db, g, 'g2', { start: new Date(Date.parse(kickoff) - 5 * 3600e3).toISOString(), ext: 'g2-ext' });
  ({ link } = await poll(db, [feedFixture(g, 'g-new', { kickoff })]));
  assert.deepEqual([link.created, link.relinked, link.unmapped[0].discovery], [0, 0, 'ambiguous_ghosts']);
  assert.equal(await matchCount(db, g), 2);
  assert.equal(await mapped(db, 'g1-ext') !== null && await mapped(db, 'g2-ext') !== null, true, 'mappings untouched');
}));

const at = (iso, hours) => new Date(Date.parse(iso) + hours * 3600e3).toISOString();
const payloadOf = (db, id) => db.query('select payload from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].payload);

test('a later scheduled game of the same pairing is never hijacked: the live fixture gets its own match', () => withDb(async (db) => {
  // Double-header: game 1 is live now (new to the calendar), game 2 is
  // scheduled 6 h later under its own provider id.
  const k = await seedKnown(db);
  const kickoff = hoursAgo(0.5);
  const later = await calendarMatch(db, k, 'later', { start: at(kickoff, 6), ext: 'dh-2' });
  const { link } = await poll(db, [feedFixture(k, 'dh-1', { kickoff, home: 1, minute: 30 })]);
  assert.deepEqual([link.relinked, link.created], [0, 1]);
  const live = await mapped(db, 'dh-1');
  assert.notEqual(live, later);
  assert.equal(await mapped(db, 'dh-2'), later, 'the later game keeps its provider id');
  assert.equal(new Date((await payloadOf(db, later)).startTime).toISOString(), at(kickoff, 6), 'and its kickoff');
  // Both are listed; the scheduled later game is not taken for a ghost.
  const listed = [...await feedIds(db, kickoff), ...await feedIds(db, at(kickoff, 6))].filter((m) => m.homeTeamId === k.home);
  assert.deepEqual([...new Set(listed.map((m) => m.id))].sort(), [later, live].sort());
  assert.deepEqual((await db.query('select hidden_match_id from futbeat_private.duplicate_calendar_fixtures(current_date-2,current_date+2) where hidden_match_id=any($1)', [[later, live]])).rows, []);
}));

test('a ghost whose own provider id is reported in the same batch is alive: never relinked', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(1);
  const ghost = await calendarMatch(db, k, 'alive', { start: at(kickoff, -10), ext: 'alive-old' });
  const { link } = await poll(db, [
    feedFixture(k, 'alive-new', { kickoff, minute: 40 }),
    feedFixture(k, 'alive-old', { kickoff: at(kickoff, -10), status: 'NOT_STARTED', minute: 0 }),
  ]);
  assert.deepEqual([link.relinked, link.created], [0, 0]);
  assert.equal(link.unmapped.find((u) => u.externalMatchId === 'alive-new').discovery, 'ghost_still_reported');
  assert.equal(await mapped(db, 'alive-old'), ghost);
  assert.equal(await mapped(db, 'alive-new'), null);
  assert.equal(new Date((await payloadOf(db, ghost)).startTime).toISOString(), at(kickoff, -10));
}));

test('wrong competition or an old ghost (> 24 h) is never relinked; the live fixture gets its own match', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(0.5);
  // Same clubs, another competition, 10 h earlier.
  const otherComp = `fb_comp_ll${k.n}_other`;
  await put(db, otherComp, 'competition', { name: `Copa ${k.n}` });
  const cup = `fb_match_ll${k.n}_cup`;
  await put(db, cup, 'match', { competitionId: otherComp, homeTeamId: k.home, awayTeamId: k.away, startTime: at(kickoff, -10),
    status: 'SCHEDULED', events: [], statistics: [], provenance: { source: 'GOAL API', receivedAt: hoursAgo(300), verificationStatus: 'PROVISIONAL' } });
  await map(db, 'match', 'cup-ext', cup);
  // The same pairing three days ago, never played.
  const old = await calendarMatch(db, k, 'old', { start: at(kickoff, -72), ext: 'old-ext' });
  const { link } = await poll(db, [feedFixture(k, 'fresh-1', { kickoff, minute: 12 })]);
  assert.deepEqual([link.relinked, link.created], [0, 1]);
  assert.equal(await mapped(db, 'cup-ext'), cup);
  assert.equal(await mapped(db, 'old-ext'), old);
  assert.equal(new Date((await payloadOf(db, cup)).startTime).toISOString(), at(kickoff, -10));
  assert.equal(new Date((await payloadOf(db, old)).startTime).toISOString(), at(kickoff, -72));
  assert.notEqual(await mapped(db, 'fresh-1'), null);
}));

test('retries are idempotent: the same fixture polled again after a relink or a creation changes nothing', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(1);
  const ghost = await calendarMatch(db, k, 'retry', { start: at(kickoff, -18), ext: 'retry-old' });
  const fixture = feedFixture(k, 'retry-new', { kickoff, minute: 50 });
  assert.equal((await poll(db, [fixture])).link.relinked, 1);
  const first = await payloadOf(db, ghost);
  // The same answer replayed twice (worker retry, duplicate cron).
  for (let i = 0; i < 2; i++) {
    const { link } = await poll(db, [fixture]);
    assert.deepEqual([link.relinked, link.created, link.alreadyLinked], [0, 0, 1]);
  }
  const again = await payloadOf(db, ghost);
  assert.deepEqual(again.provenance.previousExternalIds, ['retry-old'], 'audited once');
  assert.equal(again.provenance.relinkedAt, first.provenance.relinkedAt);
  assert.equal(await matchCount(db, k), 1);
  // Direct replay of the discovery itself (no linker in front).
  const direct = (await db.query('select futbeat_private.discover_goal_live_match($1) v', [JSON.stringify(fixture)])).rows[0].v;
  assert.deepEqual(direct, { outcome: 'already_linked', matchId: ghost });
}));

test('two creators of one provider id never leave two matches (writer outside the lock wins the mapping)', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(0.5);
  // A match some other writer created for the same provider id...
  const theirs = await calendarMatch(db, k, 'theirs', { start: kickoff, ext: null });
  // ...and maps right between discovery's lookup and its insert. PGlite has
  // one connection, so the interleaving is reproduced deterministically: the
  // concurrent writer's mapping lands when discovery inserts its entity.
  await db.exec(`create function futbeat_private.test_concurrent_mapper() returns trigger language plpgsql as $$
    begin
      if new.payload#>>'{provenance,discoveredVia}'='live-feed' then
        insert into futbeat_private.provider_entities values('goal_api','match',new.payload#>>'{provenance,externalId}','${theirs}');
      end if;
      return new;
    end $$;
    create trigger test_concurrent_mapper after insert on futbeat_private.entities
      for each row execute function futbeat_private.test_concurrent_mapper();`);
  // Linker sees nothing within 3 h? It would link "theirs": take it out of
  // reach of the linker so only discovery runs (kickoff moved 5 h).
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [theirs, JSON.stringify({ startTime: at(kickoff, 5) })]);
  const out = (await db.query('select futbeat_private.discover_goal_live_match($1) v', [JSON.stringify(feedFixture(k, 'race-1', { kickoff }))])).rows[0].v;
  assert.deepEqual(out, { outcome: 'already_linked', matchId: theirs });
  assert.equal(await mapped(db, 'race-1'), theirs);
  assert.equal(await matchCount(db, k), 1, 'the entity discovery created was removed, not orphaned');
  await db.exec('drop trigger test_concurrent_mapper on futbeat_private.entities; drop function futbeat_private.test_concurrent_mapper();');
}));

test('the catalogue resolver and discovery share one identity per provider id (either order)', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(0.5);
  await poll(db, [feedFixture(k, 'shared-1', { kickoff })]);
  const discovered = await mapped(db, 'shared-1');
  const resolve = (ext) => db.query("select futbeat_private.futbeat_resolve_global_entity('goal_api','match',$1,'') v", [ext]).then((r) => r.rows[0].v);
  assert.equal(await resolve('shared-1'), discovered, 'the ingest reuses the discovered match');
  // Ingest first: discovery then finds the mapping and creates nothing.
  const created = await resolve('shared-2');
  const { link } = await poll(db, [feedFixture(k, 'shared-2', { kickoff: at(kickoff, 6) })]);
  assert.deepEqual([link.created, link.relinked, link.alreadyLinked], [0, 0, 1]);
  assert.equal(await mapped(db, 'shared-2'), created);
  // Players keep their own lock path.
  assert.match(await db.query("select futbeat_private.futbeat_resolve_global_entity('goal_api','player','pl-1','Jugador') v").then((r) => r.rows[0].v), /^fb_player_/);
}));

test('evidence stored while a fixture was unmapped is attached once it becomes identifiable', () => withDb(async (db) => {
  const k = await seedKnown(db, { mapCompetition: false });
  const kickoff = hoursAgo(0.5);
  await poll(db, [feedFixture(k, 'late-1', { kickoff, home: 1, minute: 20 })]);
  assert.equal(await mapped(db, 'late-1'), null);
  // The competition gets mapped (e.g. by a catalogue ingest).
  await map(db, 'competition', k.compExt, k.comp);
  const { link } = await poll(db, [feedFixture(k, 'late-1', { kickoff, home: 1, minute: 22 })]);
  assert.equal(link.created, 1);
  const id = await mapped(db, 'late-1');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_observations where canonical_match_id=$1', [id])).rows[0].n, 2, 'both observations belong to the match');
  assert.deepEqual([(await model(db, id)).status, (await model(db, id)).score], ['LIVE', { home: 1, away: 0 }]);
}));

test('a terminal recovery still pending asks the results lane for its date (once per hour), instead of expiring unattended', () => withDb(async (db) => {
  const k = await seedKnown(db);
  const kickoff = hoursAgo(5);
  const id = await calendarMatch(db, k, 'rec', { start: kickoff, ext: 'rec-1' });
  const date = (await db.query("select ($1::timestamptz at time zone 'UTC')::date::text d", [kickoff])).rows[0].d;
  const recovery = (detected) => db.query(`insert into futbeat_private.live_terminal_recovery(provider,external_match_id,canonical_match_id,reason,last_live_status,detected_at,next_attempt_at)
    values('goal_api','rec-1',$1,'absent_from_live','LIVE',$2,now())
    on conflict(provider,external_match_id) do update set detected_at=excluded.detected_at,state='PENDING'`, [id, detected]);
  const demand = () => db.query("select provider_date::text d,request_count::int n from futbeat_private.results_date_user_demand where provider='goal_api'").then((r) => r.rows);
  const settle = () => db.query('select futbeat_private.settle_terminal_recovery()');

  await recovery(new Date(Date.now() - 2 * 60e3).toISOString()); // detected 2 minutes ago
  await settle();
  assert.deepEqual(await demand(), [], 'the fast detail path gets its chance first');

  await recovery(new Date(Date.now() - 15 * 60e3).toISOString());
  await settle();
  assert.deepEqual(await demand(), [{ d: date, n: 1 }]);
  await settle();
  await settle();
  assert.deepEqual(await demand(), [{ d: date, n: 1 }], 'not refreshed more than hourly');

  // The results lane takes that date first, as a priority date.
  const plan = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.deepEqual([plan.allowed, plan.date, plan.userPriority], [true, date, true], JSON.stringify(plan));

  // Once the final is known the recovery is settled: no more demand.
  await db.query('update futbeat_private.entities set payload=payload||$2::jsonb where id=$1', [id,
    JSON.stringify({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 1, away: 1 } })]);
  await db.query("update futbeat_private.results_date_user_demand set requested_at=now()-interval '2 hours'");
  await settle();
  assert.equal((await db.query("select state from futbeat_private.live_terminal_recovery where external_match_id='rec-1'")).rows[0].state, 'RESOLVED');
  assert.deepEqual(await demand(), [{ d: date, n: 1 }]);
}));

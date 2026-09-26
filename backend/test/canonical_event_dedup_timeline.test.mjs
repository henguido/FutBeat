import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { fallbackSignatureHash, normalizeFixtureEvents, parseEventMinute } from '../../supabase/functions/_shared/live_events.ts';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// #121: canonical event dedup + timeline, against the real migrations in
// PGlite. Generic fixtures only (no real teams, fixtures or players).

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
let clock = Date.now();
// Monotonic and never behind wall time (push devices register at now()).
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();

async function seed(db, { follow = true } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_ev${n}`, home: `fb_team_evh${n}`, away: `fb_team_eva${n}`, match: `fb_match_ev${n}`,
    ext: `goal-ev-${n}`, homeExt: `H${n}`, awayExt: `A${n}`, p1: `fb_player_ev${n}a`, p2: `fb_player_ev${n}b` };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  await put(ids.p1, 'player', { name: `Jugador A ${n}` });
  await put(ids.p2, 'player', { name: `Jugador B ${n}` });
  await put(ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: new Date(Date.now() - 3600e3).toISOString(), status: 'SCHEDULED', events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - 7200e3).toISOString() } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', ids.homeExt, ids.home], ['team', ids.awayExt, ids.away],
    ['player', `P1-${n}`, ids.p1], ['player', `P2-${n}`, ids.p2]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  if (follow) {
    const uid = randomUUID();
    await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)", [uid, randomUUID(), `tok-${n}`]);
    await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'match',$2)", [uid, ids.match]);
  }
  return { ...ids, n };
}

// A GOAL LIVE fixture exactly as the worker normalizes it.
function fixture(s, { home = 0, away = 0, minute = 10, status = 'LIVE', events = [], cards = [], substitutions = [] } = {}) {
  const raw = { id: s.ext, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards, substitutions };
  const obs = { externalMatchId: s.ext, status, minute, score: { home, away }, events: normalizeFixtureEvents(raw), rawPayload: raw };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([obs, ++seq])).digest('hex');
  return obs;
}
const goalRow = (s, { id, time, side = 'home', player = 'P1' }) => ({
  id, type: 'goal', time,
  ...(side === 'home' ? { homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre' } : { awayScorerId: `${player}-${s.n}`, awayScorer: 'Nombre' }),
});
const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const visible = (db, id) => db.query('select futbeat_private.match_read_model(payload)->\'events\' v from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].v ?? []);
const goals = async (db, id) => (await visible(db, id)).filter((e) => e.type === 'GOAL');
const stored = (db, id) => db.query("select id,payload,notify_candidate from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL' order by first_seen_at,id", [id]).then((r) => r.rows);
const goalPushes = (db, id) => db.query("select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1 and e.event_type='GOAL'", [id]).then((r) => r.rows[0].n);
const project = (db, events, home = 'h', away = 'a') => db.query('select futbeat_private.visible_match_events($1,$2,$3) v', [JSON.stringify(events), home, away]).then((r) => r.rows[0].v);

test('A. same observation carries the rich GOAL with the score change: no synthetic duplicate', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  const rows = await stored(db, s.match);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].payload.synthetic, undefined);
  assert.equal(rows[0].payload.playerId, s.p1);
  assert.equal((await goals(db, s.match)).length, 1);
  assert.equal(await goalPushes(db, s.match), 1);
}));

test('A2. an OLD rich goal in the payload never hides a new score increase', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const first = goalRow(s, { id: '9001', time: '19' });
  await record(db, fixture(s, { home: 1, minute: 20, events: [first] }));
  // Second goal: score rises again, the payload still only has the first goal.
  await record(db, fixture(s, { home: 2, minute: 30, events: [first] }));
  const rows = await stored(db, s.match);
  assert.equal(rows.filter((r) => r.payload.synthetic).length, 1, 'synthetic fallback for the unexplained goal');
  assert.equal((await goals(db, s.match)).length, 2);
  assert.equal(await goalPushes(db, s.match), 2);
}));

test('B/J. synthetic first, rich later: both auditable, one visible (rich), one push', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 25 }));
  assert.equal(await goalPushes(db, s.match), 1, 'provisional goal notifies');
  await record(db, fixture(s, { home: 1, minute: 27, events: [goalRow(s, { id: '9002', time: '23' })] }));
  const rows = await stored(db, s.match);
  assert.equal(rows.length, 2, 'audit keeps both rows');
  assert.deepEqual(rows.map((r) => Boolean(r.payload.synthetic)), [true, false]);
  assert.equal(rows[1].notify_candidate, false, 'rich twin never notifies');
  const shown = await goals(db, s.match);
  assert.equal(shown.length, 1);
  assert.deepEqual([shown[0].playerId, shown[0].minute, shown[0].synthetic], [s.p1, 23, undefined]);
  assert.equal(await goalPushes(db, s.match), 1);
  const [live] = (await db.query('select latest_events from public.live_match_updates where match_id=$1', [s.match])).rows;
  assert.equal(live.latest_events.filter((e) => e.type === 'GOAL').length, 1, 'realtime sends one goal');
}));

test('J2. rich first, synthetic later (score lagged): the synthetic never pushes again', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { minute: 21, events: [goalRow(s, { id: '9003', time: '20', side: 'away', player: 'P2' })] }));
  const pushes = await goalPushes(db, s.match);
  await record(db, fixture(s, { away: 1, minute: 22, events: [goalRow(s, { id: '9003', time: '20', side: 'away', player: 'P2' })] }));
  assert.equal((await stored(db, s.match)).length, 2);
  assert.equal(await goalPushes(db, s.match), pushes);
  assert.equal((await goals(db, s.match)).length, 1);
}));

test('C. two genuine same-team goals at 20 and 23 stay two, before and after rich evidence', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  const g1 = goalRow(s, { id: '9101', time: '20' });
  await record(db, fixture(s, { home: 1, minute: 20, events: [g1] }));
  await record(db, fixture(s, { home: 2, minute: 23, events: [g1] })); // synthetic for goal 2
  assert.equal((await goals(db, s.match)).length, 2, 'rich goal 1 never absorbs the synthetic of goal 2');
  assert.equal(await goalPushes(db, s.match), 2);
  const g2 = goalRow(s, { id: '9102', time: '23' }); // same player scores again
  await record(db, fixture(s, { home: 2, minute: 24, events: [g1, g2] }));
  const shown = await goals(db, s.match);
  assert.deepEqual(shown.map((e) => [e.minute, Boolean(e.synthetic)]), [[20, false], [23, false]]);
  assert.equal(await goalPushes(db, s.match), 2, 'the rich twin of goal 2 does not push again');
}));

test('D. two providers report the same player/team goal at the same minute: one visible', () => withDb(async (db) => {
  const events = [
    { id: 'fb_event_x1', type: 'GOAL', minute: 40, teamId: 'h', playerId: 'p', providerEventKey: '77', provider: 'goal_api' },
    { id: 'fb_event_x2', type: 'GOAL', minute: 40, teamId: 'h', playerId: 'p', providerEventKey: 'af-5', provider: 'api_football' },
    { id: 'fb_event_x3', type: 'GOAL', minute: 41, teamId: 'h', playerId: 'p', providerEventKey: 'sm-9', provider: 'sportmonks' },
  ];
  const shown = await project(db, events);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].id, 'fb_event_x1');
}));

test('E. different players close together (goals and cards) all remain', () => withDb(async (db) => {
  const shown = await project(db, [
    { id: 'fb_event_e1', type: 'GOAL', minute: 20, teamId: 'h', playerId: 'p1' },
    { id: 'fb_event_e2', type: 'GOAL', minute: 20, teamId: 'h', playerId: 'p2' },
    { id: 'fb_event_e3', type: 'YELLOW_CARD', minute: 55, teamId: 'a', playerId: 'p3' },
    { id: 'fb_event_e4', type: 'YELLOW_CARD', minute: 55, teamId: 'a', playerId: 'p4' },
    { id: 'fb_event_e5', type: 'YELLOW_CARD', minute: 55, teamId: 'h', playerId: 'p3' },
    // Same provider, two distinct upstream rows: never merged.
    { id: 'fb_event_e6', type: 'GOAL', minute: 70, teamId: 'a', providerEventKey: '501', provider: 'goal_api' },
    { id: 'fb_event_e7', type: 'GOAL', minute: 70, teamId: 'a', providerEventKey: '502', provider: 'goal_api' },
  ]);
  assert.equal(shown.length, 7);
}));

test('conservative rich-vs-rich: type + team + minute alone never merges real events', () => withDb(async (db) => {
  const goal = (id, over = {}) => ({ id, type: 'GOAL', minute: 30, teamId: 'h', ...over });
  // A. same team/minute, no players, different upstream ids -> 2.
  assert.equal((await project(db, [goal('a1', { providerEventKey: '601', provider: 'goal_api' }), goal('a2', { providerEventKey: '602', provider: 'goal_api' })])).length, 2);
  // A'. no player, no upstream id, no score-after -> keep both.
  assert.equal((await project(db, [goal('a3'), goal('a4')])).length, 2);
  // B. no players, score after 1-0 and 2-0 -> 2.
  assert.equal((await project(db, [goal('b1', { score: { home: 1, away: 0 } }), goal('b2', { score: { home: 2, away: 0 } })])).length, 2);
  // Different score-after is always two, even for the same player.
  assert.equal((await project(db, [goal('b3', { playerId: 'p', score: { home: 1, away: 0 } }), goal('b4', { playerId: 'p', score: { home: 2, away: 0 } })])).length, 2);
  // C. two providers, same canonical player + team + minute -> 1.
  assert.equal((await project(db, [goal('c1', { playerId: 'p', providerEventKey: '9', provider: 'goal_api' }), goal('c2', { playerId: 'p', providerEventKey: 'x-9', provider: 'api_football' })])).length, 1);
  // D. two providers, no player, same team/minute and the same score-after -> 1.
  assert.equal((await project(db, [goal('d1', { score: { home: 1, away: 0 }, provider: 'goal_api' }), goal('d2', { score: { home: 1, away: 0 }, provider: 'api_football' })])).length, 1);
  // Player on one side only: needs the same score-after; without it both stay.
  assert.equal((await project(db, [goal('d3', { playerId: 'p', score: { home: 1, away: 0 } }), goal('d4', { score: { home: 1, away: 0 } })])).length, 1);
  assert.equal((await project(db, [goal('d5', { playerId: 'p' }), goal('d6')])).length, 2);
  // E. two rich cards at the same minute/team without enough identity -> both.
  const card = (id, over = {}) => ({ id, type: 'YELLOW_CARD', minute: 44, teamId: 'a', ...over });
  assert.equal((await project(db, [card('e1'), card('e2')])).length, 2);
  assert.equal((await project(db, [card('e3', { playerId: 'p1' }), card('e4')])).length, 2);
  assert.equal((await project(db, [card('e5', { playerId: 'p1' }), card('e6', { playerId: 'p1', provider: 'api_football' })])).length, 1);
  const sub = (id, over = {}) => ({ id, type: 'SUBSTITUTION', minute: 60, teamId: 'h', ...over });
  assert.equal((await project(db, [sub('s1'), sub('s2')])).length, 2);
  assert.equal((await project(db, [sub('s3', { playerId: 'o', assistPlayerId: 'i1' }), sub('s4', { playerId: 'o', assistPlayerId: 'i2' })])).length, 2);
  // F. synthetic + rich still folds into one (notification: see B/J).
  assert.equal((await project(db, [goal('f1', { playerId: 'p', minute: 23 }),
    { id: 'f2', type: 'GOAL', minute: 25, teamId: 'h', synthetic: true, score: { home: 1, away: 0 } }])).length, 1);
}));

const liveKeys = (db, s) => db.query("select event_key from futbeat_private.live_events where provider='goal_api' and external_match_id=$1 order by first_seen_at,event_key", [s.ext]).then((r) => r.rows.map((x) => x.event_key));
const canonicalCount = (db, s, type) => db.query('select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type=$2', [s.match, type]).then((r) => r.rows[0].n);
const outbox = (db, s) => db.query('select count(*)::int n from futbeat_private.notification_outbox o join futbeat_private.canonical_events e on e.id=o.event_id where e.match_id=$1', [s.match]).then((r) => r.rows[0].n);
const anonymousGoal = (over = {}) => ({ type: 'goal', time: '90+5', ...over });

test('fallback hash: standard 64-bit FNV-1a, deterministic, distinct for distinct signatures', () => {
  // Published FNV-1a 64 test vectors.
  assert.equal(fallbackSignatureHash(''), 'cbf29ce484222325');
  assert.equal(fallbackSignatureHash('a'), 'af63dc4c8601ec8c');
  assert.equal(fallbackSignatureHash('foobar'), '85944171f73967e8');
  const one = JSON.stringify(['GOAL', 90, 5, '', '', '', '1-0', 'GOAL']);
  const two = JSON.stringify(['GOAL', 90, 5, '', '', '', '2-0', 'GOAL']);
  assert.match(fallbackSignatureHash(one), /^[0-9a-f]{16}$/);
  assert.notEqual(fallbackSignatureHash(one), fallbackSignatureHash(two));
  assert.equal(fallbackSignatureHash(one), fallbackSignatureHash(JSON.stringify(['GOAL', 90, 5, '', '', '', '1-0', 'GOAL'])));
  // Non-ASCII evidence is hashed over UTF-8 bytes, still deterministic.
  assert.equal(fallbackSignatureHash('Sustitución ñ'), fallbackSignatureHash('Sustitución ñ'));
  assert.notEqual(fallbackSignatureHash('Sustitución ñ'), fallbackSignatureHash('Sustitucion n'));
});

test('fallback identity A: anonymous same-minute goals with different score-after are two events', () => withDb(async (db) => {
  const s = await seed(db);
  const rows = [anonymousGoal({ score: '1 - 0' }), anonymousGoal({ score: '2 - 0' })];
  const [a, b] = normalizeFixtureEvents({ events: rows });
  assert.notEqual(a.eventKey, b.eventKey);
  assert.match(a.eventKey, /^fallback:[0-9a-f]{16}:1$/);
  assert.deepEqual([a.minute, a.extraMinute, a.scoreAfter], [90, 5, { home: 1, away: 0 }]);
  await record(db, fixture(s, { minute: 95 }));
  await record(db, fixture(s, { minute: 96, events: rows }));
  assert.equal((await liveKeys(db, s)).length, 2);
  assert.equal(await canonicalCount(db, s, 'GOAL'), 2);
  const shown = await goals(db, s.match);
  assert.equal(shown.length, 2, 'different score-after: never collapsed');
  assert.deepEqual(shown.map((g) => g.score).sort((x, y) => x.home - y.home), [{ home: 1, away: 0 }, { home: 2, away: 0 }]);
}));

test('fallback identity B/C: identical anonymous goals are :1 and :2; repeating the payload adds nothing', () => withDb(async (db) => {
  const s = await seed(db);
  const rows = [anonymousGoal(), anonymousGoal()];
  const keys = normalizeFixtureEvents({ events: rows }).map((e) => e.eventKey);
  assert.equal(keys[0].replace(/:1$/, ':2'), keys[1]);
  assert.deepEqual(normalizeFixtureEvents({ events: rows }).map((e) => e.eventKey), keys, 'deterministic');
  await record(db, fixture(s, { minute: 95 }));
  await record(db, fixture(s, { minute: 96, events: rows }));
  const pushes = await outbox(db, s);
  assert.deepEqual(await liveKeys(db, s), keys);
  assert.equal(await canonicalCount(db, s, 'GOAL'), 2);
  assert.equal((await goals(db, s.match)).length, 2, 'no evidence to collapse: both kept');
  // C. the same events again (new poll) and the exact same observation twice.
  await record(db, fixture(s, { minute: 97, events: rows }));
  const same = fixture(s, { minute: 98, events: rows });
  await record(db, same);
  const dup = await record(db, same);
  assert.equal(dup.duplicates, 1);
  assert.deepEqual(await liveKeys(db, s), keys);
  assert.equal(await canonicalCount(db, s, 'GOAL'), 2);
  assert.equal(await outbox(db, s), pushes, 'no duplicate notifications');
}));

test('fallback identity D: a second identical occurrence gets :2 and the first keeps its key and id', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { minute: 94 }));
  await record(db, fixture(s, { minute: 95, events: [anonymousGoal()] }));
  const [first] = await liveKeys(db, s);
  const [firstRow] = await stored(db, s.match);
  const pushes = await outbox(db, s);
  await record(db, fixture(s, { minute: 97, events: [anonymousGoal(), anonymousGoal()] }));
  assert.deepEqual(await liveKeys(db, s), [first, first.replace(/:1$/, ':2')]);
  const rows = await stored(db, s.match);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].id, firstRow.id, 'first occurrence keeps its canonical id');
  assert.equal(await outbox(db, s), pushes + 1, 'only the genuinely new goal notifies');
  await record(db, fixture(s, { minute: 98, events: [anonymousGoal(), anonymousGoal()] }));
  assert.equal(await outbox(db, s), pushes + 1);
}));

test('fallback identity: a pre-#121 canonical row is claimed by the first occurrence, never duplicated', () => withDb(async (db) => {
  const s = await seed(db);
  const legacy = (await db.query("select 'fb_event_'||md5(concat_ws('|',$1::text,'goal_api','GOAL',90,'5',null,null,'')) v", [s.match])).rows[0].v;
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values($1,$2,'goal_api','GOAL',$3,now()-interval '5 minutes')`, [legacy, s.match, JSON.stringify({ id: legacy, matchId: s.match, type: 'GOAL', minute: 90, extraMinute: 5 })]);
  await record(db, fixture(s, { minute: 95 }));
  await record(db, fixture(s, { minute: 96, events: [anonymousGoal(), anonymousGoal()] }));
  const rows = await stored(db, s.match);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].id, legacy);
  assert.match(rows[0].payload.providerEventKey, /:1$/);
  assert.match(rows[1].payload.providerEventKey, /:2$/);
}));

test('fallback identity E/F: anonymous cards/subs/VAR are kept; rows with a provider id are unchanged', () => withDb(async (db) => {
  const s = await seed(db);
  const cards = [{ card: 'Yellow Card', time: '44' }, { card: 'Yellow Card', time: '44' }];
  const [c1, c2] = normalizeFixtureEvents({ cards });
  assert.notEqual(c1.eventKey, c2.eventKey);
  const [s1, s2] = normalizeFixtureEvents({ homeTeam: { id: 'h' }, substitutions: [{ team: 'home', time: '60' }, { team: 'home', time: '60' }] });
  assert.notEqual(s1.eventKey, s2.eventKey);
  const vars = normalizeFixtureEvents({ events: [{ type: 'VAR', time: '70' }, { type: 'VAR', time: '70' }] });
  assert.notEqual(vars[0].eventKey, vars[1].eventKey);
  await record(db, fixture(s, { minute: 43 }));
  await record(db, fixture(s, { minute: 45, cards }));
  assert.equal(await canonicalCount(db, s, 'YELLOW_CARD'), 2);
  assert.equal((await visible(db, s.match)).filter((e) => e.type === 'YELLOW_CARD').length, 2);

  // F. provider row ids stay the identity and the canonical id formula is unchanged.
  const t = await seed(db);
  const withId = [goalRow(t, { id: '7001', time: '12' }), goalRow(t, { id: '7002', time: '12' })];
  assert.deepEqual(normalizeFixtureEvents({ homeTeam: { id: t.homeExt }, events: withId }).map((e) => e.eventKey), ['7001', '7002']);
  await record(db, fixture(t, { minute: 11 }));
  await record(db, fixture(t, { minute: 13, events: [withId[0]] }));
  const expected = (await db.query("select 'fb_event_'||md5(concat_ws('|',$1::text,'goal_api','GOAL',12,null,$2::text,$3::text,'')) v", [t.match, t.homeExt, `P1-${t.n}`])).rows[0].v;
  assert.equal((await stored(db, t.match))[0].id, expected);
}));

test('F/G. added time survives LIVE and detail: 90+5 is minute 90 + extraMinute 5 and one visible event', () => withDb(async (db) => {
  for (const [text, expected] of [['18', [18, null]], ['45+2', [45, 2]], ['90+5', [90, 5]], ["90 + 5'", [90, 5]], [null, [null, null]], ['', [null, null]], ['abc', [null, null]]]) {
    const { minute, extraMinute } = parseEventMinute(text);
    assert.deepEqual([minute, extraMinute], expected, String(text));
  }
  const s = await seed(db);
  const row = goalRow(s, { id: '9500', time: '90+5' });
  const card = { id: '9501', card: 'Yellow Card', time: '45+2', homePlayerId: `P1-${s.n}`, homeFault: 'Nombre' };
  const sub = { id: '9502', team: 'away', time: '90+3', substitutionPlayerId: `P2-${s.n}|P1-${s.n}` };
  const [liveGoal, liveCard, liveSub] = normalizeFixtureEvents({ homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt },
    events: [row], cards: [card], substitutions: [sub] });
  assert.deepEqual([liveGoal.minute, liveGoal.extraMinute, liveGoal.eventKey], [90, 5, '9500']);
  assert.deepEqual([liveCard.minute, liveCard.extraMinute], [45, 2]);
  assert.deepEqual([liveSub.minute, liveSub.extraMinute], [90, 3]);
  // Fallback identity (no upstream id) keeps added time apart.
  const [a, b] = normalizeFixtureEvents({ homeTeam: { id: 'h' }, events: [
    { type: 'goal', time: '90+2', homeScorerId: 'x' }, { type: 'goal', time: '90+5', homeScorerId: 'x' }] });
  assert.notEqual(a.eventKey, b.eventKey);

  const detail = normalizeMatchDetail({ payload: { events: [row], cards: [card], substitutions: [sub] } });
  const detailGoal = detail.incidents.find((e) => e.type === 'GOAL');
  assert.deepEqual([detailGoal.minute, detailGoal.extraMinute, detailGoal.providerEventId], [90, 5, liveGoal.eventKey]);
  assert.deepEqual(detail.incidents.map((e) => e.providerEventId).sort(), ['9500', '9501', '9502']);

  await record(db, fixture(s, { home: 0, minute: 88 }));
  await record(db, fixture(s, { home: 1, minute: 95, events: [row] }));
  const [stored90] = await stored(db, s.match);
  assert.deepEqual([stored90.payload.minute, stored90.payload.extraMinute, stored90.payload.providerEventKey], [90, 5, '9500']);
  // A legacy LIVE row of the same upstream event without added time collapses into it.
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values('fb_event_legacy90',$1,'goal_api','GOAL',$2,now())`, [s.match, JSON.stringify({ id: 'fb_event_legacy90', matchId: s.match, type: 'GOAL', minute: 90, teamId: s.home, playerId: s.p1 })]);
  const shown = await goals(db, s.match);
  assert.equal(shown.length, 1);
  assert.deepEqual([shown[0].minute, shown[0].extraMinute], [90, 5]);
}));

test('H/I. synthetic-only goal is a usable plain GOAL; technical copy never visible', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { away: 1, minute: 33 }));
  const [row] = await stored(db, s.match);
  assert.equal(row.payload.detail, 'Marcador actualizado', 'audit text kept internally');
  const events = await visible(db, s.match);
  const [goal] = events.filter((e) => e.type === 'GOAL');
  assert.deepEqual([goal.teamId, goal.minute, goal.synthetic, goal.score], [s.away, 33, true, { home: 0, away: 1 }]);
  assert.equal(goal.detail, undefined);
  assert.ok(!JSON.stringify(events).includes('Marcador actualizado'));
  const [live] = (await db.query('select latest_events from public.live_match_updates where match_id=$1', [s.match])).rows;
  assert.ok(!JSON.stringify(live.latest_events).includes('Marcador actualizado'));
  assert.ok(!JSON.stringify(await project(db, [{ id: 'x', type: 'GOAL', minute: 1, detail: 'Marcador actualizado' }])).includes('Marcador actualizado'));
}));

test('K. KICKOFF/HALFTIME/FULL_TIME are preserved and never merged with football events', () => withDb(async (db) => {
  const shown = await project(db, [
    { id: 'fb_event_k', type: 'KICKOFF', minute: 0 },
    { id: 'fb_event_g', type: 'GOAL', minute: 0, teamId: 'h' },
    { id: 'fb_event_h', type: 'HALFTIME', minute: 45 },
    { id: 'fb_event_c', type: 'YELLOW_CARD', minute: 45, extraMinute: 2, teamId: 'a' },
    { id: 'fb_event_f', type: 'FULL_TIME', minute: null },
    { id: 'fb_event_f2', type: 'FULL_TIME', minute: 90 },
  ]);
  assert.deepEqual(shown.map((e) => e.id).sort(), ['fb_event_c', 'fb_event_f', 'fb_event_f2', 'fb_event_g', 'fb_event_h', 'fb_event_k']);
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { minute: 45, status: 'HALFTIME' }));
  await record(db, fixture(s, { minute: 90, status: 'FINISHED_PENDING_VERIFICATION' }));
  const types = (await visible(db, s.match)).map((e) => e.type).sort();
  assert.deepEqual(types, ['FULL_TIME', 'HALFTIME', 'KICKOFF']);
}));

test('no workflow, cron or provider configuration touched by #121', async () => {
  const { readFile } = await import('node:fs/promises');
  const sql = await readFile(new URL('../../supabase/migrations/20260926030000_canonical_event_dedup_timeline.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /cron\.schedule|provider_hub_config|provider_quota_policy|delete from futbeat_private\.canonical_events|truncate/i);
});

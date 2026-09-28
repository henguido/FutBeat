import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { normalizeFixtureEvents } from '../../supabase/functions/_shared/live_events.ts';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// #106 Free player alerts against the real migrations in PGlite: official
// lineup starter/bench and LIVE player events, fanned out internally from
// one canonical observation. Generic ids; no provider is ever called.

let seq = 0;
async function world(db) {
  const n = ++seq;
  const ids = {
    comp: `fb_comp_pa${n}`, home: `fb_team_pah${n}`, away: `fb_team_paa${n}`, match: `fb_match_pa${n}`,
    ext: `pa-${n}`, homeExt: `pah-${n}`, awayExt: `paa-${n}`,
    star: `fb_player_star${n}`, mate: `fb_player_mate${n}`, rival: `fb_player_rival${n}`, other: `fb_player_other${n}`,
  };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  await put(ids.match, 'match', {
    competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, status: 'SCHEDULED',
    startTime: new Date(Date.now() + 30 * 60000).toISOString(), events: [],
    provenance: { receivedAt: new Date(Date.now() - 3600e3).toISOString() },
  });
  for (const [id, name] of [[ids.star, 'Estrella'], [ids.mate, 'Compañero'], [ids.rival, 'Rival'], [ids.other, 'Otro']]) {
    await put(id, 'player', { name });
  }
  const map = (kind, external, canonical, provider = 'goal_api') =>
    db.query('insert into futbeat_private.provider_entities values($1,$2,$3,$4)', [provider, kind, external, canonical]);
  await map('match', ids.ext, ids.match);
  await map('team', ids.homeExt, ids.home);
  await map('team', ids.awayExt, ids.away);
  await map('player', `p-star-${n}`, ids.star);
  await map('player', `p-mate-${n}`, ids.mate);
  await map('player', `p-rival-${n}`, ids.rival);
  await map('player', `p-other-${n}`, ids.other);
  ids.pStar = `p-star-${n}`; ids.pMate = `p-mate-${n}`; ids.pRival = `p-rival-${n}`;
  return ids;
}

async function user(db, follows, prefs = null) {
  const uid = randomUUID();
  const device = randomUUID();
  await db.query(`insert into futbeat_private.push_devices(id,user_id,installation_id,platform,transport,token,enabled,registered_at)
    values($1,$2,$3,'android','test',$4,true,now()-interval '1 day')`, [device, uid, randomUUID(), `tok-${uid}`]);
  for (const [type, id] of follows) {
    await db.query(`insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
      values($1,$2,$3,now()-interval '1 day')`, [uid, type, id]);
  }
  if (prefs) {
    await db.query(`insert into futbeat_private.user_preferences(user_id,notify_goals,notify_cards,notify_lineups)
      values($1,$2,$3,$4)`, [uid, prefs.goals ?? true, prefs.cards ?? true, prefs.lineups ?? true]);
  }
  return uid;
}

const outbox = (db, uid) => db.query(`select notification_key,event_id,message,state from futbeat_private.notification_outbox
  where user_id=$1 order by created_at,id`, [uid]).then((r) => r.rows);
const ledger = (db) => db.query('select count(*)::int n from futbeat_private.provider_call_ledger').then((r) => r.rows[0].n);

// ---------------------------------------------------------------- lineups
function lineup(ids, { homeStarters = [], homeBench = [], fill = true } = {}) {
  const rows = [];
  const add = (team, type, playerId, name) => rows.push({ team, type, playerId, lineupPlayer: name });
  for (const [pid, name] of homeStarters) add('home', 'starting_lineups', pid, name);
  if (fill) for (let i = homeStarters.length; i < 11; i++) add('home', 'starting_lineups', `${ids.ext}-hf${i}`, `Relleno ${i}`);
  for (const [pid, name] of homeBench) add('home', 'substitutes', pid, name);
  for (let i = 0; i < 11; i++) add('away', 'starting_lineups', `${ids.ext}-af${i}`, `Visitante ${i}`);
  return { lineups: rows };
}
const store = (db, ids, payload, fetchedAt = new Date()) => db.query(
  'select public.futbeat_store_match_detail($1,$2,$3,$4) v',
  [ids.match, ids.ext, fetchedAt.toISOString(), JSON.stringify(payload)]);
const lineupAlerts = async (db, uid) => (await outbox(db, uid)).filter((r) => r.message.type === 'LINEUP');

test('1/2/4/5/21/22. official starter and bench alert once each; repeats never duplicate; Free; zero provider calls', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fanStar = await user(db, [['player', ids.star]]);
    const fanMate = await user(db, [['player', ids.mate]]);
    const calls = await ledger(db);
    const payload = lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']], homeBench: [[ids.pMate, 'Compañero']] });
    await store(db, ids, payload);
    let star = await lineupAlerts(db, fanStar);
    let mate = await lineupAlerts(db, fanMate);
    assert.equal(star.length, 1);
    assert.equal(star[0].notification_key, `lineup:${ids.match}:${ids.star}:starter`);
    assert.match(star[0].message.title, /Estrella es titular/);
    assert.equal(mate.length, 1);
    assert.equal(mate[0].notification_key, `lineup:${ids.match}:${ids.mate}:bench`);
    // Same lineup refreshed twice: still one each.
    await store(db, ids, payload, new Date(Date.now() + 1000));
    await store(db, ids, payload, new Date(Date.now() + 2000));
    assert.equal((await lineupAlerts(db, fanStar)).length, 1);
    assert.equal((await lineupAlerts(db, fanMate)).length, 1);
    assert.equal(await ledger(db), calls, 'fan-out never calls a provider');
  } finally { await db.close(); }
});

test('3. probable lineups never alert: too early, or an incomplete XI', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fan = await user(db, [['player', ids.star]]);
    const payload = lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']] });
    // Observed 3 h before kickoff: outside the official window.
    await store(db, ids, payload, new Date(Date.now() - 150 * 60000));
    assert.equal((await lineupAlerts(db, fan)).length, 0);
    // In the window but only 5 starters: not a confirmed XI.
    await store(db, ids, lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']], fill: false }), new Date());
    assert.equal((await lineupAlerts(db, fan)).length, 0);
    // The complete official XI later: exactly one alert.
    await store(db, ids, payload, new Date(Date.now() + 1000));
    assert.equal((await lineupAlerts(db, fan)).length, 1);
  } finally { await db.close(); }
});

test('6. conservative corrections: starter -> bench alerts once more, back to starter never storms', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fan = await user(db, [['player', ids.star]]);
    await store(db, ids, lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']] }));
    await store(db, ids, lineup(ids, { homeBench: [[ids.pStar, 'Estrella']] }), new Date(Date.now() + 1000));
    await store(db, ids, lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']] }), new Date(Date.now() + 2000));
    await store(db, ids, lineup(ids, { homeBench: [[ids.pStar, 'Estrella']] }), new Date(Date.now() + 3000));
    const keys = (await lineupAlerts(db, fan)).map((r) => r.notification_key.split(':').at(-1));
    assert.deepEqual(keys, ['starter', 'bench']);
    const state = (await db.query('select role,official,notified_roles from futbeat_private.lineup_player_alerts where match_id=$1 and player_id=$2', [ids.match, ids.star])).rows[0];
    assert.deepEqual(state, { role: 'bench', official: true, notified_roles: ['starter', 'bench'] });
  } finally { await db.close(); }
});

test('lineup alerts respect notify_lineups and historical detail never alerts', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const off = await user(db, [['player', ids.star]], { lineups: false });
    await store(db, ids, lineup(ids, { homeStarters: [[ids.pStar, 'Estrella']] }));
    assert.equal((await lineupAlerts(db, off)).length, 0);

    const old = await world(db);
    await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb((now()-interval '3 days')::text)) where id=$1", [old.match]);
    const fan = await user(db, [['player', old.star]]);
    await store(db, old, lineup(old, { homeStarters: [[old.pStar, 'Estrella']] }));
    assert.equal((await lineupAlerts(db, fan)).length, 0, 'a backfilled historical lineup is silent');
  } finally { await db.close(); }
});

// ------------------------------------------------------------- LIVE events
let clock = Date.now();
const tick = () => new Date((clock = Math.max(clock + 1000, Date.now()))).toISOString();
function live(db, ids, events, { minute = 60, provider = 'goal_api', ext = ids.ext } = {}) {
  const obs = { externalMatchId: ext, status: 'LIVE', minute, score: { home: events.filter((e) => e.type === 'GOAL').length, away: 0 }, events, nonce: ++seq };
  obs.payloadHash = createHash('sha256').update(JSON.stringify(obs)).digest('hex');
  return db.query('select public.futbeat_record_live_batch($1,$2,$3) v', [provider, tick(), JSON.stringify([obs])]);
}
const ev = (ids, key, type, minute, player, assist = null, team = ids.homeExt) => ({
  eventKey: key, type, minute, teamExternalId: team, playerExternalId: player,
  ...(assist ? { assistExternalId: assist } : {}), payload: { time: { elapsed: minute } },
});
async function started(db, ids) {
  // First batch establishes the baseline and never notifies.
  await live(db, ids, [], { minute: 1 });
}

test('7-13. player events: goal, assist, yellow, red, in, out, missed penalty -> one alert each for the right follower', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fanStar = await user(db, [['player', ids.star]]);
    const fanMate = await user(db, [['player', ids.mate]]);
    await started(db, ids);
    const events = [
      ev(ids, 'g1', 'GOAL', 10, ids.pStar, ids.pMate),
      ev(ids, 'y1', 'YELLOW_CARD', 20, ids.pStar),
      ev(ids, 'r1', 'RED_CARD', 30, ids.pMate),
      ev(ids, 's1', 'SUBSTITUTION', 40, ids.pMate, ids.pStar),
      ev(ids, 'm1', 'MISSED_PENALTY', 45, ids.pStar),
    ];
    for (let i = 1; i <= events.length; i++) await live(db, ids, events.slice(0, i), { minute: events[i - 1].minute });
    const titles = async (uid) => (await outbox(db, uid)).map((r) => r.message.title.replace(/^\S+ \d+' /, ''));
    // SUBSTITUTION: playerId (mate) leaves, assistPlayerId (star) enters.
    assert.deepEqual(await titles(fanStar), ['Gol de Estrella', 'Amarilla para Estrella', 'Entra Estrella', 'Penal fallado por Estrella']);
    assert.deepEqual(await titles(fanMate), ['Asistencia de Compañero', 'Roja para Compañero', 'Sale Compañero']);
    for (const row of await outbox(db, fanStar)) {
      assert.equal(row.message.playerId, ids.star);
      assert.deepEqual(row.message.subjectRefs, [{ type: 'player', id: ids.star }]);
    }
  } finally { await db.close(); }
});

test('14/20. unattributable or unrelated players: no player alert', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fanStar = await user(db, [['player', ids.star]]);
    const fanOther = await user(db, [['player', ids.other]]);
    await started(db, ids);
    await live(db, ids, [ev(ids, 'g-unknown', 'GOAL', 12, 'provider-id-without-mapping')], { minute: 12 });
    await live(db, ids, [ev(ids, 'g-unknown', 'GOAL', 12, 'provider-id-without-mapping'), ev(ids, 'g-rival', 'GOAL', 14, ids.pRival)], { minute: 14 });
    assert.equal((await outbox(db, fanStar)).length, 0);
    assert.equal((await outbox(db, fanOther)).length, 0);
    const stored = (await db.query("select payload from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL' order by first_seen_at", [ids.match])).rows;
    assert.equal(stored[0].payload.playerId, undefined, 'unknown identity stays null');
  } finally { await db.close(); }
});

test('15/16/17. team + match + player follow: one logical notification with the player copy; repeats and a second provider never add one', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    await db.query("insert into futbeat_private.provider_entities values('api_football','match',$1,$2),('api_football','team',$3,$4),('api_football','player',$5,$6)",
      [`af-${ids.ext}`, ids.match, `af-${ids.homeExt}`, ids.home, `af-${ids.pStar}`, ids.star]);
    const fan = await user(db, [['match', ids.match], ['team', ids.home], ['player', ids.star]]);
    const teamOnly = await user(db, [['team', ids.home]]);
    await started(db, ids);
    const goal = ev(ids, 'g1', 'GOAL', 33, ids.pStar);
    await live(db, ids, [goal], { minute: 33 });
    await live(db, ids, [goal], { minute: 34 });
    await live(db, ids, [{ ...goal, eventKey: 'g1-rekeyed-comment' }], { minute: 35 });
    // Another provider confirms the same goal (same canonical player/minute).
    await live(db, ids, [], { minute: 1, provider: 'api_football', ext: `af-${ids.ext}` });
    await live(db, ids, [{ ...goal, eventKey: 'af-g1', teamExternalId: `af-${ids.homeExt}`, playerExternalId: `af-${ids.pStar}` }],
      { minute: 36, provider: 'api_football', ext: `af-${ids.ext}` });
    const rows = await outbox(db, fan);
    assert.equal(rows.filter((r) => r.message.type === 'GOAL').length, 1);
    assert.match(rows[0].message.title, /Gol de Estrella/);
    const generic = await outbox(db, teamOnly);
    assert.equal(generic.filter((r) => r.message.type === 'GOAL').length, 1);
    assert.equal(generic[0].message.playerId, undefined, 'team followers keep the generic copy');
  } finally { await db.close(); }
});

test('18. unfollow before dispatch cancels a player-only alert, keeps a team-backed one', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const playerOnly = await user(db, [['player', ids.star]]);
    const both = await user(db, [['team', ids.home], ['player', ids.star]]);
    await started(db, ids);
    await live(db, ids, [ev(ids, 'g1', 'GOAL', 50, ids.pStar)], { minute: 50 });
    await db.query("delete from futbeat_private.push_follows where entity_type='player'");
    const claimed = (await db.query("select public.futbeat_claim_notifications('dry_run',100) v")).rows[0].v;
    assert.equal(claimed.length, 1);
    assert.equal((await outbox(db, playerOnly))[0].state, 'cancelled');
    assert.equal((await outbox(db, both))[0].state, 'sending');
  } finally { await db.close(); }
});

test('player-only followers are claimed and sent (subjectRefs revalidation)', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fan = await user(db, [['player', ids.star]]);
    await started(db, ids);
    await live(db, ids, [ev(ids, 'g1', 'GOAL', 50, ids.pStar)], { minute: 50 });
    const claimed = (await db.query("select public.futbeat_claim_notifications('dry_run',100) v")).rows[0].v;
    assert.equal(claimed.length, 1);
    assert.equal((await outbox(db, fan))[0].state, 'sending');
  } finally { await db.close(); }
});

test('19. an event recovered 30 match minutes late is stored for history but sends no player alert', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fan = await user(db, [['player', ids.star]]);
    await started(db, ids);
    await live(db, ids, [], { minute: 80 });
    await live(db, ids, [ev(ids, 'late-goal', 'GOAL', 50, ids.pStar)], { minute: 80 });
    assert.equal((await outbox(db, fan)).length, 0);
    const stored = (await db.query("select count(*)::int n from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL' and payload->>'playerId'=$2", [ids.match, ids.star])).rows[0].n;
    assert.equal(stored, 1, 'the attributed goal is kept for the timeline');
    // A fresh one still alerts.
    await live(db, ids, [ev(ids, 'late-goal', 'GOAL', 50, ids.pStar), ev(ids, 'fresh', 'GOAL', 81, ids.pStar)], { minute: 81 });
    assert.equal((await outbox(db, fan)).length, 1);
  } finally { await db.close(); }
});

test('preferences: notify_goals / notify_cards also gate player alerts', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const noGoals = await user(db, [['player', ids.star]], { goals: false });
    await started(db, ids);
    const goal = ev(ids, 'g1', 'GOAL', 10, ids.pStar);
    await live(db, ids, [goal], { minute: 10 });
    await live(db, ids, [goal, ev(ids, 'y1', 'YELLOW_CARD', 11, ids.pStar)], { minute: 11 });
    assert.deepEqual((await outbox(db, noGoals)).map((r) => r.message.type), ['YELLOW_CARD']);
  } finally { await db.close(); }
});

test('new helpers and the lineup state table stay private', async () => {
  const db = await openDatabase();
  try {
    const rows = (await db.query(`select p.proname,has_function_privilege('anon',p.oid,'execute') anon,
        has_function_privilege('authenticated',p.oid,'execute') auth
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='futbeat_private' and p.proname in
        ('player_event_is_stale','player_event_message','lineup_player_roles','note_lineup_alerts')`)).rows;
    assert.equal(rows.length, 4);
    assert.ok(rows.every((r) => !r.anon && !r.auth));
    assert.equal((await db.query("select has_table_privilege('authenticated','futbeat_private.lineup_player_alerts','select') v")).rows[0].v, false);
  } finally { await db.close(); }
});

test('P1 regression: a raw GOAL substitution "OUT|IN" tells the outgoing follower "Sale" and the incoming one "Entra"', async () => {
  const db = await openDatabase();
  try {
    const ids = await world(db);
    const fanOut = await user(db, [['player', ids.mate]]);
    const fanIn = await user(db, [['player', ids.star]]);
    const raw = { id: 'sub-raw', team: 'home', time: '67', substitutionPlayerId: `${ids.pMate}|${ids.pStar}` };
    // The detail normalizer (the app's source of truth) reads it as OUT|IN.
    const [detailSub] = normalizeMatchDetail({ payload: { substitutions: [raw] } }).incidents;
    assert.deepEqual([detailSub.outPlayerId, detailSub.inPlayerId], [ids.pMate, ids.pStar]);
    // The live path, from the same raw row.
    const [liveSub] = normalizeFixtureEvents({ homeTeam: { id: ids.homeExt }, awayTeam: { id: ids.awayExt }, substitutions: [raw] });
    await started(db, ids);
    await live(db, ids, [liveSub], { minute: 67 });
    const titleOf = async (uid) => (await outbox(db, uid)).map((r) => r.message.title);
    assert.deepEqual(await titleOf(fanOut), ["🔄 67' Sale Compañero"]);
    assert.deepEqual(await titleOf(fanIn), ["🔄 67' Entra Estrella"]);
  } finally { await db.close(); }
});

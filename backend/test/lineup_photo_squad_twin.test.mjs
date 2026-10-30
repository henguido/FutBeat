import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';
import { lineupPlayerIds, normalizeLineupSide } from '../../supabase/functions/_shared/match_detail.ts';

// DATA 219: GOAL lists one person under a numeric lineup playerKey and a
// catalog id ("cm...") in squads/search. A lineup stub minted before the squad
// never gets linked, so the lineup showed no photo while the squad twin had a
// VERIFIED one. D1 shows the twin's photo only when the pairing is
// unambiguous; nothing is merged. Real SQL (PGlite, all migrations) + real
// write paths (harvest_lineup_players, futbeat_store_team_squad).

const cdn = (name) => `https://media.goal-api.com/badges/players/${name}.jpg`;

async function team(db, id, name = id) {
  await db.query(`insert into futbeat_private.entities values('fb_comp_219','competition',$1) on conflict do nothing`,
    [JSON.stringify({ id: 'fb_comp_219', name: 'Cup', country: 'England' })]);
  await db.query(`insert into futbeat_private.entities values($1,'team',$2) on conflict do nothing`,
    [id, JSON.stringify({ id, name, competitionId: 'fb_comp_219' })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$1) on conflict do nothing", [id]);
  return id;
}

async function match(db, id, home, away) {
  await db.query(`insert into futbeat_private.entities values($1,'match',$2) on conflict do nothing`,
    [id, JSON.stringify({ id, homeTeamId: home, awayTeamId: away, competitionId: 'fb_comp_219', status: 'VERIFIED' })]);
  return id;
}

// rows: {key, name, number?, side?, image?}
async function lineup(db, matchId, rows) {
  const lineups = rows.map((r) => ({ team: r.side ?? 'home', type: r.sub ? 'substitutes' : 'starting_lineups',
    playerId: null, playerKey: r.key, lineupPlayer: r.name, lineupNumber: r.number == null ? '' : String(r.number),
    ...(r.image ? { playerImage: r.image } : {}) }));
  await db.query('select futbeat_private.harvest_lineup_players($1,$2,now())', [matchId, JSON.stringify({ lineups })]);
  return lineups;
}

async function squad(db, tid, rows, stamp = new Date().toISOString()) {
  const players = await normalizeGoalApiSquad(rows, tid, async (kind, external, identity) =>
    (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
      ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4) v', [tid, 'goal_api', stamp, JSON.stringify(players)]);
}

const canonical = async (db, ext) => (await db.query(
  "select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext])).rows[0]?.canonical_id;
const read = async (db, ids) => (await db.query("select public.futbeat_read_lineup_player_media('goal_api',$1) v", [ids])).rows[0].v;

async function scene(fn) {
  const db = await openDatabase();
  try {
    const home = await team(db, 'fb_team_219_home', 'Home FC');
    const away = await team(db, 'fb_team_219_away', 'Away FC');
    const m = await match(db, 'fb_match_219', home, away);
    await fn(db, { home, away, m });
  } finally { await db.close(); }
}

test('own verified photo wins and is labelled PLAYER', async () => {
  await scene(async (db, { m }) => {
    await lineup(db, m, [{ key: '1001', name: 'Direct Photo', number: 1, image: cdn('direct') }]);
    const r = await read(db, ['1001']);
    assert.deepEqual(r['1001'], { providerId: '1001', canonicalId: await canonical(db, '1001'), image: cdn('direct'), imageSource: 'PLAYER' });
  });
});

test('unique verified squad twin gives the photo; identities stay separate', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '4032345715', name: 'James Tarkowski', number: 6 }]);
    await squad(db, home, [{ id: 'cmr7tark', name: 'James Tarkowski', number: 6, photo: cdn('tarkowski') }]);
    const stub = await canonical(db, '4032345715');
    const twin = await canonical(db, 'cmr7tark');
    assert.notEqual(stub, twin, 'precondition: split identity (the production case)');
    const before = (await db.query('select count(*)::int n from futbeat_private.provider_entities')).rows[0].n;
    const r = await read(db, ['4032345715']);
    assert.deepEqual(r['4032345715'], { providerId: '4032345715', canonicalId: stub, image: cdn('tarkowski'),
      imageSource: 'SQUAD_TWIN', twinCanonicalId: twin });
    // Read-only: no merge, no redirect, no media copied onto the stub.
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_entities')).rows[0].n, before);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.entity_redirects where kind='player'")).rows[0].n, 0);
    assert.equal((await db.query('select payload->\'media\' m from futbeat_private.entities where id=$1', [stub])).rows[0].m, null);
    assert.equal(await canonical(db, '4032345715'), stub);
  });
});

test('accents and token order fold like the squad twin key', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '614049608', name: 'Merlin Röhl', number: 34 }]);
    await squad(db, home, [{ id: 'cmr7rohl', name: 'Rohl Merlin', number: 34, photo: cdn('rohl') }]);
    assert.equal((await read(db, ['614049608']))['614049608'].image, cdn('rohl'));
  });
});

test('two rich twins with the same name are ambiguous', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '2001', name: 'Carlos Alcaraz' }]);
    await squad(db, home, [
      { id: 'cmr7alc1', name: 'Carlos Alcaraz', number: 24, photo: cdn('alc1') },
      { id: 'cmr7alc2', name: 'Carlos Alcaraz', number: 10, photo: cdn('alc2') },
    ]);
    assert.deepEqual((await read(db, ['2001']))['2001'], { providerId: '2001', canonicalId: await canonical(db, '2001'), image: null });
  });
});

test('a known shirt number disambiguates, a different known number never pairs', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '2002', name: 'Carlos Alcaraz', number: 24 }, { key: '2003', name: 'Jordan Pickford', number: 1 }]);
    await squad(db, home, [
      { id: 'cmr7alc1', name: 'Carlos Alcaraz', number: 24, photo: cdn('alc1') },
      { id: 'cmr7alc2', name: 'Carlos Alcaraz', number: 10, photo: cdn('alc2') },
      { id: 'cmr7pick', name: 'Jordan Pickford', number: 12, photo: cdn('pick') },
    ]);
    const r = await read(db, ['2002', '2003']);
    assert.equal(r['2002'].image, cdn('alc1'));
    assert.equal(r['2003'].image, null);
  });
});

test('a sparse duplicate squad row does not make the rich twin ambiguous', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '2004', name: 'Pablo Arboine', number: 5 }]);
    await squad(db, home, [
      { id: 'cmr7arb1', name: 'Pablo Arboine', number: 5, photo: cdn('arboine'), dateOfBirth: '1998-04-03' },
      { id: 'cmr7arb2', name: 'Arboine Pablo', number: 5 },
    ]);
    assert.equal((await read(db, ['2004']))['2004'].image, cdn('arboine'));
  });
});

test('a twin of another team never pairs', async () => {
  await scene(async (db, { away, m }) => {
    await lineup(db, m, [{ key: '3001', name: 'Harvey Barnes', number: 11 }]);
    await squad(db, away, [{ id: 'cmr7barn', name: 'Harvey Barnes', number: 11, photo: cdn('barnes') }]);
    assert.equal((await read(db, ['3001']))['3001'].image, null);
  });
});

test('homonyms in one lineup resolving to one twin are both rejected', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '3002', name: 'Jordan Henderson', number: 8 }, { key: '3003', name: 'Jordan Henderson', sub: true }]);
    await squad(db, home, [{ id: 'cmr7hend', name: 'Jordan Henderson', number: 8, photo: cdn('henderson') }]);
    const r = await read(db, ['3002', '3003']);
    assert.equal(r['3002'].image, null);
    assert.equal(r['3003'].image, null);
  });
});

test('an unverified twin photo is never shown', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '3004', name: 'Lewis Hall', number: 3 }]);
    // Stored media is never downgraded by triggers, so seed the twin directly.
    await db.query(`insert into futbeat_private.entities values('fb_player_219_hall','player',$1)`, [JSON.stringify({
      id: 'fb_player_219_hall', name: 'Lewis Hall', teamId: home, shirtNumber: 3, dateOfBirth: '2004-09-08',
      media: { url: cdn('hall'), kind: 'PLAYER_PHOTO', source: 'GOAL API', verificationStatus: 'PROVISIONAL' } })]);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','player','cmr7hall','fb_player_219_hall')");
    await db.query("insert into futbeat_private.team_squad_members values($1,'fb_player_219_hall','goal_api',now())", [home]);
    assert.equal((await read(db, ['3004']))['3004'].image, null);
  });
});

test('no twin keeps the old shape: image null, no extra keys', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '171540400', name: 'Jordan Pickford', number: 1 }]);
    await squad(db, home, [{ id: 'cmr7other', name: 'Someone Else', number: 9, photo: cdn('else') }]);
    assert.deepEqual((await read(db, ['171540400', 'unknown']))['171540400'],
      { providerId: '171540400', canonicalId: await canonical(db, '171540400'), image: null });
    assert.deepEqual((await read(db, ['unknown'])).unknown, { providerId: 'unknown', canonicalId: null, image: null });
  });
});

test('a twin that already has its own numeric id is another lineup identity', async () => {
  await scene(async (db, { home, m }) => {
    await squad(db, home, [{ id: 'cmr7will', name: 'Joe Willock', number: 28, photo: cdn('willock') }]);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','player','999001',$1)", [await canonical(db, 'cmr7will')]);
    await db.query(`insert into futbeat_private.entities values('fb_player_219_will_stub','player',$1)`,
      [JSON.stringify({ id: 'fb_player_219_will_stub', name: 'Joe Willock', teamId: home, shirtNumber: 28 })]);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','player','2886133965','fb_player_219_will_stub')");
    assert.equal((await read(db, ['2886133965']))['2886133965'].image, null);
  });
});

test('a player who left the current squad answer does not pair', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '3005', name: 'Malick Thiaw', number: 12 }]);
    await squad(db, home, [{ id: 'cmr7thia', name: 'Malick Thiaw', number: 12, photo: cdn('thiaw') }], '2026-10-01T00:00:00Z');
    await squad(db, home, [{ id: 'cmr7new', name: 'New Signing', number: 4, photo: cdn('new') }], '2026-10-20T00:00:00Z');
    const kept = (await db.query('select count(*)::int n from futbeat_private.team_squad_members where team_id=$1', [home])).rows[0].n;
    const r = await read(db, ['3005']);
    assert.equal(r['3005'].image, null, `stale member must not pair (members kept: ${kept})`);
  });
});

test('one-token names need the same known shirt number', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '310238476', name: 'Joelinton', number: 7 }, { key: '3006', name: 'Richarlison' }]);
    await squad(db, home, [
      { id: 'cmr7joel', name: 'Joelinton', number: 7, photo: cdn('joelinton') },
      { id: 'cmr7rich', name: 'Richarlison', number: 9, photo: cdn('richarlison') },
    ]);
    const r = await read(db, ['310238476', '3006']);
    assert.equal(r['310238476'].image, cdn('joelinton'));
    assert.equal(r['3006'].image, null);
  });
});

test('club and national team: only the squad of the lineup team counts', async () => {
  await scene(async (db, { home, away }) => {
    const national = await team(db, 'fb_team_219_england', 'England');
    const intl = await match(db, 'fb_match_219_intl', national, away);
    // Seen last for the national team: the club twin is a different team context.
    await lineup(db, intl, [{ key: '4001', name: 'Dan Burn', number: 15 }]);
    await squad(db, home, [{ id: 'cmr7burn', name: 'Dan Burn', number: 33, photo: cdn('burn') }]);
    assert.equal((await read(db, ['4001']))['4001'].image, null);
    // Same person listed in the national squad: unambiguous in that team.
    await squad(db, national, [{ id: 'cmr7burn', name: 'Dan Burn', number: 15, photo: cdn('burn') }]);
    assert.equal((await read(db, ['4001']))['4001'].image, cdn('burn'));
  });
});

test('API normalizer renders the twin photo with the unchanged lineup contract', async () => {
  await scene(async (db, { home, m }) => {
    const rows = await lineup(db, m, [{ key: '4032345715', name: 'James Tarkowski', number: 6 }, { key: '171540400', name: 'Jordan Pickford', number: 1 }]);
    await squad(db, home, [{ id: 'cmr7tark', name: 'James Tarkowski', number: 6, photo: cdn('tarkowski') }]);
    const detail = { matchId: m, payload: { lineups: rows } };
    const media = await read(db, lineupPlayerIds(detail));
    const starters = normalizeLineupSide(rows, 'home', media).starters;
    const tark = starters.find((p) => p.name === 'James Tarkowski');
    const pick = starters.find((p) => p.name === 'Jordan Pickford');
    assert.equal(tark.image, cdn('tarkowski'));
    assert.equal(tark.canonicalId, await canonical(db, '4032345715'));
    assert.equal(pick.image, null);
    assert.deepEqual(Object.keys(tark).sort(), Object.keys(pick).sort());
    assert.ok(!('imageSource' in tark) && !('twinCanonicalId' in tark), 'app contract unchanged');
  });
});

test('D2: no search discovery for a stub whose photo a twin provides; others unchanged', async () => {
  await scene(async (db, { home, m }) => {
    await lineup(db, m, [{ key: '5001', name: 'Sven Botman', number: 4 }, { key: '5002', name: 'Nick Pope', number: 22 }]);
    await squad(db, home, [{ id: 'cmr7botm', name: 'Sven Botman', number: 4, photo: cdn('botman') }]);
    const stubs = [await canonical(db, '5001'), await canonical(db, '5002')];
    await db.query('select public.futbeat_request_lineup_hydration($1,$2)', [stubs, []]);
    const demands = (await db.query('select query_key from futbeat_private.player_search_demands order by 1')).rows.map((r) => r.query_key);
    assert.ok(!demands.some((q) => q.includes('botman')), `no discovery for the twin-resolved stub: ${demands}`);
    assert.ok(demands.some((q) => q.includes('pope')), `discovery unchanged for the unresolved stub: ${demands}`);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where provider='goal_api'")).rows[0].n, 0);
  });
});

test('full lineup: one statement, bounded time, no per-player scan of all players', async () => {
  await scene(async (db, { home, away, m }) => {
    // Background: 2,000 unrelated players (a production-like players table).
    await db.query(`insert into futbeat_private.entities
      select 'fb_player_bg_'||g,'player',jsonb_build_object('id','fb_player_bg_'||g,'name','Background Player '||g,'teamId','fb_team_bg')
      from generate_series(1,2000) g`);
    const rows = [];
    for (let i = 0; i < 40; i++) rows.push({ key: String(7000 + i), name: `Lineup Player${String.fromCharCode(97 + (i % 26))} ${i}`, number: i + 1, side: i < 20 ? 'home' : 'away', sub: i % 20 >= 11 });
    await lineup(db, m, rows);
    await squad(db, home, rows.slice(0, 20).map((r, i) => ({ id: `cmr7h${i}`, name: r.name, number: r.number, photo: i < 11 ? cdn(`h${i}`) : null })));
    await squad(db, away, rows.slice(20).map((r, i) => ({ id: `cmr7a${i}`, name: r.name, number: r.number, photo: i < 11 ? cdn(`a${i}`) : null })));
    const ids = rows.map((r) => r.key);
    await read(db, ids);
    const t0 = performance.now();
    const r = await read(db, ids);
    const ms = performance.now() - t0;
    assert.equal(Object.values(r).filter((x) => x.imageSource === 'SQUAD_TWIN').length, 22);
    assert.ok(ms < 1500, `lineup media read took ${ms.toFixed(1)} ms`);
    const plan = (await db.query("explain select public.futbeat_read_lineup_player_media('goal_api',$1)", [ids])).rows.map((x) => x['QUERY PLAN']).join('\n');
    assert.ok(plan.length > 0);
    console.log(`DATA219 full lineup (40 ids, 2x20 squad, 2000 background players): ${ms.toFixed(1)} ms, 22/40 twin photos`);
  });
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Broad player-search regression matrix over one shared catalog. Every case
// asserts the exact player list so ranking and precision regressions surface.

const catalog = [
  { id: 'fb_player_sm_kante', name: "N'Golo Kanté" },
  { id: 'fb_player_sm_jm', name: 'José Martínez' },
  { id: 'fb_player_sm_jml', name: 'Jose Martinez Lopez' },
  { id: 'fb_player_sm_km', name: 'Kylian Mbappé', shortName: 'K. Mbappé' },
  { id: 'fb_player_sm_cr', name: 'Cristiano Ronaldo', aliases: ['CR7'] },
  { id: 'fb_player_sm_ra', name: 'Ronald Araújo' },
  { id: 'fb_player_sm_jpm', name: 'Jean-Philippe Mateta' },
  { id: 'fb_player_sm_kn', name: 'Keylor Navas' },
  { id: 'fb_player_sm_cb', name: 'Celso Borges' },
  { id: 'fb_player_sm_co', name: 'Celso Ortiz' },
  { id: 'fb_player_sm_br', name: 'Bryan Ruiz' },
  { id: 'fb_player_sm_bo', name: 'Bryan Oviedo' },
  { id: 'fb_player_sm_ml', name: 'Maximiliano Lopez' },
  { id: 'fb_player_sm_jc', name: 'Joel Campbell' },
  { id: 'fb_player_sm_as', name: 'Álvaro Saborío' },
  { id: 'fb_player_sm_eh', name: 'Erling Haaland' },
];

const cases = [
  // exact / prefix / word prefix / alias / shortName
  ['keylor navas', ['Keylor Navas']],
  ['navas', ['Keylor Navas']],
  ['mbap', ['Kylian Mbappé']],
  ['k. mbappe', ['Kylian Mbappé']],
  ['cr7', ['Cristiano Ronaldo']],
  ['jean philippe', ['Jean-Philippe Mateta']],
  ['mateta', ['Jean-Philippe Mateta']],
  // accents both ways
  ['alvaro saborio', ['Álvaro Saborío']],
  ['ÁLVARO', ['Álvaro Saborío']],
  ['josé martínez', ['José Martínez', 'Jose Martinez Lopez']],
  ['jose martinez', ['José Martínez', 'Jose Martinez Lopez']],
  // apostrophes
  ['kante', ["N'Golo Kanté"]],
  ["n'golo", ["N'Golo Kanté"]],
  ['ngolo', ["N'Golo Kanté"]],
  ['ngolo kante', ["N'Golo Kanté"]],
  // reasonable typos (single and multi-word)
  ['campbel', ['Joel Campbell']],
  ['haland', ['Erling Haaland']],
  ['keilor navas', ['Keylor Navas']],
  ['celso borjes', ['Celso Borges']],
  ['bryan ruis', ['Bryan Ruiz']],
  ['erling haland', ['Erling Haaland']],
  ['ronaldo araujo', ['Ronald Araújo']],
  // irrelevant fuzzy never appears
  ['celso borges', ['Celso Borges']],
  ['bryan ruiz', ['Bryan Ruiz']],
  ['maximiliano ruiz', []],
  ['cristiano zanetti', []],
  ['keylor ortiz', []],
  ['messi', []],
  ['xyz', []],
  ['zzzz navas', []],
];

test('player search matrix: exact, prefix, alias, accents, apostrophes, typos and precision', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities(id,kind,payload)
      select item->>'id','player',item from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(catalog)]);
    const failures = [];
    for (const [query, expected] of cases) {
      const v = (await db.query('select public.futbeat_search_catalog($1,null,50) v', [query])).rows[0].v;
      const names = v.players.map((p) => p.name);
      if (JSON.stringify(names) !== JSON.stringify(expected)) failures.push(`${query}: ${JSON.stringify(names)}`);
    }
    assert.deepEqual(failures, []);
  } finally { await db.close(); }
});

test('team redirects surface the canonical team once and players keep resolving', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_sm_canon','team','{"id":"fb_team_sm_canon","name":"Deportivo Saprissa"}'),
      ('fb_team_sm_alias','team','{"id":"fb_team_sm_alias","name":"Saprissa"}'),
      ('fb_player_sm_p','player','{"id":"fb_player_sm_p","name":"Mariano Torres","teamId":"fb_team_sm_alias"}')`);
    await db.query(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
      values('fb_team_sm_alias','fb_team_sm_canon','team','test')`);
    const v = (await db.query("select public.futbeat_search_catalog('saprissa',null,50) v")).rows[0].v;
    assert.deepEqual(v.teams.map((t) => t.id), ['fb_team_sm_canon']);
    const p = (await db.query("select public.futbeat_search_catalog('mariano torres',null,50) v")).rows[0].v;
    assert.deepEqual(p.players.map((x) => x.name), ['Mariano Torres']);
  } finally { await db.close(); }
});

test('renamed players are reindexed: the old name stops matching, the new one matches', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_player_sm_r','player','{"id":"fb_player_sm_r","name":"Jugador Provisional"}')`);
    await db.query(`update futbeat_private.entities set payload=payload||'{"name":"Jugadór Definitivo"}' where id='fb_player_sm_r'`);
    const names = async (q) => (await db.query('select public.futbeat_search_catalog($1,null,50) v', [q])).rows[0].v.players.map((p) => p.name);
    assert.deepEqual(await names('provisional'), []);
    assert.deepEqual(await names('jugador definitivo'), ['Jugadór Definitivo']);
  } finally { await db.close(); }
});

test('search helpers stay private', async () => {
  const db = await openDatabase();
  try {
    for (const role of ['anon', 'authenticated', 'service_role']) {
      for (const fn of ['futbeat_private.search_compact_fold(text)', 'futbeat_private.search_word_guard(text,text)']) {
        assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok, false, `${role} ${fn}`);
      }
    }
  } finally { await db.close(); }
});

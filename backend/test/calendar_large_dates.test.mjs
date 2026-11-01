import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Turn 244: dates above 1,500 fixtures and the +90 recovery. The read must not change its
// answer, the plan must spend what the GOAL budget allows, and a repeated store must not
// duplicate anything.

const previous = await readFile(new URL('../../supabase/migrations/20261007010000_ingest_context_single_pass.sql', import.meta.url), 'utf8');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const body = previous.match(/create or replace function public\.futbeat_read_ingest_context[\s\S]*?\$function\$;|create or replace function public\.futbeat_read_ingest_context[\s\S]*?\$\$;/i)[0];
const installPrevious = (db) => db.exec(body.replace('public.futbeat_read_ingest_context', 'public.read_ingest_context_previous'));

const snapshot = (extra) => ({
  schemaVersion: 1, demo: false, players: [], standings: [],
  competitions: [{ id: 'fb_competition_c1', name: 'One' }, { id: 'fb_competition_c_alias', name: 'Alias' }, { id: 'fb_competition_c2', name: 'Two' }, { id: 'fb_competition_c3_alias', name: 'Lonely' }, { id: 'fb_competition_c1', name: 'Repeated' }],
  teams: [{ id: 'fb_team_t1', name: 'One' }, { id: 'fb_team_t_alias', name: 'Alias' }, { id: 'fb_team_t2', name: 'Two' }, { id: 'fb_team_t3_alias', name: 'Stored' }, { id: 'fb_team_t4_alias', name: 'Unstored' }, { id: 'fb_team_t1', name: 'Repeated' }],
  matches: [
    { id: 'm1', homeTeamId: 'fb_team_t1', awayTeamId: 'fb_team_t2', competitionId: 'fb_competition_c1', startTime: '2026-11-07T12:00:00.000Z' },
    { id: 'm2', homeTeamId: 'fb_team_t_alias', awayTeamId: 'fb_team_t2', competitionId: 'fb_competition_c_alias', startTime: '2026-11-07T23:59:00.000Z' },
    { id: 'm3', homeTeamId: 'fb_team_t3_alias', awayTeamId: 'fb_team_t4_alias', competitionId: 'fb_competition_c2', startTime: '2026-11-07T15:00:00.000Z' },
    { id: 'm_out', homeTeamId: 'fb_team_t1', awayTeamId: 'fb_team_t2', competitionId: 'fb_competition_c1', startTime: '2026-11-09T12:00:00.000Z' },
    { id: 'm_stranger', homeTeamId: 'fb_team_t1', awayTeamId: 'fb_team_tx', competitionId: 'fb_competition_c1', startTime: '2026-11-07T12:00:00.000Z' },
  ],
  ...extra,
});

async function seedContext(db) {
  const entity = (id, kind, name) => db.query(`insert into futbeat_private.entities(id,kind,payload)
    values($1,$2,$3::jsonb) on conflict(id) do nothing`, [id, kind, JSON.stringify({ id, name })]);
  await entity('fb_team_t1', 'team', 'Stale entity, snapshot wins');
  await entity('fb_team_t3', 'team', 'Stored payload');
  await entity('fb_team_t4', 'team', 'Stored too');
  await entity('fb_competition_c1', 'competition', 'Stale');
  await entity('fb_competition_c3', 'competition', 'Stored competition');
  for (const id of ['t_alias', 't3_alias', 't4_alias']) await entity(`fb_team_${id}`, 'team', 'Alias row');
  for (const id of ['c_alias', 'c3_alias']) await entity(`fb_competition_${id}`, 'competition', 'Alias row');
  await db.query(`insert into futbeat_private.entity_redirects(kind,alias_id,canonical_id,reason) values
    ('team','fb_team_t_alias','fb_team_t1','test'),('team','fb_team_t3_alias','fb_team_t3','test'),('team','fb_team_t4_alias','fb_team_t4','test'),
    ('competition','fb_competition_c_alias','fb_competition_c1','test'),('competition','fb_competition_c3_alias','fb_competition_c3','test')`);
}

const importSnapshot = (db, value) => db.query(`insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot)
  values(gen_random_uuid()::text,now(),'{}'::jsonb,$1::jsonb)`, [JSON.stringify(value)]);

const contexts = async (db, args) => {
  const sql = (name) => db.query(`select public.${name}($1::text[],$2::text[],$3::timestamptz,$4::timestamptz) value`, args).then((r) => r.rows[0].value);
  return [await sql('read_ingest_context_previous'), await sql('futbeat_read_ingest_context')];
};

const WINDOW = ['2026-11-07T00:00:00Z', '2026-11-07T23:59:59Z'];

test('the context answers exactly as before, aliases included', () => withDb(async (db) => {
  await installPrevious(db);
  await seedContext(db);
  await importSnapshot(db, snapshot());
  for (const args of [
    [['fb_competition_c1', 'fb_competition_c2', 'fb_competition_c3'], ['fb_team_t1', 'fb_team_t2', 'fb_team_t3', 'fb_team_t4'], ...WINDOW],
    [['fb_competition_c1'], ['fb_team_t1'], ...WINDOW],
    [['fb_competition_c3'], ['fb_team_t3'], ...WINDOW],
    [[], [], ...WINDOW],
    [['fb_competition_c1'], ['fb_team_t1', 'fb_team_t2'], null, null],
    [['fb_competition_c1', 'fb_competition_c1'], ['fb_team_t1', 'fb_team_t1', 'fb_team_t2'], ...WINDOW],
    [null, null, ...WINDOW],
  ]) {
    const [before, after] = await contexts(db, args);
    assert.deepEqual(after, before, JSON.stringify(args));
  }
  const [, full] = await contexts(db, [['fb_competition_c1', 'fb_competition_c2', 'fb_competition_c3'], ['fb_team_t1', 'fb_team_t2', 'fb_team_t3', 'fb_team_t4'], ...WINDOW]);
  assert.equal(full.teams.find((t) => t.id === 'fb_team_t1').name, 'One', 'canonical row wins, first position');
  assert.equal(full.teams.find((t) => t.id === 'fb_team_t3').name, 'Stored payload', 'an alias alone takes the stored payload');
  assert.equal(full.teams.find((t) => t.id === 'fb_team_t4').name, 'Stored too');
  assert.deepEqual(full.matches.map((m) => m.id), ['m1', 'm2', 'm3']);
}));

test('the context stays equal with an empty or malformed latest snapshot', () => withDb(async (db) => {
  await installPrevious(db);
  await db.query('delete from futbeat_private.imports');
  assert.deepEqual(...await contexts(db, [['fb_competition_c1'], ['fb_team_t1'], ...WINDOW]));
  await importSnapshot(db, { schemaVersion: 1, demo: false, teams: 'x', competitions: null });
  assert.deepEqual(...await contexts(db, [['fb_competition_c1'], ['fb_team_t1'], ...WINDOW]));
}));

const day = (offset) => `(now() at time zone 'UTC')::date+${offset}`;
const cover = (db, offset, age) => db.query(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count)
  values('goal_api',${day(offset)},now()-$1::interval,1) on conflict(provider,provider_date) do update set fetched_at=excluded.fetched_at`, [age]);
const dateAt = (db, offset) => db.query(`select to_char(${day(offset)},'YYYY-MM-DD') d`).then((r) => r.rows[0].d);
const missing = (db, from, to, limit = 90) => db.query(`select public.futbeat_calendar_missing_provider_dates('goal_api',${day(from)},${day(to)},$1) value`, [limit]).then((r) => r.rows[0].value);
const ledger = (db, status, metadata, age = '1 minute') => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,reserved_at,metadata)
  values('goal_api','calendar-ingest','github-actions',$1,now()-$3::interval,$2::jsonb)`, [status, JSON.stringify(metadata), age]);

test('refresh by distance: near daily, far every three weeks', () => withDb(async (db) => {
  const cases = [[3, '25 hours', true], [3, '23 hours', false], [4, '2 days', false], [4, '73 hours', true], [14, '73 hours', true],
    [15, '6 days', false], [15, '8 days', true], [45, '8 days', true], [46, '8 days', false], [90, '20 days', false], [90, '22 days', true]];
  for (const [offset, age, stale] of cases) {
    await cover(db, offset, age);
    const date = await dateAt(db, offset);
    assert.equal((await missing(db, offset, offset)).includes(date), stale, `+${offset} ${age}`);
  }
}));

test('nearest first: a date never covered comes before a far one', () => withDb(async (db) => {
  const dates = await missing(db, 2, 90, 3);
  assert.deepEqual(dates, [await dateAt(db, 2), await dateAt(db, 3), await dateAt(db, 4)]);
}));

test('two failures in 24 h rest the date; one does not, and it comes back alone', () => withDb(async (db) => {
  const date = await dateAt(db, 5);
  await ledger(db, 'FAILED', { failedDate: date });
  assert.ok((await missing(db, 5, 5)).includes(date), 'one failure keeps it');
  await ledger(db, 'FAILED', { failedDate: date });
  assert.deepEqual(await missing(db, 5, 5), [], 'rests');
  await db.query(`update futbeat_private.provider_call_ledger set reserved_at=now()-interval '25 hours' where call_kind='calendar-ingest'`);
  assert.deepEqual(await missing(db, 5, 5), [date], 'back after 24 h');
}));

test('a failure without a date rests nothing', () => withDb(async (db) => {
  await ledger(db, 'FAILED', { stage: 'read-current' });
  await ledger(db, 'FAILED', { stage: 'read-current' });
  await ledger(db, 'FAILED', { failedDate: null });
  assert.equal((await missing(db, 5, 5)).length, 1);
}));

test('a rested date also leaves the requested plan', () => withDb(async (db) => {
  const date = await dateAt(db, 5);
  await db.query(`insert into futbeat_private.calendar_date_requests(provider,provider_date,first_requested_at,last_requested_at,request_count)
    values('goal_api',$1::date,now(),now(),1)`, [date]);
  await ledger(db, 'FAILED', { failedDate: date });
  await ledger(db, 'FAILED', { failedDate: date });
  assert.deepEqual((await db.query('select public.futbeat_requested_calendar_dates(12) value')).rows[0].value, []);
  const { rows } = await db.query('select count(*)::int n from futbeat_private.calendar_date_requests');
  assert.equal(rows[0].n, 1, 'the request stays for later');
}));

test('the plan offers what the 64 daily ingests still allow, then nothing', () => withDb(async (db) => {
  for (let i = 0; i < 61; i += 1) await ledger(db, 'SUCCEEDED', {});
  await ledger(db, 'SUCCEEDED', {}, '2 days');
  assert.equal((await missing(db, 2, 90, 45)).length, 3, 'only today counts');
  await ledger(db, 'SUCCEEDED', {});
  await ledger(db, 'SUCCEEDED', {});
  await ledger(db, 'FAILED', { failedDate: '2026-01-01' });
  assert.deepEqual(await missing(db, 2, 90, 45), []);
  await db.query(`insert into futbeat_private.calendar_date_requests(provider,provider_date,first_requested_at,last_requested_at,request_count)
    values('goal_api',${day(5)},now(),now(),1)`);
  assert.deepEqual((await db.query('select public.futbeat_requested_calendar_dates(12) value')).rows[0].value, []);
}));

test('reservation and plan agree on the 64th ingest', () => withDb(async (db) => {
  for (let i = 0; i < 64; i += 1) await ledger(db, 'SUCCEEDED', {});
  const { rows } = await db.query(`select public.futbeat_reserve_provider_call('goal_api','calendar-ingest','github-actions',64,0,true) value`);
  assert.equal(rows[0].value.allowed, false);
  assert.equal(rows[0].value.reason, 'daily_limit');
  assert.deepEqual(await missing(db, 2, 90, 45), []);
}));

const match = (i, date, recv) => ({ id: `fb_match_large${i}`, homeTeamId: 'fb_team_lh', awayTeamId: 'fb_team_la', competitionId: 'fb_competition_l', events: [], minute: null, score: null, season: '2026', statistics: [], status: 'SCHEDULED', venue: '',
  startTime: `${date}T${String(10 + (i % 10)).padStart(2, '0')}:00:00.000Z`,
  provenance: { externalId: `l${i}`, receivedAt: recv, source: 'GOAL API', verificationStatus: 'PROVISIONAL' } });
const dateSnapshot = (ids, date, recv) => ({ demo: false, schemaVersion: 1,
  competitions: [{ id: 'fb_competition_l', name: 'L', country: 'XX', kind: 'league' }],
  teams: [{ id: 'fb_team_lh', name: 'H' }, { id: 'fb_team_la', name: 'A' }],
  matches: ids.map((i) => match(i, date, recv)) });
const store = async (db, ids, date, recv, count = ids.length) => {
  for (let lo = 0; lo < ids.length; lo += 300) {
    await db.query(`select public.futbeat_store_calendar_entities('goal_api',$1::jsonb)`, [JSON.stringify(dateSnapshot(ids.slice(lo, lo + 300), date, recv))]);
  }
  await db.query(`select public.futbeat_store_calendar_range('goal_api',$1::timestamptz,$2::jsonb,$3::jsonb)`,
    [recv, JSON.stringify([{ date, count }]), JSON.stringify(dateSnapshot(ids, date, recv))]);
};
const indexed = (db, date) => db.query(`select count(*)::int n,count(distinct match_id)::int d from futbeat_private.calendar_matches
  where start_time>=$1::date::timestamp at time zone 'UTC' and start_time<($1::date+1)::timestamp at time zone 'UTC'`, [date]).then((r) => r.rows[0]);

test('a retry and a later refresh leave one row per fixture', () => withDb(async (db) => {
  const date = '2027-03-06';
  const ids = Array.from({ length: 700 }, (_, i) => i);
  await store(db, ids, date, '2026-11-01T00:00:00.000Z');
  await store(db, ids, date, '2026-11-01T00:00:00.000Z');
  await store(db, ids, date, '2026-11-08T00:00:00.000Z');
  assert.deepEqual(await indexed(db, date), { n: 700, d: 700 });
  const { rows } = await db.query(`select count(*)::int n,max(fixture_count) c from futbeat_private.calendar_coverage where provider_date=$1`, [date]);
  assert.deepEqual(rows[0], { n: 1, c: 700 });
}));

test('chunks stored before a failed date store are found again, and nothing is covered', () => withDb(async (db) => {
  const date = '2027-03-13';
  const ids = Array.from({ length: 450 }, (_, i) => i + 1000);
  const recv = '2026-11-01T00:00:00.000Z';
  await db.query(`select public.futbeat_store_calendar_entities('goal_api',$1::jsonb)`, [JSON.stringify(dateSnapshot(ids.slice(0, 300), date, recv))]);
  const { rows } = await db.query(`select count(*)::int n from futbeat_private.calendar_coverage where provider_date=$1`, [date]);
  assert.equal(rows[0].n, 0, 'the date stays in the plan');
  await store(db, ids, date, recv);
  assert.deepEqual(await indexed(db, date), { n: 450, d: 450 });
}));

test('a fixture gone from the provider leaves the date; its neighbours stay', () => withDb(async (db) => {
  const date = '2027-03-20';
  await store(db, [1, 2, 3].map((i) => i + 2000), date, '2026-11-01T00:00:00.000Z');
  await store(db, [1, 3].map((i) => i + 2000), date, '2026-11-08T00:00:00.000Z');
  assert.deepEqual(await indexed(db, date), { n: 2, d: 2 });
}));

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { CollectorInputError, parseCollectorInput, runNewsCollector } from '../../supabase/functions/_shared/news_collector.ts';

// News collector v2 (#104) end to end against PGlite. fetch is a fake that
// serves fixtures; every call it receives is recorded. No network.

const fixture = (name) => readFile(new URL(`./fixtures/news/${name}`, import.meta.url), 'utf8');
const TEAM = 'fb_team_col_uno';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('${TEAM}','team','{"id":"${TEAM}","name":"Club Uno","country":"Costa Rica"}')`);
    await db.query(`insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,priority_score,depth)
      values('team','${TEAM}',2,500,'DEEP')`);
    await fn(db);
  } finally { await db.close(); }
}

function rpcFor(db) {
  return async (name, body = {}) => {
    const keys = Object.keys(body);
    const sql = `select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`;
    const values = keys.map((k) => (body[k] !== null && typeof body[k] === 'object' ? JSON.stringify(body[k]) : body[k]));
    return (await db.query(sql, values)).rows[0]?.v ?? null;
  };
}

function fakeFetch(routes) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, headers: init.headers });
    const route = routes.find((r) => url.startsWith(r.prefix));
    if (!route) throw new Error(`unexpected ${url}`);
    return route.respond(init);
  };
  return { fetch, calls };
}

// Fixture times are fixed (2026-10-18); the store accepts the last 35 days.
// Shift them to "now" so the test does not age.
const shiftDates = (text) => text
  .replaceAll('2026-10-18 14:05:00 +0000', new Date(Date.now() - 2 * 3600e3).toISOString())
  .replaceAll('2026-10-18 10:00:00 +0000', new Date(Date.now() - 6 * 3600e3).toISOString())
  .replaceAll('Sun, 18 Oct 2026 16:00:00 GMT', new Date(Date.now() - 3600e3).toUTCString())
  .replaceAll('Sat, 17 Oct 2026 20:30:00 -0600', new Date(Date.now() - 20 * 3600e3).toUTCString());

test('input: mode required, dryRun defaults to true, unknown fields refused', () => {
  assert.deepEqual(parseCollectorInput({ mode: 'rss' }), { mode: 'rss', dryRun: true });
  assert.deepEqual(parseCollectorInput({ mode: 'currents', dryRun: false }), { mode: 'currents', dryRun: false });
  assert.throws(() => parseCollectorInput({ mode: 'x' }), CollectorInputError);
  assert.throws(() => parseCollectorInput({ mode: 'rss', url: 'https://evil' }), CollectorInputError);
});

test('disabled providers: nothing planned, nothing fetched, nothing reserved', () => withDb(async (db) => {
  const { fetch, calls } = fakeFetch([]);
  for (const mode of ['currents', 'rss']) {
    const result = await runNewsCollector({ mode, dryRun: false }, { rpc: rpcFor(db), fetch, currentsKey: 'k'.repeat(20) });
    assert.equal(result.status, 'skipped');
  }
  assert.equal(calls.length, 0);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.news_collector_calls')).rows[0].n, 0);
}));

test('currents: dry run plans the top central interest without calling it', () => withDb(async (db) => {
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='currents'");
  const { fetch, calls } = fakeFetch([]);
  const result = await runNewsCollector({ mode: 'currents', dryRun: true }, { rpc: rpcFor(db), fetch, currentsKey: 'k'.repeat(20) });
  assert.equal(result.status, 'dry_run');
  assert.equal(result.subject.subjectId, TEAM);
  assert.equal(calls.length, 0);
}));

test('currents: one search, key only in a header, stored and budgeted', () => withDb(async (db) => {
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='currents'");
  const body = shiftDates(await fixture('currents_search.json'));
  const { fetch, calls } = fakeFetch([{ prefix: 'https://api.currentsapi.services/', respond: () => new Response(body, { status: 200 }) }]);
  const key = 'secret-key-value-123';
  const result = await runNewsCollector({ mode: 'currents', dryRun: false }, { rpc: rpcFor(db), fetch, currentsKey: key });
  assert.equal(result.status, 'ok');
  assert.equal(result.inserted, 2);
  assert.equal(calls.length, 1);
  assert.ok(!calls[0].url.includes(key));
  assert.equal(calls[0].headers.Authorization, key);
  assert.match(calls[0].url, /keywords=%22Club\+Uno%22|keywords=%22Club%20Uno%22/);
  const ledger = (await db.query('select status,inserted from futbeat_private.news_collector_calls')).rows;
  assert.deepEqual(ledger, [{ status: 'SUCCEEDED', inserted: 2 }]);
  // The subject is now covered: the next run has nothing due.
  const again = await runNewsCollector({ mode: 'currents', dryRun: false }, { rpc: rpcFor(db), fetch, currentsKey: key });
  assert.equal(again.status, 'skipped');
  assert.equal(calls.length, 1);
}));

test('currents: missing key never reserves; HTTP failure is recorded', () => withDb(async (db) => {
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='currents'");
  const { fetch } = fakeFetch([{ prefix: 'https://api.currentsapi.services/', respond: () => new Response('{}', { status: 429 }) }]);
  assert.equal((await runNewsCollector({ mode: 'currents', dryRun: false }, { rpc: rpcFor(db), fetch, currentsKey: '' })).reason, 'provider_not_configured');
  const failed = await runNewsCollector({ mode: 'currents', dryRun: false }, { rpc: rpcFor(db), fetch, currentsKey: 'k'.repeat(20) });
  assert.deepEqual(failed, { status: 'failed', error: 'HTTP_429' });
  assert.deepEqual((await db.query('select status,http_status,error_code from futbeat_private.news_collector_calls')).rows,
    [{ status: 'FAILED', http_status: 429, error_code: 'HTTP_429' }]);
}));

test('rss: conditional GET; a 304 writes no article; foreign-domain items are dropped', () => withDb(async (db) => {
  await db.query("update futbeat_private.news_provider_config set enabled=true,min_interval_seconds=0 where provider='rss'");
  await db.query("insert into futbeat_private.news_sources(domain,display_name,role) values('club-uno.example','Club Uno','FIRST_PARTY_OFFICIAL')");
  await db.query("insert into futbeat_private.news_feeds(id,url,source_domain,enabled) values('club-uno','https://club-uno.example/rss','club-uno.example',true)");
  await db.query("update futbeat_private.news_feeds set enabled=false where id<>'club-uno'");
  const xml = shiftDates(await fixture('publisher_rss.xml'))
    .replace('</channel>', '<item><title>Item ajeno</title><link>https://otro.example/x</link><guid>x</guid><pubDate>' + new Date().toUTCString() + '</pubDate></item></channel>');
  let served = 0;
  const { fetch, calls } = fakeFetch([{ prefix: 'https://club-uno.example/rss', respond: (init) => {
    served++;
    if (init.headers['If-None-Match'] === '"v1"') return new Response(null, { status: 304 });
    return new Response(xml, { status: 200, headers: { 'content-type': 'application/rss+xml', etag: '"v1"' } });
  } }]);
  const first = await runNewsCollector({ mode: 'rss', dryRun: false }, { rpc: rpcFor(db), fetch });
  assert.equal(first.status, 'ok');
  assert.equal(first.inserted, 2, 'the foreign-domain item is not this publisher\'s');
  // Make it due again and fetch: 304.
  await db.query("update futbeat_private.news_feeds set next_fetch_at=now()-interval '1 minute' where id='club-uno'");
  const second = await runNewsCollector({ mode: 'rss', dryRun: false }, { rpc: rpcFor(db), fetch });
  assert.equal(second.status, 'not_modified');
  assert.equal(calls[1].headers['If-None-Match'], '"v1"');
  assert.equal(served, 2);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.news_articles')).rows[0].n, 2);
  const official = (await db.query("select source_role,category,transfer_status from futbeat_private.news_articles where external_id='club-uno-1001'")).rows[0];
  assert.deepEqual(official, { source_role: 'FIRST_PARTY_OFFICIAL', category: 'TRANSFER', transfer_status: 'CONFIRMED' });
}));

test('rss: a non-feed answer fails and backs the feed off', () => withDb(async (db) => {
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='rss'");
  await db.query("update futbeat_private.news_feeds set enabled=true where id='teletica-futbol'");
  const { fetch } = fakeFetch([{ prefix: 'https://www.teletica.com/', respond: () => new Response('<html></html>', { status: 200, headers: { 'content-type': 'text/html' } }) }]);
  const result = await runNewsCollector({ mode: 'rss', dryRun: false }, { rpc: rpcFor(db), fetch });
  assert.deepEqual(result, { status: 'failed', feed: 'teletica-futbol', error: 'NOT_A_FEED' });
  const feed = (await db.query("select consecutive_failures,next_fetch_at>now() later from futbeat_private.news_feeds where id='teletica-futbol'")).rows[0];
  assert.deepEqual(feed, { consecutive_failures: 1, later: true });
}));

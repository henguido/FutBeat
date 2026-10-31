import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { handleQaStoredRead } from '../../supabase/functions/_shared/qa_stored_reads.ts';

const request = (path, method = 'GET') => new Request(`https://local.test/functions/v1/futbeat-api/v1/qa-stored/${path}`, { method });
test('QA stored API is disabled by default, rejects writes and unknown routes before DB', async () => {
  const noDb = () => { throw Error('Unexpected DB call'); };
  assert.equal((await handleQaStoredRead(request('calendar?date=2026-10-29'), noDb)).status, 404);
  for (const [path, method, status] of [['calendar', 'POST', 405], ['player-profile?id=x', 'GET', 403], ['calendar?date=2026-02-30', 'GET', 400], ['match-detail?id=Everton', 'GET', 400]]) {
    assert.equal((await handleQaStoredRead(request(path, method), noDb, true)).status, status);
  }
});
test('stored API performs only bounded stored RPCs, including incomplete detail with photos missing', async () => {
  const calls = [];
  const allowed = new Set(['futbeat_read_qa_stored_calendar', 'futbeat_read_match_context', 'futbeat_read_match_detail', 'futbeat_read_lineup_player_media', 'futbeat_read_match_videos']);
  const rpc = async (name) => {
    assert(allowed.has(name), `Demand or write RPC forbidden: ${name}`); calls.push(name);
    if (name === 'futbeat_read_match_detail') return { data: { matchId: 'fb_match_test', payload: { lineups: { home: { startingLineups: [{ playerId: '123', playerName: 'Stored player' }] } } } }, error: null };
    return { data: name === 'futbeat_read_lineup_player_media' ? { '123': { canonicalId: 'fb_player_stored' } } : { schemaVersion: 1, demo: false }, error: null };
  };
  for (const path of ['calendar?date=2026-10-29', 'match-context?id=fb_match_test', 'match-detail?id=fb_match_test&request=1']) {
    const result = await handleQaStoredRead(request(path), rpc, true);
    assert.equal(result.status, 200); assert.equal(result.headers.get('x-futbeat-qa-stored'), 'v1');
    assert.equal(result.headers.get('cache-control'), 'no-store');
  }
  assert.equal(calls.length, 5);
  assert(calls.includes('futbeat_read_lineup_player_media'));
  assert(!calls.some((name) => /request_|wake_|enqueue/.test(name)));
});
test('stored misses and RPC failures never queue a fallback', async () => {
  for (const [error, status] of [[null, 404], [{ message: 'offline' }, 503]]) {
    let calls = 0;
    const result = await handleQaStoredRead(request('calendar?date=2026-10-29'), async () => { calls++; return { data: null, error }; }, true);
    assert.equal(result.status, status); assert.equal(calls, 1);
  }
});
test('candidate calendar function works in a read-only transaction; stale/missing days create no demands', async () => {
  const db = new PGlite();
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema futbeat_private;
      create table futbeat_private.compact_calendar_cache(calendar_date date, timezone text, payload jsonb, expires_at timestamptz);
      insert into futbeat_private.compact_calendar_cache values('2026-10-29','America/Costa_Rica','{"schemaVersion":1,"demo":false,"matches":[]}',now()-interval '1 day');`);
    await db.exec(await readFile(new URL('../../scripts/qa/qa227-stored-calendar.sql', import.meta.url), 'utf8'));
    await db.exec('begin read only');
    for (let i = 0; i < 20; i++) {
      const { rows } = await db.query("select public.futbeat_read_qa_stored_calendar('2026-10-29') v");
      assert.equal(rows[0].v.freshness.stale, true); assert.equal(rows[0].v.freshness.revalidating, false);
    }
    assert.equal((await db.query("select public.futbeat_read_qa_stored_calendar('2026-10-28') v")).rows[0].v, null);
    await db.exec('commit');
    assert.equal((await db.query('select count(*)::int n from futbeat_private.compact_calendar_cache')).rows[0].n, 1);
    await db.exec('drop function public.futbeat_read_qa_stored_calendar(date,text)');
    assert.equal((await db.query('select count(*)::int n from futbeat_private.compact_calendar_cache')).rows[0].n, 1);
  } finally { await db.close(); }
});

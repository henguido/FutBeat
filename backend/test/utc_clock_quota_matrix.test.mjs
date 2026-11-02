import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

test('UTC clock: explicit dates, parse and UTC remain native', () => {
  assert.equal(new Date('2026-01-02T03:04:05Z').toISOString(), '2026-01-02T03:04:05.000Z');
  assert.equal(Date.parse('2026-01-02T00:00:00Z'), Date.UTC(2026, 0, 2));
  assert.ok(Math.abs(new Date().getTime() - Date.now()) < 1000);
});

test('actual process UTC: SQL agrees; yesterday resets, today counts and LIVE reserve holds', async () => {
  const db = await openDatabase();
  const decision = async () => (await db.query("select futbeat_private.quota_decision('goal_api','live-goal','live') v")).rows[0].v;
  try {
    const sqlNow = (await db.query('select now() n')).rows[0].n;
    assert.ok(Math.abs(sqlNow.getTime() - Date.now()) < 60000);
    const cap = (await decision()).safetyCap;
    // Absolute UTC day boundaries: no offset accidentally crosses midnight.
    await db.query(`insert into futbeat_private.provider_call_ledger
      (provider,call_kind,trigger_source,status,reserved_at,completed_at,provider_remaining,metadata)
      values('goal_api','live-goal','test','SUCCEEDED',
        (date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')-interval '1 second',
        (date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')-interval '1 second',5,$1)`,
      [JSON.stringify({ providerRequests: cap })]);
    assert.equal((await decision()).usedToday, 0);
    assert.equal((await decision()).allowed, true);
    await db.query(`insert into futbeat_private.provider_call_ledger
      (provider,call_kind,trigger_source,status,reserved_at,completed_at,metadata)
      values('goal_api','live-goal','test','SUCCEEDED',now(),now(),$1)`,
      [JSON.stringify({ providerRequests: cap })]);
    assert.equal((await decision()).usedToday, cap);
    assert.equal((await decision()).allowed, false);
    await db.query("delete from futbeat_private.provider_call_ledger where reserved_at >= (date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')");
    await db.query(`insert into futbeat_private.provider_call_ledger
      (provider,call_kind,trigger_source,status,reserved_at,completed_at,provider_remaining)
      values('goal_api','global-ingest','test','SUCCEEDED',now(),now(),5)`);
    assert.equal((await decision()).allowed, false, 'today remaining must protect the LIVE reserve');
  } finally { await db.close(); }
});

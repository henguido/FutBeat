import './helpers/midday_utc_clock.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';

test('midday clock: JS and PGlite now() agree, far from both UTC day boundaries', async () => {
  const db = await PGlite.create();
  try {
    const { sql_now: sqlNow, utc_hour: utcHour } = (await db.query(
      "select now() sql_now,extract(hour from now() at time zone 'UTC')::int utc_hour",
    )).rows[0];
    assert.equal(new Date().getUTCHours(), 12);
    assert.equal(utcHour, 12);
    assert.ok(Math.abs(Date.now() - sqlNow.getTime()) < 60e3, 'PGlite must follow the shifted JS clock');
  } finally { await db.close(); }
});

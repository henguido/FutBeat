import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

test('calendar demand deduplicates users and maps a Costa Rica day to UTC dates', async () => {
  const db = await openDatabase();
  try {
    const day = (await db.query(
      "select ((now() at time zone 'America/Costa_Rica')::date+20)::text value",
    )).rows[0].value;

    const first = (await db.query(
      "select public.futbeat_request_calendar_date($1::date,'America/Costa_Rica') value",
      [day],
    )).rows[0].value;
    const second = (await db.query(
      "select public.futbeat_request_calendar_date($1::date,'America/Costa_Rica') value",
      [day],
    )).rows[0].value;

    assert.equal(first.length, 2);
    assert.deepEqual(second, first);
    const queued = (await db.query(
      "select provider_date::text,request_count from futbeat_private.calendar_date_requests order by provider_date",
    )).rows;
    assert.equal(queued.length, 2);
    assert.deepEqual(queued.map((row) => Number(row.request_count)), [2, 2]);

    const plan = (await db.query(
      'select public.futbeat_requested_calendar_dates(12) value',
    )).rows[0].value;
    assert.deepEqual(plan, first);
  } finally {
    await db.close();
  }
});

test('valid stored coverage prevents provider work and fulfilled demand disappears', async () => {
  const db = await openDatabase();
  try {
    const day = (await db.query(
      "select ((now() at time zone 'America/Costa_Rica')::date+30)::text value",
    )).rows[0].value;
    const requested = (await db.query(
      "select public.futbeat_request_calendar_date($1::date,'America/Costa_Rica') value",
      [day],
    )).rows[0].value;
    assert.equal(requested.length, 2);

    for (const providerDate of requested) {
      await db.query(
        "insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count) values('goal_api',$1::date,now(),0) on conflict(provider,provider_date) do update set fetched_at=now(),fixture_count=0",
        [providerDate],
      );
    }

    const plan = (await db.query(
      'select public.futbeat_requested_calendar_dates(12) value',
    )).rows[0].value;
    assert.deepEqual(plan, []);
    const repeated = (await db.query(
      "select public.futbeat_request_calendar_date($1::date,'America/Costa_Rica') value",
      [day],
    )).rows[0].value;
    assert.deepEqual(repeated, []);
  } finally {
    await db.close();
  }
});

test('calendar API schedules recovery only when persisted coverage is partial', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /snapshot\.coverage\?\.partial === true/);
  assert.match(source, /futbeat_request_calendar_date/);
  assert.match(source, /p_local_date: date/);
  assert.match(source, /p_timezone: timezone/);
  assert.ok(
    source.indexOf("/futbeat-api/v1/calendar") <
      source.indexOf("futbeat_request_calendar_date"),
    'calendar recovery must run inside the calendar route',
  );
});

test('global collector prioritizes requested dates without removing daily expansion', async () => {
  const worker = await readFile(
    new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url),
    'utf8',
  );
  const workflow = await readFile(
    new URL('../../.github/workflows/global-fixtures.yml', import.meta.url),
    'utf8',
  );
  assert.match(worker, /futbeat_requested_calendar_dates/);
  assert.match(worker, /requestedOnly === true/);
  assert.match(workflow, /requestedOnly = \$true/);
  assert.match(workflow, /requestedOnly = \$false/);
  assert.match(workflow, /CALENDAR_EXPAND_OK/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';

// Differential check for 20260930125000: reconcile_goal_results_local before
// (20260922230000, the body running in production) and after must write
// exactly the same thing whenever a GOAL answer is coherent (running total =
// result). Only the score source changed; selection, lifecycle, evidence
// time, provenance, called-off handling, events and the unresolved /
// missing_from_provider bookkeeping must not.

const original = (await readFile(new URL('../../supabase/migrations/20260922230000_preserve_terminal_match_writes.sql', import.meta.url), 'utf8'))
  .replace(/\r\n/g, '\n');
const start = original.indexOf('create or replace function futbeat_private.reconcile_goal_results_local(p_provider_date date)');
const originalReconcile = original.slice(start, original.indexOf('\nend $$;', start) + '\nend $$;'.length);

// Deterministic PRNG (mulberry32).
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];

const PAYLOAD_STATUSES = ['SCHEDULED', 'LIVE', 'FINISHED_PENDING_VERIFICATION', 'VERIFIED', 'POSTPONED', 'CANCELLED', 'ABANDONED', 'SUSPENDED'];
const OBS = {
  LIVE: { matchStatus: 'LIVE', matchPeriod: 'SECOND_HALF' },
  HALFTIME: { matchStatus: 'HALF_TIME', matchPeriod: 'HALF_TIME' },
  FINISHED_PENDING_VERIFICATION: { matchStatus: 'FINISHED', matchPeriod: 'FINISHED' },
  POSTPONED: { matchStatus: 'POSTPONED', matchPeriod: 'NOT_STARTED' },
  CANCELLED: { matchStatus: 'CANCELLED', matchPeriod: 'NOT_STARTED' },
  ABANDONED: { matchStatus: 'ABANDONED', matchPeriod: 'SECOND_HALF' },
  SCHEDULED: { matchStatus: 'NOT_STARTED', matchPeriod: 'NOT_STARTED' },
};

// One provider date of scenarios, written identically into both databases.
function scenarios(seed, count, day) {
  const r = rng(seed);
  const base = Date.parse(`${day}T12:00:00.000Z`);
  const out = [];
  for (let i = 0; i < count; i++) {
    const kickoff = new Date(base + Math.floor(r() * 10) * 3600e3 - 5 * 3600e3).toISOString();
    const status = pick(r, PAYLOAD_STATUSES);
    const scored = r() < 0.7;
    const payloadScore = scored ? { home: Math.floor(r() * 5), away: Math.floor(r() * 5) } : null;
    const receivedAt = new Date(Date.parse(kickoff) + (r() * 6 - 2) * 3600e3).toISOString();
    const observations = [];
    for (let k = Math.floor(r() * 4); k > 0; k--) {
      const s = pick(r, Object.keys(OBS));
      const withScore = r() < 0.85;
      const home = withScore ? Math.floor(r() * 5) : null;
      const away = withScore ? Math.floor(r() * 5) : null;
      const raw = r() < 0.15 ? {} // legacy / foreign shape: stored columns only
        : { ...OBS[s], homeTeamScore: home == null ? null : String(home), awayTeamScore: away == null ? null : String(away),
            // A coherent GOAL answer: FT equals the result after a final.
            homeTeamFtScore: s === 'FINISHED_PENDING_VERIFICATION' && home != null ? String(home) : null,
            awayTeamFtScore: s === 'FINISHED_PENDING_VERIFICATION' && away != null ? String(away) : null,
            kickoffUtc: r() < 0.3 ? new Date(Date.parse(kickoff) + 3600e3).toISOString() : kickoff };
      observations.push({ status: s, home, away, raw,
        receivedAt: new Date(Date.parse(kickoff) + (r() * 8 - 1) * 3600e3).toISOString(),
        observedAt: r() < 0.3 ? new Date(Date.parse(kickoff) + r() * 3 * 3600e3).toISOString() : null });
    }
    const events = r() < 0.3;
    out.push({ i, kickoff, status, payloadScore, receivedAt, observations, events });
  }
  return out;
}

async function seed(db, list, tag) {
  await db.exec('alter table futbeat_private.provider_observations disable trigger futbeat_terminal_score_correction');
  for (const s of list) {
    const id = `fb_match_eq${tag}_${s.i}`;
    await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, 'match', JSON.stringify({
      id, competitionId: 'fb_comp_eq', homeTeamId: `fb_team_eqh${s.i}`, awayTeamId: `fb_team_eqa${s.i}`,
      startTime: s.kickoff, status: s.status, ...(s.payloadScore ? { score: s.payloadScore } : {}), events: [], statistics: [],
      provenance: { source: 'GOAL API', receivedAt: s.receivedAt } })]);
    let n = 0;
    for (const o of s.observations) {
      await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,
          provider_observed_at,status,home_score,away_score,payload_hash,raw_payload)
        values('goal_api',$1,$2,$3,$4,$5,$6,$7,$8,$9)`, [`ext-eq${tag}-${s.i}`, id, o.receivedAt, o.observedAt, o.status, o.home, o.away,
        createHash('sha256').update(`${tag}-${s.i}-${n++}`).digest('hex'), JSON.stringify(o.raw)]);
    }
    if (s.events) {
      await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
        values($1,$2,'goal_api','GOAL',$3,$4)`, [`fb_event_eq${tag}_${s.i}`, id, JSON.stringify({ minute: 30, team: 'home' }), s.kickoff]);
    }
  }
}

async function snapshot(db, day) {
  const matches = (await db.query("select id,payload from futbeat_private.entities where kind='match' and id like 'fb_match_eq%' order by id")).rows;
  const states = (await db.query("select match_id,state,provider_date::text,evidence_at,canonical_payload_hash from futbeat_private.match_result_reconciliation where match_id like 'fb_match_eq%' order by match_id")).rows;
  const coverage = (await db.query("select results_complete from futbeat_private.calendar_coverage where provider='goal_api' and provider_date=$1", [day])).rows;
  return { matches, states, coverage };
}

test('reconcile_goal_results_local: identical to the production body for every coherent answer (differential, 3 x 120 scenarios)', async () => {
  for (const seedValue of [1, 7, 42]) {
    const before = await openDatabase();
    const after = await openDatabase();
    try {
      await before.exec(originalReconcile);
      const day = (await after.query("select (current_date-3)::text d")).rows[0].d;
      const list = scenarios(seedValue, 120, day);
      for (const db of [before, after]) {
        await seed(db, list, 'x');
        await db.query("insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at) values('goal_api',$1,now()) on conflict do nothing", [day]);
      }
      const a = (await before.query('select futbeat_private.reconcile_goal_results_local($1::date) v', [day])).rows[0].v;
      const b = (await after.query('select futbeat_private.reconcile_goal_results_local($1::date) v', [day])).rows[0].v;
      assert.ok(a.updated > 0, `seed ${seedValue}: the scenarios exercise writes`);
      assert.deepEqual(b, a, `seed ${seedValue}: same summary`);
      const sa = await snapshot(before, day);
      const sb = await snapshot(after, day);
      assert.deepEqual(sb.matches, sa.matches, `seed ${seedValue}: same match payloads`);
      assert.deepEqual(sb.states, sa.states, `seed ${seedValue}: same reconciliation states`);
      assert.deepEqual(sb.coverage, sa.coverage, `seed ${seedValue}: same coverage`);
    } finally {
      await before.close();
      await after.close();
    }
  }
});

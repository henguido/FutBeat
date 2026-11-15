#!/usr/bin/env node
// Seven-day replay of the GOAL quota: 1,000 requests a day, reset at 00:00 UTC.
// Load: backend/test/fixtures/goal_quota_load_244.json, derived from the ledger.
// Every live poll keeps its measured time, list size, absences and reappearances;
// matches are built from those absences with the measured class mix.
// The rules mirror the production SQL (quota_decision, reserve_terminal_recovery_call,
// match_detail_planner_due). `efficient` turns on migration 20261031240000.
// It is a model, not a measurement: see calibrate() for how close "before" lands.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const DAY = 1440;
const FINAL_MIN = 120; // finalFetchAfterMinutes
const LIVE_POLL_RESERVE_PER_HOUR = 13;
const FLOORS = { live: 20, results: 20, user_high: 150, user: 300, coverage: 300, bootstrap: 600 };
const SHARES = { live: .25, results: .15, prematch: .15, recent: .25, history: .08, upcoming: .03 };
const SHARE_KEY = { live: 'live', results: 'results', prematch: 'prematch', recent_hot: 'recent', recent: 'recent', history: 'history', upcoming: 'upcoming' };
const RANK = { live: 1, results: 2, prematch: 3, recent_hot: 4, recent: 5, upcoming: 6, history: 7 };

function rng(seed) { // mulberry32: same load on every run
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const loadFixture = () => JSON.parse(readFileSync(
  new URL('../../backend/test/fixtures/goal_quota_load_244.json', import.meta.url), 'utf8'));

function buildMatches(load, sc, random) {
  const { mix, sections } = load;
  const stubShare = sc.calendarRecovered ? 0 : mix.stub / mix.matches;
  const realShare = 1 - mix.stub / mix.matches;
  const prioShare = mix.priority / mix.matches / realShare;
  const favOfPrio = mix.favorite / mix.priority;
  const matches = [];
  const scale = sc.volume ?? 1;
  for (const [t, total, absent, , reappeared] of load.polls) {
    const net = Math.max(0, absent - reappeared) * scale;
    let n = Math.floor(net) + (random() < net % 1 ? 1 : 0);
    for (; n > 0; n--) {
      const stub = random() < stubShare;
      const priority = !stub && random() < prioShare;
      const favorite = priority && random() < favOfPrio;
      const finalAt = t - Math.floor(random() * 5);
      const kickoff = finalAt - 105 - Math.floor(random() * 20);
      const hasLineup = random() < (priority ? sections.lineupPriority : sections.lineupLow) * 1.15;
      const hasStats = random() < (priority ? sections.statsPriority : sections.statsLow) * 1.1;
      matches.push({
        stub, priority, favorite, finalAt, kickoff, detectedAt: t, total,
        lineupAt: hasLineup ? kickoff - 20 + Math.floor(random() * 35) : null,
        statsAt: hasStats ? kickoff + 5 : null,
        overdue: false, overdueUntil: 0,
        fetched: null, cachedFinal: false, lineup: 'UNKNOWN', stats: 'UNKNOWN', lineupMisses: 0, statMisses: 0,
        lastMissAt: -1e9, recheckAt: Infinity, phase: {}, knownFinalAt: null, lineupSeenAt: null,
      });
    }
  }
  return matches;
}

function day(t) { return Math.floor(t / DAY); }

export function simulate(load, { efficient = false, scenario = {} } = {}) {
  const sc = { pages: false, calendarRecovered: false, calendarUnitsPerDay: 0, volume: 1, seed: 244, ...scenario };
  const random = rng(sc.seed);
  const matches = buildMatches(load, sc, random);
  const start = load.polls[0][0];
  const end = load.polls.at(-1)[0] + 1;
  const byDay = {};
  const dayStat = (t) => (byDay[day(t)] ??= { used: 0, detail: 0, kinds: {}, buckets: {}, squads: 0, remAt18: null, minRem: 1000 });
  const hourly = Array(24).fill(0);
  const totals = { kinds: {}, buckets: {}, denied: { live: 0, other: 0 }, exhaustedMinutes: 0 };
  const spend = (t, kind, units = 1, bucket = null) => {
    const d = dayStat(t);
    d.used += units; d.kinds[kind] = (d.kinds[kind] ?? 0) + units;
    totals.kinds[kind] = (totals.kinds[kind] ?? 0) + units;
    if (kind === 'match-detail') {
      d.detail += units;
      d.buckets[bucket] = (d.buckets[bucket] ?? 0) + 1;
      hourly[Math.floor(t / 60) % 24] += 1;
      totals.buckets[bucket] = (totals.buckets[bucket] ?? 0) + 1;
    }
  };
  const remaining = (t) => Math.max(0, 1000 - dayStat(t).used);
  const allowed = (t, kind, cls) => {
    const rem = remaining(t);
    let reserve = 0;
    if (kind !== 'live-goal' && kind !== 'results-date') {
      const factor = ['user', 'user_high', 'live'].includes(cls) ? .5 : 1;
      const hoursLeft = (DAY - (t % DAY)) / 60;
      reserve = Math.ceil(hoursLeft * LIVE_POLL_RESERVE_PER_HOUR * (sc.pages ? 2 : 1) * factor);
    }
    return rem > Math.max(FLOORS[cls], FLOORS.live + reserve);
  };
  const band = (rem) => (rem > 600 ? 'abundant' : rem > 300 ? 'normal' : rem > 150 ? 'tight' : 'critical');

  const rows = []; // live_terminal_recovery
  const addRow = (m, reason, t) => {
    rows.push({ m, reason, attempts: 0, next: t + (reason === 'absent' ? 1 : 0), detectedAt: t, state: 'PENDING' });
  };
  const ghost = () => ({ stub: random() < .32, priority: false, ghost: true, finalAt: Infinity, kickoff: 0 });

  const resultsDates = {}; // date -> {next, requested, lastCall, attempts}
  const dateOf = (m) => day(m.kickoff);
  const answerResults = (t, date) => {
    const units = sc.pages && matches.length > 2500 ? 2 : (matches.filter((m) => dateOf(m) === date).length > 500 ? 2 : 1);
    spend(t, 'results-date', units);
    for (const m of matches) {
      if (dateOf(m) === date && !m.stub && m.finalAt <= t - (sc.resultsLag ?? 5) && m.knownFinalAt == null) m.knownFinalAt = t;
    }
  };

  const fetchDetail = (t, m, bucket) => {
    spend(t, 'match-detail', 1, bucket);
    if (m.ghost) return;
    const isFinal = t >= m.finalAt;
    m.fetched = t;
    m.cachedFinal = isFinal;
    if (isFinal && !m.stub && m.knownFinalAt == null) m.knownFinalAt = t;
    const lineupNow = m.lineupAt != null && t >= m.lineupAt;
    const statsNow = m.statsAt != null && t >= m.statsAt;
    if (lineupNow) { if (m.lineupSeenAt == null) m.lineupSeenAt = t; m.lineup = 'AVAILABLE'; }
    if (statsNow) m.stats = 'AVAILABLE';
    if (isFinal && t >= m.lastMissAt + 15) {
      m.lastMissAt = t;
      if (!lineupNow && ++m.lineupMisses >= 2) { m.lineup = 'NO_DATA'; m.recheckAt = t + 720; }
      if (!statsNow && ++m.statMisses >= 2) { m.stats = 'NO_DATA'; m.recheckAt = t + 720; }
    }
  };

  const bucketOf = (m, t) => {
    if (m.stub) return null;
    // A final the system has not seen yet still reads as LIVE.
    if (t >= m.kickoff && t < m.kickoff + 240 && (t < m.finalAt || m.knownFinalAt == null)) return 'live';
    if (t >= m.finalAt && t < m.kickoff + 240) return 'results';
    if (t < m.kickoff) return t >= m.kickoff - 90 ? 'prematch' : t >= m.kickoff - 1440 ? 'upcoming' : null;
    if (t < m.kickoff + 360) return 'recent_hot';
    if (t < m.kickoff + 2160) return 'recent';
    if (t < m.kickoff + 10080) return 'history';
    return null;
  };
  const phaseOf = (b) => (['prematch', 'live', 'results'].includes(b) ? b : 'finished');
  const caps = { prematch: 3, live: 6, results: 2, finished: 4 };
  const plannerDue = (m, b, t) => {
    const rem = remaining(t);
    if (efficient && !m.priority) {
      return m.fetched == null && ['live', 'results', 'recent_hot', 'recent'].includes(b) && band(rem) === 'abundant';
    }
    const phase = phaseOf(b);
    const cap = efficient && phase === 'live' ? 4 : caps[phase];
    m.phase[phase] = (m.phase[phase] ?? []).filter((x) => x > t - DAY);
    if (m.phase[phase].length >= cap) return false;
    if (m.fetched == null) return true;
    if (b === 'results') {
      if (efficient && m.cachedFinal) return t >= m.kickoff + FINAL_MIN && m.fetched < m.kickoff + FINAL_MIN;
      return t - m.fetched > 30;
    }
    if (b === 'upcoming') return false;
    const gapNear = t < m.kickoff + 360 ? 15 : 360;
    if (b === 'live') {
      const retry = efficient ? 10 : 5;
      return (m.lineup === 'UNKNOWN' && t - m.fetched > retry) || (t - m.fetched > 30 && ['abundant', 'normal'].includes(band(rem)));
    }
    if (b === 'prematch') return t >= m.kickoff - 90 && m.lineup === 'UNKNOWN' && t - m.fetched > 20;
    if (t >= m.kickoff + FINAL_MIN && m.fetched < m.kickoff + FINAL_MIN) return true;
    return t - m.fetched > gapNear && (m.lineup === 'UNKNOWN' || m.stats === 'UNKNOWN'
      || ((m.lineup === 'NO_DATA' || m.stats === 'NO_DATA') && m.recheckAt <= t));
  };

  const settle = (t) => {
    const waiting = {};
    for (const r of rows) {
      if (r.state !== 'PENDING') continue;
      const m = r.m;
      if (!m.stub && !m.ghost && m.knownFinalAt != null) { r.state = 'RESOLVED'; continue; }
      if (r.reason === 'overdue' && r.attempts >= (efficient ? 3 : 6)) { r.state = 'EXHAUSTED'; continue; }
      if (r.attempts >= 6 || t - r.detectedAt > 360) { r.state = 'EXHAUSTED'; continue; }
      if (efficient && m.stub) { r.state = 'EXHAUSTED'; continue; }
      if (t - r.detectedAt > 10 && !m.stub && !m.ghost) {
        const date = dateOf(m);
        (waiting[date] ??= { n: 0, zero: 0 }).n++;
        if (r.attempts === 0) waiting[date].zero++;
      }
    }
    const every = efficient ? 30 : 60;
    for (const [date, w] of Object.entries(waiting)) {
      const s = (resultsDates[date] ??= { next: 0, requested: -1e9, last: -1e9, attempts: 0 });
      if (t - s.requested >= every) {
        s.requested = t;
        if (efficient && w.zero >= 3) s.next = t;
      }
    }
  };
  const nextRecovery = (t) => {
    let best = null;
    for (const r of rows) {
      if (r.state !== 'PENDING' || r.next > t) continue;
      const m = r.m;
      if (r.reason === 'absent' && r.attempts >= 2) continue;
      if (efficient && r.reason === 'absent' && !m.priority && !(t - r.detectedAt >= 45 && r.attempts === 0)) continue;
      const score = [(efficient && m.priority) ? 0 : 1, r.next];
      if (!best || score[0] < best.score[0] || (score[0] === best.score[0] && score[1] < best.score[1])) best = { r, score };
    }
    return best?.r ?? null;
  };
  const serveRecovery = (t) => {
    if (!(remaining(t) > FLOORS.user_high) || !allowed(t, 'match-detail', 'results') || dayStat(t).detail >= 900) return false;
    const r = nextRecovery(t);
    if (!r) return false;
    r.attempts += 1;
    r.next = t + (efficient && r.reason === 'overdue' ? 30 : Math.min(30, 2 ** r.attempts));
    fetchDetail(t, r.m, 'recovery');
    const isFinal = !r.m.ghost && t >= r.m.finalAt;
    if (isFinal && (efficient || !r.m.stub)) r.state = 'RESOLVED';
    return true;
  };
  // The planner queues at most its band batch per run; the slow buckets only on
  // the full run, every five minutes (plannerFullIntervalSeconds).
  const servePlanner = (t, active, tick) => {
    const d = dayStat(t);
    const rem = remaining(t);
    if (d.detail >= 900) return false;
    const batch = { abundant: 4, normal: 2, tight: 1, critical: 0 }[band(rem)];
    let best = null;
    for (const m of active) {
      const b = bucketOf(m, t);
      if (!b || b === 'history' && band(rem) !== 'abundant') continue;
      if ((b === 'recent' || b === 'upcoming') && !['abundant', 'normal'].includes(band(rem))) continue;
      const urgent = b === 'live' || b === 'results';
      if (!urgent && tick.background >= batch) continue;
      if (['recent', 'upcoming', 'history'].includes(b) && t % 5 !== 0) continue;
      const cls = b === 'live' ? 'live' : b === 'results' ? 'results' : b === 'prematch' ? 'user_high' : b === 'history' ? 'bootstrap' : 'coverage';
      if (b !== 'results' && rem <= 400) continue;
      if (urgent ? d.detail >= 765 : d.detail >= 540) continue;
      if (!allowed(t, 'match-detail', cls)) continue;
      const shareKey = SHARE_KEY[b];
      const usedBucket = b === 'recent_hot' || b === 'recent'
        ? (d.buckets.recent ?? 0) + (d.buckets.recent_hot ?? 0) : (d.buckets[b] ?? 0);
      if (usedBucket >= Math.floor(900 * SHARES[shareKey])) continue;
      if (!plannerDue(m, b, t)) continue;
      const score = RANK[b] * 2 - (efficient && m.priority ? 1 : 0);
      if (!best || score < best.score) best = { m, b, score };
    }
    if (!best) return false;
    fetchDetail(t, best.m, best.b);
    (best.m.phase[phaseOf(best.b)] ??= []).push(t);
    if (best.b !== 'live' && best.b !== 'results') tick.background += 1;
    return true;
  };

  const pollAt = new Map(load.polls.map((p) => [p[0], p]));
  const otherAt = new Map();
  for (const o of load.others) (otherAt.get(o[0]) ?? otherAt.set(o[0], []).get(o[0])).push(o);
  const byDetected = new Map();
  for (const m of matches) (byDetected.get(m.detectedAt) ?? byDetected.set(m.detectedAt, []).get(m.detectedAt)).push(m);
  const squadPacedCap = 25;
  const calendarBudget = sc.calendarUnitsPerDay;

  for (let t = start; t < end; t++) {
    if (t % DAY === 18 * 60) dayStat(t).remAt18 = remaining(t);
    const active = matches.filter((m) => t >= m.kickoff - 1440 && t < m.kickoff + 10080 && !m.stub);

    // Calendar lane after the reset: reserve-sized estimate, not measured.
    if (calendarBudget && t % DAY === 17) spend(t, 'calendar-ingest', calendarBudget);
    for (const o of otherAt.get(t) ?? []) {
      if (remaining(t) > FLOORS.live) spend(t, o[1], o[2]); else totals.denied.other += 1;
    }

    const poll = pollAt.get(t);
    if (poll) {
      const [, total, , overdue, reappeared] = poll;
      const units = sc.pages && total >= 100 ? 3 : sc.pages && total >= 95 ? 2 : 1;
      if (remaining(t) > 0) {
        spend(t, 'live-goal', units);
        for (const m of byDetected.get(t) ?? []) addRow(m, 'absent', t);
        // A cut list reports matches as gone; with every page read they stay.
        const falseGone = sc.pages && total >= 95 ? 0 : reappeared;
        for (let i = 0; i < falseGone; i++) {
          const g = ghost();
          addRow(g, 'absent', t);
          rows[rows.length - 1].cancelAt = t + 5 + Math.floor(random() * 25);
        }
        for (let i = 0; i < overdue; i++) {
          const g = { ...ghost(), overdue: true, ghost: true, priority: random() < .2, stub: random() < .32 };
          addRow(g, 'overdue', t);
          rows[rows.length - 1].cancelAt = t + 20 + Math.floor(random() * 50);
        }
      } else totals.denied.live += 1;
    }
    for (const r of rows) if (r.state === 'PENDING' && r.cancelAt != null && t >= r.cancelAt) r.state = 'CANCELLED';

    // futbeat-goal-results-cron and its demand path.
    settle(t);
    for (const [dateKey, s] of Object.entries(resultsDates)) {
      const date = Number(dateKey);
      if (s.requested > s.last && t >= s.next && remaining(t) > FLOORS.results) {
        s.last = t; s.attempts += 1;
        s.next = t + 120 * Math.min(s.attempts, 4);
        answerResults(t, date);
      }
    }
    if (t % 120 === 43 && remaining(t) > 120 && day(t) > 0) {
      const date = day(t) - 1;
      const s = (resultsDates[date] ??= { next: 0, requested: -1e9, last: -1e9, attempts: 0 });
      if (t >= s.next) { s.last = t; s.attempts += 1; s.next = t + 120 * Math.min(s.attempts, 4); answerResults(t, date); }
    }

    // detail cron: up to 3 calls a minute; the five-minute run adds one and a squad.
    const tick = { background: 0 };
    for (let i = 0; i < 3 + (t % 5 === 0 ? 1 : 0); i++) {
      if (!serveRecovery(t) && !servePlanner(t, active, tick)) break;
    }
    if (t % 5 === 0 && allowed(t, 'team-squad', 'coverage')) {
      const d = dayStat(t);
      // 65 a day is the measured rate; the due pool, not the quota, limits it.
      if (d.squads < (efficient ? squadPacedCap : 65)) {
        d.squads += 1;
        spend(t, 'team-squad', 1);
      }
    }
    const d = dayStat(t);
    d.minRem = Math.min(d.minRem, remaining(t));
    if (remaining(t) <= FLOORS.live) totals.exhaustedMinutes += 1;
  }

  const inWindow = matches.filter((m) => !m.stub && m.detectedAt >= DAY && m.detectedAt < end - 1440);
  const latency = (list) => {
    const known = list.filter((m) => m.knownFinalAt != null).map((m) => m.knownFinalAt - m.finalAt).sort((a, b) => a - b);
    return {
      matches: list.length,
      resolved: known.length,
      resolvedShare: list.length ? +(known.length / list.length).toFixed(3) : 1,
      p50: known[Math.floor(known.length * .5)] ?? null,
      p95: known[Math.floor(known.length * .95)] ?? null,
    };
  };
  const lineups = (list) => {
    const expected = list.filter((m) => m.lineupAt != null);
    const got = expected.filter((m) => m.lineupSeenAt != null);
    return { expected: expected.length, captured: got.length, share: expected.length ? +(got.length / expected.length).toFixed(3) : 1 };
  };
  const days = Object.entries(byDay).sort(([a], [b]) => a - b).map(([k, v]) => ({ day: Number(k), used: v.used, detail: v.detail, remAt18: v.remAt18, minRem: v.minRem }));
  const fullDays = days.filter((x) => x.day >= 1 && x.day <= 7);
  return {
    matches: matches.length,
    detailByHour: hourly,
    kinds: totals.kinds,
    buckets: totals.buckets,
    total: Object.values(totals.kinds).reduce((a, b) => a + b, 0),
    days,
    avgRemAt18: Math.round(fullDays.reduce((a, x) => a + (x.remAt18 ?? 0), 0) / Math.max(1, fullDays.length)),
    worstRemAt18: Math.min(...fullDays.map((x) => x.remAt18 ?? 1000)),
    livePollsDenied: totals.denied.live,
    otherDenied: totals.denied.other,
    exhaustedMinutes: totals.exhaustedMinutes,
    resultsPriority: latency(inWindow.filter((m) => m.priority)),
    resultsFavorite: latency(inWindow.filter((m) => m.favorite)),
    resultsAll: latency(inWindow),
    lineupsPriority: lineups(inWindow.filter((m) => m.priority)),
    lineupsLow: lineups(inWindow.filter((m) => !m.priority)),
  };
}

export const SCENARIOS = {
  'A semana medida (1 pagina, calendario roto)': {},
  'B A + paginacion LIVE (hasta 2 paginas extra)': { pages: true },
  'C B + calendario recuperado (+60/dia, estimado)': { pages: true, calendarRecovered: true, calendarUnitsPerDay: 60 },
  'D C + carga 130 %': { pages: true, calendarRecovered: true, calendarUnitsPerDay: 60, volume: 1.3 },
};

export function compareAll(load = loadFixture()) {
  const out = {};
  for (const [name, scenario] of Object.entries(SCENARIOS)) {
    out[name] = { before: simulate(load, { scenario }), after: simulate(load, { efficient: true, scenario }) };
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const load = loadFixture();
  const results = compareAll(load);
  const b = results[Object.keys(SCENARIOS)[0]].before;
  console.log('calibracion (A antes frente a ledger, 7 dias):', JSON.stringify({ medido: load.measured, simulado: { detalle: b.buckets, live: b.kinds['live-goal'], resultados: b.kinds['results-date'], squads: b.kinds['team-squad'], detalleHora: b.detailByHour } }));
  for (const [name, { before, after }] of Object.entries(results)) {
    console.log(`\n${name}`);
    for (const [label, r] of [['antes', before], ['despues', after]]) {
      console.log(`  ${label.padEnd(8)} total ${r.total} detalle ${r.kinds['match-detail'] ?? 0} live ${r.kinds['live-goal'] ?? 0} res ${r.kinds['results-date'] ?? 0} squad ${r.kinds['team-squad'] ?? 0} | 18:00 media ${r.avgRemAt18} peor ${r.worstRemAt18} | live negados ${r.livePollsDenied} | prio p95 ${r.resultsPriority.p95} min (${r.resultsPriority.resolvedShare}) fav p95 ${r.resultsFavorite.p95} todos p95 ${r.resultsAll.p95} (${r.resultsAll.resolvedShare}) | aliniac prio ${r.lineupsPriority.share} baja ${r.lineupsLow.share}`);
    }
    console.log(`  buckets antes ${JSON.stringify(before.buckets)}`);
    console.log(`  buckets desp  ${JSON.stringify(after.buckets)}`);
  }
}

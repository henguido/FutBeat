#!/usr/bin/env python
"""Days to cover +14/+45/+90 with the real GOAL quota. Compares policies; it is not a forecast.

Measured inputs (read-only JSON from production, path in argv[1]): rem.json, remaining by hour;
day.json, fixtures by date; runs200.tsv, real start of each scheduled run.
Assumed, and stated: future dates are as large as past ones of the same weekday (GOAL may
publish fewer far ahead, so this errs on the slow side); a day repeats a past day; one page per
100 fixtures; no ingest fails; days are independent.
"""
import collections, datetime as dt, json, math, os, random, statistics as st, sys

K = sys.argv[1] if len(sys.argv) > 1 else '.'
RESERVE, MARGIN, FRESH = 350, 15, 650
load = lambda n: json.load(open(os.path.join(K, n), encoding='utf-8'))[0]['r']

hours = collections.defaultdict(dict)
for x in load('rem.json'):
    hours[x['h'][:10]][int(x['h'][11:])] = x['mn']
QUOTA_DAYS = [d for d in sorted(hours) if len(hours[d]) >= 15]
sizes = collections.defaultdict(list)
for x in load('day.json'):
    d = dt.date.fromisoformat(x['d'])
    if dt.date(2026, 9, 1) <= d < dt.date(2026, 10, 30) and x['n'] >= 40:
        sizes[d.isoweekday()].append(x['n'])
runs = collections.defaultdict(list)
for line in open(os.path.join(K, 'runs200.tsv')):
    t, event, _ = line.split('\t')
    if event == 'schedule':
        runs[t[:10]].append(int(t[11:13]) + int(t[14:16]) / 60)
RUN_DAYS = [d for d in sorted(runs) if d >= '2026-09-22' and d < '2026-11-01']


def remaining_at(day, hour, relief):
    table = hours[day]
    keys = [h for h in table if h <= int(hour)]
    value = table[max(keys)] if keys else 1000
    if relief and hour < 6:
        value = 1000 - (1000 - value) * relief
    return value


def pages(n):
    return max(1, math.ceil(n / 100))


def stale_age(policy, offset):
    if policy == 'now':
        return 1 if offset <= 14 else 7
    return 1 if offset <= 3 else 3 if offset <= 14 else 7 if offset <= 45 else 21


def simulate(rng, days, policy='new', budget=90, near_budget=45, near_to=14, extra=0.0, relief=0.0):
    start = dt.date(2026, 11, 1)
    size = {}
    size_of = lambda d: size.setdefault(d, rng.choice(sizes[d.isoweekday()]))
    fetched = {}
    done = {14: None, 45: None, 90: None}
    spent, live, sample = [], [], []
    for i in range(days):
        today = start + dt.timedelta(i)
        quota_day = rng.choice(QUOTA_DAYS)
        times = sorted(runs[rng.choice(RUN_DAYS)])
        if extra and min(times) > 2 and rng.random() < extra:
            times = [0.85] + times
        day_spent, day_ingests = 0, 0
        for t in times:
            now = i + t / 24
            remaining = remaining_at(quota_day, t, relief) - day_spent
            if remaining < RESERVE:
                continue
            hot = sum(pages(size_of(today + dt.timedelta(k))) for k in (-1, 0, 1, 2))
            remaining -= hot
            day_spent += hot
            if remaining < RESERVE:
                continue
            expand = remaining >= FRESH or int(t) == 9
            limit = budget if expand else near_budget
            last = 90 if expand else near_to
            used = 0
            for off in range(2, last + 1):
                d = today + dt.timedelta(off)
                if d in fetched and now - fetched[d] < stale_age(policy, off):
                    continue
                if remaining <= RESERVE + MARGIN or used >= limit or day_ingests >= 64:
                    break
                cost = pages(size_of(d))
                used += cost
                remaining -= cost
                day_spent += cost
                day_ingests += 1
                fetched[d] = now
        spent.append(day_spent)
        for span in done:
            if done[span] is None and all(today + dt.timedelta(o) in fetched for o in range(2, span + 1)):
                done[span] = i + 1
        fresh = sum(1 for o in range(2, 91) if today + dt.timedelta(o) in fetched
                    and i + 1 - fetched[today + dt.timedelta(o)] < stale_age('new', o) + 1)
        sample.append(fresh / 89)
    return done, st.mean(spent), st.mean(sample[-14:])


CASES = (
    ('actual (plan de hoy, near +7)', dict(policy='now', near_to=7, near_budget=90)),
    ('propuesta (migración + workflow)', dict()),
    ('propuesta, presupuesto 150', dict(budget=150)),
    ('propuesta, +50% ejecuciones tempranas', dict(extra=0.5)),
    ('propuesta, BE-205 reduce a la mitad el gasto 00-06 h', dict(relief=0.5)),
)

if __name__ == '__main__':
    early = sum(1 for d in RUN_DAYS if min(runs[d]) <= 2) / len(RUN_DAYS)
    print(f'dias cuota {QUOTA_DAYS[0]}..{QUOTA_DAYS[-1]} ({len(QUOTA_DAYS)}), dias corrida {len(RUN_DAYS)}, primera corrida antes de 02:00 UTC {early:.0%}')
    print('paginas por semana', sum(pages(st.median(sizes[w])) for w in range(1, 8)), {w: st.median(sizes[w]) for w in range(1, 8)})
    for name, kw in CASES:
        res = [simulate(random.Random(s), 45, **kw) for s in range(200)]
        out = []
        for span in (14, 45, 90):
            vals = sorted(r[0][span] for r in res if r[0][span])
            out.append(f'+{span}: p50 {vals[len(vals) // 2] if vals else "no"} p90 {vals[int(len(vals) * .9)] if len(vals) == len(res) else "no"} ({len(vals)}/{len(res)})')
        print(f'{name:52s} {" | ".join(out)} | pag/dia {st.mean(r[1] for r in res):.0f} | vigente final {st.mean(r[2] for r in res):.0%}')

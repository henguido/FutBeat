#!/usr/bin/env python
"""Times each statement of the calendar ingest for one synthetic date on local PG 17.

Local only: refuses any host but localhost. No GOAL, no production. The database must be a
copy of pro152_migtpl with the production bodies loaded (prod_fns.sql of the turn 244 kit). Statement timings are
scaled with --factor (production/local; 4.3 for writes, 18 for the context read, turn 244 report) to compare with
the 8 s limit of the API role; --reproduce runs the same statement under 8 s / factor so
57014 happens for real.
"""
import argparse, json, os, re, subprocess, sys

BIN = 'F:/FutBeat/local-pg17/x/pgsql/bin/psql.exe'
ENV = dict(os.environ, PGCLIENTENCODING='UTF8')
SNAP = """create or replace function pg_temp.snap(tag text,day date,recv text,lo int,hi int) returns jsonb language sql as $f$
select jsonb_build_object('demo',false,'schemaVersion',1,
 'competitions',coalesce((select jsonb_agg(jsonb_build_object('id','fb_competition_b'||tag||c,'name','Comp '||c,'country','XX','kind','league'))
    from generate_series(lo%300,(hi%300)+case when hi%300<lo%300 then 300 else 0 end) c),'[]'::jsonb),
 'teams',(select jsonb_agg(jsonb_build_object('id','fb_team_b'||tag||t,'name','Team '||t)) from generate_series(2*lo,2*hi+1) t),
 'matches',(select jsonb_agg(jsonb_build_object('id','fb_match_b'||tag||i,'homeTeamId','fb_team_b'||tag||(2*i),'awayTeamId','fb_team_b'||tag||(2*i+1),
   'competitionId','fb_competition_b'||tag||(i%300),'events','[]'::jsonb,'minute',null,'score',null,'season','2026','statistics','[]'::jsonb,'status','SCHEDULED','venue','',
   'startTime',to_char((day::timestamp+make_interval(mins=>i%1200)),'YYYY-MM-DD"T"HH24:MI:SS.000"Z"'),
   'provenance',jsonb_build_object('externalId','b'||tag||i,'receivedAt',recv,'source','GOAL API','verificationStatus','PROVISIONAL'))) from generate_series(lo,hi) i))
$f$;
create or replace function pg_temp.ctx(tag text,n int,day date) returns jsonb language sql as $f$
select public.CTXFN(
 (select array_agg(id) from (select value->>'id' id from futbeat_private.imports i,jsonb_array_elements(i.snapshot->'competitions') order by 1 limit least(n/5,400)) x),
 (select array_agg(id) from (select value->>'id' id from futbeat_private.imports i,jsonb_array_elements(i.snapshot->'teams') order by 1 limit least(2*n,6000)) x),
 day::timestamp at time zone 'UTC',(day+1)::timestamp at time zone 'UTC')
$f$;
set client_min_messages=warning;
set work_mem='2184kB';
"""


SQLHEAD = SNAP.replace('CTXFN', 'futbeat_read_ingest_context')


def psql(db, sql, ok=True):
    p = subprocess.run([BIN, '-h', 'localhost', '-p', '54329', '-U', 'postgres', '-X', '-At', '-d', db] + (['-v', 'ON_ERROR_STOP=1'] if ok else []),
                       input=sql, capture_output=True, text=True, encoding='utf-8', env=ENV)
    if ok and p.returncode:
        sys.exit(p.stderr[-800:])
    return p.stdout + p.stderr


def timed(db, stmts):
    out = psql(db, SQLHEAD + chr(92) + 'timing on' + chr(10) + ''.join(s + chr(10) for s in stmts))
    return [float(x) for x in re.findall(r'Time: ([\d.]+) ms', out)][-len(stmts):]


def run(db, n, day, tag, reps):
    store = lambda recv, lo, hi: f"select left(public.futbeat_store_calendar_entities('goal_api',pg_temp.snap('{tag}','{day}','{recv}',{lo},{hi}))::text,20);"
    cov = json.dumps([{'date': day, 'count': n}])
    rng = lambda recv: f"select left(public.futbeat_store_calendar_range('goal_api','{recv}'::timestamptz,'{cov}'::jsonb,pg_temp.snap('{tag}','{day}','{recv}',0,{n-1}))::text,20);"
    read = f"select length(public.futbeat_read_calendar_range('{day}','{day}','UTC')::text);"
    ctx = f"select length(pg_temp.ctx('{tag}',{n},'{day}')::text);"
    res = {'n': n}
    res['context'] = max(timed(db, [ctx] * reps))
    res['read_range_cold'] = max(timed(db, [read] * reps))
    # v43: one statement, unseen fixtures. Rolled back to keep the date cold.
    recv = '2026-11-01T00:00:00.000Z'
    t = timed(db, ['begin;', rng(recv), 'rollback;'])
    res['single_store_cold'] = t[1]
    # v44: entity chunks, then the date store.
    chunks = [store(recv, lo, min(lo + 299, n - 1)) for lo in range(0, n, 300)]
    t = timed(db, chunks + [rng(recv)])
    res['chunk_max_cold'] = max(t[:-1]); res['chunks_sum_cold'] = sum(t[:-1]); res['date_store_cold'] = t[-1]
    res['read_range_refresh'] = max(timed(db, [read] * reps))
    recv = '2026-11-08T00:00:00.000Z'
    t = timed(db, [store(recv, lo, min(lo + 299, n - 1)) for lo in range(0, n, 300)] + [rng(recv)])
    res['chunk_max_refresh'] = max(t[:-1]); res['chunks_sum_refresh'] = sum(t[:-1]); res['date_store_refresh'] = t[-1]
    return res


def reproduce(db, n, day, tag, factor):
    """The statements that exceed the scaled limit, cancelled for real by PG."""
    limit = int(8000 / factor)
    recv = '2026-11-15T00:00:00.000Z'
    cov = json.dumps([{'date': day, 'count': n}])
    out = {}
    for name, sql in (('read_range', f"select length(public.futbeat_read_calendar_range('{day}','{day}','UTC')::text);"),
                      ('context', f"select length(pg_temp.ctx('{tag}',{n},'{day}')::text);"),
                      ('date_store', f"select left(public.futbeat_store_calendar_range('goal_api','{recv}'::timestamptz,'{cov}'::jsonb,pg_temp.snap('{tag}','{day}','{recv}',0,{n-1}))::text,20);")):
        r = psql(db, SQLHEAD + f"set statement_timeout='{limit}ms';\n{sql}\n", ok=False)
        out[name] = '57014' if 'statement timeout' in r else 'ok'
    return {'n': n, 'limit_ms': limit, **out}


if __name__ == '__main__':
    a = argparse.ArgumentParser()
    a.add_argument('--db', default='s244_a'); a.add_argument('--sizes', default='300,800,1500,1592,2000,3000')
    a.add_argument('--factor', type=float, default=0.0); a.add_argument('--reps', type=int, default=3)
    a.add_argument('--out', default=''); a.add_argument('--context-fn', default='futbeat_read_ingest_context'); a.add_argument('--tag', default='a')
    x = a.parse_args()
    SQLHEAD = SNAP.replace('CTXFN', x.context_fn)
    rows = []
    for i, n in enumerate(int(s) for s in x.sizes.split(',')):
        day = f'2027-03-{i + 1:02d}'
        tag = f'{x.tag}{n}'
        r = run(x.db, n, day, tag, x.reps)
        if x.factor:
            r['reproduce'] = reproduce(x.db, n, day, tag, x.factor)
        rows.append(r)
        print(json.dumps(r))
    if x.out:
        json.dump(rows, open(x.out, 'w'), indent=1)

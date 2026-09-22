// All fixtures/strategy replacements are disposable PGlite only. No network.
import { openDatabase } from '../storage/database.mjs';
import { seedCandidatePool, installPlanner, tracePools, planNodes } from './squad_candidate_pool.mjs';
import { explain } from './squad_planner.mjs';

export const bucketExpression = "case when m.start_time<=now()+interval '24 hours' then 0 when m.start_time<=now()+interval '72 hours' then 1 else 2 end";
export const plan = async (db, limit = 20) => (await db.query('select public.futbeat_team_squad_plan($1) value', [limit])).rows[0].value;
export const ranked = async db => (await db.query('select * from futbeat_private.squad_upcoming_candidates()')).rows;
export const definition = async (db, signature) => (await db.query('select pg_get_functiondef($1::regprocedure) v', [signature])).rows[0].v;

export async function seedRankingFixture(db, large = false) {
  if (large) {
    await seedCandidatePool(db);
    await db.exec('delete from futbeat_private.coverage_interests');
    // Same 10000-team universe, varied genuine editorial/derived metadata.
    await db.exec(`insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source)
      select 'fb_pool_comp_'||i,'other',case when i%10=0 then 930 when i%10=1 then 970 else 100 end,
        case when i%10<2 then 'editorial' else 'derived' end from generate_series(0,99) i
      on conflict(competition_id) do update set relevance_score=excluded.relevance_score,source=excluded.source;
      insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
        values('competition','fb_pool_comp_5',2,'DEEP');
      insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
        values('00000000-0000-0000-0000-000000000001','team','fb_pool_team_4',now()+interval '1 hour');`);
    return;
  }
  const fixtures = [
    ['low_near', 'Lower competition', 100, 'derived', 10],
    ['u23_near', 'U23 modest metadata', 100, 'derived', 12],
    ['women_near', 'Women modest metadata', 100, 'derived', 14],
    ['premier_early', 'Premier', 930, 'editorial', 20],
    ['premier_hour', 'Premier', 930, 'editorial', 60],
    ['premier_late', 'Premier', 930, 'editorial', 120],
    ['champions', 'Champions', 970, 'editorial', 40],
    ['libertadores', 'Libertadores', 950, 'editorial', 80],
    ['laliga', 'LaLiga', 920, 'editorial', 90],
    ['seriea', 'Serie A', 910, 'editorial', 100],
    ['medium', 'Medium editorial', 500, 'editorial', 30],
    ['followed', 'Followed competition', 500, 'editorial', 45],
    ['demand', 'Premier demanded', 930, 'editorial', 180],
    ['champions_6d', 'Champions six days', 970, 'editorial', 6 * 1440],
    ['near_score_6d', 'Editorial 940 six days', 940, 'editorial', 6 * 1440],
    ['women_high', 'Women editorial high', 960, 'editorial', 50],
    ['u23_high', 'U23 editorial high', 940, 'editorial', 70],
    ['derived_high', 'Untrusted derived 999', 999, 'derived', 5],
    ['provider_high', 'Provider 999', 999, 'provider', 6],
    ['unknown', 'Missing metadata', null, null, 7],
  ];
  // Names are fixture labels only; no production name/country heuristic.
  await db.exec('alter table futbeat_private.entities disable trigger user');
  try {
    for (const [key, label, score, source, minutes] of fixtures) {
      const competition = `fb_rank_comp_${key}`, team = `fb_team_rank_${key}`, match = `fb_rank_match_${key}`;
      await db.query(`insert into futbeat_private.entities values($1,'competition',$2),($3,'team',$4),($5,'match',$6)`, [
        competition, JSON.stringify({ id: competition, name: label }), team, JSON.stringify({ id: team, name: label, competitionId: competition }),
        match, JSON.stringify({ id: match, homeTeamId: team, awayTeamId: team, competitionId: competition, status: 'SCHEDULED' }),
      ]);
      await db.query("insert into futbeat_private.calendar_matches values($1,now()+$2*interval '1 minute','fixture',now())", [match, minutes]);
      await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)", [key, team]);
      if (source) await db.query("insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source) values($1,'other',$2,$3)", [competition, score, source]);
    }
  } finally { await db.exec('alter table futbeat_private.entities enable trigger user'); }
  await db.exec(`insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
    values('competition','fb_rank_comp_followed',2,'DEEP');
    insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
    values('00000000-0000-0000-0000-000000000001','team','fb_team_rank_demand',now()+interval '1 hour'); analyze;`);
}

export async function compareStrategies(db) {
  const b = await definition(db, 'futbeat_private.squad_upcoming_candidates(integer)');
  if (!b.includes(bucketExpression)) throw new Error('Bucket expression changed: review strategy comparison');
  const results = [];
  try {
    for (const [strategy, sql] of [['A', b.replace(bucketExpression, '0')], ['B', b]]) {
      await db.exec(sql);
      await ranked(db);
      const p = await explain(db, 'select * from futbeat_private.squad_upcoming_candidates()');
      const rows = await ranked(db);
      results.push({ strategy, ms: p['Execution Time'], top: rows.slice(0, 20).map(r => r.team_id), candidates: rows.length });
    }
  } finally { await db.exec(b); }
  return results;
}

async function main() {
  for (const large of [false, true]) {
    const db = await openDatabase();
    try {
      await seedRankingFixture(db, large);
      const rawUpcoming = (await db.query(`select count(*)::int n from futbeat_private.calendar_matches c
        join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
        cross join lateral(values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) t(id)
        where c.start_time between now() and now()+interval '7 days' and e.payload->>'status'='SCHEDULED' and t.id is not null`)).rows[0].n;
      console.log(JSON.stringify({ fixture: large ? '10000' : 'realistic', strategies: await compareStrategies(db) }));
      const updated = await definition(db, 'futbeat_private.futbeat_team_squad_plan(integer)');
      for (const label of ['CURRENT', 'NEW']) {
        if (label === 'CURRENT') await installPlanner(db, '20260922141448_optimize_squad_candidate_pool.sql');
        else await db.exec(updated);
        for (const limit of [1, 5, 20]) {
          await plan(db, limit);
          const ms = [];
          for (let sample = 0; sample < 3; sample++) ms.push((await explain(db, `select public.futbeat_team_squad_plan(${limit})`))['Execution Time']);
          ms.sort((a, b) => a - b);
          const traced = await tracePools(db, limit);
          console.log(JSON.stringify({ fixture: large ? '10000' : 'realistic', label, limit, ms: ms[1],
            rawUpcoming, candidateRowsInspected: traced.raw, mappings: traced.mappings, top: traced.result.map(r => r.teamId) }));
        }
      }
      const body = (await db.query("select prosrc from pg_proc where oid='futbeat_private.squad_upcoming_candidates(integer)'::regprocedure")).rows[0].prosrc;
      const p = await explain(db, body.trim().replace(/;$/, '').replaceAll('p_bucket', '0'));
      console.log(JSON.stringify({ fixture: large ? '10000' : 'realistic', rankingMs: p['Execution Time'],
        nodes: planNodes(p.Plan).filter(n => n.cte || n.subplan || n.sort || n.index) }));
    } finally { await db.close(); }
  }
}
if (process.argv[1]?.replaceAll('\\', '/').endsWith('/bench/squad_upcoming_ranking.mjs')) await main();

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { assignClusters, prepareArticle } from '../../supabase/functions/_shared/news_pipeline.ts';

// News pipeline v2 (#104), storage + feed read. Synthetic articles on the
// seeded source domains; no provider is ever called.

const HOUR = 3600e3;
const ago = (hours) => new Date(Date.now() - hours * HOUR).toISOString();
const TEAM = 'fb_team_news_uno';
const PLAYER = 'fb_player_news_mario';
const COMP = 'fb_comp_news';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('${COMP}','competition','{"id":"${COMP}","name":"Primera Ejemplo","country":"Costa Rica"}'),
      ('${TEAM}','team','{"id":"${TEAM}","name":"Club Uno","country":"Costa Rica","competitionId":"${COMP}"}'),
      ('fb_team_news_far','team','{"id":"fb_team_news_far","name":"Lejano FC","country":"Spain"}'),
      ('${PLAYER}','player','{"id":"${PLAYER}","name":"Mario Ejemplo Rojas","teamId":"${TEAM}"}')`);
    await fn(db);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where provider<>'goal_api'")).rows[0].n, 0);
  } finally { await db.close(); }
}

const v = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;
const rows = async (db, sql, params = []) => (await db.query(sql, params)).rows;

const CANDIDATES = [
  { type: 'team', id: TEAM, names: ['Club Uno'] },
  { type: 'player', id: PLAYER, names: ['Mario Ejemplo Rojas'] },
  { type: 'team', id: 'fb_team_news_far', names: ['Lejano FC'] },
];

async function policies(db, provider) {
  return v(db, 'select public.futbeat_news_policies($1) v', [provider]);
}

async function prepare(db, provider, raws) {
  const p = await policies(db, provider);
  return raws.map((raw) => prepareArticle({ provider, ...raw }, { provider: p.provider, sources: p.sources, candidates: CANDIDATES }));
}

async function store(db, provider, prepared, subject = null) {
  const recent = await v(db, 'select public.futbeat_news_recent_fingerprints(72) v');
  const clusters = assignClusters(prepared, recent);
  const articles = prepared.map((a) => ({ ...a, clusterId: clusters.get(a.id) }));
  return v(db, 'select public.futbeat_store_news_batch_v2($1,now(),$2,$3,$4) v',
    [provider, JSON.stringify(articles), subject?.type ?? null, subject?.id ?? null]);
}

async function follower(db) {
  const uid = randomUUID();
  await db.query(`insert into futbeat_private.push_devices(id,user_id,installation_id,platform,transport,token,enabled,registered_at)
    values($1,$2,$3,'android','test',$4,true,now()-interval '1 day')`, [randomUUID(), uid, randomUUID(), `tok-${uid}`]);
  await db.query('insert into futbeat_private.user_preferences(user_id,notify_news) values($1,true)', [uid]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at) values($1,'team',$2,now()-interval '1 day')", [uid, TEAM]);
  return uid;
}
const outbox = (db) => rows(db, "select notification_key,user_id from futbeat_private.notification_outbox where notification_key like 'news:%' order by notification_key");

const rumor = { externalId: 'r1', title: 'Club Uno estaría cerca de fichar a Mario Ejemplo Rojas', url: 'https://agregador.example/r1', sourceName: 'agregador.example', publishedAt: ago(5), description: 'Rumores de negociaciones.' };
const report = { externalId: 'm1', title: 'Club Uno ficha a Mario Ejemplo Rojas como refuerzo', url: 'https://www.teletica.com/deportes/club-uno-ficha-mario?utm_source=x', sourceName: 'Teletica', publishedAt: ago(4), description: 'El delantero llega al club.', imageUrl: 'https://www.teletica.com/img/m.jpg' };
const official = { externalId: 'o1', title: 'Comunicado: Club Uno ficha a Mario Ejemplo Rojas', url: 'https://saprissa.com/noticias/mario-ejemplo-rojas', sourceName: 'Club', publishedAt: ago(3), description: 'Oficial.' };

test('v1 evidence: re-storing the same article rewrites the row every time', () => withDb(async (db) => {
  const article = [{ id: 'nd-1', title: 'Club Uno gana', url: 'https://teletica.com/a', sourceName: 'Teletica', publishedAt: ago(1) }];
  const call = () => db.query("select public.futbeat_store_news_batch('team',$1,now(),'Club Uno',$2)", [TEAM, JSON.stringify(article)]);
  await call();
  const x1 = await v(db, "select xmin::text v from futbeat_private.news_articles where id='newsdata:nd-1'");
  const s1 = await v(db, "select xmin::text v from futbeat_private.news_subjects where article_id='newsdata:nd-1'");
  await call();
  assert.notEqual(await v(db, "select xmin::text v from futbeat_private.news_articles where id='newsdata:nd-1'"), x1);
  assert.notEqual(await v(db, "select xmin::text v from futbeat_private.news_subjects where article_id='newsdata:nd-1'"), s1,
    'the push-triggering row is updated again');
}));

test('v2: an identical re-store writes nothing', () => withDb(async (db) => {
  const prepared = await prepare(db, 'currents', [report]);
  const first = await store(db, 'currents', prepared);
  assert.equal(first.inserted, 1);
  const x1 = await v(db, 'select xmin::text v from futbeat_private.news_articles where id=$1', [prepared[0].id]);
  const c1 = await v(db, 'select xmin::text v from futbeat_private.news_clusters');
  const second = await store(db, 'currents', prepared);
  assert.deepEqual([second.inserted, second.updated, second.unchanged], [0, 0, 1]);
  assert.equal(await v(db, 'select xmin::text v from futbeat_private.news_articles where id=$1', [prepared[0].id]), x1);
  assert.equal(await v(db, 'select xmin::text v from futbeat_private.news_clusters'), c1);
}));

test('v2: three outlets, one story, one notification; anchor is the first verified member', () => withDb(async (db) => {
  const uid = await follower(db);
  await store(db, 'currents', await prepare(db, 'currents', [rumor]));
  // Unverified-only story: stored, never pushed nor attached to profiles.
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.news_subjects'), 0);
  assert.deepEqual(await outbox(db), []);
  await store(db, 'currents', await prepare(db, 'currents', [report]));
  await store(db, 'rss', await prepare(db, 'rss', [official]));
  const cluster = (await rows(db, 'select * from futbeat_private.news_clusters'))[0];
  assert.equal(cluster.member_count, 3);
  assert.equal(cluster.story_state, 'OFFICIAL');
  assert.equal(cluster.transfer_status, 'CONFIRMED');
  assert.equal(cluster.cluster_id, 'currents:r1');
  assert.equal(cluster.anchor_article_id, 'currents:m1');
  assert.deepEqual(await outbox(db), [{ notification_key: 'news:currents:m1', user_id: uid }]);
  assert.deepEqual((await rows(db, 'select article_id,subject_type from futbeat_private.news_subjects order by subject_type'))
    .map((r) => `${r.article_id}/${r.subject_type}`), ['currents:m1/player', 'currents:m1/team']);
}));

test('v2: rights are derived server-side; nothing is granted without review', () => withDb(async (db) => {
  const [a] = await prepare(db, 'currents', [report]);
  // A client that claims rights it does not have.
  await store(db, 'currents', [{ ...a, snippet: 'Texto completo del artículo '.repeat(40), imageUrl: 'https://www.teletica.com/img/m.jpg', transferStatus: 'CONFIRMED' }]);
  let row = (await rows(db, 'select description,image_url,transfer_status,source_role,attribution from futbeat_private.news_articles'))[0];
  assert.equal(row.description, null);
  assert.equal(row.image_url, null);
  assert.equal(row.transfer_status, 'REPORT', 'media cannot confirm a transfer');
  assert.equal(row.source_role, 'ESTABLISHED_MEDIA');
  assert.deepEqual(row.attribution, { publisher: 'Teletica', provider: 'Currents API' });
  // Rights cannot be granted without a review date.
  await assert.rejects(db.query("update futbeat_private.news_sources set snippet_allowed=true where domain='teletica.com'"));
  await db.query("update futbeat_private.news_sources set snippet_allowed=true,max_snippet_chars=40,rights_reviewed_at=now() where domain='teletica.com'");
  await db.query("update futbeat_private.news_provider_config set snippet_allowed=true,terms_reviewed_at=now() where provider='currents'");
  const [b] = await prepare(db, 'currents', [{ ...report, title: report.title + ' (actualizado)' }]);
  const result = await store(db, 'currents', [{ ...b, snippet: 'x'.repeat(200) }]);
  assert.equal(result.updated, 1);
  row = (await rows(db, 'select description from futbeat_private.news_articles'))[0];
  assert.equal(row.description.length, 40);
}));

test('v2: another provider\'s copy of the same canonical URL is not a second article', () => withDb(async (db) => {
  await store(db, 'currents', await prepare(db, 'currents', [report]));
  const copy = await prepare(db, 'rss', [{ ...report, externalId: 'feed-9', url: 'https://teletica.com/deportes/club-uno-ficha-mario/' }]);
  const result = await store(db, 'rss', copy);
  assert.equal(result.unchanged, 1);
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.news_articles'), 1);
}));

test('v2: distinct stories stay distinct; invalid rows are skipped', () => withDb(async (db) => {
  const other = { externalId: 'm2', title: 'Lejano FC vence en el clásico', url: 'https://teletica.com/x2', sourceName: 'Teletica', publishedAt: ago(2) };
  const res = await store(db, 'currents', await prepare(db, 'currents', [report, other]));
  assert.equal(res.inserted, 2);
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.news_clusters'), 2);
  const bad = await v(db, 'select public.futbeat_store_news_batch_v2($1,now(),$2) v', ['currents', JSON.stringify([
    { provider: 'currents', externalId: 'z', url: 'http://insecure.example', urlKey: 'k', title: 't', contentHash: 'h', publishedAt: ago(1) },
    { provider: 'rss', externalId: 'z2', url: 'https://teletica.com/z2', urlKey: 'k2', title: 't', contentHash: 'h', publishedAt: ago(1) },
  ])]);
  assert.equal(bad.skipped, 2);
}));

test('feed: one card per story, most trusted member shown, also-reported list, tabs', () => withDb(async (db) => {
  await store(db, 'currents', await prepare(db, 'currents', [rumor, report]));
  await store(db, 'rss', await prepare(db, 'rss', [official]));
  await store(db, 'currents', await prepare(db, 'currents', [
    { externalId: 'far1', title: 'Lejano FC vence en el clásico', url: 'https://teletica.com/far1', sourceName: 'Teletica', publishedAt: ago(1) },
  ]));
  const feed = (tab, follows = [], country = null) => v(db, 'select public.futbeat_read_news_feed($1,$2,$3) v', [tab, country, JSON.stringify(follows)]);
  const latest = await feed('latest');
  assert.equal(latest.schemaVersion, 2);
  assert.equal(latest.stories.length, 2);
  const story = latest.stories.find((s) => s.clusterId === 'currents:r1');
  assert.equal(story.sourceRole, 'FIRST_PARTY_OFFICIAL');
  assert.equal(story.url, 'https://saprissa.com/noticias/mario-ejemplo-rojas');
  assert.equal(story.storyState, 'OFFICIAL');
  assert.equal(story.transferStatus, 'CONFIRMED');
  assert.deepEqual(story.alsoReportedBy.map((m) => m.sourceRole), ['ESTABLISHED_MEDIA', 'UNVERIFIED']);
  assert.deepEqual(story.entities.map((e) => e.id).sort(), [PLAYER, TEAM].sort());
  // Latest: newest activity first; for_you: the followed team's story first.
  assert.equal(latest.stories[0].clusterId, 'currents:far1');
  const mine = await feed('for_you', [{ type: 'team', id: TEAM }]);
  assert.equal(mine.stories[0].clusterId, 'currents:r1');
  assert.equal(mine.stories.length, 2, 'follows reorder, never trap');
  assert.deepEqual((await feed('transfers')).stories.map((s) => s.clusterId), ['currents:r1']);
  assert.deepEqual((await feed('country', [], 'CR')).stories.map((s) => s.clusterId), ['currents:r1']);
  await assert.rejects(feed('everything'));
}));

test('budget: disabled by default, own ledger, daily limit and min interval', () => withDb(async (db) => {
  const reserve = () => v(db, "select public.futbeat_reserve_news_call('currents','team:x') v");
  assert.deepEqual(await reserve(), { allowed: false, reason: 'provider_disabled' });
  await db.query("update futbeat_private.news_provider_config set enabled=true,daily_limit=2,min_interval_seconds=0 where provider='currents'");
  assert.equal((await reserve()).allowed, true);
  assert.equal((await reserve()).allowed, true);
  assert.equal((await reserve()).reason, 'news_daily_limit');
  await db.query("update futbeat_private.news_provider_config set daily_limit=10,min_interval_seconds=600 where provider='currents'");
  assert.equal((await reserve()).reason, 'min_interval');
  assert.equal(await v(db, 'select count(*)::int v from futbeat_private.provider_call_ledger'), 0);
  const health = await v(db, 'select public.futbeat_news_health() v');
  assert.equal(health.providers.find((p) => p.provider === 'currents').usedToday, 2);
}));

test('feeds: disabled until reviewed; failures back off', () => withDb(async (db) => {
  assert.equal(await v(db, 'select public.futbeat_news_feed_due() v'), null);
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='rss'");
  await db.query("update futbeat_private.news_feeds set enabled=true where id='teletica-futbol'");
  const due = await v(db, 'select public.futbeat_news_feed_due() v');
  assert.equal(due.id, 'teletica-futbol');
  assert.equal(due.sourceName, 'Teletica');
  await db.query("select public.futbeat_news_feed_result('teletica-futbol',false,null,null,'HTTP_500')");
  await db.query("select public.futbeat_news_feed_result('teletica-futbol',false,null,null,'HTTP_500')");
  const row = (await rows(db, "select consecutive_failures,extract(epoch from next_fetch_at-now())/60 mins from futbeat_private.news_feeds where id='teletica-futbol'"))[0];
  assert.equal(row.consecutive_failures, 2);
  assert.ok(row.mins > 100 && row.mins <= 121);
  assert.equal(await v(db, 'select public.futbeat_news_feed_due() v'), null);
}));

test('query plan: central interests only, per provider cadence', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,priority_score,depth)
    values('team','${TEAM}',3,900,'DEEP')`);
  assert.deepEqual(await v(db, "select public.futbeat_news_query_plan('currents',5) v"), [], 'disabled provider plans nothing');
  await db.query("update futbeat_private.news_provider_config set enabled=true where provider='currents'");
  const plan = await v(db, "select public.futbeat_news_query_plan('currents',5) v");
  assert.equal(plan[0].subjectId, TEAM);
  assert.equal(plan[0].query, 'Club Uno');
  await store(db, 'currents', await prepare(db, 'currents', [report]), { type: 'team', id: TEAM });
  assert.deepEqual(await v(db, "select public.futbeat_news_query_plan('currents',5) v"), []);
}));

test('tagging dictionary: bounded, from interests and selected countries', () => withDb(async (db) => {
  await db.query("insert into futbeat_private.user_preferences(user_id,selected_country) values($1,'CR')", [randomUUID()]);
  const dict = await v(db, 'select public.futbeat_news_tagging_dictionary(100) v');
  const ids = dict.map((d) => d.id);
  assert.ok(ids.includes(TEAM) && ids.includes(COMP));
  assert.ok(!ids.includes('fb_team_news_far'));
  assert.deepEqual(dict.find((d) => d.id === TEAM).names, ['club uno']);
}));

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  assignClusters, canonicalUrl, classify, normalizeCurrents, normalizeFeed, normalizeNewsData,
  plainText, prepareArticle, sameStory, sourcePolicyFor, stableHash, storyState, tagSubjects,
  titleTokens, transferStatus,
} from '../../supabase/functions/_shared/news_pipeline.ts';

// News pipeline v2 (#104), pure layer. Synthetic fixtures; no network.

const fixture = (name) => readFile(new URL(`./fixtures/news/${name}`, import.meta.url), 'utf8');
const NOW = new Date('2026-10-19T12:00:00Z');

const SOURCES = [
  { domain: 'club-uno.example', displayName: 'Club Uno (oficial)', role: 'FIRST_PARTY_OFFICIAL', snippetAllowed: true, maxSnippetChars: 200, imageAllowed: true },
  { domain: 'federacion.example', displayName: 'Federación Ejemplo', role: 'FIRST_PARTY_OFFICIAL', snippetAllowed: false, maxSnippetChars: 0, imageAllowed: false },
  { domain: 'medio-deportivo.example', displayName: 'Medio Deportivo', role: 'ESTABLISHED_MEDIA', snippetAllowed: true, maxSnippetChars: 160, imageAllowed: false },
  { domain: 'agregador.example', displayName: 'Agregador', role: 'AGGREGATOR', snippetAllowed: false, maxSnippetChars: 0, imageAllowed: false },
];
const PROVIDERS = {
  currents: { provider: 'currents', snippetAllowed: true, imageAllowed: false, attribution: 'Currents API' },
  newsdata: { provider: 'newsdata', snippetAllowed: false, imageAllowed: false, attribution: null },
  rss: { provider: 'rss', snippetAllowed: true, imageAllowed: true, attribution: null },
};
const CANDIDATES = [
  { type: 'team', id: 'fb_team_uno', names: ['Club Uno', 'C. Uno'] },
  { type: 'player', id: 'fb_player_mario', names: ['Mario Ejemplo Rojas', 'Mario Ejemplo'] },
  { type: 'player', id: 'fb_player_pedro', names: ['Pedro Ejemplo Solís'] },
  { type: 'player', id: 'fb_player_x', names: ['Rojas'] },
];
const prepare = (raw, provider) => prepareArticle(raw, { provider: PROVIDERS[provider], sources: SOURCES, candidates: CANDIDATES, now: NOW });

test('canonical URL: tracking, www, amp, fragment, trailing slash and param order', () => {
  assert.equal(canonicalUrl('https://www.Medio.example/a/b/?utm_source=x&b=2&a=1#top'), 'https://medio.example/a/b?a=1&b=2');
  assert.equal(canonicalUrl('https://amp.medio.example/a/b/amp/'), 'https://medio.example/a/b');
  assert.equal(canonicalUrl('https://medio.example/a?fbclid=1&gclid=2'), 'https://medio.example/a');
  assert.equal(canonicalUrl('http://medio.example/a'), null);
  assert.equal(canonicalUrl('https://user:pw@medio.example/a'), null);
  assert.equal(canonicalUrl('not a url'), null);
});

test('source policy: most specific parent domain wins; unknown is null', () => {
  assert.equal(sourcePolicyFor('news.club-uno.example', SOURCES).role, 'FIRST_PARTY_OFFICIAL');
  assert.equal(sourcePolicyFor('club-uno.example.evil.test', SOURCES), null);
  assert.equal(sourcePolicyFor('otro.example', SOURCES), null);
});

test('adapters: Currents, NewsData, RSS and Atom normalize to one contract', async () => {
  const currents = normalizeCurrents(JSON.parse(await fixture('currents_search.json')));
  assert.deepEqual(currents.map((a) => a.externalId), ['cur-001', 'cur-002']);
  assert.equal(currents[0].sourceName, 'medio-deportivo.example');
  assert.equal(currents[0].publishedAt, '2026-10-18T14:05:00.000Z');
  assert.equal(currents[1].imageUrl, '');
  const newsdata = normalizeNewsData(JSON.parse(await fixture('newsdata_latest.json')));
  assert.deepEqual(newsdata.map((a) => a.externalId), ['nd-001']);
  assert.equal(newsdata[0].publishedAt, '2026-10-18T14:06:00.000Z');
  const rss = normalizeFeed(await fixture('publisher_rss.xml'), { sourceName: 'Club Uno', sourceUrl: 'https://club-uno.example' });
  assert.equal(rss.length, 2);
  assert.equal(rss[0].title, 'Comunicado: Club Uno ficha a Mario Ejemplo Rojas');
  assert.equal(rss[0].description, 'El club oficializa la incorporación del delantero Mario Ejemplo Rojas & su presentación.');
  assert.equal(rss[0].imageUrl, 'https://club-uno.example/img/mario.jpg');
  assert.equal(rss[1].publishedAt, '2026-10-18T02:30:00.000Z');
  const atom = normalizeFeed(await fixture('publisher_atom.xml'), { sourceName: 'Federación Ejemplo' });
  assert.equal(atom[0].url, 'https://federacion.example/noticias/convocatoria-octubre');
  assert.equal(atom[0].publishedAt, '2026-10-16T18:00:00.000Z');
});

test('plain text strips markup and never keeps script content as markup', () => {
  assert.equal(plainText('<p>Hola <script>x</script> <b>mundo</b> &iquest;s&iacute;?</p>'), 'Hola x mundo ¿sí?');
});

test('rights: snippet/image only when provider AND publisher allow; capped', async () => {
  const [cur] = normalizeCurrents(JSON.parse(await fixture('currents_search.json')));
  const a = prepare(cur, 'currents');
  assert.ok(a.snippet && a.snippet.length <= 160);
  assert.equal(a.imageUrl, null, 'publisher does not allow images');
  assert.deepEqual(a.attribution, { publisher: 'Medio Deportivo', provider: 'Currents API' });
  const [nd] = normalizeNewsData(JSON.parse(await fixture('newsdata_latest.json')));
  assert.equal(prepare(nd, 'newsdata').snippet, null, 'provider terms not cleared');
  const unknown = prepare({ ...cur, url: 'https://desconocido.example/x' }, 'currents');
  assert.equal(unknown.sourceRole, 'UNVERIFIED');
  assert.equal(unknown.snippet, null);
  assert.equal(unknown.imageUrl, null);
  const [official] = normalizeFeed(await fixture('publisher_rss.xml'), { sourceName: 'Club Uno' });
  const o = prepare(official, 'rss');
  assert.equal(o.imageUrl, 'https://club-uno.example/img/mario.jpg');
  assert.equal(o.sourceName, 'Club Uno (oficial)');
});

test('prepare: publisher suffix stripped, stale/future/insecure rows rejected', async () => {
  const [nd] = normalizeNewsData(JSON.parse(await fixture('newsdata_latest.json')));
  assert.equal(prepare(nd, 'newsdata').title, 'Club Uno ficha a Mario Ejemplo Rojas como refuerzo para el Apertura');
  assert.equal(prepare({ ...nd, publishedAt: '2026-08-01T00:00:00Z' }, 'newsdata'), null);
  assert.equal(prepare({ ...nd, publishedAt: '2026-10-22T00:00:00Z' }, 'newsdata'), null);
  assert.equal(prepare({ ...nd, url: 'http://medio-deportivo.example/x' }, 'newsdata'), null);
});

test('content hash is stable and changes only with visible content', async () => {
  const [cur] = normalizeCurrents(JSON.parse(await fixture('currents_search.json')));
  const a = prepare(cur, 'currents');
  assert.equal(prepare(cur, 'currents').contentHash, a.contentHash);
  assert.notEqual(prepare({ ...cur, title: cur.title + ' (actualizado)' }, 'currents').contentHash, a.contentHash);
  assert.equal(stableHash('abc'), stableHash('abc'));
  assert.equal(stableHash('abc').length, 16);
});

test('classification and transfer state: repetition never confirms', () => {
  assert.equal(classify('Club Uno ficha a un delantero'), 'TRANSFER');
  assert.equal(classify('Parte médico: lesión del capitán'), 'INJURY');
  assert.equal(classify('Club Uno vence a Club Dos'), 'MATCH');
  assert.equal(classify('Convocatoria para la fecha FIFA'), 'SQUAD');
  assert.equal(classify('El entrenador habló tras el partido'), 'GENERAL');
  assert.equal(classify('Club Uno anuncia nuevo entrenador'), 'COACHING');
  assert.equal(transferStatus('TRANSFER', 'FIRST_PARTY_OFFICIAL', 'Club Uno ficha a X'), 'CONFIRMED');
  assert.equal(transferStatus('TRANSFER', 'FIRST_PARTY_OFFICIAL', 'Club Uno negocia con X'), 'RUMOR');
  assert.equal(transferStatus('TRANSFER', 'ESTABLISHED_MEDIA', 'Club Uno ficha a X'), 'REPORT');
  assert.equal(transferStatus('TRANSFER', 'AGGREGATOR', 'Club Uno ficha a X'), 'RUMOR');
  assert.equal(transferStatus('MATCH', 'ESTABLISHED_MEDIA', 'x'), null);
  const many = Array.from({ length: 5 }, () => ({ sourceRole: 'AGGREGATOR', transferStatus: 'RUMOR' }));
  assert.deepEqual(storyState(many), { state: 'DEVELOPING', transferStatus: 'RUMOR' });
  assert.deepEqual(storyState([...many, { sourceRole: 'ESTABLISHED_MEDIA', transferStatus: 'REPORT' }]),
    { state: 'REPORT', transferStatus: 'REPORT' });
  assert.deepEqual(storyState([...many, { sourceRole: 'FIRST_PARTY_OFFICIAL', transferStatus: 'CONFIRMED' }]),
    { state: 'OFFICIAL', transferStatus: 'CONFIRMED' });
});

test('tagging: explicit mention only; surnames alone and shared names never tag', () => {
  const tags = tagSubjects('Club Uno ficha a Mario Ejemplo Rojas', '', CANDIDATES);
  assert.deepEqual(tags, [{ type: 'player', id: 'fb_player_mario' }, { type: 'team', id: 'fb_team_uno' }]);
  assert.deepEqual(tagSubjects('Rojas marca dos goles', '', CANDIDATES), [], 'single surname');
  const homonyms = [...CANDIDATES, { type: 'player', id: 'fb_player_mario_2', names: ['Mario Ejemplo Rojas'] }];
  assert.deepEqual(tagSubjects('Mario Ejemplo Rojas renueva', '', homonyms), [], 'ambiguous name tags nobody');
  assert.deepEqual(tagSubjects('Club Unolandia campeón', '', CANDIDATES), [], 'whole words only');
  assert.deepEqual(tagSubjects('CLUB UNO, líder', '', CANDIDATES), [{ type: 'team', id: 'fb_team_uno' }]);
});

test('clustering: same URL, similar headline, entity+category; distinct signings stay apart', async () => {
  const [cur1, cur2] = normalizeCurrents(JSON.parse(await fixture('currents_search.json')));
  const [nd] = normalizeNewsData(JSON.parse(await fixture('newsdata_latest.json')));
  const [official, injury] = normalizeFeed(await fixture('publisher_rss.xml'), { sourceName: 'Club Uno' });
  const batch = [prepare(cur1, 'currents'), prepare(cur2, 'currents'), prepare(nd, 'newsdata'), prepare(official, 'rss'), prepare(injury, 'rss')];
  const clusters = assignClusters(batch, []);
  // cur-002 (rumor, earliest) starts the story; the report, the NewsData copy
  // (same canonical URL) and the official confirmation join it.
  assert.equal(clusters.get('currents:cur-002'), 'currents:cur-002');
  assert.equal(clusters.get('currents:cur-001'), 'currents:cur-002');
  assert.equal(clusters.get('newsdata:nd-001'), 'currents:cur-002');
  assert.equal(clusters.get('rss:club-uno-1001'), 'currents:cur-002');
  assert.equal(clusters.get('rss:club-uno-1002'), 'rss:club-uno-1002');

  const other = prepare({ ...cur1, externalId: 'cur-777', url: 'https://medio-deportivo.example/otro',
    title: 'Club Uno ficha a Pedro Ejemplo Solís como refuerzo para el Apertura', description: '' }, 'currents');
  assert.equal(sameStory(batch[0], other), null, 'two signings of one club are two stories');
  // Same, with players unknown to FutBeat (no player tags): the proper
  // names in the headlines still keep the stories apart.
  const untagged = (title, id) => prepareArticle({ ...cur1, externalId: id, url: `https://medio-deportivo.example/${id}`, title, description: '' },
    { provider: PROVIDERS.currents, sources: SOURCES, candidates: [], now: NOW });
  assert.equal(sameStory(untagged('Club Uno ficha a Luis Nuevo como refuerzo para el Apertura', 'u1'),
    untagged('Club Uno ficha a Juan Otro como refuerzo para el Apertura', 'u2')), null);
  assert.equal(sameStory(untagged('Club Uno ficha a Luis Nuevo como refuerzo para el Apertura', 'u1'),
    untagged('Club Uno ficha a Luis Nuevo como refuerzo del Apertura', 'u3')), 'headline');
});

test('clustering: stored clusters are kept and the window is 48 h', async () => {
  const [cur1] = normalizeCurrents(JSON.parse(await fixture('currents_search.json')));
  const a = prepare(cur1, 'currents');
  const stored = [{ id: 'old:1', clusterId: 'old:root', urlKey: 'zzz', titleTokens: a.titleTokens, category: 'TRANSFER', subjects: a.subjects, publishedAt: '2026-10-17T15:00:00.000Z' }];
  assert.equal(assignClusters([a], stored).get(a.id), 'old:root');
  const late = { ...stored[0], publishedAt: '2026-10-15T00:00:00.000Z' };
  assert.equal(assignClusters([a], [late]).get(a.id), a.id);
  // Re-reading an already stored article keeps its stored cluster.
  assert.equal(assignClusters([a], [{ ...stored[0], id: a.id, clusterId: 'kept' }]).get(a.id), 'kept');
});

test('title tokens drop stopwords, accents and the publisher suffix', () => {
  assert.deepEqual(titleTokens('Club Uno vence a la Selección - Medio Deportivo', 'Medio Deportivo'),
    ['club', 'seleccion', 'uno', 'vence']);
});

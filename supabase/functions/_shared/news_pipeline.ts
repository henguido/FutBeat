// News pipeline v2 (#104): provider-agnostic, deterministic, rights-aware.
//
// Providers (NewsData, Currents, publisher RSS/Atom) normalize into ONE
// article contract; the collector then applies the source/provider rights
// policy, classifies, tags canonical entities by explicit mention, and
// assigns a story cluster. Pure functions only: no network, no clock unless
// passed, no randomness. Shared by the Deno collector and Node tests.
//
// Never stored or returned: full article bodies, scraped text, images or
// snippets whose rights are not explicitly allowed. Names are used here
// only to TAG an article with an entity it mentions, never to merge
// entities.

export type SourceRole =
  | "FIRST_PARTY_OFFICIAL"
  | "ESTABLISHED_MEDIA"
  | "AGGREGATOR"
  | "UNVERIFIED";

export type NewsCategory =
  | "TRANSFER"
  | "INJURY"
  | "DISCIPLINE"
  | "COACHING"
  | "SQUAD"
  | "MATCH"
  | "GENERAL";

export type TransferStatus = "RUMOR" | "REPORT" | "CONFIRMED";

/** One provider row after normalization (before policy). */
export interface RawArticle {
  provider: string;
  externalId: string;
  title: string;
  url: string;
  sourceName: string;
  sourceUrl?: string;
  publishedAt: string;
  language?: string;
  description?: string;
  imageUrl?: string;
}

/** Rights and trust of a publisher domain (futbeat_private.news_sources). */
export interface SourcePolicy {
  domain: string;
  displayName: string;
  role: SourceRole;
  snippetAllowed: boolean;
  maxSnippetChars: number;
  imageAllowed: boolean;
}

/** Terms of the provider that delivered the row (news_provider_config). */
export interface ProviderPolicy {
  provider: string;
  snippetAllowed: boolean;
  imageAllowed: boolean;
  attribution?: string | null;
}

export interface TagCandidate {
  type: "team" | "player" | "competition";
  id: string;
  names: string[];
}

export interface TaggedSubject {
  type: TagCandidate["type"];
  id: string;
}

export interface PreparedArticle {
  id: string;
  provider: string;
  externalId: string;
  title: string;
  url: string;
  urlKey: string;
  sourceName: string;
  sourceDomain: string;
  sourceRole: SourceRole;
  publishedAt: string;
  language: string | null;
  snippet: string | null;
  imageUrl: string | null;
  attribution: { publisher: string; provider: string | null };
  category: NewsCategory;
  transferStatus: TransferStatus | null;
  titleTokens: string[];
  nameTokens: string[];
  subjects: TaggedSubject[];
  contentHash: string;
}

/** Rows read back to cluster new articles against (recent window). */
export interface ClusterCandidate {
  id: string;
  clusterId: string;
  urlKey: string | null;
  titleTokens: string[];
  nameTokens?: string[];
  category: NewsCategory | string;
  subjects: TaggedSubject[];
  publishedAt: string;
}

export const NEWS_CONTRACT_VERSION = 2;
export const CLUSTER_WINDOW_HOURS = 48;
const MAX_TITLE = 300;
const HARD_SNIPPET_CAP = 300;

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

export function clean(value: unknown): string {
  return typeof value === "string" || typeof value === "number"
    ? String(value).replace(/\s+/g, " ").trim()
    : "";
}

const ENTITIES: Record<string, string> = {
  "&amp;": "&",
  "&quot;": '"',
  "&#39;": "'",
  "&apos;": "'",
  "&lt;": "<",
  "&gt;": ">",
  "&nbsp;": " ",
};

/** Plain text: CDATA unwrapped, tags removed, common entities decoded. */
export function plainText(value: unknown): string {
  const text = clean(value)
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]*>/g, " ")
    .replace(/&([aeiouAEIOU])(acute|grave|uml);/g, (_, v, mark) =>
      (v + { acute: "́", grave: "̀", uml: "̈" }[mark as "acute"]).normalize("NFC"))
    .replace(/&([nN])tilde;/g, (_, n) => (n === "n" ? "ñ" : "Ñ"))
    .replace(/&(iexcl|iquest|laquo|raquo|ndash|mdash|hellip);/g, (_, n) =>
      ({ iexcl: "¡", iquest: "¿", laquo: "«", raquo: "»", ndash: "–", mdash: "—", hellip: "…" })[
        n as "iexcl"
      ])
    .replace(/&(amp|quot|#39|apos|lt|gt|nbsp);/g, (m) => ENTITIES[m] ?? m)
    .replace(/&#x([0-9a-f]{1,5});/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&#(\d{1,5});/g, (_, n) => String.fromCodePoint(Number(n)));
  return clean(text);
}

/** Lowercase, accents removed, punctuation as spaces. */
export function fold(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9ñ]+/g, " ")
    .trim();
}

const STOPWORDS = new Set(
  (
    "a al ante bajo con contra de del desde el en entre hacia hasta la las lo los para por segun sin " +
    "so sobre tras un una unos unas y o u e que se su sus es son fue ser como mas pero ya le les " +
    "the of and or to in on at for with by from is are was be as an it its this that into after over " +
    "vs v"
  ).split(" "),
);

/** Title without a trailing " - Publisher" / " | Publisher" suffix. */
export function stripPublisherSuffix(title: string, sourceName: string): string {
  const source = fold(sourceName);
  if (!source) return title;
  const match = title.match(/^(.*\S)\s+[-|–—:]\s+([^-|–—:]+)$/);
  if (match && fold(match[2]) === source) return match[1];
  return title;
}

/** Sorted distinct significant tokens of a headline. */
export function titleTokens(title: string, sourceName = ""): string[] {
  const tokens = fold(stripPublisherSuffix(title, sourceName))
    .split(" ")
    .filter((t) => t.length > 1 && !STOPWORDS.has(t));
  return [...new Set(tokens)].sort();
}

/**
 * Folded tokens of capitalized words that are not the headline's first
 * word: the proper names a headline is about ("Mario", "Rojas", "Uno").
 */
export function nameTokens(title: string, sourceName = ""): string[] {
  const words = stripPublisherSuffix(title, sourceName).split(/\s+/).slice(1);
  const out = new Set<string>();
  for (const word of words) {
    const bare = word.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, "");
    if (!/^\p{Lu}/u.test(bare) || bare === bare.toUpperCase() && bare.length > 4) continue;
    for (const token of fold(bare).split(" ")) {
      if (token.length > 1 && !STOPWORDS.has(token)) out.add(token);
    }
  }
  return [...out].sort();
}

// FNV-1a 64-bit: deterministic, synchronous, same in Deno and Node.
export function stableHash(value: string): string {
  let hash = 0xcbf29ce484222325n;
  const bytes = new TextEncoder().encode(value);
  for (const byte of bytes) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

const TRACKING = /^(utm_.*|fbclid|gclid|dclid|mc_cid|mc_eid|igshid|ref|ref_src|cmpid|ocid|amp|output|outputtype)$/i;

/**
 * Canonical https URL used as the article's identity across providers:
 * host lowercased without "www.", tracking parameters and fragment removed,
 * remaining parameters sorted, "/amp" suffix and trailing slash removed.
 * null for non-https or malformed URLs.
 */
export function canonicalUrl(value: unknown): string | null {
  const raw = clean(value);
  if (!raw.startsWith("https://")) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.username || url.password) return null;
  const host = url.hostname.toLowerCase().replace(/^www\./, "").replace(/^amp\./, "");
  let path = url.pathname.replace(/\/amp\/?$/i, "/").replace(/\/+$/, "");
  if (!path) path = "";
  const params = [...url.searchParams.entries()]
    .filter(([key]) => !TRACKING.test(key))
    .sort(([a, av], [b, bv]) => (a === b ? av.localeCompare(bv) : a.localeCompare(b)));
  const query = params.length
    ? "?" + params.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&")
    : "";
  return `https://${host}${path}${query}`;
}

export function domainOf(value: unknown): string {
  const url = canonicalUrl(value);
  return url ? new URL(url).hostname : "";
}

/** The most specific policy whose domain equals or is a parent of host. */
export function sourcePolicyFor(
  host: string,
  policies: SourcePolicy[],
): SourcePolicy | null {
  let best: SourcePolicy | null = null;
  for (const policy of policies) {
    const domain = policy.domain.toLowerCase();
    if (host === domain || host.endsWith("." + domain)) {
      if (!best || domain.length > best.domain.length) best = policy;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Provider adapters (shape only; no rights decision here)
// ---------------------------------------------------------------------------

function isoTime(value: unknown, assumeUtc = false): string {
  const raw = clean(value);
  if (!raw) return "";
  const normalized = assumeUtc && !/[zZ]|[+-]\d\d:?\d\d$/.test(raw)
    ? raw.replace(" ", "T") + "Z"
    : raw.replace(/^(\d{4}-\d\d-\d\d) /, "$1T")
      .replace(/^(\d{4}-\d\d-\d\dT[\d:.]+)\s*([+-]\d\d):?(\d\d)$/, "$1$2:$3");
  const parsed = new Date(normalized);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : "";
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

/** NewsData.io /latest. Same acceptance as the v1 collector. */
export function normalizeNewsData(payload: unknown): RawArticle[] {
  const rows = record(payload).results;
  const out: RawArticle[] = [];
  for (const raw of Array.isArray(rows) ? rows : []) {
    const row = record(raw);
    if (row.duplicate === true) continue;
    out.push({
      provider: "newsdata",
      externalId: clean(row.article_id),
      title: plainText(row.title),
      url: clean(row.link),
      sourceName: clean(row.source_name ?? row.source_id),
      sourceUrl: clean(row.source_url),
      publishedAt: isoTime(row.pubDate, clean(row.pubDateTZ).toUpperCase() === "UTC"),
      language: clean(row.language),
      description: plainText(row.description),
      imageUrl: clean(row.image_url),
    });
  }
  return out.filter(validRaw);
}

/** Currents API /v1/search or /v1/latest-news. */
export function normalizeCurrents(payload: unknown): RawArticle[] {
  const rows = record(payload).news;
  const out: RawArticle[] = [];
  for (const raw of Array.isArray(rows) ? rows : []) {
    const row = record(raw);
    const url = clean(row.url);
    out.push({
      provider: "currents",
      externalId: clean(row.id),
      title: plainText(row.title),
      url,
      // Currents gives no publisher name: the publisher is the domain.
      sourceName: domainOf(url),
      publishedAt: isoTime(row.published, false),
      language: clean(row.language),
      description: plainText(row.description),
      imageUrl: clean(row.image) === "None" ? "" : clean(row.image),
    });
  }
  return out.filter(validRaw);
}

function tag(xml: string, name: string): string {
  const escaped = name.replace(":", "\\:");
  const match = xml.match(new RegExp(`<${escaped}(?:\\s[^>]*)?>([\\s\\S]*?)</${escaped}>`, "i"));
  return match ? match[1] : "";
}

function attr(xml: string, name: string, attribute: string): string {
  const escaped = name.replace(":", "\\:");
  const match = xml.match(new RegExp(`<${escaped}\\s[^>]*${attribute}\\s*=\\s*"([^"]*)"`, "i"));
  return match ? match[1] : "";
}

/**
 * RSS 2.0 / Atom feed of ONE publisher. The publisher is the feed's source
 * (passed in), never inferred from the items. At most 50 items.
 */
export function normalizeFeed(
  xml: string,
  feed: { provider?: string; sourceName: string; sourceUrl?: string },
): RawArticle[] {
  const declaredLanguage = plainText(tag(xml, "language")) || attr(xml, "feed", "xml:lang");
  const validLanguage = (value: string) => /^[a-z]{2}(?:-[a-z]{2})?$/i.test(value)
    ? value.toLowerCase()
    : "";
  const items = [
    ...xml.matchAll(/<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi),
    ...xml.matchAll(/<entry(?:\s[^>]*)?>([\s\S]*?)<\/entry>/gi),
  ].slice(0, 50);
  const out: RawArticle[] = [];
  for (const [whole, body] of items) {
    const link = plainText(tag(body, "link")) || attr(body, "link", "href");
    const guid = plainText(tag(body, "guid")) || plainText(tag(body, "id"));
    out.push({
      provider: feed.provider ?? "rss",
      externalId: guid || link,
      title: plainText(tag(body, "title")),
      url: link,
      sourceName: feed.sourceName,
      sourceUrl: feed.sourceUrl,
      // Publisher location is not language. Use only a declared item/feed
      // language; leave it unknown if the XML provides no trustworthy tag.
      language: validLanguage(
        attr(whole, "item", "xml:lang") || attr(whole, "entry", "xml:lang") ||
          plainText(tag(body, "dc:language")) || declaredLanguage,
      ),
      publishedAt: isoTime(
        plainText(tag(body, "pubDate")) || plainText(tag(body, "published")) ||
          plainText(tag(body, "updated")) || plainText(tag(body, "dc:date")),
      ),
      description: plainText(tag(body, "description")) || plainText(tag(body, "summary")),
      imageUrl: attr(body, "media:content", "url") || attr(body, "enclosure", "url"),
    });
  }
  return out.filter(validRaw);
}

function validRaw(a: RawArticle): boolean {
  return Boolean(
    a.externalId && a.title && a.sourceName && a.publishedAt && canonicalUrl(a.url),
  );
}

// ---------------------------------------------------------------------------
// Classification (deterministic lexicon, Spanish + English)
// ---------------------------------------------------------------------------

const LEXICON: Array<[NewsCategory, string[]]> = [
  ["TRANSFER", [
    "fichaje", "ficha a", "ficho a", "fichar", "refuerzo", "refuerza", "traspaso", "transferencia",
    "cedido", "cesion", "prestamo", "nuevo jugador", "llega a", "se une a", "deja el club",
    "rescinde", "signs", "signed", "signing", "loan", "transfer", "joins",
  ]],
  ["INJURY", [
    "lesion", "lesionado", "lesiona", "se lesiono", "rotura", "desgarro", "desgarre", "esguince",
    "molestia muscular", "parte medico", "injury", "injured", "ruled out",
  ]],
  ["DISCIPLINE", [
    "sancion", "sancionado", "suspendido", "suspension", "tribunal disciplinario", "castigo",
    "multa", "banned", "suspended", "ban",
  ]],
  ["COACHING", [
    "destituido", "destitucion", "despedido", "cesado", "nuevo entrenador", "nuevo tecnico",
    "nuevo dt", "renuncia del", "presenta a su entrenador", "sacked", "appointed", "new coach",
    "new manager",
  ]],
  ["SQUAD", [
    "convocatoria", "convocados", "convoca", "convocado", "nomina", "lista de convocados",
    "call up", "called up", "squad list",
  ]],
  ["MATCH", [
    "previa", "cronica", "resultado", "vence a", "gana a", "golea", "empata", "empate",
    "derrota", "pierde ante", "remontada", "clasifica", "eliminado", "match report", "beat",
    "defeat", "draw with", "preview", "highlights",
  ]],
];

const RUMOR = [
  "rumor", "rumores", "interesa", "interes en", "suena", "podria", "negocia", "negociaciones",
  "en la mira", "pretende", "sondea", "seria", "estaria", "cerca de", "linked", "could",
  "talks", "eyeing", "target", "reportedly", "close to",
];

function hasPhrase(folded: string, phrase: string): boolean {
  return (" " + folded + " ").includes(" " + phrase + " ");
}

export function classify(title: string, description = ""): NewsCategory {
  const text = fold(`${title} ${description}`);
  for (const [category, words] of LEXICON) {
    if (words.some((w) => hasPhrase(text, w))) return category;
  }
  return "GENERAL";
}

/**
 * Transfer state of ONE article. CONFIRMED only from a first-party official
 * source wording it as done; how many outlets repeat a report never matters.
 */
export function transferStatus(
  category: NewsCategory,
  role: SourceRole,
  title: string,
  description = "",
): TransferStatus | null {
  if (category !== "TRANSFER") return null;
  const text = fold(`${title} ${description}`);
  if (RUMOR.some((w) => hasPhrase(text, w))) return "RUMOR";
  if (role === "FIRST_PARTY_OFFICIAL") return "CONFIRMED";
  if (role === "ESTABLISHED_MEDIA") return "REPORT";
  return "RUMOR";
}

// ---------------------------------------------------------------------------
// Entity tagging (explicit mention only)
// ---------------------------------------------------------------------------

/**
 * Entities explicitly named in the headline or the provider description.
 * Players need a name of 2+ words (a surname alone is ambiguous); teams and
 * competitions need 3+ characters. A name shared by two candidates of the
 * same type is ambiguous and tags neither.
 */
export function tagSubjects(
  title: string,
  description: string,
  candidates: TagCandidate[],
): TaggedSubject[] {
  const text = fold(`${title} ${description}`);
  const owners = new Map<string, Set<string>>();
  for (const c of candidates) {
    for (const name of c.names) {
      const key = `${c.type}:${fold(name)}`;
      if (!owners.has(key)) owners.set(key, new Set());
      owners.get(key)!.add(c.id);
    }
  }
  // Mentions that name two candidates: neither is tagged, not even through
  // a shorter alias contained in that mention.
  const ambiguous = [...owners.entries()]
    .filter(([key, ids]) => ids.size > 1 && hasPhrase(text, key.slice(key.indexOf(":") + 1)))
    .map(([key]) => key.slice(key.indexOf(":") + 1));
  const found = new Map<string, TaggedSubject>();
  for (const c of candidates) {
    for (const name of c.names) {
      const folded = fold(name);
      const words = folded.split(" ").filter(Boolean).length;
      if (c.type === "player" ? words < 2 : folded.length < 3) continue;
      if ((owners.get(`${c.type}:${folded}`)?.size ?? 0) > 1) continue;
      if (ambiguous.some((mention) => hasPhrase(mention, folded))) continue;
      if (hasPhrase(text, folded)) found.set(`${c.type}:${c.id}`, { type: c.type, id: c.id });
    }
  }
  return [...found.values()].sort((a, b) =>
    a.type === b.type ? a.id.localeCompare(b.id) : a.type.localeCompare(b.type)
  );
}

// ---------------------------------------------------------------------------
// Policy + preparation
// ---------------------------------------------------------------------------

const DEFAULT_SOURCE: Omit<SourcePolicy, "domain" | "displayName"> = {
  // Unknown publisher: link-out only, never confirmed by itself.
  role: "UNVERIFIED",
  snippetAllowed: false,
  maxSnippetChars: 0,
  imageAllowed: false,
};

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  const cut = text.slice(0, max);
  const space = cut.lastIndexOf(" ");
  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s.,;:]+$/, "") + "…";
}

/**
 * Applies rights and trust to one normalized row. Snippets and images are
 * kept only when BOTH the provider terms and the publisher policy allow
 * them; the snippet is capped at the stricter limit (and 300 characters).
 */
export function prepareArticle(
  raw: RawArticle,
  ctx: {
    provider: ProviderPolicy;
    sources: SourcePolicy[];
    candidates?: TagCandidate[];
    now?: Date;
  },
): PreparedArticle | null {
  const url = canonicalUrl(raw.url);
  const published = new Date(raw.publishedAt);
  if (!url || !Number.isFinite(published.getTime())) return null;
  const now = ctx.now ?? new Date();
  if (published.getTime() > now.getTime() + 86400e3) return null;
  if (published.getTime() < now.getTime() - 35 * 86400e3) return null;
  const host = new URL(url).hostname;
  const source = sourcePolicyFor(host, ctx.sources);
  const policy = source ?? { domain: host, displayName: raw.sourceName, ...DEFAULT_SOURCE };
  const title = truncate(stripPublisherSuffix(plainText(raw.title), raw.sourceName), MAX_TITLE);
  if (!title) return null;
  const description = plainText(raw.description ?? "");
  const snippetCap = Math.min(policy.maxSnippetChars, HARD_SNIPPET_CAP);
  const snippet = ctx.provider.snippetAllowed && policy.snippetAllowed && snippetCap > 0 && description
    ? truncate(description, snippetCap)
    : null;
  const image = canonicalUrl(raw.imageUrl);
  const imageUrl = ctx.provider.imageAllowed && policy.imageAllowed && image ? image : null;
  const category = classify(title, description);
  const subjects = tagSubjects(title, description, ctx.candidates ?? []);
  const publisher = source?.displayName || raw.sourceName;
  const prepared = {
    provider: raw.provider,
    externalId: raw.externalId.slice(0, 200),
    title,
    url,
    urlKey: stableHash(url),
    sourceName: publisher.slice(0, 300),
    sourceDomain: host,
    sourceRole: policy.role,
    publishedAt: published.toISOString(),
    language: clean(raw.language).slice(0, 40) || null,
    snippet,
    imageUrl,
    attribution: { publisher: publisher.slice(0, 300), provider: ctx.provider.attribution ?? null },
    category,
    transferStatus: transferStatus(category, policy.role, title, description),
    titleTokens: titleTokens(title, raw.sourceName),
    nameTokens: nameTokens(title, raw.sourceName),
    subjects,
  };
  // What a reader sees; an unchanged hash means no write.
  const contentHash = stableHash(JSON.stringify([
    prepared.title, prepared.url, prepared.sourceName, prepared.publishedAt, prepared.snippet,
    prepared.imageUrl, prepared.category, prepared.transferStatus, prepared.sourceRole,
    prepared.attribution, prepared.subjects,
  ]));
  return {
    ...prepared,
    id: `${raw.provider}:${prepared.externalId}`,
    contentHash,
  };
}

// ---------------------------------------------------------------------------
// Story clustering
// ---------------------------------------------------------------------------

export function jaccard(a: string[], b: string[]): number {
  if (!a.length || !b.length) return 0;
  const left = new Set(a);
  let common = 0;
  for (const token of new Set(b)) if (left.has(token)) common++;
  return common / (left.size + new Set(b).size - common);
}

function subjectKeys(subjects: TaggedSubject[], type?: string): Set<string> {
  return new Set(
    subjects.filter((s) => !type || s.type === type).map((s) => `${s.type}:${s.id}`),
  );
}

function intersects(a: Set<string>, b: Set<string>): boolean {
  for (const x of a) if (b.has(x)) return true;
  return false;
}

/**
 * Why two articles are the same story, or null. Deterministic:
 *  - same canonical URL;
 *  - headline similarity >= 0.6;
 *  - similarity >= 0.4, same non-GENERAL category and a shared entity.
 * Only within 48 h; never when each headline names someone the other does
 * not, nor when both are tagged with players and share none (two signings
 * of one club are two stories).
 */
export function sameStory(
  a: Pick<ClusterCandidate, "urlKey" | "titleTokens" | "nameTokens" | "category" | "subjects" | "publishedAt">,
  b: Pick<ClusterCandidate, "urlKey" | "titleTokens" | "nameTokens" | "category" | "subjects" | "publishedAt">,
): "same_url" | "headline" | "entity_headline" | null {
  if (a.urlKey && a.urlKey === b.urlKey) return "same_url";
  const gap = Math.abs(Date.parse(a.publishedAt) - Date.parse(b.publishedAt));
  if (!(gap <= CLUSTER_WINDOW_HOURS * 3600e3)) return null;
  // Each headline names someone the other does not: two stories.
  const aNames = (a.nameTokens ?? []).filter((t) => !b.titleTokens.includes(t));
  const bNames = (b.nameTokens ?? []).filter((t) => !a.titleTokens.includes(t));
  if (aNames.length && bNames.length) return null;
  const aPlayers = subjectKeys(a.subjects, "player");
  const bPlayers = subjectKeys(b.subjects, "player");
  if (aPlayers.size && bPlayers.size && !intersects(aPlayers, bPlayers)) return null;
  const similarity = jaccard(a.titleTokens, b.titleTokens);
  if (similarity >= 0.6) return "headline";
  if (
    similarity >= 0.4 && a.category === b.category && a.category !== "GENERAL" &&
    intersects(subjectKeys(a.subjects), subjectKeys(b.subjects))
  ) return "entity_headline";
  return null;
}

/**
 * Cluster ids for a batch, given the recent stored articles. An article
 * joins the cluster of its earliest matching article (stored or earlier in
 * the batch); otherwise it starts its own cluster (its own id). Stored
 * clusters are never re-pointed.
 */
export function assignClusters(
  batch: PreparedArticle[],
  recent: ClusterCandidate[],
): Map<string, string> {
  const pool: ClusterCandidate[] = [...recent].sort((x, y) =>
    x.publishedAt === y.publishedAt ? x.id.localeCompare(y.id) : x.publishedAt.localeCompare(y.publishedAt)
  );
  const result = new Map<string, string>();
  const ordered = [...batch].sort((x, y) =>
    x.publishedAt === y.publishedAt ? x.id.localeCompare(y.id) : x.publishedAt.localeCompare(y.publishedAt)
  );
  for (const article of ordered) {
    const stored = pool.find((c) => c.id === article.id);
    if (stored) {
      result.set(article.id, stored.clusterId);
      continue;
    }
    const match = pool.find((c) => sameStory(c, article) !== null);
    const clusterId = match ? match.clusterId : article.id;
    result.set(article.id, clusterId);
    pool.push({
      id: article.id,
      clusterId,
      urlKey: article.urlKey,
      titleTokens: article.titleTokens,
      nameTokens: article.nameTokens,
      category: article.category,
      subjects: article.subjects,
      publishedAt: article.publishedAt,
    });
  }
  return result;
}

/**
 * Story state of a cluster from its members' roles and transfer states.
 * Repetition never upgrades a story: CONFIRMED needs an official member.
 */
export function storyState(
  members: Array<{ sourceRole: SourceRole | string; transferStatus: TransferStatus | string | null }>,
): { state: "OFFICIAL" | "REPORT" | "DEVELOPING"; transferStatus: TransferStatus | null } {
  const official = members.some((m) => m.sourceRole === "FIRST_PARTY_OFFICIAL");
  const media = members.some((m) => m.sourceRole === "ESTABLISHED_MEDIA");
  const transfers = members.map((m) => m.transferStatus).filter(Boolean);
  const transfer: TransferStatus | null = !transfers.length
    ? null
    : members.some((m) => m.transferStatus === "CONFIRMED" && m.sourceRole === "FIRST_PARTY_OFFICIAL")
    ? "CONFIRMED"
    : transfers.includes("REPORT")
    ? "REPORT"
    : "RUMOR";
  return { state: official ? "OFFICIAL" : media ? "REPORT" : "DEVELOPING", transferStatus: transfer };
}

import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';

// Supabase rejects migrations that set pg_trgm parameters (e.g. a
// function-level `set pg_trgm.strict_word_similarity_threshold=...`):
// 42501 permission denied to set parameter. PGlite runs as superuser, so the
// functional suites cannot catch it; this static guard does.

const folder = new URL('../../supabase/migrations/', import.meta.url);

// Historical migrations that already carry the clause. Production runs
// remote-only compat variants of these functions; they are left untouched.
const LEGACY = new Set([
  '20260922235500_player_search_coverage.sql',
  '20260923010000_player_search_typo_guard.sql',
  '20260923120000_player_on_demand.sql',
]);

const SETS_PG_TRGM = [
  /\bset\s+pg_trgm\.[a-z_]+\s*(=|\bto\b)/i,
  /\bset_config\s*\(\s*'pg_trgm\./i,
  /\balter\s+(role|database|function)[^;]*\bset\s+pg_trgm\./i,
];

const stripComments = (sql) => sql.replace(/--[^\n]*/g, '');

test('no migration outside the legacy allowlist sets pg_trgm parameters', async () => {
  const offenders = [];
  for (const name of (await readdir(folder)).filter((n) => n.endsWith('.sql')).sort()) {
    const sql = stripComments(await readFile(new URL(name, folder), 'utf8'));
    if (SETS_PG_TRGM.some((pattern) => pattern.test(sql))) offenders.push(name);
  }
  assert.deepEqual(offenders.filter((name) => !LEGACY.has(name)), [],
    'Supabase rejects setting pg_trgm.* (42501); rely on the default thresholds instead');
  // The allowlist is exact: fixing a legacy file must shrink it, never hide new ones.
  assert.deepEqual(offenders, [...LEGACY].sort());
});

test('country-aware search no longer sets pg_trgm and keeps its safe search_path', async () => {
  const sql = await readFile(new URL('20260928051417_country_aware_search.sql', folder), 'utf8');
  const code = stripComments(sql);
  assert.doesNotMatch(code, /pg_trgm\./i);
  const start = code.indexOf('create or replace function public.futbeat_search_catalog(');
  assert.ok(start >= 0);
  const header = code.slice(start, code.indexOf('$$', start));
  assert.match(header, /set\s+search_path\s*=\s*''/i);
  // The strict threshold still comes from pg_trgm's default (0.5).
  assert.match(code.slice(start), /operator\(extensions\.<<%\)/);
});

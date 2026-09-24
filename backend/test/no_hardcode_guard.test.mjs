import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

// Guard: Match Center completeness/standings logic must be generic. QA cases
// (teams, leagues, players, ids) may appear in test fixtures, never in
// production runtime code or in the migrations of this feature onward.
// Older published migrations carry pre-existing editorial seed data and are
// out of scope (published migrations are never edited).

const root = new URL('../../', import.meta.url);
const FIRST_GUARDED_MIGRATION = '20260923170000';
const BANNED = [/newcastle/i, /\bhull\b/i, /premier league/i, /\bmatz\b/i, /\bsels\b/i];
// Concrete canonical ids (fb_<kind>_<32 hex>) must never be hardcoded.
const CANONICAL_ID = /fb_(comp|competition|team|player|match)_[0-9a-f]{32}/i;

async function files(dir, pattern) {
  const out = [];
  for (const entry of await readdir(new URL(dir, root), { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await files(path + '/', pattern));
    else if (pattern.test(entry.name)) out.push(path);
  }
  return out;
}

test('production runtime code and new migrations contain no QA-specific names or canonical ids', async () => {
  const guarded = [
    ...await files('supabase/functions/', /\.(ts|mjs|js)$/),
    ...await files('apps/mobile/lib/', /\.dart$/),
    ...await files('backend/providers/', /\.mjs$/),
    ...(await files('supabase/migrations/', /\.sql$/))
      .filter((path) => path.split(/[\\/]/).at(-1) >= FIRST_GUARDED_MIGRATION),
  ];
  assert.ok(guarded.some((p) => p.includes('20260923180000')), 'the standings migration is guarded');
  const violations = [];
  for (const path of guarded) {
    const text = await readFile(new URL(path.replaceAll('\\', '/'), root), 'utf8');
    for (const pattern of [...BANNED, CANONICAL_ID]) {
      const hit = text.match(pattern);
      if (hit) violations.push(`${path}: ${hit[0]}`);
    }
  }
  assert.deepEqual(violations, []);
});

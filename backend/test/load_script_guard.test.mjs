import test from 'node:test';
import assert from 'node:assert/strict';
import { plan } from '../../scripts/load/public-api-multi-client.mjs';

// The multi-client load script refuses production unless explicitly
// confirmed, and only plans GET reads of stored data.

const opts = (extra = {}) => ({ clients: 2, rounds: 1, match: 'fb_match_abc', team: null, run: false, allowProduction: false, productionRef: '', ...extra });

test('production is refused without the explicit confirmation', () => {
  assert.throws(() => plan(opts(), 'https://izlmruqawgagwdcsjhte.supabase.co'), /REFUSED/);
  assert.throws(() => plan(opts({ allowProduction: true, productionRef: 'other' }), 'https://izlmruqawgagwdcsjhte.supabase.co'), /REFUSED/);
  assert.equal(plan(opts({ allowProduction: true, productionRef: 'izlmruqawgagwdcsjhte' }), 'https://izlmruqawgagwdcsjhte.supabase.co').ref, 'izlmruqawgagwdcsjhte');
});

test('staging plan: stored reads only, detail without demand', () => {
  const p = plan(opts(), 'https://stagingref000000000000.supabase.co');
  assert.equal(p.requests, 2 * 1 * p.routes.length);
  assert.ok(p.routes.includes('/v1/match-detail?id=fb_match_abc&request=0'));
  assert.ok(p.routes.every((r) => r.startsWith('/v1/')));
});

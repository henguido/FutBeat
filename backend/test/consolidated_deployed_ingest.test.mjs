import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { runChunksWithTimeoutRetry } from '../../supabase/functions/_shared/chunked_rpc.ts';

const source = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
for (const [method, rpcName] of [['storeGlobalEntities', 'futbeat_store_global_fixture_entities'], ['storeCalendarEntities', 'futbeat_store_calendar_entities']]) {
  test(`deployed ingest ${method}: 300-entity chunks, identity deduplication, no calendar follow-up merge`, async () => {
    const calls = [];
    const ctx = vm.createContext({ Map, Set, Array, String, console, runChunksWithTimeoutRetry,
      rpc: async (name, args) => { calls.push({ name, args }); return { accepted: args.p_snapshot.matches.length }; } });
    const body = source.slice(source.indexOf('const GLOBAL_ENTITY_CHUNK_MAX'), source.indexOf('type ExistingLoader'));
    vm.runInContext(stripTypeScriptTypes(body), ctx);
    const matches = Array.from({ length: 650 }, (_, i) => ({ id: `fb_match_${i}`, homeTeamId: 'fb_team_h', awayTeamId: 'fb_team_a', competitionId: 'fb_comp_c' }));
    const snapshot = { matches: [...matches, { ...matches[0], status: 'LIVE' }], teams: [{ id: 'fb_team_h' }, { id: 'fb_team_a' }], competitions: [{ id: 'fb_comp_c' }] };
    if (method === 'storeCalendarEntities') await ctx[method]('goal_api', snapshot);
    else await ctx[method](snapshot);
    assert.deepEqual(calls.map(c => c.name), [rpcName, rpcName, rpcName]);
    assert.deepEqual(calls.map(c => c.args.p_snapshot.matches.length), [300, 300, 50]);
    const written = calls.flatMap(c => c.args.p_snapshot.matches);
    assert.equal(new Set(written.map(m => m.id)).size, 650);
    assert.equal(written.find(m => m.id === 'fb_match_0').status, 'LIVE');
    assert.equal(calls.some(c => c.name === 'futbeat_finalize_calendar_date'), false);
  });
}

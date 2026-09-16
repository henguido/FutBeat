import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { aggregateWork, dataPriority, interestPriority } from '../interest/strategy.mjs';
import { openDatabase } from '../storage/database.mjs';
const empty = { explicitFollowers: 0, selectedCountryUsers: 0, detectedCountryUsers: 0, temporaryUsers: 0 };

test('new CR user receives inferred base coverage without becoming a favorite', () => {
  const result = interestPriority({ ...empty, detectedCountryUsers: 1 });
  assert.equal(result.depth, 'BASE'); assert.ok(result.score > 1);
});
test('manual country and explicit foreign favorite follow the intended order', () => {
  const detected = interestPriority({ ...empty, detectedCountryUsers: 20 });
  const selected = interestPriority({ ...empty, selectedCountryUsers: 1, detectedCountryUsers: 20 });
  const favorite = interestPriority({ ...empty, explicitFollowers: 1, selectedCountryUsers: 100 });
  assert.ok(selected.score > detected.score); assert.ok(favorite.score > selected.score); assert.equal(favorite.depth, 'DEEP');
});
test('competition favorite and followed match are deep interests', () => {
  for (const entityType of ['competition', 'match']) assert.equal(aggregateWork([{ entityType, entityId: 'fb_any', explicitFollowers: 1 }])[0].depth, 'DEEP');
});
test('opened match gets temporary detail priority without becoming favorite', () => {
  const detail = dataPriority({ ...empty, temporaryUsers: 1 }, 'match_detail');
  const feed = dataPriority({ ...empty, temporaryUsers: 1 }, 'feed');
  assert.equal(detail.depth, 'TEMPORARY'); assert.ok(detail.score > feed.score);
});
test('removing a favorite lowers priority and 5000 users create one work item', () => {
  const [popular] = aggregateWork([
    { entityType: 'team', entityId: 'fb_team_lda', explicitFollowers: 3000 },
    { entityType: 'team', entityId: 'fb_team_lda', explicitFollowers: 2000 },
  ]);
  assert.equal(popular.explicitFollowers, 5000); assert.equal(aggregateWork([{ entityType: 'team', entityId: 'fb_team_lda' }]).length, 1);
  assert.ok(popular.score > interestPriority(empty).score);
});
test('unknown country uses global fallback and unavailable remains explicit', () => {
  assert.deepEqual(interestPriority(empty), { score: 1, depth: 'BASE' });
  assert.equal({ available: false, reason: 'not_available' }.available, false);
});

test('durable aggregation deduplicates work and removes deleted favorites', async () => {
  const db = await openDatabase();
  try {
    await db.exec("create schema auth; create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;");
    await db.query("insert into futbeat_private.entities values ('fb_team_interest','team',$1),('fb_match_interest','match',$2)", [
      JSON.stringify({ id: 'fb_team_interest' }),
      JSON.stringify({ id: 'fb_match_interest' }),
    ]);
    const users = [randomUUID(), randomUUID()];
    for (const uid of users) {
      await db.query("select set_config('request.jwt.claim.sub',$1,false)", [uid]);
      await db.query("select public.futbeat_sync_user_preferences('CR',null)");
      await db.query("select public.futbeat_sync_push_follows($1)", [
        JSON.stringify([{ type: 'team', id: 'fb_team_interest' }]),
      ]);
    }
    let row = (await db.query("select * from futbeat_private.coverage_interests where subject_type='team' and subject_id='fb_team_interest'")).rows[0];
    assert.equal(row.explicit_followers, 2);
    assert.equal(row.depth, 'DEEP');
    assert.equal((await db.query("select count(*)::int n from futbeat_private.coverage_interests where subject_id='fb_team_interest'")).rows[0].n, 1);

    await db.query("select public.futbeat_sync_push_follows('[]'::jsonb)");
    row = (await db.query("select * from futbeat_private.coverage_interests where subject_id='fb_team_interest'")).rows[0];
    assert.equal(row.explicit_followers, 1);
    await db.query("select public.futbeat_touch_temporary_interest('match','fb_match_interest',30)");
    row = (await db.query("select * from futbeat_private.coverage_interests where subject_id='fb_match_interest'")).rows[0];
    assert.equal(row.depth, 'TEMPORARY');
  } finally {
    await db.close();
  }
});

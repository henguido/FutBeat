import test from 'node:test';
import assert from 'node:assert/strict';
import { modelLiveDelivery } from '../notifications/capacity_model.mjs';

test('scoped messages are bounded by relevance rather than all matches', () => {
  const r = modelLiveDelivery({clients: 100_000, matches: 300,
    changesPerMatch: 4, relevantMatchesPerClient: 3});
  assert.equal(r.globalMessages, 120_000_000);
  assert.equal(r.scopedMessages, 1_200_000);
  assert.equal(r.channels, 100_000);
});

test('model makes current per-device outbox growth explicit', () => {
  const r = modelLiveDelivery({clients: 1_000, matches: 10,
    changesPerMatch: 2, relevantMatchesPerClient: 3, devicesPerClient: 2});
  assert.equal(r.currentOutboxRows, 40_000);
  assert.equal(r.topicEventRows, 20);
});

test('zero interest opens no channel', () => {
  const r = modelLiveDelivery({clients: 100, matches: 50,
    changesPerMatch: 1, relevantMatchesPerClient: 0});
  assert.equal(r.scopedMessages, 0);
  assert.equal(r.channels, 0);
});

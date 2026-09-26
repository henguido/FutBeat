import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// #99: GOAL incidents carry structured scorer/assist names exactly as the
// provider sent them (never inferred), alongside the existing fields.
const goals = (events) => normalizeMatchDetail({ payload: { events } }).incidents.filter((e) => e.type === 'GOAL');

test('home scorer: playerName + side home; stoppage minute split; assist kept', () => {
  const [goal] = goals([{ type: 'GOAL', time: '45+2', homeScorer: 'I. Vagabov', homeScorerId: 'p1',
    homeAssist: 'A. Asistente', homeAssistId: 'p2', score: '3 - 0', info: null }]);
  assert.equal(goal.playerName, 'I. Vagabov');
  assert.equal(goal.assistName, 'A. Asistente');
  assert.equal(goal.side, 'home');
  assert.deepEqual([goal.minute, goal.extraMinute], [45, 2]);
  assert.deepEqual([goal.playerId, goal.assistPlayerId], ['p1', 'p2']);
  assert.equal(goal.info, null);
  // Existing contract unchanged.
  assert.equal(goal.label, 'Gol');
  assert.equal(goal.detail, 'I. Vagabov · Asistencia: A. Asistente · 3 - 0');
});

test('away scorer: playerName + side away; provider info preserved verbatim', () => {
  const [goal] = goals([{ type: 'GOAL', time: '45', awayScorer: 'V. Sokolov', info: 'Penalty' }]);
  assert.deepEqual([goal.playerName, goal.side, goal.info, goal.assistName], ['V. Sokolov', 'away', 'Penalty', null]);
  assert.deepEqual([goal.minute, goal.extraMinute], [45, null]);
});

test('no scorer: playerName null, nothing invented', () => {
  const [goal] = goals([{ type: 'GOAL', time: '55', score: '1 - 0' }]);
  assert.equal(goal.playerName, null);
  assert.equal(goal.assistName, null);
  assert.equal(goal.side, null);
  assert.equal(goal.playerId, null);
});

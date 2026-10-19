import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SUMMARY_GENERATOR_VERSION, buildMatchSummary, canonicalJson, summaryPhase,
} from '../../supabase/functions/_shared/match_summary.ts';

// Match summary contract v1: facts only, deterministic, versioned.
// Synthetic matches; no provider, no clock.

const HOME = 'fb_team_sum_home';
const AWAY = 'fb_team_sum_away';
const teams = { [HOME]: { name: 'Club Uno' }, [AWAY]: { name: 'Club Dos' } };
const players = {
  fb_player_a: { name: 'Ana Delantera' },
  fb_player_b: { name: 'Bruno Medio' },
  fb_player_c: { name: 'Carlos Defensa' },
};
const goal = (id, side, minute, extra = {}) => ({ id, type: 'GOAL', minute, teamId: side === 'home' ? HOME : AWAY, ...extra });
const input = (match, extra = {}) => ({
  match: { id: 'fb_match_sum', startTime: '2026-10-18T22:00:00Z', homeTeamId: HOME, awayTeamId: AWAY, events: [], ...match },
  teams, players, competition: { name: 'Primera Ejemplo' }, ...extra,
});
const texts = (s) => s.paragraphs.map((p) => p.text);

test('phase follows the effective status; final only when VERIFIED', () => {
  assert.equal(summaryPhase('VERIFIED'), 'FINAL');
  assert.equal(summaryPhase('FINISHED_PENDING_VERIFICATION'), 'FINAL_PROVISIONAL');
  assert.equal(summaryPhase('HALFTIME'), 'LIVE');
  assert.equal(summaryPhase('POSTPONED'), 'CALLED_OFF');
  assert.equal(summaryPhase('SCHEDULED'), 'PRE_MATCH');
  assert.equal(summaryPhase('WEIRD'), 'UNKNOWN');
});

test('verified final: result, scorers with assists, penalty and own goal', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 2, away: 1 }, events: [
    goal('e1', 'home', 12, { playerId: 'fb_player_a', assistPlayerId: 'fb_player_b' }),
    goal('e2', 'away', 40, { playerId: 'fb_player_c', ownGoal: true }),
    goal('e3', 'home', 90, { playerId: 'fb_player_a', extraMinute: 3, detail: 'Penalty' }),
    { id: 'y1', type: 'YELLOW_CARD', minute: 50, teamId: AWAY, playerId: 'fb_player_c' },
  ] }));
  assert.equal(s.contract, 'futbeat.match-summary');
  assert.equal(s.contractVersion, 1);
  assert.equal(s.generatorVersion, SUMMARY_GENERATOR_VERSION);
  assert.equal(s.phase, 'FINAL');
  assert.equal(s.headline, 'Club Uno 2-1 Club Dos');
  assert.deepEqual(texts(s), [
    'Club Uno venció 2-1 a Club Dos. Primera Ejemplo.',
    'Goles de Club Uno: Ana Delantera (12′, asistencia de Bruno Medio) y Ana Delantera (90+3′, penal).',
    'Goles de Club Dos: Carlos Defensa en propia puerta (40′).',
  ]);
  assert.deepEqual(s.paragraphs[1].facts, ['goal-1', 'goal-3']);
  assert.ok(s.omissions.some((o) => o.code === 'statistics_not_summarized'));
});

test('goal events that do not add up to the score name nobody', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 2, away: 0 }, events: [
    goal('e1', 'home', 12, { playerId: 'fb_player_a' }),
  ] }));
  assert.deepEqual(texts(s), ['Club Uno venció 2-0 a Club Dos. Primera Ejemplo.']);
  assert.equal(s.facts.filter((f) => f.kind === 'goal').length, 0);
  assert.ok(s.omissions.some((o) => o.code === 'scorers_unverified'));
});

test('synthetic "score changed" goals never become scorers', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 1, away: 0 }, events: [
    goal('syn', 'home', 30, { synthetic: true, detail: 'Marcador actualizado' }),
  ] }));
  assert.ok(s.omissions.some((o) => o.code === 'scorers_unverified'));
  assert.ok(!texts(s).some((t) => t.startsWith('Goles')));
});

test('retracted events are ignored; a goal without identity is not attributed', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 1, away: 0 }, events: [
    goal('r', 'home', 5, { playerId: 'fb_player_b', retracted: true }),
    goal('e1', 'home', 20),
  ] }));
  assert.deepEqual(texts(s)[1], 'Goles de Club Uno: gol sin autor confirmado (20′).');
});

test('provisional final: labelled, and assists are held back', () => {
  const s = buildMatchSummary(input({ status: 'FINISHED_PENDING_VERIFICATION', score: { home: 1, away: 1 }, events: [
    goal('e1', 'home', 10, { playerId: 'fb_player_a', assistPlayerId: 'fb_player_b' }),
    goal('e2', 'away', 80, { playerId: 'fb_player_c' }),
  ] }));
  assert.equal(s.phase, 'FINAL_PROVISIONAL');
  assert.equal(texts(s)[0], 'Resultado provisional: Club Uno y Club Dos empataron 1-1. Primera Ejemplo.');
  assert.equal(texts(s)[1], 'Goles de Club Uno: Ana Delantera (10′).');
  assert.ok(s.omissions.some((o) => o.code === 'assists_pending_verification'));
});

test('shoot-out only when the match score is level and the shoot-out decisive', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 0, away: 0 }, periods: { penalties: { home: 4, away: 5 } } }));
  assert.deepEqual(texts(s), ['Club Uno y Club Dos empataron 0-0. Primera Ejemplo.', 'Club Dos ganó en la tanda de penales (5-4).']);
  const unclear = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 1, away: 0 }, periods: { penalties: { home: 4, away: 5 } },
    events: [goal('e1', 'home', 3, { playerId: 'fb_player_a' })] }));
  assert.ok(!texts(unclear).some((t) => t.includes('penales')));
});

test('live, pre-match, called off and unknown score', () => {
  const live = buildMatchSummary(input({ status: 'LIVE', score: { home: 0, away: 1 }, events: [goal('e', 'away', 33, { playerId: 'fb_player_c' })] }));
  assert.equal(texts(live)[0], 'En juego: Club Uno 0-1 Club Dos. Primera Ejemplo.');
  const pre = buildMatchSummary(input({ status: 'SCHEDULED' }));
  assert.equal(texts(pre)[0], 'Club Uno recibe a Club Dos el domingo 18 de octubre, 16:00 (Primera Ejemplo).');
  const off = buildMatchSummary(input({ status: 'POSTPONED' }));
  assert.equal(texts(off)[0], 'El partido entre Club Uno y Club Dos fue postergado.');
  const noScore = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 1 } }));
  assert.deepEqual(texts(noScore), []);
  assert.ok(noScore.omissions.some((o) => o.code === 'score_unavailable'));
});

test('red cards are reported with team and minute; yellow cards are not', () => {
  const s = buildMatchSummary(input({ status: 'VERIFIED', score: { home: 0, away: 0 }, events: [
    { id: 'r1', type: 'RED_CARD', minute: 70, teamId: AWAY, playerId: 'fb_player_c' },
    { id: 'y1', type: 'YELLOW_CARD', minute: 20, teamId: HOME, playerId: 'fb_player_a' },
  ] }));
  assert.equal(texts(s)[1], 'Expulsado: Carlos Defensa (Club Dos, 70′).');
});

test('determinism: identical input gives identical bytes; key order does not matter', () => {
  const a = input({ status: 'VERIFIED', score: { home: 1, away: 0 }, events: [goal('e1', 'home', 12, { playerId: 'fb_player_a' })] });
  const b = JSON.parse(JSON.stringify(a));
  b.match = Object.fromEntries(Object.entries(b.match).reverse());
  assert.equal(JSON.stringify(buildMatchSummary(a)), JSON.stringify(buildMatchSummary(a)));
  assert.equal(buildMatchSummary(a).fingerprint.input, buildMatchSummary(b).fingerprint.input);
  assert.equal(canonicalJson({ b: 1, a: [2, { d: 3, c: 4 }] }), '{"a":[2,{"c":4,"d":3}],"b":1}');
});

test('significant fingerprint: changes with facts or names, not with irrelevant input', () => {
  const base = input({ status: 'LIVE', score: { home: 1, away: 0 }, events: [goal('e1', 'home', 12, { playerId: 'fb_player_a' })] });
  const sig = (x) => buildMatchSummary(x).fingerprint.significant;
  const s0 = sig(base);
  // A yellow card, a substitution or an unrelated player's data: same story.
  const noise = structuredClone(base);
  noise.match.events.push({ id: 'y', type: 'YELLOW_CARD', minute: 30, teamId: AWAY, playerId: 'fb_player_c' });
  noise.players.fb_player_z = { name: 'Nadie' };
  assert.equal(sig(noise), s0);
  // A goal, a phase change or a scorer's name: regenerate.
  const goal2 = structuredClone(base);
  goal2.match.score = { home: 2, away: 0 };
  goal2.match.events.push(goal('e2', 'home', 50, { playerId: 'fb_player_b' }));
  assert.notEqual(sig(goal2), s0);
  assert.notEqual(sig({ ...base, match: { ...base.match, status: 'VERIFIED' } }), s0);
  const renamed = structuredClone(base);
  renamed.players.fb_player_a = { name: 'Ana María Delantera' };
  assert.notEqual(sig(renamed), s0);
});

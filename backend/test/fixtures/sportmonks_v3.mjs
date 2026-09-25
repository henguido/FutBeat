// Synthetic Sportmonks Football API v3 shapes for tests (#102). Built by
// hand from the public documentation's field names; NOT copied from any real
// account response. Ids, names and dates are invented.

export const HOME = 9001;
export const AWAY = 9002;
export const LEAGUE = 777;
export const SEASON = 20260;

const states = {
  NS: { id: 1, state: 'NS', name: 'Not Started', short_name: 'NS', developer_name: 'NS' },
  INPLAY_1ST_HALF: { id: 2, state: 'INPLAY_1ST_HALF', name: '1st Half', short_name: '1st', developer_name: 'INPLAY_1ST_HALF' },
  HT: { id: 3, state: 'HT', name: 'Half-Time', short_name: 'HT', developer_name: 'HT' },
  FT: { id: 5, state: 'FT', name: 'Full-Time', short_name: 'FT', developer_name: 'FT' },
  POSTPONED: { id: 10, state: 'POSTPONED', name: 'Postponed', short_name: 'POSTP', developer_name: 'POSTPONED' },
};

export function participants() {
  return [
    { id: HOME, name: 'Sintético Local FC', short_code: 'SLF', image_path: 'https://cdn.example.invalid/9001.png',
      meta: { location: 'home', winner: null, position: 1 } },
    { id: AWAY, name: 'Sintético Visita FC', short_code: 'SVF', image_path: 'https://cdn.example.invalid/9002.png',
      meta: { location: 'away', winner: null, position: 2 } },
  ];
}

export function scores(home, away) {
  return [
    { id: 1, fixture_id: 5001, type_id: 1525, participant_id: HOME, score: { goals: home, participant: 'home' }, description: 'CURRENT' },
    { id: 2, fixture_id: 5001, type_id: 1525, participant_id: AWAY, score: { goals: away, participant: 'away' }, description: 'CURRENT' },
    { id: 3, fixture_id: 5001, type_id: 1, participant_id: HOME, score: { goals: 0, participant: 'home' }, description: '1ST_HALF' },
  ];
}

export function goalEvent(id, { minute, extra = null, participant = HOME, player = 70001, result = '1-0' } = {}) {
  return {
    id, fixture_id: 5001, period_id: 1, participant_id: participant, type_id: 14, section: 'event',
    player_id: player, related_player_id: null, player_name: 'Anotador Sintético', related_player_name: null,
    result, info: null, addition: null, minute, extra_minute: extra, injured: null, on_bench: false,
  };
}

export function substitutionEvent(id, { minute, participant = AWAY, playerIn = 80002, playerOut = 80001 } = {}) {
  return {
    id, fixture_id: 5001, period_id: 2, participant_id: participant, type_id: 18, section: 'event',
    player_id: playerIn, related_player_id: playerOut, player_name: 'Entra', related_player_name: 'Sale',
    result: null, info: null, addition: null, minute, extra_minute: null, injured: false, on_bench: false,
  };
}

export function fixture({
  id = 5001,
  state = 'NS',
  kickoff = '2026-10-04T18:00:00Z',
  score = null,
  events,
  periods,
  venue = { id: 321, name: 'Estadio Sintético', city_name: 'Ciudad' },
  omit = [],
} = {}) {
  const base = {
    id, sport_id: 1, league_id: LEAGUE, season_id: SEASON, stage_id: 3001, round_id: 4001, group_id: null,
    aggregate_id: null, state_id: states[state]?.id ?? 99, venue_id: venue?.id ?? null,
    name: 'Sintético Local FC vs Sintético Visita FC',
    starting_at: kickoff.replace('T', ' ').replace('Z', '').slice(0, 19),
    result_info: null, leg: '1/1', details: null, length: 90, placeholder: false, has_odds: false,
    starting_at_timestamp: Math.floor(Date.parse(kickoff) / 1000),
    participants: participants(),
    scores: score ? scores(score[0], score[1]) : [],
    state: states[state] ?? { id: 99, state, name: state, short_name: state, developer_name: state },
    venue,
    events: events ?? [],
    periods: periods ?? [],
  };
  for (const key of omit) delete base[key];
  return base;
}

export const envelope = (data, remaining = 2999) => ({
  data,
  subscription: [{ meta: [], plans: [{ plan: 'Synthetic', sport: 'Football', category: 'Test' }] }],
  rate_limit: { resets_in_seconds: 3600, remaining, requested_entity: 'Fixture' },
  timezone: 'UTC',
});

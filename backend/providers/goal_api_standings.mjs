const clean = (value) => String(value ?? '').trim();

function nonNegativeInteger(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid GOAL API standings ${label}`);
  }
  return parsed;
}

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function teamIdentity(row) {
  const external = clean(
    row?.team?.id ??
    row?.teamId ??
    row?.team_id ??
    row?.teamKey,
  );
  const name = clean(
    row?.team?.name ??
    row?.teamName ??
    row?.team_name,
  );
  if (!external || !name) return null;
  return {
    kind: 'team',
    external,
    name,
    country: clean(row?.team?.country?.name ?? row?.team?.country),
    shortName: '',
  };
}

export function collectGoalApiStandingsIdentities(rawRows) {
  if (!Array.isArray(rawRows)) {
    throw new Error('Invalid GOAL API standings');
  }

  const result = new Map();
  for (const row of rawRows) {
    const identity = teamIdentity(row);
    if (identity) {
      result.set(`${identity.kind}:${identity.external}`, identity);
    }
  }
  return [...result.values()];
}

export async function normalizeGoalApiStandings(
  rawRows,
  competitionId,
  resolve,
  receivedAt,
  { season = '' } = {},
) {
  if (!Array.isArray(rawRows)) {
    throw new Error('Invalid GOAL API standings');
  }
  if (typeof competitionId !== 'string' || !competitionId.startsWith('fb_')) {
    throw new Error('Invalid canonical competition');
  }
  if (typeof resolve !== 'function') {
    throw new Error('GOAL API standings resolver is required');
  }
  if (!Number.isFinite(Date.parse(receivedAt))) {
    throw new Error('Invalid standings receivedAt');
  }

  const rows = [];
  const seenTeams = new Set();

  for (let index = 0; index < rawRows.length; index += 1) {
    const raw = rawRows[index];
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;

    const identity = teamIdentity(raw);
    if (!identity) continue;

    const teamId = await resolve(
      identity.kind,
      identity.external,
      identity,
    );
    if (!teamId || seenTeams.has(teamId)) continue;
    seenTeams.add(teamId);

    const gf = nonNegativeInteger(
      raw.overallLeagueGF ?? raw.goalsFor ?? raw.gf ?? 0,
      'goals for',
    );
    const ga = nonNegativeInteger(
      raw.overallLeagueGA ?? raw.goalsAgainst ?? raw.ga ?? 0,
      'goals against',
    );

    rows.push({
      position: positiveInteger(
        raw.overallLeaguePosition ?? raw.position ?? raw.rank,
        index + 1,
      ),
      teamId,
      played: nonNegativeInteger(
        raw.overallLeaguePlayed ?? raw.played ?? 0,
        'played',
      ),
      won: nonNegativeInteger(
        raw.overallLeagueW ?? raw.won ?? raw.win ?? 0,
        'won',
      ),
      drawn: nonNegativeInteger(
        raw.overallLeagueD ?? raw.drawn ?? raw.draw ?? 0,
        'drawn',
      ),
      lost: nonNegativeInteger(
        raw.overallLeagueL ?? raw.lost ?? raw.loss ?? 0,
        'lost',
      ),
      gf,
      ga,
      points: nonNegativeInteger(
        raw.overallLeaguePTS ?? raw.points ?? raw.pts ?? 0,
        'points',
      ),
    });
  }

  rows.sort((left, right) =>
    left.position - right.position ||
    right.points - left.points ||
    (right.gf - right.ga) - (left.gf - left.ga) ||
    right.gf - left.gf ||
    left.teamId.localeCompare(right.teamId)
  );

  return {
    competitionId,
    season: clean(season),
    provisional: false,
    source: 'GOAL API',
    updatedAt: receivedAt,
    rows: rows.map(({ position, ...row }) => row),
  };
}

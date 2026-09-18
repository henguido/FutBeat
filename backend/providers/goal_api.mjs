import { validateSnapshot } from './core/snapshot.mjs';

const clean = (value) => String(value ?? '').trim();

function required(value, label) {
  const result = clean(value);
  if (!result) throw new Error(`Missing GOAL API ${label}`);
  return result;
}

function trustedMedia(value, kind, receivedAt) {
  if (!value) return null;
  let url;
  try {
    url = new URL(String(value));
  } catch {
    throw new Error(`Invalid GOAL API ${kind} media URL`);
  }
  if (url.protocol !== 'https:' || url.hostname !== 'media.goal-api.com') {
    throw new Error(`Untrusted GOAL API ${kind} media URL`);
  }
  return {
    url: url.toString(),
    kind,
    source: 'GOAL API',
    receivedAt,
    verificationStatus: 'VERIFIED',
    rightsStatus: 'REVIEW_REQUIRED',
    usageScope: 'DEVELOPMENT_ONLY',
  };
}

function statusOf(fixture) {
  const status = clean(fixture?.matchStatus).toUpperCase();
  const period = clean(fixture?.matchPeriod).toUpperCase();

  if (status === 'POSTPONED') return 'POSTPONED';
  if (status === 'CANCELLED') return 'CANCELLED';
  if (status === 'SUSPENDED') return 'SUSPENDED';
  if (status === 'ABANDONED') return 'ABANDONED';
  if (status === 'HALF_TIME' || period === 'HALF_TIME') return 'HALFTIME';

  if (status === 'LIVE') {
    if (period === 'EXTRA_TIME') return 'EXTRA_TIME';
    if (period === 'PENALTIES') return 'PENALTIES';
    return 'LIVE';
  }

  if (['FINISHED', 'AFTER_ET', 'AFTER_PEN', 'AWARDED'].includes(status)) {
    return 'VERIFIED';
  }

  return 'SCHEDULED';
}

function integerScore(value) {
  if (value == null || value === '') return null;
  const score = Number(value);
  return Number.isInteger(score) && score >= 0 ? score : null;
}

const fixtureKey = (home, away, startTime) =>
  `${home}|${away}|${Math.floor(Date.parse(startTime) / 300000)}`;

export async function normalizeGoalApiFixtures(
  rawFixtures,
  resolve,
  receivedAt,
  existing = null,
) {
  if (!Array.isArray(rawFixtures)) throw new Error('Invalid GOAL API fixtures');
  if (typeof resolve !== 'function') throw new Error('GOAL API resolver is required');
  if (!Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid receivedAt');

  const competitions = new Map();
  const teams = new Map();
  const matches = new Map();
  const existingFixtures = new Map();

  for (const match of existing?.matches ?? []) {
    existingFixtures.set(
      fixtureKey(match.homeTeamId, match.awayTeamId, match.startTime),
      match.id,
    );
  }

  for (const fixture of rawFixtures) {
    const kickoff = clean(fixture?.kickoffUtc);
    if (!kickoff || !Number.isFinite(Date.parse(kickoff))) continue;

    const leagueExternal = clean(fixture?.league?.id ?? fixture?.leagueId);
    const leagueName = clean(fixture?.league?.name ?? fixture?.leagueName);
    if (!leagueExternal || !leagueName) continue;

    const country = clean(fixture?.countryName);
    const competitionId = await resolve('competition', leagueExternal, {
      name: leagueName,
      country,
      shortName: '',
    });

    const previousCompetition = existing?.competitions?.find?.(
      (item) => item.id === competitionId,
    );
    const competitionMedia = trustedMedia(
      fixture?.league?.logo ?? fixture?.leagueLogo,
      'COMPETITION_LOGO',
      receivedAt,
    );
    competitions.set(competitionId, previousCompetition ? {
      ...previousCompetition,
      name: leagueName,
      country: previousCompetition.country || country,
      season: clean(fixture?.leagueYear) || previousCompetition.season || '',
      media: previousCompetition.media ?? competitionMedia,
    } : {
      id: competitionId,
      name: leagueName,
      country,
      season: clean(fixture?.leagueYear),
      media: competitionMedia,
    });

    const normalizeTeam = async (side) => {
      const nested = fixture?.[side];
      const prefix = side === 'homeTeam' ? 'home' : 'away';
      const external = clean(
        nested?.id ?? fixture?.[`${prefix}TeamId`],
      );
      const name = clean(
        nested?.name ?? fixture?.[`${prefix}TeamName`],
      );
      if (!external || !name) return null;

      const id = await resolve('team', external, {
        name,
        country: '',
        shortName: '',
      });
      const previous = existing?.teams?.find?.((item) => item.id === id);
      const badge = trustedMedia(
        nested?.badge ??
          fixture?.[side === 'homeTeam' ? 'teamHomeBadge' : 'teamAwayBadge'],
        'TEAM_LOGO',
        receivedAt,
      );

      const next = previous ? {
        ...previous,
        name: previous.name || name,
        competitionId,
        media: previous.media ?? badge,
      } : {
        id,
        name,
        shortName: '',
        country: '',
        competitionId,
        aliases: [],
        media: badge,
      };
      teams.set(id, next);
      return id;
    };

    const homeId = await normalizeTeam('homeTeam');
    const awayId = await normalizeTeam('awayTeam');
    if (!homeId || !awayId || homeId === awayId) continue;

    const startTime = new Date(kickoff).toISOString();
    const key = fixtureKey(homeId, awayId, startTime);
    const matchExternal = required(fixture?.apiId ?? fixture?.id, 'fixture id');
    const matchId = existingFixtures.get(key) ??
      await resolve('match', matchExternal, {
        name: '',
        country: '',
        shortName: '',
      });

    const status = statusOf(fixture);
    const homeScore = integerScore(fixture?.homeTeamScore);
    const awayScore = integerScore(fixture?.awayTeamScore);
    const score = [
      'LIVE',
      'HALFTIME',
      'EXTRA_TIME',
      'PENALTIES',
      'VERIFIED',
    ].includes(status) && homeScore !== null && awayScore !== null
      ? { home: homeScore, away: awayScore }
      : null;

    const elapsed = Number(fixture?.matchElapsed);
    const minute = [
      'LIVE',
      'HALFTIME',
      'EXTRA_TIME',
      'PENALTIES',
    ].includes(status) && Number.isInteger(elapsed) && elapsed >= 0
      ? elapsed
      : null;

    matches.set(matchId, {
      id: matchId,
      competitionId,
      season: clean(fixture?.leagueYear),
      homeTeamId: homeId,
      awayTeamId: awayId,
      startTime,
      status,
      score,
      minute,
      venue: clean(fixture?.matchStadium),
      events: [],
      statistics: [],
      provenance: {
        source: 'GOAL API',
        externalId: matchExternal,
        receivedAt,
        verificationStatus: 'PROVISIONAL',
      },
    });
    existingFixtures.set(key, matchId);
  }

  return validateSnapshot({
    schemaVersion: 1,
    demo: false,
    updatedAt: receivedAt,
    coverage: {
      source: 'FutBeat Global',
      partial: true,
      live: false,
      developmentOnly: true,
      description: 'Calendario global centralizado por fecha',
      sources: ['GOAL API'],
    },
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    players: [],
    matches: [...matches.values()],
    standings: [],
  });
}

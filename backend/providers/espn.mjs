import { validateSnapshot } from './core/snapshot.mjs';

const clean = (value) => String(value ?? '').trim();

function required(value, label) {
  const result = clean(value);
  if (!result) throw new Error(`Missing ESPN ${label}`);
  return result;
}

function media(value, kind, receivedAt) {
  if (!value) return null;
  let url;
  try {
    url = new URL(String(value));
  } catch {
    throw new Error(`Invalid ESPN ${kind} media URL`);
  }
  if (
    url.protocol !== 'https:' ||
    !(url.hostname === 'espncdn.com' || url.hostname.endsWith('.espncdn.com'))
  ) {
    throw new Error(`Untrusted ESPN ${kind} media URL`);
  }
  return {
    url: url.toString(),
    kind,
    source: 'ESPN',
    receivedAt,
    verificationStatus: 'VERIFIED',
    rightsStatus: 'REVIEW_REQUIRED',
    usageScope: 'DEVELOPMENT_ONLY',
  };
}

function competitionName(event) {
  const slug = clean(event?.season?.slug);
  if (!slug) return 'ESPN Soccer';
  const withoutSeason = slug.replace(/^\d{4}(?:-\d{2,4})?-/, '');
  const words = withoutSeason.split('-').filter(Boolean);
  if (!words.length) return 'ESPN Soccer';
  return words
    .map((word) => word.length <= 3 && /^[a-z]+$/.test(word)
      ? word.toUpperCase()
      : word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

function competitionExternalId(event) {
  const slug = clean(event?.season?.slug);
  if (slug) return slug;
  const year = clean(event?.season?.year);
  const type = clean(event?.season?.type);
  if (year || type) return `season-${year || 'unknown'}-${type || 'unknown'}`;
  throw new Error('Missing ESPN competition identity');
}

function statusOf(event, competition) {
  const type = competition?.status?.type ?? event?.status?.type ?? {};
  const state = clean(type.state).toLowerCase();
  const detail = [
    type.name,
    type.description,
    type.detail,
    type.shortDetail,
  ].map(clean).join(' ').toLowerCase();

  if (detail.includes('postpon')) return 'POSTPONED';
  if (detail.includes('cancel')) return 'CANCELLED';
  if (detail.includes('suspend')) return 'SUSPENDED';
  if (detail.includes('abandon')) return 'ABANDONED';
  if (state === 'in') {
    if (detail.includes('half time') || detail.includes('halftime')) return 'HALFTIME';
    return 'LIVE';
  }
  if (state === 'post' || type.completed === true) return 'VERIFIED';
  return 'SCHEDULED';
}

function scoreOf(competitor) {
  const raw = competitor?.score?.value ?? competitor?.score;
  if (raw == null || raw === '') return null;
  const value = Number(raw);
  return Number.isInteger(value) && value >= 0 ? value : null;
}

function minuteOf(event, competition) {
  const display = clean(
    competition?.status?.displayClock ??
    event?.status?.displayClock ??
    competition?.status?.type?.shortDetail ??
    event?.status?.type?.shortDetail,
  );
  const match = display.match(/^(\d{1,3})/);
  return match ? Number(match[1]) : null;
}

function teamLogo(team) {
  return team?.logo ?? team?.logos?.[0]?.href ?? null;
}

const fixtureKey = (home, away, startTime) =>
  `${home}|${away}|${Math.floor(Date.parse(startTime) / 300000)}`;

export async function normalizeEspnFixtures(
  rawEvents,
  resolve,
  receivedAt,
  existing = null,
) {
  if (!Array.isArray(rawEvents)) throw new Error('Invalid ESPN events');
  if (typeof resolve !== 'function') throw new Error('ESPN resolver is required');
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

  for (const event of rawEvents) {
    const competition = event?.competitions?.[0];
    if (!competition) continue;

    const competitors = Array.isArray(competition.competitors)
      ? competition.competitors
      : [];
    const home = competitors.find((item) => item?.homeAway === 'home');
    const away = competitors.find((item) => item?.homeAway === 'away');
    if (!home?.team || !away?.team) continue;

    const compExternal = competitionExternalId(event);
    const compName = competitionName(event);
    const competitionId = await resolve('competition', compExternal, {
      name: compName,
      country: '',
      shortName: '',
    });

    competitions.set(competitionId, {
      id: competitionId,
      name: compName,
      country: '',
      season: clean(event?.season?.year),
      media: null,
    });

    const normalizeTeam = async (competitor) => {
      const team = competitor.team;
      const external = required(team.id, 'team id');
      const name = required(team.displayName ?? team.shortDisplayName ?? team.name, 'team name');
      const shortName = clean(team.abbreviation);
      const id = await resolve('team', external, {
        name,
        country: '',
        shortName,
      });
      const previous = existing?.teams?.find?.((item) => item.id === id);
      const candidateMedia = media(teamLogo(team), 'TEAM_LOGO', receivedAt);
      teams.set(id, previous ? {
        ...previous,
        competitionId,
        media: previous.media ?? candidateMedia,
      } : {
        id,
        name,
        shortName,
        country: '',
        competitionId,
        aliases: [],
        media: candidateMedia,
      });
      return id;
    };

    const homeId = await normalizeTeam(home);
    const awayId = await normalizeTeam(away);
    if (homeId === awayId) throw new Error('ESPN fixture resolved to one team');

    const startTime = new Date(
      required(competition.date ?? event.date, 'fixture date'),
    ).toISOString();
    if (!Number.isFinite(Date.parse(startTime))) {
      throw new Error('Invalid ESPN fixture date');
    }

    const key = fixtureKey(homeId, awayId, startTime);
    const eventExternal = required(event.id ?? competition.id, 'event id');
    const matchId = existingFixtures.get(key) ??
      await resolve('match', eventExternal, {
        name: '',
        country: '',
        shortName: '',
      });

    const status = statusOf(event, competition);
    const homeScore = scoreOf(home);
    const awayScore = scoreOf(away);
    const score = ['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES', 'VERIFIED']
      .includes(status) &&
      homeScore !== null &&
      awayScore !== null
      ? { home: homeScore, away: awayScore }
      : null;

    matches.set(matchId, {
      id: matchId,
      competitionId,
      season: clean(event?.season?.year),
      homeTeamId: homeId,
      awayTeamId: awayId,
      startTime,
      status,
      score,
      minute: ['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES'].includes(status)
        ? minuteOf(event, competition)
        : null,
      venue: clean(competition?.venue?.fullName ?? competition?.venue?.name),
      events: [],
      statistics: [],
      provenance: {
        source: 'ESPN',
        externalId: eventExternal,
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
      live: true,
      developmentOnly: true,
      description: 'Calendario global centralizado por fecha',
      sources: ['ESPN'],
    },
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    players: [],
    matches: [...matches.values()],
    standings: [],
  });
}

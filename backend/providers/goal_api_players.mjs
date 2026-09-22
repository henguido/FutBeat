const clean = (value) => String(value ?? '').trim();

function rawPlayers(payload) {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== 'object') throw new Error('Invalid squad envelope');

  const root = payload;
  if (root.success === false || root.error) throw new Error('Failed squad response');
  if (Array.isArray(root.data)) return root.data;
  if (root.data && typeof root.data === 'object') {
    if (Array.isArray(root.data.players)) return root.data.players;
    if (Array.isArray(root.data.squad)) return root.data.squad;
  }
  if (Array.isArray(root.players)) return root.players;
  if (Array.isArray(root.squad)) return root.squad;
  throw new Error('Invalid squad envelope');
}

function nestedPlayer(row) {
  return row?.player && typeof row.player === 'object' ? row.player : row;
}

function playerIdentity(row) {
  const player = nestedPlayer(row);
  const external = clean(
    player?.id ?? player?.apiId ?? player?.playerId ??
      row?.playerId ?? row?.apiId ?? row?.id,
  );
  const firstName = clean(player?.firstName ?? row?.firstName);
  const lastName = clean(player?.lastName ?? row?.lastName);
  const composed = [firstName, lastName].filter(Boolean).join(' ');
  const name = clean(
    player?.name ?? player?.playerName ?? row?.playerName ?? row?.name ?? composed,
  );
  if (!external || !name) return null;

  return {
    kind: 'player',
    external,
    name,
    country: clean(
      player?.nationality ?? player?.countryName ?? player?.country ??
        row?.nationality ?? row?.countryName ?? row?.country,
    ),
    shortName: clean(player?.shortName ?? row?.shortName),
  };
}

export function collectGoalApiPlayerIdentities(payload) {
  const identities = new Map();
  const rows = rawPlayers(payload);
  for (const row of rows) {
    const identity = playerIdentity(row);
    if (identity) identities.set(identity.external, identity);
  }
  if (rows.length > 0 && identities.size === 0) throw new Error('Squad contains no valid identities');
  return [...identities.values()];
}

function verifiedPhoto(value, receivedAt) {
  if (!value) return null;
  try {
    const url = new URL(String(value));
    if (url.protocol !== 'https:' || url.hostname !== 'media.goal-api.com' || url.username || url.password || url.port) {
      return null;
    }
    return {
      url: url.toString(),
      kind: 'PLAYER_PHOTO',
      source: 'GOAL API',
      receivedAt,
      verificationStatus: 'VERIFIED',
      rightsStatus: 'REVIEW_REQUIRED',
      usageScope: 'DEVELOPMENT_ONLY',
    };
  } catch {
    return null;
  }
}

function integerOrNull(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : null;
}

function dateOrNull(value) {
  const result = clean(value);
  if (!result) return null;
  const parsed = Date.parse(result);
  return Number.isFinite(parsed) ? result : null;
}

function decimalOrNull(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function booleanOrNull(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'boolean') return value;
  const normalized = clean(value).toLowerCase();
  if (['1', 'true', 'yes', 'y'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'n'].includes(normalized)) return false;
  return null;
}

export async function normalizeGoalApiSquad(
  payload,
  teamId,
  resolve,
  receivedAt,
) {
  if (!clean(teamId).startsWith('fb_team_')) {
    throw new Error('Invalid canonical team id');
  }
  if (typeof resolve !== 'function') throw new Error('Player resolver is required');
  if (!Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid receivedAt');

  const players = new Map();
  const rows = rawPlayers(payload);
  for (const row of rows) {
    const identity = playerIdentity(row);
    if (!identity) continue;

    const player = nestedPlayer(row);
    const id = await resolve('player', identity.external, identity);
    const photoValue =
      player?.photo ?? player?.photoUrl ?? player?.image ?? player?.avatar ??
        row?.photo ?? row?.photoUrl ?? row?.image ?? row?.avatar;
    const photo = verifiedPhoto(photoValue, receivedAt);
    if (photo) Object.assign(photo, { externalId: identity.external, discoveredVia: 'squad' });

    const position = clean(
      player?.position?.name ?? player?.positionName ?? player?.position ??
        row?.position?.name ?? row?.positionName ?? row?.position,
    );
    const shirtNumber = integerOrNull(
      player?.number ?? player?.shirtNumber ?? player?.jerseyNumber ??
        row?.number ?? row?.shirtNumber ?? row?.jerseyNumber,
    );
    const age = integerOrNull(player?.age ?? row?.age);
    const dateOfBirth = dateOrNull(
      player?.dateOfBirth ?? player?.birthDate ?? player?.birthdate ??
        player?.birthday ?? row?.dateOfBirth ?? row?.birthDate ??
        row?.birthdate ?? row?.birthday,
    );
    const matchesPlayed = integerOrNull(
      player?.matchPlayed ?? player?.matchesPlayed ??
        row?.matchPlayed ?? row?.matchesPlayed,
    );
    const goals = integerOrNull(player?.goals ?? row?.goals);
    const assists = integerOrNull(player?.assists ?? row?.assists);
    const yellowCards = integerOrNull(
      player?.yellowCards ?? row?.yellowCards,
    );
    const redCards = integerOrNull(player?.redCards ?? row?.redCards);
    const rating = decimalOrNull(player?.rating ?? row?.rating);
    const injured = booleanOrNull(player?.injured ?? row?.injured);

    players.set(id, {
      id,
      name: identity.name,
      shortName: identity.shortName,
      country: identity.country,
      teamId,
      position,
      shirtNumber,
      age,
      dateOfBirth,
      matchesPlayed,
      goals,
      assists,
      yellowCards,
      redCards,
      rating,
      injured,
      aliases: [],
      media: photo,
      provenance: {
        source: 'GOAL API',
        externalId: identity.external,
        receivedAt,
        verificationStatus: 'PROVISIONAL',
        mediaSource: 'squad',
        mediaStatus: photo ? 'AVAILABLE' : clean(photoValue) ? 'FETCH_FAILED' : 'NO_PHOTO',
      },
    });
  }

  if (rows.length > 0 && players.size === 0) throw new Error('Squad contains no valid identities');
  return [...players.values()];
}

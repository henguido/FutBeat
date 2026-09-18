const clean = (value) => String(value ?? '').trim();

function rawPlayers(payload) {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== 'object') return [];

  const root = payload;
  if (Array.isArray(root.data)) return root.data;
  if (root.data && typeof root.data === 'object') {
    if (Array.isArray(root.data.players)) return root.data.players;
    if (Array.isArray(root.data.squad)) return root.data.squad;
  }
  if (Array.isArray(root.players)) return root.players;
  if (Array.isArray(root.squad)) return root.squad;
  return [];
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
  for (const row of rawPlayers(payload)) {
    const identity = playerIdentity(row);
    if (identity) identities.set(identity.external, identity);
  }
  return [...identities.values()];
}

function verifiedPhoto(value, receivedAt) {
  if (!value) return null;
  try {
    const url = new URL(String(value));
    if (url.protocol !== 'https:' || url.hostname !== 'media.goal-api.com') {
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
  for (const row of rawPlayers(payload)) {
    const identity = playerIdentity(row);
    if (!identity) continue;

    const player = nestedPlayer(row);
    const id = await resolve('player', identity.external, identity);
    const photo = verifiedPhoto(
      player?.photo ?? player?.photoUrl ?? player?.image ?? player?.avatar ??
        row?.photo ?? row?.photoUrl ?? row?.image ?? row?.avatar,
      receivedAt,
    );

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
      player?.dateOfBirth ?? player?.birthDate ?? player?.birthday ??
        row?.dateOfBirth ?? row?.birthDate ?? row?.birthday,
    );

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
      aliases: [],
      media: photo,
      provenance: {
        source: 'GOAL API',
        externalId: identity.external,
        receivedAt,
        verificationStatus: 'PROVISIONAL',
      },
    });
  }

  return [...players.values()];
}

const numeric = (value) => /^[1-9][0-9]*$/.test(String(value ?? '').trim());
const text = (value) => String(value ?? '').trim();

/**
 * Builds an in-memory resolver from externally verified GOAL crosswalks.
 * Descriptive similarity is deliberately ignored: a bridge must carry an
 * official/provider reference that names both external ids.
 */
export function verifiedGoalPlayerCrosswalk(rows) {
  const result = new Map();
  for (const row of rows ?? []) {
    const lineupId = text(row?.lineupExternalId);
    const catalogId = text(row?.catalogExternalId);
    const reference = text(row?.sourceReference);
    const bridgeType = text(row?.bridgeType);
    if (!numeric(lineupId) || numeric(catalogId) || !catalogId || !reference ||
        !['PROVIDER_CROSSWALK', 'OFFICIAL_PROFILE'].includes(bridgeType)) {
      continue;
    }
    if (result.has(lineupId) && result.get(lineupId) !== catalogId) {
      result.delete(lineupId); // conflicting evidence stays unresolved
      continue;
    }
    result.set(lineupId, catalogId);
  }
  return result;
}

/** Extracts the official id/apiId relation carried by one GOAL player row. */
export function crosswalksFromGoalPlayerRows(rows) {
  return (rows ?? []).map((row) => ({
    lineupExternalId: text(row?.lineupExternalId),
    catalogExternalId: text(row?.externalId),
    bridgeType: 'PROVIDER_CROSSWALK',
    sourceReference: text(row?.externalId)
      ? `goal-player-row:${text(row.externalId)}`
      : '',
  }));
}

export function resolveGoalPlayerExternalId(externalId, crosswalk) {
  const id = text(externalId);
  return crosswalk.get(id) ?? id;
}

/**
 * Read-only candidate classifier. Matching fields explain why a pair merits
 * review but never make it verified.
 */
export function auditGoalPlayerCandidates(lineupRows, squadRows) {
  const candidates = [];
  for (const lineup of lineupRows ?? []) {
    const matches = (squadRows ?? []).filter((squad) =>
      text(squad.teamId) === text(lineup.teamId) &&
      text(squad.name).toLocaleLowerCase() === text(lineup.name).toLocaleLowerCase());
    for (const squad of matches) {
      const signals = ['same_team', 'same_name'];
      if (text(lineup.shirtNumber) && text(lineup.shirtNumber) === text(squad.shirtNumber)) signals.push('same_shirt');
      if (text(lineup.position) && text(lineup.position) === text(squad.position)) signals.push('same_position');
      if (text(lineup.dateOfBirth) && text(lineup.dateOfBirth) === text(squad.dateOfBirth)) signals.push('same_dob');
      candidates.push({
        lineupExternalId: text(lineup.externalId),
        catalogExternalId: text(squad.externalId),
        lineupCanonicalId: text(lineup.canonicalId),
        catalogCanonicalId: text(squad.canonicalId),
        signals,
        decision: matches.length > 1 ? 'AMBIGUOUS' : 'CANDIDATE_ONLY',
        verified: false,
      });
    }
  }
  return candidates;
}


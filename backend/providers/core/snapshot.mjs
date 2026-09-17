export const statuses = new Set(['DISCOVERED', 'SCHEDULED', 'PRE_MATCH', 'LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES', 'FINISHED_PENDING_VERIFICATION', 'VERIFIED', 'POSTPONED', 'SUSPENDED', 'ABANDONED', 'CANCELLED']);

// Reject an incomplete batch before exposing any of it to readers.
export function validateSnapshot(data) {
  if (data.schemaVersion !== 1 || typeof data.demo !== 'boolean') throw new Error('Unsupported snapshot');
  if (!data.demo && data.coverage?.capabilities) {
    const allowed = new Set(['available', 'unavailable', 'temporarily_unavailable']);
    for (const key of ['teams', 'upcomingFixtures', 'pastResults', 'standings']) {
      const capability = data.coverage.capabilities[key];
      if (!allowed.has(capability?.status) || typeof capability.stale !== 'boolean' ||
        (capability.itemCount !== null && (!Number.isInteger(capability.itemCount) || capability.itemCount < 0))) {
        throw new Error(`Invalid ${key} coverage`);
      }
    }
  }
  const indexes = {};
  for (const type of ['competitions', 'teams', 'players', 'matches']) {
    if (!Array.isArray(data[type])) throw new Error(`Missing ${type}`);
    indexes[type] = new Set();
    for (const item of data[type]) {
      if (typeof item.id !== 'string' || !item.id.startsWith('fb_') || indexes[type].has(item.id)) throw new Error(`Invalid/duplicate ${type} ID`);
      indexes[type].add(item.id);
    }
  }
  for (const t of data.teams) if (!indexes.competitions.has(t.competitionId)) throw new Error('Unknown competition');
  for (const p of data.players) if (!indexes.teams.has(p.teamId)) throw new Error('Unknown player team');
  for (const m of data.matches) {
    if (!statuses.has(m.status) || !Number.isFinite(Date.parse(m.startTime))) throw new Error('Invalid match state/time');
    if (!indexes.competitions.has(m.competitionId) || !indexes.teams.has(m.homeTeamId) || !indexes.teams.has(m.awayTeamId) || m.homeTeamId === m.awayTeamId) throw new Error('Invalid match references');
    if (m.score !== null && (!Number.isInteger(m.score.home) || !Number.isInteger(m.score.away) || m.score.home < 0 || m.score.away < 0)) throw new Error('Invalid score');
    if (!m.provenance?.source || !Number.isFinite(Date.parse(m.provenance.receivedAt))) throw new Error('Missing provenance');
    const events = new Set();
    for (const e of m.events) {
      if (events.has(e.id) || (e.playerId && !indexes.players.has(e.playerId)) || ![m.homeTeamId, m.awayTeamId].includes(e.teamId)) throw new Error('Invalid event');
      events.add(e.id);
    }
  }
  return data;
}

// GOAL standings contract (no I/O): endpoint path and the reader for the
// rows' season label. The standings SQL store (futbeat_store_goal_standings)
// already validates and canonicalizes the raw rows, so they are passed as-is.
// The season field names mirror the existing standings workflow; they are
// UNVERIFIED against a captured response. When a row carries no season, the
// database archives the table under the competition's current season.

/** Path relative to https://api.goal-api.com/v1 (the worker adds base + auth). */
export const GOAL_STANDINGS_ENDPOINT = (externalLeagueId: string) =>
  `/standings/${encodeURIComponent(externalLeagueId)}`;

/** Raw provider rows, or [] when the response has no table. */
export function goalStandingsRows(payload: unknown): unknown[] {
  const data = payload && typeof payload === 'object' && !Array.isArray(payload)
    ? (payload as Record<string, unknown>).data
    : null;
  return Array.isArray(data) ? data : [];
}

/** Season label from the first row that carries one, else ''. */
export function goalStandingsSeason(rows: unknown[]): string {
  for (const row of rows.slice(0, 1)) {
    if (!row || typeof row !== 'object') continue;
    for (const field of ['season', 'leagueSeason', 'overallLeagueSeason']) {
      const value = (row as Record<string, unknown>)[field];
      if ((typeof value === 'string' || typeof value === 'number') && String(value).trim()) {
        return String(value).trim();
      }
    }
  }
  return '';
}

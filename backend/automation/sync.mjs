import { validateSnapshot } from '../providers/core/snapshot.mjs';

export function nextPollSeconds(match, now = new Date()) {
  if (['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES'].includes(match.status)) return 30;
  if (match.status === 'FINISHED_PENDING_VERIFICATION') return 120;
  if (['VERIFIED', 'CANCELLED', 'ABANDONED'].includes(match.status)) return null;
  if (['POSTPONED', 'SUSPENDED'].includes(match.status)) return 1800;
  const until = Date.parse(match.startTime) - now.getTime();
  return until <= 3600000 ? 300 : until <= 86400000 ? 1800 : 21600;
}

// A single-process demo boundary. A durable worker must replace this store with
// a transactional database + unique job key before production deployment.
export class SnapshotStore {
  #snapshot;
  #applied = new Set();
  constructor(snapshot) { this.#snapshot = structuredClone(validateSnapshot(snapshot)); }
  read() { return structuredClone(this.#snapshot); }
  async sync(provider, jobKey) {
    if (this.#applied.has(jobKey)) return false;
    const candidate = validateSnapshot(await provider.getSnapshot());
    if (this.#applied.has(jobKey)) return false;
    this.#snapshot = structuredClone(candidate);
    this.#applied.add(jobKey);
    return true;
  }
}

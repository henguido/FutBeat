export const providerCapabilities = Object.freeze([
  'fixtures',
  'liveScores',
  'events',
  'lineups',
  'statistics',
  'standings',
  'players',
  'transfers',
  'media',
  'push',
]);

export class ProviderQuotaError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'ProviderQuotaError';
    this.details = details;
  }
}

function positiveInteger(value, label) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`Invalid ${label}`);
  return value;
}

export function createProviderDescriptor({
  id,
  source,
  capabilities = [],
  developmentOnly = false,
  live = false,
}) {
  if (typeof id !== 'string' || !/^[a-z0-9_]+$/.test(id)) throw new Error('Invalid provider id');
  if (typeof source !== 'string' || !source.trim()) throw new Error('Invalid provider source');
  const allowed = new Set(providerCapabilities);
  const normalized = [...new Set(capabilities)];
  for (const capability of normalized) {
    if (!allowed.has(capability)) throw new Error(`Unknown provider capability: ${capability}`);
  }
  return Object.freeze({
    id,
    source,
    capabilities: Object.freeze(normalized),
    developmentOnly: Boolean(developmentOnly),
    live: Boolean(live),
  });
}

export class RequestBudget {
  #dailyUsed = 0;
  #minuteUsed = 0;
  #dayKey = null;
  #minuteKey = null;

  constructor({
    dailyLimit,
    perMinuteLimit,
    clock = () => new Date(),
    provider = 'provider',
  }) {
    this.dailyLimit = positiveInteger(dailyLimit, 'dailyLimit');
    this.perMinuteLimit = positiveInteger(perMinuteLimit, 'perMinuteLimit');
    this.clock = clock;
    this.provider = provider;
  }

  #roll(now) {
    const iso = now.toISOString();
    const dayKey = iso.slice(0, 10);
    const minuteKey = iso.slice(0, 16);
    if (this.#dayKey !== dayKey) {
      this.#dayKey = dayKey;
      this.#dailyUsed = 0;
    }
    if (this.#minuteKey !== minuteKey) {
      this.#minuteKey = minuteKey;
      this.#minuteUsed = 0;
    }
  }

  reserve(count = 1) {
    positiveInteger(count, 'request count');
    const now = this.clock();
    if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid budget clock');
    this.#roll(now);
    if (this.#dailyUsed + count > this.dailyLimit) {
      throw new ProviderQuotaError(`${this.provider} daily request budget exhausted`, {
        scope: 'day',
        limit: this.dailyLimit,
        used: this.#dailyUsed,
      });
    }
    if (this.#minuteUsed + count > this.perMinuteLimit) {
      throw new ProviderQuotaError(`${this.provider} per-minute request budget exhausted`, {
        scope: 'minute',
        limit: this.perMinuteLimit,
        used: this.#minuteUsed,
      });
    }
    this.#dailyUsed += count;
    this.#minuteUsed += count;
    return this.snapshot();
  }

  snapshot() {
    const now = this.clock();
    this.#roll(now);
    return Object.freeze({
      provider: this.provider,
      dailyLimit: this.dailyLimit,
      dailyUsed: this.#dailyUsed,
      dailyRemaining: this.dailyLimit - this.#dailyUsed,
      perMinuteLimit: this.perMinuteLimit,
      minuteUsed: this.#minuteUsed,
      minuteRemaining: this.perMinuteLimit - this.#minuteUsed,
    });
  }
}

export function assertApiEnvelope(data) {
  if (!data || typeof data !== 'object') throw new Error('Invalid provider response');
  const errors = data.errors;
  const hasErrors = Array.isArray(errors)
    ? errors.length > 0
    : errors && typeof errors === 'object' && Object.keys(errors).length > 0;
  if (hasErrors) throw new Error('Provider returned API errors');
  if (!Array.isArray(data.response)) throw new Error('Provider response payload missing');
  return data;
}

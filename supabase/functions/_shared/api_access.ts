// Public API access contract for FutBeat 1.0 (futbeat-api).
//
// Modes (FUTBEAT_API_ACCESS_MODE, read once per isolate):
//   open  (unset)  today's behaviour: no credential checked; limits by IP
//                  hash and globally.
//   dual           a user JWT is verified when present (guest or registered
//                  limits); requests without one are still served (IP and
//                  global limits). Migration step for installed apps.
//   user           every request needs a valid Supabase user JWT (anonymous
//                  guest or registered). The production target.
// Any other value is treated as `user`: a typo must never open the API.
//
// The JWT is verified by @supabase/server against the project's JWKS
// (asymmetric signing keys) and its issuer; a present-but-invalid token is
// rejected, never downgraded. Only `role: authenticated` tokens count as a
// user: service or anon keys are not identities.

export type AccessMode = 'open' | 'dual' | 'user';
export type IdentityKind = 'anonymous' | 'registered' | 'none';

export interface Identity {
  kind: IdentityKind;
  subject: string | null;
}

export function accessMode(value: string | undefined | null): AccessMode {
  const mode = (value ?? '').trim().toLowerCase();
  if (mode === '' || mode === 'open') return 'open';
  if (mode === 'dual') return 'dual';
  return 'user';
}

/** The @supabase/server `auth` option for a mode. */
export function authOption(mode: AccessMode): 'none' | 'user' | ['user', 'none'] {
  if (mode === 'open') return 'none';
  return mode === 'dual' ? ['user', 'none'] : 'user';
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Who is calling, from the verified context only. */
export function requestIdentity(ctx: {
  authMode?: string;
  jwtClaims?: Record<string, unknown> | null;
}): Identity {
  const claims = ctx.jwtClaims ?? null;
  if (ctx.authMode !== 'user' || !claims) return { kind: 'none', subject: null };
  const sub = typeof claims.sub === 'string' ? claims.sub.toLowerCase() : '';
  if (claims.role !== 'authenticated' || !UUID.test(sub)) return { kind: 'none', subject: null };
  return claims.is_anonymous === true
    ? { kind: 'anonymous', subject: `anon:${sub}` }
    : { kind: 'registered', subject: `user:${sub}` };
}

/** Client IP as the platform reports it (first X-Forwarded-For hop). */
export function clientIp(request: Request): string | null {
  const forwarded = request.headers.get('x-forwarded-for') ?? '';
  const first = forwarded.split(',')[0]?.trim() ||
    request.headers.get('cf-connecting-ip')?.trim() ||
    request.headers.get('x-real-ip')?.trim() || '';
  return /^[0-9a-fA-F:.]{2,45}$/.test(first) ? first.toLowerCase() : null;
}

/**
 * Salted SHA-256 of the IP (32 hex). Without a salt (>= 16 chars) no hash is
 * produced: an unsalted IPv4 hash is reversible by brute force.
 */
export async function ipHash(ip: string | null, salt: string | undefined | null): Promise<string | null> {
  if (!ip || !salt || salt.length < 16) return null;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}|${ip}`));
  return [...new Uint8Array(digest)].slice(0, 16).map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Admission cost of a route (search scans the catalog). */
export function routeCost(path: string): number {
  return path.endsWith('/v1/search') ? 2 : 1;
}

export const API_ROUTES = [
  '/v1/snapshot', '/v1/entity', '/v1/team-context', '/v1/team-matches', '/v1/explore',
  '/v1/search', '/v1/news', '/v1/match-summary', '/v1/favorites', '/v1/match-context',
  '/v1/match-preview', '/v1/standings-form', '/v1/match-h2h', '/v1/match-detail', '/v1/calendar',
];

export const isKnownRoute = (path: string) => API_ROUTES.some((route) => path.endsWith(`/futbeat-api${route}`));

/**
 * Last line of defence when the admission RPC is unavailable: a per-isolate
 * minute window per key. Coarse (each isolate counts alone) but bounded.
 */
export class IsolateLimiter {
  private windows = new Map<string, { minute: number; hits: number }>();
  private perMinute: number;
  private maxKeys: number;
  constructor(perMinute = 120, maxKeys = 5000) {
    this.perMinute = perMinute;
    this.maxKeys = maxKeys;
  }

  take(key: string, cost = 1, now = Date.now()): boolean {
    const minute = Math.floor(now / 60000);
    const current = this.windows.get(key);
    const hits = (current && current.minute === minute ? current.hits : 0) + cost;
    if (!current && this.windows.size >= this.maxKeys) this.prune(minute);
    this.windows.set(key, { minute, hits });
    return hits <= this.perMinute;
  }

  private prune(minute: number) {
    for (const [key, value] of this.windows) {
      if (value.minute !== minute) this.windows.delete(key);
    }
    if (this.windows.size >= this.maxKeys) this.windows.clear();
  }
}

export const unauthorized = () =>
  new Response(JSON.stringify({ error: 'Sesión requerida', code: 'SESSION_REQUIRED' }), {
    status: 401,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'WWW-Authenticate': 'Bearer realm="futbeat-api"',
    },
  });

export const throttled = (retryAfterSeconds: number, reason: string) =>
  new Response(JSON.stringify({ error: 'Demasiadas solicitudes', code: 'RATE_LIMITED', reason }), {
    status: 429,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'Retry-After': String(Math.max(1, Math.min(3600, Math.round(retryAfterSeconds)))),
    },
  });

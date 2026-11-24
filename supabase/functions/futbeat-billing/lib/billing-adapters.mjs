import { Buffer } from 'node:buffer';

// PREMIUM-PROD adapters (WebCrypto + fetch only, so the same code runs in Node tests and Supabase Edge/Deno).

// Supabase Auth: the project's own /auth/v1/user validates the session. Anonymous users cannot subscribe.
export function createSupabaseAuthenticator({ supabaseUrl, anonKey, fetchImpl = fetch }) {
  if (!supabaseUrl || !anonKey) throw new Error('Supabase Auth configuration incomplete');
  return async (bearer) => {
    const response = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${bearer}` },
      redirect: 'error', signal: AbortSignal.timeout(5000),
    });
    if (response.status !== 200) return null;
    const user = await response.json().catch(() => null);
    if (!user || typeof user.id !== 'string' || user.is_anonymous === true) return null;
    if (user.aud && user.aud !== 'authenticated') return null;
    return user.id;
  };
}

const b64url = (bytes) => Buffer.from(bytes).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const fromB64url = (text) => Buffer.from(text.replace(/-/g, '+').replace(/_/g, '/'), 'base64');

async function importPkcs8(pem) {
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64');
  return crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

// Google service account (JSON key held as an Edge secret) -> short-lived Android Publisher access token.
export function createServiceAccountTokenSource({
  json, scope = 'https://www.googleapis.com/auth/androidpublisher', fetchImpl = fetch, now = Date.now,
}) {
  const sa = typeof json === 'string' ? JSON.parse(json) : json;
  if (!sa?.client_email || !sa?.private_key) throw new Error('Service account key incomplete');
  let cached = null;
  let keyPromise = null;
  return async () => {
    if (cached && cached.until > now() + 60_000) return cached.token;
    keyPromise ??= importPkcs8(sa.private_key);
    const iat = Math.floor(now() / 1000);
    const header = b64url(Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
    const claims = b64url(Buffer.from(JSON.stringify({
      iss: sa.client_email, scope, aud: 'https://oauth2.googleapis.com/token', iat, exp: iat + 3600,
    })));
    const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', await keyPromise, Buffer.from(`${header}.${claims}`));
    const response = await fetchImpl('https://oauth2.googleapis.com/token', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${header}.${claims}.${b64url(signature)}`,
      }).toString(),
    });
    if (!response.ok) return null;
    const body = await response.json();
    if (typeof body.access_token !== 'string') return null;
    cached = { token: body.access_token, until: now() + Math.min(3600, Number(body.expires_in) || 0) * 1000 };
    return cached.token;
  };
}

// Pub/Sub push authentication (RTDN): Google-signed OIDC token for the configured push service account and
// audience (https://cloud.google.com/pubsub/docs/authenticate-push-subscriptions).
export function createPushVerifier({
  audience, serviceAccountEmail, fetchImpl = fetch, now = Date.now,
  certsUrl = 'https://www.googleapis.com/oauth2/v3/certs',
}) {
  if (!audience || !serviceAccountEmail) throw new Error('RTDN push verifier configuration incomplete');
  let jwks = null;
  async function key(kid) {
    if (!jwks || jwks.until < now()) {
      const response = await fetchImpl(certsUrl, { redirect: 'error', signal: AbortSignal.timeout(5000) });
      if (!response.ok) return null;
      jwks = { keys: (await response.json()).keys ?? [], until: now() + 3600_000 };
    }
    const jwk = jwks.keys.find((k) => k.kid === kid && k.kty === 'RSA');
    return jwk ? crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']) : null;
  }
  return async (authorization) => {
    try {
      const token = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(authorization ?? '')?.[1];
      if (!token) return false;
      const [h, c, s] = token.split('.');
      const header = JSON.parse(fromB64url(h).toString('utf8'));
      const claims = JSON.parse(fromB64url(c).toString('utf8'));
      if (header.alg !== 'RS256') return false;
      const k = await key(header.kid);
      if (!k || !await crypto.subtle.verify('RSASSA-PKCS1-v1_5', k, fromB64url(s), Buffer.from(`${h}.${c}`))) return false;
      const t = Math.floor(now() / 1000);
      return ['accounts.google.com', 'https://accounts.google.com'].includes(claims.iss)
        && claims.aud === audience && claims.email === serviceAccountEmail && claims.email_verified === true
        && Number(claims.exp) > t && Number(claims.iat ?? 0) <= t + 300;
    } catch {
      return false;
    }
  };
}

// ------------------------------------------------------------------------------------------------------
// PREMIUM-G2: keyless Google credential through Workload Identity Federation (no service-account key).
// Supabase Edge Functions have no Google-attached identity, so the function is its own OIDC issuer: it signs
// a 5-minute ES256 assertion with a P-256 key held as an Edge secret (the public JWK is UPLOADED to the WIF
// provider, nothing is published), exchanges it at Google STS for a federated token and impersonates the
// Play service account (iamcredentials generateAccessToken, androidpublisher scope only, 1 h).
// The signing key cannot reach any Google API by itself: the provider pins issuer, audience and subject
// (attribute condition), and only that principal holds roles/iam.serviceAccountTokenCreator on that one
// service account. Disabling the provider revokes everything at once; rotation = upload a second JWK.
//
// Lifecycle: cached in the isolate, refreshed EARLY (refreshBeforeMs, default 10 min before expiry) with a
// single in-flight refresh per isolate; a failed refresh keeps serving the still-valid token; with no valid
// token the source returns null (the Publisher call then fails as "unavailable": never a revocation) and
// backs off exponentially (5 s .. 5 min). invalidate() is called on a Publisher 401.
const STS = 'https://sts.googleapis.com/v1/token';
const IAM = 'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts';

async function importSigningKey(jwk) {
  const key = typeof jwk === 'string' ? JSON.parse(jwk) : jwk;
  if (key?.kty !== 'EC' || key.crv !== 'P-256' || !key.d || !key.kid) {
    throw new Error('Federation signing key must be a P-256 private JWK with kid');
  }
  const cryptoKey = await crypto.subtle.importKey('jwk', { kty: key.kty, crv: key.crv, x: key.x, y: key.y, d: key.d },
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  return { kid: key.kid, cryptoKey };
}

export function createFederatedTokenSource({
  signingJwk, issuer, subject, audience, serviceAccountEmail,
  scope = 'https://www.googleapis.com/auth/androidpublisher', lifetimeSeconds = 3600,
  refreshBeforeMs = 10 * 60_000, fetchImpl = fetch, now = Date.now, log = () => {},
}) {
  if (!signingJwk || !issuer || !subject || !audience || !serviceAccountEmail) throw new Error('Federation configuration incomplete');
  if (!/^\/\/iam\.googleapis\.com\/projects\/\d+\/locations\/global\/workloadIdentityPools\/[a-z0-9-]+\/providers\/[a-z0-9-]+$/.test(audience)) {
    throw new Error('Federation audience must be the full WIF provider resource');
  }
  if (!/^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$/.test(serviceAccountEmail)) throw new Error('Invalid service account');
  const jwk = typeof signingJwk === 'string' ? JSON.parse(signingJwk) : signingJwk;
  if (jwk?.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.d || !jwk.kid) throw new Error('Federation signing key must be a P-256 private JWK with kid');
  let keyPromise = null;
  let cached = null;           // { token, until }
  let inflight = null;
  let failures = 0; let retryAt = 0;
  const state = { lastError: null, refreshes: 0, failures: 0 };

  async function assertion() {
    keyPromise ??= importSigningKey(jwk);
    const { kid, cryptoKey } = await keyPromise;
    const iat = Math.floor(now() / 1000);
    const head = b64url(Buffer.from(JSON.stringify({ alg: 'ES256', typ: 'JWT', kid })));
    // JWT aud = the provider URL (https:), STS audience = the provider resource (//): Google WIF defaults.
    const body = b64url(Buffer.from(JSON.stringify({ iss: issuer, sub: subject, aud: `https:${audience}`, iat, exp: iat + 300 })));
    const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, cryptoKey, Buffer.from(`${head}.${body}`));
    return `${head}.${body}.${b64url(sig)}`;   // WebCrypto ECDSA output is already JOSE (r||s)
  }
  async function post(url, init, what) {
    const response = await fetchImpl(url, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000), ...init });
    const json = await response.json().catch(() => ({}));
    if (!response.ok) {
      const reason = typeof json?.error === 'string' ? json.error : json?.error?.status ?? null;
      throw Object.assign(new Error(`${what} ${response.status}`), { reason });
    }
    return json;
  }
  async function refresh() {
    const sts = await post(STS, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange', audience,
        scope: 'https://www.googleapis.com/auth/cloud-platform',
        requested_token_type: 'urn:ietf:params:oauth:token-type:access_token',
        subject_token_type: 'urn:ietf:params:oauth:token-type:jwt', subject_token: await assertion(),
      }).toString(),
    }, 'sts');
    if (typeof sts.access_token !== 'string') throw new Error('sts: no token');
    const iam = await post(`${IAM}/${encodeURIComponent(serviceAccountEmail)}:generateAccessToken`, {
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${sts.access_token}` },
      body: JSON.stringify({ scope: [scope], lifetime: `${lifetimeSeconds}s` }),
    }, 'iamcredentials');
    const until = Date.parse(iam.expireTime);
    if (typeof iam.accessToken !== 'string' || !(until > now() + 60_000)) throw new Error('iamcredentials: bad token');
    return { token: iam.accessToken, until };
  }
  const valid = (c, marginMs) => c && c.until > now() + marginMs;

  async function get() {
    if (valid(cached, refreshBeforeMs)) return cached.token;
    if (now() < retryAt) return valid(cached, 60_000) ? cached.token : null;
    inflight ??= refresh().then((fresh) => {
      cached = fresh; failures = 0; retryAt = 0; state.refreshes++; state.lastError = null;
    }, (error) => {
      failures++; state.failures++;
      retryAt = now() + Math.min(300_000, 5_000 * 2 ** (failures - 1));
      state.lastError = `${error.message}${error.reason ? ` (${error.reason})` : ''}`.slice(0, 120);
      log('play credential refresh failed', state.lastError);   // never the assertion or a token
    }).finally(() => { inflight = null; });
    await inflight;
    return valid(cached, 60_000) ? cached.token : null;
  }
  get.invalidate = () => { cached = null; retryAt = 0; };
  get.status = () => ({
    ...state, cached: Boolean(cached), expiresInS: cached ? Math.max(0, Math.round((cached.until - now()) / 1000)) : 0,
    backoffS: Math.max(0, Math.round((retryAt - now()) / 1000)),
  });
  return get;
}

// Publisher fetch with one retry after a 401: the cached Google token is dropped and re-minted once.
export function createPublisherFetch({ accessToken, fetchImpl = fetch }) {
  return async (url, init = {}) => {
    const first = await fetchImpl(url, init);
    if (first.status !== 401 || typeof accessToken.invalidate !== 'function') return first;
    accessToken.invalidate();
    const fresh = await accessToken();
    if (!fresh) return first;
    return fetchImpl(url, { ...init, headers: { ...(init.headers ?? {}), Authorization: `Bearer ${fresh}` } });
  };
}

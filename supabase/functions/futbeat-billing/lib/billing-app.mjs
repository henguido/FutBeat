import { Buffer } from 'node:buffer';
import { timingSafeEqual } from 'node:crypto';

// PREMIUM-PROD HTTP contract v1 (extends the Codex release handler; same paths, statuses and bodies, so the
// Android Billing QA transport keeps working). Mounted as the Supabase Edge Function `futbeat-billing`:
//   GET  /billing/v1/entitlement            Bearer <Supabase session>  -> authoritative state
//   POST /billing/v1/verify   {token}       Bearer <Supabase session>  -> verify one Play purchase token
//   POST /billing/v1/restore  {tokens:[..]} Bearer <Supabase session>  -> verify up to 10 tokens (Play restore)
//   POST /billing/v1/rtdn     Pub/Sub push (OIDC JWT)                  -> recheck a known token now
//   POST /billing/v1/cron     x-futbeat-billing-cron                   -> acknowledgements + reconciliation
export const CONTRACT_VERSION = 1;
const codes = { rejected: 403, unavailable: 503, limited: 429, active: 200, inactive: 200 };

function equalSecret(a, b) {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length > 0 && x.length === y.length && timingSafeEqual(x, y);
}

async function readJson(request, limit = 8192) {
  if (request.headers.get('content-type')?.split(';')[0].trim() !== 'application/json' || !request.body) return null;
  let bytes = 0;
  const chunks = [];
  for await (const chunk of request.body) {
    bytes += chunk.byteLength;
    if (bytes > limit) return { tooLarge: true };
    chunks.push(chunk);
  }
  try {
    return { body: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))) };
  } catch {
    return null;
  }
}

export function createBillingApp({
  service, authenticate, intakeEnabled, cronToken, rtdn = { enabled: false }, log = () => {},
  allowRequest = async () => true, credentialStatus = null,
}) {
  const reply = (status, body) => Response.json({ version: CONTRACT_VERSION, ...body }, {
    status, headers: { 'Cache-Control': 'no-store' },
  });
  const publicState = (result) => ({
    status: Object.hasOwn(codes, result.status) ? result.status : 'unavailable',
    ...(result.status === 'active' ? { expiresAt: result.expiresAt, paidUntil: result.paidUntil, plan: result.plan } : {}),
  });
  return async (request) => {
    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/(functions\/v1\/)?futbeat-billing(?=\/)/, '');
    const proto = request.headers.get('x-forwarded-proto');
    if ((proto && proto !== 'https') || url.search) return reply(400, { status: 'invalid_request' });
    const route = `${request.method} ${path}`;
    try {
      if (route === 'POST /billing/v1/cron') {
        if (!equalSecret(request.headers.get('x-futbeat-billing-cron'), cronToken)) return reply(403, { status: 'forbidden' });
        let acks = 0;
        while (acks < 10) {
          let more;
          try { more = await service.drainAcknowledgements(); } catch { acks++; continue; }
          if (!more) break;
          acks++;
        }
        const rechecks = await service.reconcileDue(20);
        // G2: the cron reply (kept by pg_net) carries the Google credential health, never a token.
        const credential = credentialStatus ? await credentialStatus() : undefined;
        return reply(200, { status: 'ok', acknowledgements: acks, rechecks, ...(credential ? { credential } : {}) });
      }
      if (route === 'POST /billing/v1/rtdn') {
        if (!rtdn.enabled) return reply(404, { status: 'not_found' });
        if (!await rtdn.verifyPush(request.headers.get('authorization'))) return reply(401, { status: 'unauthorized' });
        const parsed = await readJson(request, 65536);
        const data = parsed?.body?.message?.data;
        let note = null;
        try { note = JSON.parse(Buffer.from(String(data ?? ''), 'base64').toString('utf8')); } catch { /* ack bad payloads */ }
        if (note?.packageName && note.packageName !== 'com.futbeat.futbeat') return reply(200, { status: 'ignored' });
        const token = note?.subscriptionNotification?.purchaseToken ?? note?.voidedPurchaseNotification?.purchaseToken;
        if (typeof token !== 'string' || !token || token.length > 4096) return reply(200, { status: 'ignored' });
        const result = await service.notify(token);
        // 'deferred' (Play unavailable) is retried by the cron; Pub/Sub must not redeliver forever.
        return reply(200, { status: result.status });
      }
      const read = route === 'GET /billing/v1/entitlement';
      const verify = route === 'POST /billing/v1/verify';
      const restore = route === 'POST /billing/v1/restore';
      if (!read && !verify && !restore) return reply(404, { status: 'not_found' });
      const bearer = /^Bearer ([^\s]+)$/.exec(request.headers.get('Authorization') ?? '')?.[1];
      const account = bearer && await authenticate(bearer);
      if (!account) return reply(401, { status: 'unauthorized' });
      if (read) return reply(200, { ...publicState(await service.entitlement(account)), purchasesEnabled: intakeEnabled() === true });
      if (!await allowRequest(account)) return reply(429, { status: 'limited' });
      const parsed = await readJson(request);
      if (parsed?.tooLarge) return reply(413, { status: 'invalid_request' });
      const body = parsed?.body;
      if (verify) {
        const token = body && Object.keys(body).length === 1 ? body.token : undefined;
        if (typeof token !== 'string' || !token.trim() || token.length > 4096) return reply(400, { status: 'invalid_request' });
        // Existing tokens stay reconcilable while intake is off; new ones need intake.
        const result = await service.verify(account, token, { allowNew: intakeEnabled() === true });
        return reply(codes[result.status] ?? 503, publicState(result));
      }
      const tokens = body && Object.keys(body).length === 1 ? body.tokens : undefined;
      if (!Array.isArray(tokens) || tokens.length === 0 || tokens.length > 10 ||
          tokens.some((t) => typeof t !== 'string' || !t.trim() || t.length > 4096)) {
        return reply(400, { status: 'invalid_request' });
      }
      const outcomes = [];
      for (const token of [...new Set(tokens)]) {
        try { outcomes.push((await service.verify(account, token, { allowNew: intakeEnabled() === true })).status); }
        catch { outcomes.push('unavailable'); }
      }
      const state = await service.entitlement(account);
      return reply(200, { ...publicState(state), restored: outcomes.filter((s) => s === 'active').length,
        rejected: outcomes.filter((s) => s === 'rejected').length, purchasesEnabled: intakeEnabled() === true });
    } catch (error) {
      log('billing request failed', route, error instanceof Error ? error.message.slice(0, 120) : 'unknown');
      return reply(503, { status: 'unavailable' });
    }
  };
}

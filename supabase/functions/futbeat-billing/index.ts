// PREMIUM-PROD: Supabase Edge Function `futbeat-billing` (NOT deployed). Deploy with verify_jwt=false: user
// routes authenticate the Supabase session themselves (/auth/v1/user, non-anonymous), RTDN uses Google OIDC,
// the cron uses its own secret. All billing state lives in billing_private (Postgres, never exposed to clients).
//
// Secrets (Supabase function secrets; never in the app, the repo or logs):
//   FUTBEAT_PLAY_WIF_KEY / _AUDIENCE, FUTBEAT_PLAY_SA   G2 keyless federation (recommended; see below)
//   FUTBEAT_PLAY_SA_JSON          legacy: service account key with Play access limited to com.futbeat.futbeat
//   FUTBEAT_PLAY_ACCESS_TOKEN     (qa only, instead of the key) short-lived impersonated token, <= 1 h
//                                 (view financial data + manage orders and subscriptions; no publishing)
//   FUTBEAT_PREMIUM_TOKEN_KEYS    {"v1":"<base64 32 bytes>", ...}; FUTBEAT_PREMIUM_TOKEN_KEY_CURRENT=v1
//   FUTBEAT_BILLING_CRON_TOKEN    random >= 32 chars, also stored in Vault for the pg_cron job
//   FUTBEAT_PREMIUM_ENVIRONMENT   qa | production   (production rejects Play license-test purchases)
//   FUTBEAT_PREMIUM_INTAKE        on | off          (off: no NEW purchases accepted; existing ones still reconcile)
//   FUTBEAT_PREMIUM_RTDN          on | off; FUTBEAT_RTDN_AUDIENCE, FUTBEAT_RTDN_PUSH_SA (only when on)
//   FUTBEAT_PUBLISHER_PER_MINUTE  integer (default 600; Google standard quota 3,000/min per bucket)
// Provided by the platform: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_DB_URL.
import { Buffer } from "node:buffer";
import postgres from "npm:postgres@3.4.5";
import { createBillingApp } from "./lib/billing-app.mjs";
import {
  createFederatedTokenSource, createPublisherFetch, createPushVerifier, createServiceAccountTokenSource, createSupabaseAuthenticator,
} from "./lib/billing-adapters.mjs";
import { createPremiumReleasePublisher, createPublisherBudget } from "./lib/premium-play-api.mjs";
import { createPremiumReleaseService } from "./lib/premium-release-service.mjs";
import { createPremiumTokenVault } from "./lib/premium-token-vault.mjs";

const env = (name: string) => (Deno.env.get(name) ?? "").trim();
const supabaseUrl = env("SUPABASE_URL");
// One short-lived connection per isolate through the Supabase pooler (transaction mode: no prepared statements).
const sql = postgres(env("SUPABASE_DB_URL"), { max: 1, prepare: false, idle_timeout: 20, connect_timeout: 10 });
const db = {
  async query(text: string, params: unknown[] = []) {
    return { rows: await sql.unsafe(text, params as never[]) };
  },
};

const keyMap = JSON.parse(env("FUTBEAT_PREMIUM_TOKEN_KEYS") || "{}") as Record<string, string>;
const keys = new Map(Object.entries(keyMap).map(([version, b64]) => [version, createPremiumTokenVault({
  key: Buffer.from(b64, "base64"), authOrigin: supabaseUrl, packageName: "com.futbeat.futbeat",
})]));
const environment = env("FUTBEAT_PREMIUM_ENVIRONMENT");
const perMinute = Number(env("FUTBEAT_PUBLISHER_PER_MINUTE") || "600");

// Google credential, in order of preference:
//   G2 (keyless, recommended): Workload Identity Federation. FUTBEAT_PLAY_WIF_KEY (private P-256 JWK, the
//      public half is uploaded to the WIF provider), FUTBEAT_PLAY_WIF_AUDIENCE (//iam.googleapis.com/projects/
//      <n>/locations/global/workloadIdentityPools/<pool>/providers/<provider>), FUTBEAT_PLAY_SA (service account
//      to impersonate). Issuer and subject are fixed per environment: futbeat-billing:<environment>.
//   legacy: FUTBEAT_PLAY_SA_JSON service-account key (only if the WIF route is refused).
//   G1 only: FUTBEAT_PLAY_ACCESS_TOKEN, an operator-issued token (<= 1 h), qa only.
const wifKey = env("FUTBEAT_PLAY_WIF_KEY");
const saJson = env("FUTBEAT_PLAY_SA_JSON");
const wifSa = env("FUTBEAT_PLAY_SA");
const playEmail = wifKey ? wifSa : saJson ? String(JSON.parse(saJson).client_email ?? "") : "";
// Separation: production never runs on the QA identity nor on an operator token; QA never on a production one.
if (environment === "production" && (!playEmail || /-qa@/.test(playEmail) || env("FUTBEAT_PLAY_ACCESS_TOKEN"))) {
  throw new Error("Production billing requires the dedicated production service account");
}
if (environment === "qa" && playEmail && !/-qa@/.test(playEmail)) {
  throw new Error("QA billing must use the QA service account");
}
const accessToken = wifKey
  ? createFederatedTokenSource({
    signingJwk: wifKey, audience: env("FUTBEAT_PLAY_WIF_AUDIENCE"), serviceAccountEmail: wifSa,
    issuer: `https://futbeat.com/billing-wif/${environment}`, subject: `futbeat-billing:${environment}`,
    // QA validation window only: a shorter Google token (900..3600 s) so real automatic renewals are observed
    // within minutes. Production always uses 3600 s.
    lifetimeSeconds: environment === "qa"
      ? Math.min(3600, Math.max(900, Number(env("FUTBEAT_PLAY_TOKEN_LIFETIME_S") || "3600")))
      : 3600,
    log: (...a: unknown[]) => console.error(...a),
  })
  : saJson
  ? createServiceAccountTokenSource({ json: saJson })
  : async () => (environment === "qa" && env("FUTBEAT_PLAY_ACCESS_TOKEN")) || null;
const publisher = createPremiumReleasePublisher({
  environment,
  accessToken,
  fetchImpl: createPublisherFetch({ accessToken }),
  budget: createPublisherBudget(db, perMinute),
});
// The cron route warms the credential (cached: a Google call only when a refresh is due), so its health is
// proven every run even when no purchase needs Play.
const credentialStatus = async () => {
  let ready = false;
  try { ready = Boolean(await accessToken()); } catch { ready = false; }
  return {
    mode: wifKey ? "wif" : saJson ? "sa-key" : env("FUTBEAT_PLAY_ACCESS_TOKEN") ? "operator-token" : "none",
    ready,
    ...((accessToken as { status?: () => Record<string, unknown> }).status?.() ?? {}),
  };
};
const service = createPremiumReleaseService({
  db, publisher, issuer: `${supabaseUrl}/auth/v1`, keys, currentKey: env("FUTBEAT_PREMIUM_TOKEN_KEY_CURRENT"), environment,
});
const rtdnOn = env("FUTBEAT_PREMIUM_RTDN") === "on";
const app = createBillingApp({
  service,
  authenticate: createSupabaseAuthenticator({ supabaseUrl, anonKey: env("SUPABASE_ANON_KEY") }),
  intakeEnabled: () => env("FUTBEAT_PREMIUM_INTAKE") === "on",
  cronToken: env("FUTBEAT_BILLING_CRON_TOKEN"),
  rtdn: rtdnOn
    ? { enabled: true, verifyPush: createPushVerifier({ audience: env("FUTBEAT_RTDN_AUDIENCE"), serviceAccountEmail: env("FUTBEAT_RTDN_PUSH_SA") }) }
    : { enabled: false },
  log: (...a: unknown[]) => console.error(...a),
  credentialStatus,
  allowRequest: async (account: string) =>
    (await db.query("SELECT billing_private.allow_request($1, $2) AS ok", [account, Number(env("FUTBEAT_BILLING_PER_ACCOUNT_MINUTE") || "10")])).rows[0].ok === true,
});

Deno.serve(app);

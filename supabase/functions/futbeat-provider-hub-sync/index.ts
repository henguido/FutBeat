// Provider Hub secondary worker (#102 Phase 1B).
//
// Internal only. Same auth pattern as futbeat-goal-live-sync: deployed with
// verify_jwt=false (see supabase/config.toml) because the caller does not
// send a user JWT; every request must carry the stored internal
// `x-futbeat-cron-token`, compared in constant time before anything runs.
// POST only, small bounded JSON body, no query parameters honored.
//
// dryRun defaults to true: routing, quota decision and mapping are computed
// with read-only RPCs and NO provider request, ledger row or write happens;
// it also works while the provider is disabled (reported as such). With
// dryRun=false nothing is spent while provider_hub_config keeps the provider
// disabled. No cron or workflow calls this function.
//
// Supersedes the legacy, unscheduled futbeat-live-sync / futbeat-fixtures-sync.
import {
  WorkerInputError,
  parseWorkerInput,
  runProviderHubWork,
} from "../../../backend/providers/hub_worker.mjs";
import { createApiFootballProvider } from "../../../backend/providers/api_football.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MAX_BODY_BYTES = 2048;

const rpc = async (name: string, body: unknown = {}) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`RPC ${name} failed: ${response.status}`);
  }
  return text ? JSON.parse(text) : null;
};

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

async function secureEqual(left: string, right: string) {
  if (!left || !right) return false;
  const [a, b] = await Promise.all([sha256Hex(left), sha256Hex(right)]);
  return a === b;
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  let expected = "";
  try {
    expected = String(await rpc("futbeat_read_goal_live_cron_token") ?? "")
      .trim();
  } catch {
    return Response.json({ error: "Unavailable" }, { status: 503 });
  }
  const supplied = String(request.headers.get("x-futbeat-cron-token") ?? "")
    .trim();
  if (expected.length < 32 || !(await secureEqual(expected, supplied))) {
    return Response.json({ error: "Forbidden" }, { status: 403 });
  }

  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return Response.json({ error: "Body too large" }, { status: 413 });
  }
  let input;
  try {
    input = parseWorkerInput(JSON.parse(raw || "{}"));
  } catch (error) {
    const message = error instanceof WorkerInputError
      ? error.message
      : "Invalid JSON";
    return Response.json({ error: message }, { status: 400 });
  }

  try {
    const result = await runProviderHubWork(input, {
      rpc,
      // Existing backend secret name; read only when executing, never logged
      // or returned.
      readApiKey: async () => Deno.env.get("FUTBEAT_API_FOOTBALL_KEY") ?? "",
      createProvider: (
        { apiKey, budget }: { apiKey: string; budget: unknown },
      ) =>
        (createApiFootballProvider as (
          options: Record<string, unknown>,
        ) => unknown)({ apiKey, budget }),
    });
    return Response.json(result);
  } catch (error) {
    console.error(
      "provider hub worker failed",
      error instanceof Error ? error.message.slice(0, 200) : "unknown",
    );
    return Response.json({ error: "Provider hub worker failed" }, {
      status: 500,
    });
  }
});

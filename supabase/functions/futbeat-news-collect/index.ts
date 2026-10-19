// News collector v2 (#104). Internal only, same auth pattern as
// futbeat-provider-hub-sync: verify_jwt=false (see supabase/config.toml),
// every request must carry the stored internal `x-futbeat-cron-token`,
// compared in constant time before anything runs. POST {mode, dryRun}.
//
// dryRun defaults to true. Providers and feeds ship disabled
// (news_provider_config / news_feeds), so even dryRun=false spends nothing
// until an operator enables one after reviewing its terms. Not scheduled:
// no cron or workflow calls this function. The mobile app never calls it.
import {
  CollectorInputError,
  parseCollectorInput,
  runNewsCollector,
} from "../_shared/news_collector.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MAX_BODY_BYTES = 512;

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
  if (!response.ok) throw new Error(`RPC ${name} failed: ${response.status}`);
  return text ? JSON.parse(text) : null;
};

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
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
    expected = String(await rpc("futbeat_read_goal_live_cron_token") ?? "").trim();
  } catch {
    return Response.json({ error: "Unavailable" }, { status: 503 });
  }
  const supplied = String(request.headers.get("x-futbeat-cron-token") ?? "").trim();
  if (expected.length < 32 || !(await secureEqual(expected, supplied))) {
    return Response.json({ error: "Forbidden" }, { status: 403 });
  }
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) return Response.json({ error: "Body too large" }, { status: 413 });
  let input;
  try {
    input = parseCollectorInput(JSON.parse(raw || "{}"));
  } catch (error) {
    const message = error instanceof CollectorInputError ? error.message : "Invalid JSON";
    return Response.json({ error: message }, { status: 400 });
  }
  try {
    const result = await runNewsCollector(input, {
      rpc,
      fetch: (target, init) => fetch(target, init),
      // Backend-only secret (#104); read only when executing, never logged
      // or returned.
      currentsKey: Deno.env.get("FUTBEAT_CURRENTS_API_KEY") ?? "",
    });
    return Response.json(result);
  } catch (error) {
    console.error("news collector failed", error instanceof Error ? error.message.slice(0, 200) : "unknown");
    return Response.json({ error: "News collector failed" }, { status: 500 });
  }
});

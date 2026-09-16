import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), {
  status,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  },
});

function authorized(req: Request) {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const auth = req.headers.get("authorization") ?? "";

  let defaultSecret = "";
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    defaultSecret = typeof keys.default === "string" ? keys.default : "";
  } catch {
    defaultSecret = "";
  }

  const apikey = req.headers.get("apikey") ?? "";
  return (legacy && auth === `Bearer ${legacy}`) || (defaultSecret && apikey === defaultSecret);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  if (!authorized(req)) return json(403, { error: "Forbidden" });

  const apiKey = Deno.env.get("FUTBEAT_API_FOOTBALL_KEY");
  if (!apiKey) return json(503, { error: "Provider not configured" });

  try {
    const upstream = await fetch("https://v3.football.api-sports.io/fixtures?live=all", {
      method: "GET",
      headers: {
        "x-apisports-key": apiKey,
        accept: "application/json",
      },
      signal: AbortSignal.timeout(15000),
    });

    const remaining = upstream.headers.get("x-ratelimit-requests-remaining");
    const payload = await upstream.json();

    if (!upstream.ok) {
      return json(502, {
        error: `API-Football HTTP ${upstream.status}`,
        remaining,
      });
    }
    if (!payload || !Array.isArray(payload.response)) {
      return json(502, { error: "Invalid provider response", remaining });
    }

    return json(200, {
      provider: "api_football",
      ok: true,
      liveMatches: payload.response.length,
      remaining,
      checkedAt: new Date().toISOString(),
    });
  } catch {
    return json(502, { error: "Provider request failed" });
  }
});

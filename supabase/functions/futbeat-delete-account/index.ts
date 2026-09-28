import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (status: number, body: unknown) =>
  Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });

function defaultSecret() {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}

function jwtSubject(authorization: string) {
  try {
    const token = authorization.replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1]?.replace(/-/g, "+").replace(/_/g, "/");
    if (!part) return null;
    const payload = JSON.parse(atob(part.padEnd(Math.ceil(part.length / 4) * 4, "=")));
    const subject = typeof payload.sub === "string" ? payload.sub : "";
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(subject)
      ? subject
      : null;
  } catch {
    return null;
  }
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") return json(405, { error: "Method not allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const secret = defaultSecret();
  const authorization = request.headers.get("authorization") ?? "";
  const subject = jwtSubject(authorization);
  if (!supabaseUrl || !secret) return json(503, { error: "Account deletion unavailable" });
  if (!subject || !authorization.startsWith("Bearer ")) {
    return json(401, { error: "Authentication required" });
  }

  const adminHeaders = { apikey: secret, authorization: `Bearer ${secret}` };
  const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: secret, authorization },
    signal: AbortSignal.timeout(10000),
  });

  if (!userResponse.ok) {
    // The gateway has already verified the JWT. A retry after a successful
    // deletion no longer resolves /user; only return success if Admin confirms
    // that this same JWT subject is already absent.
    const existing = await fetch(`${supabaseUrl}/auth/v1/admin/users/${subject}`, {
      headers: adminHeaders,
      signal: AbortSignal.timeout(10000),
    });
    if (existing.status === 404) return json(200, { deleted: true, alreadyDeleted: true });
    return json(401, { error: "Authentication required" });
  }

  const user = await userResponse.json();
  if (user?.id !== subject) return json(403, { error: "Forbidden" });

  const deletion = await fetch(`${supabaseUrl}/auth/v1/admin/users/${subject}`, {
    method: "DELETE",
    headers: adminHeaders,
    signal: AbortSignal.timeout(10000),
  });
  if (deletion.status === 404) return json(200, { deleted: true, alreadyDeleted: true });
  if (!deletion.ok) return json(503, { error: "Account deletion unavailable" });
  return json(200, { deleted: true });
});

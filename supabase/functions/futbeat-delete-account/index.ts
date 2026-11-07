import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Self-service account deletion. The target is always the verified JWT
// subject (JWT verification stays enabled at the gateway); deleting the Auth
// record cascades to every per-user table.
//
// R05 (FutBeat 1.0): with X-FutBeat-Deletion-Id (a UUID v4 the app stored
// before calling) the deletion leaves a durable receipt the app can query
// later without a session (public.futbeat_account_deletion_status). The
// receipt is written BEFORE anything is deleted: if it cannot be written the
// account is not deleted (503, safe to retry with the same id). Without the
// header the behaviour is exactly the previous one (installed APKs).
// Contract: packages/contracts/account-deletion-v1.md.
//
// BE11-A5: a receipt that holds a live uid is only written after Auth itself
// (/auth/v1/user) has accepted the token, never from the unverified JWT
// payload alone. The gateway check stays on; this keeps the function safe
// even if it were deployed with --no-verify-jwt.

const json = (status: number, body: unknown) =>
  Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
    return UUID.test(subject) ? subject : null;
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

  const rawId = request.headers.get("x-futbeat-deletion-id");
  if (rawId !== null && !UUID.test(rawId.trim())) {
    return json(400, { error: "Invalid deletion id", code: "INVALID_DELETION_ID" });
  }
  const deletionId = rawId === null ? null : rawId.trim().toLowerCase();

  const adminHeaders = { apikey: secret, authorization: `Bearer ${secret}` };
  const receipt = async (fn: "begin" | "finish"): Promise<string | null> => {
    try {
      const response = await fetch(`${supabaseUrl}/rest/v1/rpc/futbeat_account_deletion_${fn}`, {
        method: "POST",
        headers: { ...adminHeaders, "content-type": "application/json" },
        body: JSON.stringify({ p_deletion_id: deletionId, p_subject: subject }),
        signal: AbortSignal.timeout(10000),
      });
      if (!response.ok) return null;
      const body = await response.json();
      return typeof body?.status === "string" ? body.status : null;
    } catch {
      return null;
    }
  };
  const deleted = async (alreadyDeleted: boolean) => {
    if (deletionId !== null) await receipt("finish"); // best effort: status() also completes it
    return json(200, {
      deleted: true,
      ...(alreadyDeleted ? { alreadyDeleted: true } : {}),
      ...(deletionId !== null ? { deletionId } : {}),
    });
  };

  const conflict = () => json(409, { error: "Deletion id already used", code: "DELETION_ID_CONFLICT" });

  const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: secret, authorization },
    signal: AbortSignal.timeout(10000),
  });

  if (!userResponse.ok) {
    // A retry after a successful deletion no longer resolves /user; only
    // return success if Admin confirms that this same JWT subject is already
    // absent. The receipt written here names a uid that no longer exists, so
    // it can never hold a live account's uid.
    const existing = await fetch(`${supabaseUrl}/auth/v1/admin/users/${subject}`, {
      headers: adminHeaders,
      signal: AbortSignal.timeout(10000),
    });
    if (existing.status !== 404) return json(401, { error: "Authentication required" });
    if (deletionId !== null && await receipt("begin") === "conflict") return conflict();
    return deleted(true);
  }

  const user = await userResponse.json();
  if (user?.id !== subject) return json(403, { error: "Forbidden" });

  if (deletionId !== null) {
    const state = await receipt("begin");
    if (state === null) return json(503, { error: "Account deletion unavailable", code: "RECEIPT_UNAVAILABLE" });
    if (state === "conflict") return conflict();
    if (state === "deleted") return json(200, { deleted: true, alreadyDeleted: true, deletionId });
  }

  const deletion = await fetch(`${supabaseUrl}/auth/v1/admin/users/${subject}`, {
    method: "DELETE",
    headers: adminHeaders,
    signal: AbortSignal.timeout(10000),
  });
  if (deletion.status === 404) return deleted(true);
  if (!deletion.ok) return json(503, { error: "Account deletion unavailable" });
  return deleted(false);
});

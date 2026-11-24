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
//
// BE12-D: only an explicit "user_not_found" from Auth (a token Auth verified
// whose user is gone) takes the already-deleted path; a forged, expired or
// otherwise rejected token is 401 and touches nothing. An Auth outage is 503,
// never 401. A DELETE whose outcome is unknown (timeout, network) is 202 when
// a receipt exists: the app reads the outcome from the status RPC.

const json = (status: number, body: unknown) =>
  Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });

// fetch that never throws: a timeout or network error is null.
async function call(url: string, init: RequestInit): Promise<Response | null> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(10000) });
  } catch {
    return null;
  }
}

// GoTrue answers a valid token whose user no longer exists with
// error_code "user_not_found" (body and X-Sb-Error-Code header).
async function authErrorCode(response: Response) {
  const header = response.headers.get("x-sb-error-code");
  if (header) return header;
  try {
    const body = await response.json();
    return typeof body?.error_code === "string" ? body.error_code : "";
  } catch {
    return "";
  }
}

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
    const response = await call(`${supabaseUrl}/rest/v1/rpc/futbeat_account_deletion_${fn}`, {
      method: "POST",
      headers: { ...adminHeaders, "content-type": "application/json" },
      body: JSON.stringify({ p_deletion_id: deletionId, p_subject: subject }),
    });
    if (!response?.ok) return null;
    try {
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
  const unavailable = (code: string) => json(503, { error: "Account deletion unavailable", code });
  const unauthenticated = () => json(401, { error: "Authentication required" });

  const userResponse = await call(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: secret, authorization },
  });
  if (userResponse === null || userResponse.status >= 500) return unavailable("AUTH_UNAVAILABLE");

  if (!userResponse.ok) {
    // A retry after a successful deletion no longer resolves /user. Only an
    // Auth-verified token whose user is gone (user_not_found) may continue,
    // and only if Admin confirms that this same JWT subject is absent. The
    // receipt written here names a uid that no longer exists, so it can never
    // hold a live account's uid.
    if (await authErrorCode(userResponse) !== "user_not_found") return unauthenticated();
    const existing = await call(`${supabaseUrl}/auth/v1/admin/users/${subject}`, { headers: adminHeaders });
    if (existing === null || existing.status >= 500) return unavailable("AUTH_UNAVAILABLE");
    if (existing.status !== 404) return unauthenticated();
    if (deletionId !== null && await receipt("begin") === "conflict") return conflict();
    return deleted(true);
  }

  const user = await userResponse.json();
  if (user?.id !== subject) return json(403, { error: "Forbidden" });

  if (deletionId !== null) {
    const state = await receipt("begin");
    if (state === null) return unavailable("RECEIPT_UNAVAILABLE");
    if (state === "conflict") return conflict();
    if (state === "deleted") return json(200, { deleted: true, alreadyDeleted: true, deletionId });
  }

  const deletion = await call(`${supabaseUrl}/auth/v1/admin/users/${subject}`, {
    method: "DELETE",
    headers: adminHeaders,
  });
  if (deletion === null) {
    // Outcome unknown (timeout or network): the account may be gone. With a
    // receipt the app asks futbeat_account_deletion_status; without one the
    // previous answer (503, retry) stays.
    if (deletionId === null) return json(503, { error: "Account deletion unavailable" });
    return json(202, { deleted: false, pending: true, deletionId, code: "DELETION_PENDING" });
  }
  if (deletion.status === 404) return deleted(true);
  if (!deletion.ok) {
    return deletionId === null
      ? json(503, { error: "Account deletion unavailable" })
      : unavailable("DELETION_FAILED");
  }
  return deleted(false);
});

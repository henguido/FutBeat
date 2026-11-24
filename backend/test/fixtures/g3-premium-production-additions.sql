-- PREMIUM-PROD additions on top of the Codex ledger (premium-production-ledger.sql, unchanged).
-- Audit trail (no token, no PII beyond the account id), RTDN recheck, account erasure.
CREATE TABLE billing_private.events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  token_hash bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  account_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('purchase','recheck','replacement','rtdn','forget')),
  play_state text,
  result text
);
ALTER TABLE billing_private.events ENABLE ROW LEVEL SECURITY;
CREATE INDEX events_account ON billing_private.events (account_id, at);

CREATE FUNCTION billing_private.note_event(hash bytea, account uuid, kind text, play_state text, result text)
RETURNS void LANGUAGE sql SET search_path = pg_catalog AS $$
  INSERT INTO billing_private.events(token_hash, account_id, kind, play_state, result)
  VALUES (hash, account, kind, play_state, result);
  DELETE FROM billing_private.events WHERE at < now() - interval '400 days';
$$;
REVOKE ALL ON FUNCTION billing_private.note_event(bytea, uuid, text, text, text) FROM PUBLIC;

-- RTDN: make a known, non-terminal token due now (the service then asks Play).
CREATE FUNCTION billing_private.mark_recheck(hash bytea)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH w AS (UPDATE billing_private.purchases SET next_check_at = now()
    WHERE token_hash = hash AND NOT terminal RETURNING account_id)
  INSERT INTO billing_private.events(token_hash, account_id, kind)
  SELECT hash, account_id, 'rtdn' FROM w
  RETURNING true
$$;
REVOKE ALL ON FUNCTION billing_private.mark_recheck(bytea) FROM PUBLIC;

-- Account deletion: rights and sealed tokens are erased (Play keeps billing the subscription until the
-- user cancels it in Play: the app must say so before deleting the account).
CREATE FUNCTION billing_private.forget_account(account uuid, issuer text)
RETURNS integer LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE n integer;
BEGIN
  DELETE FROM billing_private.purchases WHERE account_id = account AND auth_issuer = issuer;
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM billing_private.events WHERE account_id = account;
  RETURN n;
END
$$;
REVOKE ALL ON FUNCTION billing_private.forget_account(uuid, text) FROM PUBLIC;

-- Nothing in billing_private is reachable through PostgREST (schema not exposed) or by client roles.
REVOKE ALL ON ALL TABLES IN SCHEMA billing_private FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA billing_private FROM PUBLIC;
DO $r$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON SCHEMA billing_private FROM anon, authenticated;
  END IF;
END $r$;

-- Per-account request limit for verify/restore (protects the shared Publisher budget from one account).
CREATE TABLE billing_private.request_window (
  account_id uuid PRIMARY KEY,
  window_start timestamptz NOT NULL,
  requests integer NOT NULL
);
ALTER TABLE billing_private.request_window ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION billing_private.allow_request(account uuid, max_per_minute integer)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  INSERT INTO billing_private.request_window AS w (account_id, window_start, requests)
  VALUES (account, clock_timestamp(), 1)
  ON CONFLICT (account_id) DO UPDATE SET
    window_start = CASE WHEN w.window_start <= clock_timestamp() - interval '1 minute' THEN clock_timestamp() ELSE w.window_start END,
    requests = CASE WHEN w.window_start <= clock_timestamp() - interval '1 minute' THEN 1 ELSE w.requests + 1 END
  RETURNING requests <= greatest(max_per_minute, 1)
$$;
REVOKE ALL ON FUNCTION billing_private.allow_request(uuid, integer) FROM PUBLIC;

-- Whatever path deletes a Supabase Auth user (app, dashboard, futbeat-delete-account), its billing data goes.
CREATE FUNCTION billing_private.forget_deleted_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  DELETE FROM billing_private.purchases WHERE account_id = OLD.id;
  DELETE FROM billing_private.events WHERE account_id = OLD.id;
  DELETE FROM billing_private.request_window WHERE account_id = OLD.id;
  RETURN OLD;
END
$$;
REVOKE ALL ON FUNCTION billing_private.forget_deleted_user() FROM PUBLIC;
DO $t$ BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    CREATE TRIGGER futbeat_billing_forget_deleted_user AFTER DELETE ON auth.users
      FOR EACH ROW EXECUTE FUNCTION billing_private.forget_deleted_user();
  END IF;
END $t$;

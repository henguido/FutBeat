-- Local proposal. Apply only in an approved deployment after staging validation.
CREATE SCHEMA billing_private;
REVOKE ALL ON SCHEMA billing_private FROM PUBLIC;

CREATE SEQUENCE billing_private.observation_revision AS bigint;

CREATE TABLE billing_private.purchases (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  account_id uuid NOT NULL,
  auth_issuer text NOT NULL,
  package_name text NOT NULL CHECK (package_name = 'com.futbeat.futbeat'),
  product_id text NOT NULL CHECK (product_id = 'futbeat_premium'),
  base_plan_id text NOT NULL CHECK (base_plan_id IN ('monthly', 'yearly')),
  sealed_token bytea NOT NULL CHECK (octet_length(sealed_token) > 28),
  key_version text NOT NULL CHECK (key_version <> ''),
  revision bigint NOT NULL CHECK (revision > 0),
  verified_at timestamptz NOT NULL,
  expires_at timestamptz,
  terminal boolean NOT NULL,
  ack_pending boolean NOT NULL,
  next_check_at timestamptz,
  ack_attempts integer NOT NULL DEFAULT 0,
  ack_due_at timestamptz NOT NULL DEFAULT now(),
  ack_lease_until timestamptz,
  CHECK (NOT terminal OR (expires_at IS NULL AND NOT ack_pending AND next_check_at IS NULL)),
  CHECK (NOT ack_pending OR expires_at IS NOT NULL)
);
ALTER TABLE billing_private.purchases ENABLE ROW LEVEL SECURITY;
CREATE INDEX purchases_owner ON billing_private.purchases (auth_issuer, account_id);
CREATE INDEX purchases_due ON billing_private.purchases (next_check_at) WHERE NOT terminal;
CREATE INDEX purchases_ack_due ON billing_private.purchases (ack_due_at) WHERE ack_pending;

-- Called only after Publisher verification. Revision is reserved before the HTTP call.
-- The worker must commit this transaction before it can send the Play acknowledgement.
CREATE FUNCTION billing_private.record_observation(observed billing_private.purchases)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH written AS (
    INSERT INTO billing_private.purchases AS current_purchase
    SELECT (observed).*
    ON CONFLICT (token_hash) DO UPDATE SET
      sealed_token = EXCLUDED.sealed_token,
      key_version = EXCLUDED.key_version,
      revision = EXCLUDED.revision,
      verified_at = EXCLUDED.verified_at,
      expires_at = EXCLUDED.expires_at,
      terminal = EXCLUDED.terminal,
      ack_pending = EXCLUDED.ack_pending AND current_purchase.ack_due_at <> 'infinity',
      next_check_at = EXCLUDED.next_check_at
    WHERE current_purchase.account_id = EXCLUDED.account_id
      AND current_purchase.auth_issuer = EXCLUDED.auth_issuer
      AND current_purchase.package_name = EXCLUDED.package_name
      AND current_purchase.product_id = EXCLUDED.product_id
      AND current_purchase.base_plan_id = EXCLUDED.base_plan_id
      AND NOT current_purchase.terminal
      AND current_purchase.revision < EXCLUDED.revision
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM written)
$$;
REVOKE ALL ON FUNCTION billing_private.record_observation(billing_private.purchases) FROM PUBLIC;

CREATE FUNCTION billing_private.replace_purchase(
  observed billing_private.purchases, previous_hash bytea
) RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE previous billing_private.purchases;
BEGIN
  IF previous_hash = observed.token_hash OR observed.terminal OR
     observed.expires_at IS NULL OR observed.expires_at <= now() THEN RETURN false; END IF;
  -- Serialize replacements even if the predecessor has never been seen.
  PERFORM pg_advisory_xact_lock(hashtextextended(encode(previous_hash, 'hex'), 0));
  SELECT * INTO previous FROM billing_private.purchases WHERE token_hash = previous_hash FOR UPDATE;
  IF NOT FOUND OR previous.account_id <> observed.account_id OR
     previous.auth_issuer <> observed.auth_issuer OR previous.revision >= observed.revision THEN
    RETURN false;
  END IF;
  IF NOT billing_private.record_observation(observed) THEN RETURN false; END IF;
  UPDATE billing_private.purchases SET terminal = true, revision = observed.revision,
    expires_at = NULL, ack_pending = false, next_check_at = NULL, ack_lease_until = NULL
  WHERE token_hash = previous_hash;
  RETURN true;
END
$$;
REVOKE ALL ON FUNCTION billing_private.replace_purchase(billing_private.purchases, bytea) FROM PUBLIC;

CREATE FUNCTION billing_private.claim_ack(issuer text, max_jobs integer)
RETURNS SETOF billing_private.purchases LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH due AS (
    SELECT token_hash FROM billing_private.purchases
    WHERE auth_issuer = issuer AND ack_pending AND NOT terminal AND expires_at > now() AND ack_due_at <= now()
      AND (ack_lease_until IS NULL OR ack_lease_until <= now())
    ORDER BY ack_due_at, token_hash
    LIMIT least(greatest(max_jobs, 0), 50) FOR UPDATE SKIP LOCKED
  )
  UPDATE billing_private.purchases p SET ack_lease_until = now() + interval '60 seconds',
    ack_attempts = p.ack_attempts + 1
  FROM due WHERE p.token_hash = due.token_hash RETURNING p.*
$$;
REVOKE ALL ON FUNCTION billing_private.claim_ack(text, integer) FROM PUBLIC;

CREATE FUNCTION billing_private.finish_ack(hash bytea, attempt integer, succeeded boolean)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH written AS (
    UPDATE billing_private.purchases SET ack_pending = NOT succeeded,
      ack_lease_until = NULL,
      ack_due_at = CASE WHEN succeeded THEN 'infinity'::timestamptz ELSE
        now() + make_interval(secs => least(300, 5 * power(2, least(attempt, 6)))) END
    WHERE token_hash = hash AND ack_attempts = attempt AND ack_pending AND NOT terminal
      AND ack_lease_until > now()
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM written)
$$;
REVOKE ALL ON FUNCTION billing_private.finish_ack(bytea, integer, boolean) FROM PUBLIC;

CREATE FUNCTION billing_private.claim_rechecks(issuer text, max_jobs integer)
RETURNS SETOF billing_private.purchases LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH due AS (
    SELECT token_hash FROM billing_private.purchases
    WHERE auth_issuer = issuer AND NOT terminal AND next_check_at <= now()
    ORDER BY next_check_at, token_hash
    LIMIT least(greatest(max_jobs, 0), 50) FOR UPDATE SKIP LOCKED
  )
  UPDATE billing_private.purchases p SET next_check_at = now() + interval '2 minutes'
  FROM due WHERE p.token_hash = due.token_hash RETURNING p.*
$$;
REVOKE ALL ON FUNCTION billing_private.claim_rechecks(text, integer) FROM PUBLIC;

CREATE TABLE billing_private.publisher_budget (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  requests timestamptz[] NOT NULL DEFAULT '{}',
  blocked_until timestamptz NOT NULL DEFAULT '-infinity'
);
ALTER TABLE billing_private.publisher_budget ENABLE ROW LEVEL SECURITY;
INSERT INTO billing_private.publisher_budget DEFAULT VALUES;

-- One budget per Publisher quota project; all workers must use this database.
CREATE FUNCTION billing_private.reserve_publisher(max_per_minute integer)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE recent timestamptz[];
DECLARE paused_until timestamptz;
DECLARE stamp timestamptz;
BEGIN
  SELECT requests, blocked_until INTO recent, paused_until
    FROM billing_private.publisher_budget WHERE singleton FOR UPDATE;
  stamp := clock_timestamp();
  IF stamp < paused_until THEN RETURN false; END IF;
  recent := ARRAY(SELECT x FROM unnest(recent) x WHERE x > stamp - interval '1 minute');
  IF cardinality(recent) >= least(greatest(max_per_minute, 1), 3000) THEN RETURN false; END IF;
  UPDATE billing_private.publisher_budget SET requests = array_append(recent, stamp) WHERE singleton;
  RETURN true;
END
$$;
REVOKE ALL ON FUNCTION billing_private.reserve_publisher(integer) FROM PUBLIC;

CREATE FUNCTION billing_private.pause_publisher(seconds integer)
RETURNS void LANGUAGE sql SET search_path = pg_catalog AS $$
  UPDATE billing_private.publisher_budget SET blocked_until = greatest(blocked_until,
    clock_timestamp() + make_interval(secs => greatest(seconds, 1))) WHERE singleton
$$;
REVOKE ALL ON FUNCTION billing_private.pause_publisher(integer) FROM PUBLIC;

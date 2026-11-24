import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { evaluatePurchase } from './premium-play-policy.mjs';

// PREMIUM-PROD: the Codex release service (artifacts/android-commercial-qa @49382fc, 20/20 tests) with the
// production adjustments, all opt-in through `freshness` so the QA behaviour stays reproducible:
//   * staleness: an entitlement counts until min(Play expiryTime, last successful verification + maxStaleMs).
//     QA keeps 15 min; production uses 72 h so a Play / network outage never removes Premium from a payer,
//     while a revocation is seen at the next successful recheck (or at once with RTDN).
//   * recheck cadence: every recheckMs and just after the paid period ends (renewal or expiry).
//   * notify(token): RTDN / external signal -> immediate authoritative recheck of a KNOWN token only.
//   * forgetAccount(account): account deletion erases tokens and rights (no sealed token kept).
export const releaseRecheckMs = 10 * 60_000;
export const releaseFreshnessMs = 15 * 60_000;
export const productionFreshness = { recheckMs: 6 * 3_600_000, maxStaleMs: 72 * 3_600_000 };
const digest = (token) => createHash('sha256').update(token).digest();
const packageName = 'com.futbeat.futbeat';
const plans = ['monthly', 'yearly'].map((basePlanId) => ({ productId: 'futbeat_premium', basePlanId }));

export function createPremiumReleaseService({
  db, publisher, issuer, keys, currentKey, environment, now = Date.now,
  freshness = environment === 'production' ? productionFreshness : { recheckMs: releaseRecheckMs, maxStaleMs: releaseFreshnessMs },
}) {
  if (!issuer || !keys.get(currentKey) || !['qa', 'production'].includes(environment)) {
    throw new Error('Billing service configuration incomplete');
  }
  const { recheckMs, maxStaleMs } = freshness;
  const renewalGraceMs = freshness.renewalGraceMs ?? (environment === 'production' ? 3_600_000 : 120_000);
  if (!(recheckMs > 0) || !(maxStaleMs >= recheckMs)) throw new Error('Billing freshness configuration invalid');
  const row = async (sql, params) => (await db.query(sql, params)).rows[0];
  const find = (hash) => row('SELECT * FROM billing_private.purchases WHERE token_hash = $1', [hash]);
  const owns = (purchase, account) => purchase.account_id === account && purchase.auth_issuer === issuer;
  function open(purchase) {
    if (purchase.auth_issuer !== issuer || purchase.package_name !== packageName) throw new Error('Wrong purchase scope');
    const token = keys.get(purchase.key_version)?.open(purchase.sealed_token, {
      ...purchase, token_hash: Buffer.from(purchase.token_hash).toString('hex'),
    });
    if (!token || !digest(token).equals(Buffer.from(purchase.token_hash))) throw new Error('Unavailable purchase key');
    return token;
  }
  async function entitlement(account) {
    const { rows } = await db.query(`
      SELECT *, least(expires_at, verified_at + make_interval(secs => $4::double precision)) AS expiry
      FROM billing_private.purchases WHERE account_id = $1 AND auth_issuer = $2
        AND NOT terminal AND expires_at IS NOT NULL AND key_version = ANY($3::text[])
      ORDER BY expiry DESC
    `, [account, issuer, [...keys.keys()], maxStaleMs / 1000]);
    for (const purchase of rows) {
      if (Date.parse(purchase.expiry) <= now()) break;
      open(purchase);
      return {
        status: 'active', expiresAt: new Date(purchase.expiry).toISOString(),
        paidUntil: new Date(purchase.expires_at).toISOString(), plan: purchase.base_plan_id,
      };
    }
    return { status: 'inactive' };
  }
  async function verify(account, token, { allowNew = false } = {}) {
    const hash = digest(token);
    const existing = await find(hash);
    if (existing && !owns(existing, account)) return { status: 'rejected' };
    if (!existing && !allowNew) return { status: 'unavailable' };
    if (existing?.terminal) return entitlement(account);
    const { revision } = await row("SELECT nextval('billing_private.observation_revision')::text AS revision");
    const started = now();
    const purchase = await publisher.fetchPurchase(token);
    const result = evaluatePurchase({ purchase, accountId: account, plans, environment, now: now() });
    if (result.status === 'rejected') return result;
    const plan = plans.find((p) => purchase.lineItems.some(
      (i) => i.productId === p.productId && i.offerDetails?.basePlanId === p.basePlanId,
    ));
    const terminal = ['SUBSCRIPTION_STATE_EXPIRED', 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED']
      .includes(purchase.subscriptionState);
    const sealed = keys.get(currentKey).seal(token, {
      token_hash: hash.toString('hex'), account_id: account, product_id: plan.productId,
    });
    // Next authoritative check: the regular cadence, or just after the paid period ends (30 s, the time Play
    // needs to publish a renewal). G2 renewal grace: while Play reports an ACTIVE, auto-renewing plan the right
    // is extended by renewalGraceMs past the paid end, so a renewal is never shown as a minute of "inactive"
    // (G1 A1: 67 s gap). Cancelled, refunded or revoked plans get no grace: auto-renew is off or the state is
    // terminal, and the check right after the paid end applies it.
    const items = (purchase.lineItems ?? []).filter((i) => i?.productId === plan.productId);
    const playEnd = Math.max(0, ...items.map((i) => Date.parse(i?.expiryTime) || 0));
    const autoRenew = purchase.subscriptionState === 'SUBSCRIPTION_STATE_ACTIVE'
      && items.some((i) => i?.autoRenewingPlan?.autoRenewEnabled === true);
    let renewalPending = false;
    if (autoRenew && playEnd && playEnd + renewalGraceMs > now()) {
      // Still ACTIVE and auto-renewing: inside the grace even when Play has not yet moved the expiry.
      renewalPending = playEnd <= now();
      if (renewalPending) result.status = 'active';
      result.expiresAt = new Date(playEnd + renewalGraceMs).toISOString();
    }
    const paidEnd = playEnd || null;
    const nextCheck = terminal ? null : new Date(renewalPending
      ? started + 60_000   // renewal not yet visible: ask again in a minute, still inside the grace
      : Math.min(started + recheckMs, paidEnd && paidEnd > started ? paidEnd + 30_000 : started + recheckMs));
    const values = [hash, account, issuer, packageName, plan.productId, plan.basePlanId,
      sealed, currentKey, revision, new Date(started), result.expiresAt ?? null,
      terminal, result.acknowledgeAfterCommit === true, nextCheck];
    const observation = `ROW($1::bytea,$2::uuid,$3::text,$4::text,$5::text,$6::text,
      $7::bytea,$8::text,$9::bigint,$10::timestamptz,$11::timestamptz,$12::boolean,
      $13::boolean,$14::timestamptz,0,now(),NULL)::billing_private.purchases`;
    let applied;
    if (result.status === 'active' && purchase.linkedPurchaseToken && !existing) {
      values.push(digest(purchase.linkedPurchaseToken));
      ({ applied } = await row(`SELECT billing_private.replace_purchase(${observation}, $15) AS applied`, values));
    } else {
      ({ applied } = await row(`SELECT billing_private.record_observation(${observation}) AS applied`, values));
    }
    if (!applied) {
      const saved = await find(hash);
      if (!saved || !owns(saved, account)) return { status: 'rejected' };
    } else {
      await db.query('SELECT billing_private.note_event($1,$2,$3,$4,$5)', [hash, account,
        existing ? 'recheck' : (purchase.linkedPurchaseToken ? 'replacement' : 'purchase'),
        purchase.subscriptionState ?? null, result.status]);
    }
    return entitlement(account);
  }
  return {
    entitlement,
    verify,
    // RTDN or an operator signal: only a token already owned by an account is rechecked (Play is asked,
    // the notification itself is never trusted). Unknown tokens are ignored: the app verifies them.
    async notify(token) {
      const purchase = await find(digest(token));
      if (!purchase || purchase.terminal) return { status: 'ignored' };
      await db.query('SELECT billing_private.mark_recheck($1)', [purchase.token_hash]);
      try {
        const result = await verify(purchase.account_id, open(purchase));
        return { status: 'rechecked', entitlement: result.status };
      } catch {
        return { status: 'deferred' };  // next_check_at stays due: the cron retries
      }
    },
    async forgetAccount(account) {
      const { rows } = await db.query('SELECT billing_private.forget_account($1,$2) AS n', [account, issuer]);
      return Number(rows[0].n);
    },
    async reconcileDue(limit = 20) {
      // G2: one claim of distinct due rows per run (2-min lease, each check < 10 s), so a row that becomes due
      // again during the run can never be claimed twice nor starve the others.
      const { rows: due } = await db.query('SELECT * FROM billing_private.claim_rechecks($1, $2)',
        [issuer, Math.min(20, Math.max(0, limit))]);
      let attempts = 0;
      for (const purchase of due) {
        attempts++;
        try {
          await verify(purchase.account_id, open(purchase));
        } catch {
          // The claim already set a retry deadline without extending the entitlement.
        }
      }
      return attempts;
    },
    async drainAcknowledgements() {
      // One claim at a time keeps the lease longer than the Publisher timeout.
      const purchase = await row('SELECT * FROM billing_private.claim_ack($1, 1)', [issuer]);
      if (!purchase) return false;
      let success = false;
      try {
        await publisher.acknowledge(open(purchase), purchase.account_id, environment);
        success = true;
      } finally {
        await db.query('SELECT billing_private.finish_ack($1,$2,$3)',
          [purchase.token_hash, purchase.ack_attempts, success]);
      }
      return true;
    },
  };
}

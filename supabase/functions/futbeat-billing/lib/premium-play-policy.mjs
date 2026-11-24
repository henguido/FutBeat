import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

const activeStates = new Set([
  'SUBSCRIPTION_STATE_ACTIVE',
  'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
  'SUBSCRIPTION_STATE_CANCELED',
]);

// Isolated policy. Only pass a response obtained by the server from
// subscriptionsv2.get for the configured QA package and submitted token.
export function evaluateTestPurchase({ purchase, accountId, plans, now }) {
  return evaluatePurchase({ purchase, accountId, plans, now, environment: 'qa' });
}

export function evaluatePurchase({ purchase, accountId, plans, now, environment }) {
  if (typeof accountId !== 'string' || !accountId || !Number.isFinite(now)) {
    throw new TypeError('An authenticated account and server time are required');
  }
  if (environment !== 'qa' && environment !== 'production') {
    throw new TypeError('An explicit purchase environment is required');
  }
  const tag = createHash('sha256').update(`futbeat:account:${accountId}`).digest('hex');
  const testMarker = purchase?.testPurchase;
  const expectedEnvironment = environment === 'qa'
    ? testMarker != null && typeof testMarker === 'object' && !Array.isArray(testMarker)
    : purchase && !Object.hasOwn(purchase, 'testPurchase');
  if (!expectedEnvironment ||
      purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId !== tag) {
    return { status: 'rejected' };
  }

  const items = Array.isArray(purchase.lineItems) ? purchase.lineItems : [];
  const recognized = items.filter((item) =>
    plans.some(({ productId, basePlanId }) =>
      productId === item?.productId && basePlanId === item?.offerDetails?.basePlanId));
  if (!recognized.length) return { status: 'rejected' };
  if (!activeStates.has(purchase.subscriptionState)) return { status: 'inactive' };

  const expiry = Math.max(...recognized.map(({ expiryTime }) =>
    typeof expiryTime === 'string' ? Date.parse(expiryTime) || 0 : 0));
  if (expiry <= now) return { status: 'inactive' };
  return {
    status: 'active',
    expiresAt: new Date(expiry).toISOString(),
    acknowledgeAfterCommit: purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING',
  };
}

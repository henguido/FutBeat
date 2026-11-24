import { Buffer } from 'node:buffer';
import { evaluatePurchase } from './premium-play-policy.mjs';

const api = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';

export function createPremiumReleasePublisher({ environment, accessToken, fetchImpl = fetch, budget }) {
  if (!['qa', 'production'].includes(environment)) throw new TypeError('Invalid Publisher environment');
  if (!budget) throw new TypeError('Shared Publisher budget required');
  const plans = ['monthly', 'yearly'].map((basePlanId) => ({ productId: 'futbeat_premium', basePlanId }));
  const { fetchPurchase, call } = createPublisherRequests({
    packageName: 'com.futbeat.futbeat', accessToken, fetchImpl, budget,
  });
  return {
    fetchPurchase,
    async acknowledge(token, accountId, expectedEnvironment) {
      if (expectedEnvironment !== environment) throw new Error('Wrong Publisher environment');
      const purchase = await fetchPurchase(token);
      const result = evaluatePurchase({ purchase, accountId, plans, environment, now: Date.now() });
      if (result.status !== 'active') throw new Error('Purchase cannot be acknowledged');
      if (purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED') return;
      if (!result.acknowledgeAfterCommit) throw new Error('Unknown acknowledgement state');
      const response = await call(`subscriptions/futbeat_premium/tokens/${encodeURIComponent(token)}:acknowledge`, 'POST');
      if (!response.ok) throw new Error(`Publisher acknowledgement failed (${response.status})`);
    },
  };
}

export function createPremiumPlayQaApi({
  packageName, plans, accessToken, allowOfficialLicenseTests = false, fetchImpl = fetch,
}) {
  if (packageName !== 'com.futbeat.futbeat.commercialqa' &&
      !(allowOfficialLicenseTests === true && packageName === 'com.futbeat.futbeat')) {
    throw new TypeError('The package is not enabled for Play license tests');
  }
  const { fetchPurchase, call } = createPublisherRequests({ packageName, accessToken, fetchImpl });
  return {
    fetchPurchase,
    async revokeTestPurchase(token, expectedAccountTag) {
      const purchase = await fetchPurchase(token);
      const items = purchase.lineItems;
      if (!purchase.testPurchase ||
          purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId !== expectedAccountTag ||
          purchase.subscriptionState !== 'SUBSCRIPTION_STATE_ACTIVE' ||
          !Array.isArray(items) || items.length !== 1 ||
          !plans.some((plan) => plan.productId === items[0].productId &&
            plan.basePlanId === items[0].offerDetails?.basePlanId)) {
        throw new Error('Revocation requires the expected active test subscription');
      }
      const response = await call(`subscriptionsv2/tokens/${encodeURIComponent(token)}:revoke`,
        'POST', { revocationContext: { fullRefund: {} } });
      return response.status;
    },
    async acknowledge(token) {
      const purchase = await fetchPurchase(token);
      if (!purchase?.testPurchase) throw new Error('Play test purchase required');
      if (purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED') return;
      if (purchase.acknowledgementState !== 'ACKNOWLEDGEMENT_STATE_PENDING') {
        throw new Error('Play acknowledgement state unavailable');
      }
      const item = purchase.lineItems?.find(({ productId, offerDetails }) =>
        plans.some((plan) => plan.productId === productId && plan.basePlanId === offerDetails?.basePlanId));
      if (!item) throw new Error('Play QA plan is unavailable');
      const response = await call(
        `subscriptions/${encodeURIComponent(item.productId)}/tokens/${encodeURIComponent(token)}:acknowledge`,
        'POST',
      );
      if (!response.ok) throw new Error(`Play QA acknowledgement failed (${response.status})`);
    },
  };
}

function createPublisherRequests({ packageName, accessToken, fetchImpl, budget }) {
  const base = `${api}/${packageName}/purchases`;

  async function call(path, method = 'GET', body = {}) {
    const credential = await accessToken();
    if (!credential) throw new Error('Play QA credentials unavailable');
    if (budget && !await budget.reserve()) throw new Error('Publisher budget unavailable');
    const response = await fetchImpl(`${base}/${path}`, {
      method,
      redirect: 'error',
      signal: AbortSignal.timeout(10000),
      headers: {
        Authorization: `Bearer ${credential}`,
        ...(method === 'POST' ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(method === 'POST' ? { body: JSON.stringify(body) } : {}),
    });
    if (response.status === 429 && budget) await budget.pause(response.headers.get('Retry-After'));
    return response;
  }

  async function fetchPurchase(token) {
    const response = await call(`subscriptionsv2/tokens/${encodeURIComponent(token)}`);
    if (!response.ok) throw new Error(`Play QA verification failed (${response.status})`);
    return response.json();
  }

  return { fetchPurchase, call };
}

export function createPublisherBudget(db, maxPerMinute) {
  if (!Number.isInteger(maxPerMinute) || maxPerMinute < 1 || maxPerMinute > 3000) {
    throw new TypeError('Explicit Publisher quota budget required');
  }
  return {
    async reserve() {
      const { rows } = await db.query('SELECT billing_private.reserve_publisher($1) AS allowed', [maxPerMinute]);
      return rows[0].allowed;
    },
    async pause(retryAfter) {
      const seconds = /^\d+$/.test(retryAfter ?? '') ? Number(retryAfter)
        : Math.ceil((Date.parse(retryAfter) - Date.now()) / 1000);
      const delay = Number.isFinite(seconds) ? Math.min(86_400, Math.max(30, seconds)) : 60;
      await db.query('SELECT billing_private.pause_publisher($1)', [delay + Math.floor(Math.random() * 11)]);
    },
  };
}

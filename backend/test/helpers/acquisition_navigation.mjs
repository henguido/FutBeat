// Explicit opt-in for tests of the retained acquisition primitives. Never imported by runtime code.
// Production/app navigation defaults remain passive; D1v2 has its own default-mode regression.
export async function enableAcquisitionTestNavigation(db, { legacyMatchDetail = false } = {}) {
  if (legacyMatchDetail) {
    // Test-only retained opt-in path. The default D1v2 acceptance explicitly asserts this stays OFF.
    await db.query(`update futbeat_private.provider_quota_policy set freshness=freshness||'{"openTriggersFetch":1}'::jsonb where provider='goal_api'`);
  }
  const result = await db.query(`update futbeat_private.api_access_policy
    set navigation_demands=true where singleton returning navigation_demands`);
  if (result.rows.length !== 1 || result.rows[0].navigation_demands !== true) {
    throw new Error('Acquisition test fixture requires the versioned passive policy');
  }
}

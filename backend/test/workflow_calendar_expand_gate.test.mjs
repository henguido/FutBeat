import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// ARCH-155: the cold calendar must not depend on a manual dispatch. 10-28/29 the 09:17 UTC run
// found 333 and 282 GOAL calls left (< 350 reserve) and skipped, so the expansion never ran.
const workflow = await readFile(new URL('../../.github/workflows/global-fixtures.yml', import.meta.url), 'utf8');
const num = (re) => Number(workflow.match(re)?.[1]);

test('scheduled runs expand the cold calendar whenever the daily quota is fresh', () => {
  assert.match(workflow, /\$shouldExpand = @\("workflow_dispatch", "push"\) -contains \$env:GITHUB_EVENT_NAME -or \$utcHour -eq 9 -or\s+\(\$null -ne \$postHotRemaining -and \[int\]\$postHotRemaining -ge \$expandFreshQuota\)/);
  // The gate is evaluated after the post-hot quota check, on its providerRemaining.
  assert.ok(workflow.indexOf('$postHotRemaining = $postHotQuota.plan.providerRemaining') > workflow.indexOf('action = "global-quota-plan"'));
  assert.ok(workflow.indexOf('$shouldExpand =') > workflow.indexOf('$postHotRemaining ='));
  assert.ok(workflow.indexOf('$shouldExpand =') < workflow.indexOf('if ($shouldExpand) {'));
});

test('a fresh-quota expansion cannot eat into the reserve: threshold >= reserve + request budget', () => {
  const fresh = num(/\$expandFreshQuota = (\d+)/);
  const reserve = num(/\$quotaReserve = (\d+)/);
  const budget = num(/\$calendarRequestBudget = (\d+)/);
  const globalReserve = num(/\$globalReserve = (\d+)/);
  assert.ok(fresh >= reserve + budget, `${fresh} >= ${reserve} + ${budget}`);
  assert.ok(fresh > globalReserve);
});

// Drains the outbox within one invocation: claim a batch, send it with bounded
// concurrency, record every receipt, and claim again while the time budget
// allows. Claimed rows are always finished (a batch is never abandoned); a new
// batch is only claimed while the budget is not spent.
export const DISPATCH_DEFAULTS = Object.freeze({ batchSize:50, concurrency:10, budgetMs:45000 });

async function sendOne({ row, rpc, transport }) {
 async function retryBeforeSend(receipt) {
  let recorded = false;
  try { recorded = await rpc('futbeat_requeue_notification_attempt',{
   p_id:row.id,p_attempt:row.attemptId,p_reason:receipt,
  }); } catch { /* the stale-attempt guard requeues when no transport started */ }
  return { id:row.id, state:'pending', receipt, recorded };
 }
 let valid;
 try {
  valid = await rpc('futbeat_notification_attempt_valid',{
   p_id:row.id,p_attempt:row.attemptId,p_token:row.token,
  });
 } catch {
  return retryBeforeSend('VALIDATION_UNAVAILABLE');
 }
 if (!valid) {
  let recorded = false;
  try { recorded = await rpc('futbeat_cancel_notification_attempt',{
   p_id:row.id,p_attempt:row.attemptId,p_reason:'PRE_SEND_INVALID',
  }); } catch { /* the stale-attempt guard will settle it */ }
  return { id:row.id, state:'cancelled', receipt:'attempt_invalid', recorded };
 }
 let started;
 try { started = await rpc('futbeat_mark_notification_send_started',{
  p_id:row.id,p_attempt:row.attemptId,p_token:row.token,
 }); } catch { return retryBeforeSend('SEND_START_UNAVAILABLE'); }
 if (!started) {
  let recorded = false;
  try { recorded = await rpc('futbeat_cancel_notification_attempt',{
   p_id:row.id,p_attempt:row.attemptId,p_reason:'PRE_SEND_INVALID',
  }); } catch { /* the stale-attempt guard will settle it */ }
  return { id:row.id, state:'cancelled', receipt:'attempt_invalid', recorded };
 }
 let outcome;
 try { outcome = await transport.send(row); }
 catch { outcome = { state:'uncertain', receipt:'TRANSPORT_FAILURE' }; }
 let recorded = false;
 try { recorded = await rpc('futbeat_finish_notification',{p_id:row.id,p_attempt:row.attemptId,
  p_state:outcome.state,p_receipt:outcome.receipt ?? null}); }
 catch { /* no transport retry after an ambiguous receipt */ }
 return { id:row.id, state:outcome.state, receipt:outcome.receipt ?? null, recorded };
}

async function pool(items, size, work) {
 const results = new Array(items.length);
 let next = 0;
 const lanes = Array.from({ length:Math.max(1, Math.min(size, items.length)) }, async () => {
  while (next < items.length) {
   const index = next++;
   results[index] = await work(items[index]);
  }
 });
 await Promise.all(lanes);
 return results;
}

export async function dispatchNotifications({ rpc, transport, mode = 'dry_run',
 limit, batchSize = limit ?? DISPATCH_DEFAULTS.batchSize, concurrency = DISPATCH_DEFAULTS.concurrency,
 budgetMs = DISPATCH_DEFAULTS.budgetMs, maxBatches = Infinity, clock = () => Date.now() }) {
 const started = clock();
 const results = [];
 for (let batch = 0; batch < maxBatches && clock() - started < budgetMs; batch++) {
  const claim = await rpc('futbeat_claim_notifications_v2',{p_mode:mode,p_limit:batchSize});
  if (!claim || !Array.isArray(claim.rows) || !Number.isInteger(claim.scanned))
   throw new Error('Invalid notification claim response');
  if (claim.scanned === 0) break;
  const rows = claim.rows;
  for (const result of await pool(rows, concurrency, row => sendOne({ row, rpc, transport }))) results.push(result);
  // A short batch drained the queue (rows cancelled at claim are not returned,
  // so only an empty claim is conclusive; one more claim is cheap).
 }
 return results;
}

export function summarize(results) {
 const counts = {};
 for (const { state } of results) counts[state] = (counts[state] ?? 0) + 1;
 return { processed:results.length, counts,
  deadTokens:results.filter(r => r.receipt === 'FCM_UNREGISTERED' || r.receipt === 'APNS_UNREGISTERED').length };
}

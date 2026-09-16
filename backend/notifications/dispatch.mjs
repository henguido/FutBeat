export async function dispatchNotifications({rpc,transport,mode='dry_run',limit=20}) {
 const rows=await rpc('futbeat_claim_notifications',{p_mode:mode,p_limit:limit});
 const results=[];
 for(const row of rows) {
  let outcome;
  try { outcome=await transport.send(row); }
  catch { outcome={state:'uncertain',receipt:'TRANSPORT_FAILURE'}; }
  const recorded=await rpc('futbeat_finish_notification',{p_id:row.id,p_attempt:row.attemptId,
   p_state:outcome.state,p_receipt:outcome.receipt ?? null});
  results.push({id:row.id,state:outcome.state,recorded});
 }
 return results;
}

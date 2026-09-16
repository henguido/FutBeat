import { createTransport } from '../../../backend/notifications/transports.mjs';
import { dispatchNotifications } from '../../../backend/notifications/dispatch.mjs';

// Platform JWT verification stays enabled; a public JWT alone never authorizes dispatch.
Deno.serve(async (request: Request) => {
 const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
 if(request.method!=='POST') return new Response(null,{status:405});
 if(!key) return new Response(null,{status:503});
 const rpc=async(name:string,args:unknown)=>{
  const response=await fetch(Deno.env.get('SUPABASE_URL')+'/rest/v1/rpc/'+name,{
   method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},
   body:JSON.stringify(args),signal:AbortSignal.timeout(10000)});
  if(!response.ok) throw new Error('Push storage unavailable');
  return response.json();
 };
 try {
  if(request.headers.get('authorization')!=='Bearer '+key) {
   const token=request.headers.get('x-futbeat-scheduler');
   if(!token || !await rpc('futbeat_authorize_push_scheduler',{p_token:token})) return new Response(null,{status:403});
  }
  const mode=Deno.env.get('FUTBEAT_PUSH_MODE') ?? 'dry_run';
  const env=Object.fromEntries(['FCM_SERVICE_ACCOUNT_JSON','APNS_PRIVATE_KEY','APNS_KEY_ID','APNS_TEAM_ID','APNS_TOPIC','APNS_SANDBOX']
   .map(name=>[name,Deno.env.get(name)]));
  return Response.json({results:await dispatchNotifications({rpc,transport:createTransport({mode,env}),mode,limit:3})});
 } catch { return Response.json({error:'Push dispatch unavailable'},{status:503}); }
});

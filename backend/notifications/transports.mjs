import { Buffer } from 'node:buffer';
const enc = value => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
async function jwt(header, claims, pem, algorithm) {
 const body = enc(header) + '.' + enc(claims);
 const binary = Buffer.from(pem.replace(/-----[^-]+-----/g,'').replace(/\s/g,''),'base64');
 const key = await crypto.subtle.importKey('pkcs8',binary,algorithm,false,['sign']);
 const signature = await crypto.subtle.sign(algorithm,key,new TextEncoder().encode(body));
 return body + '.' + Buffer.from(signature).toString('base64url');
}

// Android notification channel the app creates (one channel for match and
// player alerts). Overridable per message (message.channelId) or by env.
export const DEFAULT_ANDROID_CHANNEL = 'futbeat_match_alerts';
const SEND_TIMEOUT_MS = 10000;

// One notification slot per logical event: a GOAL_ANNULLED replaces its goal,
// a lineup correction replaces the earlier lineup alert. FCM/APNs collapse ids
// are at most 64 bytes.
export function collapseKeyOf(row) {
 const key = row.message?.collapseKey ?? row.message?.eventId ?? row.id;
 return String(key).slice(0, 64);
}

// Data values must be strings for FCM.
function dataOf(row) {
 const m = row.message ?? {};
 const data = { notificationId: String(row.id) };
 for (const name of ['type','eventId','matchId','playerId','annulsEventId','articleId','transferId','url'])
  if (m[name] !== undefined && m[name] !== null) data[name] = String(m[name]);
 return data;
}

// Dead-token classification: the device must be disabled (receipt handled by
// futbeat_finish_notification).
function retryAfterSeconds(response) {
  const retryAfter = response.headers.get('retry-after');
  const seconds = Number(retryAfter);
  const delay = retryAfter && Number.isFinite(seconds)
   ? Math.ceil(seconds) : retryAfter ? Math.ceil((Date.parse(retryAfter)-Date.now())/1000) : 60;
  return Number.isFinite(delay) ? Math.min(2147483647,Math.max(60,delay)) : 60;
}
function backoffSeconds(row, base) {
 const attempts = Math.min(8,Math.max(0,Number(row.retryCount) || 0));
 const stagger = [...String(row.id ?? '')].reduce((sum,ch)=>sum+ch.charCodeAt(0),0) % 16;
 return Math.ceil(Math.min(86400,base * 2 ** attempts) * (1 + stagger / 100));
}
async function fcmFailure(response, row) {
 if (response.status === 429)
  return { state:'retryable', receipt:'FCM_HTTP_429',
   retryAfterSeconds:Math.max(retryAfterSeconds(response),backoffSeconds(row,60)) };
 let code = null;
 try {
  const body = await response.json();
  code = body?.error?.details?.find(d => d?.errorCode)?.errorCode ?? body?.error?.status ?? null;
 } catch { /* no body */ }
 // A generic 404 can mean the FCM project or endpoint is misconfigured.
 // Only the token-specific FcmError is evidence that this device is dead.
 if (code === 'UNREGISTERED') return { state:'failed', receipt:'FCM_UNREGISTERED' };
 return { state: response.status >= 500 ? 'retryable' : 'failed',
  receipt:'FCM_HTTP_' + response.status + (code ? ':' + code : ''),
  ...(response.status >= 500 ? { retryAfterSeconds:Math.max(retryAfterSeconds(response),backoffSeconds(row,60)) } : {}) };
}
async function apnsFailure(response, row) {
 if (response.status === 429)
  return { state:'retryable', receipt:'APNS_HTTP_429',
   retryAfterSeconds:Math.max(retryAfterSeconds(response),backoffSeconds(row,60)) };
 let reason = null;
 try { reason = (await response.json())?.reason ?? null; } catch { /* no body */ }
 if (response.status === 410 || (response.status < 500 && reason === 'Unregistered'))
  return { state:'failed', receipt:'APNS_UNREGISTERED' };
 return { state: response.status >= 500 ? 'retryable' : 'failed',
  receipt:'APNS_HTTP_' + response.status + (reason ? ':' + reason : ''),
  ...(response.status >= 500 ? { retryAfterSeconds:Math.max(retryAfterSeconds(response),backoffSeconds(row,900)) } : {}) };
}

export function createTransport({ mode = 'dry_run', env = {}, fetcher = fetch, clock = () => Date.now() } = {}) {
 if (mode === 'dry_run') return { async send(row) {
  if (row.transport !== 'test') throw new Error('Dry run accepts test devices only');
  return { state:'simulated', receipt:'dry-run:' + row.id };
 }};
 if (mode !== 'live') throw new Error('Invalid push mode');

 // FCM OAuth access token, cached for this transport (one dispatcher
 // invocation): one token request however many messages are sent; concurrent
 // sends share the same in-flight request.
 let fcmAccount;
 let fcmToken = null; // { value, expiresAt } or a pending promise
 const fcmAccess = async () => {
  if (fcmAccount === undefined) {
   try { fcmAccount = JSON.parse(env.FCM_SERVICE_ACCOUNT_JSON ?? '{}'); } catch { fcmAccount = {}; }
  }
  const account = fcmAccount;
  if (!account.private_key || !account.client_email || !account.project_id) return { error:'FCM_NOT_CONFIGURED' };
  if (fcmToken && !(fcmToken instanceof Promise) && fcmToken.expiresAt - 60000 > clock()) return { account, token:fcmToken.value };
  if (!(fcmToken instanceof Promise)) {
   fcmToken = (async () => {
    const now = Math.floor(clock()/1000);
    let assertion;
    try { assertion = await jwt({alg:'RS256',typ:'JWT'},{
     iss:account.client_email,scope:'https://www.googleapis.com/auth/firebase.messaging',
     aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600,
    },account.private_key,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'}); }
    catch { return { error:'FCM_AUTH_INVALID', retryable:false }; }
    let reply;
    try { reply = await fetcher('https://oauth2.googleapis.com/token',{method:'POST',
     headers:{'Content-Type':'application/x-www-form-urlencoded'},
     body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}),
     signal:AbortSignal.timeout(SEND_TIMEOUT_MS)}); }
    catch { return { error:'FCM_AUTH_UNAVAILABLE', retryable:true }; }
    if (!reply.ok) return { error:'FCM_AUTH_HTTP_'+reply.status,
     retryable:reply.status===429 || reply.status>=500 };
    let payload;
    try { payload = await reply.json(); }
    catch { return { error:'FCM_AUTH_UNAVAILABLE', retryable:true }; }
    const { access_token, expires_in } = payload ?? {};
    if (!access_token) return { error:'FCM_AUTH_INVALID', retryable:false };
    return { value:access_token, expiresAt:clock() + Math.max(60, Number(expires_in) || 3600) * 1000 };
   })();
  }
  const pending = fcmToken;
  const resolved = await pending;
  if (fcmToken === pending) fcmToken = resolved.value ? resolved : null;
  return resolved.value ? { account, token:resolved.value } : resolved;
 };

 let apnsJwt = null; // { value, issuedAt }; APNs accepts a provider token for up to 1 h
 const apnsToken = async () => {
  if (apnsJwt && clock() - apnsJwt.issuedAt < 50 * 60000) return apnsJwt.value;
  const issuedAt = clock();
  const value = await jwt({alg:'ES256',kid:env.APNS_KEY_ID},{iss:env.APNS_TEAM_ID,iat:Math.floor(issuedAt/1000)},
   env.APNS_PRIVATE_KEY,{name:'ECDSA',namedCurve:'P-256',hash:'SHA-256'});
  apnsJwt = { value, issuedAt };
  return value;
 };

 return { async prepare(row) {
  if (row.transport === 'apns') {
   if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) return null;
   try { await apnsToken(); return null; }
   catch { return { state:'retryable', receipt:'APNS_AUTH_UNAVAILABLE' }; }
  }
  if (row.transport !== 'fcm') return null;
  const access = await fcmAccess();
  return access.error && access.retryable
   ? { state:'retryable', receipt:access.error } : null;
 }, async send(row) {
  if (row.transport === 'test') return { state:'simulated', receipt:'dry-run:' + row.id };
  let url,headers,body;
  const title = row.message?.title;
  const text = row.message?.body ?? undefined;
  const collapse = collapseKeyOf(row);
  if (row.transport === 'fcm') {
   const access = await fcmAccess();
   if (access.error) return {state:access.retryable ? 'retryable' : 'failed',receipt:access.error};
   url='https://fcm.googleapis.com/v1/projects/'+encodeURIComponent(access.account.project_id)+'/messages:send';
   headers={Authorization:'Bearer '+access.token,'Content-Type':'application/json'};
   body={message:{token:row.token,notification:{title,...(text ? {body:text} : {})},
    data:dataOf(row),
    android:{priority:'high',collapse_key:collapse,notification:{tag:collapse,
     channel_id:row.message?.channelId ?? env.FCM_ANDROID_CHANNEL_ID ?? DEFAULT_ANDROID_CHANNEL}},
    apns:{headers:{'apns-collapse-id':collapse}}}};
  } else if(row.transport==='apns') {
   if(!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC)
    return {state:'failed',receipt:'APNS_NOT_CONFIGURED'};
   const token=await apnsToken();
   const host=env.APNS_SANDBOX==='true'?'api.sandbox.push.apple.com':'api.push.apple.com';
   url='https://'+host+'/3/device/'+encodeURIComponent(row.token);
   headers={authorization:'bearer '+token,'apns-topic':env.APNS_TOPIC,'apns-push-type':'alert',
    'apns-id':row.id,'apns-collapse-id':collapse,'Content-Type':'application/json'};
   body={aps:{alert:{title,...(text ? {body:text} : {})},sound:'default','thread-id':row.message?.matchId ?? undefined},
    ...dataOf(row)};
  } else return {state:'failed',receipt:'UNSUPPORTED_TRANSPORT'};
  // Once the send starts, an ambiguous failure is never automatically retried.
  try {
   const response=await fetcher(url,{method:'POST',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(SEND_TIMEOUT_MS)});
   if(response.ok) return {state:'sent',receipt:row.transport==='apns' ? response.headers.get('apns-id') : (await response.json()).name};
   return row.transport==='apns' ? apnsFailure(response,row) : fcmFailure(response,row);
  } catch { return {state:'uncertain',receipt:'SEND_ACK_UNKNOWN'}; }
 }};
}

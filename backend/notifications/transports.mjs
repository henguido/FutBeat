import { Buffer } from 'node:buffer';
const enc = value => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
async function jwt(header, claims, pem, algorithm) {
 const body = enc(header) + '.' + enc(claims);
 const binary = Buffer.from(pem.replace(/-----[^-]+-----/g,'').replace(/\s/g,''),'base64');
 const key = await crypto.subtle.importKey('pkcs8',binary,algorithm,false,['sign']);
 const signature = await crypto.subtle.sign(algorithm,key,new TextEncoder().encode(body));
 return body + '.' + Buffer.from(signature).toString('base64url');
}
export function createTransport({ mode = 'dry_run', env = {}, fetcher = fetch, clock = () => Date.now() } = {}) {
 if (mode === 'dry_run') return { async send(row) {
  if (row.transport !== 'test') throw new Error('Dry run accepts test devices only');
  return { state:'simulated', receipt:'dry-run:' + row.id };
 }};
 if (mode !== 'live') throw new Error('Invalid push mode');
 return { async send(row) {
  const now = Math.floor(clock()/1000);
  let url,headers,body;
  if (row.transport === 'fcm') {
   const account = JSON.parse(env.FCM_SERVICE_ACCOUNT_JSON ?? '{}');
   if (!account.private_key || !account.client_email || !account.project_id) return {state:'failed',receipt:'FCM_NOT_CONFIGURED'};
   const assertion = await jwt({alg:'RS256',typ:'JWT'},{
    iss:account.client_email,scope:'https://www.googleapis.com/auth/firebase.messaging',
    aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600,
   },account.private_key,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'});
   const tokenReply=await fetcher('https://oauth2.googleapis.com/token',{method:'POST',
    headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}),
    signal:AbortSignal.timeout(10000)});
   if(!tokenReply.ok) return {state:'failed',receipt:'FCM_AUTH_FAILED'};
   const {access_token}=await tokenReply.json();
   if(!access_token) return {state:'failed',receipt:'FCM_AUTH_FAILED'};
   url='https://fcm.googleapis.com/v1/projects/'+encodeURIComponent(account.project_id)+'/messages:send';
   headers={Authorization:'Bearer '+access_token,'Content-Type':'application/json'};
   body={message:{token:row.token,notification:{title:row.message.title},
    data:{eventId:row.message.eventId,matchId:row.message.matchId,notificationId:row.id},
    android:{collapse_key:row.id,notification:{tag:row.id}},apns:{headers:{'apns-collapse-id':row.id}}}};
  } else if(row.transport==='apns') {
   if(!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC)
    return {state:'failed',receipt:'APNS_NOT_CONFIGURED'};
   const token=await jwt({alg:'ES256',kid:env.APNS_KEY_ID},{iss:env.APNS_TEAM_ID,iat:now},
    env.APNS_PRIVATE_KEY,{name:'ECDSA',namedCurve:'P-256',hash:'SHA-256'});
   const host=env.APNS_SANDBOX==='true'?'api.sandbox.push.apple.com':'api.push.apple.com';
   url='https://'+host+'/3/device/'+encodeURIComponent(row.token);
   headers={authorization:'bearer '+token,'apns-topic':env.APNS_TOPIC,'apns-push-type':'alert',
    'apns-id':row.id,'apns-collapse-id':row.id,'Content-Type':'application/json'};
   body={aps:{alert:{title:row.message.title},sound:'default'},eventId:row.message.eventId,
    matchId:row.message.matchId,notificationId:row.id};
  } else return {state:'failed',receipt:'UNSUPPORTED_TRANSPORT'};
  // Once the send starts, an ambiguous failure is never automatically retried.
  try {
   const response=await fetcher(url,{method:'POST',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
   if(response.ok) return {state:'sent',receipt:row.transport==='apns' ? response.headers.get('apns-id') : (await response.json()).name};
   return {state:response.status>=500?'uncertain':'failed',receipt:row.transport.toUpperCase()+'_HTTP_'+response.status};
  } catch { return {state:'uncertain',receipt:'SEND_ACK_UNKNOWN'}; }
 }};
}

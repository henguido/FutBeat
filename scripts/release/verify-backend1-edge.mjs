import {readFileSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,dirname,relative} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const m=JSON.parse(readFileSync(resolve(root,'scripts/release/backend1.edge-sources.json'),'utf8'));
const sha=b=>createHash('sha256').update(b).digest('hex').toLowerCase();
const checked=[];const adaptations=m.localAdaptations;
for(const row of m.inputs){
 if(!row.localPath)continue;
 let data=readFileSync(resolve(root,row.localPath));
 for(const edit of adaptations.filter(x=>x.path===row.localPath)){
  let text=data.toString('utf8');
  if(text.split(edit.to).length!==2)throw Error('Unexpected adaptation count: '+row.localPath);
  data=Buffer.from(text.replace(edit.to,edit.from));
 }
 if(sha(data)!==row.lfSha256)throw Error('Unconfirmed Edge content: '+row.localPath);
 checked.push(row.localPath);
}
const graph=[];const seen=new Set();
function walk(path){
 path=resolve(path);if(seen.has(path))return;seen.add(path);
 if(relative(root,path).startsWith('..')||!existsSync(path))throw Error('Missing or outside-repository import: '+relative(root,path));
 const s=readFileSync(path,'utf8');graph.push(relative(root,path).replaceAll('\\','/'));
 for(const match of s.matchAll(/(?:from\s*|import\s*)['"](\.[^'"]+)['"]/g))walk(resolve(dirname(path),match[1]));
}
for(const slug of Object.keys(m.functions))walk(resolve(root,'supabase/functions',slug,'index.ts'));
const toml=readFileSync(resolve(root,'supabase/config.toml'),'utf8');
for(const [slug,meta] of Object.entries(m.functions)){
 const marker='[functions.'+slug+']';const start=toml.indexOf(marker);if(start<0)throw Error('Missing JWT block '+slug);
 const block=toml.slice(start+marker.length).split(/\n\[/,1)[0];
 if(!new RegExp('verify_jwt\\s*=\\s*'+String(meta.verifyJwt)+'\\b').test(block))throw Error('Wrong JWT mode '+slug);
}
console.log(JSON.stringify({status:'PASS',confirmedSourceInputs:checked.length,closedImportFiles:graph.length,jwtFunctions:Object.keys(m.functions).length,sourceAdaptations:adaptations,uncertified:['global-ingest imported source bytes not read back; clean deploy tree/ezbr evidence retained','passive-api deployed npm resolution unknown; local source pins 1.8.0'],graph},null,2));

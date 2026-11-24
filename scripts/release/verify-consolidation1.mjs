import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, relative } from 'node:path';
const root=fileURLToPath(new URL('../../',import.meta.url));
const manifestPath='scripts/release/consolidation1.sources.json';
const manifest=JSON.parse(readFileSync(resolve(root,manifestPath),'utf8'));
const sha=b=>createHash('sha256').update(b).digest('hex').toUpperCase();
const drift=[],unsafe=[];
for(const row of manifest.files){
 const path=resolve(root,row.path);
 if(relative(root,path).startsWith('..') || /(^|\/)(\.env(?:\.|$)|secure|\.temp)(\/|$)/i.test(row.path))throw Error('Forbidden source path');
 if(!existsSync(path)){drift.push(row.path);continue;}
 const b=readFileSync(path);if(sha(b)!==row.sha256)drift.push(row.path);
 if(b.includes(0))continue;
 const s=b.toString('utf8');
 // Report paths only. Never print a suspected credential.
 if(/-----BEGIN (?:EC |RSA )?PRIVATE KEY-----[\s\S]{32,}?-----END/.test(s)||/sb_secret_[A-Za-z0-9_-]{12,}/.test(s)||/postgres(?:ql)?:\/\/[^\s:/]+:[^\s@]+@/i.test(s))unsafe.push(row.path);
 for(const token of s.match(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g)??[]){
  try{if(JSON.parse(Buffer.from(token.split('.')[1],'base64url')).role==='service_role')unsafe.push(row.path);}catch{}
 }
}
const git=(...args)=>execFileSync('git',['-C',root,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
const required=[...manifest.files.map(x=>x.path),manifestPath,'scripts/release/verify-consolidation1.mjs','docs/release/FUTBEAT-1.0-INTEGRATION-MASTER.md'];
const tracked=new Set(git('ls-files').split('\n'));
const missing=required.filter(p=>!tracked.has(p));
const dirty=git('diff','--name-only','HEAD').split('\n').filter(p=>required.includes(p));
const openGates=Object.entries(manifest.closureGates??{}).filter(([,passed])=>passed!==true).map(([name])=>name);
const result={openGates,pendingPrerequisiteParity:manifest.prerequisiteParityPending,inputs:manifest.files.length,sourceDrift:drift,secretFindings:[...new Set(unsafe)],pendingEdgeParity:manifest.pendingEdgeParity,missingFromGit:missing,dirtyTracked:dirty,commitReady:drift.length===0&&unsafe.length===0&&manifest.pendingEdgeParity.length===0&&(manifest.prerequisiteParityPending??[]).length===0&&openGates.length===0,gitReproductionReady:missing.length===0&&dirty.length===0};
console.log(JSON.stringify(result,null,2));
if(drift.length||unsafe.length||(process.argv.includes('--require-ready')&&!result.commitReady)||(process.argv.includes('--require-clean-git')&&!result.gitReproductionReady))process.exitCode=1;

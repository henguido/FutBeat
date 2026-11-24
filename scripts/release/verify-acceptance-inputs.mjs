import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, relative } from 'node:path';

const root = fileURLToPath(new URL('../../', import.meta.url));
const manifestPath = 'scripts/release/acceptance17.sources.json';
const manifest = JSON.parse(readFileSync(resolve(root, manifestPath), 'utf8'));
if (process.version !== manifest.toolchain.node) throw new Error('Node toolchain differs from frozen contracts');
const sha = value => createHash('sha256').update(value).digest('hex').toUpperCase();
const drift = [];
for (const file of manifest.derivedInputs ?? []) {
  const path = resolve(root, file.path);
  if (existsSync(path) && sha(readFileSync(path)) !== file.sha256) drift.push(file.path);
}
for (const file of manifest.files) {
  const path = resolve(root, file.path);
  if (relative(root, path).startsWith('..')) throw new Error('Input outside repository');
  if (!existsSync(path) || sha(readFileSync(path)) !== file.sha256) drift.push(file.path);
}
const git = (...args) => execFileSync('git', ['-C', root, ...args], {
  encoding:'utf8', stdio:['ignore','pipe','pipe'],
}).trim();
const tracked = new Set(git('ls-files').split('\n'));
const required = [...manifest.files.map(file => file.path), manifestPath];
const missingFromGit = required.filter(path => !tracked.has(path));
const dirtyTracked = git('diff', '--name-only', 'HEAD').split('\n').filter(path => required.includes(path));
const eol = manifest.files.filter(file => file.sha256 !== file.lfSha256).map(file => file.path);
const result = {
  head: git('rev-parse', 'HEAD'),
  candidateSha256: manifest.candidateSha256,
  sourceDrift: drift,
  missingFromGit,
  dirtyTracked,
  rawEolDiffersFromGitLf: eol,
  gitReady: missingFromGit.length === 0 && dirtyTracked.length === 0 && eol.length === 0,
};
console.log(JSON.stringify(result, null, 2));
if (drift.length || (process.argv.includes('--require-clean-git') && !result.gitReady)) process.exitCode = 1;

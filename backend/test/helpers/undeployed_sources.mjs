import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

// Test-only patch reconstruction: never writes a file, applies a deployment,
// or combines the production 300-entity write path with calendar follow-ups.
const root = new URL('../../../', import.meta.url);
const text = async path => (await readFile(new URL(path, root), 'utf8')).replaceAll('\r\n', '\n');
const manifest = JSON.parse(await text('scripts/release/backend1.undeployed-sources.json'));
const sha = s => createHash('sha256').update(s).digest('hex');
export async function readUndeployedSource(path) {
  const row = manifest.files.find(row => row.path === path);
  assert.ok(row, 'Undeployed source must be explicitly pinned');
  let base = await text(path);
  for (const [from, to] of row.baseReplacements) base = base.replaceAll(from, to);
  assert.equal(sha(base), row.baseSha256, 'Patch base drift: ' + path);
  const patch = await text(row.patch);
  const section = patch.split(/(?=^diff --git )/m).find(s => s.startsWith(`diff --git a/${path} b/${path}\n`));
  assert.ok(section, 'Missing patch section: ' + path);
  const input = base.split('\n');
  if (input.at(-1) === '') input.pop();
  const out = []; let cursor = 0;
  const lines = section.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const hunk = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(lines[i]);
    if (!hunk) continue;
    const start = Number(hunk[1]) - 1;
    assert.ok(start >= cursor, 'Overlapping patch hunks');
    out.push(...input.slice(cursor, start)); cursor = start;
    let consumed = 0, added = 0;
    while (++i < lines.length && !lines[i].startsWith('@@ ')) {
      const line = lines[i];
      if (line === '' || line.startsWith('\\')) continue;
      assert.ok([' ', '-', '+'].includes(line[0]), 'Unexpected patch syntax');
      if (line[0] !== '+') { assert.equal(input[cursor++], line.slice(1), 'Patch context: ' + path); consumed++; }
      if (line[0] !== '-') { out.push(line.slice(1)); added++; }
    }
    assert.equal(consumed, Number(hunk[2] ?? 1));
    assert.equal(added, Number(hunk[4] ?? 1));
    i--;
  }
  out.push(...input.slice(cursor));
  const result = out.join('\n') + '\n';
  assert.equal(sha(result), row.targetSha256, 'Undeployed target drift: ' + path);
  return result;
}
export async function importUndeployedModule(path) {
  const url = new URL(path, root);
  const source = (await readUndeployedSource(path)).replace(/from (['"])(\.[^'"]+)\1/g,
    (_match, quote, specifier) => `from ${quote}${new URL(specifier, url).href}${quote}`);
  return import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
}

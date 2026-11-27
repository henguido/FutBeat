import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

// Test-only: re-applies a pinned SQL follow-up that is in Git but NOT deployed, on top of the
// production state that the migrations rebuild. Never writes a file or touches a real database.
const root = new URL('../../../', import.meta.url);
const text = async (path) => (await readFile(new URL(path, root), 'utf8')).replaceAll('\r\n', '\n');
const manifest = JSON.parse(await text('scripts/release/backend1.undeployed-sources.json'));

export async function applyUndeployedSql(db, path) {
  const row = (manifest.sqlFollowUps ?? []).find((r) => r.path === path);
  assert.ok(row, 'Undeployed SQL must be explicitly pinned: ' + path);
  const sql = await text(path);
  assert.equal(createHash('sha256').update(sql).digest('hex'), row.sha256, 'Undeployed SQL drift: ' + path);
  await db.exec(sql);
}

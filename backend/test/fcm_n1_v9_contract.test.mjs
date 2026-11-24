import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fcmDataOf } from '../notifications/transports.mjs';

const fixtures = JSON.parse(await readFile(new URL('./fixtures/fcm_n1_v9_payloads.json', import.meta.url), 'utf8'));
for (const fixture of fixtures) {
  test(`FCM v9 shared Android wire contract: ${fixture.name}`, () => {
    const data = fcmDataOf(fixture.row);
    assert.deepEqual(data, fixture.data);
    assert.ok(Object.values(data).every(value => typeof value === 'string'));
    assert.equal(data.notificationId, fixture.row.id);
  });
}

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(`../../${path}`, import.meta.url), 'utf8');

test('Android release signing is fail-closed and never uses the debug key', async () => {
  const gradle = await read('apps/mobile/android/app/build.gradle.kts');

  assert.doesNotMatch(
    gradle,
    /release\s*\{[^}]*signingConfig\s*=\s*signingConfigs\.getByName\(["']debug["']\)/s,
  );
  assert.match(gradle, /Release signing credentials are not configured/);
  assert.match(gradle, /gradle\.taskGraph\.whenReady/);
  assert.match(gradle, /taskGraph\.allTasks\.any/);
  assert.doesNotMatch(gradle, /startParameter\.taskNames/);
  for (const property of ['storeFile', 'storePassword', 'keyAlias', 'keyPassword']) {
    assert.match(gradle, new RegExp(`"${property}"`));
  }
  assert.match(gradle, /signingConfigs\.getByName\("release"\)/);
});

test('Android launcher declares fallback, adaptive, round, and monochrome resources', async () => {
  const [manifest, adaptive, adaptiveRound] = await Promise.all([
    read('apps/mobile/android/app/src/main/AndroidManifest.xml'),
    read('apps/mobile/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml'),
    read('apps/mobile/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml'),
  ]);

  assert.match(manifest, /android:icon="@mipmap\/ic_launcher"/);
  assert.match(manifest, /android:roundIcon="@mipmap\/ic_launcher_round"/);
  for (const resource of [adaptive, adaptiveRound]) {
    assert.match(resource, /<adaptive-icon/);
    assert.match(resource, /<background/);
    assert.match(resource, /<foreground/);
    assert.match(resource, /<monochrome/);
  }
});

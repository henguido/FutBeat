import { copyFile } from 'node:fs/promises';
await copyFile(new URL('../packages/contracts/demo.snapshot.json', import.meta.url), new URL('../apps/mobile/assets/demo.snapshot.json', import.meta.url));
console.log('Fixture móvil actualizado.');

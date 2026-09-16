import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { mkdir } from 'node:fs/promises';
import { openDatabase, PersistentStore } from '../storage/database.mjs';
import { fetchCostaRica } from '../providers/thesportsdb.mjs';
import { createApi } from './server.mjs';

const directory = resolve(process.env.FUTBEAT_DATA_DIR || '.local-data/postgres');
await mkdir(directory, { recursive: true });
const db = await openDatabase(directory);
const store = new PersistentStore(db);
if (process.argv.includes('--sync')) {
  try {
    console.log(JSON.stringify(await store.import(await fetchCostaRica(), randomUUID())));
  } finally { await db.close(); }
} else {
  const port = Number(process.env.PORT || 8787);
  const host = process.env.HOST || '127.0.0.1';
  const server = createApi(store);
  server.listen(port, host, () => console.log(`FutBeat provider API: http://${host}:${port}/v1/snapshot`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close(async () => { await db.close(); }));
}

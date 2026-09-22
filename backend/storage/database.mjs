import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { normalize } from '../providers/thesportsdb.mjs';
import { validateSnapshot } from '../providers/core/snapshot.mjs';

const known = { 'competition:4815': 'fb_comp_cr', 'team:139705': 'fb_team_car', 'team:139703': 'fb_team_lda' };

export async function openDatabase(directory) {
  const db = await PGlite.create(directory, { extensions: { pg_trgm } });
  // Supabase creates these roles before project migrations. Mirror that
  // prerequisite so permission migrations are exercised locally as written.
  await db.exec(`do $$ begin
    if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
    if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
    if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
  end $$;`);
  await db.exec('create table if not exists public.futbeat_migrations (name text primary key); alter table public.futbeat_migrations enable row level security; revoke all on public.futbeat_migrations from public;');
  // Reconcile local development timestamps with the versions recorded by Supabase.
  for (const [previous, deployed] of [
    ['20260916023038_provider_ingestion.sql', '20260916025345_provider_ingestion.sql'],
    ['20260916025130_cloud_snapshot_read.sql', '20260916025352_cloud_snapshot_read.sql'],
  ]) await db.query('update public.futbeat_migrations set name=$2 where name=$1', [previous, deployed]);
  const folder = new URL('../../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(folder)).filter((name) => name.endsWith('.sql')).sort()) {
    await db.transaction(async (tx) => {
      if ((await tx.query('select name from public.futbeat_migrations where name=$1', [name])).rows.length) return;
      await tx.exec(await readFile(new URL(name, folder), 'utf8'));
      await tx.query('insert into public.futbeat_migrations values ($1)', [name]);
    });
  }
  return db;
}

export class PersistentStore {
  constructor(db, clock = () => new Date()) { this.db = db; this.clock = clock; this.mode = 'provider'; }
  async read() {
    const result = await this.db.query('select snapshot from futbeat_private.imports order by received_at desc, job_id desc limit 1');
    if (!result.rows.length) throw new Error('No imported data');
    const snapshot = result.rows[0].snapshot;
    return { ...snapshot, freshness: { stale: this.clock().getTime() - Date.parse(snapshot.updatedAt) > 6 * 3600000 } };
  }
  async import(raw, jobId, receivedAt = this.clock().toISOString()) {
    if (!jobId || !Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid import identity/time');
    return this.db.transaction(async (tx) => {
      if ((await tx.query('select job_id from futbeat_private.imports where job_id=$1', [jobId])).rows.length) return { duplicate: true };
      const latest = (await tx.query('select received_at from futbeat_private.imports order by received_at desc limit 1')).rows[0];
      if (latest && Date.parse(receivedAt) <= new Date(latest.received_at).getTime()) throw new Error('Out-of-order import');
      const resolve = async (kind, externalId) => {
        const mapping = await tx.query('select canonical_id from futbeat_private.provider_entities where provider=$1 and kind=$2 and external_id=$3', ['thesportsdb', kind, externalId]);
        if (mapping.rows.length) return mapping.rows[0].canonical_id;
        const id = known[`${kind}:${externalId}`] ?? `fb_${kind}_${randomUUID()}`;
        await tx.query('insert into futbeat_private.entities values ($1,$2,$3) on conflict (id) do nothing', [id, kind, JSON.stringify({ id })]);
        await tx.query('insert into futbeat_private.provider_entities values ($1,$2,$3,$4)', ['thesportsdb', kind, externalId, id]);
        return id;
      };
      const batch = validateSnapshot(await normalize(raw, resolve, receivedAt));
      for (const [key, kind] of [['competitions', 'competition'], ['teams', 'team'], ['matches', 'match']]) {
        for (const entity of batch[key]) await tx.query('update futbeat_private.entities set payload=$2 where id=$1', [entity.id, JSON.stringify(entity)]);
        // A limited provider window must never delete previously imported records.
        batch[key] = (await tx.query('select payload from futbeat_private.entities where kind=$1 order by id', [kind])).rows.map((row) => row.payload);
      }
      validateSnapshot(batch);
      await tx.query('insert into futbeat_private.imports values ($1,$2,$3,$4)', [jobId, receivedAt, JSON.stringify(raw), JSON.stringify(batch)]);
      return { duplicate: false, matches: batch.matches.length };
    });
  }
}

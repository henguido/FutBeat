-- Private BFF storage: no direct mobile/Data API access.
create schema futbeat_private;
revoke all on schema futbeat_private from public;
create table futbeat_private.entities (
  id text primary key check (id like 'fb_%'),
  kind text not null check (kind in ('competition', 'team', 'match')),
  payload jsonb not null
);
create table futbeat_private.provider_entities (
  provider text not null,
  kind text not null,
  external_id text not null,
  canonical_id text not null references futbeat_private.entities(id),
  primary key (provider, kind, external_id)
);
create table futbeat_private.imports (
  job_id text primary key,
  received_at timestamptz not null,
  raw_payload jsonb not null,
  snapshot jsonb not null
);
alter table futbeat_private.entities enable row level security;
alter table futbeat_private.provider_entities enable row level security;
alter table futbeat_private.imports enable row level security;
revoke all on all tables in schema futbeat_private from public;

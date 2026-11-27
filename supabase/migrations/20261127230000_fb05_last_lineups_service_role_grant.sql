-- Follow-up to 20261127043800 (FB-05 record, frozen in Release18 as efe7490b): make explicit the
-- service_role grant that production holds on public.futbeat_read_match_last_lineups(text).
-- Production got it from Supabase's default privileges for new public functions; a plain PostgreSQL
-- rebuild has no such default, so without this line it differs from production in that one ACL entry.
-- Idempotent; in production it is a no-op (the grant already exists). No data, no behaviour change.
grant execute on function public.futbeat_read_match_last_lineups(text) to service_role;

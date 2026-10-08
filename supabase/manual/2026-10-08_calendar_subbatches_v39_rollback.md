# Rollback: calendar sub-batches (global-ingest v39)

Use only on a real regression. Each part is independent; go in this order.

1. **Edge v39 → v38.** v38 is the source at `21c71c2`: production version 38,
   `ezbr_sha256` `857f2a9c30d0765b53fcc7b6adb02f6fe2070b65f0c3732ce6bcc62aeb80f2af`.

   ```bash
   git worktree add --detach ../FutBeat-v38 21c71c2
   cd ../FutBeat-v38 && npx.cmd -y supabase functions deploy futbeat-global-ingest --no-verify-jwt
   ```

   Smoke test: a POST without auth returns 403.

2. **Migration `20261008010000`.** Run this only after step 1, because v39 calls the function.

   ```bash
   npx.cmd -y supabase db query --linked -f supabase/manual/20261008010000_calendar_date_finalize_rollback.sql
   npx.cmd -y supabase migration repair --status reverted 20261008010000
   ```

3. **Workflow.** The change is in local commit `5a4e92c`, which is not on `main`. If it ever reaches `main`, revert it with `git revert 5a4e92c` (PR flow). While it is not on `main`, there is nothing to undo.

The data needs no rollback. Sub-batches only upsert, the finalize step only deletes calendar index rows for fixtures GOAL no longer lists for that date, and the coverage row is the same one v38 would write.

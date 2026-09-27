# Account lifecycle v1

This phase keeps guest usage optional while adding password recovery, email
confirmation status/resend, and authenticated self-service account deletion.

## Deletion ownership

`futbeat-delete-account` accepts no user id. Its target is always the subject
of the caller's verified JWT. The function validates the live Auth user and
then uses the server-only Supabase Admin API to delete that same Auth record.
The service-role/secret key never enters the mobile application.

Foreign keys from the private user-owned tables to `auth.users` use
`ON DELETE CASCADE`. Deleting the Auth record is therefore the single database
operation that removes profile preferences, follows, temporary interests,
push devices, and notification outbox entries. Canonical sports entities are
not linked to the Auth record and remain intact. A retry succeeds when that JWT
subject is already absent.

## Release order

No remote deployment is performed by this change. During a later controlled
release:

1. apply `20260927174752_account_deletion_cascade.sql`;
2. deploy `futbeat-delete-account` with JWT verification enabled;
3. verify password-recovery and signup-confirmation email templates plus the
   Auth site/redirect URLs in the target Supabase project;
4. exercise recovery, confirmation resend, deletion, retry, and guest fallback
   with non-production test accounts before publishing the mobile build.

The mobile app retains its local sports catalog, match cache, and local
favorites after cloud-account deletion so guest mode remains usable. It clears
the secure Auth session, tokens, account timers/subscriptions, push enrollment,
and locally stored cloud profile settings.

## Remaining launch configuration

Public Privacy Policy and Terms URLs were not found in the repository. No dead
or invented links are shown; the real public URLs remain a Google Play launch
prerequisite. The password-recovery email destination/deep-link behavior must
also be verified against the target project's Auth URL configuration before
release.

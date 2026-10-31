# MOBILE239 — LIVE observation handoff to Claude

No backend, SQL, cron, provider or production changes were made.

The mobile freshness window remains 15 minutes. Receipt of an HTTP response,
a Realtime frame, a snapshot import or an event minute is not evidence of a
new sports observation. `updated_at` can be rewritten during publication;
the mobile client no longer treats it as renewed sports freshness.

Current safe fallback: use `changed_at` as a conservative lower bound when a
separate provider observation is unavailable. Keep the last known score and
football state with a warning, including when timestamps are absent. Never
infer FINISHED from elapsed time. Existing terminal/revision/canonical-ID
guards remain in effect. Without a trusted HTTP Date, REST freshness remains
unverified; future timestamps fail conservatively. Realtime with clock skew
can also be labelled conservatively until reconciliation.

For a future confirmed contract, expose an explicit UTC observation timestamp
whose semantics are "provider actually observed this fixture", independent
of goal occurrence, content-change and republishing times. The parser accepts
optional `provider_observed_at` on Realtime rows; snapshot presentation accepts
`liveObservedAt` or `provenance.providerObservedAt`. This does NOT assert that
these fields are currently deployed. The REST column selection has not been
expanded to an unverified column. Coordinate that separately if needed.

An unchanged score can therefore be labelled old despite a healthy backend
until that observation contract is available. This conservative warning is
intentional. Missing metadata must not create polling: a synthetic regression
detected 4 context reads in two minutes, fixed to 1. Existing bounded recovery
for dated, stale LIVE overlays remains; no new sports polling was added.

Observation metadata survives the existing SQLite calendar JSON format,
verified by closing and reopening a real local SQLite file. No new schema or
per-event writes were introduced. Realtime overlays retain their existing
in-memory lifecycle; the disk cache remains the last persisted payload, not
a claim that every Realtime frame has been written.

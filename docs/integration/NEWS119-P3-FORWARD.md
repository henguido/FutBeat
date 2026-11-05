# NEWS119 — P3 reader forward correction

`20261019120000_news_pipeline_v2.sql` was changed after its first publication.
An environment that recorded that version does not rerun it. NEWS119 adds a
new version, `20261020212315_news119_p3_reader_forward_compat.sql`, without
editing P3 or changing tables, rows, grants, providers, feeds, or cron.

The correction replaces only
`futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer)`
with the final reader from main. It removes publisher-country fallback for an
untagged story and supplies `sourceCountryCode`, `language`,
`inSelectedCountry`, and `storyCountryNames`. The NEWS115 public rights wrapper
remains in place.

## Apply order and STOP gate

Apply after P3, shared retention, NEWS110/111, and NEWS115 rights. Before any
authorized staging application, inspect the migration ledger and the current
private reader. The migration accepts only the known original P3 body
(`0073fe6b0bd1fad59d526cccaf9fb03b`) or final main body
(`85ede30c7ad35dc049d62042f42d65f8`), with CRLF normalized. Stop if the
ledger, function body, NEWS115 wrapper, or source table differs. Do not repair
the ledger by hand or apply this migration directly to production.

The SQL uses one short transaction, a 5-second lock timeout, and a 30-second
statement timeout. The function body is byte-equivalent to the final P3 reader.
Reapplying it to a clean installation is safe; the normal migration ledger
should still run it only once.

## Local native PostgreSQL 17.6 verification

Two disposable databases were built from the repository migrations:

- Clean: all 157 migrations, including NEWS119.
- Historical: original P3 from `2eacd8f`, subsequent 2026 migrations, then NEWS119.

Before NEWS119, the historical reader omitted all four metadata fields and
incorrectly placed an untagged `as.com` story in Spain's country tab. Both
databases now have the same reader hash, expose the fields, and exclude that
story from the country tab. Native tests also covered v1/v2 retention,
per-field rights revocation, 30-second rights expiry, and disabled feeds.
Application to the historical database took 85 ms in the tiny local fixture;
article/source/feed counts stayed 1/20/6 and WAL advanced about 3.3 KiB.
Those measurements are not production performance estimates.

Controlled local reversal restored only the historical function definition:
article rows and the v1 reader remained. NEWS119 was then reapplied. There is
no automatic remote rollback: restoring the old function also restores its
incorrect country classification. For a staging incident, pause the v2 API
and review a function-only reversal separately; never drop shared news data.

No staging or production migration was run. All sources remain disabled.

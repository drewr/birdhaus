# Design: a reproducible AWS account, and moving off the sandbox

Status: built and run (2026-10-29). The resources live in the owner's account, and the sandbox resources are gone.

## Context

All Birdhaus AWS resources used to live in the `datum-sandbox-admin` account (007091975061), which is meant for experiments. They moved to the owner's own account (profile `drewr-admin`, us-east-1). It was a good moment:
- The database holds only test data: one test waitlist entry, no orders, and Umami's first page views.
- SES never finished verifying `birdhaus.store` in the sandbox (DKIM still `PENDING`), so no working alert email is lost.
- The new account generates new DKIM records anyway.

The data must survive the move, and the Postgres entrypoint must never start against an empty bucket, because it would `initdb` a fresh database.

## What existed in the sandbox (recreated, then deleted)

- **S3:** bucket `birdhaus-pg-007091975061-use1`, prefix `birdhaus-db/` (WAL-G base backups and WAL), versioned.
- **IAM:** managed policy `/birdhaus-pg/birdhaus-pg-deployment`, and user `birdhaus-pg-birdhaus-db` (tag `deployment=birdhaus-db`) with one access key.
- **birdhaus-watch:**
  - Lambda `birdhaus-watch` and its function URL.
  - DynamoDB table `birdhaus-watch`.
  - Roles `birdhaus-watch` and `birdhaus-watch-scheduler`.
  - Schedules `birdhaus-watch-sweep` and `birdhaus-watch-digest`.
  - SES identities `birdhaus.store` and the alert address.
- **Datum Secrets that point at the sandbox:** `birdhaus-db-aws` (key, region, `WALG_S3_PREFIX`) and `birdhaus-db-watch` (watch URL and token).
- **DNS:** three SES DKIM CNAMEs in `dns/cname.yaml`.

## Steps (what the scripts below automate, in order)

1. **Log in:** `aws login --profile drewr-admin` (the operator). Confirm the account ID, and that it has no `birdhaus-*` resources yet.
2. **Bucket and IAM in drewr:** `AWS_PROFILE=drewr-admin ./postgres/aws/bootstrap.hs bucket`. It derives `birdhaus-pg-<drewr-account>-use1` with the same settings (public access block, SSE, TLS-only, versioning, lifecycle) and the shared policy. Then run `test-isolation` there.
3. **Freeze and copy the data:**
   - Pause Umami: scale it to 0, or accept a few lost page views.
   - In the running database: `checkpoint; select pg_switch_wal();`, then wait until `pg_stat_archiver` shows that segment archived and no `.ready` files remain.
   - Copy the prefix from the sandbox to the new bucket with each profile's own credentials: `aws s3 sync s3://old/birdhaus-db/ <local temp dir>` with the sandbox profile, then `aws s3 sync <temp> s3://new/birdhaus-db/` with drewr. It's small (MBs). Compare object counts and total bytes, then delete the temp dir.
4. **Switch Postgres:**
   - Delete the Datum Secret `birdhaus-db-aws` and run `bootstrap.hs deployment birdhaus-db drewr-y4nd1b` with drewr. That creates the new user and key and recreates the Secret with the new prefix.
   - `datumctl compute restart birdhaus-pg`. The entrypoint restores from the new bucket; check the log line names the new bucket.
5. **Verify the data:** waitlist and orders counts match the values from before the move, and Umami's tables are intact. A fresh base backup and new WAL land in the new bucket, and `pg_stat_archiver.failed_count` is 0.
6. **Watcher in drewr:**
   - `AWS_PROFILE=drewr-admin ./ops/watch/deploy.hs deploy --to <alert email> --project drewr-y4nd1b`. The operator clicks the new SES verification link.
   - Replace the three sandbox DKIM CNAMEs in `dns/cname.yaml` with the new ones and apply (needs the operator's approval).
   - Delete and recreate `birdhaus-db-watch` (the function URL and token are new), then redeploy Postgres with `postgres/deploy.hs --workload birdhaus-pg`. That's already idempotent, and it attaches the Secret.
7. **Verify alerting:**
   - The `postgres` heartbeat arrives and the probes pass (`deploy.hs status`).
   - When SES verifies, `test-alert` arrives with DKIM pass.
   - If SES stays `PENDING` well past an hour with correct DNS, recreate the identity to force a check.
8. **Delete from the sandbox** (sandbox profile; done 2026-10-29):
   - `AWS_PROFILE=datum-sandbox-admin ./ops/aws-account.hs destroy --confirm 007091975061 --project drewr-y4nd1b --session <datum-session>`.
   - The sandbox watcher had already gone: no table, Lambda, schedules or SES identities remained. The command removed the IAM user and its key, the shared policy, and the bucket (114 object versions and delete markers).
   - Datum's `birdhaus-store-db` was unaffected; it's Stripe and database settings only.
9. **Docs:** replace sandbox references (account ID, the profile name `datum-sandbox-admin`, the "sandbox AWS account" wording) in `docs/design/postgres-s3.md`, `postgres/README.md`, `ops/watch/README.md` and `AGENTS.md`. Commit `dns/ses.yaml` with the new records and remove the three sandbox SES records from `dns/cname.yaml`.

## Everything in code: one entry point for a fresh account

Every piece of AWS setup must be reproducible from the repo, so the steps above are performed by scripts, not by hand. A new top-level script `ops/aws-account.hs` (turtle, same conventions) runs the existing ones in order, and each existing script gains what it's missing.

`ops/aws-account.hs` subcommands, all run with `AWS_PROFILE` set to an admin profile for the target account:

- **`setup --project P --alert-to EMAIL`:** idempotent, safe to re-run.
  1. `postgres/aws/bootstrap.hs bucket`: bucket, policy, settings.
  2. `postgres/aws/bootstrap.hs deployment birdhaus-db P`, if the IAM user or the Datum Secret doesn't exist.
  3. `ops/watch/deploy.hs deploy --to EMAIL --project P`.
  4. Writes `dns/ses.yaml`: a separate DNSRecordSet `birdhaus-store-ses` holding the SES DKIM CNAMEs, generated from SES. Being its own record set, regenerating it never touches the Stripe records in `dns/cname.yaml`.
  5. Prints the remaining manual steps: apply `dns/ses.yaml` (DNS changes need approval), click the SES verification email, then redeploy Postgres so it picks up `birdhaus-db-watch`.
- **`copy-data --from-profile OLD --project P`:** copies `birdhaus-db/` from the old account's bucket to this account's bucket. (`--project` locates the source instance for the WAL check.)
  - It closes the source's current WAL segment (`pg_switch_wal`) and waits until the archive has drained, using `pg_stat_archiver` and `ls archive_status` inside the instance. Writes after that switch are not copied, so pause consumers first.
  - It refuses if the destination prefix isn't empty.
  - It verifies object counts and bytes after copying.
- **`switch --project P`:** points Postgres at this account.
  - Recreates `birdhaus-db-aws` and `birdhaus-db-watch` from this account's resources (deletes the old Secrets first). The alert address comes from the new `birdhaus-watch` Lambda.
  - Refuses unless the new bucket holds a base backup.
  - Restarts the Postgres workload, waits for recovery, and prints row counts.
- **`destroy --confirm ACCOUNT_ID --project P`:** removes every Birdhaus resource in the account, by delegating to `ops/watch/deploy.hs destroy`, `postgres/aws/bootstrap.hs destroy` and `destroy-bucket`. (`--project` lets it read the Datum Secret that would still be pointing at the account.)
  - It refuses if the account is the one the Datum Secrets currently point at, or if `--confirm` doesn't match the account ID.
  - This is how the sandbox gets cleaned up.

Additions to the existing scripts:
- **`ops/watch/deploy.hs`:**
  - A `destroy` subcommand: schedules, function URL and permissions, Lambda, table, both roles, SES identities.
  - A `dkim` subcommand that prints the CNAMEs as YAML for `aws-account.hs` to write.
  - Drop the hand-edit instructions from its output.
- **`postgres/aws/bootstrap.hs`:** a `destroy-bucket` subcommand (all versions and delete markers, then the bucket, then the shared policy once no user uses it). `destroy NAME` already removes a deployment's user.
- **`dns/cname.yaml`:** remove the three sandbox SES records, since SES records now live in the generated `dns/ses.yaml`.
- **Docs:** a new "Fresh AWS account" section in `README.md`. It covers the prerequisite (an admin profile), the `setup` command, and the two manual steps (DNS approval and the SES verification click). It also covers moving accounts: `setup`, `copy-data`, `switch`, then `destroy` the old account.

The move ran as: `setup` (drewr) → apply `dns/ses.yaml` and click verify → `copy-data --from-profile datum-sandbox-admin --project P` → `switch --project P` → check → `destroy` (sandbox).

## Operational note (2026-10-31)

The `drewr-admin` profile is the `drewr` IAM user. It can use S3, Lambda, DynamoDB, Scheduler and SES, but it has no IAM permissions, so `setup`, `destroy` and a full `ops/watch/deploy.hs deploy` need an IAM admin (`drewr-root`, the account root, or the SSO administrator). Checks-only watcher changes use `ops/watch/deploy.hs code`, which needs only Lambda.

## Rollback

Rollback was available until the sandbox resources were deleted on 2026-10-29: recreate `birdhaus-db-aws` with the sandbox key (`bootstrap.hs rotate` with the sandbox profile) and restart Postgres. It restored from the old bucket, which had everything up to the switch. That path is now closed.

## Verification

- Before and after counts of waitlist, orders and Umami's `website_event` rows match.
- `wal-g backup-list` inside the instance lists backups in the new bucket only. `aws s3 ls` with drewr shows new WAL arriving every few minutes.
- `ops/watch/deploy.hs status` (drewr) shows every check up. The test alert arrives.
- The sandbox account has no `birdhaus-*` resources left (S3, IAM, Lambda, DynamoDB, Scheduler, SES).
- The only remaining mention of the sandbox account ID is in this design doc.

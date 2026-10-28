# Design: S3-backed PostgreSQL on Datum Compute

Status: built and deployed as `birdhaus-db` in the sandbox project (us-east-1). Consumers are not connected yet.

## Problem

Birdhaus has no persistence. Orders exist only as Stripe PaymentIntents, and self-hosted analytics (Umami) needs a Postgres. Datum Compute offers no durable disks, so a Postgres instance loses its data whenever the instance is replaced. This design makes S3 the durable store: Postgres runs on the instance's local disk, continuously archives to S3, and a replacement instance restores itself from S3 on boot.

## Goals and non-goals

Goals:
- A single Postgres that loses at most about 60 seconds of writes if its instance disappears.
- A stable address that consumers (the store, Umami, other projects) can hold in configuration.
- Reusable: another project can deploy the same thing with its own bucket and credentials.

Non-goals: high availability or automatic failover (restore takes minutes), read replicas, and databases larger than the instance's local disk.

## Constraints from the platform

- Only the `general-purpose` runtime class (a lightweight VM running standard Linux containers) can run Postgres. The `unikernel` class keeps its root filesystem in memory and has no disk volumes.
- `general-purpose` offers no durable disks and no snapshots: storage lives and dies with the instance. S3 is the only durability.
- Instances sit on the project's private IPv6 network. There is no service discovery, so consumers connect to an IPv6 address. A network interface with `reclaimPolicy: Retain` keeps its address when the instance is replaced.
- Instances have no cloud IAM role, so S3 access needs a static access key stored in a Datum secret.
- Interfaces are IPv6-only, but the instance's DNS64/NAT64 makes IPv4-only hosts such as S3 reachable (see the spike results).

## Architecture

```
 birdhaus-store (unikernel) ─┐                          S3 (same region)
 umami                   ────┼── IPv6 :5432 ──► birdhaus-db ──► wal-push     (WAL, at least every 60 s)
 other projects          ────┘   (retained     (general-purpose,  backup-push  (daily base backup)
                                  address)       Postgres + WAL-G) ◄── backup-fetch + wal-fetch (restore on boot)
```

### Image

`postgres/Dockerfile`: the official `postgres:17-bookworm` image plus a pinned, checksum-verified WAL-G binary and `tini`.

### Boot sequence (`postgres/entrypoint.sh`)

1. If `PGDATA` is empty and S3 holds a backup: `wal-g backup-fetch LATEST`, create `recovery.signal`, and set `restore_command='wal-g wal-fetch %f %p'` and `recovery_target_timeline=latest`.
2. If `PGDATA` is empty and S3 has no backup: `initdb`, then create each database and role listed in the configuration.
3. Write configuration overrides: `archive_mode=on`, `archive_command='wal-g wal-push %p'`, `archive_timeout=60`, `wal_level=replica`, `listen_addresses='*'`, `password_encryption=scram-sha-256`. `pg_hba.conf` accepts only scram-sha-256 on the private network, and the `postgres` superuser is reachable only over the local socket (it has no password). Each boot reconciles databases, roles and passwords, so adding a database or rotating a password is a secret change plus a restart.
4. Run Postgres under tini. A background loop runs `wal-g backup-push` daily (and once shortly after first start) and `wal-g delete retain FULL 7 --confirm`.
5. On SIGTERM: `pg_switch_wal()`, wait for the archive to drain, then a fast shutdown.

### Workload

- `runtime.class: general-purpose`, instance type `datumcloud-d1-standard-2`, in the same location as the consumers and the bucket.
- `reclaimPolicy: Retain` on `eth0`, so consumers keep a stable `PGHOST`.
- `drop: [ALL]` plus `add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID]`, which the spike showed is enough for the stock Postgres image.
- Configuration through two secrets: AWS credentials, bucket and prefix (as environment), and role passwords (mounted as a volume).
- Optionally, an interface `networkPolicy` that admits only the consumers' addresses.

### S3 and IAM

**Isolation model: one shared bucket, one prefix per deployment, one IAM user per deployment, one shared policy.** A deployment is one Postgres cluster (for example `birdhaus-db`). Deployments cannot see each other's backups or WAL.

- **Bucket** (`birdhaus-pg-<account-id>-<region code>` (for example `use1`)): public access blocked, owner-enforced ownership (no ACLs), SSE-S3 default encryption, versioning on, HTTPS required by bucket policy, and a lifecycle rule that expires noncurrent versions after 14 days and aborts incomplete multipart uploads after 7. Versioning means a mistaken `wal-g delete` is recoverable for 14 days.
- **Prefix**: `s3://<bucket>/<deployment>/`. Deployment names match `^[a-z0-9][a-z0-9-]{1,40}$`, and every grant ends in `/`, so `app` cannot reach `app-2/`.
- **IAM user** `birdhaus-pg-<deployment>` under the path `/birdhaus-pg/`, tagged `deployment=<deployment>`. It has no IAM permissions, so it cannot change its own tag or policy.
- **One shared managed policy** (`birdhaus-pg-deployment`) uses the user's tag as a policy variable, so adding a deployment never means writing or editing a policy:
  - `ListBucket` and `ListBucketMultipartUploads` on the bucket, only when `s3:prefix` matches `${aws:PrincipalTag/deployment}/*`
  - `GetObject`, `PutObject`, `DeleteObject`, `AbortMultipartUpload` and `ListMultipartUploadParts` on `<bucket>/${aws:PrincipalTag/deployment}/*`
  - an explicit `Deny` on all of S3 when the tag is missing
- **Credentials:** instances have no cloud IAM role, so each deployment gets one static access key, stored in the Datum secret `<deployment>-aws` along with `AWS_REGION` and `WALG_S3_PREFIX`. The secret is created with `datumctl create`, not `apply`, because `apply` copies the secret's contents into a plaintext `last-applied-configuration` annotation. Keys rotate with `bootstrap.hs rotate`, which creates the new key before deleting the old one.
- **What an operator can still do:** whoever has `iam:TagUser` or `iam:AttachUserPolicy` in the AWS account (the admin) can break isolation by retagging. That is acceptable because that person already controls the bucket. For a stronger boundary, give each deployment its own bucket, or enable WAL-G client-side encryption (`WALG_LIBSODIUM_KEY`) with a key held only in the deployment's secret.
- **WAL-G endpoint:** WAL-G can use the default regional S3 endpoint, with NAT64 handling the IPv4-only address. The dual-stack endpoint (`s3.dualstack.<region>.amazonaws.com`) also works and avoids NAT64, so prefer it.

`postgres/aws/bootstrap.hs` implements this. The bucket is `--bucket`, else `$BUCKET`, else the derived name for the active AWS account and region. (`bucket`, `deployment`, `rotate`, `destroy`). `destroy` removes the user and key but keeps the data. `test-isolation` creates throwaway deployments and proves the boundary with real credentials, then deletes them. It checks that a deployment can use its own prefix and is denied on:

- another deployment's objects (get, put, delete and list)
- a whole-bucket list
- a prefix-confusion list (`x` against `x-2`)
- an untagged user
- retagging itself, attaching an admin policy and changing the bucket policy
- plain HTTP

### Consumers

One cluster, one database and role per consumer (for example `umami` and `birdhaus`), declared by a `DATABASES` list with a password per database in the secret. Roles cannot read each other's databases.

- **Umami:** a separate workload pointing at the database address.
- **Birdhaus orders:** a schema migration and a `POST /api/stripe-webhook` handler that verifies Stripe's signature and records `payment_intent.succeeded`. This also closes the webhook gap noted in `AGENTS.md`.

## Planned files

- `postgres/Dockerfile`, `entrypoint.sh` (the only shell script, since it runs inside the container image), `birdhaus.conf` (settings included from `postgresql.conf`), `pg_hba.conf` (all written)
- `postgres/deploy.hs`: a turtle script in the style of `run.hs` that builds, pushes and deploys the workload. All names, the bucket, prefix, databases and instance size are parameters.
- `postgres/aws/bootstrap.hs` (written): bucket and shared policy, per-deployment IAM user and Datum secret, rotation, and the isolation test. It never writes keys to disk.
- `postgres/README.md`: operations, including connecting with `datumctl compute exec`, the restore drill, key rotation and teardown.

## Spike results (2026-10-26)

A throwaway `general-purpose` workload in us-east-1 (`datumcloud-d1-standard-2`), since destroyed, showed:

- **S3 is reachable over IPv6.** The dual-stack endpoint answers on native IPv6 (about 20 ms for a request), and the default endpoint answers through NAT64 (`64:ff9b::/96`, about 15 ms). A request to an existing bucket returned 403, which proves S3 answered. Instances use Google DNS64 resolvers. Real PUT and GET throughput was not measured, since the spike had no credentials.
- **Stock Postgres 17 runs with five capabilities** (`CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID`), listening on IPv4 and IPv6. A client reached it over the instance's private IPv6 address and was asked for a password.
- **A restart replaces the instance and loses local data.** After `datumctl compute restart`, the new instance's Postgres had a fresh start time and the table was gone. This is the failure the S3 design recovers from. The replacement was available in about 7 seconds, so most restore time will be fetching and replaying from S3.
- **The address survived replacement** even with `reclaimPolicy: Delete`, because the instance slot persisted. Keep `Retain` anyway, since it also covers destroy and recreate.
- **Disk:** the root filesystem reports 1.7 TB, but it is a host-level overlay (59 GB already used), so the figure says nothing about the instance's quota. Find the real limit before relying on size. The instance shows 3.9 GB of memory, more than the 2 GiB instance type name suggests.
- **Operating note:** `datumctl compute exec <instance> -- psql -U …` failed with "no project set". Wrapping the command as `-- sh -c "psql …"` worked.

## Build order

1. **Spike: done** (see above). Still open: the instance's real disk limit and S3 throughput with credentials.
2. **Bucket and shared policy: done**, and `test-isolation` passes. Per-deployment users and secrets are created on demand with `bootstrap.hs deployment`.
3. **Image and entrypoint: done**, and tested (see below).
4. **`deploy.hs` and the deploy: done.**
5. **Restore drill on Datum: done** (see below). The loss-bound and consumer-path drills have not been run on Datum.
6. Connect a consumer, then build the Umami and order-record work.

## Image test results (2026-10-26)

Run under colima with temporary admin credentials and a throwaway prefix in the real bucket (since deleted):

- **Fresh boot:** no backups, so `initdb`, then a base backup about 15 s after start, and the `birdhaus` and `umami` databases and roles created.
- **Restore after a clean stop:** SIGTERM (`pg_switch_wal()` then a fast shutdown), then a new container with an empty disk. It fetched the base backup in 2 s, replayed WAL, and all 1000 rows were back, including rows written after the base backup.
- **Restore after a hard kill:** 100 rows written and archived by `archive_timeout`, then 100 more, then `kill -KILL`. The restore had the first 100 and lost the second 100, which is the expected loss window. It came up on timeline 2 and took a fresh base backup.
- **Isolation:** the `umami` role is refused (`no CONNECT privilege`) on the `birdhaus` database, and the `postgres` superuser is rejected over TCP.
- **Safety:** if `wal-g backup-list` fails, the entrypoint exits instead of running `initdb`, so a transient S3 error cannot fork the cluster's history.
- The WAL-G v3.0.9 download is checksum-verified for amd64 and arm64. Only arm64 was run (colima); amd64 is what Datum will run and has not been exercised.

## Deployment results (2026-10-27)

- **Image type:** `datumctl compute build` produces a unikernel image (`os: kraftcloud`), which a general-purpose workload cannot pull (`ImageUnavailable`). `deploy.hs` builds an ordinary amd64 image with nerdctl in colima and pushes it to GHCR.
- **Boot:** the five capabilities were enough. With the per-deployment IAM key, the instance initialised, took a base backup 5 s after start, and `pg_stat_archiver.failed_count` stayed 0, over the dual-stack S3 endpoint.
- **Restore drill:** 500 rows written, `pg_switch_wal()`, `datumctl compute restart`. The new instance fetched the base backup in 1 s, replayed WAL, and had all 500 rows about 8 s after the restart. The address (`fd20:0:1:1:0:4::`) did not change.
- **Disk:** `df` still shows a 1.8 TB host overlay, so the instance's real quota is unknown.

## Moving to the birdhaus VPC (2026-10-27)

The `birdhaus` Network (`network/birdhaus.yaml`, `fd20:0:4a::/48`) now holds the store and the database. Moving the database was a test of the design: the workload was recreated on the new network, and the new instance restored from S3 in about 5 s with the same databases and roles. Its address changed (`fd20:0:4a::1:0:0`), so consumers need the new `PGHOST`.

- **Platform gotcha:** changing a workload's network does not work in place for a workload with `reclaimPolicy: Retain`. The retained interface stays bound to the old network, and the instance fails with `NetworkMismatch` even after the interface and workload are deleted, because the instance name (`<workload>-default-<location>-0`) keeps pointing at the stale holder. Instances cannot be deleted by a project user. The workaround was a new workload name (`birdhaus-pg`), which gets a new interface name. The store has `reclaimPolicy: Delete` and moved in place with no problem.
- The store (`fd20:0:4a::2:0:0`) and database share the network, but the store has no database client yet, so that path is untested. From inside the database instance, a scram login as `birdhaus` over its own VPC address works.

## Verification

- **Archiving works:** the workload logs show archiving, `pg_stat_archiver.failed_count` is 0, and `wal-g backup-list` shows a base backup.
- **Restore drill:** create rows, run `pg_switch_wal()`, then `datumctl compute restart` so the instance is replaced and its disk is lost. After boot the rows are back and the address is unchanged. Record the restore time.
- **Loss bound:** write rows and stop the instance abruptly. The loss must be under about 60 seconds of writes.
- **Consumer path:** a second workload on the same network connects with scram, and a role cannot reach another consumer's database.
- **Security:** `git grep` finds no keys or passwords, the bucket blocks public access, and the IAM policy denies access outside its prefix (test with a second prefix).
- **Cost:** record the bucket size after a day of use.

## Risks

- **Silent failure** (archiving stops while Postgres keeps serving) is now watched: the entrypoint reports to birdhaus-watch (`ops/watch/`), which emails the operator. Tested by revoking the database user's S3 access, which was detected in 4.5 minutes.

- **Local disk size** caps the database and the real limit is still unknown (the spike could not tell). Find it before storing anything large; beyond it, use a larger instance type or keep cold data elsewhere.
- **Replacement downtime:** a restore takes minutes, and consumers see connection errors meanwhile. Clients need retries, and the unikernel app must not crash-loop on a missing database.
- **Not highly available**, by choice.
- **A static key in a secret** is the only credential path available. Limit its policy to one prefix and document rotation.
- **Sandbox account:** moving to a production AWS account later means re-running the bootstrap with a different account and bucket.

# Design: S3-backed PostgreSQL on Datum Compute

Status: proposed. Nothing described here is built yet.

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
- Interfaces are IPv6-only unless dual-stack is requested, so S3 must be reached through its dual-stack endpoint. This is unproven and is the first thing to test.

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
3. Write configuration overrides: `archive_mode=on`, `archive_command='wal-g wal-push %p'`, `archive_timeout=60`, `wal_level=replica`, `listen_addresses='*'`, `password_encryption=scram-sha-256`. `pg_hba.conf` accepts only scram-sha-256 on the private network.
4. Run Postgres under tini. A background loop runs `wal-g backup-push` daily (and once shortly after first start) and `wal-g delete retain FULL 7 --confirm`.
5. On SIGTERM: `pg_switch_wal()`, wait for the archive to drain, then a fast shutdown.

### Workload

- `runtime.class: general-purpose`, instance type `datumcloud-d1-standard-2`, in the same location as the consumers and the bucket.
- `reclaimPolicy: Retain` on `eth0`, so consumers keep a stable `PGHOST`.
- The extra Linux capabilities a stock Postgres container needs (CHOWN, FOWNER, DAC_OVERRIDE, SETUID, SETGID, KILL, and similar), trimmed to the minimum after testing.
- Configuration through two secrets: AWS credentials, bucket and prefix (as environment), and role passwords (mounted as a volume).
- Optionally, an interface `networkPolicy` that admits only the consumers' addresses.

### S3 and IAM

- One bucket per environment, named `birdhaus-pg-<account-id>-<region>`: public access blocked, SSE-S3 encryption, versioning on, a lifecycle rule that expires noncurrent versions and incomplete multipart uploads after 14 days.
- One prefix per cluster (for example `birdhaus-db/`), so one bucket can serve several deployments.
- A dedicated IAM user whose policy allows only `s3:ListBucket` (limited to the prefix) and Get, Put and Delete on objects under it. Its access key lives in a Datum secret and never in git.
- WAL-G uses the S3 dual-stack endpoint (`https://s3.dualstack.<region>.amazonaws.com`), with path-style addressing if needed.

### Consumers

One cluster, one database and role per consumer (for example `umami` and `birdhaus`), declared by a `DATABASES` list with a password per database in the secret. Roles cannot read each other's databases.

- **Umami:** a separate workload pointing at the database address.
- **Birdhaus orders:** a schema migration and a `POST /api/stripe-webhook` handler that verifies Stripe's signature and records `payment_intent.succeeded`. This also closes the webhook gap noted in `AGENTS.md`.

## Planned files

- `postgres/Dockerfile`, `entrypoint.sh`, `postgresql.conf.tmpl`, `pg_hba.conf`
- `postgres/deploy.hs`: a turtle script in the style of `run.hs` that builds, pushes and deploys the workload. All names, the bucket, prefix, databases and instance size are parameters.
- `postgres/aws/bootstrap.sh`: an idempotent script that creates the bucket, lifecycle rules, IAM user and policy, and the Datum secrets, without writing keys into the repository.
- `postgres/README.md`: operations, including connecting with `datumctl compute exec`, the restore drill, key rotation and teardown.

## Build order

1. **Spike (go/no-go):** deploy a throwaway `general-purpose` workload. Confirm it can reach the S3 dual-stack endpoint over IPv6, that the Postgres image starts with the trimmed capabilities, and how much local disk it has. If S3 is unreachable over IPv6, stop and rethink (for example a dual-stack interface) before building more.
2. Create the bucket, IAM user and policy, and the Datum secrets.
3. Build the image and entrypoint. Test locally for init, restore and the SIGTERM path.
4. Write `deploy.hs` and deploy.
5. Run the drills below.
6. Connect a consumer, then build the Umami and order-record work.

## Verification

- **Archiving works:** the workload logs show archiving, `pg_stat_archiver.failed_count` is 0, and `wal-g backup-list` shows a base backup.
- **Restore drill:** create rows, run `pg_switch_wal()`, then `datumctl compute restart` so the instance is replaced and its disk is lost. After boot the rows are back and the address is unchanged. Record the restore time.
- **Loss bound:** write rows and stop the instance abruptly. The loss must be under about 60 seconds of writes.
- **Consumer path:** a second workload on the same network connects with scram, and a role cannot reach another consumer's database.
- **Security:** `git grep` finds no keys or passwords, the bucket blocks public access, and the IAM policy denies access outside its prefix (test with a second prefix).
- **Cost:** record the bucket size after a day of use.

## Risks

- **S3 over IPv6 is unproven.** The spike comes first for this reason.
- **Local disk size** caps the database. The spike reports it; beyond that, use a larger instance type or keep cold data elsewhere.
- **Replacement downtime:** a restore takes minutes, and consumers see connection errors meanwhile. Clients need retries, and the unikernel app must not crash-loop on a missing database.
- **Not highly available**, by choice.
- **A static key in a secret** is the only credential path available. Limit its policy to one prefix and document rotation.
- **Sandbox account:** moving to a production AWS account later means re-running the bootstrap with a different account and bucket.

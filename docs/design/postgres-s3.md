# Design: S3-backed PostgreSQL on Datum Compute

Status: proposed; the platform spike (below) passed. Nothing else is built yet.

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
3. Write configuration overrides: `archive_mode=on`, `archive_command='wal-g wal-push %p'`, `archive_timeout=60`, `wal_level=replica`, `listen_addresses='*'`, `password_encryption=scram-sha-256`. `pg_hba.conf` accepts only scram-sha-256 on the private network.
4. Run Postgres under tini. A background loop runs `wal-g backup-push` daily (and once shortly after first start) and `wal-g delete retain FULL 7 --confirm`.
5. On SIGTERM: `pg_switch_wal()`, wait for the archive to drain, then a fast shutdown.

### Workload

- `runtime.class: general-purpose`, instance type `datumcloud-d1-standard-2`, in the same location as the consumers and the bucket.
- `reclaimPolicy: Retain` on `eth0`, so consumers keep a stable `PGHOST`.
- `drop: [ALL]` plus `add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID]`, which the spike showed is enough for the stock Postgres image.
- Configuration through two secrets: AWS credentials, bucket and prefix (as environment), and role passwords (mounted as a volume).
- Optionally, an interface `networkPolicy` that admits only the consumers' addresses.

### S3 and IAM

- One bucket per environment, named `birdhaus-pg-<account-id>-<region>`: public access blocked, SSE-S3 encryption, versioning on, a lifecycle rule that expires noncurrent versions and incomplete multipart uploads after 14 days.
- One prefix per cluster (for example `birdhaus-db/`), so one bucket can serve several deployments.
- A dedicated IAM user whose policy allows only `s3:ListBucket` (limited to the prefix) and Get, Put and Delete on objects under it. Its access key lives in a Datum secret and never in git.
- WAL-G can use the default regional S3 endpoint; NAT64 handles the IPv4-only address. The dual-stack endpoint (`s3.dualstack.<region>.amazonaws.com`) also works and avoids NAT64, so prefer it.

### Consumers

One cluster, one database and role per consumer (for example `umami` and `birdhaus`), declared by a `DATABASES` list with a password per database in the secret. Roles cannot read each other's databases.

- **Umami:** a separate workload pointing at the database address.
- **Birdhaus orders:** a schema migration and a `POST /api/stripe-webhook` handler that verifies Stripe's signature and records `payment_intent.succeeded`. This also closes the webhook gap noted in `AGENTS.md`.

## Planned files

- `postgres/Dockerfile`, `entrypoint.sh`, `postgresql.conf.tmpl`, `pg_hba.conf`
- `postgres/deploy.hs`: a turtle script in the style of `run.hs` that builds, pushes and deploys the workload. All names, the bucket, prefix, databases and instance size are parameters.
- `postgres/aws/bootstrap.sh`: an idempotent script that creates the bucket, lifecycle rules, IAM user and policy, and the Datum secrets, without writing keys into the repository.
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

- **Local disk size** caps the database and the real limit is still unknown (the spike could not tell). Find it before storing anything large; beyond it, use a larger instance type or keep cold data elsewhere.
- **Replacement downtime:** a restore takes minutes, and consumers see connection errors meanwhile. Clients need retries, and the unikernel app must not crash-loop on a missing database.
- **Not highly available**, by choice.
- **A static key in a secret** is the only credential path available. Limit its policy to one prefix and document rotation.
- **Sandbox account:** moving to a production AWS account later means re-running the bootstrap with a different account and bucket.

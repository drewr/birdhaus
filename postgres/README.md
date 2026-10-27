# Postgres on Datum Compute, durable in S3

One Postgres per deployment (default `birdhaus-db`) runs on a general-purpose instance's local disk and continuously archives to S3 with WAL-G. A replacement instance restores itself from S3 on boot. Design and test results: [`docs/design/postgres-s3.md`](../docs/design/postgres-s3.md).

## Deploy

Prerequisites: `datumctl` on PATH, `gh` logged in with `write:packages`, colima running the containerd runtime, and an AWS profile that can administer IAM and S3.

```sh
# Once per AWS account and region: bucket and shared policy.
./postgres/aws/bootstrap.hs bucket
# Once per deployment: IAM user plus the Datum secret NAME-aws.
./postgres/aws/bootstrap.hs deployment birdhaus-db <project>
# Build, push, deploy. Creates the secret NAME-db (one random password per database) on first run.
./postgres/deploy.hs --project <project> --pull-secret <ghcr-pull-secret>
```

`deploy.hs` options: `--name`, `--workload` (default: the name), `--databases` (default `"birdhaus umami"`), `--network` (default `birdhaus`; create it with `datumctl apply -f network/`), `--location`, `--instance-type`, `--tag`.

The sandbox deployment runs as workload `birdhaus-pg` with deployment name `birdhaus-db` (see the design doc for why). Pass `--workload birdhaus-pg` when redeploying it. Do not change the network of an existing workload in place; recreate it under a new workload name.

## Connect

The instance's IPv6 address is `PGHOST` and is stable (`reclaimPolicy: Retain`):

```sh
datumctl get instances | grep birdhaus-pg
```

Each database has a role of the same name, with its password in the `NAME-db` secret under the database's name. Roles cannot connect to each other's databases, and the `postgres` superuser is local-only. Consumers must retry connections, since a restore takes seconds to minutes.

```sh
datumctl compute exec birdhaus-pg-default-us-east-1-0 -- sh -c "gosu postgres psql -d birdhaus"
```

(Wrap the command in `sh -c`; plain flags after `--` fail.)

## Operate

- **Logs:** `datumctl compute logs birdhaus-pg`. Look for `[entrypoint]` lines, and check `select failed_count from pg_stat_archiver` is 0.
- **Backups:** one base backup shortly after every boot and then daily, keeping 7. List them with `wal-g backup-list` inside the instance.
- **Restore drill:** `datumctl compute restart birdhaus-pg`. The new instance has an empty disk and restores in seconds for a small database.
- **Add a database or rotate a password:** change the `NAME-db` secret and restart. Every boot reconciles roles and passwords.
- **Rotate the AWS key:** `./postgres/aws/bootstrap.hs rotate birdhaus-db <project>`, then restart.
- **Teardown:** `datumctl compute destroy birdhaus-pg`, then `bootstrap.hs destroy birdhaus-db` (removes the IAM user, keeps the data). Delete the `birdhaus-db/` prefix in the bucket to drop the data.

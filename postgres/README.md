# Postgres on Datum Compute, durable in S3

One Postgres per deployment (default `birdhaus-db`) runs on a general-purpose instance's local disk and continuously archives to S3 with WAL-G. A replacement instance restores itself from S3 on boot. Design and test results: [`docs/design/postgres-s3.md`](../docs/design/postgres-s3.md).

## Deploy

Prerequisites: `datumctl` on PATH, `gh` logged in with `write:packages`, colima running the containerd runtime, and an AWS profile that can administer IAM and S3.

```sh
# Once per AWS account: bucket, shared policy, deployment user, the Datum
# Secrets and birdhaus-watch. Writes dns/ses.yaml.
./ops/aws-account.hs setup --project <project> --alert-to <email>
# Build, push, deploy. Creates the secret NAME-db (one random password per database) on first run.
./postgres/deploy.hs --project <project> --pull-secret <ghcr-pull-secret>
```

For an existing account, the individual steps are still available: `./postgres/aws/bootstrap.hs bucket`, then `deployment birdhaus-db <project>`. `ops/aws-account.hs copy-data` and `switch` move an existing deployment to another account; see the root README.

`deploy.hs` options: `--name`, `--workload` (default: the name), `--databases` (default `"birdhaus umami auth"`), `--network` (default `birdhaus`; create it with `datumctl apply -f network/`), `--location`, `--instance-type`, `--tag`.

The `auth` database belongs to Rauthy ([`auth/README.md`](../auth/README.md)). Adding a database means adding its password to the `NAME-db` Secret, passing it in `--databases`, and redeploying: every boot reconciles databases, roles and passwords.

The deployment runs as workload `birdhaus-pg` with deployment name `birdhaus-db` (see the design doc for why). Pass `--workload birdhaus-pg` when redeploying it. Do not change the network of an existing workload in place; recreate it under a new workload name.

## Connect

Connect to `db.birdhaus.store`, an AAAA record (`dns/aaaa.yaml`) for the instance's private address. Update that record if the address changes. The address is stable across restarts (`reclaimPolicy: Retain`) but not across recreating the workload:

```sh
datumctl get instances | grep birdhaus-pg
```

Each database has a role of the same name, with its password in the `NAME-db` secret under the database's name. Roles cannot connect to each other's databases, and the `postgres` superuser is local-only. Consumers must retry connections, since a restore takes seconds to minutes.

```sh
datumctl compute exec birdhaus-pg-default-us-east-1-0 -- sh -c "gosu postgres psql -d birdhaus"
```

(Wrap the command in `sh -c`; plain flags after `--` fail.)

## Operate

- **Alerts:** with the Secret `birdhaus-db-watch` present, the entrypoint reports health to birdhaus-watch every 5 minutes: archive failures and backlog, base backup age, recovery, and disk. See `ops/watch/README.md`.

- **Logs:** `datumctl compute logs birdhaus-pg`. Look for `[entrypoint]` lines, and check `select failed_count from pg_stat_archiver` is 0.
- **Backups:** one base backup shortly after every boot and then daily, keeping 7. List them with `wal-g backup-list` inside the instance.
- **Restore drill:** `datumctl compute restart birdhaus-pg`. The new instance has an empty disk and restores in seconds for a small database.
- **Add a database or rotate a password:** change the `NAME-db` secret and restart. Every boot reconciles roles and passwords.
- **Rotate the AWS key:** `./postgres/aws/bootstrap.hs rotate birdhaus-db <project>`, then restart.
- **Teardown:** `datumctl compute destroy birdhaus-pg`, then `bootstrap.hs destroy birdhaus-db` (removes the IAM user, keeps the data). To drop the data too, run `bootstrap.hs destroy-bucket`, which deletes every object version, the bucket, and the shared policy once nothing uses it. `ops/aws-account.hs destroy` does the whole account, including the watcher, but refuses while the Datum Secrets still point at it.

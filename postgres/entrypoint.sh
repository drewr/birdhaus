#!/bin/bash
# Boot, run and shut down a Postgres whose durability lives in S3 (see
# docs/design/postgres-s3.md). Runs as root and drops to postgres for every
# Postgres and WAL-G process. This is the one shell script in the repo because
# it runs inside the container image.
#
# Environment:
#   WALG_S3_PREFIX, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION  required
#   DATABASES      space-separated database names; each gets a role of the same
#                  name whose password is the file $SECRETS_DIR/<name>
#   SECRETS_DIR    default /secrets/db
#   AWS_ENDPOINT   default the S3 dual-stack endpoint for AWS_REGION
#   BACKUP_INTERVAL_HOURS  default 24
#   BACKUP_RETAIN          full backups to keep, default 7
set -euo pipefail

: "${WALG_S3_PREFIX:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${AWS_REGION:?}"
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
SECRETS_DIR="${SECRETS_DIR:-/secrets/db}"
DATABASES="${DATABASES:-}"
BACKUP_INTERVAL_HOURS="${BACKUP_INTERVAL_HOURS:-24}"
BACKUP_RETAIN="${BACKUP_RETAIN:-7}"
STATE_DIR=/var/lib/birdhaus
# Native IPv6 to S3; path-style because the dual-stack endpoint has no
# per-bucket hostnames for every bucket name.
export AWS_ENDPOINT="${AWS_ENDPOINT:-https://s3.dualstack.${AWS_REGION}.amazonaws.com}"
export AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-true}"
export PGHOST=/var/run/postgresql

log() { echo "[entrypoint] $*" >&2; }
as_pg() { gosu postgres "$@"; }
psql_pg() { as_pg psql -X -qAt -v ON_ERROR_STOP=1 -d postgres "$@"; }

for db in $DATABASES; do
  [[ "$db" =~ ^[a-z][a-z0-9_]{0,30}$ ]] || { log "invalid database name: $db"; exit 1; }
  [ -s "$SECRETS_DIR/$db" ] || { log "no password for $db in $SECRETS_DIR"; exit 1; }
done

mkdir -p "$PGDATA" "$STATE_DIR" /var/run/postgresql
chown postgres:postgres "$PGDATA" "$STATE_DIR" /var/run/postgresql
chmod 700 "$PGDATA"

# A transient S3 error must never look like "no backups": initdb over a
# cluster that exists in S3 would fork its history.
list_backups() {
  local out i
  for i in 1 2 3 4 5; do
    if out=$(as_pg wal-g backup-list --json 2>/dev/null); then echo "$out"; return 0; fi
    log "wal-g backup-list failed (attempt $i)"; sleep $((i * 3))
  done
  return 1
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  backups=$(list_backups) || { log "cannot list backups in $WALG_S3_PREFIX; refusing to initialise"; exit 1; }
  if grep -q backup_name <<<"$backups"; then
    log "restoring the latest base backup from $WALG_S3_PREFIX"
    started=$(date +%s)
    as_pg wal-g backup-fetch "$PGDATA" LATEST
    as_pg touch "$PGDATA/recovery.signal"
    log "base backup fetched in $(( $(date +%s) - started ))s; replaying WAL on start"
  else
    log "no backups in $WALG_S3_PREFIX; initialising a new cluster"
    as_pg initdb -D "$PGDATA" --encoding=UTF8 --auth-local=peer --auth-host=scram-sha-256
  fi
  # Restored clusters carry the old backup's state; a fresh base backup on the
  # new timeline shortens the next restore.
  rm -f "$STATE_DIR/last-backup"
fi

grep -q "include_if_exists = 'birdhaus.conf'" "$PGDATA/postgresql.conf" ||
  echo "include_if_exists = 'birdhaus.conf'" >>"$PGDATA/postgresql.conf"
install -o postgres -g postgres -m 0600 /etc/birdhaus/birdhaus.conf "$PGDATA/birdhaus.conf"
install -o postgres -g postgres -m 0600 /etc/birdhaus/pg_hba.conf "$PGDATA/pg_hba.conf"

wait_ready() {
  until as_pg pg_isready -q -h "$PGHOST"; do sleep 1; done
  until [ "$(psql_pg -c 'select pg_is_in_recovery()' 2>/dev/null || echo t)" = f ]; do sleep 2; done
}

# Create or update each database, its role and password. Idempotent, so it
# also applies new databases and rotated passwords on every boot.
reconcile() {
  local db pw
  for db in $DATABASES; do
    pw=$(cat "$SECRETS_DIR/$db")
    psql_pg -v pw="$pw" <<SQL
select format('create role %I login', '$db')
  where not exists (select from pg_roles where rolname = '$db') \gexec
alter role "$db" password :'pw';
select format('create database %I owner %I', '$db', '$db')
  where not exists (select from pg_database where datname = '$db') \gexec
revoke connect on database "$db" from public;
grant connect on database "$db" to "$db";
SQL
  done
  log "databases reconciled: ${DATABASES:-none}"
}

backup_loop() {
  wait_ready
  local last now
  while true; do
    now=$(date +%s)
    last=$(cat "$STATE_DIR/last-backup" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge $((BACKUP_INTERVAL_HOURS * 3600)) ]; then
      log "taking a base backup"
      if as_pg wal-g backup-push "$PGDATA"; then
        echo "$now" >"$STATE_DIR/last-backup"
        as_pg wal-g delete retain FULL "$BACKUP_RETAIN" --confirm || log "wal-g delete failed"
      else
        log "base backup failed; will retry"
      fi
    fi
    sleep 300
  done
}

PG_PID=""
LOOP_PID=""
stop() {
  log "stopping"
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
  if [ -n "$PG_PID" ]; then
    # Close the current WAL segment so it is archived before exit; the
    # archiver drains everything pending during a fast shutdown.
    psql_pg -c 'select pg_switch_wal()' >/dev/null 2>&1 || true
    kill -INT "$PG_PID" 2>/dev/null || true
    wait "$PG_PID" 2>/dev/null || true
  fi
  exit 0
}
trap stop TERM INT

as_pg postgres -D "$PGDATA" &
PG_PID=$!
( wait_ready && reconcile ) &
backup_loop &
LOOP_PID=$!

# Return when Postgres exits for any reason other than our own stop().
wait "$PG_PID" && rc=0 || rc=$?
log "postgres exited with status $rc"
kill "$LOOP_PID" 2>/dev/null || true
exit "$rc"

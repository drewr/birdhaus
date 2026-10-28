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
#   WATCH_URL, WATCH_CHECK, WATCH_TOKEN  optional: report health to
#                  birdhaus-watch every 5 minutes (ops/watch/README.md)
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

# Every 5 minutes: ping birdhaus-watch when healthy, or report every problem
# found. Silence is itself an alert, so a dead instance is caught too. Runs
# without set -e: a failing check must be reported, not end the loop.
watch_loop() {
  set +e
  local started problems now rec failing failed_wal ready latest age used
  started=$(date +%s)
  printf 'Authorization: Bearer %s\n' "$WATCH_TOKEN" >"$STATE_DIR/watch-header"
  chmod 600 "$STATE_DIR/watch-header"
  sleep 60
  while true; do
    problems=()
    now=$(date +%s)
    if ! as_pg pg_isready -q -h "$PGHOST"; then
      problems+=("Postgres is not accepting connections.")
    else
      rec=$(psql_pg -c 'select pg_is_in_recovery()' 2>/dev/null)
      if [ "$rec" = t ]; then
        [ $((now - started)) -gt 900 ] && problems+=("Postgres is still in recovery $(( (now - started) / 60 )) minutes after boot.")
      elif [ "$rec" = f ]; then
        # The most recent archive attempt failed: WAL is not reaching S3.
        IFS='|' read -r failing failed_wal <<<"$(psql_pg -c "select coalesce(last_failed_time > coalesce(last_archived_time, 'epoch'), false), coalesce(last_failed_wal, '') from pg_stat_archiver" 2>/dev/null)"
        [ "$failing" = t ] && problems+=("WAL archiving to S3 is failing (last failed segment $failed_wal). Writes since then are not durable.")
        ready=$(find "$PGDATA/pg_wal/archive_status" -name '*.ready' 2>/dev/null | wc -l)
        [ "$ready" -gt 3 ] && problems+=("$ready WAL segments are waiting to be archived.")
        if latest=$(as_pg wal-g backup-list --json 2>/dev/null | grep -o '"time":"[^"]*"' | cut -d'"' -f4 | sort | tail -1) && [ -n "$latest" ]; then
          age=$(( (now - $(date -d "$latest" +%s)) / 3600 ))
          [ "$age" -ge 26 ] && problems+=("The newest base backup is $age hours old.")
        elif [ $((now - started)) -gt 3600 ]; then
          problems+=("No base backup could be listed in $WALG_S3_PREFIX.")
        fi
      else
        problems+=("Postgres did not answer a query.")
      fi
    fi
    used=$(df -P "$PGDATA" | awk 'NR == 2 { sub("%", "", $5); print $5 }')
    [ "${used:-0}" -gt 85 ] && problems+=("The data disk is ${used}% full.")

    if [ ${#problems[@]} -eq 0 ]; then
      curl -fsS -m 10 -X POST -H @"$STATE_DIR/watch-header" "$WATCH_URL/ping/$WATCH_CHECK" >/dev/null || log "watch ping failed"
    else
      log "health problems: ${problems[*]}"
      printf '%s\n' "${problems[@]}" | curl -fsS -m 10 -X POST -H @"$STATE_DIR/watch-header" --data-binary @- "$WATCH_URL/fail/$WATCH_CHECK" >/dev/null || log "watch report failed"
    fi
    sleep 300
  done
}

PG_PID=""
LOOP_PID=""
WATCH_PID=""
stop() {
  log "stopping"
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
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
if [ -n "${WATCH_URL:-}" ] && [ -n "${WATCH_TOKEN:-}" ]; then
  WATCH_CHECK="${WATCH_CHECK:-postgres}"
  watch_loop &
  WATCH_PID=$!
else
  log "WATCH_URL is not set; health reporting is off"
fi

# Return when Postgres exits for any reason other than our own stop().
wait "$PG_PID" && rc=0 || rc=$?
log "postgres exited with status $rc"
kill "$LOOP_PID" 2>/dev/null || true
[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
exit "$rc"

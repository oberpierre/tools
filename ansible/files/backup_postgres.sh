#!/bin/sh
# Full logical backup of the central Postgres: cluster roles/grants plus one
# custom-format dump per user database, bundled, encrypted with age
# (github.com/FiloSottile/age) and pushed to an rclone remote. Every run is a
# complete, self-contained snapshot (no restore chain), so old backups can be
# pruned to the newest KEEP_LAST objects without breaking any restore. Custom
# format (-Fc) is kept per database so a single database can be pg_restored
# selectively into a scratch DB without touching the others.
set -eu

: "${PG_HOST:?}" "${PG_PORT:?}" "${PG_SUPERUSER:?}" "${PGPASSWORD:?}"
: "${AGE_RECIPIENT:?}" "${RCLONE_REMOTE:?}" "${KEEP_LAST:?}"
export PGPASSWORD

# The postgres:*-alpine image ships the matching pg_dump; age/rclone/curl are
# added here so no bespoke backup image has to be built and pushed.
apk add --no-cache age rclone curl >/dev/null

ts=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp -d)
trap 'rm -rf "$work" "/tmp/postgres-$ts.tar.gz.age"' EXIT

pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" --globals-only >"$work/globals.sql"

# 'postgres' and template DBs carry no application data worth a per-DB dump. Capture the list in its
# own assignment rather than piping `psql | while`: a pipeline hides a psql failure behind the loop's
# zero exit, so set -e would not catch it and we would ship a globals-only "backup". As a command
# substitution, a psql failure aborts the run here.
# 'backup_verify%' are the transient scratch DBs the restore-verification CronJobs create; skip them
# so an orphan (from a job killed before its cleanup) never gets rolled into a real backup.
dbs=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -Atqc \
  "SELECT datname FROM pg_database
     WHERE datistemplate = false AND datname <> 'postgres' AND datname NOT LIKE 'backup_verify%'")
printf '%s\n' "$dbs" | while IFS= read -r db; do
  [ -n "$db" ] || continue
  pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -Fc "$db" >"$work/$db.pgc"
done

archive="postgres-$ts.tar.gz.age"
# pipefail (scoped to this subshell) so a tar error is not masked by age exiting 0 on the partial
# stream, which would upload a truncated archive that only fails at restore time. Kept local because
# a global pipefail would also trip the retention `printf | head` below on its normal SIGPIPE.
( set -o pipefail; tar -C "$work" -czf - . | age -r "$AGE_RECIPIENT" -o "/tmp/$archive" )

dest="$RCLONE_REMOTE/postgres"
rclone copy "/tmp/$archive" "$dest/"

# Retention: keep the newest KEEP_LAST objects. Timestamped names sort
# lexicographically by age, so the surplus is the head of the sorted list.
existing=$(rclone lsf "$dest/" | sort)
total=$(printf '%s\n' "$existing" | grep -c . || true)
surplus=$((total - KEEP_LAST))
if [ "$surplus" -gt 0 ]; then
  printf '%s\n' "$existing" | head -n "$surplus" | while IFS= read -r old; do
    [ -n "$old" ] && rclone deletefile "$dest/$old"
  done
fi

echo "backup complete: $dest/$archive"

# Heartbeat for the dead-man's-switch: record this successful run so Prometheus can alert if no
# backup lands within the expected window. Only the success path reaches here (set -e), so a failed
# run simply lets the timestamp go stale. No-op unless a Pushgateway URL is configured.
if [ -n "${PUSHGATEWAY_URL:-}" ]; then
  printf '# TYPE backup_last_success_timestamp gauge\nbackup_last_success_timestamp %s\n' "$(date +%s)" \
    | curl -sS --max-time 30 --data-binary @- "$PUSHGATEWAY_URL/metrics/job/backup/store/postgres" || true
fi

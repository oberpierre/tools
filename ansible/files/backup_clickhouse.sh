#!/bin/sh
# Network-only logical backup of a ClickHouse database over the HTTP interface: per object,
# SHOW CREATE (schema); per data-bearing table, SELECT * FORMAT Native (data). Dictionaries
# and views hold no rows of their own (a dictionary reloads from its source table), so they
# are schema-only. The whole set is bundled, encrypted with age (github.com/FiloSottile/age)
# and pushed to an rclone remote, keeping the newest KEEP_LAST. Nothing touches ClickHouse's
# data directory, so the running server is never disturbed.
set -eu

: "${CH_URL:?}" "${CH_USER:?}" "${CH_PASSWORD:?}" "${CH_DB:?}"
: "${AGE_RECIPIENT:?}" "${RCLONE_REMOTE:?}" "${KEEP_LAST:?}"

apk add --no-cache curl age rclone >/dev/null

# Credentials go in headers, never in the URL/argv, so they don't leak into logs.
chq() {
  curl -sS --fail-with-body "$CH_URL/" \
    -H "X-ClickHouse-User: $CH_USER" -H "X-ClickHouse-Key: $CH_PASSWORD" \
    --data-binary "$1"
}

ts=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp -d)
trap 'rm -rf "$work" "/tmp/clickhouse-$ts.tar.gz.age"' EXIT
mkdir "$work/schema" "$work/data"

# name<TAB>engine for every object; the engine decides whether it stores rows.
chq "SELECT name, engine FROM system.tables WHERE database = '$CH_DB' AND name NOT LIKE '.inner%' ORDER BY name FORMAT TabSeparated" \
  >"$work/tables.tsv"

while IFS="$(printf '\t')" read -r name engine; do
  [ -n "$name" ] || continue
  chq "SHOW CREATE TABLE \`$CH_DB\`.\`$name\` FORMAT TabSeparatedRaw" >"$work/schema/$name.sql"
  case "$engine" in
    Dictionary | *View) ;; # no stored rows to dump
    *) chq "SELECT * FROM \`$CH_DB\`.\`$name\` FORMAT Native" >"$work/data/$name.native" ;;
  esac
done <"$work/tables.tsv"

archive="clickhouse-$ts.tar.gz.age"
# Scoped pipefail so a tar failure is not masked by age exiting 0 on the partial stream. Not global:
# the retention `printf | head` below SIGPIPEs under pipefail.
( set -o pipefail; tar -C "$work" -czf - . | age -r "$AGE_RECIPIENT" -o "/tmp/$archive" )

dest="$RCLONE_REMOTE/clickhouse"
rclone copy "/tmp/$archive" "$dest/"

# Retention: keep the newest KEEP_LAST objects (timestamped names sort by age).
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
    | curl -sS --max-time 30 --data-binary @- "$PUSHGATEWAY_URL/metrics/job/backup/store/clickhouse" || true
fi

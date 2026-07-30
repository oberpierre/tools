#!/bin/sh
# Round-trip verification of the cluster backups: verify a backup taken right now is actually
# restorable, end to end, using the SAME backup and restore scripts the real system uses.
#
# It runs IN-CLUSTER as a CronJob using a temporary age key and the local file system as rclone target.
# The throwaway age keypair is used for the backup_<store>.sh dumps data, so the age key for the live
# backups is never exposed to the cluster while verifying the dump/encrypt/decrypt/restore machinery.
#
# The outcome is pushed to Pushgateway so Prometheus can alert on failure or staleness (a dead-man's
# switch). The group is POSTed, not PUT: only the metric families we send are replaced, so pushing
# success=0 on a failure leaves the last good backup_verify_last_success_timestamp in place for the
# staleness rule to keep measuring against.
#
# Required env: STORE (postgres|clickhouse), PUSHGATEWAY_URL, plus the per-store connection vars read
# in each case below. SCRIPTS_DIR holds the deployed backup scripts; VERIFY_DIR the restore scripts.
set -eu

: "${STORE:?}" "${PUSHGATEWAY_URL:?}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
VERIFY_DIR="${VERIFY_DIR:-/verify}"

work="$(mktemp -d)"
key="$work/age.key"
remote="$work/remote"          # a plain directory is a valid rclone destination (local backend)
export RCLONE_CONFIG="$work/rclone.conf"; : >"$RCLONE_CONFIG"   # empty config => no named remotes, local paths only
export PATH="$work:$PATH"       # the kubectl we fetch below
mkdir -p "$remote"

ok=0
rows=0
pw=""
created=0
scratch="backup_verify_$(date -u +%Y%m%d%H%M%S)"

# ClickHouse admin queries go over HTTP with the password in a header (never argv), matching the
# backup script; used for the assertion and the scratch-DB drop. Only called on clickhouse runs.
chq() {
  curl -sS --fail-with-body "$CH_URL/" \
    -H "X-ClickHouse-User: $CH_USER" -H "X-ClickHouse-Key: $CH_PASSWORD" \
    --data-binary "$1"
}

# Drop the scratch DB (best effort) and push the outcome, whatever exit we leave on.
finish() {
  status=$?
  if [ "$created" = 1 ]; then
    case "$STORE" in
      postgres) kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
        env PGPASSWORD="${pw:-}" dropdb --if-exists -U "$PG_SUPERUSER" "$scratch" >/dev/null 2>&1 || true ;;
      clickhouse) chq "DROP DATABASE IF EXISTS \`$scratch\`" >/dev/null 2>&1 || true ;;
    esac
  fi
  now="$(date +%s)"
  if [ "$ok" = 1 ]; then
    printf '# TYPE backup_verify_success gauge\nbackup_verify_success 1\n# TYPE backup_verify_last_success_timestamp gauge\nbackup_verify_last_success_timestamp %s\n# TYPE backup_verify_rows gauge\nbackup_verify_rows %s\n' \
      "$now" "$rows"
  else
    printf '# TYPE backup_verify_success gauge\nbackup_verify_success 0\n'
  fi | curl -sS --max-time 30 --data-binary @- \
    "$PUSHGATEWAY_URL/metrics/job/backup-verify/store/$STORE" || true
  rm -rf "$work"
  return "$status"
}
trap finish EXIT

# bash for the restore scripts; age/rclone/curl for the pipeline; kubectl to drive the DB pods (the
# restore scripts exec/cp through it). Fetched at runtime so no bespoke image has to be built/pushed,
# same choice the backup CronJobs make. KUBECTL_VERSION pins it if the auto-detected stable drifts.
apk add --no-cache bash age rclone curl >/dev/null
kver="${KUBECTL_VERSION:-$(curl -sSL https://dl.k8s.io/release/stable.txt)}"
curl -sSLo "$work/kubectl" "https://dl.k8s.io/release/$kver/bin/linux/amd64/kubectl"
chmod +x "$work/kubectl"

age-keygen -o "$key" 2>/dev/null
recipient="$(age-keygen -y "$key")"

case "$STORE" in
  postgres)
    : "${PG_NAMESPACE:?}" "${PG_POD:?}" "${VERIFY_DB:?}"
    PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
    PG_CONTAINER="${PG_CONTAINER:-postgresql}"

    # PUSHGATEWAY_URL= so the inner backup does NOT push the real backup_last_success_timestamp
    # heartbeat. This is a throwaway local backup; letting it refresh the heartbeat would keep
    # BackupStale green even while the actual nightly off-site backup is failing.
    AGE_RECIPIENT="$recipient" RCLONE_REMOTE="$remote" KEEP_LAST=1 PUSHGATEWAY_URL= \
      sh "$SCRIPTS_DIR/backup_postgres.sh"

    pw="$(kubectl get secret postgresql-credentials -n "$PG_NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)"
    kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" createdb -U "$PG_SUPERUSER" "$scratch"
    created=1

    AGE_IDENTITY="$key" RCLONE_REMOTE="$remote" \
      PG_NAMESPACE="$PG_NAMESPACE" PG_POD="$PG_POD" \
      PG_SUPERUSER="$PG_SUPERUSER" PG_CONTAINER="$PG_CONTAINER" \
      bash "$VERIFY_DIR/restore_postgres.sh" --db "$VERIFY_DB" --target "$scratch"

    # ANALYZE so n_live_tup reflects the freshly loaded rows, then sum them as the authoritative
    # "the restore produced queryable data" signal (independent of the restore script's own output).
    kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" psql -U "$PG_SUPERUSER" -d "$scratch" -c "ANALYZE" >/dev/null
    rows="$(kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" psql -U "$PG_SUPERUSER" -d "$scratch" -Atqc \
      "SELECT COALESCE(sum(n_live_tup), 0) FROM pg_stat_user_tables")"
    ;;

  clickhouse)
    : "${CH_URL:?}" "${CH_USER:?}" "${CH_PASSWORD:?}" "${CH_DB:?}" "${CH_NAMESPACE:?}" "${CH_POD:?}"

    # PUSHGATEWAY_URL= for the same reason as the postgres call above: don't let the throwaway
    # local backup refresh the real backup heartbeat.
    AGE_RECIPIENT="$recipient" RCLONE_REMOTE="$remote" KEEP_LAST=1 PUSHGATEWAY_URL= \
      sh "$SCRIPTS_DIR/backup_clickhouse.sh"

    # restore_clickhouse.sh --target CREATEs the database itself, so mark it for cleanup up front.
    created=1
    AGE_IDENTITY="$key" RCLONE_REMOTE="$remote" \
      CH_NAMESPACE="$CH_NAMESPACE" CH_POD="$CH_POD" CH_DB="$CH_DB" CH_USER="$CH_USER" \
      bash "$VERIFY_DIR/restore_clickhouse.sh" --target "$scratch"

    # total_rows in system.tables is exact for MergeTree; dictionaries/views report NULL and drop out.
    rows="$(chq "SELECT sum(total_rows) FROM system.tables WHERE database = '$scratch'")"
    ;;

  *) echo "unknown STORE: $STORE" >&2; exit 2 ;;
esac

case "${rows:-0}" in ''|*[!0-9]*) rows=0 ;; esac
[ "$rows" -gt 0 ] || { echo "assertion failed: restored $STORE scratch DB '$scratch' has 0 rows" >&2; exit 1; }
echo "verify ok: $STORE round-tripped, scratch '$scratch' holds $rows rows"
ok=1

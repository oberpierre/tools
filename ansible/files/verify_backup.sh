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
source_rows=0
pw=""
created=0
# Fixed name (concurrencyPolicy Forbid rules out overlap) so a killed run leaves at most one orphan,
# reclaimed by the drop-before-create below, rather than a new scratch DB every day.
scratch="backup_verify_$STORE"

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
# Match the node architecture; --fail so a transient dl.k8s.io error is not saved as a bogus
# "kubectl" binary, --retry to ride out a blip.
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
kver="${KUBECTL_VERSION:-$(curl -fsSL --retry 3 https://dl.k8s.io/release/stable.txt)}"
curl -fsSL --retry 3 -o "$work/kubectl" "https://dl.k8s.io/release/$kver/bin/linux/$arch/kubectl"
chmod +x "$work/kubectl"

age-keygen -o "$key" 2>/dev/null
recipient="$(age-keygen -y "$key")"

case "$STORE" in
  postgres)
    : "${PG_NAMESPACE:?}" "${PG_POD:?}" "${VERIFY_DB:?}"
    PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
    PG_CONTAINER="${PG_CONTAINER:-postgresql}"

    pw="$(kubectl get secret postgresql-credentials -n "$PG_NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)"

    # Baseline the live source BEFORE the backup, so the assertion compares against the data the dump
    # captured. n_live_tup is kept current on a live DB (autovacuum), so no ANALYZE is needed here.
    source_rows="$(kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" psql -U "$PG_SUPERUSER" -d "$VERIFY_DB" -Atqc \
      "SELECT COALESCE(sum(n_live_tup), 0) FROM pg_stat_user_tables")"

    # PUSHGATEWAY_URL= so the throwaway local backup does NOT push the real backup_last_success
    # heartbeat, which would keep BackupStale green while the actual nightly off-site backup fails.
    AGE_RECIPIENT="$recipient" RCLONE_REMOTE="$remote" KEEP_LAST=1 PUSHGATEWAY_URL= \
      sh "$SCRIPTS_DIR/backup_postgres.sh"

    # Reclaim an orphan scratch DB left by a previous SIGKILLed run, then recreate it fresh.
    created=1
    kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" dropdb --if-exists -U "$PG_SUPERUSER" "$scratch"
    kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" createdb -U "$PG_SUPERUSER" "$scratch"

    AGE_IDENTITY="$key" RCLONE_REMOTE="$remote" \
      PG_NAMESPACE="$PG_NAMESPACE" PG_POD="$PG_POD" \
      PG_SUPERUSER="$PG_SUPERUSER" PG_CONTAINER="$PG_CONTAINER" \
      bash "$VERIFY_DIR/restore_postgres.sh" --db "$VERIFY_DB" --target "$scratch"

    # ANALYZE so n_live_tup reflects the freshly loaded rows, then sum them for the assertion below.
    kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" psql -U "$PG_SUPERUSER" -d "$scratch" -c "ANALYZE" >/dev/null
    rows="$(kubectl exec -c "$PG_CONTAINER" -n "$PG_NAMESPACE" "$PG_POD" -- \
      env PGPASSWORD="$pw" psql -U "$PG_SUPERUSER" -d "$scratch" -Atqc \
      "SELECT COALESCE(sum(n_live_tup), 0) FROM pg_stat_user_tables")"
    ;;

  clickhouse)
    : "${CH_URL:?}" "${CH_USER:?}" "${CH_PASSWORD:?}" "${CH_DB:?}" "${CH_NAMESPACE:?}" "${CH_POD:?}"

    # Count rows only over the tables the backup actually dumps (the data-bearing ones). A loaded
    # dictionary reports its element count in total_rows, and .inner MV tables hold rows too, but the
    # dump skips both as schema-only; including them here would make the live source out-count the
    # restored scratch and fail the assertion on a good backup. Baseline before the backup runs.
    ch_row_filter="name NOT LIKE '.inner%' AND engine NOT LIKE '%View' AND engine != 'Dictionary'"
    source_rows="$(chq "SELECT sum(total_rows) FROM system.tables WHERE database = '$CH_DB' AND $ch_row_filter")"

    # PUSHGATEWAY_URL= for the same reason as the postgres call above: don't let the throwaway
    # local backup refresh the real backup heartbeat.
    AGE_RECIPIENT="$recipient" RCLONE_REMOTE="$remote" KEEP_LAST=1 PUSHGATEWAY_URL= \
      sh "$SCRIPTS_DIR/backup_clickhouse.sh"

    # Reclaim an orphan from a killed run before restoring: restore_clickhouse.sh --target only does
    # CREATE DATABASE IF NOT EXISTS, so leftover tables would fail its create loop as "already exists".
    created=1
    chq "DROP DATABASE IF EXISTS \`$scratch\`" >/dev/null
    AGE_IDENTITY="$key" RCLONE_REMOTE="$remote" \
      CH_NAMESPACE="$CH_NAMESPACE" CH_POD="$CH_POD" CH_DB="$CH_DB" CH_USER="$CH_USER" \
      bash "$VERIFY_DIR/restore_clickhouse.sh" --target "$scratch"

    # Same filter as the source baseline so the two totals cover the identical set of tables.
    rows="$(chq "SELECT sum(total_rows) FROM system.tables WHERE database = '$scratch' AND $ch_row_filter")"
    ;;

  *) echo "unknown STORE: $STORE" >&2; exit 2 ;;
esac

case "${rows:-0}" in ''|*[!0-9]*) rows=0 ;; esac
case "${source_rows:-0}" in ''|*[!0-9]*) source_rows=0 ;; esac
# A faithful restore reproduces the source, so require the scratch DB to hold at least ~90% of the
# live source's rows. The slack absorbs rows written between the baseline count and the backup
# snapshot; an empty source (0 rows) restores to 0 and passes, so a brand-new deployment with no
# traffic yet is not flagged as a failure.
if [ "$((rows * 10))" -lt "$((source_rows * 9))" ]; then
  echo "assertion failed: $STORE restored $rows rows but the live source holds $source_rows" >&2
  exit 1
fi
echo "verify ok: $STORE round-tripped $rows rows (live source $source_rows)"
ok=1

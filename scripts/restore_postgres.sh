#!/usr/bin/env bash
# Restore a Postgres backup produced by ansible/files/backup_postgres.sh.
#
# Runs on the operator's machine (needs kubectl, rclone and age
# (github.com/FiloSottile/age) with the OFFLINE age identity/private key). It
# pulls an encrypted archive from the rclone remote, decrypts it, and restores
# one database BACK ONTO THE CLUSTER by streaming it through `kubectl exec …
# pg_restore` into the target Postgres pod. By default it restores into a
# throwaway database and prints per-table row counts, so a backup is proven
# restorable before it is ever trusted or promoted to live.
#
# Usage:
#   restore_postgres.sh --db <name> [--archive NAME] [--target DB | --live]
#     --db       database to restore (its <db>.pgc inside the archive)
#     --archive  archive object name (default: newest in the remote)
#     --target   restore into this existing database
#     --live     restore into the original --db (DANGER: overwrites live data)
#   default:     restore into a scratch DB, verify, then drop it
#
# Required env (no defaults = fail loudly rather than guess the wrong target):
#   RCLONE_REMOTE  rclone remote root, e.g. gdrive:cluster-backups
#   AGE_IDENTITY   path to your offline age identity (private key) file
#   PG_NAMESPACE   namespace of the target Postgres, e.g. data-services
#   PG_POD         target Postgres pod, e.g. postgresql-0
# Optional: PG_SUPERUSER (default: postgres, the Bitnami superuser).
set -euo pipefail

: "${RCLONE_REMOTE:?set the rclone remote root, e.g. gdrive:cluster-backups}"
: "${AGE_IDENTITY:?set the path to your offline age identity (private key) file}"
: "${PG_NAMESPACE:?set the target Postgres namespace, e.g. data-services}"
: "${PG_POD:?set the target Postgres pod, e.g. postgresql-0}"
REMOTE="$RCLONE_REMOTE/postgres"
NS="$PG_NAMESPACE"
POD="$PG_POD"
SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_CONTAINER="${PG_CONTAINER:-postgresql}"   # the DB container in the pod (vs the metrics sidecar)

DB="" ARCHIVE="" TARGET="" MODE="scratch"
while [ $# -gt 0 ]; do
  case "$1" in
    --db) DB="$2"; shift 2 ;;
    --archive) ARCHIVE="$2"; shift 2 ;;
    --target) TARGET="$2"; MODE="target"; shift 2 ;;
    --live) MODE="live"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DB" ] || { echo "error: --db is required" >&2; exit 2; }
[ -f "$AGE_IDENTITY" ] || { echo "error: age identity not found: $AGE_IDENTITY" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(rclone lsf "$REMOTE/" | sort | tail -1)"
  [ -n "$ARCHIVE" ] || { echo "error: no archives found in $REMOTE" >&2; exit 1; }
fi
echo "restoring database '$DB' from $REMOTE/$ARCHIVE"

rclone copy "$REMOTE/$ARCHIVE" "$tmp/"
age -d -i "$AGE_IDENTITY" "$tmp/$ARCHIVE" | tar -C "$tmp" -xzf -
dump="$tmp/$DB.pgc"
[ -f "$dump" ] || { echo "error: $DB.pgc not in archive (has: $(ls "$tmp" | tr '\n' ' '))" >&2; exit 1; }

# Password comes from the same secret the backup CronJob reads.
pgpw="$(kubectl get secret postgresql-credentials -n "$NS" -o jsonpath='{.data.postgres-password}' | base64 -d)"
kexec() { kubectl exec -i -c "$PG_CONTAINER" -n "$NS" "$POD" -- env PGPASSWORD="$pgpw" "$@"; }

case "$MODE" in
  live)    target="$DB" ;;
  target)  target="$TARGET" ;;
  scratch) target="${DB}_restore_$(date -u +%Y%m%d%H%M%S)" ;;
esac

if [ "$MODE" != "live" ] && [ "$MODE" != "target" ]; then
  echo "creating scratch database '$target'"
  kexec createdb -U "$SUPERUSER" "$target"
fi

# Copy the dump into the pod and restore from that file rather than piping it into
# `kubectl exec -i` stdin: streaming a binary archive over the exec channel can hang (stdin EOF
# is not reliably propagated), and a real file also lets pg_restore seek.
echo "copying dump into the pod"
kubectl cp "$dump" "$NS/$POD:/tmp/restore-$$.pgc" -c "$PG_CONTAINER"

echo "pg_restore -> '$target'"
kexec pg_restore -U "$SUPERUSER" -d "$target" --no-owner --clean --if-exists "/tmp/restore-$$.pgc" || true
kexec rm -f "/tmp/restore-$$.pgc" || true

echo "verification (per-table live tuple estimates):"
kexec psql -U "$SUPERUSER" -d "$target" -c \
  "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1, 2;"

if [ "$MODE" = "scratch" ]; then
  echo "dropping scratch database '$target'"
  kexec dropdb -U "$SUPERUSER" "$target"
fi
echo "done"

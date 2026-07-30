#!/usr/bin/env bash
# Restore a Postgres backup produced by ansible/files/backup_postgres.sh.
#
# Runs on the operator's machine (needs kubectl, rclone and age
# (github.com/FiloSottile/age) with the OFFLINE age identity/private key). It
# pulls an encrypted archive from the rclone remote, decrypts it, and restores
# databases BACK ONTO THE CLUSTER via `kubectl cp` + pg_restore into the target
# Postgres pod. With --db it restores a single database (into a throwaway DB by
# default, printing per-table row counts so a backup is proven restorable before
# it is trusted). With --all it restores the whole cluster (roles/grants + every
# database) into their original names, for disaster recovery into a fresh pod.
#
# Usage:
#   restore_postgres.sh --db <name> [--archive NAME] [--target DB | --live]
#   restore_postgres.sh --all [--archive NAME]
#     --db       restore one database (its <db>.pgc inside the archive)
#     --all      restore roles/grants + every database into their original names,
#                onto the pod PG_POD points at (a fresh instance for DR, or a side
#                instance to verify the whole archive at once)
#     --archive  archive object name (default: newest in the remote)
#     --target   restore --db into this existing database
#     --live     restore --db into its original name (DANGER: overwrites live data)
#   default (with --db): restore into a scratch DB, verify, then drop it
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

DB="" ARCHIVE="" TARGET="" MODE=""
# set_mode rejects a second mode flag rather than letting the last one silently win: with the
# destructive --all/--live paths, `--target scratch --all` quietly ignoring --target would overwrite
# live databases. need_arg guards value-taking flags so a trailing `--db` prints usage instead of
# dying on an unbound $2 under set -u.
set_mode() { [ -z "$MODE" ] || { echo "error: --all, --target and --live are mutually exclusive" >&2; exit 2; }; MODE="$1"; }
need_arg() { [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --db) need_arg "$@"; DB="$2"; shift 2 ;;
    --all) set_mode all; shift ;;
    --archive) need_arg "$@"; ARCHIVE="$2"; shift 2 ;;
    --target) need_arg "$@"; set_mode target; TARGET="$2"; shift 2 ;;
    --live) set_mode live; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$MODE" = "all" ]; then
  [ -z "$DB" ] || { echo "error: --db and --all are mutually exclusive" >&2; exit 2; }
else
  MODE="${MODE:-scratch}"
  [ -n "$DB" ] || { echo "error: --db or --all is required" >&2; exit 2; }
fi
[ -f "$AGE_IDENTITY" ] || { echo "error: age identity not found: $AGE_IDENTITY" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(rclone lsf "$REMOTE/" | sort | tail -1)"
  [ -n "$ARCHIVE" ] || { echo "error: no archives found in $REMOTE" >&2; exit 1; }
fi
echo "using archive $REMOTE/$ARCHIVE"
rclone copy "$REMOTE/$ARCHIVE" "$tmp/"
age -d -i "$AGE_IDENTITY" "$tmp/$ARCHIVE" | tar -C "$tmp" -xzf -

# Password comes from the same secret the backup CronJob reads.
pgpw="$(kubectl get secret postgresql-credentials -n "$NS" -o jsonpath='{.data.postgres-password}' | base64 -d)"
kexec() { kubectl exec -i -c "$PG_CONTAINER" -n "$NS" "$POD" -- env PGPASSWORD="$pgpw" "$@"; }

# Dumps are `kubectl cp`-ed into the pod and restored from that file rather than piped into
# `kubectl exec -i` stdin: streaming a binary archive over the exec channel can hang (stdin EOF
# is not reliably propagated), and a real file also lets pg_restore seek.
# pg_restore does not stop on error by default (no --exit-on-error): it restores everything it can,
# skips only the items that error, and exits non-zero to report that some errors were ignored. Those
# are usually benign (an ignorable COMMENT, a grant to a role that predates the dump), and the rest
# of the restore still happened, so we surface each as a WARNING but do NOT fail the run over it; you
# can re-run '--db <name>' for any database that needs a clean retry.
fail=0
if [ "$MODE" = "all" ]; then
  [ -f "$tmp/globals.sql" ] || { echo "error: globals.sql not in archive" >&2; exit 1; }
  echo "restoring roles/grants + every database into $NS/$POD (original names)"
  # Roles/grants first, so object ownership restores faithfully. Some roles (e.g. the Bitnami
  # defaults) may already exist; psql prints those errors but keeps going and exits 0 (no
  # ON_ERROR_STOP), so a non-zero exit here is a real failure that set -e should stop on.
  kubectl cp "$tmp/globals.sql" "$NS/$POD:/tmp/globals-$$.sql" -c "$PG_CONTAINER"
  kexec psql -U "$SUPERUSER" -d postgres -f "/tmp/globals-$$.sql"
  kexec rm -f "/tmp/globals-$$.sql" || true

  for dump in "$tmp"/*.pgc; do
    [ -e "$dump" ] || continue
    db="$(basename "$dump" .pgc)"
    echo "restoring database '$db'"
    kexec createdb -U "$SUPERUSER" "$db" 2>/dev/null || true   # may already exist
    kubectl cp "$dump" "$NS/$POD:/tmp/restore-$$.pgc" -c "$PG_CONTAINER"
    if ! kexec pg_restore -U "$SUPERUSER" -d "$db" --clean --if-exists "/tmp/restore-$$.pgc"; then
      echo "WARNING: pg_restore reported errors for database '$db' (review the output above)" >&2
      fail=$((fail + 1))
    fi
    kexec rm -f "/tmp/restore-$$.pgc" || true
  done

  echo "verification (databases present):"
  kexec psql -U "$SUPERUSER" -d postgres -c "\l"
  if [ "$fail" -gt 0 ]; then
    echo "note: $fail database(s) reported restore errors above; review them and re-run '--db <name>' if needed" >&2
  fi
  echo "done"
  exit 0
fi

# --- single database (--db) ---
dump="$tmp/$DB.pgc"
[ -f "$dump" ] || { echo "error: $DB.pgc not in archive (has: $(ls "$tmp" | tr '\n' ' '))" >&2; exit 1; }

case "$MODE" in
  live)    target="$DB" ;;
  target)  target="$TARGET" ;;
  scratch) target="${DB}_restore_$(date -u +%Y%m%d%H%M%S)" ;;
esac

if [ "$MODE" != "live" ] && [ "$MODE" != "target" ]; then
  echo "creating scratch database '$target'"
  kexec createdb -U "$SUPERUSER" "$target"
fi

echo "copying dump into the pod"
kubectl cp "$dump" "$NS/$POD:/tmp/restore-$$.pgc" -c "$PG_CONTAINER"

echo "pg_restore -> '$target'"
if ! kexec pg_restore -U "$SUPERUSER" -d "$target" --no-owner --clean --if-exists "/tmp/restore-$$.pgc"; then
  echo "WARNING: pg_restore reported errors (review the output above); the row counts below show what actually restored" >&2
fi
kexec rm -f "/tmp/restore-$$.pgc" || true

echo "verification (per-table live tuple estimates):"
kexec psql -U "$SUPERUSER" -d "$target" -c \
  "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1, 2;"

if [ "$MODE" = "scratch" ]; then
  echo "dropping scratch database '$target'"
  kexec dropdb -U "$SUPERUSER" "$target"
fi
echo "done"

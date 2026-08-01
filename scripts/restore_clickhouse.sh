#!/usr/bin/env bash
# Restore a ClickHouse backup produced by ansible/files/backup_clickhouse.sh.
#
# Runs on the operator's machine (needs kubectl, rclone and age (github.com/FiloSottile/age)
# with the OFFLINE age identity/private key). It pulls and decrypts the archive, then recreates
# the database's tables and dictionaries and INSERTs their Native data BACK ONTO THE CLUSTER.
# Each file is `kubectl cp`-ed into the pod and read there by clickhouse-client, so nothing
# streams over the exec channel. By default it restores into a throwaway database, prints row
# counts, then drops it.
#
# Usage:
#   restore_clickhouse.sh [--archive NAME] [--target DB | --live]
#     --target  restore into this existing database (created if absent)
#     --live    DROP and recreate CH_DB, then restore into it (DESTRUCTIVE; asks to confirm)
#   default:  restore into a scratch DB <CH_DB>_restore_<ts>, verify, then drop it
#
# Required env (no defaults = fail loudly rather than guess the wrong target):
#   RCLONE_REMOTE  rclone remote root, e.g. gdrive:cluster-backups
#   AGE_IDENTITY   path to your offline age identity (private key) file
#   CH_NAMESPACE   namespace of the target ClickHouse, e.g. data-services
#   CH_POD         target ClickHouse pod, e.g. clickhouse-shard0-0
#   CH_DB          database to restore, e.g. plausible_events_db
# Optional: CH_USER (default clickhouse), CH_CONTAINER (default clickhouse),
#           CH_SECRET (default clickhouse-credentials), CH_SECRET_KEY (default admin-password).
# Credentials are passed via a clickhouse-client config file copied into the pod, so the
# password never appears on any command line (nor in `ps`) and may contain any character.
set -euo pipefail

: "${RCLONE_REMOTE:?set the rclone remote root, e.g. gdrive:cluster-backups}"
: "${AGE_IDENTITY:?set the path to your offline age identity (private key) file}"
: "${CH_NAMESPACE:?set the target ClickHouse namespace, e.g. data-services}"
: "${CH_POD:?set the target ClickHouse pod, e.g. clickhouse-shard0-0}"
: "${CH_DB:?set the database to restore, e.g. plausible_events_db}"
REMOTE="$RCLONE_REMOTE/clickhouse"
NS="$CH_NAMESPACE"
POD="$CH_POD"
CH_USER="${CH_USER:-clickhouse}"
CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
CH_SECRET="${CH_SECRET:-clickhouse-credentials}"
CH_SECRET_KEY="${CH_SECRET_KEY:-admin-password}"

ARCHIVE="" TARGET="" MODE=""
# Reject a second mode flag instead of letting the last silently win (--live is destructive).
# need_arg keeps a missing value from dying on an unbound $2 under set -u.
set_mode() { [ -z "$MODE" ] || { echo "error: --target and --live are mutually exclusive" >&2; exit 2; }; MODE="$1"; }
need_arg() { [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) need_arg "$@"; ARCHIVE="$2"; shift 2 ;;
    --target) need_arg "$@"; set_mode target; TARGET="$2"; shift 2 ;;
    --live) set_mode live; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:-scratch}"
[ -f "$AGE_IDENTITY" ] || { echo "error: age identity not found: $AGE_IDENTITY" >&2; exit 2; }

tmp="$(mktemp -d)"
cfg_pod=""   # in-pod client-config path; set once written, removed by cleanup
scratch_db=""   # scratch DB to drop on exit; set once created, so a mid-restore failure cleans up too
cleanup() {
  rm -rf "$tmp"
  [ -n "$scratch_db" ] && chq --query "DROP DATABASE IF EXISTS \`$scratch_db\`" >/dev/null 2>&1 || true
  [ -n "$cfg_pod" ] && kubectl exec -c "$CH_CONTAINER" -n "$NS" "$POD" -- \
    rm -f "$cfg_pod" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(rclone lsf "$REMOTE/" | sort | tail -1)"
  [ -n "$ARCHIVE" ] || { echo "error: no archives found in $REMOTE" >&2; exit 1; }
fi
echo "restoring ClickHouse database '$CH_DB' from $REMOTE/$ARCHIVE"
rclone copy "$REMOTE/$ARCHIVE" "$tmp/"
age -d -i "$AGE_IDENTITY" "$tmp/$ARCHIVE" | tar -C "$tmp" -xzf -
[ -f "$tmp/tables.tsv" ] || { echo "error: archive is missing tables.tsv" >&2; exit 1; }

pw="$(kubectl get secret "$CH_SECRET" -n "$NS" -o jsonpath="{.data.$CH_SECRET_KEY}" | base64 -d)"

case "$MODE" in
  live) target="$CH_DB" ;;
  target) target="$TARGET" ;;
  scratch) target="${CH_DB}_restore_$(date -u +%Y%m%d%H%M%S)" ;;
esac

in_pod() { kubectl cp "$1" "$NS/$POD:$2" -c "$CH_CONTAINER"; }
rm_pod() { kubectl exec -c "$CH_CONTAINER" -n "$NS" "$POD" -- rm -f "$1"; }

# Put the credentials in a clickhouse-client config file copied into the pod rather than on
# any command line: the password stays out of argv/`ps` (in the pod and locally) and can hold
# any character, so there is no shell-quoting hazard. It is chmod 600 and dropped on exit.
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cfg_pod="/tmp/chrestore-$$.xml"
printf '<config>\n  <user>%s</user>\n  <password>%s</password>\n</config>\n' \
  "$(printf '%s' "$CH_USER" | xml_escape)" "$(printf '%s' "$pw" | xml_escape)" \
  >"$tmp/client.xml"
chmod 600 "$tmp/client.xml"
in_pod "$tmp/client.xml" "$cfg_pod"
kubectl exec -c "$CH_CONTAINER" -n "$NS" "$POD" -- chmod 600 "$cfg_pod"

# Small query straight through exec; file-fed statements are copied in first (below).
chq() { kubectl exec -i -c "$CH_CONTAINER" -n "$NS" "$POD" -- \
  clickhouse-client --config-file "$cfg_pod" "$@"; }

case "$MODE" in
  live)
    # Drop and recreate: the DDL from SHOW CREATE is a bare CREATE TABLE, so without this every object
    # fails as "already exists". This destroys the database's contents, which is what --live means.
    echo "WARNING: --live will DROP DATABASE \`$target\` on $NS/$POD and rebuild it from the backup." >&2
    printf 'Type the database name (%s) to confirm: ' "$target" >&2
    read -r confirm
    [ "$confirm" = "$target" ] || { echo "aborted" >&2; exit 1; }
    chq --query "DROP DATABASE IF EXISTS \`$target\`"
    chq --query "CREATE DATABASE \`$target\`"
    ;;
  *)
    chq --query "CREATE DATABASE IF NOT EXISTS \`$target\`"
    ;;
esac
if [ "$MODE" = "scratch" ]; then scratch_db="$target"; fi
echo "restoring into database '$target'"

# SHOW CREATE emits the source DB name; repoint it at the target (plain global replace,
# the DB name is a distinctive identifier that won't collide with other tokens). It also
# MASKS secrets, so a dictionary's SOURCE(CLICKHOUSE(... PASSWORD ...)) comes back as
# PASSWORD '[HIDDEN]' and the dictionary can't reload (auth fails) the moment an INSERT
# recomputes a MATERIALIZED dictGet() column. Re-inject the real password (we connect as the
# same user) into any PASSWORD '...'; only dictionary SOURCE clauses carry one. The password
# is escaped for use as a sed replacement (\, /, & which assumes it contains no single quote).
pw_sed="$(printf '%s' "$pw" | sed 's|[\\/&]|\\&|g')"
rewrite() { sed -e "s/$CH_DB/$target/g" -e "s/PASSWORD '[^']*'/PASSWORD '$pw_sed'/g"; }

rf="/tmp/chrestore-$$"

# Rewrite every DDL to point at the target DB, once, up front.
while IFS=$'\t' read -r name engine; do
  [ -n "$name" ] || continue
  rewrite <"$tmp/schema/$name.sql" >"$tmp/schema/$name.ddl"
done <"$tmp/tables.tsv"

# Create the schema without knowing the dependency graph. Object type implies no order here:
# a plain table (events_v2) can depend on a dictionary via an ALIAS/MATERIALIZED dictGet(),
# while that dictionary reads another table, so no fixed table/dict/view sequence works.
# Instead retry the not-yet-created objects until a full pass creates nothing new; each pass
# creates whatever now has its dependencies satisfied. Converges for any acyclic schema; a
# pass with zero progress means a real cycle or bad DDL, so we stop and report it.
done_dir="$tmp/done"; mkdir "$done_dir"
while :; do
  progress=0 remaining=0 lasterr=""
  while IFS=$'\t' read -r name engine; do
    [ -n "$name" ] || continue
    [ -e "$done_dir/$name" ] && continue
    in_pod "$tmp/schema/$name.ddl" "$rf.sql"
    if err="$(kubectl exec -c "$CH_CONTAINER" -n "$NS" "$POD" -- \
        clickhouse-client --config-file "$cfg_pod" --queries-file "$rf.sql" 2>&1)"; then
      echo "  created $name"; : >"$done_dir/$name"; progress=1
    else
      remaining=$((remaining + 1)); lasterr="$name: $err"
    fi
  done <"$tmp/tables.tsv"
  [ "$remaining" -eq 0 ] && break
  if [ "$progress" -eq 0 ]; then
    echo "error: unable to create the remaining $remaining object(s) (dependency cycle or bad DDL)." >&2
    echo "last failure -> $lasterr" >&2
    exit 1
  fi
done
rm_pod "$rf.sql"

# Load the Native data (schema-only objects namely dictionaries/views, have no .native file).
# Streamed from the copied-in file via the pod's shell; only trusted paths/identifiers are
# interpolated into the command, never the password.
while IFS=$'\t' read -r name engine; do
  [ -n "$name" ] || continue
  [ -s "$tmp/data/$name.native" ] || continue
  echo "  data $name"
  in_pod "$tmp/data/$name.native" "$rf.native"
  kubectl exec -c "$CH_CONTAINER" -n "$NS" "$POD" -- \
    sh -c "clickhouse-client --config-file '$cfg_pod' --database '$target' --query 'INSERT INTO \`$name\` FORMAT Native' < '$rf.native'"
  rm_pod "$rf.native"
done <"$tmp/tables.tsv"

echo "verification (row counts):"
chq --query "SELECT name, total_rows FROM system.tables WHERE database = '$target' ORDER BY name FORMAT PrettyCompact"

echo "done"   # a scratch DB is dropped by cleanup() on exit, including after a failed restore

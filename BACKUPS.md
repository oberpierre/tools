# Backups & Restore

The cluster's central stateful stores are backed up as **encrypted, off-site logical dumps**. Each night every store is dumped, encrypted client-side, and pushed to a remote (e.g. Google Drive). This guide is the operational runbook: how the backups work, and how to pull, restore, and verify them.

Setup is the [`k8s_setup_backups.yml`](ansible/k8s_setup_backups.yml) playbook, see the [Ansible README](ansible/README.md#usage).

## What gets backed up

| Store                  | Contents                                                        | Method                                                                        |
| ---------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Central **Postgres**   | Cluster roles/grants + one custom-format dump per user database | `pg_dumpall --globals-only` + `pg_dump -Fc`                                   |
| Central **ClickHouse** | Every table's schema and data in the events database            | Network-only logical dump: `SHOW CREATE` + `SELECT … FORMAT Native` over HTTP |

Every run is a **full, self-contained snapshot**, there is no incremental chain, so any single archive restores the whole store on its own. Retention keeps the newest `KEEP_LAST` (default 14); older archives are pruned.

## How it works

- Nightly **CronJobs** run [`backup_postgres.sh`](ansible/files/backup_postgres.sh) and [`backup_clickhouse.sh`](ansible/files/backup_clickhouse.sh).
- Each dump is bundled, encrypted with [age](https://github.com/FiloSottile/age), and uploaded with [rclone](https://rclone.org/) to `<remote>/postgres/` and `<remote>/clickhouse/`.
- Archives are named `postgres-<UTC-timestamp>.tar.gz.age` and `clickhouse-<UTC-timestamp>.tar.gz.age`.

Nothing touches the databases' data directories, the dumps run over the network against the running servers, so a backup never interferes with them.

## Encryption & keys

Backups are encrypted to an **age public recipient**. Keep the matching **private key OFFLINE**, it should never be stored on the cluster or on the remote.

The private key is used **only** during restoration or verification of the data, never during the backup itself.

> **If you lose the private key, every backup becomes unreadable.** Keep an offline copy somewhere separate from both the cluster and the remote.

## Configuration

Backup settings live in [`k8s_setup_backups.yml`](ansible/k8s_setup_backups.yml):

| Variable             | Purpose                                                      | Default                                        |
| -------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| `backup_remote`      | rclone `remote:path` root; each store gets its own subfolder | `gdrive:cluster-backups`                       |
| `backup_keep_last`   | How many of the newest archives to keep per store            | `14`                                           |
| `backups[].schedule` | Cron schedule per store                                      | postgres: `0 2 * * *`, clickhouse: `0 3 * * *` |

The rclone config and the age **public** recipient come from Vault (`vault_backup_rclone_conf`, `vault_backup_age_recipient`), see [`example_user_vault.yml`](ansible/vars/example_user_vault.yml). Re-run the `k8s_setup_backups.yml` playbook after changing any of these.

## Operator prerequisites

The scripts below run on **your machine**, not the cluster. You need:

- [`rclone`](https://rclone.org/) configured with the same remote (e.g. a `gdrive` remote)
- [`age`](https://github.com/FiloSottile/age) and your **offline** identity (private key) file
- `kubectl` with cluster access, **only** for restore/verify (pulling needs neither kubectl nor the cluster)

Every script is driven by environment variables and fails loudly if a required one is missing.

> The example commands below use the playbook defaults: namespace `data-services`, pod names `postgresql-0` / `clickhouse-shard0-0`, `clickhouse` username, and the ClickHouse events DB `plausible_events_db`. These reflect the default/example setup, adjust them to your configuration. Values in `{{ }}` (your age-key path and Postgres database name) are placeholders to fill in.

## Trigger a backup on demand

The CronJobs run nightly, but you may fire one immediately on demand:

```bash
kubectl create job -n data-services --from=cronjob/backup-postgres pg-backup-now
kubectl logs -n data-services job/pg-backup-now -f
kubectl create job -n data-services --from=cronjob/backup-clickhouse ch-backup-now
kubectl logs -n data-services job/ch-backup-now -f
```

## Pull a backup locally

The backups are plain age-encrypted tarballs under the remote, so rclone and age are all you need to fetch or inspect one, no dedicated tooling required. Restoring INTO a running instance is the job of the restore scripts (below), which pull and decrypt on their own.

```bash
# List the archives
rclone lsf gdrive:cluster-backups/postgres/ | sort -r
# List the newest archive
rclone lsf gdrive:cluster-backups/postgres/ | sort -r | head -n 1

# Keep an offline (still-encrypted) copy of an archive
rclone copy gdrive:cluster-backups/postgres/postgres-<ts>.tar.gz.age ./

# Decrypt and extract to inspect (needs your offline age key)
age -d -i {{ path_to_age_key }} postgres-<ts>.tar.gz.age | tar -xzf -
```

Swap `postgres` for `clickhouse` to work with the ClickHouse archives.

## Restore

Both restore scripts default to **scratch mode**: they restore into a throwaway database, print row counts, then drop it, so you never risk live data while checking a backup. Pass `--target <db>` to restore into an existing database, or `--live` to overwrite the original (**NOTE that this is destructive**).

### Postgres - [`scripts/restore_postgres.sh`](scripts/restore_postgres.sh)

Env: `RCLONE_REMOTE`, `AGE_IDENTITY`, `PG_NAMESPACE`, `PG_POD` (optional `PG_SUPERUSER` = `postgres`, `PG_CONTAINER` = `postgresql`). `--db` selects which `<db>.pgc` inside the archive to restore.

```bash
RCLONE_REMOTE=gdrive:cluster-backups AGE_IDENTITY={{ path_to_age_key }} \
PG_NAMESPACE=data-services PG_POD=postgresql-0 \
  scripts/restore_postgres.sh --db {{ database }}
```

### ClickHouse - [`scripts/restore_clickhouse.sh`](scripts/restore_clickhouse.sh)

Env: `RCLONE_REMOTE`, `AGE_IDENTITY`, `CH_NAMESPACE`, `CH_POD`, `CH_DB` (optional `CH_USER`, `CH_CONTAINER`, `CH_SECRET`, `CH_SECRET_KEY`).

```bash
RCLONE_REMOTE=gdrive:cluster-backups AGE_IDENTITY={{ path_to_age_key }} \
CH_NAMESPACE=data-services CH_POD=clickhouse-shard0-0 CH_DB=plausible_events_db \
CH_USER=clickhouse \
  scripts/restore_clickhouse.sh
```

The script creates the schema in dependency order automatically and re-injects the dictionary source password (which `SHOW CREATE` masks), so ClickHouse's dictionaries and `dictGet`-derived columns restore cleanly.

> **`--live` and ClickHouse:** `MATERIALIZED` columns that call `dictGet()` are recomputed on insert. For a faithful live restore, load the dictionaries' source tables and `SYSTEM RELOAD DICTIONARIES` before inserting the dependent tables. Scratch verification is unaffected - row counts are correct regardless.

## Verify a backup

**A backup you haven't restored isn't a backup.** The scratch-mode restore _is_ the verification: it pulls the latest archive, restores into a throwaway database, prints per-table row counts, and drops it, proving restorability without touching live data.

```bash
# Postgres - restore latest into a scratch DB, print row counts, drop it
RCLONE_REMOTE=gdrive:cluster-backups AGE_IDENTITY={{ path_to_age_key }} \
PG_NAMESPACE=data-services PG_POD=postgresql-0 \
  scripts/restore_postgres.sh --db {{ database }}

# ClickHouse - same, into a scratch DB
RCLONE_REMOTE=gdrive:cluster-backups AGE_IDENTITY={{ path_to_age_key }} \
CH_NAMESPACE=data-services CH_POD=clickhouse-shard0-0 CH_DB=plausible_events_db \
CH_USER=clickhouse \
  scripts/restore_clickhouse.sh
```

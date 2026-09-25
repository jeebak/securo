# Securo backup/restore (local ops, not part of upstream)

Local-only tooling for this self-hosted deployment. Not tracked by the
upstream repo (see `.git/info/exclude`) and not something to contribute back.

## What gets backed up

- **Postgres** (`securo` db) — logical `pg_dump --format=custom`, gzipped.
  Portable across Postgres/pgvector image versions and doesn't require
  quiescing the app (pg_dump takes a consistent MVCC snapshot against a live
  database).
- **`attachments` volume** — uploaded receipts.
- **`agent_knowledge` volume** — the agents feature's RAG knowledge base.
- **`.env` and `secrets/`** — SimpleFIN tokens, MCP signing key, everything
  that would otherwise mean relinking every bank connection from scratch.
  Copied with `chmod go-rwx`.

**Deliberately excluded:** the `agent_embedding_models` volume — a
re-downloadable ONNX model cache, not user data.

## Where backups go

`$SECURO_BACKUP_ROOT`, default `${XDG_DATA_HOME:-~/.local/share}/backups/securo`
— outside this clone (so it survives a `git clean` and
isn't accidentally excluded/included by this repo's own `.gitignore`). One
timestamped subdirectory per run. Anything older than `$SECURO_BACKUP_RETENTION_DAYS`
(default 7) is pruned automatically.

Each run's `$DEST` also syncs to S3 (`s3://$SECURO_BACKUP_S3_BUCKET/<timestamp>/`,
`AWS_PROFILE=securo-backup` — a dedicated IAM user scoped to only
`PutObject`/`GetObject`/`ListBucket` on that one bucket, no `DeleteObject`, so
a leaked key can't be used to wipe existing backups). The bucket has its own
independent lifecycle rule (90-day expiration, 14-day noncurrent-version
expiration on top of versioning) — remote retention isn't tied to
`$SECURO_BACKUP_RETENTION_DAYS`. The bucket name is personal config, so it is
read from `${XDG_CONFIG_HOME:-~/.config}/securo/backup.env`
(`SECURO_BACKUP_S3_BUCKET=...`); an empty value skips the sync and an unset one
fails the run. Override the profile via `$SECURO_BACKUP_S3_PROFILE`. A sync failure logs an
ERROR and the script exits 1 after the local backup and pruning have finished,
so the unit shows up in `systemctl --user --failed`. The local backup that run
produced is still good, but that run has no off-host copy until the next one
succeeds. The unit sets `Environment=PATH=...` to include mise's awscli
install, because systemd's default user PATH lacks `aws` and, without it,
every timer run fails the sync.

## Running it

Manual (also do this before any `docker compose pull`, since the stack
tracks `:latest` with no version pin):

```
ops/backup.sh
```

Scheduled: a systemd --user timer, daily at 03:00 (±15min jitter),
`Persistent=true` so a missed run (machine off at 3am) fires on next login —
this account already has lingering enabled, so it runs even logged out.

```
cp ops/systemd/securo-backup.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now securo-backup.timer
systemctl --user list-timers securo-backup.timer   # confirm next run
journalctl --user -u securo-backup.service          # check a run's output
```

## Restoring

```
ops/restore.sh ~/.local/share/backups/securo/<timestamp>
```

Destructive — drops and recreates the `securo` database, so it prompts for
an explicit `restore` confirmation. Restores the Postgres dump automatically;
prints the commands for the attachments/agent_knowledge volumes and leaves
config (`.env`/`secrets/`) for you to diff and copy back by hand, so a
restore can never silently clobber live credentials.

**An untested backup isn't a backup.** Periodically restore into a throwaway
compose project (`docker compose -p securo-restore-test ...`) to confirm the
dump actually restores end to end, rather than trusting the timer's exit code
alone.

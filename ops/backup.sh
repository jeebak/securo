#!/usr/bin/env bash
# Backs up the self-hosted Securo stack: a logical Postgres dump (pg_dump,
# not a raw volume copy -- portable across Postgres/pgvector image versions
# and doesn't require quiescing the app, since pg_dump takes a consistent
# MVCC snapshot against a live database), the attachments and agent_knowledge
# volumes, and the .env/secrets/ config that would otherwise mean relinking
# every SimpleFIN connection from scratch. Skips the
# agent_embedding_models volume deliberately -- it's a re-downloadable ONNX
# model cache, not user data.
#
# Also syncs the fresh backup to S3 (bucket/profile below) as the off-host
# copy -- a scoped IAM user with only PutObject/GetObject/ListBucket on that
# one bucket, no DeleteObject, so a leaked key can't be used to wipe existing
# backups. The bucket has its own independent lifecycle (90-day expiration),
# so remote retention isn't tied to RETENTION_DAYS below.
#
# Run manually before any `docker compose pull` (the running stack tracks
# :latest with no version pin, so an update can land further ahead than
# expected), and on a schedule via the systemd timer in ops/systemd/.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${SECURO_BACKUP_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/backups/securo}"
RETENTION_DAYS="${SECURO_BACKUP_RETENTION_DAYS:-7}"
STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
DEST="$BACKUP_ROOT/$STAMP"

cd "$COMPOSE_DIR"
mkdir -p "$DEST"

echo "[$STAMP] Backing up Postgres (logical dump)..."
docker compose exec -T db pg_dump -U postgres -d securo --format=custom \
  | gzip > "$DEST/securo-db.dump.gz"

echo "[$STAMP] Backing up attachments volume..."
docker run --rm \
  -v securo_attachments:/data:ro \
  -v "$DEST":/backup \
  alpine tar czf /backup/attachments.tar.gz -C /data .

echo "[$STAMP] Backing up agent_knowledge volume..."
docker run --rm \
  -v securo_agent_knowledge:/data:ro \
  -v "$DEST":/backup \
  alpine tar czf /backup/agent_knowledge.tar.gz -C /data .

echo "[$STAMP] Backing up config (.env, secrets/)..."
mkdir -p "$DEST/config"
cp "$COMPOSE_DIR/.env" "$DEST/config/.env"
cp -r "$COMPOSE_DIR/secrets" "$DEST/config/secrets"
chmod -R go-rwx "$DEST/config"

echo "[$STAMP] Recording source version..."
git -C "$COMPOSE_DIR" describe --tags >"$DEST/SECURO_VERSION.txt" 2>/dev/null || echo "unknown" >"$DEST/SECURO_VERSION.txt"

SIZE="$(du -sh "$DEST" | cut -f1)"
echo "[$STAMP] Backup complete: $DEST ($SIZE)"

# AWS_CA_BUNDLE is set globally on this host to a path that doesn't exist,
# which breaks the CLI's SSL validation -- unset it just for this call.
# The bucket name is personal config, kept out of this (public) repo: set
# SECURO_BACKUP_S3_BUCKET in ${XDG_CONFIG_HOME:-~/.config}/securo/backup.env, or export it. An
# explicitly empty value skips the sync; an unset one fails the run.
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/securo/backup.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"
S3_BUCKET="${SECURO_BACKUP_S3_BUCKET-__unset__}"
S3_PROFILE="${SECURO_BACKUP_S3_PROFILE:-securo-backup}"
SYNC_OK=1
if [[ "$S3_BUCKET" == "__unset__" ]]; then
  SYNC_OK=0
  echo "[$STAMP] ERROR: SECURO_BACKUP_S3_BUCKET is not set (see $CONFIG) -- no off-host copy for this run." >&2
elif [[ -n "$S3_BUCKET" ]]; then
  echo "[$STAMP] Syncing to s3://$S3_BUCKET/$STAMP/..."
  if env -u AWS_CA_BUNDLE aws s3 sync "$DEST" "s3://$S3_BUCKET/$STAMP/" --profile "$S3_PROFILE"; then
    echo "[$STAMP] Off-host copy complete."
  else
    SYNC_OK=0
    echo "[$STAMP] ERROR: S3 sync failed -- local backup is still good, but this run has no off-host copy." >&2
  fi
fi

echo "[$STAMP] Pruning backups older than ${RETENTION_DAYS}d..."
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \;

echo "[$STAMP] Done."
# Fail the unit (after the local backup and pruning finished) so a missing
# off-host copy shows up in `systemctl --user --failed`, not only in the log.
[[ $SYNC_OK == 1 ]] || exit 1

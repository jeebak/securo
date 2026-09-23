#!/usr/bin/env bash
# Backs up the self-hosted Securo stack: a logical Postgres dump (pg_dump,
# not a raw volume copy -- portable across Postgres/pgvector image versions
# and doesn't require quiescing the app, since pg_dump takes a consistent
# MVCC snapshot against a live database), the attachments and agent_knowledge
# volumes, and the .env/secrets/ config that would otherwise mean relinking
# every SimpleFIN/Truthifi connection from scratch. Skips the
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
BACKUP_ROOT="${SECURO_BACKUP_ROOT:-$HOME/Projects/repos/Financial/github.com/securo-backups}"
RETENTION_DAYS="${SECURO_BACKUP_RETENTION_DAYS:-30}"
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
S3_BUCKET="${SECURO_BACKUP_S3_BUCKET:-jeebak-securo-backups}"
S3_PROFILE="${SECURO_BACKUP_S3_PROFILE:-securo-backup}"
echo "[$STAMP] Syncing to s3://$S3_BUCKET/$STAMP/..."
if env -u AWS_CA_BUNDLE aws s3 sync "$DEST" "s3://$S3_BUCKET/$STAMP/" --profile "$S3_PROFILE"; then
  echo "[$STAMP] Off-host copy complete."
else
  echo "[$STAMP] WARNING: S3 sync failed -- local backup is still good, but this run has no off-host copy. Investigate before relying on it." >&2
fi

echo "[$STAMP] Pruning backups older than ${RETENTION_DAYS}d..."
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \;

echo "[$STAMP] Done."

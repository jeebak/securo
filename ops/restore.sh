#!/usr/bin/env bash
# Restores a Securo backup made by backup.sh. DESTRUCTIVE to the live
# database -- run manually only, never on a timer, and confirm you're
# pointed at the right stack before typing "restore".
#
# Usage: ops/restore.sh /path/to/securo-backups/<timestamp>
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/backup-timestamp-dir}"

if [[ ! -f "$SRC/securo-db.dump.gz" ]]; then
  echo "No securo-db.dump.gz in $SRC -- is this a backup.sh output dir?" >&2
  exit 1
fi

echo "About to DROP and recreate the 'securo' database in:"
echo "  $COMPOSE_DIR"
echo "and restore it from:"
echo "  $SRC"
if [[ -f "$SRC/SECURO_VERSION.txt" ]]; then
  echo "  (backup was taken at Securo version: $(cat "$SRC/SECURO_VERSION.txt"))"
fi
read -r -p "Type 'restore' to continue: " CONFIRM
[[ "$CONFIRM" == "restore" ]] || { echo "Aborted."; exit 1; }

cd "$COMPOSE_DIR"

echo "Stopping app services (leaving db up)..."
docker compose stop backend celery-worker celery-beat mcp-server frontend

echo "Dropping and recreating database..."
docker compose exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS securo;"
docker compose exec -T db psql -U postgres -c "CREATE DATABASE securo;"

echo "Restoring dump..."
gunzip -c "$SRC/securo-db.dump.gz" | docker compose exec -T db pg_restore -U postgres -d securo

echo
echo "Database restored. NOT auto-restored (do these manually if needed):"
echo
echo "  Attachments volume:"
echo "    docker run --rm -v securo_attachments:/data -v $SRC:/backup alpine \\"
echo "      sh -c 'rm -rf /data/* && tar xzf /backup/attachments.tar.gz -C /data'"
echo
echo "  Agent knowledge volume:"
echo "    docker run --rm -v securo_agent_knowledge:/data -v $SRC:/backup alpine \\"
echo "      sh -c 'rm -rf /data/* && tar xzf /backup/agent_knowledge.tar.gz -C /data'"
echo
echo "  Config (.env, secrets/) is in $SRC/config/ -- deliberately not auto-restored,"
echo "  to avoid silently overwriting live credentials/tokens. Diff before copying back."
echo
echo "Restart the stack when ready: docker compose up -d"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

COLLECTION=3179428851
RCONPW=$(grep -E '^CS2_RCONPW=' .env | cut -d= -f2-)
started=$(docker inspect -f '{{.State.StartedAt}}' cs2)

for _ in $(seq 1 60); do
  if docker logs --since "$started" cs2 2>&1 | grep -q "GameServerSteamAPIActivated"; then
    sleep 5
    rcon -a 127.0.0.1:27015 -p "$RCONPW" "host_workshop_collection $COLLECTION"
    exit 0
  fi
  sleep 5
done

echo "timed out waiting for Steam logon" >&2
exit 1

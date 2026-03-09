#!/usr/bin/env bash
# Manually check for and apply OpenClaw version updates.
# Usage: ./scripts/upgrade.sh [version]
# If no version is given, fetches the latest from GHCR.
set -euo pipefail

DOCKERFILE="Dockerfile"

if [[ -n "${1:-}" ]]; then
  LATEST="$1"
else
  echo "Fetching latest OpenClaw version from GHCR..."
  TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:openclaw/openclaw:pull" | jq -r '.token')
  TAGS=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://ghcr.io/v2/openclaw/openclaw/tags/list" | jq -r '.tags[]')

  LATEST=$(echo "$TAGS" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' \
    | sort -V \
    | tail -1)
fi

CURRENT=$(grep -oP 'OPENCLAW_VERSION=\K[^ ]+' "$DOCKERFILE" | head -1)

if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "Already up to date: $CURRENT"
  exit 0
fi

echo "Updating: $CURRENT → $LATEST"
sed -i'' -e "s/OPENCLAW_VERSION=.*/OPENCLAW_VERSION=$LATEST/" "$DOCKERFILE"
echo "Done. Commit and push to trigger Railway redeploy."

#!/usr/bin/env bash
# Manually check for and apply OpenClaw version updates.
# Usage: ./scripts/upgrade.sh [version]
# If no version is given, fetches the latest from GHCR.
set -euo pipefail

DOCKERFILE="Dockerfile"

if [[ -n "${1:-}" ]]; then
  LATEST="$1"
else
  echo "Fetching latest OpenClaw version from GitHub releases..."
  LATEST=$(curl -fsSL https://api.github.com/repos/openclaw/openclaw/releases/latest \
    | jq -r '.tag_name | ltrimstr("v")')
fi

CURRENT=$(sed -n 's/^ARG OPENCLAW_VERSION=//p' "$DOCKERFILE" | head -1)

if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "Already up to date: $CURRENT"
  exit 0
fi

echo "Updating: $CURRENT → $LATEST"
sed -i'' -e "s/OPENCLAW_VERSION=.*/OPENCLAW_VERSION=$LATEST/" "$DOCKERFILE"
echo "Done. Commit and push to trigger Railway redeploy."

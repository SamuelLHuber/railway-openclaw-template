#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-}"
NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
DEPLOYMENT="${OPENCLAW_DEPLOYMENT:-openclaw}"

kubectl_cmd() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
  else
    kubectl "$@"
  fi
}

list_cmd=(exec -n "$NAMESPACE" deploy/"$DEPLOYMENT" -- sh -lc 'node openclaw.mjs devices list')

if [[ "${1:-}" == "list" ]]; then
  exec kubectl_cmd "${list_cmd[@]}"
fi

if [[ "${1:-}" == "approve" ]]; then
  request_id="${2:-}"
  if [[ -z "$request_id" ]]; then
    echo "usage: $0 approve <requestId>" >&2
    exit 1
  fi
  exec kubectl_cmd exec -n "$NAMESPACE" deploy/"$DEPLOYMENT" -- sh -lc "node openclaw.mjs devices approve $request_id"
fi

pending_id=$(kubectl_cmd "${list_cmd[@]}" | awk '/^[│] [0-9a-f-]{36} / {gsub(/│/,"",$2); print $2; exit}')

if [[ -z "$pending_id" ]]; then
  echo "No pending device requests found."
  exit 0
fi

echo "Approving pending request: $pending_id"
exec kubectl_cmd exec -n "$NAMESPACE" deploy/"$DEPLOYMENT" -- sh -lc "node openclaw.mjs devices approve $pending_id"

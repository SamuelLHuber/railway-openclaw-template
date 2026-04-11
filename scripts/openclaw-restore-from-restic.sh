#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-}"
NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
RELEASE_NAME="${OPENCLAW_RELEASE_NAME:-openclaw}"
CHART_PATH="${OPENCLAW_CHART_PATH:-charts/openclaw}"
SNAPSHOT="${OPENCLAW_RESTORE_SNAPSHOT:-latest}"
RUN_ID="${OPENCLAW_RESTORE_RUN_ID:-restore-$(date -u +%Y%m%d%H%M%S)}"
RESTORE_SECRET="${OPENCLAW_RESTORE_SECRET:-}"

kubectl_cmd() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
  else
    kubectl "$@"
  fi
}

helm_cmd() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG="$KUBECONFIG_PATH" helm "$@"
  else
    helm "$@"
  fi
}

echo "[1/6] Scaling OpenClaw deployment down"
kubectl_cmd -n "$NAMESPACE" scale deploy/openclaw --replicas=0
kubectl_cmd -n "$NAMESPACE" rollout status deploy/openclaw --timeout=300s || true

echo "[2/6] Enabling restore job (runId=$RUN_ID, snapshot=$SNAPSHOT)"
helm_args=(upgrade "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE" --reuse-values
  --set restore.enabled=true
  --set restore.runId="$RUN_ID"
  --set restore.snapshot="$SNAPSHOT")

if [[ -n "$RESTORE_SECRET" ]]; then
  helm_args+=(--set restore.existingSecret="$RESTORE_SECRET")
fi

helm_cmd "${helm_args[@]}"

JOB_NAME="${RELEASE_NAME}-restore-${RUN_ID}"
JOB_NAME="$(echo "$JOB_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
JOB_NAME="${JOB_NAME:0:63}"
JOB_NAME="${JOB_NAME%-}"

echo "[3/6] Waiting for restore job: $JOB_NAME"
kubectl_cmd -n "$NAMESPACE" wait --for=condition=complete --timeout=900s "job/$JOB_NAME"

echo "[4/6] Restore job logs"
POD_NAME="$(kubectl_cmd -n "$NAMESPACE" get pods -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}')"
kubectl_cmd -n "$NAMESPACE" logs "$POD_NAME" -c restic-restore --tail=120
kubectl_cmd -n "$NAMESPACE" logs "$POD_NAME" -c verify-openclaw-backup --tail=120
kubectl_cmd -n "$NAMESPACE" logs "$POD_NAME" -c apply-restore --tail=120

echo "[5/6] Disabling restore mode in Helm values"
helm_cmd upgrade "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE" --reuse-values --set restore.enabled=false

echo "[6/6] Scaling OpenClaw deployment back up"
kubectl_cmd -n "$NAMESPACE" scale deploy/openclaw --replicas=1
kubectl_cmd -n "$NAMESPACE" rollout status deploy/openclaw --timeout=300s

echo "Restore complete."

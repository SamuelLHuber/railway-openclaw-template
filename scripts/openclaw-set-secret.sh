#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-}"
NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
SECRET_NAME="${OPENCLAW_SECRET_NAME:-openclaw-secret}"

kubectl_cmd() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
  else
    kubectl "$@"
  fi
}

get_existing_secret_value() {
  local key="$1"
  kubectl_cmd -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

existing_gateway_password="$(get_existing_secret_value OPENCLAW_GATEWAY_PASSWORD)"
existing_allowed_origin="$(get_existing_secret_value OPENCLAW_ALLOWED_ORIGIN)"
existing_openai_api_key="$(get_existing_secret_value OPENAI_API_KEY)"
existing_anthropic_api_key="$(get_existing_secret_value ANTHROPIC_API_KEY)"
existing_gemini_api_key="$(get_existing_secret_value GEMINI_API_KEY)"
existing_openrouter_api_key="$(get_existing_secret_value OPENROUTER_API_KEY)"
existing_mistral_api_key="$(get_existing_secret_value MISTRAL_API_KEY)"

GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-$existing_gateway_password}"
ALLOWED_ORIGIN="${OPENCLAW_ALLOWED_ORIGIN:-$existing_allowed_origin}"
OPENAI_API_KEY_VALUE="${OPENAI_API_KEY:-$existing_openai_api_key}"
ANTHROPIC_API_KEY_VALUE="${ANTHROPIC_API_KEY:-$existing_anthropic_api_key}"
GEMINI_API_KEY_VALUE="${GEMINI_API_KEY:-$existing_gemini_api_key}"
OPENROUTER_API_KEY_VALUE="${OPENROUTER_API_KEY:-$existing_openrouter_api_key}"
MISTRAL_API_KEY_VALUE="${MISTRAL_API_KEY:-$existing_mistral_api_key}"

if [[ -z "$GATEWAY_PASSWORD" ]]; then
  echo "OPENCLAW_GATEWAY_PASSWORD is required (or must already exist in the secret)" >&2
  exit 1
fi

if [[ -z "$ALLOWED_ORIGIN" ]]; then
  echo "OPENCLAW_ALLOWED_ORIGIN is required (or must already exist in the secret)" >&2
  exit 1
fi

cmd=(create secret generic "$SECRET_NAME"
  -n "$NAMESPACE"
  --from-literal=OPENCLAW_GATEWAY_PASSWORD="$GATEWAY_PASSWORD"
  --from-literal=OPENCLAW_ALLOWED_ORIGIN="$ALLOWED_ORIGIN"
  --dry-run=client -o yaml)

if [[ -n "$OPENAI_API_KEY_VALUE" ]]; then
  cmd+=(--from-literal=OPENAI_API_KEY="$OPENAI_API_KEY_VALUE")
fi
if [[ -n "$ANTHROPIC_API_KEY_VALUE" ]]; then
  cmd+=(--from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_VALUE")
fi
if [[ -n "$GEMINI_API_KEY_VALUE" ]]; then
  cmd+=(--from-literal=GEMINI_API_KEY="$GEMINI_API_KEY_VALUE")
fi
if [[ -n "$OPENROUTER_API_KEY_VALUE" ]]; then
  cmd+=(--from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY_VALUE")
fi
if [[ -n "$MISTRAL_API_KEY_VALUE" ]]; then
  cmd+=(--from-literal=MISTRAL_API_KEY="$MISTRAL_API_KEY_VALUE")
fi

kubectl_cmd "${cmd[@]}" | kubectl_cmd apply -f -

echo "Secret applied in namespace $NAMESPACE"
echo "Restart OpenClaw to pick up changed env vars:"
if [[ -n "$KUBECONFIG_PATH" ]]; then
  echo "kubectl --kubeconfig $KUBECONFIG_PATH -n $NAMESPACE rollout restart deploy/openclaw"
else
  echo "kubectl -n $NAMESPACE rollout restart deploy/openclaw"
fi

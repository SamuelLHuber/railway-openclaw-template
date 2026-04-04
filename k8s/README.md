# OpenClaw on Kubernetes: local validation reference

This directory contains reference manifests and notes for validating an OpenClaw Kubernetes deployment locally.

These files are **reference artifacts**, not final production packaging.
The supported portable Kubernetes packaging path for this repo is the Helm chart in `charts/openclaw/`.

Included files:
- `reference-k3d.yaml` — validated base deployment on `k3d`
- `networkpolicy-reference.yaml` — validated reference NetworkPolicy model
- `gatewayapi-envoy-k3d-reference.yaml` — validated local Gateway API routing example using Envoy Gateway
- `../charts/openclaw/` — portable Helm chart for the hardened OpenClaw deployment model

---

## What this validates

The local validation flow is intended to prove:
- upstream OpenClaw image works on Kubernetes
- `/data` PVC model works
- seed-only init-container config model works
- persisted config is not overwritten on restart
- app runs as non-root
- service account token is not mounted
- public internet egress can be allowed
- internal/private destinations can be blocked with `NetworkPolicy`
- OpenClaw can be routed through Kubernetes Gateway API
- Control UI password auth works through that routing path

The intended NetworkPolicy model is:

Allowed world:
- public internet egress
- DNS
- inbound only from the actual Gateway API dataplane path

Forbidden world:
- Kubernetes API
- cluster services
- pod network
- service CIDRs
- node private subnets
- private RFC1918 destinations
- metadata endpoints

Also keep these controls separate:

- `NetworkPolicy` = who may connect and where OpenClaw may egress
- `gateway.trustedProxies` = whose forwarded headers OpenClaw may believe

For the portable template:
- `NetworkPolicy` is required
- `trustedProxies` is recommended and environment-specific

---

## Prerequisites

Required locally:
- `docker`
- `kubectl`
- `k3d`

Optional but used in the validated Gateway API path:
- internet access from the cluster to install Envoy Gateway manifests

---

## 1. Create a local cluster

```bash
k3d cluster create openclaw-test --servers 1 --agents 0 --wait
kubectl config use-context k3d-openclaw-test
```

Verify cluster health:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

---

## 2. Deploy the validated base OpenClaw setup

Apply the base manifest:

```bash
kubectl apply -f k8s/reference-k3d.yaml
kubectl -n openclaw rollout status deploy/openclaw --timeout=180s
kubectl -n openclaw get pods,pvc,svc -o wide
```

What this gives you:
- namespace `openclaw`
- service account with `automountServiceAccountToken: false`
- secret with bootstrap password/origin values
- PVC mounted at `/data`
- init container that seeds `openclaw.json` only if missing
- upstream image deployment
- `ClusterIP` service

---

## 3. Verify the runtime model

Inspect the running pod:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc '
  id
  echo ---
  ls -ld /data /data/.openclaw /data/workspace
  echo ---
  test -e /var/run/secrets/kubernetes.io/serviceaccount && echo token-present || echo token-absent
  echo ---
  sed -n "1,80p" /data/.openclaw/openclaw.json
'
```

You should confirm:
- runtime uid/gid is `1000:1000`
- `/data/.openclaw/openclaw.json` exists
- no service account token is mounted
- config contains password auth and allowed origin

---

## 4. Verify app health directly

Get the pod IP:

```bash
PODIP=$(kubectl -n openclaw get pod -l app=openclaw -o jsonpath='{.items[0].status.podIP}')
echo "$PODIP"
```

Check health from inside the pod:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -sS http://$PODIP:8080/healthz"
```

Expected response:

```json
{"ok":true,"status":"live"}
```

---

## 5. Verify seed-only config ownership

Change the persisted config manually:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "node -e 'const fs=require(\"fs\"); const p=\"/data/.openclaw/openclaw.json\"; let s=fs.readFileSync(p,\"utf8\"); s=s.replace(\"openai/gpt-5.4-mini\",\"openai/gpt-5.4\"); fs.writeFileSync(p,s); console.log(\"updated\")'"
```

Restart the deployment:

```bash
kubectl -n openclaw rollout restart deploy/openclaw
kubectl -n openclaw rollout status deploy/openclaw --timeout=180s
```

Confirm the file was **not** overwritten by the init container:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "grep -n 'primary' /data/.openclaw/openclaw.json"
```

If you want to restore the original value for later tests:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "node -e 'const fs=require(\"fs\"); const p=\"/data/.openclaw/openclaw.json\"; let s=fs.readFileSync(p,\"utf8\"); s=s.replace(\"openai/gpt-5.4\",\"openai/gpt-5.4-mini\"); fs.writeFileSync(p,s)'"
kubectl -n openclaw rollout restart deploy/openclaw
kubectl -n openclaw rollout status deploy/openclaw --timeout=180s
```

---

## 6. Verify public internet egress and baseline cluster reachability

Check public internet egress:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -I -s https://api.github.com | head -1"
```

Check Kubernetes API network reachability before NetworkPolicy:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -k -sS -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc"
```

Typical result before isolation:
- public internet works
- Kubernetes API returns `401` (reachable but unauthorized)

This demonstrates why network isolation is still required even when no service account token is mounted.

---

## 7. Validate NetworkPolicy behavior

The reference policy assumes inbound traffic should come only from the Gateway dataplane path.

For local validation, create synthetic allowed/disallowed clients first.

Create a synthetic allowed source namespace/pod and disallowed peer pods:

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: gateway-test
---
apiVersion: v1
kind: Namespace
metadata:
  name: peer-test
---
apiVersion: v1
kind: Pod
metadata:
  name: gateway-client
  namespace: gateway-test
  labels:
    access: openclaw-gateway
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.7.1
      command: ["sh", "-lc", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: peer-client
  namespace: peer-test
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.7.1
      command: ["sh", "-lc", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: local-peer
  namespace: openclaw
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.7.1
      command: ["sh", "-lc", "sleep 3600"]
YAML

kubectl -n gateway-test wait --for=condition=Ready pod/gateway-client --timeout=120s
kubectl -n peer-test wait --for=condition=Ready pod/peer-client --timeout=120s
kubectl -n openclaw wait --for=condition=Ready pod/local-peer --timeout=120s
```

Apply the reference NetworkPolicy:

```bash
kubectl apply -f k8s/networkpolicy-reference.yaml
kubectl -n openclaw get networkpolicy
```

Test ingress behavior:

```bash
PODIP=$(kubectl -n openclaw get pod -l app=openclaw -o jsonpath='{.items[0].status.podIP}')

kubectl -n gateway-test exec gateway-client -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PODIP:8080/healthz"

kubectl -n peer-test exec peer-client -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PODIP:8080/healthz || true"

kubectl -n openclaw exec local-peer -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PODIP:8080/healthz || true"
```

Expected:
- `gateway-client` succeeds
- `peer-client` fails
- `local-peer` fails

Test egress behavior:

```bash
PEERIP=$(kubectl -n peer-test get pod peer-client -o jsonpath='{.status.podIP}')

kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -I -s --max-time 10 https://api.github.com | head -1"

kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -k -sS --max-time 5 -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc || true"

kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PEERIP:80 || true"
```

Expected:
- public internet works
- Kubernetes API is blocked
- direct pod access is blocked

---

## 8. Validate Gateway API routing locally with Envoy Gateway

### 8.1 Install Envoy Gateway

```bash
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.5.4/install.yaml
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
```

Note:
- in our local validation, the install produced one CRD-related warning/error late in the apply, but the Gateway dataplane still came up and routing worked
- this is acceptable for local experimentation, not a production claim

### 8.2 Apply the Gateway API reference

```bash
kubectl apply -f k8s/gatewayapi-envoy-k3d-reference.yaml
kubectl get gatewayclass,gateway,httproute -A -o wide
kubectl -n openclaw describe gateway openclaw-gateway
kubectl -n openclaw describe httproute openclaw-route
```

### 8.3 Port-forward the Envoy dataplane service

Find the generated Envoy service:

```bash
kubectl -n envoy-gateway-system get svc | grep openclaw
```

Port-forward it locally:

```bash
kubectl -n envoy-gateway-system port-forward svc/envoy-openclaw-openclaw-gateway-1dc42a2f 18080:80
```

If the generated service name differs, substitute the actual name.

### 8.4 Verify routing

In another shell:

```bash
curl -i -s http://127.0.0.1:18080/healthz | head -20
curl -i -s http://127.0.0.1:18080/ | head -20
```

Expected:
- `200` from `/healthz`
- Control UI HTML from `/`

---

## 9. Validate Control UI password auth through Gateway API

For local browser testing, temporarily patch `allowedOrigins` to match the local forwarded URL.

Patch the persisted config:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "node -e 'const fs=require(\"fs\"); const p=\"/data/.openclaw/openclaw.json\"; let s=fs.readFileSync(p,\"utf8\"); s=s.replace(\"https://openclaw.example.com\",\"http://127.0.0.1:18080\"); fs.writeFileSync(p,s); console.log(s)'"
```

Restart OpenClaw:

```bash
kubectl -n openclaw rollout restart deploy/openclaw
kubectl -n openclaw rollout status deploy/openclaw --timeout=180s
```

Open the UI in a browser:

```text
http://127.0.0.1:18080/overview
```

Validated local behavior:
- UI loads
- password is required
- after entering the correct password, device pairing is still required
- after approving the device, the dashboard connects successfully

### Pair a pending device

List pending devices:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc 'node openclaw.mjs devices list'
```

Approve the request:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc 'node openclaw.mjs devices approve <requestId>'
```

Then reconnect in the browser.

---

## 10. Important production follow-up: trusted proxies

During Gateway API testing, OpenClaw may log warnings indicating proxy headers were received from an untrusted address unless `gateway.trustedProxies` is configured for that environment.

Implication:
- `gateway.trustedProxies` is **recommended** for proxied/Gateway deployments
- it is **not required** in this portable reference template because the correct value is deployment-specific
- if used, it should contain the smallest stable trusted proxy range for the actual dataplane/proxy path

This is a production tuning item, not a portable hardcoded baseline.

---

## 11. Cleanup

Delete the local cluster:

```bash
k3d cluster delete openclaw-test
```

---

## Production follow-through

For production use:

- use the Helm chart in `charts/openclaw/`
- use `charts/openclaw/README.md` as the primary operator-facing Kubernetes guide
- use `specs/k8s.md` for the security model, rationale, and validated findings

This `k8s/` directory remains focused on local validation and reference manifests only.

## Notes / limitations

- These artifacts are intentionally focused on validated local behavior, not final production hardening completeness.
- Production still needs:
  - real HTTPS/TLS
  - final public hostname
  - final `OPENCLAW_ALLOWED_ORIGIN`
  - final `gateway.trustedProxies`
  - final Gateway dataplane selectors in `NetworkPolicy`
  - backup implementation in a later phase

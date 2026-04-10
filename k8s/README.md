# OpenClaw on Kubernetes: local validation with Helm

This directory now exists only for Kubernetes validation documentation.

For the live hoth cluster values file used by Helm, see `k8s/values-hoth.yaml`.

The supported Kubernetes deployment path for this repo is:
- Helm chart: `charts/openclaw/`

Raw Kubernetes manifests are no longer the source of truth.

---

## What this validates

The local validation flow is intended to prove that the Helm chart correctly deploys OpenClaw with the intended hardened model:

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

Keep these controls separate:
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
- `helm`

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

## 2. Install the chart in k3d

Use the provided local values file:

```bash
helm upgrade --install openclaw charts/openclaw \
  --namespace openclaw \
  --create-namespace \
  -f charts/openclaw/values-k3d.example.yaml

kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
kubectl -n openclaw get pods,pvc,svc -o wide
```

What this gives you:
- namespace `openclaw`
- service account with `automountServiceAccountToken: false`
- chart-managed Secret with bootstrap password/origin values
- PVC mounted at `/data`
- init container that seeds `openclaw.json` only if missing
- upstream image deployment
- `ClusterIP` service
- chart-managed `NetworkPolicy`

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

## 6. Verify public internet egress and cluster blocking

Check public internet egress:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -I -s https://api.github.com | head -1"
```

Check Kubernetes API network reachability after chart-managed NetworkPolicy:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  "curl -k -sS --max-time 5 -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc || true"
```

Expected result:
- public internet works
- Kubernetes API returns `000` / connect failure

---

## 7. Validate NetworkPolicy behavior

The `values-k3d.example.yaml` file expects an allowed source namespace/pod:
- namespace: `gateway-test`
- label: `access=openclaw-gateway`

Create synthetic allowed and disallowed clients:

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
YAML

kubectl -n gateway-test wait --for=condition=Ready pod/gateway-client --timeout=120s
kubectl -n peer-test wait --for=condition=Ready pod/peer-client --timeout=120s
```

Test ingress behavior:

```bash
PODIP=$(kubectl -n openclaw get pod -l app=openclaw -o jsonpath='{.items[0].status.podIP}')

kubectl -n gateway-test exec gateway-client -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PODIP:8080/healthz"

kubectl -n peer-test exec peer-client -- sh -lc \
  "curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://$PODIP:8080/healthz || true"
```

Expected:
- `gateway-client` succeeds
- `peer-client` fails

Test egress behavior:

```bash
kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  'curl -I -s https://api.github.com | head -1'

kubectl -n openclaw exec deploy/openclaw -- sh -lc \
  'curl -k -sS --max-time 5 -o /dev/null -w "%{http_code}\n" https://kubernetes.default.svc || true'
```

Expected:
- public internet works
- Kubernetes API is blocked

---

## 8. Optional: validate Gateway API locally with Envoy Gateway

This is optional and outside the chart itself.
It is only for proving that OpenClaw works behind a Gateway API dataplane path.

### Install Envoy Gateway

```bash
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.5.4/install.yaml
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
```

### Create a simple local Gateway / Route

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openclaw-gateway
  namespace: openclaw
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openclaw-route
  namespace: openclaw
spec:
  parentRefs:
    - name: openclaw-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: openclaw
          port: 8080
YAML
```

Find the generated Envoy service and port-forward it:

```bash
kubectl -n envoy-gateway-system get svc | grep openclaw
kubectl -n envoy-gateway-system port-forward svc/<generated-service-name> 18080:80
```

In another shell:

```bash
curl -i -s http://127.0.0.1:18080/healthz | head -20
curl -i -s http://127.0.0.1:18080/ | head -20
```

You should see OpenClaw responses through the Gateway dataplane.

### Optional UI auth check

For local browser testing, update the persisted allowed origin to `http://127.0.0.1:18080`, restart OpenClaw, and then open:

```text
http://127.0.0.1:18080/overview
```

This proves password auth and pairing behavior through the proxied path.

---

## Production follow-through

For production use:
- use the Helm chart in `charts/openclaw/`
- use `charts/openclaw/README.md` as the primary operator-facing Kubernetes guide
- use `specs/k8s.md` for the security model, rationale, and validated findings

This directory is intentionally limited to local validation guidance.

---

## Cleanup

Delete the local cluster:

```bash
k3d cluster delete openclaw-test
```

---

## Notes / limitations

- These validation steps are intentionally focused on local Helm-backed behavior, not final production hardening completeness.
- Production still needs:
  - real HTTPS/TLS
  - final public hostname
  - final `OPENCLAW_ALLOWED_ORIGIN`
  - optional `gateway.trustedProxies`
  - final Gateway dataplane selectors in `networkPolicy.ingressFrom`
  - backup implementation in a later phase

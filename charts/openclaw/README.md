# OpenClaw Helm chart

Portable, hardened OpenClaw chart derived from the validated Kubernetes deployment model.

## Intended GitOps shape

- one Helm release = one OpenClaw instance
- one namespace per OpenClaw instance
- one Secret per OpenClaw instance
- one PVC per OpenClaw instance
- one hostname / HTTPRoute per OpenClaw instance

This is the intended packaging model for running multiple isolated OpenClaw instances, for example one per employee.

Recommended production pattern:

- manage namespaces separately in GitOps
- use `secret.existingSecret` with Sealed Secrets / External Secrets / SOPS / Vault-style secret delivery
- supply cluster-specific Gateway dataplane selectors and proxy trust via values files, not chart defaults

## Security model

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

For the chart:
- `networkPolicy` is enabled by default
- `trustedProxies` is optional and environment-specific

## What the chart deploys

- singleton `Deployment`
- upstream image only
- PVC mounted at `/data`
- seed-only init container
- non-root runtime container
- dedicated `ServiceAccount` without token mount
- `ClusterIP` `Service`
- optional `HTTPRoute`
- namespace-scoped `NetworkPolicy`
- optional backup `CronJob` using `openclaw backup create --verify` + `restic`

## Required values

### Secret handling

If creating the Secret from the chart:

- `secret.create=true`
- `secret.gatewayPassword`
- `secret.allowedOrigin`

If using an existing Secret:

- `secret.create=false`
- `secret.existingSecret=<name>`

### Gateway API exposure

If exposing through Gateway API:

- `httpRoute.enabled=true`
- `httpRoute.hostname=<final hostname>`
- `httpRoute.parentRefs=[...]`

### NetworkPolicy

If `networkPolicy.enabled=true`, set the actual Gateway dataplane peers that may reach OpenClaw:

- `networkPolicy.ingressFrom=[...]`

This is cluster-specific by design.

## Backups and restore

### Scheduled backups (optional)

This chart can run a scheduled backup `CronJob`.

Flow per run:

1. init container (`ghcr.io/openclaw/openclaw`) runs:
   - `openclaw backup create --output /backup/openclaw-backup.tar.gz --verify`
2. main container (`restic/restic`) stores the archive in a restic repository
3. retention is applied via `restic forget --prune`

Minimal values example:

```yaml
backup:
  enabled: true
  schedule: "5 * * * *"
  restic:
    createSecret: true
    repository: s3:https://s3.example.com/openclaw
    password: change-me
    extraEnv:
      AWS_ACCESS_KEY_ID: "..."
      AWS_SECRET_ACCESS_KEY: "..."
  retention:
    keepHourly: 12
    keepDaily: 7
```

If you already manage credentials externally, set `backup.restic.existingSecret` and keep `createSecret: false`.

### Restore Job template

A restore `Job` can be created by setting:

```yaml
restore:
  enabled: true
  runId: restore-20260411-1
  snapshot: latest
```

The restore job does:

1. `restic restore <snapshot>`
2. locate `openclaw-backup.tar.gz`
3. `openclaw backup verify /restore/openclaw-backup.tar.gz`
4. apply payload back into `/data` (and optionally preserve current `/data/.openclaw` and `/data/workspace`)

### Full restore playbook

1. Scale down OpenClaw:

```bash
kubectl -n openclaw scale deploy/openclaw --replicas=0
```

2. Run restore helper script (recommended):

```bash
KUBECONFIG=~/.kube/hoth \
OPENCLAW_NAMESPACE=openclaw \
OPENCLAW_RESTORE_SNAPSHOT=latest \
./scripts/openclaw-restore-from-restic.sh
```

This script:
- scales deployment down
- enables restore job via Helm values (`restore.enabled=true`)
- waits for job completion and prints logs
- disables restore mode (`restore.enabled=false`)
- scales deployment back up

3. Validate service health:

```bash
kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
kubectl -n openclaw get pods
```

### Manual restore commands (without script)

```bash
helm upgrade openclaw charts/openclaw \
  --namespace openclaw \
  --reuse-values \
  --set restore.enabled=true \
  --set restore.runId=restore-20260411-1 \
  --set restore.snapshot=latest

kubectl -n openclaw wait --for=condition=complete --timeout=900s job/openclaw-restore-restore-20260411-1

helm upgrade openclaw charts/openclaw \
  --namespace openclaw \
  --reuse-values \
  --set restore.enabled=false
```

## Values files in this repo

- `values.yaml` — portable defaults
- `values-istio-gateway.example.yaml` — generic shared-Istio-Gateway / Gateway API example
- `values-k3d.example.yaml` — local `k3d` example

## Example installs

### Generic existing-secret install

```bash
helm upgrade --install openclaw charts/openclaw \
  --namespace openclaw \
  -f my-values.yaml
```

### Shared Istio Gateway example

```bash
helm upgrade --install openclaw charts/openclaw \
  --namespace openclaw \
  -f charts/openclaw/values-istio-gateway.example.yaml
```

### k3d example

```bash
helm upgrade --install openclaw charts/openclaw \
  --namespace openclaw \
  -f charts/openclaw/values-k3d.example.yaml
```

## Multi-instance example

Example GitOps layout:

- `clusters/prod/openclaw-alice-values.yaml`
- `clusters/prod/openclaw-bob-values.yaml`

Each values file should define at least:

- namespace / release target
- secret source
- hostname
- Gateway parent refs
- Gateway dataplane selectors for `networkPolicy.ingressFrom`
- optional `trustedProxies`

## Validation status

Validated during this work:

- `helm lint` with `values-istio-gateway.example.yaml`
- `helm lint` with `values-k3d.example.yaml`
- `helm template` renders valid YAML
- server-side dry-run against a real shared-Istio-Gateway cluster using the Istio Gateway example values
- live install on `k3d` with `values-k3d.example.yaml`
- CI workflow added in `.github/workflows/chart-validate.yml` to repeat lint/render/k3d smoke validation

Validated behavior on `k3d` chart install:

- pod starts successfully
- PVC binds and `/data` is writable by uid/gid 1000
- no service account token is mounted
- gateway-designated source can reach TCP/8080
- peer namespace pod cannot reach OpenClaw directly
- public internet egress works
- `kubernetes.default.svc` is blocked by `NetworkPolicy`

## Operator notes

### Secret updates

If you use an existing Secret, update it out-of-band and restart the Deployment to pick up new env vars.

A helper script is included:

```bash
OPENCLAW_NAMESPACE=openclaw \
OPENCLAW_ALLOWED_ORIGIN=https://openclaw.example.com \
OPENCLAW_GATEWAY_PASSWORD='REPLACE_ME' \
OPENAI_API_KEY='sk-...' \
./scripts/openclaw-set-secret.sh
```

Then restart:

```bash
kubectl -n openclaw rollout restart deploy/openclaw
kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
```

### Device pairing

If the Control UI shows `pairing required`, approve the device from the running Deployment:

```bash
./scripts/openclaw-approve-device.sh list
./scripts/openclaw-approve-device.sh approve <requestId>
```

### Password rotation

Because config is seed-only, changing the Secret does not rewrite `/data/.openclaw/openclaw.json` after first boot.
If you rotate the gateway password, update the persisted config and then restart OpenClaw.

### Recovering from bad persisted config

The normal recovery path is to edit `/data/.openclaw/openclaw.json` in place and restart the Deployment.
Only delete the PVC if you intentionally want a full reset of persisted OpenClaw state.

## Important notes

- The init container seeds config only if `/data/.openclaw/openclaw.json` is missing.
- Later Secret changes do not rewrite persisted config values already stored in the PVC.
- Do not hardcode a cluster-specific Gateway dataplane selector into portable defaults.
- Set `trustedProxies` only when you know the proxy IP/CIDR OpenClaw should trust.
- The chart schema enforces the main required value combinations.

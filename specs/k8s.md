# Kubernetes Deployment Handoff: OpenClaw

## Purpose

This document is a handoff specification for deploying OpenClaw on Kubernetes **without Railway**.

## Executive summary

We want to deploy **upstream OpenClaw** on Kubernetes using:
- the **upstream OpenClaw container image**
- a **persistent volume mounted at `/data`**
- an **init container that seeds config only if missing**
- a **single replica**
- a **public HTTPS Kubernetes Gateway API entrypoint**
- a **password-protected web UI / gateway**
- strong **namespace / RBAC / network isolation**

The deployment must be isolated such that the OpenClaw pod:
- has **no Kubernetes API privileges**
- has **no implicit access to in-cluster services**
- has **no access to other namespaces/pods/services unless explicitly allowed**
- can only receive inbound traffic via the configured Gateway API dataplane/controller path
- can only egress to the public internet and other explicitly permitted destinations

Config ownership model:
- On first startup, Kubernetes bootstraps `openclaw.json`
- After that, **OpenClaw UI owns the config**
- The init container must **only create config if missing**
- The init container must **not overwrite an existing config**

---

## Scope

### In scope

This handoff covers:
- local and production Kubernetes deployment architecture
- storage strategy
- bootstrap configuration strategy
- Gateway API and TLS strategy
- namespace and service account isolation
- RBAC minimization
- network isolation with default deny posture
- local testing on `k3d`
- validation criteria

### Out of scope

This handoff does **not** define:
- Helm chart packaging details unless the implementer chooses Helm
- GitOps tooling specifics (Argo CD / Flux / etc.)
- cloud-specific LB / DNS setup
- backup implementation details beyond requirements
- backup sidecar / CronJob / snapshot implementation design
- SSO or external IdP integration
- multi-replica / HA architecture
- multi-tenant or adversarial-user sharing of one OpenClaw deployment

### Deferred / do later

Backup implementation is explicitly deferred for now.

We acknowledge that `/data` is a critical state volume and will eventually require:
- consistent backup strategy
- daily backup scheduling
- retention policy (target: keep last 3 backups)
- documented restore workflow
- a concrete Kubernetes-native backup design

The current intended future direction is:
- primary persistent storage backed by the in-cluster Ceph storage provider
- storage-native snapshot capability where available (for example Ceph CSI `VolumeSnapshot`)
- a Kubernetes `CronJob`-driven backup workflow running daily
- retention of the last 3 backups
- documented restore from backup/snapshot

However, backup mechanism selection and implementation are **out of scope for the current phase** and should be handled in a later follow-up spec.

---

## Trust model

### Intended security model

This deployment is for a **trusted single-user / single-operator** OpenClaw setup.

Implications:
- We are **not** trying to support hostile multi-tenant access inside one OpenClaw instance
- We are **not** trying to use one OpenClaw gateway as a security boundary between mutually untrusted users
- The primary security concern is securing the **public web endpoint** and preventing the pod from gaining unintended **cluster access** or lateral movement capability

### Security priorities

In priority order:
1. Secure the public web surface
2. Require gateway/UI authentication
3. Restrict browser origin access correctly
4. Prevent cluster API access
5. Prevent in-cluster lateral movement
6. Restrict egress to explicit destinations only
7. Keep pod filesystem/state isolated to its own PVC

### Non-goal security assumptions

We are **not** relying on OpenClaw itself to provide Kubernetes or network isolation.
That isolation must be provided by Kubernetes and platform controls.

---

## Architecture decision

### Container image

Use the **upstream OpenClaw image**, not this repository's wrapper image.

Expected image source:
- `ghcr.io/openclaw/openclaw:<version>`

Current expected version at time of writing:
- `2026.4.2`

Rationale:
- avoid maintaining a custom wrapper image for Kubernetes
- keep runtime close to upstream
- move environment-specific bootstrap logic into Kubernetes init container(s)

### Config bootstrap strategy

Use an **init container** that:
- ensures `/data/.openclaw` exists
- ensures `/data/workspace` exists
- writes `/data/.openclaw/openclaw.json` **only if the file does not already exist**

This is a hard requirement.

#### Required config ownership behavior

- If `openclaw.json` does not exist: create it
- If `openclaw.json` already exists: do nothing
- OpenClaw UI / operator edits after first boot must persist across restarts and upgrades

### Replica count

Run **exactly one replica**.

This is a hard requirement.

Rationale:
- OpenClaw state is persisted on disk under `/data`
- sessions/config/credentials are local-state oriented
- we should assume singleton semantics unless upstream documents otherwise

---

## Runtime assumptions that must be verified

The implementer must verify these assumptions against the upstream image.

Partial findings already confirmed locally against `ghcr.io/openclaw/openclaw:2026.4.2`:
- the image default user is `node` (`uid=1000`, `gid=1000`)
- default image entrypoint/cmd is `docker-entrypoint.sh` + `node openclaw.mjs gateway --allow-unconfigured`
- the app files live under `/app`
- the image can be launched directly, but writable permissions on `/data` must be correct for the `node` user

Operational implication:
- the Kubernetes deployment should assume a non-root runtime by default
- the PVC permissions / `fsGroup` / security context must be validated so the container can create and write `/data/.openclaw`

### Confirmed local `k3d` findings

The following behaviors were validated locally on `k3d`:
- upstream image runs successfully in Kubernetes with explicit `/data`-based env vars and command override
- seed-only init-container behavior works as intended
- persisted `openclaw.json` is **not** overwritten on restart once it exists
- `automountServiceAccountToken: false` works and no service account token is mounted into the app pod
- public internet egress works when allowed
- Kubernetes API network reachability exists by default and must be blocked explicitly with network policy
- inbound isolation works with `NetworkPolicy` when configured to allow only the designated Gateway-path source

Concrete implementation finding:
- a permissions fixup is required for `/data` ownership/writability for uid/gid `1000`; otherwise the upstream image can fail with `EACCES` while creating `/data/.openclaw`

### Assumption A: startup command

We currently assume the upstream image can be started with:

```bash
node openclaw.mjs gateway --allow-unconfigured --bind lan --port 8080
```

This is consistent with the upstream image default command shape and should still be verified in Kubernetes.

### Assumption B: config path

We currently assume OpenClaw reads config from:

```text
/data/.openclaw/openclaw.json
```

when:
- `HOME=/data`, and/or
- OpenClaw state is expected beneath `/data`

This must be verified against upstream behavior.

### Assumption C: persistent directories

We currently assume these paths are valid and required:
- `/data/.openclaw`
- `/data/workspace`

This must be verified.

### Assumption D: port and bind mode

We currently assume:
- OpenClaw should listen on port `8080`
- bind mode `lan` is appropriate inside Kubernetes because external access is mediated by Service + Kubernetes Gateway API

This must be verified.

### Assumption E: web auth/origin settings

We currently assume the following config is valid and sufficient to protect the public UI:

```json5
{
  gateway: {
    port: 8080,
    auth: {
      mode: "password",
      password: "<secret>",
    },
    controlUi: {
      allowedOrigins: ["https://openclaw.example.com"],
    },
  },
}
```

This must be validated against actual runtime behavior.

---

## Required bootstrap config

The init container must seed an `openclaw.json` equivalent in intent to:

```json5
{
  agents: {
    defaults: {
      model: { primary: "openai/gpt-5.4-mini" },
    },
  },
  gateway: {
    port: 8080,
    auth: {
      mode: "password",
      password: "${OPENCLAW_GATEWAY_PASSWORD}",
    },
    controlUi: {
      allowedOrigins: ["${OPENCLAW_ALLOWED_ORIGIN}"],
    },
  },
}
```

### Hard requirements

The bootstrap config must:
- require password auth for the gateway/UI
- specify explicit allowed browser origin(s)
- avoid insecure origin fallback behavior
- avoid dangerous compatibility flags unless explicitly approved

### Recommended optional setting

For deployments behind Gateway API / reverse proxies / service-mesh gateways, `gateway.trustedProxies` is recommended but not required in the portable baseline template.

Reason:
- the correct value is environment-specific
- some deployments may work acceptably without it
- when set, it should contain the smallest stable trusted proxy range for that environment

### Explicitly forbidden settings

The bootstrap config must **not** enable:
- `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true`
- `gateway.controlUi.dangerouslyDisableDeviceAuth=true`
- any equivalent insecure fallback unless there is written approval and a documented exception

---

## Required Kubernetes resources

The implementation must include, at minimum:

1. `Namespace`
2. `ServiceAccount`
3. `Secret` for credentials
4. `PersistentVolumeClaim`
5. `Deployment`
6. `Service` (ClusterIP)
7. Kubernetes Gateway API resources (`Gateway`, `HTTPRoute`, and related policy objects as needed)
8. `NetworkPolicy` resources implementing default deny + explicit allow rules

Optional:
- `ConfigMap` for non-secret bootstrap template content
- `PodDisruptionBudget`
- `ResourceQuota`
- `LimitRange`
- `HorizontalPodAutoscaler` is **not** expected and not recommended unless singleton concerns are addressed

---

## Namespace isolation requirements

Deploy into a **dedicated namespace**, e.g. `openclaw`.

Hard requirements:
- no unrelated workloads in this namespace
- all network policies scoped to this namespace
- namespace should be treated as an isolation boundary for this app

Recommended labels:

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

If the upstream image cannot satisfy `restricted`, document the exact incompatibility and the minimum required relaxation.

---

## Service account / RBAC requirements

### Hard requirements

- Use a dedicated `ServiceAccount`
- Set `automountServiceAccountToken: false`
- Do **not** bind any `Role`, `ClusterRole`, `RoleBinding`, or `ClusterRoleBinding` unless explicitly justified and approved

### Security intent

The OpenClaw pod must have:
- no Kubernetes API token mounted
- no Kubernetes API permissions
- no ability to read Secrets, ConfigMaps, Pods, Services, or any other cluster resources

### Validation requirement

The implementation must include a test that verifies:
- `/var/run/secrets/kubernetes.io/serviceaccount` is absent in the OpenClaw container, or otherwise no token is present

---

## Storage requirements

### Persistent volume

A PVC must be mounted at:
- `/data`

### Required persistence semantics

The volume must preserve:
- OpenClaw config
- sessions
- credentials
- state
- workspace content

### Required access mode

Expected minimum:
- `ReadWriteOnce`

### Required capacity

Initial recommendation:
- at least `10Gi`

Final sizing may be adjusted based on expected session volume and artifacts.

### Storage isolation requirements

The pod must not mount:
- hostPath volumes
- docker socket
- arbitrary shared volumes from other apps

Only mount:
- the dedicated PVC for `/data`
- explicitly required Kubernetes Secrets / ConfigMaps

---

## Deployment requirements

### Pod count

- replicas: `1`

### Init container behavior

The init container must:
1. create `/data/.openclaw` if missing
2. create `/data/workspace` if missing
3. create `/data/.openclaw/openclaw.json` **only if missing**
4. leave existing `openclaw.json` untouched

### Required environment inputs

At minimum:
- `OPENCLAW_GATEWAY_PASSWORD`
- `OPENCLAW_ALLOWED_ORIGIN`

Optional / expected depending on provider use:
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- etc.

### Startup behavior

The main OpenClaw container must start the upstream app with explicit command/args if required.

Expected target behavior:
- listens on container port `8080`
- is reachable by Kubernetes Service
- is reachable publicly only through Kubernetes Gateway API exposure

### Health checks

If supported, configure probes against:
- `/healthz`

Need to verify exact readiness/liveness semantics.

---

## Service requirements

Use a `ClusterIP` service.

Hard requirements:
- do not expose OpenClaw via `NodePort`
- do not expose the pod directly unless there is a documented exception

The Service exists only as the backend target for Kubernetes Gateway API routing and in-cluster traffic from explicitly allowed components.

---

## Gateway API requirements

### Exposure model

OpenClaw must be exposed publicly through Kubernetes Gateway API over HTTPS.

### Hard requirements

- TLS termination required
- HTTP should redirect to HTTPS
- the public hostname must match `OPENCLAW_ALLOWED_ORIGIN`
- Gateway API backend routing must point to the OpenClaw `ClusterIP` service

### Security assumptions

OpenClaw public surface is acceptable only if all of the following are true:
- gateway auth is enabled
- allowed origins are explicitly configured
- Gateway API is the only allowed inbound path
- direct pod/node exposure is not enabled

Recommended for proxied deployments:
- configure `gateway.trustedProxies` if the chosen dataplane/proxy path requires OpenClaw to trust forwarded headers explicitly

### Optional defense in depth

Depending on operational preference, any of the following may be added:
- IP allowlist at the Gateway/API policy layer
- external auth at the Gateway/API policy layer
- WAF protections

These are optional and do not replace OpenClaw gateway auth.

---

## Network isolation requirements

This is a core part of the handoff.

### Goal

The OpenClaw pod must be isolated such that it cannot:
- initiate arbitrary connections to in-cluster services
- talk to Kubernetes API
- laterally move to other pods/services/namespaces
- receive inbound connections from arbitrary in-cluster clients

At the same time, OpenClaw does require controlled outbound internet access because it may need to:
- call model inference APIs
- call provider authentication endpoints
- access enabled channel/provider APIs
- use approved internet-facing tools/features

Security intent:
- allow required public internet egress
- block internal/private destination access by default

Working model:

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

### Default deny posture

The namespace must include:
- default deny ingress policy
- default deny egress policy

This is a hard requirement.

### Allowed ingress

Only allow ingress to OpenClaw pods from the configured Kubernetes Gateway API dataplane/controller path, on the application port.

This rule should be as narrow as practical:
- prefer namespace + pod selector constraints if feasible
- allow only the necessary port

### Allowed egress

Allow only what is necessary.

Minimum expected egress allowances:
1. DNS
2. outbound HTTPS to the public internet required for operation

This means OpenClaw is allowed to reach the public internet for legitimate application behavior, but that does **not** imply access to internal/private destinations.

Portable baseline expectation:
- allow outbound TCP/80 and TCP/443 to public internet
- explicitly exclude internal/private destination ranges from that internet egress rule

For the current phase, we do **not** require host-by-host internet allowlisting. The working model is:
- allow public internet access
- block internal/private destination access

Implementation may still use more restrictive public-internet controls later if desired, but that is not required for initial delivery.

### Explicit forbidden egress targets

The implementation must prevent access to, unless explicitly approved:
- `kubernetes.default.svc`
- Kubernetes API service CIDR/IP
- cluster services
- pod CIDR(s)
- service CIDR(s)
- pod network
- node private subnets
- private RFC1918 networks
- cloud metadata endpoints (for example `169.254.169.254`)

This is the intended model:
- allowed world: required public internet destinations
- forbidden world: internal/private destinations

Keep proxy trust separate from network isolation:
- `NetworkPolicy` = who may connect and where OpenClaw may egress
- `gateway.trustedProxies` = whose forwarded headers OpenClaw may believe

For the portable template:
- `NetworkPolicy` is required
- `trustedProxies` is recommended, but environment-specific

---

## Pod / container security requirements

### Hard requirements

At minimum:
- `allowPrivilegeEscalation: false`
- drop all Linux capabilities unless a capability is explicitly required
- use `seccompProfile: RuntimeDefault`

### Strongly preferred

If compatible with upstream image behavior:
- `runAsNonRoot: true`
- explicit `runAsUser` / `runAsGroup`
- `fsGroup` if needed for PVC permissions
- `readOnlyRootFilesystem: true`

### If not possible

If any of the above cannot be applied, the implementer must document:
- which setting failed
- why it failed
- the minimum secure alternative

---

## Secrets handling requirements

### Hard requirements

Use Kubernetes `Secret` objects for:
- gateway password
- provider API keys
- other sensitive credentials

Do not hardcode secrets into:
- manifests
- container image
- ConfigMaps
- Git-tracked files

### Required secret inputs

At minimum:
- `OPENCLAW_GATEWAY_PASSWORD`

Likely others depending on use:
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- etc.

### Allowed origin handling

`OPENCLAW_ALLOWED_ORIGIN` is not necessarily secret, but it may still be supplied by env or ConfigMap.

---

## Operational requirements

### Updates

Updates should generally mean updating the OpenClaw image tag and rolling the Deployment.

Because config is seed-only:
- config changes made in UI persist across upgrades
- changing bootstrap env values later does **not** automatically rewrite persisted config

This must be explicitly documented in the runbook.

### Backups

The `/data` volume must be treated as stateful and important.

Backup implementation is deferred to a later phase and is not required for the initial Kubernetes delivery.

For now, the runbook should explicitly note that backup/restore design remains outstanding and will later need to cover at least:
- `openclaw.json`
- credentials
- sessions
- state directories
- installed tools and other runtime state stored on `/data`

### Disaster recovery requirement

For the current phase, the implementer should document only the operational limitation that backup/restore is not yet implemented.

A later phase should provide documented answers for:
- how to restore OpenClaw from PVC backup
- how to rotate gateway password if needed
- how to recover if bootstrap config is wrong but volume is already initialized

---

## Required local validation environment

We have local `k3d` available and should use it for implementation validation.

### Hard requirement

The implementation must be validated locally on `k3d` before it is considered ready.

### Important caveat

We must first verify that the local cluster/CNI actually enforces `NetworkPolicy`. Otherwise network tests may give false confidence.

---

## Validation plan

The implementer must validate all of the following.

### Phase 1: Verify network policy enforcement in k3d

Before testing OpenClaw itself, prove that the local cluster enforces network policies.

Required tests:
- deploy a simple server pod in one namespace
- deploy a simple client pod in another namespace
- confirm connectivity without policy
- apply default deny policy
- confirm connectivity fails
- apply explicit allow rule
- confirm only allowed traffic succeeds

If this cannot be demonstrated, the local cluster is not sufficient for network isolation validation.

### Phase 2: Verify basic OpenClaw startup

Required tests:
- namespace created
- PVC bound
- init container completes
- main pod starts
- Service routes traffic
- `/healthz` responds if expected

### Phase 3: Verify bootstrap config behavior

Required tests:
1. fresh deploy with empty PVC
2. confirm init container creates `/data/.openclaw/openclaw.json`
3. confirm config contains password auth and allowed origin
4. modify config through UI or manually in the volume
5. restart / redeploy
6. confirm init container does **not** overwrite the existing file

This is a hard acceptance criterion.

### Phase 4: Verify UI auth/origin behavior

Required tests:
- access UI through intended HTTPS hostname
- confirm password is required
- confirm valid password works
- confirm invalid password fails
- verify behavior when origin/host does not match allowed origin

### Phase 5: Verify no Kubernetes credentials

Required tests:
- inspect pod/container filesystem
- verify service account token is not mounted

### Phase 6: Verify no Kubernetes API reachability or permissions

Required tests from inside the OpenClaw pod:
- attempt connection to `kubernetes.default.svc`
- expected result: blocked by network policy or otherwise inaccessible
- if reachable, confirm no credentials and no RBAC privileges

The preferred outcome is **network blocked**, not merely unauthorized.

### Phase 7: Verify Gateway API ingress isolation

Required tests:
- another pod in another namespace attempts direct access to OpenClaw pod/service
- expected result: denied
- Gateway API dataplane/controller path to OpenClaw remains functional

### Phase 8: Verify egress restrictions

Required tests from inside the OpenClaw pod:
- DNS works
- allowed external HTTPS destinations work
- disallowed in-cluster destinations fail
- metadata endpoint access fails
- arbitrary internal/private CIDR access fails

### Phase 9: Verify persistence across pod replacement

Required tests:
- restart deployment
- delete pod and allow recreate
- verify sessions/config persist
- verify config remains operator-owned

---

## Acceptance criteria

The implementation is acceptable only if all of the following are true:

1. Uses upstream OpenClaw image
2. Uses dedicated namespace
3. Uses dedicated ServiceAccount with `automountServiceAccountToken: false`
4. Grants no RBAC permissions unless explicitly approved
5. Uses PVC mounted at `/data`
6. Uses init container that seeds config **only if missing**
7. Runs exactly one replica
8. Exposes app only through HTTPS Gateway API
9. Requires password auth for UI/gateway
10. Uses explicit allowed origin configuration
11. Does not enable insecure host-header/origin fallback
12. Applies default deny ingress and default deny egress
13. Allows ingress only from the Gateway API dataplane/controller path
14. Prevents cluster/API lateral access unless explicitly allowed
15. Provides a tested egress policy aligned to operational needs
16. Is validated locally on `k3d`
17. Has documented runbook notes for updates, backups, and recovery

---

## Open questions for the implementer to resolve

The following questions must be answered during implementation:

1. What exact command/args does the upstream image require in Kubernetes?
2. Does the upstream image run correctly as non-root?
3. What is the minimum working pod security context?
4. What exact config path(s) does upstream read in this setup?
5. What is the exact readiness/liveness probe behavior?
6. Which Kubernetes Gateway API implementation/dataplane will be used locally and in production?
7. Which network-policy-capable implementation is enforcing network isolation in the target environment?
8. What are the actual cluster pod CIDR and service CIDR values that must be treated as forbidden destinations?
9. What backup mechanism will protect the `/data` PVC?
10. What is the operator runbook for rotating gateway password after initial bootstrap if config is UI-owned?

---

## Suggested implementation order

1. Prove `k3d` network policy enforcement works
2. Stand up namespace + SA + PVC + Deployment with upstream image
3. Implement seed-only init container
4. Add Service + Gateway API resources
5. Validate password auth and origin behavior
6. Add default deny network policies
7. Add explicit inbound allow from Gateway API dataplane/controller path
8. Add explicit egress allow for DNS + public internet while blocking forbidden internal/private destinations
9. Tighten pod security settings
10. Document operational runbook and known tradeoffs

---

## Known tradeoffs

### Seed-only config vs declarative reconciliation

We are explicitly choosing:
- seed config once
- then let OpenClaw UI own it

Tradeoff:
- easier operator UX
- less declarative config management
- bootstrap env changes later do not automatically reconcile persisted config

This is intentional.

### Single replica

We are explicitly choosing singleton deployment for safety and correctness.

Tradeoff:
- simpler state semantics
- no HA / no horizontal scaling

This is intentional.

### Public Gateway API exposure with app auth

We are explicitly allowing public network reachability through Kubernetes Gateway API, but only if:
- HTTPS is used
- gateway password auth is enabled
- origin restrictions are configured
- network isolation prevents cluster-side abuse

This is intentional.

---

## Deliverables expected from DevOps

The DevOps implementation should produce:

1. Kubernetes manifests or Helm chart
2. A short runbook for deploy/update/rollback/recovery
3. A local `k3d` validation procedure
4. Evidence that network policies are enforced and effective
5. Evidence that OpenClaw cannot access cluster resources by default
6. Evidence that config is seeded only once and then preserved
7. Evidence that UI password protection works through Gateway API exposure

---

## Reference implementation artifacts in this repo

The following reference files are included in this repository:

- `k8s/reference-k3d.yaml`
  - validated base deployment on local `k3d`
  - includes Namespace, ServiceAccount, Secret, PVC, Deployment, and Service
  - uses the upstream OpenClaw image
  - uses the seed-only init-container model
  - includes the `/data` ownership fixup required for the non-root `node` user

- `k8s/networkpolicy-reference.yaml`
  - reference NetworkPolicy set for the intended isolation model
  - validated locally with a synthetic allowed-source namespace/pod
  - must be adapted so the ingress allow rule matches the actual Kubernetes Gateway API dataplane/controller implementation in the target environment

These files are intended as a working reference baseline, not as the final production packaging.

---

## Appendix: validated local `k3d` findings

The following was validated locally during implementation:

### A. Upstream image runtime

For `ghcr.io/openclaw/openclaw:2026.4.2`:
- default runtime user is `node` (`uid=1000`, `gid=1000`)
- default command shape is compatible with `node openclaw.mjs gateway --allow-unconfigured`
- app files are under `/app`

### B. Kubernetes runtime model

Validated working runtime inputs:
- `HOME=/data`
- `OPENCLAW_STATE_DIR=/data/.openclaw`
- `OPENCLAW_WORKSPACE_DIR=/data/workspace`
- `OPENCLAW_GATEWAY_PORT=8080`
- command override: `node openclaw.mjs gateway --allow-unconfigured --bind lan --port 8080`

### C. PVC permissions

Confirmed requirement:
- `/data` must be writable by uid/gid `1000`
- without ownership/permissions fixup, the app can fail with `EACCES` when creating `/data/.openclaw`

Validated working approach:
- init container creates `/data/.openclaw` and `/data/workspace`
- init container performs `chown -R 1000:1000 /data`
- pod security context includes `fsGroup: 1000`

### D. Seed-only config ownership

Validated behavior:
- if `/data/.openclaw/openclaw.json` is missing, init container creates it
- if the file already exists, init container does not overwrite it
- persisted config changes survive deployment restart

### E. Service account isolation

Validated behavior:
- `automountServiceAccountToken: false` prevents a Kubernetes service account token from being mounted into the app pod

### F. Network behavior before policy

Validated behavior before applying NetworkPolicy:
- pod had public internet access
- pod could also reach `kubernetes.default.svc` at the network layer
- lack of service account token prevented authenticated API use, but the network path still existed

Interpretation:
- RBAC/token suppression alone is insufficient
- explicit network isolation is required

### G. Network behavior with reference policy

Validated behavior after applying reference-style NetworkPolicy:
- allowed source pod could reach OpenClaw on port `8080`
- disallowed peer pod could not reach OpenClaw
- same-namespace peer pod could not reach OpenClaw unless explicitly allowed
- OpenClaw retained public internet HTTPS access
- OpenClaw could no longer reach `kubernetes.default.svc`
- OpenClaw could no longer reach a peer pod directly

This validated the intended model:
- allowed world: public internet
- forbidden world: internal/private destinations

### H. Gateway API validation status

Additional local validation was performed with Envoy Gateway on `k3d`:
- a `GatewayClass`, `Gateway`, and `HTTPRoute` successfully routed traffic to the OpenClaw `Service`
- the Control UI was reachable through the Gateway API dataplane
- password-based authentication worked through that path
- device pairing also worked through that path after manual approval
- `gateway.trustedProxies` was identified as an environment-specific tuning parameter, not a portable hardcoded template value

Additional operational finding:
- when accessed through the Gateway API dataplane/proxy path, OpenClaw may log warnings about proxy headers coming from an untrusted address unless `gateway.trustedProxies` is configured for that environment
- configuring `gateway.trustedProxies` is therefore **recommended** for proxied/Gateway deployments, but is not treated as a hard baseline requirement for this template because the correct value is deployment-specific

What is still **not** fully validated end-to-end in this repo:
- final production TLS wiring
- final production `allowedOrigins` value on the real public hostname
- optional `trustedProxies` settings for the chosen Gateway API dataplane

Those still need to be validated in the target environment using the actual Gateway API implementation.

---

## Final directive

When in doubt, prefer the more isolated option.

The default posture for this deployment must be:
- no cluster privileges
- no lateral network access
- no direct inbound except the Gateway API dataplane/controller path
- no config overwrite once initialized
- no insecure compatibility flags

Any deviation from that baseline must be documented explicitly, justified, and approved.

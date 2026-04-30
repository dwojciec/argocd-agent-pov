# Argo CD Agent PoV — Principal + managed-cluster (managed) + autonomous-cluster (autonomous)

**Prefer French?** See the condensed guide in [README-french.md](README-french.md).

This repository provides manifests and scripts to validate **OpenShift GitOps / Argo CD Agent** across three separate OpenShift clusters.

**Detailed walkthrough (tasks T01–T60)** : [`step-by-step.md`](step-by-step.md) · *French:* [`Etape-par-etape.md`](Etape-par-etape.md).

**Non-`cluster-admin` users (e.g. `user1`) — creating apps on the `managed-cluster` spoke in managed mode** : roles, `AppProject`, Argo CD / Kubernetes RBAC : [`docs/developer-user1.md`](docs/developer-user1.md) · *French:* [`docs/utilisateur-developpeur-user1.md`](docs/utilisateur-developpeur-user1.md).

| Cluster | Role | Agent mode |
|---------|------|------------|
| **principal** | Hub: Argo CD UI + **Principal** component | — |
| **managed-cluster** | Spoke: **managed agent** | The hub is the source of truth for `Application` resources |
| **autonomous-cluster** | Spoke: **autonomous agent** | `Application` resources are defined on the spoke and surfaced to the hub |

Useful references:

- [Using the Argo CD Agent with OpenShift GitOps (Red Hat)](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops)
- [Ep.15 OpenShift GitOps — Argo CD Agent (stderr.at)](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)
- [TLS & cert-manager (argocd-agent.readthedocs.io)](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/)

**Important**: this is a **non-production PoV**. Adjust operator channels, service names (resource-proxy, principal), and `NetworkPolicy` labels for your OpenShift GitOps version.

---

## Repository layout

```
argocd-agent-multicluster-pov/
├── README.md                  # this file (English, default)
├── README-french.md           # condensed guide (FR)
├── step-by-step.md            # detailed manual (EN)
├── Etape-par-etape.md         # same (FR)
├── envsubst.env.example       # copy → envsubst.env (variables for envsubst)
├── docs/
│   ├── validation-applications.md
│   ├── developer-user1.md
│   └── utilisateur-developpeur-user1.md
├── ACM-implementation/        # Red Hat ACM: Placement, GitOpsCluster, guestbook → a-cluster
│   ├── README.md
│   └── applications/
├── principal/                 # PRINCIPAL cluster (hub)
│   ├── operator/
│   ├── namespaces/            # openshift-gitops, managed-cluster
│   ├── argocd/
│   ├── cert-manager/
│   ├── applications/
│   ├── appproject/
│   └── scripts/
├── managed-cluster/
│   ├── operator/
│   ├── namespaces/
│   ├── argocd/
│   ├── networkpolicy/
│   ├── helm/values-managed.yaml.template
│   └── scripts/
└── autonomous-cluster/
    ├── … (same baseline layout as managed-cluster)
    ├── helm/values-autonomous.yaml.template
    ├── applications/sample-application-autonomous-cluster2.yaml
    └── scripts/
```

---

## Prerequisites

- Three OpenShift clusters (or two if you only exercise managed: principal + managed-cluster).
- **cluster-admin** rights (or equivalent) on each cluster.
- `oc` / `kubectl` with **three stable contexts**, for example:

  ```bash
  oc config rename-context <ctx-principal> principal
  oc config rename-context <ctx-managed> managed-cluster
  oc config rename-context <ctx-autonomous> autonomous-cluster
  ```

- **`argocd-agentctl`** binary (recommended PKI flow for this PoV):
  - **Red Hat (recommended with the OpenShift GitOps operator)**: download from the [Content Gateway — openshift-gitops](https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/) (**1.19.0**, **1.20.0**, etc. — pick a version aligned with your OpenShift GitOps).
  - Upstream: [argocd-agent releases (GitHub)](https://github.com/argoproj-labs/argocd-agent/releases).
- **Helm** ≥ 3.8 for the `redhat-argocd-agent` chart.
- **Option B only**: the **cert-manager Operator for Red Hat OpenShift** must be installed on the **principal** cluster (and healthy) before you apply the manifests under `principal/cert-manager`. **jq** / **yq** are still required for the helper scripts.
- **`envsubst`** (often from the `gettext` package on Linux; on macOS: `brew install gettext` and ensure the binary is on your `PATH`) to substitute `${…}` variables in `*.template` files.

---

## Environment variables and `envsubst`

Template manifests use **`${VAR_NAME}`** (compatible with `envsubst`). Copy the example file and load it before running commands:

```bash
cp envsubst.env.example envsubst.env
# Edit envsubst.env (PRINCIPAL_ROUTE_HOST, RESOURCE_PROXY_SERVER, etc.)
set -a && source envsubst.env && set +a
```

**Targeted substitution** (useful if other `$` signs appear in files later):

```bash
envsubst '${PRINCIPAL_ROUTE_HOST}' < managed-cluster/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

**Substitute all** exported variables:

```bash
envsubst < managed-cluster/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

Same idea for `autonomous-cluster/helm/values-autonomous.yaml.template` and `principal/cert-manager/certificate-principal-tls.yaml.template`.

---

## Step 0 — Contexts and Helm chart

```bash
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update
```

On the **principal** (after installing the Argo CD Principal), get the **HTTPS hostname** for the Principal Route:

```bash
oc config use-context principal
oc get route -n openshift-gitops
```

Record the **bare hostname** for the Route (no `https://`, no **`:443`** suffix). Put it in **`envsubst.env`** as `PRINCIPAL_ROUTE_HOST` for the `*.template` files. The **`redhat-argocd-agent`** chart expects `server` as the hostname and **`serverPort`** for HTTPS (see `helm show values`: `server` / `serverPort`); the templates in this repo follow that pattern — do **not** put `https://…` in `server` or you may see connection errors like **`…:443:443` / too many colons** in agent logs.

Discover the **DNS name of the resource-proxy Service** (for `argocd-agentctl` and certificates):

```bash
oc get svc -n openshift-gitops | grep -i resource-proxy
```

---

## Step 1 — **principal** cluster

### 1.1 Operator and namespaces

```bash
oc config use-context principal
oc apply -k principal/operator
```

Wait until the operator is **Succeeded** (`oc get csv -n openshift-gitops-operator`).

```bash
oc apply -k principal/namespaces
```

### 1.2 Argo CD instance + Principal

```bash
oc apply -k principal/argocd
```

### 1.3 `AppProject` `default` — `sourceNamespaces`

Hub `Application` resources will use the `managed-cluster` namespace among others:

```bash
chmod +x principal/appproject/patch-default-source-namespaces.sh
./principal/appproject/patch-default-source-namespaces.sh openshift-gitops
```

Restart Argo CD pods if your product docs or environment require it.

### 1.4 Redis secret for the Principal

Once the `argocd-redis-initial-password` secret exists:

```bash
chmod +x principal/scripts/bootstrap-redis-secret-principal.sh
./principal/scripts/bootstrap-redis-secret-principal.sh openshift-gitops
```

---

## Step 2 — PKI and agent registration (managed-cluster + autonomous-cluster)

Two approaches; for a PoV, **option A** is the simplest.

### Option A — `argocd-agentctl` (recommended PoV)

The **`pki propagate`** and **`pki issue agent …`** commands write secrets into **`gitops-agent` (managed spoke)** or **`argocd` (autonomous spoke)**. Those namespaces must exist **before** you run them. The script below applies `managed-cluster/namespaces` and `autonomous-cluster/namespaces` up front; if you run **manually** (no script), do that before T25 / T26 — see [`Etape-par-etape.md`](Etape-par-etape.md) (*Spoke prerequisites* callout).

1. Export variables (same names as `envsubst.env.example`: `PRINCIPAL_ROUTE_HOST`, `RESOURCE_PROXY_SERVER` = **host:port** for the resource-proxy — see `oc get svc -n openshift-gitops`).

   ```bash
   set -a && source envsubst.env && set +a
   export PRINCIPAL_CTX=principal
   export CLUSTER1_CTX=managed-cluster
   export CLUSTER2_CTX=autonomous-cluster
   ```

2. Run the script (from this directory; `*/namespaces` paths are resolved relative to the script):

   ```bash
   chmod +x principal/scripts/bootstrap-argocd-agentctl.sh
   ./principal/scripts/bootstrap-argocd-agentctl.sh
   ```

The script: ensures spoke namespaces, initializes the CA, issues principal / resource-proxy certificates, creates the JWT signing key, registers **`managed-cluster`** and **`autonomous-cluster`** agents, propagates the CA, and issues client certificates on each spoke.

### Option B — **cert-manager** (optional)

**Prerequisite:** Install the **cert-manager Operator for Red Hat OpenShift** on the **principal** cluster first (Red Hat–supported cert-manager). Wait until the operator (CSV) is **Succeeded** and CRDs such as `certificates.cert-manager.io` / `issuers.cert-manager.io` are present (`oc get crd | grep cert-manager`). Without this operator, the `Certificate` and `Issuer` resources in `principal/cert-manager/` will not reconcile.

1. Generate an off-cluster CA (openssl) and create the `argocd-agent-ca` TLS secret in `openshift-gitops` (see [TLS documentation](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/#using-cert-manager)).
2. With `PRINCIPAL_ROUTE_HOST` exported:  
   `envsubst < principal/cert-manager/certificate-principal-tls.yaml.template | oc apply -f -`
3. `oc apply -k principal/cert-manager`
4. Wait for `READY=True` on `Certificate` objects.
5. Create the **`argocd-agent-jwt`** secret (for example with `argocd-agentctl jwt create-key` on the principal only, or the openssl procedure from upstream docs).
6. For each agent:

   ```bash
   ./principal/scripts/create-cluster-secret-certmanager.sh managed-cluster managed-cluster-principal
   ./principal/scripts/create-cluster-secret-certmanager.sh autonomous-cluster autonomous-cluster-principal
   ```

7. Export to each spoke:

   ```bash
   chmod +x principal/scripts/export-certmanager-secrets-to-spoke.sh
   ./principal/scripts/export-certmanager-secrets-to-spoke.sh managed-cluster-agent ./exported/managed-cluster
   oc apply -f ./exported/managed-cluster/ --context managed-cluster

   ./principal/scripts/export-certmanager-secrets-to-spoke.sh autonomous-cluster-agent ./exported/autonomous-cluster
   oc apply -f ./exported/autonomous-cluster/ --context autonomous-cluster
   ```

---

## Step 3 — **managed-cluster** (managed)

All commands below: **`oc config use-context managed-cluster`** unless noted.

### 3.1 Operator, namespace, Argo CD workload

If you already applied `managed-cluster/namespaces` before the PKI step (see **Step 2**), `oc apply -k managed-cluster/namespaces` is **idempotent**.

```bash
oc config use-context managed-cluster
oc apply -k managed-cluster/operator
# Required before managed-cluster/argocd: operator must have installed CRDs (otherwise: no matches for kind "ArgoCD")
until oc get crd argocds.argoproj.io &>/dev/null; do echo "Waiting for ArgoCD CRD…"; sleep 5; done
oc apply -k managed-cluster/namespaces
oc apply -k managed-cluster/argocd
```

If you see `ensure CRDs are installed first`, it is **not** because the `gitops-agent` namespace already existed: wait longer after `managed-cluster/operator` (e.g. `oc get csv -n openshift-gitops-operator` until **Succeeded**).

### 3.2 Local Redis secret

```bash
chmod +x managed-cluster/scripts/bootstrap-redis-secret-agent.sh
./managed-cluster/scripts/bootstrap-redis-secret-agent.sh gitops-agent
```

### 3.3 NetworkPolicy Agent → Redis

```bash
oc apply -k managed-cluster/networkpolicy
```

If the Redis pod does not carry the label `app.kubernetes.io/name=argocd-redis`, adjust `managed-cluster/networkpolicy/allow-agent-to-redis.yaml` after `oc get pods -n gitops-agent --show-labels`.

### 3.4 Helm — **managed** agent

With `PRINCIPAL_ROUTE_HOST` set (`envsubst.env` + `set -a && source envsubst.env && set +a`):

```bash
envsubst < managed-cluster/helm/values-managed.yaml.template | \
  helm install argocd-agent-managed openshift-helm-charts/redhat-argocd-agent \
    --kube-context managed-cluster \
    --namespace gitops-agent \
    -f -
```

(Alternative: render `values-managed.yaml` with `envsubst < …template > values-managed.yaml`, then `helm install … -f values-managed.yaml`.)

---

## Step 4 — **Managed** validation (principal → managed-cluster)

A minimal test app uses the **`helm-guestbook`** chart from [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps). Details and pass/fail checks: [`docs/validation-applications.md`](docs/validation-applications.md).

On the **principal**:

```bash
oc apply -f principal/applications/sample-application-managed-cluster1.yaml
```

On the hub: `Application` **`sample-managed-demo`** in namespace **`managed-cluster`**, destination **`name: managed-cluster`**, status **Synced** / **Healthy**. On the **managed-cluster** spoke: `oc get deploy,svc -n default` — chart resources (names depend on the Helm release).

---

## ACM GitOps (optional) — Guestbook on managed cluster `a-cluster`

If you enable the GitOps add-on and Argo CD Agent through **Red Hat Advanced Cluster Management** (`GitOpsCluster`, `Placement`, and so on), the end-to-end hub setup is documented under [`ACM-implementation/README.md`](ACM-implementation/README.md) — including a **pre-check** on stale hub **`Policy`** resources (`oc get policy`) that support recommends clearing before redeploy or validation. Once the add-on and agent are healthy, you can deploy the **guestbook** example from [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps) to a managed cluster named **`a-cluster`** as follows.

### Where the `Application` lives on the hub

The sample uses **`metadata.namespace: openshift-gitops`** so Argo CD reconciles the `Application` alongside the hub instance in that namespace. The namespace must be listed under **`spec.sourceNamespaces`** — see [`principal/argocd/argocd-principal.yaml`](principal/argocd/argocd-principal.yaml). The manifest uses **`project: managed-clusters-project`**; that `AppProject` must exist (ACM GitOps commonly provides it).

### Apply (hub context)

The manifest embeds **`${PRINCIPAL_ROUTE_HOST}`** in `destination.server` (hostname only — no `https://`). Copy [`envsubst.env.example`](envsubst.env.example) to `envsubst.env`, set `PRINCIPAL_ROUTE_HOST`, then:

```bash
oc config use-context principal
set -a && [ -f envsubst.env ] && . envsubst.env && set +a
envsubst '${PRINCIPAL_ROUTE_HOST}' < ACM-implementation/applications/guestbook-a-cluster.yaml | oc apply -f -
```

This yields `https://<host>/?agentName=a-cluster` and deploys the guestbook manifests into **`guestbook-deploy`** on the spoke. Change `agentName` or `destination.namespace` in [`ACM-implementation/applications/guestbook-a-cluster.yaml`](ACM-implementation/applications/guestbook-a-cluster.yaml) if your cluster secret name or target namespace differs.

### Verify

On the **hub**:

```bash
oc get application guestbook -n openshift-gitops -o yaml
```

On **managed cluster `a-cluster`** after a successful sync:

```bash
oc get deploy,svc -n guestbook-deploy --context a-cluster
```

Ensure **`guestbook-deploy`** exists on the spoke or can be created, and that **`managed-clusters-project`** allows that destination.

---

## Step 5 — **autonomous-cluster** (autonomous)

If `autonomous-cluster/namespaces` was applied before PKI, the namespaces step remains **idempotent**.

```bash
oc config use-context autonomous-cluster
oc apply -k autonomous-cluster/operator
until oc get crd argocds.argoproj.io &>/dev/null; do echo "Waiting for ArgoCD CRD…"; sleep 5; done
oc apply -k autonomous-cluster/namespaces
oc apply -k autonomous-cluster/argocd
chmod +x autonomous-cluster/scripts/bootstrap-redis-secret-agent.sh
./autonomous-cluster/scripts/bootstrap-redis-secret-agent.sh argocd
oc apply -k autonomous-cluster/networkpolicy
```

With `PRINCIPAL_ROUTE_HOST` loaded (`set -a && source envsubst.env && set +a`):

```bash
envsubst < autonomous-cluster/helm/values-autonomous.yaml.template | \
  helm install argocd-agent-autonomous openshift-helm-charts/redhat-argocd-agent \
    --kube-context autonomous-cluster \
    --namespace argocd \
    -f -
```

---

## Step 6 — **Autonomous** validation (autonomous-cluster)

Same **`helm-guestbook`** demo as managed (file and checks: [`docs/validation-applications.md`](docs/validation-applications.md)). Apply the `Application` **on autonomous-cluster** (not on the principal):

```bash
oc apply -f autonomous-cluster/applications/sample-application-autonomous-cluster2.yaml --context autonomous-cluster
```

`destination.server` must be `https://kubernetes.default.svc`. After sync: on **autonomous-cluster**, `oc get application sample-autonomous-demo -n argocd` should be **Synced** / **Healthy**; the app should also be visible **from the principal UI** for observability, per autonomous mode behavior ([details](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)).

---

## “Where to run what” cheat sheet

| Action | Cluster / context |
|--------|---------------------|
| `oc apply -k principal/…` | **principal** |
| `bootstrap-argocd-agentctl.sh`, AppProject patch, managed `Application` | **principal** (script creates required spoke namespaces first; PKI uses contexts for managed-cluster / autonomous-cluster) |
| `oc apply -k managed-cluster/…`, managed Helm | **managed-cluster** |
| `oc apply -k autonomous-cluster/…`, autonomous Helm | **autonomous-cluster** |
| `sample-application-managed-cluster1.yaml` | **principal** (hub `Application` namespace `managed-cluster`) |
| `envsubst … guestbook-a-cluster.yaml` (ACM path) | **principal** (hub `Application` in `openshift-gitops`; spoke namespace `guestbook-deploy` on `a-cluster`) |
| `sample-application-autonomous-cluster2.yaml` | **autonomous-cluster** (namespace `argocd`) |

---

## Quick troubleshooting

- **“namespaces … not found” with `argocd-agentctl pki propagate` / `pki issue agent`**: create spoke namespaces first (`oc apply -k managed-cluster/namespaces --context managed-cluster`, same for `autonomous-cluster`), or use `bootstrap-argocd-agentctl.sh` — details in [`Etape-par-etape.md`](Etape-par-etape.md) (Phase 2A).
- **`no matches for kind "ArgoCD"` / `ensure CRDs are installed first` on managed-cluster or autonomous-cluster**: wait until the OpenShift GitOps operator is **Succeeded** (CRD `argocds.argoproj.io` exists) **before** `oc apply -k managed-cluster/argocd` or `autonomous-cluster/argocd`. This is unrelated to `namespace/… unchanged` messages.
- **Principal CrashLoop — missing TLS secrets**: finish the PKI section (option A or B); check `oc get certificate -n openshift-gitops` if you use cert-manager.
- **Agent cannot reach Redis**: NetworkPolicy, Redis/Agent labels, `argocd-redis` secret on the spoke.
- **Agent: `too many colons in address` / `…:443:443`**: the chart splits **`server`** (hostname only) and **`serverPort`** (`443`). Fix `managed-cluster/helm/values-managed.yaml.template` (use an up-to-date copy of this repo) and `helm upgrade … -f` with `PRINCIPAL_ROUTE_HOST` **without** `https://` or `:443`.
- **`helm template … | grep` prints nothing**: do not hide stderr with `/dev/null` while debugging; verify `helm search repo redhat-argocd-agent` and `helm repo add openshift-helm-charts https://charts.openshift.io/`. Prefer `grep -F "agent.server.address"` — see T33 in [`step-by-step.md`](step-by-step.md).
- **`serverPort: Invalid type. Expected: string, given: integer`**: with `--set serverPort=443`, Helm sends an **integer**; the chart schema expects a **string**. Use **`--set-string serverPort=443`** (or in a values file: `serverPort: "443"` as in the repo `*.template` files).
- **Helm chart / values**: compare with [stderr.at — Helm redhat-argocd-agent](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/) (`server`, `serverPort`, `redisAddress`, Redis secrets).
- **OpenShift limitations** (Routes, load balancers, NetworkPolicy): [Red Hat blog — limitations](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops).

---

## License

Files are provided for internal PoV demonstrations; adapt security policies and PKI to your organization.

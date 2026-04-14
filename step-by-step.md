# Step-by-step guide — Argo CD Agent (multicluster PoV)

This document **complements** [`README.md`](README.md) by describing **each task**: goal, context (which cluster), detailed manual actions, and **reference** to the automation already in the repository (scripts, `*.template`).

**Target architecture**

| Cluster | Role |
|---------|------|
| **principal** | Hub: Argo CD + **Principal** component (central UI/API) |
| **cluster1** | Spoke: **managed Agent** — `Application` resources are defined on the hub |
| **cluster2** | Spoke: **autonomous Agent** — `Application` resources are defined on the spoke |

---

## How to read this guide

- Each **task** has an identifier **`Txx`** for tracking (internal checklist).
- The **Automation** column points to the repository file or command that bundles that step.
- **Manual commands** mirror the script logic: you can run them by hand to learn or troubleshoot.

---

## Environment prerequisites

### OpenShift clusters

This guide assumes you have **two or three OpenShift clusters**, at minimum version **4.18**. That version is the reference in Red Hat procedures / Argo CD Agent PoVs; still verify the official **compatibility matrix** for your **OpenShift GitOps** channel (and adjust if your organization requires a different version).

| Scenario | Number of clusters | Coverage |
|----------|-------------------|----------|
| **Reduced** PoV | **2** (principal + one spoke) | Enough to validate **one** mode at a time: **managed** *or* **autonomous** (by reinstalling the agent or switching spokes). |
| **Full** PoV (this document) | **3** (principal + cluster1 + cluster2) | **Managed** on cluster1 and **autonomous** on cluster2 in parallel. |

**Permissions**: **cluster-admin** access (or equivalent) on each relevant cluster.

**Networking**: **bidirectional** connectivity between the hub and each spoke for the **Principal** (gRPC / HTTPS depending on exposure: Routes, load balancers, firewalls). Without a reliable network path, the agent cannot reach the Principal.

---

### Overview — what we are building

The diagram below summarizes the target architecture: a **hub** hosts the Argo CD UI and **Principal**; each **spoke** runs an **Agent** (and a local Argo CD “workload” instance) that syncs applications with the hub according to the mode (**managed** = source of truth on the hub, **autonomous** = source of truth on the spoke).

```mermaid
flowchart TB
  subgraph HUB["Principal cluster — hub"]
    direction TB
    UI["Argo CD — UI / API"]
    PR["Principal — gRPC"]
    RP["Resource proxy"]
    MCR["Application CR — managed<br/>(defined on the hub)"]
    UI --- PR
    UI --- RP
    MCR --- UI
  end

  subgraph S1["Cluster cluster1 — spoke"]
    direction TB
    AM["Agent — managed"]
    W1["Argo CD workload<br/>controller / Redis / repo"]
    AM --- W1
  end

  subgraph S2["Cluster cluster2 — spoke"]
    direction TB
    ACR["Application CR — autonomous<br/>(defined on the spoke)"]
    AA["Agent — autonomous"]
    W2["Argo CD workload"]
    ACR --> AA
    AA --- W2
  end

  PR <-->|mTLS| AM
  PR <-->|mTLS| AA
  MCR -.->|deployment| AM
  ACR -.->|observability| UI
```

*Legend*: the **Principal** authenticates agents with **mTLS**. In **managed** mode, `Application` resources are created on the **principal** (`MCR`) and synced to the spoke. In **autonomous** mode, they are created on the **spoke** (`ACR` at the top of the cluster2 block, above the agent) and **surfaced** to the hub UI for observability. **Application CR** nodes are separated from **workloads** to avoid overlapping labels in the diagram.

---

### What you need (summary)

```mermaid
flowchart LR
  subgraph INFRA["Infrastructure"]
    OCP["OpenShift 4.18+<br/>2 or 3 clusters"]
    NET["Connectivity hub ↔ spokes"]
  end

  subgraph POSTE["Admin workstation"]
    OC["oc / kubectl"]
    H["helm ≥ 3.8"]
    CTL["argocd-agentctl"]
    ENV["envsubst"]
  end

  subgraph SEC["Security — PKI"]
    PKI["CA + certificates<br/>principal / proxy / agents"]
    CS["Argo CD cluster secrets"]
  end

  subgraph GITOPS["On clusters"]
    OP["OpenShift GitOps operator"]
    CR["ArgoCD CR + Principal or Agent"]
  end

  OCP --> NET
  OC --> OP
  H --> CR
  CTL --> PKI
  PKI --> CS
```

In practice, this maps to the following table (expanded in **Phase 0** and beyond).

| Area | Required for |
|------|----------------|
| **2 or 3** OCP clusters ≥ 4.18 | Hosting hub and spoke(s) |
| **Network** open hub ↔ spokes | Principal ↔ Agent connectivity |
| **`oc`** + distinct contexts | Applying manifests to the correct cluster |
| **`argocd-agentctl`** (or **cert-manager** + scripts) | mTLS, `cluster-*` secrets, client certificates |
| **`helm`** + `openshift-helm-charts` repo | `redhat-argocd-agent` chart on spokes |
| **`envsubst`** + `envsubst.env` | Generating Helm `values` and some YAML from `*.template` |
| **OpenShift GitOps** (operator) | `ArgoCD` CR with Principal or agent workload |

---

## Phase 0 — Local environment preparation

### T01 — Distinct `oc` contexts

**Goal**: target the hub and each spoke explicitly without ambiguity.

**Why**: `argocd-agentctl` and scripts use `--principal-context` and `--agent-context`; short names (`principal`, `cluster1`, `cluster2`) reduce mistakes.

**Actions**

1. Log in to each cluster (`oc login …`).
2. Rename contexts:

   ```bash
   oc config get-contexts
   oc config rename-context <old-principal-name> principal
   oc config rename-context <old-cluster1-name> cluster1
   oc config rename-context <old-cluster2-name> cluster2
   ```

**Check**: `oc config get-contexts` shows `principal`, `cluster1`, `cluster2`.

**Automation**: none (workstation configuration).

---

### T02 — Installed tools

**Goal**: have the binaries required for the PoV.

**Why**: PKI, Helm, and variable substitution are required for installation.

| Tool | Role |
|------|------|
| `oc` / `kubectl` | Apply manifests |
| `argocd-agentctl` | PKI and agent registration (option A) — [Content Gateway OpenShift GitOps](https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/) or [GitHub](https://github.com/argoproj-labs/argocd-agent/releases) |
| `helm` ≥ 3.8 | Install `redhat-argocd-agent` chart |
| `envsubst` | Fill `*.template` files (often from `gettext` package) |

**Automation**: Helm and cert-manager values use [`envsubst.env.example`](envsubst.env.example) — copy to `envsubst.env` then `set -a && source envsubst.env && set +a`.

---

### T03 — OpenShift Helm repository

**Goal**: install `openshift-helm-charts/redhat-argocd-agent`.

**Actions**

```bash
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update
```

**Check**: `helm search repo redhat-argocd-agent` lists the chart.

**Automation**: described in [`README.md`](README.md) (Step 0).

---

### T04 — `envsubst.env` variable file

**Goal**: centralize `PRINCIPAL_ROUTE_HOST`, `RESOURCE_PROXY_SERVER`, etc.

**Why**: `*.template` files use `${VAR}`; a single source of truth limits typos.

**Actions**

1. `cp envsubst.env.example envsubst.env`
2. Edit `envsubst.env`:
   - **`PRINCIPAL_ROUTE_HOST`**: **host only** for the Principal Route (no `https://`), obtained after T12 with `oc get route -n argocd --context principal`.
   - **`RESOURCE_PROXY_SERVER`**: `host:port` for the **resource-proxy** service on the principal (e.g. `…resource-proxy.argocd.svc.cluster.local:9090`), from `oc get svc -n argocd --context principal`.

**Check**: `set -a && source envsubst.env && set +a && echo "$PRINCIPAL_ROUTE_HOST"`

**Automation**: same file for `envsubst < …template | helm …`.

---

## Phase 1 — **Principal** cluster (hub)

*All commands below use the **`principal`** context (`oc config use-context principal`).*

---

### T10 — Install OpenShift GitOps operator (Subscription)

**Goal**: deploy the operator that manages `ArgoCD` resources and GitOps components.

**Why**: without a **Succeeded** CSV, `ArgoCD` CRs are not handled correctly.

**Actions**

```bash
oc config use-context principal
oc apply -k principal/operator
```

Wait until the **ClusterServiceVersion** phase is `Succeeded`:

```bash
oc get csv -n openshift-gitops-operator -w
```

**Check**: pods `Running` in `openshift-gitops-operator`.

**Automation**: [`principal/operator/`](principal/operator/) (Subscription + OperatorGroup + Namespace).

---

### T11 — Create `argocd` and `managed-cluster` namespaces

**Goal**: isolate the Argo CD / Principal instance and host hub “managed” `Application` resources.

**Why**: `managed-cluster` is listed in the hub Argo CD `spec.sourceNamespaces` for *Apps in any namespace*.

**Actions**

```bash
oc apply -k principal/namespaces
```

**Check**: `oc get ns argocd managed-cluster`.

**Automation**: [`principal/namespaces/`](principal/namespaces/).

---

### T12 — Create Argo CD instance with **Principal** enabled

**Goal**: deploy Argo CD UI/API on the hub and the **Principal** pod (gRPC endpoint for agents).

**Why**: `spec.controller.enabled: false` avoids a second controller on the hub; the Principal orchestrates sync with agents.

**Actions**

```bash
oc apply -k principal/argocd
```

**Check**: routes and pods appear in `argocd`; note the Principal **Route** for `PRINCIPAL_ROUTE_HOST` (T04).

```bash
oc get route -n argocd
oc get pods -n argocd
```

**Automation**: [`principal/argocd/argocd-principal.yaml`](principal/argocd/argocd-principal.yaml).

**Note**: until PKI (Phase 2) is ready, the Principal pod may stay in error — expected.

---

### T13 — Allow source namespaces on `AppProject` `default`

**Goal**: let Argo CD manage `Application` resources in `managed-cluster` (and `argocd` if needed).

**Why**: without `sourceNamespaces`, `Application` resources outside the instance namespace may be rejected.

**Actions** (equivalent to the script):

```bash
oc patch appproject default -n argocd --type=merge \
  -p '{"spec":{"sourceNamespaces":["managed-cluster","argocd"]}}'
```

Or run:

```bash
chmod +x principal/appproject/patch-default-source-namespaces.sh
./principal/appproject/patch-default-source-namespaces.sh argocd
```

**Check**: `oc get appproject default -n argocd -o yaml | grep -A5 sourceNamespaces`

**Automation**: [`principal/appproject/patch-default-source-namespaces.sh`](principal/appproject/patch-default-source-namespaces.sh).

---

### T14 — Redis secret for Principal

**Goal**: provide the Redis password expected by the Principal deployment (often aligned with the initial Argo CD secret).

**Why**: the Principal relies on Redis for some functions; without a consistent `argocd-redis` secret, pods may fail.

**Manual actions** (same logic as the script):

```bash
PW=$(oc get secret argocd-redis-initial-password -n argocd -o jsonpath='{.data.admin\.password}' | base64 -d)
oc create secret generic argocd-redis -n argocd --from-literal=auth="$PW" --dry-run=client -o yaml | oc apply -f -
# Then restart Principal deployment if needed
oc rollout restart deployment -n argocd -l app.kubernetes.io/name=argocd-agent-principal
```

**Check**: `oc get secret argocd-redis -n argocd`; Principal pod `Running`.

**Automation**: [`principal/scripts/bootstrap-redis-secret-principal.sh`](principal/scripts/bootstrap-redis-secret-principal.sh).

---

## Phase 2 — PKI and agent registration (cluster1 + cluster2)

Two paths: **A — argocd-agentctl** (recommended for PoV) or **B — cert-manager** (optional). Tasks below detail **A**; end of phase references **B**.

---

### Phase 2A — PKI with `argocd-agentctl` (manual, command by command)

*Principal context: `--principal-context principal`; for agents: `--agent-context cluster1` or `cluster2`.*

#### T20 — Initialize CA (Principal)

**Goal**: create `argocd-agent-ca` secret on the principal.

**Command**

```bash
argocd-agentctl pki init --principal-context principal --principal-namespace argocd
```

**Check**: `oc get secret argocd-agent-ca -n argocd --context principal`

---

#### T21 — Principal server certificate (gRPC)

**Goal**: `argocd-agent-principal-tls` secret for exposed gRPC (Route + internal SANs).

**Command** (adjust `--dns`: Route host + in-cluster service DNS)

```bash
argocd-agentctl pki issue principal \
  --principal-context principal \
  --principal-namespace argocd \
  --dns "localhost,argocd-agent-principal.argocd.svc.cluster.local,${PRINCIPAL_ROUTE_HOST}" \
  --upsert
```

**Check**: `argocd-agent-principal-tls` secret exists.

---

#### T22 — **resource-proxy** certificate

**Goal**: `argocd-agent-resource-proxy-tls` so Argo CD UI can talk to the resource proxy.

**Command** (adjust `--dns` to the real resource-proxy service name; see `oc get svc -n argocd`)

```bash
argocd-agentctl pki issue resource-proxy \
  --principal-context principal \
  --principal-namespace argocd \
  --dns "localhost,<resource-proxy-service-FQDN>" \
  --upsert
```

**Check**: `argocd-agent-resource-proxy-tls` secret exists.

---

#### T23 — Principal JWT signing key

**Goal**: `argocd-agent-jwt` secret for token signing on the Principal.

**Command**

```bash
argocd-agentctl jwt create-key \
  --principal-context principal \
  --principal-namespace argocd \
  --upsert
```

**Check**: `oc get secret argocd-agent-jwt -n argocd --context principal`

---

#### T24 — Register **cluster1** agent (Argo CD cluster secret)

**Goal**: create `cluster-cluster1` secret on the principal, labeled as a remote cluster, pointing to the resource proxy.

**Command** (`RESOURCE_PROXY_SERVER` = `host:port`, e.g. `…:9090`)

```bash
argocd-agentctl agent create cluster1 \
  --principal-context principal \
  --principal-namespace argocd \
  --resource-proxy-server "${RESOURCE_PROXY_SERVER}"
```

**Check**: `oc get secret cluster-cluster1 -n argocd -l argocd.argoproj.io/secret-type=cluster`

---

#### T25 — Propagate CA to **cluster1** and issue client certificate

**Goal**: on cluster1, `argocd-agent-ca` and `argocd-agent-client-tls` secret for mTLS.

**Commands**

```bash
argocd-agentctl pki propagate \
  --principal-context principal \
  --agent-context cluster1 \
  --principal-namespace argocd \
  --agent-namespace argocd

argocd-agentctl pki issue agent cluster1 \
  --principal-context principal \
  --agent-context cluster1 \
  --principal-namespace argocd \
  --agent-namespace argocd \
  --upsert
```

**Check** (cluster1 context): `oc get secrets -n argocd | grep argocd-agent`

---

#### T26 — Repeat for **cluster2** agent

**Goal**: same as T24–T25 with logical name `cluster2`.

**Commands**

```bash
argocd-agentctl agent create cluster2 \
  --principal-context principal \
  --principal-namespace argocd \
  --resource-proxy-server "${RESOURCE_PROXY_SERVER}"

argocd-agentctl pki propagate \
  --principal-context principal \
  --agent-context cluster2 \
  --principal-namespace argocd \
  --agent-namespace argocd

argocd-agentctl pki issue agent cluster2 \
  --principal-context principal \
  --agent-context cluster2 \
  --principal-namespace argocd \
  --agent-namespace argocd \
  --upsert
```

**Automation for T20–T26**: chain everything with [`principal/scripts/bootstrap-argocd-agentctl.sh`](principal/scripts/bootstrap-argocd-agentctl.sh) after exporting `PRINCIPAL_ROUTE_HOST`, `RESOURCE_PROXY_SERVER`, `PRINCIPAL_CTX`, `CLUSTER1_CTX`, `CLUSTER2_CTX`.

---

### Phase 2B — PKI with **cert-manager** (overview)

**Goal**: same end state for secrets, using cert-manager operator on the principal.

**Summary steps** (details in [`README.md`](README.md) — Option B):

1. Create CA (openssl) and TLS secret `argocd-agent-ca` in `argocd`.
2. Deploy `Issuer` + `Certificate` (`oc apply -k principal/cert-manager` after generating the principal cert with  
   `envsubst < principal/cert-manager/certificate-principal-tls.yaml.template | oc apply -f -`).
3. Wait for `READY` on `Certificate` resources.
4. Create `argocd-agent-jwt` (often only `argocd-agentctl jwt create-key`).
5. Build `cluster-cluster1` / `cluster-cluster2` secrets: [`principal/scripts/create-cluster-secret-certmanager.sh`](principal/scripts/create-cluster-secret-certmanager.sh).
6. Export to spokes: [`principal/scripts/export-certmanager-secrets-to-spoke.sh`](principal/scripts/export-certmanager-secrets-to-spoke.sh).

---

## Phase 3 — **cluster1** (**managed** agent)

*Context: **`cluster1`**.*

---

### T30 — Operator, namespace, Argo CD “workload”

**Goal**: install OpenShift GitOps on the spoke and an Argo CD instance **without a UI server** (local Redis + repo-server + application-controller).

**Why**: the agent drives the local controller; the UI stays on the principal.

**Actions**

```bash
oc config use-context cluster1
oc apply -k cluster1/operator
# Wait for CSV Succeeded
oc apply -k cluster1/namespaces
oc apply -k cluster1/argocd
```

**Check**: `argocd` pods in `argocd` on cluster1 (no server Route required).

**Automation**: [`cluster1/operator`](cluster1/operator), [`cluster1/argocd`](cluster1/argocd).

---

### T31 — Redis secret on spoke

**Goal**: same principle as T14 for the local Argo CD instance.

**Automation**: [`cluster1/scripts/bootstrap-redis-secret-agent.sh`](cluster1/scripts/bootstrap-redis-secret-agent.sh).

---

### T32 — NetworkPolicy Agent → Redis

**Goal**: allow Agent pod traffic to Redis (workaround for default policies that are often too strict).

**Actions**: `oc apply -k cluster1/networkpolicy` then verify Redis/Agent labels if needed.

**Automation**: [`cluster1/networkpolicy/`](cluster1/networkpolicy/).

---

### T33 — Install **managed** Helm chart

**Goal**: deploy **Agent** pod in `managed` mode, connected to the Principal HTTPS URL.

**Actions** (variables loaded from `envsubst.env`):

```bash
set -a && source envsubst.env && set +a
envsubst < cluster1/helm/values-managed.yaml.template | \
  helm install argocd-agent-managed openshift-helm-charts/redhat-argocd-agent \
    --kube-context cluster1 \
    -f -
```

**Check**: agent pod `Running`; no Principal connection errors in logs.

**Automation**: template [`cluster1/helm/values-managed.yaml.template`](cluster1/helm/values-managed.yaml.template).

---

## Phase 4 — **Managed** validation

### T40 — Deploy an `Application` from the **principal**

**Goal**: prove the hub owns the spec and **cluster1** runs the target deployment.

**Actions** (**principal** context):

```bash
oc apply -f principal/applications/sample-application-managed-cluster1.yaml
```

**Check**: on principal, `Application` `sample-managed-cluster1` in `managed-cluster`; **Synced** / **Healthy**. On cluster1, chart resources in `default`.

**Details**: [`docs/validation-applications.md`](docs/validation-applications.md).

---

## Phase 5 — **cluster2** (**autonomous** agent)

*Context: **`cluster2`**. Same sequence as Phase 3 (T30–T32), then Helm in **autonomous** mode.*

### T50 — OpenShift GitOps base + Argo CD workload + Redis + NetworkPolicy

See T30–T32 replacing `cluster1` with `cluster2` and paths `cluster2/…`.

---

### T51 — **Autonomous** Helm

**Goal**: agent whose source of truth for `Application` resources is the **spoke**.

**Actions**

```bash
set -a && source envsubst.env && set +a
envsubst < cluster2/helm/values-autonomous.yaml.template | \
  helm install argocd-agent-autonomous openshift-helm-charts/redhat-argocd-agent \
    --kube-context cluster2 \
    -f -
```

**Automation**: [`cluster2/helm/values-autonomous.yaml.template`](cluster2/helm/values-autonomous.yaml.template).

---

## Phase 6 — **Autonomous** validation

### T60 — Create `Application` on **cluster2**

**Goal**: demonstrate autonomous mode (`destination.server: https://kubernetes.default.svc`).

**Actions** (**cluster2** context):

```bash
oc apply -f cluster2/applications/sample-application-autonomous-cluster2.yaml --context cluster2
```

**Check**: **Synced** status on cluster2; visibility from principal UI per autonomous mode behavior.

**Details**: [`docs/validation-applications.md`](docs/validation-applications.md).

---

## Task summary table

| ID | Task | Cluster |
|----|------|---------|
| T01–T04 | Preparation (contexts, tools, Helm, `envsubst.env`) | Local |
| T10–T14 | Operator, namespaces, Argo CD Principal, AppProject, Redis | principal |
| T20–T26 | PKI `argocd-agentctl` + cluster1 & cluster2 agents | principal + cluster1 + cluster2 |
| T30–T33 | Managed spoke (operator, Argo CD, NP, Helm managed) | cluster1 |
| T40 | Managed test application | principal → cluster1 |
| T50–T51 | Autonomous spoke + Helm autonomous | cluster2 |
| T60 | Autonomous test application | cluster2 |

---

## “All-in-script” equivalence

| Area | Bundled script / resource |
|------|---------------------------|
| PKI + agents | [`principal/scripts/bootstrap-argocd-agentctl.sh`](principal/scripts/bootstrap-argocd-agentctl.sh) |
| Principal Redis | [`principal/scripts/bootstrap-redis-secret-principal.sh`](principal/scripts/bootstrap-redis-secret-principal.sh) |
| Spoke Redis | [`cluster1/scripts/bootstrap-redis-secret-agent.sh`](cluster1/scripts/bootstrap-redis-secret-agent.sh), [`cluster2/scripts/bootstrap-redis-secret-agent.sh`](cluster2/scripts/bootstrap-redis-secret-agent.sh) |
| AppProject | [`principal/appproject/patch-default-source-namespaces.sh`](principal/appproject/patch-default-source-namespaces.sh) |
| Cert-manager (optional) | [`create-cluster-secret-certmanager.sh`](principal/scripts/create-cluster-secret-certmanager.sh), [`export-certmanager-secrets-to-spoke.sh`](principal/scripts/export-certmanager-secrets-to-spoke.sh) |

For the condensed procedure and external links, see [`README.md`](README.md).

---

*French version: [`Etape-par-etape.md`](Etape-par-etape.md).*

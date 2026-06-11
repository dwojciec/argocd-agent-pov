# ACM implementation (GitOps / Argo CD Agent)

Step-by-step manifests for **Red Hat Advanced Cluster Management (ACM)** and OpenShift GitOps, aligned with this repository.

All cluster names are **parameterized** — nothing is tied to a specific environment. Configure `ACM-implementation/clusters.env` (from `clusters.env.example`) and render templates with the scripts under `scripts/`.

## Reference documentation

- [ACM 2.16 — GitOps](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index)
- [Enabling Argo CD Agent (GitOpsCluster + Placement)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index#enabling_argocd_agent)
- [Argo CD Agent — agent modes](https://argocd-agent.readthedocs.io/latest/user-guide/migration/#choose-agent-operation-modes)

---

## Choose managed vs autonomous mode

| Mode | Where `Application` resources live | Hub role |
|------|-----------------------------------|----------|
| **managed** | Hub (`GITOPS_NAMESPACE` or `agent-managed`) | Source of truth; syncs to spokes |
| **autonomous** | Each spoke (`openshift-gitops` or `argocd`) | Observability; spoke reconciles locally |

You can enable **one or both** modes by setting comma-separated cluster lists in `clusters.env`:

```bash
# Managed spokes only
export MANAGED_SPOKE_CLUSTERS=workload-1,workload-2
export AUTONOMOUS_SPOKE_CLUSTERS=

# Autonomous spokes only
export MANAGED_SPOKE_CLUSTERS=
export AUTONOMOUS_SPOKE_CLUSTERS=edge-1

# Mixed (typical PoV)
export MANAGED_SPOKE_CLUSTERS=managed-cluster
export AUTONOMOUS_SPOKE_CLUSTERS=autonomous-cluster
```

Each mode gets its own **Placement** and **GitOpsCluster** (`mode: managed` or `mode: autonomous` in `spec.gitopsAddon.argoCDAgent`).

Hub cluster secret names must match `metadata.labels.name` on each `ManagedCluster` (values in the placement predicates).

---

## Repository layout

```
ACM-implementation/
├── clusters.env.example          # Spoke names, modes, Git URLs (copy → clusters.env)
├── managedclustersetbinding.yaml.template
├── gitopscluster-managed.yaml.template
├── gitopscluster-autonomous.yaml.template
├── scripts/
│   ├── render-placement.sh       # Placement from comma-separated cluster list
│   ├── apply-gitopsclusters.sh   # Apply binding + placements + GitOpsClusters
│   ├── apply-managed-test-apps.sh
│   ├── apply-autonomous-test-app.sh
│   └── build-allowed-namespaces.sh
├── applications/
│   ├── managed/                  # Hub-side (managed mode)
│   └── autonomous/               # Spoke-side (autonomous mode)
└── workloads/
    ├── openshift-demo/           # Kustomize (port 8080, OpenShift-safe)
    └── openshift-demo-helm/      # Helm variant
```

> **Do not** use `oc apply -k ACM-implementation` for GitOpsCluster resources — they are templates. Use `scripts/apply-gitopsclusters.sh`.

---

## Step 1 — OpenShift GitOps operator (principal)

From repository root:

```bash
oc apply -k principal/operator
oc apply -f principal/namespaces/namespaces.yaml
```

Render and apply the Argo CD Principal CR (allowed namespaces derived from `clusters.env`):

```bash
cp envsubst.env.example envsubst.env
cp ACM-implementation/clusters.env.example ACM-implementation/clusters.env
# Edit both files

set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
export ARGOCD_PRINCIPAL_ALLOWED_NAMESPACES="$(./ACM-implementation/scripts/build-allowed-namespaces.sh)"
envsubst '${PRINCIPAL_NS} ${ARGOCD_PRINCIPAL_ALLOWED_NAMESPACES}' \
  < principal/argocd/argocd-principal.yaml.template | oc apply -f -
```

---

## Step 2 — Placement and GitOpsCluster

### Prerequisites

- Hub Argo CD principal running in `GITOPS_NAMESPACE` (default `openshift-gitops`).
- Spokes belong to `CLUSTER_SET_NAME` (default `poc-acm`):

```bash
oc get managedcluster <spoke-name> -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'
```

- Each `ManagedCluster` has `metadata.labels.name` matching its entry in `MANAGED_SPOKE_CLUSTERS` / `AUTONOMOUS_SPOKE_CLUSTERS`.

### Stale `Policy` objects

Before deploy or restart, list ACM policies on the hub:

```bash
oc get policy -n openshift-gitops
```

Delete stale policies, then re-run `apply-gitopsclusters.sh` to regenerate them.

### Apply

```bash
chmod +x ACM-implementation/scripts/*.sh
set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
./ACM-implementation/scripts/apply-gitopsclusters.sh
```

### Verify

```bash
oc get gitopscluster -n openshift-gitops
oc get placement -n openshift-gitops
oc get placementdecision -n openshift-gitops
```

---

## Step 3 — Deploy test Applications

OpenShift-compatible workloads (no Apache port 80): `ACM-implementation/workloads/openshift-demo`.

### Managed mode (hub)

```bash
set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
./ACM-implementation/scripts/apply-managed-test-apps.sh
```

First managed spoke uses Kustomize; additional spokes use Helm (same demo, different packaging).

Optional **ApplicationSet** for all managed spokes:

```bash
envsubst '${GITOPS_NAMESPACE} ${GIT_REPO_URL} ${GIT_TARGET_REVISION} ${WORKLOAD_PATH_KUSTOMIZE} ${MANAGED_DEMO_NAMESPACE}' \
  < ACM-implementation/applications/managed/applicationset-openshift-demo.yaml.template | oc apply -f -
```

### Autonomous mode (spoke)

On each autonomous spoke:

```bash
set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
export ARGOCD_NAMESPACE=openshift-gitops   # ACM add-on default; use argocd for manual PoV
oc config use-context <autonomous-spoke>
./ACM-implementation/scripts/apply-autonomous-test-app.sh <spoke-name>
```

### Verify

```bash
# Hub — managed apps
oc get application -n openshift-gitops -l test.argocd-agent-pov/mode=managed

# Spoke — workloads
oc get deploy,svc -n demo-managed --context <managed-spoke>
oc get deploy,svc -n demo-autonomous --context <autonomous-spoke>
```

---

## Manual template rendering (single spoke)

Managed demo with ACM `AppProject` and agent routing:

```bash
export SPOKE_CLUSTER_NAME=<spoke-name>
export TARGET_NAMESPACE=demo-managed
export WORKLOAD_PATH=ACM-implementation/workloads/openshift-demo
envsubst '${PRINCIPAL_ROUTE_HOST} ${SPOKE_CLUSTER_NAME} ${GIT_REPO_URL} ${GIT_TARGET_REVISION} ${WORKLOAD_PATH} ${GITOPS_NAMESPACE} ${TARGET_NAMESPACE}' \
  < ACM-implementation/applications/managed/demo-managed-spoke.yaml.template | oc apply -f -
```

---

## Next steps

PKI, Helm agent install without ACM, and non-ACM validation paths are in the main [`README.md`](../README.md). Keep the [ACM GitOps guide](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index) open while iterating on add-on and agent behaviour.

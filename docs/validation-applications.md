# Test Applications — managed vs autonomous

OpenShift-compatible demo workloads live under `ACM-implementation/workloads/` (`nginx-unprivileged` on port **8080**, no privileged binding).

| Mode | Manifest | Where to apply | Source of truth |
|------|----------|----------------|-----------------|
| **Managed** (no ACM) | `principal/applications/sample-application-managed-cluster1.yaml.template` | **Principal** hub | Hub (`agent-managed` namespace) |
| **Managed** (ACM) | `ACM-implementation/applications/managed/test-app-openshift-demo.yaml.template` | **Principal** hub | Hub (`GITOPS_NAMESPACE`) |
| **Autonomous** (no ACM) | `autonomous-cluster/applications/sample-application-autonomous-cluster2.yaml.template` | **Autonomous spoke** | Spoke (`argocd` namespace) |
| **Autonomous** (ACM) | `ACM-implementation/applications/autonomous/test-app-openshift-demo.yaml.template` | **Autonomous spoke** | Spoke (`openshift-gitops` or `ARGOCD_NAMESPACE`) |

Configure cluster names and modes in `ACM-implementation/clusters.env` (from `clusters.env.example`).

## Quick success criteria

1. **Managed (hub → spoke)**  
   - Hub: `Application` **Synced** / **Healthy**.  
   - Spoke: `oc get deploy,svc -n <demo-namespace>` → `demo-app` **Running**.

2. **Autonomous (spoke → visible on hub)**  
   - Spoke: `Application` **Synced** / **Healthy**.  
   - Hub UI: application visible for observability (autonomous mode).

## Render and apply (templates)

```bash
cp envsubst.env.example envsubst.env
cp ACM-implementation/clusters.env.example ACM-implementation/clusters.env
# Edit both files for your environment

set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
export ARGOCD_PRINCIPAL_ALLOWED_NAMESPACES="$(./ACM-implementation/scripts/build-allowed-namespaces.sh)"
export MANAGED_SPOKE_CLUSTER="${MANAGED_SPOKE_CLUSTER:-$(echo "$MANAGED_SPOKE_CLUSTERS" | cut -d, -f1)}"

# Non-ACM managed demo (principal)
envsubst < principal/applications/sample-application-managed-cluster1.yaml.template | oc apply -f -

# Non-ACM autonomous demo (autonomous spoke context)
export ARGOCD_NAMESPACE=argocd
envsubst < autonomous-cluster/applications/sample-application-autonomous-cluster2.yaml.template | oc apply -f -
```

ACM path: see [`ACM-implementation/README.md`](../ACM-implementation/README.md).

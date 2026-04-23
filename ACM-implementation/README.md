# ACM implementation steps (GitOps / Argo CD)

This folder holds step-by-step notes for implementing the GitOps workflow with **Red Hat Advanced Cluster Management for Kubernetes (ACM)** and OpenShift GitOps, aligned with the manifests in this repository (`argocd-agent-multicluster-pov`).

## Reference documentation

- [Red Hat Advanced Cluster Management for Kubernetes 2.16 — GitOps](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index#enable-gitops-addon-with-argocd) — especially *Enable GitOps add-on with Argo CD* for ACM GitOps integration context.
- [Enabling Argo CD Agent (GitOpsCluster + Placement)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index#enabling_argocd_agent) — *Placement* selects managed clusters; *GitOpsCluster* enables the GitOps add-on and Argo CD Agent toward your hub Argo CD instance.

Read those sections alongside these repository-specific commands so hub configuration (operator, Argo CD instance shape) matches your ACM GitOps rollout.

---

## Step 1 — Install and configure the OpenShift GitOps operator (principal)

Apply the Kustomize bundle under `principal/operator` on the **hub** cluster (OpenShift). It creates the `openshift-gitops-operator` namespace, an `OperatorGroup`, and a `Subscription` with environment variables that disable the default Argo CD instance and widen cluster-scoped Argo CD configuration where needed.

From the **repository root** (parent of this folder):

```bash
oc apply -k principal/operator
```

Wait until the OpenShift GitOps operator CSV is installed and its pods are healthy, for example:

```bash
oc get csv -n openshift-gitops-operator
oc get pods -n openshift-gitops-operator
```

**Note:** In [`subscription.yaml`](../principal/operator/subscription.yaml), adjust `spec.channel` (for example `gitops-1.20`) to a channel that exists in your cluster’s OperatorHub catalog.

---

## Step 2 — Create the Argo CD instance (principal / control plane)

The Argo CD custom resource is defined in [`argocd-principal.yaml`](../principal/argocd/argocd-principal.yaml). It targets namespace `gitops-control-plane`. If the hub namespaces do not exist yet, create `gitops-control-plane`, `agent-managed`, and `agent-autonomous` (see [`namespaces.yaml`](../principal/namespaces/namespaces.yaml)):

```bash
oc apply -f principal/namespaces/namespaces.yaml
```

Then apply the Argo CD instance:

```bash
oc apply -f principal/argocd/argocd-principal.yaml
```

Verify the instance and workloads:

```bash
oc get argocd -n gitops-control-plane
oc get pods -n gitops-control-plane
```

---

## Step 3 — Placement and GitOpsCluster (enable Argo CD Agent via ACM)

Follow [Enabling Argo CD Agent](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index#enabling_argocd_agent): define a **Placement** that selects your managed clusters, then a **GitOpsCluster** in the **same namespace** that references that placement and points the add-on at the hub Argo CD namespace (`gitops-control-plane` here).

### Prerequisites

- Hub: Argo CD principal instance is running in `gitops-control-plane` (steps 1–2).
- **ManagedClusterSet**: your spokes must belong to the set referenced by the binding (here **`poc-acm`**). Confirm on the hub, for example:

```bash
oc get managedcluster a-cluster -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'
oc get managedcluster b-cluster -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'
```

If your set name differs, change **`poc-acm`** in [`managedclustersetbinding-poc-acm.yaml`](managedclustersetbinding-poc-acm.yaml) (both `metadata.name` / `spec.clusterSet`) and in [`placement-managed-clusters.yaml`](placement-managed-clusters.yaml) under `spec.clusterSets`.

- **ManagedCluster labels**: the placement keeps a predicate on label **`name`** ∈ `a-cluster`, `b-cluster`. Ensure each `ManagedCluster` has `metadata.labels.name` set accordingly, or edit [`placement-managed-clusters.yaml`](placement-managed-clusters.yaml) (`matchExpressions` / `values`).

### Apply

From the **repository root**:

```bash
oc apply -k ACM-implementation
```

This applies, in order, [`managedclustersetbinding-poc-acm.yaml`](managedclustersetbinding-poc-acm.yaml) (binds the set into `gitops-control-plane`), [`placement-managed-clusters.yaml`](placement-managed-clusters.yaml), then [`gitopscluster-argocd-agent.yaml`](gitopscluster-argocd-agent.yaml) via [`kustomization.yaml`](kustomization.yaml).

Alternatively, apply the files explicitly (same order):

```bash
oc apply -f ACM-implementation/managedclustersetbinding-poc-acm.yaml
oc apply -f ACM-implementation/placement-managed-clusters.yaml
oc apply -f ACM-implementation/gitopscluster-argocd-agent.yaml
```

### Verify

```bash
oc get managedclustersetbinding -n gitops-control-plane
oc get placement placement-managed-clusters -n gitops-control-plane -o jsonpath='{.status.conditions[?(@.type=="PlacementSatisfied")]}'
echo
```

When placement is healthy, `PlacementSatisfied` should report **`status":"True"`**, **`reason":"AllDecisionsScheduled"`**, and **`message":"All cluster decisions scheduled"`**. Example:

```json
{"lastTransitionTime":"2026-04-23T16:45:36Z","message":"All cluster decisions scheduled","reason":"AllDecisionsScheduled","status":"True","type":"PlacementSatisfied"}
```

Then confirm decisions and GitOps:

```bash
oc get placementdecision -n gitops-control-plane -l cluster.open-cluster-management.io/placement=placement-managed-clusters -o yaml
oc get gitopscluster gitops-agent-clusters -n openshift-gitops -o jsonpath='{.status.conditions}' | jq
```

If you created the `GitOpsCluster` in another namespace (for example `gitops-control-plane` as in the manifests in this folder), use that namespace in the `oc get gitopscluster` command instead of `openshift-gitops`.

#### Placement still `PlacementSatisfied=False`

If you see **`reason":"NoManagedClusterMatched"`** and **`message":"No ManagedCluster matches any of the cluster predicate"`**, no cluster in the bound cluster set passed every predicate. Typical fixes:

- Confirm **`ManagedClusterSetBinding`** exists and **`spec.clusterSet`** matches the set your clusters use (`oc get managedcluster <name> -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'`).
- Align **`spec.clusterSets`** on the `Placement` with that set name (here **`poc-acm`**).
- Align the **label predicate** (`metadata.labels.name` with values `a-cluster` / `b-cluster`) with the real labels on each `ManagedCluster`, or edit [`placement-managed-clusters.yaml`](placement-managed-clusters.yaml).

If the controller does not populate the agent principal address and you need to override it (see the documentation for `serverAddress` / `serverPort` under `spec.gitopsAddon.argoCDAgent`), patch the `GitOpsCluster` after checking your Argo CD Agent principal Route hostname, for example:

```bash
oc get route -n gitops-control-plane
```

---

## Step 4 — Deploy a sample Application to managed cluster `a-cluster`

After the GitOps add-on and Argo CD Agent are healthy, deploy the **guestbook** example from [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps) to spoke **`a-cluster`**.

### Where the `Application` lives on the hub

The hub Argo CD instance allows `Application` CRs only in namespaces listed under **`spec.sourceNamespaces`** (see [`principal/argocd/argocd-principal.yaml`](../principal/argocd/argocd-principal.yaml)). The manifests below use **`agent-managed`**. If you prefer the Application in another hub namespace (for example one named like the cluster), add that namespace to `sourceNamespaces` and change `metadata.namespace` in the YAML accordingly.

### Pointing the destination at `a-cluster`

- **Recommended:** use **`destination.name: a-cluster`** so it matches the Argo CD **cluster** secret on the hub for that managed cluster (same idea as [`principal/applications/sample-application-managed-cluster1.yaml`](../principal/applications/sample-application-managed-cluster1.yaml), which uses `destination.name`).

```bash
oc apply -f ACM-implementation/applications/guestbook-a-cluster.yaml
```

- **Alternative (explicit principal URL + `agentName`):** equivalent to passing `server: 'https://<argocd-agent-principal-route>?agentName=a-cluster'`. Use the template and `PRINCIPAL_ROUTE_HOST` (hostname only, no `https://`), for example from [`envsubst.env.example`](../envsubst.env.example):

```bash
set -a && [ -f envsubst.env ] && . envsubst.env && set +a
envsubst < ACM-implementation/applications/guestbook-a-cluster-server-url.yaml.template | oc apply -f -
```

### Verify

On the **hub** (Argo CD UI or CLI):

```bash
oc get application guestbook -n agent-managed -o yaml
```

On **managed cluster `a-cluster`**, once synced:

```bash
oc get deploy,svc -n a-cluster --context a-cluster
```

Ensure namespace **`a-cluster`** exists on the spoke (or let Argo CD create it if your RBAC allows), and that the default `AppProject` allows deploying into that destination namespace.

---

## Next steps (ACM GitOps)

Additional steps (PKI outside ACM, Application placement, spoke tuning) may still live in the main [`README.md`](../README.md) walkthrough. Keep the [ACM 2.16 GitOps guide](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html-single/gitops/index#enable-gitops-addon-with-argocd) open while you iterate on add-on and agent behaviour.

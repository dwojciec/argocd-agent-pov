# Non-`cluster-admin` user — creating applications (e.g. `user1`)

This document describes what the **platform admin** must prepare so a **developer / application owner** (here **`user1`**) can **create and manage their own** Argo CD **applications** that **deploy to spoke cluster `managed-cluster`**, in **managed Agent mode**, **without** operating the agent, Principal, or certificates.

> **Key point — managed mode**  
> The source of truth for `Application` resources is the **principal (hub) cluster**. `user1` therefore interacts with **Argo CD on the principal** (UI, `argocd` CLI, or `kubectl` in an allowed namespace). They do **not** “only” create the `Application` on `managed-cluster` in the strict GitOps sense: the `Application` manifest lives on the **hub**; **workload** deployment happens **on `managed-cluster`** via the agent.  
> If the customer requires that `user1` **never** touches the principal, **autonomous** mode on a spoke is more appropriate (out of scope for this note, which focuses on **managed** mode on spoke **`managed-cluster`**).

---

## 1. Roles and responsibilities

| Actor | Role | Responsibilities |
|-------|------|------------------|
| **Cluster-admin (platform)** | Installation and hardening | OpenShift GitOps operator, Principal, agents, PKI/mTLS, `AppProject`, SSO/OAuth integration with Argo CD, Kubernetes **and** Argo CD RBAC, team namespaces, quotas/NetworkPolicies, **ServiceAccount** rights used by Argo CD to **sync** on the spoke. |
| **`user1`** (developer / technical product owner) | Argo CD consumer | Log in to Argo CD (hub), create/update **their** `Application` resources within **their** scope (project + target namespaces), trigger or automate sync, view status — **without** administering the cluster or agent. |
| **Argo CD (sync account)** | Automatic | The application controller on the spoke applies manifests with a **Kubernetes service account** (not `user1`’s human identity). The **platform** grants that account rights on target namespaces. |

---

## 2. What the cluster-admin sets up (one-time)

### 2.1 Identity for `user1`

- Create an **OpenShift user** (or group) for `user1`, or use **OAuth / SSO** already wired to the **principal** cluster where Argo CD runs.
- Map that user into **Argo CD** (policy in `argocd-rbac-cm` or OIDC integration per your model).

### 2.2 “Applications” namespace on the **principal** (hub)

*Apps in any namespace* `Application` resources must live in a namespace **declared** on the Argo CD instance (`spec.sourceNamespaces`) **and** allowed in the `AppProject`.

Typical pattern:

- Dedicated namespace: `team-user1` (or shared `managed-cluster` with tighter controls).
- Cluster-admin adds that namespace to `sourceNamespaces` on the `ArgoCD` CR if needed, and on the `AppProject` (`spec.sourceNamespaces`).

### 2.3 Dedicated `AppProject` (recommended)

Create an **`AppProject`** (e.g. `project-user1`) that **scopes** `user1`:

- **`sourceRepos`**: only Git repositories allowed for that team (avoid `*` in production).
- **`destinations`**:  
  - `name: managed-cluster` (cluster secret registered on the principal) **or** cluster URL if you use that pattern;  
  - **target namespaces** on `managed-cluster`: e.g. `user1-dev`, `user1-int` — **not** `*` in production.
- **`namespaceResourceWhitelist`** / **blacklist** per your policy (what the app may deploy).
- **`sourceNamespaces`**: principal namespaces where `user1` may create `Application` resources (e.g. `team-user1`).

Conceptual reference: Argo CD [AppProject](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/) model.

### 2.4 Argo CD RBAC (policy)

In the **`argocd-rbac-cm`** `ConfigMap` (Argo CD namespace on the principal), define a **role** such as `role:user1-developer` with **restricted** permissions:

- View/create/update/delete **applications** in project `project-user1` only.
- No access to **cluster** secrets, global **repositories**, other teams’ **projects**, or Argo CD admin settings.

Example **policy lines** (adapt — exact syntax depends on your Argo CD version):

```csv
p, role:user1-developer, applications, get, project-user1/*, allow
p, role:user1-developer, applications, create, project-user1/*, allow
p, role:user1-developer, applications, update, project-user1/*, allow
p, role:user1-developer, applications, delete, project-user1/*, allow
p, role:user1-developer, applications, sync, project-user1/*, allow
p, role:user1-developer, logs, get, project-user1/*, allow
g, user1, role:user1-developer
```

(The `g, user1, …` form depends on **OIDC claims** or Argo CD username; align with your identity provider.)

### 2.5 Kubernetes RBAC on the **principal** (if `user1` uses `kubectl`)

If `user1` applies `Application` manifests with `kubectl` (or the API):

- **`Role` + `RoleBinding`** in the team namespace (e.g. `team-user1`) for `create/get/update/delete/list/watch` on `applications.argoproj.io` (and read `appprojects` if needed).

Minimal example:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-application-editor
  namespace: team-user1
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: user1-argocd-applications
  namespace: team-user1
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-application-editor
subjects:
  - kind: User
    name: user1
    apiGroup: rbac.authorization.k8s.io
```

> Adjust `kind: User` / `Group` per your OpenShift identity provider.

### 2.6 Rights on **managed-cluster** (spoke) — **sync** account, not `user1`

**Deployment** is performed by the Argo CD **application-controller** (on the spoke) / agent. The cluster-admin must ensure the **ServiceAccount** used to apply resources on `managed-cluster` has rights on **target namespaces** (e.g. `user1-dev`).

- Either **ClusterRole** + **ClusterRoleBinding** (broad — avoid except in PoV).
- Or **Role** + **RoleBinding** per target namespace (recommended).

**`user1` generally does not need** `cluster-admin` on `managed-cluster` for sync to work. If you want `user1` to **debug** (`oc get pod` in their namespace), grant a **view** or **edit** **Role** scoped to **their namespaces** on `managed-cluster`.

---

## 3. What `user1` does day‑to‑day (without running the platform)

1. Log in to **Argo CD UI** on the **principal** (or `argocd` CLI with token).
2. Create an **Application** in project **`project-user1`**, with:
   - **destination**: `name: managed-cluster` (or admin-approved equivalent) and **namespace** allowed on `managed-cluster` (e.g. `user1-dev`).
   - **source**: Git repo allowed by `sourceRepos`.
3. Trigger synchronization or enable automated sync per project policy.

They **do not** configure: agent, Principal, certificates, `cluster` secrets, or GitOps operator.

---

## 4. Suggested customer demo script

1. Briefly show **cluster-admin** console: agents, platform namespaces.
2. Log in as **`user1`** on Argo CD: show admin menus are not available.
3. Create a demo application (e.g. `helm-guestbook`) targeting **`managed-cluster`** / team namespace.
4. Show sync and pods on **`managed-cluster`** in the target namespace.
5. Emphasize: **same pattern** for real workloads, within `AppProject` limits.

---

## 5. Common pitfalls

| Pitfall | Impact |
|---------|--------|
| `AppProject` too permissive (`*`) | `user1` may target other clusters or namespaces. |
| Inconsistent `sourceNamespaces` | Cannot create `Application` in the team namespace. |
| Sync SA without rights on `managed-cluster` | Sync **Failed** — often mistaken for “Argo CD is broken” when it is spoke RBAC. |
| Managed vs autonomous confusion | In **managed** mode, `Application` is created on the **hub**; telling users they create it “on managed-cluster” can be misleading — clarify in the demo. |

---

## 6. Useful links

- [AppProject — Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [RBAC — Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Red Hat — Argo CD Agent (blog)](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops)

---

## 7. Example manifests in this repository

| File | Purpose |
|------|---------|
| [`examples/appproject-project-user1.yaml`](examples/appproject-project-user1.yaml) | Draft `AppProject` `project-user1` (adapt). |
| [`examples/rbac-user1-applications-principal.yaml`](examples/rbac-user1-applications-principal.yaml) | `Role` / `RoleBinding` for `kubectl apply` of `Application` in `team-user1` on the **principal**. |

Remember to add **`team-user1`** to `sourceNamespaces` on the Argo CD instance (CR) and on `AppProject` `default` if you still use `default` in parallel — see product documentation for *Apps in any namespace*.

---

*Document provided for the multicluster PoV — adapt to your organization’s security policies.*

*French version: [`utilisateur-developpeur-user1.md`](utilisateur-developpeur-user1.md).*

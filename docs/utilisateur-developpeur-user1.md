# Utilisateur non `cluster-admin` — créer des applications (ex. `user1`)

Ce document décrit ce que le **platform admin** doit prévoir pour qu’un **développeur / responsable applicatif** (appelé ici **`user1`**) puisse **créer et gérer ses propres applications** Argo CD qui **déploient sur le cluster spoke `cluster1`**, en **mode Agent managed**, **sans** lui confier l’exploitation de l’agent, du Principal ni des certificats.

> **Point clé — mode managed**  
> La source de vérité des `Application` est le **cluster principal (hub)**. `user1` interagit donc avec **Argo CD sur le principal** (UI, CLI `argocd`, ou `kubectl` sur un namespace autorisé). Il ne « crée » pas l’`Application` uniquement sur `cluster1` au sens GitOps pur : le manifest `Application` vit sur le **hub** ; le **déploiement** des workloads a lieu **sur `cluster1`** via l’agent.  
> Si le client exige que `user1` ne touche **jamais** au principal, il faudrait plutôt le mode **autonomous** sur un spoke (hors scope de cette fiche, qui cible **managed + cluster1**).

---

## 1. Rôles et responsabilités

| Acteur | Rôle | Responsabilités |
|--------|------|-----------------|
| **Cluster-admin (plateforme)** | Installation et durcissement | Opérateur OpenShift GitOps, Principal, agents, PKI/mTLS, `AppProject`, intégration SSO/OAuth Argo CD, RBAC Kubernetes **et** RBAC Argo CD, namespaces d’équipe, quotas/NetworkPolicies, droits du **ServiceAccount** utilisé par Argo CD pour **sync** sur le spoke. |
| **`user1`** (développeur / product owner technique) | Consommateur Argo CD | Se connecter à Argo CD (hub), créer / mettre à jour **ses** `Application` dans **son** périmètre (projet + namespaces cibles), lancer ou automatiser la sync, consulter l’état — **sans** administrer le cluster ni l’agent. |
| **Argo CD (compte de sync)** | Automatique | Le contrôleur applicatif sur le spoke applique les manifests avec un **compte de service Kubernetes** (pas l’identité humaine de `user1`). C’est à la **plateforme** de donner à ce compte les droits sur les namespaces cibles. |

---

## 2. Ce que le cluster-admin doit mettre en place (une fois)

### 2.1 Identité de `user1`

- Créer un **utilisateur OpenShift** (ou groupe) pour `user1`, ou utiliser **OAuth / SSO** déjà branché sur le cluster **principal** où tourne Argo CD.
- Mapper cet utilisateur vers **Argo CD** (policy dans `argocd-rbac-cm` ou intégration OIDC selon votre modèle).

### 2.2 Namespace « applications » sur le **principal** (hub)

Les `Application` en *Apps in any namespace* doivent résider dans un namespace **déclaré** côté instance Argo CD (`spec.sourceNamespaces`) **et** autorisé dans l’`AppProject`.

Exemple de pattern :

- Namespace dédié : `team-user1` (ou `managed-cluster` partagé avec des contrôles plus fins).
- Le cluster-admin ajoute ce namespace aux `sourceNamespaces` de l’`ArgoCD` CR si nécessaire, et à l’`AppProject` (`spec.sourceNamespaces`).

### 2.3 `AppProject` dédié (recommandé)

Créer un **`AppProject`** (ex. `project-user1`) qui **limite** le périmètre de `user1` :

- **`sourceRepos`** : uniquement les dépôts Git autorisés pour son équipe (éviter `*` en production).
- **`destinations`** :  
  - `name: cluster1` (secret cluster enregistré sur le principal) **ou** l’URL du cluster si vous l’utilisez ainsi ;  
  - **namespaces** cibles sur `cluster1` : ex. `user1-dev`, `user1-int` — **pas** `*` en production.
- **`namespaceResourceWhitelist`** / **blacklist** selon votre politique (ce que l’app peut déployer).
- **`sourceNamespaces`** : liste des namespaces du **principal** où `user1` peut créer des `Application` (ex. `team-user1`).

Référence conceptuelle : modèle [AppProject](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/) Argo CD.

### 2.4 RBAC Argo CD (policy)

Dans la `ConfigMap` **`argocd-rbac-cm`** (namespace Argo CD sur le principal), définir un **rôle** du type `role:user1-developer` avec des droits **restreints** :

- Voir / créer / mettre à jour / supprimer les **applications** dans le projet `project-user1` uniquement.
- Pas d’accès aux **clusters** secrets, **repositories** globaux, **projets** des autres équipes, ni aux paramètres d’administration Argo CD.

Exemple de **lignes** (à adapter — la syntaxe exacte dépend de votre version Argo CD) :

```csv
p, role:user1-developer, applications, get, project-user1/*, allow
p, role:user1-developer, applications, create, project-user1/*, allow
p, role:user1-developer, applications, update, project-user1/*, allow
p, role:user1-developer, applications, delete, project-user1/*, allow
p, role:user1-developer, applications, sync, project-user1/*, allow
p, role:user1-developer, logs, get, project-user1/*, allow
g, user1, role:user1-developer
```

(La forme `g, user1, …` dépend du **claim** OIDC ou du nom d’utilisateur Argo CD ; alignez avec votre fournisseur d’identité.)

### 2.5 RBAC Kubernetes sur le **principal** (si `user1` utilise `kubectl`)

Si `user1` applique des manifests `Application` avec `kubectl` (ou l’API) :

- **`Role` + `RoleBinding`** dans le namespace d’équipe (ex. `team-user1`) pour les verbes `create/get/update/delete/list/watch` sur `applications.argoproj.io` (et `appprojects` en lecture si besoin).

Exemple minimal :

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

> Ajustez `kind: User` / `Group` selon votre fournisseur OpenShift.

### 2.6 Droits sur le **cluster1** (spoke) — compte de **sync**, pas `user1`

Le **déploiement** est effectué par le **application-controller** Argo CD (sur le spoke) / l’agent. Le cluster-admin doit s’assurer que le **ServiceAccount** utilisé pour appliquer les ressources sur `cluster1` dispose des droits sur les **namespaces cibles** (ex. `user1-dev`).

- Soit **ClusterRole** + **ClusterRoleBinding** (large, à éviter sauf PoV).
- Soit **Role** + **RoleBinding** par namespace cible (recommandé).

**`user1` n’a en principe pas besoin** de `cluster-admin` sur `cluster1` pour que la sync fonctionne. En revanche, si vous voulez que `user1` fasse du **debug** (`oc get pod` dans son namespace), donnez-lui un **Role** `view` ou `edit` **limité à ses namespaces** sur `cluster1`.

---

## 3. Ce que `user1` fait au quotidien (sans gérer l’infra)

1. Se connecter à l’**UI Argo CD** du **principal** (ou CLI `argocd` avec token).
2. Créer une **Application** dans le projet **`project-user1`**, avec :
   - **destination** : `name: cluster1` (ou équivalent validé par l’admin) et **namespace** autorisé sur `cluster1` (ex. `user1-dev`).
   - **source** : dépôt Git autorisé par `sourceRepos`.
3. Lancer la synchronisation ou activer la sync automatique selon la politique du projet.

Il **ne** configure **pas** : agent, Principal, certificats, `cluster` secrets, opérateur GitOps.

---

## 4. Démonstration « client » — script suggéré

1. Montrer la console **cluster-admin** : agents, namespaces plateforme (bref).
2. Se connecter en **`user1`** sur Argo CD : montrer que les menus d’administration ne sont pas accessibles.
3. Créer une application de démo (ex. `helm-guestbook`) pointant vers **`cluster1`** / namespace d’équipe.
4. Montrer la sync et les pods sur **`cluster1`** dans le namespace cible.
5. Insister : **même schéma** pour les vraies apps métier, dans les limites du `AppProject`.

---

## 5. Pièges courants

| Piège | Conséquence |
|-------|-------------|
| `AppProject` trop large (`*`) | `user1` peut cibler d’autres clusters ou namespaces. |
| Pas de `sourceNamespaces` cohérent | Impossible de créer l’`Application` dans le namespace d’équipe. |
| SA de sync sans droits sur `cluster1` | Sync en **Failed** — souvent vu comme « Argo CD ne marche pas » alors que c’est du RBAC spoke. |
| Confusion managed / autonomous | En **managed**, l’`Application` se crée sur le **hub** ; dire à l’utilisateur qu’il la crée « sur cluster1 » peut prêter à confusion — clarifier en démo. |

---

## 6. Liens utiles

- [AppProject — Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [RBAC — Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Red Hat — Argo CD Agent (blog)](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops)

---

## 7. Exemples de manifests dans ce dépôt

| Fichier | Usage |
|---------|--------|
| [`examples/appproject-project-user1.yaml`](examples/appproject-project-user1.yaml) | Esquisse d’`AppProject` `project-user1` (à adapter). |
| [`examples/rbac-user1-applications-principal.yaml`](examples/rbac-user1-applications-principal.yaml) | `Role` / `RoleBinding` pour `kubectl apply` d’`Application` dans `team-user1` sur le **principal**. |

N’oubliez pas d’ajouter **`team-user1`** aux `sourceNamespaces` de l’instance Argo CD (CR) et de l’`AppProject` `default` si vous utilisez encore le projet `default` en parallèle — voir la doc produit pour *Apps in any namespace*.

---

*Document fourni pour le PoV multicluster — à adapter aux politiques de sécurité de votre organisation.*

*English version: [`developer-user1.md`](developer-user1.md).*

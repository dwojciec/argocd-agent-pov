# PoV Argo CD Agent — Principal + managed-cluster (managed) + autonomous-cluster (autonomous)

*Version française du dépôt — la version anglaise (par défaut sur GitHub) est dans [`README.md`](README.md).*

Ce dépôt fournit les manifests et scripts pour valider **OpenShift GitOps / Argo CD Agent** sur trois clusters OpenShift distincts.

**Deux approches** sont possibles. **Avec Red Hat ACM (Advanced Cluster Management)**, l’intégration GitOps (`GitOpsCluster`, `Placement`, add-on GitOps et opérateurs associés) automatise une grande partie du câblage hub–spoke ; suivez [`ACM-implementation/README.md`](ACM-implementation/README.md) (en anglais) et, pour l’exemple guestbook déployé depuis le hub, la section ACM optionnelle du [`README.md`](README.md). **Sans ACM**, vous exécutez vous-même les **étapes une à une** — opérateurs, PKI, Helm, manifests — pour établir la communication entre le cluster **principal** et un ou plusieurs spokes **managed** (ou **autonomous**) ; ce parcours correspond au corps de ce guide et aux manuels détaillés liés juste après.

**Guide manuel détaillé (tâches T01–T60, explications pas à pas)** : [`Etape-par-etape.md`](Etape-par-etape.md) · *English:* [`step-by-step.md`](step-by-step.md).

**Utilisateur non `cluster-admin` (ex. `user1`) — créer des apps sur le spoke `managed-cluster` en mode managed** : rôles, `AppProject`, RBAC Argo CD / Kubernetes : [`docs/utilisateur-developpeur-user1.md`](docs/utilisateur-developpeur-user1.md) · *English:* [`docs/developer-user1.md`](docs/developer-user1.md).

| Cluster | Rôle | Mode agent |
|---------|------|------------|
| **principal** | Hub : UI Argo CD + composant **Principal** | — |
| **managed-cluster** | Spoke : **Agent en mode managed** | Le hub est la source de vérité des `Application` |
| **autonomous-cluster** | Spoke : **Agent en mode autonomous** | Les `Application` sont définies sur le spoke et remontées au hub |

Références utiles :

- [Using the Argo CD Agent with OpenShift GitOps (Red Hat)](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops)
- [Ep.15 OpenShift GitOps — Argo CD Agent (stderr.at)](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)
- [TLS & cert-manager (argocd-agent.readthedocs.io)](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/)

**Important** : ce dépôt est un **PoV** non production. Ajustez canaux d’opérateur, noms de services (resource-proxy, principal) et labels `NetworkPolicy` selon votre version d’OpenShift GitOps.

---

## Arborescence

```
argocd-agent-multicluster-pov/
├── README.md                  # English (default)
├── README-french.md           # cette page (FR)
├── Etape-par-etape.md         # procédure manuelle (FR)
├── step-by-step.md            # same (EN)
├── envsubst.env.example       # copier → envsubst.env (variables pour envsubst)
├── docs/
│   ├── validation-applications.md
│   ├── utilisateur-developpeur-user1.md  # RBAC / AppProject (FR)
│   └── developer-user1.md                # (EN)
├── principal/                 # Cluster PRINCIPAL (hub)
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
    ├── … (identique à managed-cluster côté base)
    ├── helm/values-autonomous.yaml.template
    ├── applications/sample-application-autonomous-cluster2.yaml
    └── scripts/
```

---

## Prérequis

- Trois clusters OpenShift (ou deux si vous ne testez que managed : principal + managed-cluster).
- Droits **cluster-admin** sur chaque cluster.
- `oc` / `kubectl` avec **trois contextes** nommés de façon stable, par exemple :

  ```bash
  oc config rename-context <ctx-principal> principal
  oc config rename-context <ctx-managed> managed-cluster
  oc config rename-context <ctx-autonomous> autonomous-cluster
  ```

- Binaire **`argocd-agentctl`** (PKI recommandée pour PoV) :
  - **Red Hat (recommandé avec l’opérateur OpenShift GitOps)** : téléchargement depuis le [Content Gateway — openshift-gitops](https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/) (dossiers **1.19.0**, **1.20.0**, etc. — choisir la version alignée sur votre OpenShift GitOps).
  - Amont : [releases argocd-agent (GitHub)](https://github.com/argoproj-labs/argocd-agent/releases).
- **Helm** ≥ 3.8 pour le chart `redhat-argocd-agent`.
- **Option B uniquement** : l’**opérateur cert-manager Operator for Red Hat OpenShift** doit être installé sur le cluster **principal** (et opérationnel) avant d’appliquer les manifests sous `principal/cert-manager`. Les scripts d’export restent dépendants de **jq** / **yq**.
- **`envsubst`** (souvent fourni par le paquet `gettext` sur Linux ; sur macOS : `brew install gettext` puis utiliser le binaire dans le PATH) pour substituer les variables `${…}` dans les fichiers `*.template`.

---

## Variables d’environnement et `envsubst`

Les manifests « modèles » utilisent la forme **`${NOM_VARIABLE}`** (compatible `envsubst`). Copiez l’exemple et chargez-le avant les commandes :

```bash
cp envsubst.env.example envsubst.env
# Éditez envsubst.env (PRINCIPAL_ROUTE_HOST, RESOURCE_PROXY_SERVER, etc.)
set -a && source envsubst.env && set +a
```

**Substitution ciblée** (recommandé si d’autres `$` apparaissent un jour dans les fichiers) :

```bash
envsubst '${PRINCIPAL_ROUTE_HOST}' < managed-cluster/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

**Substitution de toutes** les variables exportées :

```bash
envsubst < managed-cluster/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

Même principe pour `autonomous-cluster/helm/values-autonomous.yaml.template` et `principal/cert-manager/certificate-principal-tls.yaml.template`.

---

## Étape 0 — Contextes et chart Helm

```bash
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update
```

Récupérez sur le **principal** (après installation de l’Argo CD Principal) le **host HTTPS** de la Route du Principal :

```bash
oc config use-context principal
oc get route -n openshift-gitops
```

Notez l’**hôte seul** de la Route (sans `https://`, sans **`:443`** à la fin). Renseignez-le dans **`envsubst.env`** (`PRINCIPAL_ROUTE_HOST`) pour les `*.template`. Le chart **`redhat-argocd-agent`** attend `server` = hostname et **`serverPort`** pour le HTTPS (voir `helm show values` : `server` / `serverPort`) ; le template du dépôt suit ce schéma — ne pas passer `https://…` dans `server` sous peine d’erreurs de connexion type **`…:443:443` / too many colons** dans les logs de l’agent.

Découvrez le **nom DNS du service resource-proxy** (pour `argocd-agentctl` et les certificats) :

```bash
oc get svc -n openshift-gitops | grep -i resource-proxy
```

---

## Étape 1 — Cluster **principal**

### 1.1 Opérateur et namespaces

```bash
oc config use-context principal
oc apply -k principal/operator
```

Attendez que l’opérateur soit **Succeeded** (`oc get csv -n openshift-gitops-operator`).

```bash
oc apply -k principal/namespaces
```

### 1.2 Instance Argo CD + Principal

```bash
oc apply -k principal/argocd
```

### 1.3 AppProject `default` — `sourceNamespaces`

Les `Application` du hub utiliseront notamment le namespace `managed-cluster` :

```bash
chmod +x principal/appproject/patch-default-source-namespaces.sh
./principal/appproject/patch-default-source-namespaces.sh openshift-gitops
```

Redémarrez les pods Argo CD si la doc produit / votre environnement l’exige.

### 1.4 Secret Redis pour le Principal

Une fois le secret `argocd-redis-initial-password` présent :

```bash
chmod +x principal/scripts/bootstrap-redis-secret-principal.sh
./principal/scripts/bootstrap-redis-secret-principal.sh openshift-gitops
```

---

## Étape 2 — PKI et enregistrement des agents (managed-cluster + autonomous-cluster)

Deux approches possibles ; pour un PoV, **l’option A** est la plus simple.

### Option A — `argocd-agentctl` (recommandé PoV)

Les commandes **`pki propagate`** et **`pki issue agent …`** écrivent des secrets dans **`gitops-agent` (spoke managed)** ou **`argocd` (spoke autonomous)**. Ces namespaces doivent exister **avant** ces étapes. Le script ci‑dessous applique automatiquement `managed-cluster/namespaces` et `autonomous-cluster/namespaces` au début ; en **procédure manuelle** (sans script), faites-le avant T25 / T26 — voir [`Etape-par-etape.md`](Etape-par-etape.md) (encadré *Prérequis spokes*).

1. Définissez les variables (mêmes noms que dans `envsubst.env.example` : `PRINCIPAL_ROUTE_HOST`, `RESOURCE_PROXY_SERVER` = **host:port** du resource-proxy — voir `oc get svc -n openshift-gitops`).

   ```bash
   set -a && source envsubst.env && set +a
   export PRINCIPAL_CTX=principal
   export CLUSTER1_CTX=managed-cluster
   export CLUSTER2_CTX=autonomous-cluster
   ```

2. Exécutez le script (depuis ce répertoire ; les chemins `*/namespaces` sont résolus depuis l’emplacement du script) :

   ```bash
   chmod +x principal/scripts/bootstrap-argocd-agentctl.sh
   ./principal/scripts/bootstrap-argocd-agentctl.sh
   ```

Ce script : crée si besoin les namespaces spoke, initialise la CA, émet les certificats principal / resource-proxy, crée la clé JWT, crée les agents **`managed-cluster`** et **`autonomous-cluster`**, propage la CA et émet les certificats client sur chaque spoke.

### Option B — **cert-manager** (optionnel)

**Prérequis :** installer au préalable sur le cluster **principal** l’**opérateur cert-manager Operator for Red Hat OpenShift** (cert-manager pris en charge par Red Hat). Attendre que l’opérateur (CSV) soit en phase **Succeeded** et que les CRD du type `certificates.cert-manager.io` / `issuers.cert-manager.io` soient présentes (`oc get crd | grep cert-manager`). Sans cet opérateur, les ressources `Certificate` et `Issuer` du répertoire `principal/cert-manager/` ne seront pas prises en charge.

1. Générez une CA hors cluster (openssl) et créez le secret TLS `argocd-agent-ca` dans `openshift-gitops` (voir [documentation TLS](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/#using-cert-manager)).
2. Avec `PRINCIPAL_ROUTE_HOST` exporté :  
   `envsubst < principal/cert-manager/certificate-principal-tls.yaml.template | oc apply -f -`
3. `oc apply -k principal/cert-manager`
4. Attendez `READY=True` sur les `Certificate`.
5. Créez encore le secret **`argocd-agent-jwt`** (par ex. uniquement `argocd-agentctl jwt create-key` sur le principal, ou procédure manuelle openssl de la doc).
6. Pour chaque agent :

   ```bash
   ./principal/scripts/create-cluster-secret-certmanager.sh managed-cluster managed-cluster-principal
   ./principal/scripts/create-cluster-secret-certmanager.sh autonomous-cluster autonomous-cluster-principal
   ```

7. Exportez vers chaque spoke :

   ```bash
   chmod +x principal/scripts/export-certmanager-secrets-to-spoke.sh
   ./principal/scripts/export-certmanager-secrets-to-spoke.sh managed-cluster-agent ./exported/managed-cluster
   oc apply -f ./exported/managed-cluster/ --context managed-cluster

   ./principal/scripts/export-certmanager-secrets-to-spoke.sh autonomous-cluster-agent ./exported/autonomous-cluster
   oc apply -f ./exported/autonomous-cluster/ --context autonomous-cluster
   ```

---

## Étape 3 — Cluster **managed-cluster** (managed)

Toutes les commandes ci-dessous : **`oc config use-context managed-cluster`** (sauf indication).

### 3.1 Opérateur, namespace, Argo CD workload

Si vous avez déjà appliqué `managed-cluster/namespaces` avant l’étape PKI (voir **Étape 2**), la ligne `oc apply -k managed-cluster/namespaces` est **idempotente**.

```bash
oc config use-context managed-cluster
oc apply -k managed-cluster/operator
# Indispensable avant managed-cluster/argocd : l’opérateur doit avoir posé les CRD (sinon : no matches for kind "ArgoCD")
until oc get crd argocds.argoproj.io &>/dev/null; do echo "Attente CRD ArgoCD…"; sleep 5; done
oc apply -k managed-cluster/namespaces
oc apply -k managed-cluster/argocd
```

Si vous voyez `ensure CRDs are installed first`, ce n’est **pas** parce que le namespace `gitops-agent` existait déjà : allongez l’attente après `managed-cluster/operator` (ex. `oc get csv -n openshift-gitops-operator` jusqu’à **Succeeded**).

### 3.2 Secret Redis local

```bash
chmod +x managed-cluster/scripts/bootstrap-redis-secret-agent.sh
./managed-cluster/scripts/bootstrap-redis-secret-agent.sh gitops-agent
```

### 3.3 NetworkPolicy Agent → Redis

```bash
oc apply -k managed-cluster/networkpolicy
```

Si le pod Redis n’a pas le label `app.kubernetes.io/name=argocd-redis`, adaptez `managed-cluster/networkpolicy/allow-agent-to-redis.yaml` après `oc get pods -n gitops-agent --show-labels`.

### 3.4 Helm — Agent **managed**

Avec `PRINCIPAL_ROUTE_HOST` défini (fichier `envsubst.env` + `set -a && source envsubst.env && set +a`) :

```bash
envsubst < managed-cluster/helm/values-managed.yaml.template | \
  helm install argocd-agent-managed openshift-helm-charts/redhat-argocd-agent \
    --kube-context managed-cluster \
    --namespace gitops-agent \
    -f -
```

(Alternative : générer un fichier `values-managed.yaml` via `envsubst < …template > values-managed.yaml` puis `helm install … -f values-managed.yaml`.)

---

## Étape 4 — Validation **managed** (principal → managed-cluster)

Une application de test **minimale** est prévue : chart Helm **`helm-guestbook`** du dépôt public [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps) (quelques ressources dans le namespace cible). Détail et critères : [`docs/validation-applications.md`](docs/validation-applications.md).

Sur le **principal** :

```bash
oc apply -f principal/applications/sample-application-managed-cluster1.yaml
```

Vérifiez sur le hub : `Application` **`sample-managed-demo`** dans le namespace **`managed-cluster`**, destination **`name: managed-cluster`**, statut **Synced** / **Healthy**. Sur le spoke **managed-cluster** : `oc get deploy,svc -n default` — déploiement / service issus du chart (noms variables selon la release Helm du guestbook).

---

## Étape 5 — Cluster **autonomous-cluster** (autonomous)

Si `autonomous-cluster/namespaces` a déjà été appliqué avant la PKI, l’étape namespaces reste **idempotente**.

```bash
oc config use-context autonomous-cluster
oc apply -k autonomous-cluster/operator
until oc get crd argocds.argoproj.io &>/dev/null; do echo "Attente CRD ArgoCD…"; sleep 5; done
oc apply -k autonomous-cluster/namespaces
oc apply -k autonomous-cluster/argocd
chmod +x autonomous-cluster/scripts/bootstrap-redis-secret-agent.sh
./autonomous-cluster/scripts/bootstrap-redis-secret-agent.sh argocd
oc apply -k autonomous-cluster/networkpolicy
```

Avec `PRINCIPAL_ROUTE_HOST` chargé (`set -a && source envsubst.env && set +a`) :

```bash
envsubst < autonomous-cluster/helm/values-autonomous.yaml.template | \
  helm install argocd-agent-autonomous openshift-helm-charts/redhat-argocd-agent \
    --kube-context autonomous-cluster \
    --namespace argocd \
    -f -
```

---

## Étape 6 — Validation **autonomous** (autonomous-cluster)

Même démo **`helm-guestbook`** que pour le managed (fichier et critères : [`docs/validation-applications.md`](docs/validation-applications.md)). Déployez l’`Application` **sur autonomous-cluster** (pas sur le principal) :

```bash
oc apply -f autonomous-cluster/applications/sample-application-autonomous-cluster2.yaml --context autonomous-cluster
```

Le `destination.server` doit être `https://kubernetes.default.svc`. Après synchronisation : sur **autonomous-cluster**, `oc get application sample-autonomous-demo -n argocd` en **Synced** / **Healthy** ; l’application doit aussi être visible **depuis l’UI du principal** (observabilité) selon le mode autonomous ([détails](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)).

---

## Récapitulatif « où exécuter quoi »

| Action | Cluster / contexte |
|--------|---------------------|
| `oc apply -k principal/…` | **principal** |
| `bootstrap-argocd-agentctl.sh`, patch AppProject, `Application` managed | **principal** (le script crée d’abord les namespaces spoke requis ; la PKI touche managed-cluster / autonomous-cluster via les contextes) |
| `oc apply -k managed-cluster/…`, Helm managed | **managed-cluster** |
| `oc apply -k autonomous-cluster/…`, Helm autonomous | **autonomous-cluster** |
| `sample-application-managed-cluster1.yaml` | **principal** (namespace hub `managed-cluster` pour l’`Application`) |
| `sample-application-autonomous-cluster2.yaml` | **autonomous-cluster** (namespace `argocd`) |

---

## Dépannage rapide

- **« namespaces … not found » avec `argocd-agentctl pki propagate` / `pki issue agent`** : créer les namespaces sur les spokes (`oc apply -k managed-cluster/namespaces --context managed-cluster`, idem `autonomous-cluster`) **avant** ces commandes, ou utiliser le script `bootstrap-argocd-agentctl.sh` qui le fait automatiquement — détail : [`Etape-par-etape.md`](Etape-par-etape.md) (Phase 2A).
- **`no matches for kind "ArgoCD"` / `ensure CRDs are installed first` sur managed-cluster ou autonomous-cluster** : attendre que l’opérateur OpenShift GitOps soit **Succeeded** (CRD `argocds.argoproj.io` présent) **avant** `oc apply -k managed-cluster/argocd` ou `autonomous-cluster/argocd`. Ce n’est pas lié au message `namespace/… unchanged`.
- **Principal CrashLoop — secrets TLS manquants** : finaliser la section PKI (Option A ou B) ; vérifier `oc get certificate -n openshift-gitops` si cert-manager.
- **Agent ne joint pas Redis** : NetworkPolicy, labels Redis/Agent, secret `argocd-redis` sur le spoke.
- **Agent : `too many colons in address` / `…:443:443`** : le chart sépare **`server`** (hostname seul) et **`serverPort`** (`443`). Corrigez `managed-cluster/helm/values-managed.yaml.template` (dépôt à jour) puis `helm upgrade … -f` avec `PRINCIPAL_ROUTE_HOST` **sans** `https://` ni `:443`.
- **`helm template … | grep` ne renvoie rien** : ne pas rediriger stderr vers `/dev/null` tant que vous déboguez ; vérifier `helm search repo redhat-argocd-agent` et `helm repo add openshift-helm-charts https://charts.openshift.io/`. Utiliser `grep -F "agent.server.address"` (chaîne littérale) plutôt qu’une regex fragile — voir T33 dans [`Etape-par-etape.md`](Etape-par-etape.md).
- **`serverPort: Invalid type. Expected: string, given: integer`** : avec `--set serverPort=443`, Helm envoie un **entier** ; le schéma du chart exige une **chaîne**. Utiliser **`--set-string serverPort=443`** (ou dans un fichier values YAML : `serverPort: "443"` comme dans les `*.template` du dépôt).
- **Chart Helm / valeurs** : comparer avec [stderr.at — Helm redhat-argocd-agent](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/) (paramètres `server`, `serverPort`, `redisAddress`, secrets Redis).
- **Limitations OpenShift** (Route, LoadBalancer, NetworkPolicy) : voir [blog Red Hat — Limitations](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops).

---

## Licence

Fichiers fournis pour démonstration interne PoV ; adaptez les politiques de sécurité et la PKI à votre organisation.

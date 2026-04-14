# PoV Argo CD Agent — Principal + cluster1 (managed) + cluster2 (autonomous)

Ce dépôt fournit les manifests et scripts pour valider **OpenShift GitOps / Argo CD Agent** sur trois clusters OpenShift distincts.

**Guide manuel détaillé (tâches T01–T60, explications pas à pas)** : [`Etape-par-etape.md`](Etape-par-etape.md) · *English:* [`step-by-step.md`](step-by-step.md).

**Utilisateur non `cluster-admin` (ex. `user1`) — créer des apps sur `cluster1` en mode managed** : rôles, `AppProject`, RBAC Argo CD / Kubernetes : [`docs/utilisateur-developpeur-user1.md`](docs/utilisateur-developpeur-user1.md) · *English:* [`docs/developer-user1.md`](docs/developer-user1.md).

| Cluster | Rôle | Mode agent |
|---------|------|------------|
| **principal** | Hub : UI Argo CD + composant **Principal** | — |
| **cluster1** | Spoke : **Agent en mode managed** | Le hub est la source de vérité des `Application` |
| **cluster2** | Spoke : **Agent en mode autonomous** | Les `Application` sont définies sur le spoke et remontées au hub |

Références utiles :

- [Using the Argo CD Agent with OpenShift GitOps (Red Hat)](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops)
- [Ep.15 OpenShift GitOps — Argo CD Agent (stderr.at)](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)
- [TLS & cert-manager (argocd-agent.readthedocs.io)](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/)

**Important** : ce dépôt est un **PoV** non production. Ajustez canaux d’opérateur, noms de services (resource-proxy, principal) et labels `NetworkPolicy` selon votre version d’OpenShift GitOps.

---

## Arborescence

```
argocd-agent-multicluster-pov/
├── README.md
├── Etape-par-etape.md          # procédure manuelle (FR)
├── step-by-step.md             # same (EN)
├── envsubst.env.example        # copier → envsubst.env (variables pour envsubst)
├── docs/
│   ├── validation-applications.md   # Détail des apps de test managed / autonomous
│   ├── utilisateur-developpeur-user1.md  # RBAC / AppProject (FR)
│   └── developer-user1.md        # same (EN)
├── principal/                 # Cluster PRINCIPAL (hub)
│   ├── operator/              # OperatorGroup + Subscription OpenShift GitOps
│   ├── namespaces/            # argocd, managed-cluster
│   ├── argocd/                # ArgoCD CR (Principal, controller désactivé)
│   ├── cert-manager/          # Optionnel — Issuer + Certificates (+ certificate-principal-tls.yaml.template)
│   ├── applications/          # Application de test managed (helm-guestbook)
│   ├── appproject/            # Script patch AppProject default
│   └── scripts/               # PKI argocd-agentctl, Redis principal, secrets cluster (cert-manager)
├── cluster1/                  # Spoke managed
│   ├── operator/
│   ├── namespaces/
│   ├── argocd/                # ArgoCD minimal (server désactivé)
│   ├── networkpolicy/
│   ├── helm/values-managed.yaml.template
│   └── scripts/
└── cluster2/                  # Spoke autonomous
    ├── … (identique à cluster1 côté base)
    ├── helm/values-autonomous.yaml.template
    ├── applications/sample-application-autonomous-cluster2.yaml  # test autonomous (helm-guestbook)
    └── scripts/
```

---

## Prérequis

- Trois clusters OpenShift (ou deux si vous ne testez que managed : principal + cluster1).
- Droits **cluster-admin** sur chaque cluster.
- `oc` / `kubectl` avec **trois contextes** nommés de façon stable, par exemple :

  ```bash
  oc config rename-context <ctx-principal> principal
  oc config rename-context <ctx-cluster1> cluster1
  oc config rename-context <ctx-cluster2> cluster2
  ```

- Binaire **`argocd-agentctl`** (PKI recommandée pour PoV) :
  - **Red Hat (recommandé avec l’opérateur OpenShift GitOps)** : téléchargement depuis le [Content Gateway — openshift-gitops](https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/) (dossiers **1.19.0**, **1.20.0**, etc. — choisir la version alignée sur votre OpenShift GitOps).
  - Amont : [releases argocd-agent (GitHub)](https://github.com/argoproj-labs/argocd-agent/releases).
- **Helm** ≥ 3.8 pour le chart `redhat-argocd-agent`.
- Optionnel : **cert-manager** installé sur le principal + **jq** / **yq** pour les scripts cert-manager.
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
envsubst '${PRINCIPAL_ROUTE_HOST}' < cluster1/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

**Substitution de toutes** les variables exportées :

```bash
envsubst < cluster1/helm/values-managed.yaml.template > /tmp/values-managed.yaml
```

Même principe pour `cluster2/helm/values-autonomous.yaml.template` et `principal/cert-manager/certificate-principal-tls.yaml.template`.

---

## Étape 0 — Contextes et chart Helm

```bash
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update
```

Récupérez sur le **principal** (après installation de l’Argo CD Principal) le **host HTTPS** de la Route du Principal :

```bash
oc config use-context principal
oc get route -n argocd
```

Notez l’**hôte seul** de la Route (sans `https://`), par ex. `argocd-agent-principal-argocd.apps.cluster.example.com`. Renseignez-le dans **`envsubst.env`** (variable `PRINCIPAL_ROUTE_HOST`) pour générer les fichiers Helm et cert-manager à partir des `*.template`.

Découvrez le **nom DNS du service resource-proxy** (pour `argocd-agentctl` et les certificats) :

```bash
oc get svc -n argocd | grep -i resource-proxy
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
./principal/appproject/patch-default-source-namespaces.sh argocd
```

Redémarrez les pods Argo CD si la doc produit / votre environnement l’exige.

### 1.4 Secret Redis pour le Principal

Une fois le secret `argocd-redis-initial-password` présent :

```bash
chmod +x principal/scripts/bootstrap-redis-secret-principal.sh
./principal/scripts/bootstrap-redis-secret-principal.sh argocd
```

---

## Étape 2 — PKI et enregistrement des agents (cluster1 + cluster2)

Deux approches possibles ; pour un PoV, **l’option A** est la plus simple.

### Option A — `argocd-agentctl` (recommandé PoV)

Les commandes **`pki propagate`** et **`pki issue agent …`** écrivent des secrets dans le namespace **`argocd` sur chaque spoke**. Ce namespace doit donc exister sur **cluster1** et **cluster2** avant ces étapes. Le script ci‑dessous applique automatiquement `cluster1/namespaces` et `cluster2/namespaces` au début ; en **procédure manuelle** (sans script), faites-le avant T25 / T26 — voir [`Etape-par-etape.md`](Etape-par-etape.md) (encadré *Prérequis spokes*).

1. Définissez les variables (mêmes noms que dans `envsubst.env.example` : `PRINCIPAL_ROUTE_HOST`, `RESOURCE_PROXY_SERVER` = **host:port** du resource-proxy — voir `oc get svc -n argocd`).

   ```bash
   set -a && source envsubst.env && set +a
   export PRINCIPAL_CTX=principal
   export CLUSTER1_CTX=cluster1
   export CLUSTER2_CTX=cluster2
   ```

2. Exécutez le script (depuis ce répertoire ; les chemins `cluster*/namespaces` sont résolus depuis l’emplacement du script) :

   ```bash
   chmod +x principal/scripts/bootstrap-argocd-agentctl.sh
   ./principal/scripts/bootstrap-argocd-agentctl.sh
   ```

Ce script : crée si besoin les namespaces spoke, initialise la CA, émet les certificats principal / resource-proxy, crée la clé JWT, crée les agents **`cluster1`** et **`cluster2`**, propage la CA et émet les certificats client sur **cluster1** et **cluster2**.

### Option B — **cert-manager** (optionnel)

1. Générez une CA hors cluster (openssl) et créez le secret TLS `argocd-agent-ca` dans `argocd` (voir [documentation TLS](https://argocd-agent.readthedocs.io/latest/configuration/tls-certificates/#using-cert-manager)).
2. Avec `PRINCIPAL_ROUTE_HOST` exporté :  
   `envsubst < principal/cert-manager/certificate-principal-tls.yaml.template | oc apply -f -`
3. `oc apply -k principal/cert-manager`
4. Attendez `READY=True` sur les `Certificate`.
5. Créez encore le secret **`argocd-agent-jwt`** (par ex. uniquement `argocd-agentctl jwt create-key` sur le principal, ou procédure manuelle openssl de la doc).
6. Pour chaque agent :

   ```bash
   ./principal/scripts/create-cluster-secret-certmanager.sh cluster1 cluster1-principal
   ./principal/scripts/create-cluster-secret-certmanager.sh cluster2 cluster2-principal
   ```

7. Exportez vers chaque spoke :

   ```bash
   chmod +x principal/scripts/export-certmanager-secrets-to-spoke.sh
   ./principal/scripts/export-certmanager-secrets-to-spoke.sh cluster1-agent ./exported/cluster1
   oc apply -f ./exported/cluster1/ --context cluster1

   ./principal/scripts/export-certmanager-secrets-to-spoke.sh cluster2-agent ./exported/cluster2
   oc apply -f ./exported/cluster2/ --context cluster2
   ```

---

## Étape 3 — Cluster **cluster1** (managed)

Toutes les commandes ci-dessous : **`oc config use-context cluster1`** (sauf indication).

### 3.1 Opérateur, namespace, Argo CD workload

Si vous avez déjà appliqué `cluster1/namespaces` avant l’étape PKI (voir **Étape 2**), la ligne `oc apply -k cluster1/namespaces` est **idempotente**.

```bash
oc config use-context cluster1
oc apply -k cluster1/operator
# Attendre le CSV Succeeded
oc apply -k cluster1/namespaces
oc apply -k cluster1/argocd
```

### 3.2 Secret Redis local

```bash
chmod +x cluster1/scripts/bootstrap-redis-secret-agent.sh
./cluster1/scripts/bootstrap-redis-secret-agent.sh argocd
```

### 3.3 NetworkPolicy Agent → Redis

```bash
oc apply -k cluster1/networkpolicy
```

Si le pod Redis n’a pas le label `app.kubernetes.io/name=argocd-redis`, adaptez `cluster1/networkpolicy/allow-agent-to-redis.yaml` après `oc get pods -n argocd --show-labels`.

### 3.4 Helm — Agent **managed**

Avec `PRINCIPAL_ROUTE_HOST` défini (fichier `envsubst.env` + `set -a && source envsubst.env && set +a`) :

```bash
envsubst < cluster1/helm/values-managed.yaml.template | \
  helm install argocd-agent-managed openshift-helm-charts/redhat-argocd-agent \
    --kube-context cluster1 \
    -f -
```

(Alternative : générer un fichier `values-managed.yaml` via `envsubst < …template > values-managed.yaml` puis `helm install … -f values-managed.yaml`.)

---

## Étape 4 — Validation **managed** (principal + cluster1)

Une application de test **minimale** est prévue : chart Helm **`helm-guestbook`** du dépôt public [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps) (quelques ressources dans le namespace cible). Détail et critères : [`docs/validation-applications.md`](docs/validation-applications.md).

Sur le **principal** :

```bash
oc apply -f principal/applications/sample-application-managed-cluster1.yaml
```

Vérifiez sur le hub : `Application` `sample-managed-cluster1` dans le namespace `managed-cluster`, destination `name: cluster1`, statut **Synced** / **Healthy**. Sur **cluster1** : `oc get deploy,svc -n default` — déploiement / service issus du chart (noms variables selon la release Helm du guestbook).

---

## Étape 5 — Cluster **cluster2** (autonomous)

Si `cluster2/namespaces` a déjà été appliqué avant la PKI, l’étape namespaces reste **idempotente**.

```bash
oc config use-context cluster2
oc apply -k cluster2/operator
oc apply -k cluster2/namespaces
oc apply -k cluster2/argocd
chmod +x cluster2/scripts/bootstrap-redis-secret-agent.sh
./cluster2/scripts/bootstrap-redis-secret-agent.sh argocd
oc apply -k cluster2/networkpolicy
```

Avec `PRINCIPAL_ROUTE_HOST` chargé (`set -a && source envsubst.env && set +a`) :

```bash
envsubst < cluster2/helm/values-autonomous.yaml.template | \
  helm install argocd-agent-autonomous openshift-helm-charts/redhat-argocd-agent \
    --kube-context cluster2 \
    -f -
```

---

## Étape 6 — Validation **autonomous** (cluster2)

Même démo **`helm-guestbook`** que pour le managed (fichier et critères : [`docs/validation-applications.md`](docs/validation-applications.md)). Déployez l’`Application` **sur cluster2** (pas sur le principal) :

```bash
oc apply -f cluster2/applications/sample-application-autonomous-cluster2.yaml --context cluster2
```

Le `destination.server` doit être `https://kubernetes.default.svc`. Après synchronisation : sur **cluster2**, `oc get application sample-autonomous-cluster2 -n argocd` en **Synced** / **Healthy** ; l’application doit aussi être visible **depuis l’UI du principal** (observabilité) selon le mode autonomous ([détails](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/)).

---

## Récapitulatif « où exécuter quoi »

| Action | Cluster / contexte |
|--------|---------------------|
| `oc apply -k principal/…` | **principal** |
| `bootstrap-argocd-agentctl.sh`, patch AppProject, `Application` managed | **principal** (le script crée d’abord les namespaces `argocd` sur les spokes ; la PKI touche cluster1/cluster2 via les contextes) |
| `oc apply -k cluster1/…`, Helm managed | **cluster1** |
| `oc apply -k cluster2/…`, Helm autonomous | **cluster2** |
| `sample-application-managed-cluster1.yaml` | **principal** (namespace `managed-cluster`) |
| `sample-application-autonomous-cluster2.yaml` | **cluster2** (namespace `argocd`) |

---

## Dépannage rapide

- **`namespaces "argocd" not found` avec `argocd-agentctl pki propagate` / `pki issue agent`** : créer le namespace sur le spoke concerné (`oc apply -k cluster1/namespaces --context cluster1`, idem `cluster2`) **avant** ces commandes, ou utiliser le script `bootstrap-argocd-agentctl.sh` qui le fait automatiquement — détail : [`Etape-par-etape.md`](Etape-par-etape.md) (Phase 2A).
- **Principal CrashLoop — secrets TLS manquants** : finaliser la section PKI (Option A ou B) ; vérifier `oc get certificate -n argocd` si cert-manager.
- **Agent ne joint pas Redis** : NetworkPolicy, labels Redis/Agent, secret `argocd-redis` sur le spoke.
- **Chart Helm / valeurs** : comparer avec [stderr.at — Helm redhat-argocd-agent](https://blog.stderr.at/gitopscollection/2026-01-14-argocd-agent/) (paramètres `server`, `redisAddress`, secrets Redis).
- **Limitations OpenShift** (Route, LoadBalancer, NetworkPolicy) : voir [blog Red Hat — Limitations](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops).

---

## Licence

Fichiers fournis pour démonstration interne PoV ; adaptez les politiques de sécurité et la PKI à votre organisation.

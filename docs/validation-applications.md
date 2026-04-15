# Applications de test — managed vs autonomous

Les manifests suivants déploient la même démo **légère** ([`helm-guestbook`](https://github.com/argoproj/argocd-example-apps/tree/master/helm-guestbook) dans [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps)) : un chart Helm minimal (une `Deployment` + `Service`), adapté à un test de bout en bout sans bruit inutile.

| Mode | Fichier | Où appliquer | Rôle |
|------|---------|--------------|------|
| **Managed** | `principal/applications/sample-application-managed-cluster1.yaml` | Contexte **principal** | Source de vérité sur le hub ; sync vers **managed-cluster** via `destination.name: managed-cluster` |
| **Autonomous** | `autonomous-cluster/applications/sample-application-autonomous-cluster2.yaml` | Contexte **autonomous-cluster** | Source de vérité sur le spoke ; `destination.server: https://kubernetes.default.svc` |

## Critères de réussite rapides

1. **Managed (principal → managed-cluster)**  
   - Sur le principal : `oc get application sample-managed-demo -n managed-cluster` → `Synced` / `Healthy`.  
   - Sur managed-cluster : `oc get deploy,svc -n default` → ressources `helm-guestbook` présentes (noms dépendant du chart).

2. **Autonomous (autonomous-cluster → visible hub)**  
   - Sur autonomous-cluster : `oc get application sample-autonomous-demo -n argocd` → `Synced` / `Healthy`.  
   - Sur le principal (UI ou CLI) : l’application apparaît pour observation selon le mode autonomous (voir doc produit).

Si vous préférez l’exemple **Kustomize** « guestbook » classique (plus de ressources), remplacez dans les `Application` : `path: helm-guestbook` par `path: guestbook`.

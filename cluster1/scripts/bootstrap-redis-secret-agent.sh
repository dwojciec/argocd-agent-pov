#!/usr/bin/env bash
# Secret Redis pour l’instance Argo CD locale (cluster workload). À lancer sur CLUSTER1 ou CLUSTER2.
set -euo pipefail
NS="${1:-argocd}"

PW="$(oc get secret argocd-redis-initial-password -n "${NS}" -o jsonpath='{.data.admin\.password}' | base64 -d)"
oc create secret generic argocd-redis -n "${NS}" --from-literal=auth="${PW}" \
  --dry-run=client -o yaml | oc apply -f -

#!/usr/bin/env bash
# Secret Redis pour l’instance Argo CD locale (cluster workload). À lancer sur le spoke managed ou autonomous.
set -euo pipefail
NS="${1:-gitops-agent}"

PW="$(oc get secret argocd-redis-initial-password -n "${NS}" -o jsonpath='{.data.admin\.password}' | base64 -d)"
oc create secret generic argocd-redis -n "${NS}" --from-literal=auth="${PW}" \
  --dry-run=client -o yaml | oc apply -f -

#!/usr/bin/env bash
# Crée le secret Redis attendu par le Principal (à lancer sur le cluster PRINCIPAL).
set -euo pipefail
NS="${1:-gitops-control-plane}"

PW="$(oc get secret argocd-redis-initial-password -n "${NS}" -o jsonpath='{.data.admin\.password}' | base64 -d)"
oc create secret generic argocd-redis -n "${NS}" --from-literal=auth="${PW}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Redémarrage du déploiement Principal (adapter le nom si besoin)..."
oc rollout restart deployment -n "${NS}" -l app.kubernetes.io/name=argocd-agent-principal 2>/dev/null || \
  oc rollout restart deployment -n "${NS}" "$(oc get deploy -n "${NS}" -o name | grep -E 'agent-principal|gitops-agent-principal' | head -1)"

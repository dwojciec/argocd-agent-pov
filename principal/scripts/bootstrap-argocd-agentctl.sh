#!/usr/bin/env bash
# PKI et enregistrement des agents avec argocd-agentctl (cluster PRINCIPAL + contextes kubectl).
# Prérequis : binaire argocd-agentctl, oc configuré avec les contextes PRINCIPAL / CLUSTER1 / CLUSTER2.
# Le script applique d’abord cluster{1,2}/namespaces (namespace argocd sur les spokes) : sans cela,
# pki propagate / pki issue agent échouent avec « namespaces "argocd" not found ».
#
# Usage :
#   export PRINCIPAL_CTX=principal
#   export CLUSTER1_CTX=cluster1
#   export CLUSTER2_CTX=cluster2
#   export PRINCIPAL_NS=argocd
#   export PRINCIPAL_ROUTE_HOST=argocd-agent-principal-argocd.apps.example.com
#   export RESOURCE_PROXY_SERVER=argocd-agent-principal-resource-proxy.argocd.svc.cluster.local:9090
#   ./bootstrap-argocd-agentctl.sh
#
# Adaptez PRINCIPAL_ROUTE_HOST et RESOURCE_PROXY_SERVER (host:port du resource-proxy).
set -euo pipefail

PRINCIPAL_CTX="${PRINCIPAL_CTX:-principal}"
CLUSTER1_CTX="${CLUSTER1_CTX:-cluster1}"
CLUSTER2_CTX="${CLUSTER2_CTX:-cluster2}"
PRINCIPAL_NS="${PRINCIPAL_NS:-argocd}"

: "${PRINCIPAL_ROUTE_HOST:?Définir PRINCIPAL_ROUTE_HOST (host de la Route Principal)}"
: "${RESOURCE_PROXY_SERVER:?Définir RESOURCE_PROXY_SERVER (host:port du service resource-proxy, ex. svc:9090)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo ">>> Namespaces spoke (argocd) — prérequis pour pki propagate / issue agent"
oc apply -k "${REPO_ROOT}/cluster1/namespaces" --context "${CLUSTER1_CTX}"
oc apply -k "${REPO_ROOT}/cluster2/namespaces" --context "${CLUSTER2_CTX}"

echo ">>> Init PKI (CA) sur ${PRINCIPAL_CTX}"
argocd-agentctl pki init --principal-context "${PRINCIPAL_CTX}" --principal-namespace "${PRINCIPAL_NS}"

echo ">>> Certificat Principal (gRPC)"
argocd-agentctl pki issue principal \
  --principal-context "${PRINCIPAL_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --dns "localhost,argocd-agent-principal.${PRINCIPAL_NS}.svc.cluster.local,${PRINCIPAL_ROUTE_HOST}" \
  --upsert

echo ">>> Certificat resource-proxy"
RP_HOST="${RESOURCE_PROXY_SERVER%%:*}"
argocd-agentctl pki issue resource-proxy \
  --principal-context "${PRINCIPAL_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --dns "localhost,${RP_HOST}" \
  --upsert

echo ">>> JWT signing key"
argocd-agentctl jwt create-key \
  --principal-context "${PRINCIPAL_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --upsert

echo ">>> Secret cluster + certificats agent — cluster1 (managed)"
argocd-agentctl agent create cluster1 \
  --principal-context "${PRINCIPAL_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --resource-proxy-server "${RESOURCE_PROXY_SERVER}"

argocd-agentctl pki propagate \
  --principal-context "${PRINCIPAL_CTX}" \
  --agent-context "${CLUSTER1_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --agent-namespace "${PRINCIPAL_NS}"

argocd-agentctl pki issue agent cluster1 \
  --principal-context "${PRINCIPAL_CTX}" \
  --agent-context "${CLUSTER1_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --agent-namespace "${PRINCIPAL_NS}" \
  --upsert

echo ">>> Secret cluster + certificats agent — cluster2 (autonomous)"
argocd-agentctl agent create cluster2 \
  --principal-context "${PRINCIPAL_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --resource-proxy-server "${RESOURCE_PROXY_SERVER}"

argocd-agentctl pki propagate \
  --principal-context "${PRINCIPAL_CTX}" \
  --agent-context "${CLUSTER2_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --agent-namespace "${PRINCIPAL_NS}"

argocd-agentctl pki issue agent cluster2 \
  --principal-context "${PRINCIPAL_CTX}" \
  --agent-context "${CLUSTER2_CTX}" \
  --principal-namespace "${PRINCIPAL_NS}" \
  --agent-namespace "${PRINCIPAL_NS}" \
  --upsert

echo "Terminé. Vérifiez les secrets argocd-agent-* sur le principal et les spokes."

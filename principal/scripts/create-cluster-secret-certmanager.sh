#!/usr/bin/env bash
# Construit le secret Argo CD cluster-<name> à partir d’un secret TLS cert-manager (principal).
# Prérequis : jq, oc
# Usage : ./create-cluster-secret-certmanager.sh cluster1 cluster1-principal
#         Variable optionnelle PROXY_SVC (défaut ci-dessous, host:port du resource-proxy).
set -euo pipefail
NAME="${1:?nom logique agent (ex: cluster1)}"
TLS_SECRET="${2:?nom du secret TLS (ex: cluster1-principal)}"
NS="${3:-argocd}"
PROXY_SVC="${PROXY_SVC:-argocd-agent-resource-proxy.argocd.svc.cluster.local:9090}"

AGENT_CA_B64="$(oc get secret "${TLS_SECRET}" -n "${NS}" -o jsonpath='{.data.ca\.crt}')"
AGENT_TLS_B64="$(oc get secret "${TLS_SECRET}" -n "${NS}" -o jsonpath='{.data.tls\.crt}')"
AGENT_KEY_B64="$(oc get secret "${TLS_SECRET}" -n "${NS}" -o jsonpath='{.data.tls\.key}')"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

jq -n \
  --arg cert "${AGENT_TLS_B64}" \
  --arg key "${AGENT_KEY_B64}" \
  --arg ca "${AGENT_CA_B64}" \
  '{
    username: "argocd-agent",
    password: "unused",
    tlsClientConfig: {
      insecure: false,
      certData: $cert,
      keyData: $key,
      caData: $ca
    }
  }' > "${TMP}"

oc create secret generic "cluster-${NAME}" -n "${NS}" \
  --from-literal=name="${NAME}" \
  --from-literal="server=https://${PROXY_SVC}" \
  --from-file=config="${TMP}" \
  --dry-run=client -o yaml | oc apply -f -

oc label secret "cluster-${NAME}" -n "${NS}" argocd.argoproj.io/secret-type=cluster --overwrite

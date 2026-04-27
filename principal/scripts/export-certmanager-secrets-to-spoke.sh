#!/usr/bin/env bash
# Génère des manifests à appliquer sur le spoke (cert-manager) : client TLS renommé + CA sans clé privée.
# Prérequis : yq (https://github.com/mikefarah/yq/) v4.
# Usage : ./export-certmanager-secrets-to-spoke.sh managed-cluster-agent ./out
set -euo pipefail
AGENT_CERT_SECRET="${1:?ex: managed-cluster-agent}"
OUTDIR="${2:-./exported-secrets}"
NS="${3:-openshift-gitops}"

mkdir -p "${OUTDIR}"

oc get secret "${AGENT_CERT_SECRET}" -n "${NS}" -o yaml | \
  yq eval 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.annotations)' - | \
  yq eval '.metadata.name = "argocd-agent-client-tls"' - > "${OUTDIR}/argocd-agent-client-tls.yaml"

oc get secret argocd-agent-ca -n "${NS}" -o yaml | \
  yq eval 'del(.data."tls.key", .metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.annotations)' - | \
  yq eval '.type = "Opaque"' - > "${OUTDIR}/argocd-agent-ca-public.yaml"

echo "Fichiers générés dans ${OUTDIR}/"
echo "Sur le cluster spoke : oc apply -f ${OUTDIR}/"

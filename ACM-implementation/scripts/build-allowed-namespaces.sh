#!/usr/bin/env bash
# Print ARGOCD_PRINCIPAL_ALLOWED_NAMESPACES from clusters.env (for envsubst / principal ArgoCD CR).
# Usage:
#   set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
#   export ARGOCD_PRINCIPAL_ALLOWED_NAMESPACES="$(./ACM-implementation/scripts/build-allowed-namespaces.sh)"
set -euo pipefail

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

: "${GITOPS_NAMESPACE:=openshift-gitops}"

namespaces=("${GITOPS_NAMESPACE}" "agent-managed" "agent-autonomous")

append_clusters() {
  local csv="${1:-}"
  [[ -z "${csv}" ]] && return
  IFS=',' read -ra clusters <<< "${csv}"
  for cluster in "${clusters[@]}"; do
    cluster="$(trim "${cluster}")"
    [[ -n "${cluster}" ]] && namespaces+=("${cluster}")
  done
}

append_clusters "${MANAGED_SPOKE_CLUSTERS:-}"
append_clusters "${AUTONOMOUS_SPOKE_CLUSTERS:-}"

if [[ -n "${ARGOCD_PRINCIPAL_EXTRA_NAMESPACES:-}" ]]; then
  append_clusters "${ARGOCD_PRINCIPAL_EXTRA_NAMESPACES}"
fi

# Deduplicate while preserving order
seen=""
result=""
for ns in "${namespaces[@]}"; do
  if [[ ",${seen}," != *",${ns},"* ]]; then
    seen="${seen},${ns}"
    result="${result}${ns},"
  fi
done
result="${result%,}"
echo "${result}"

#!/usr/bin/env bash
# Create AppProjects required for autonomous mode UI on hub and spoke.
#
# Autonomous apps use project "default" on the spoke; on the hub they appear as
# {SPOKE_CLUSTER_NAME}-default in namespace {SPOKE_CLUSTER_NAME}.
#
# Usage (from repository root):
#   set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
#   ./ACM-implementation/scripts/apply-autonomous-appprojects.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
acm_dir="${repo_root}/ACM-implementation"

: "${AUTONOMOUS_SPOKE_CLUSTERS:?set AUTONOMOUS_SPOKE_CLUSTERS in clusters.env}"
: "${GITOPS_NAMESPACE:?set GITOPS_NAMESPACE in clusters.env}"

SPOKE_PROJECT="${SPOKE_PROJECT:-default}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
OC_SPOKE_CONTEXT="${SPOKE_CONTEXT:-}"

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

hub_oc=(oc)

IFS=',' read -ra clusters <<< "${AUTONOMOUS_SPOKE_CLUSTERS}"
for cluster in "${clusters[@]}"; do
  cluster="$(trim "${cluster}")"
  [[ -z "${cluster}" ]] && continue

  export SPOKE_CLUSTER_NAME="${cluster}"
  export SPOKE_PROJECT="${SPOKE_PROJECT}"
  export GITOPS_NAMESPACE="${GITOPS_NAMESPACE}"
  export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE}"

  echo ">>> Hub AppProject ${SPOKE_CLUSTER_NAME}-${SPOKE_PROJECT}"
  envsubst '${SPOKE_CLUSTER_NAME} ${SPOKE_PROJECT} ${GITOPS_NAMESPACE}' \
    < "${acm_dir}/appproject/hub-autonomous-appproject.yaml.template" | "${hub_oc[@]}" apply -f -

  spoke_context="${OC_SPOKE_CONTEXT:-${cluster}}"
  spoke_oc=(oc --context="${spoke_context}")

  echo ">>> Spoke AppProject ${SPOKE_PROJECT} (context: ${spoke_context})"
  envsubst '${SPOKE_CLUSTER_NAME} ${SPOKE_PROJECT} ${ARGOCD_NAMESPACE}' \
    < "${acm_dir}/appproject/spoke-autonomous-appproject.yaml.template" | "${spoke_oc[@]}" apply -f -
done

echo ">>> Verify hub AppProjects"
"${hub_oc[@]}" get appproject -n "${GITOPS_NAMESPACE}" -l argocd-agent-pov/mode=autonomous

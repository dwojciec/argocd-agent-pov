#!/usr/bin/env bash
# Render and apply ACM GitOpsCluster resources for managed and/or autonomous spokes.
#
# Prerequisites:
#   - oc logged in to the hub (principal)
#   - envsubst.env and ACM-implementation/clusters.env configured
#
# Usage (from repository root):
#   set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
#   ./ACM-implementation/scripts/apply-gitopsclusters.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
acm_dir="${repo_root}/ACM-implementation"
render_placement="${acm_dir}/scripts/render-placement.sh"

: "${CLUSTER_SET_NAME:?set CLUSTER_SET_NAME in clusters.env}"
: "${GITOPS_NAMESPACE:?set GITOPS_NAMESPACE in clusters.env}"

echo ">>> ManagedClusterSetBinding (${CLUSTER_SET_NAME} → ${GITOPS_NAMESPACE})"
envsubst '${CLUSTER_SET_NAME} ${GITOPS_NAMESPACE}' \
  < "${acm_dir}/managedclustersetbinding.yaml.template" | oc apply -f -

if [[ -n "${MANAGED_SPOKE_CLUSTERS:-}" ]]; then
  echo ">>> Placement + GitOpsCluster (managed mode): ${MANAGED_SPOKE_CLUSTERS}"
  "${render_placement}" placement-managed-spokes "${CLUSTER_SET_NAME}" "${GITOPS_NAMESPACE}" \
    "${MANAGED_SPOKE_CLUSTERS}" | oc apply -f -
  envsubst '${GITOPS_NAMESPACE}' \
    < "${acm_dir}/gitopscluster-managed.yaml.template" | oc apply -f -
else
  echo ">>> Skipping managed mode (MANAGED_SPOKE_CLUSTERS is empty)"
fi

if [[ -n "${AUTONOMOUS_SPOKE_CLUSTERS:-}" ]]; then
  echo ">>> Placement + GitOpsCluster (autonomous mode): ${AUTONOMOUS_SPOKE_CLUSTERS}"
  "${render_placement}" placement-autonomous-spokes "${CLUSTER_SET_NAME}" "${GITOPS_NAMESPACE}" \
    "${AUTONOMOUS_SPOKE_CLUSTERS}" | oc apply -f -
  envsubst '${GITOPS_NAMESPACE}' \
    < "${acm_dir}/gitopscluster-autonomous.yaml.template" | oc apply -f -
else
  echo ">>> Skipping autonomous mode (AUTONOMOUS_SPOKE_CLUSTERS is empty)"
fi

echo ">>> Verify"
oc get managedclustersetbinding -n "${GITOPS_NAMESPACE}"
oc get placement -n "${GITOPS_NAMESPACE}" 2>/dev/null || true
oc get gitopscluster -n "${GITOPS_NAMESPACE}" 2>/dev/null || true

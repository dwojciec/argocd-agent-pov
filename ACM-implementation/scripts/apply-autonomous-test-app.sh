#!/usr/bin/env bash
# Apply a spoke-side test Application for autonomous mode (run with spoke context).
#
# Usage:
#   set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
#   export SPOKE_CONTEXT=a-cluster   # kubectl/oc context for the autonomous spoke
#   ./ACM-implementation/scripts/apply-autonomous-test-app.sh [spoke-cluster-name]
#
# spoke-cluster-name defaults to the first entry in AUTONOMOUS_SPOKE_CLUSTERS (informational label only).
set -euo pipefail

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
acm_dir="${repo_root}/ACM-implementation"

: "${AUTONOMOUS_SPOKE_CLUSTERS:?set AUTONOMOUS_SPOKE_CLUSTERS in clusters.env}"
: "${GIT_REPO_URL:?set GIT_REPO_URL in clusters.env}"
: "${GIT_TARGET_REVISION:?set GIT_TARGET_REVISION in clusters.env}"
: "${WORKLOAD_PATH_KUSTOMIZE:?set WORKLOAD_PATH_KUSTOMIZE in clusters.env}"
: "${AUTONOMOUS_DEMO_NAMESPACE:=demo-autonomous}"

spoke_name="${1:-}"
if [[ -z "${spoke_name}" ]]; then
  IFS=',' read -ra clusters <<< "${AUTONOMOUS_SPOKE_CLUSTERS}"
  spoke_name="$(trim "${clusters[0]}")"
fi

export SPOKE_CLUSTER_NAME="${spoke_name}"
export APP_NAME="test-app-autonomous"
export TARGET_NAMESPACE="${AUTONOMOUS_DEMO_NAMESPACE}"
export WORKLOAD_PATH="${WORKLOAD_PATH_KUSTOMIZE}"
export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
OC_CONTEXT="${SPOKE_CONTEXT:-${KUBECONFIG_CONTEXT:-}}"
oc_cmd=(oc)
if [[ -n "${OC_CONTEXT}" ]]; then
  oc_cmd=(oc --context="${OC_CONTEXT}")
fi

echo ">>> Application ${APP_NAME} on spoke (autonomous) → namespace ${TARGET_NAMESPACE} (context: ${OC_CONTEXT:-current})"
envsubst '${APP_NAME} ${ARGOCD_NAMESPACE} ${TARGET_NAMESPACE} ${GIT_REPO_URL} ${GIT_TARGET_REVISION} ${WORKLOAD_PATH} ${SPOKE_CLUSTER_NAME}' \
  < "${acm_dir}/applications/autonomous/test-app-openshift-demo.yaml.template" | "${oc_cmd[@]}" apply -f -

echo ">>> Verify on spoke"
"${oc_cmd[@]}" get application.argoproj.io "${APP_NAME}" -n "${ARGOCD_NAMESPACE}"

#!/usr/bin/env bash
# Apply hub-side test Applications for managed-mode spokes (OpenShift-compatible demo).
#
# Usage (from repository root):
#   set -a && source envsubst.env && source ACM-implementation/clusters.env && set +a
#   ./ACM-implementation/scripts/apply-managed-test-apps.sh
set -euo pipefail

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
acm_dir="${repo_root}/ACM-implementation"

: "${MANAGED_SPOKE_CLUSTERS:?set MANAGED_SPOKE_CLUSTERS in clusters.env}"
: "${GITOPS_NAMESPACE:?set GITOPS_NAMESPACE in clusters.env}"
: "${GIT_REPO_URL:?set GIT_REPO_URL in clusters.env}"
: "${GIT_TARGET_REVISION:?set GIT_TARGET_REVISION in clusters.env}"
: "${WORKLOAD_PATH_KUSTOMIZE:?set WORKLOAD_PATH_KUSTOMIZE in clusters.env}"
: "${WORKLOAD_PATH_HELM:?set WORKLOAD_PATH_HELM in clusters.env}"
: "${MANAGED_DEMO_NAMESPACE:=demo-managed}"

IFS=',' read -ra clusters <<< "${MANAGED_SPOKE_CLUSTERS}"
index=0
for cluster in "${clusters[@]}"; do
  cluster="$(trim "${cluster}")"
  [[ -z "${cluster}" ]] && continue
  index=$((index + 1))

  if [[ "${index}" -eq 1 ]]; then
    workload_path="${WORKLOAD_PATH_KUSTOMIZE}"
    app_suffix="kustomize"
  else
    workload_path="${WORKLOAD_PATH_HELM}"
    app_suffix="helm"
  fi

  export SPOKE_CLUSTER_NAME="${cluster}"
  export APP_NAME="test-app-managed-${cluster}"
  export TARGET_NAMESPACE="${MANAGED_DEMO_NAMESPACE}"
  export WORKLOAD_PATH="${workload_path}"

  echo ">>> Application ${APP_NAME} → ${SPOKE_CLUSTER_NAME}/${TARGET_NAMESPACE} (${WORKLOAD_PATH})"
  envsubst '${APP_NAME} ${GITOPS_NAMESPACE} ${SPOKE_CLUSTER_NAME} ${TARGET_NAMESPACE} ${GIT_REPO_URL} ${GIT_TARGET_REVISION} ${WORKLOAD_PATH}' \
    < "${acm_dir}/applications/managed/test-app-openshift-demo.yaml.template" | oc apply -f -
done

echo ">>> Verify on hub"
oc get application.argoproj.io -n "${GITOPS_NAMESPACE}" -l test.argocd-agent-pov/mode=managed

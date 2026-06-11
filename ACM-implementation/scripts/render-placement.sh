#!/usr/bin/env bash
# Render a Placement manifest from a comma-separated cluster list.
# Usage:
#   render-placement.sh <placement-name> <cluster-set-name> <gitops-namespace> <cluster1,cluster2,...>
set -euo pipefail

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

placement_name="${1:?placement name}"
cluster_set="${2:?cluster set name}"
gitops_ns="${3:?gitops namespace}"
clusters_csv="${4:?comma-separated cluster names}"

values_yaml=""
IFS=',' read -ra clusters <<< "${clusters_csv}"
for cluster in "${clusters[@]}"; do
  cluster="$(trim "${cluster}")"
  [[ -z "${cluster}" ]] && continue
  values_yaml="${values_yaml}                - ${cluster}"$'\n'
done

if [[ -z "${values_yaml}" ]]; then
  echo "error: no cluster names in list: ${clusters_csv}" >&2
  exit 1
fi

cat <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ${placement_name}
  namespace: ${gitops_ns}
spec:
  clusterSets:
    - ${cluster_set}
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: name
              operator: In
              values:
${values_yaml}
EOF
